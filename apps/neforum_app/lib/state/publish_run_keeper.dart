import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' show Clock, PostProgress, PublishProgressTracker, PublishRunPlan, systemClock;

import '../platform/notifications.dart';
import '../platform/publish_host.dart';
import 'providers.dart';
import 'publish_run_surface.dart';

/// The least a network counts on the bar, as `TargetProgressTracker.weight` counts it.
const int _kLeastShareBytes = 1024 * 1024;

class _KeptRun {
  _KeptRun(this.postId);
  final String postId;

  /// Callers holding this post's run: a composer run and the scheduler can overlap.
  int holds = 1;
  PostProgress? progress;
}

/// Between publish runs and [PublishHost]. A failure of the host never reaches a
/// run: every call to it is caught, and nothing waits for one.
///
/// Holds are counted per post. The host hears `begin` at the first hold and `end`
/// at the last, so two callers on one post, or two posts at once, never stop the
/// keep-alive under each other. The surface follows the oldest run.
class PublishRunKeeper {
  PublishRunKeeper({
    required PublishHost host,
    required this.onCancel,
    this.onOpenPost,
    this.onLimitReached,
    this.beforeReleaseHidden,
    this.onRefused,
    AppLifecycleState? Function()? lifecycle,
    Clock? clock,
    this.resendAfter = const Duration(seconds: 60),
  })  : _host = host,
        _lifecycle = lifecycle ?? (() => WidgetsBinding.instance.lifecycleState),
        _now = clock ?? systemClock {
    _signals = host.signals.listen(_onSignal);
  }

  final PublishHost _host;

  /// Stops the run of a post: what Activity's Cancel button does.
  final void Function(String postId) onCancel;
  final void Function(String postId)? onOpenPost;
  final void Function(String title, String body, String postId)? onLimitReached;

  /// Saves what must be saved before a hidden app loses its keep-alive.
  final Future<void> Function()? beforeReleaseHidden;

  /// Android said no while the person is looking.
  final void Function()? onRefused;
  final AppLifecycleState? Function() _lifecycle;
  final Clock _now;
  late final StreamSubscription<PublishHostSignal> _signals;

  /// An unchanged picture still goes out this often while events arrive: each one
  /// tells native the run is alive, and a run that goes silent loses its wake lock.
  final Duration resendAfter;

  final Map<String, _KeptRun> _runs = {};
  PublishWindowState _window = PublishWindowState.open;
  String? _lastSent;
  DateTime? _lastSentAt;

  /// Posts being kept alive, oldest first.
  Iterable<String> get activePosts => _runs.keys;

  int holdsOf(String postId) => _runs[postId]?.holds ?? 0;

  PublishWindowState get windowState {
    final state = _lifecycle();
    if (state != AppLifecycleState.resumed && state != AppLifecycleState.inactive) return _window;
    // A window on screen is open, and stays so until native says it goes again.
    return _window = PublishWindowState.open;
  }

  void _onSignal(PublishHostSignal signal) {
    switch (signal) {
      case PublishHostCancelRequested(:final postId):
        if (_runs.containsKey(postId)) onCancel(postId);
      case PublishHostTimedOut():
        // A few seconds to stop, or Android ends the process. Networks not reached
        // become cancelled, with Retry.
        for (final id in _runs.keys.toList()) {
          onCancel(id);
          onLimitReached?.call(kPublishLimitTitle, kPublishLimitBody, id);
        }
      case PublishHostWindowClosing():
        _window = PublishWindowState.gone;
      case PublishHostOpenPost(:final postId):
        onOpenPost?.call(postId);
    }
  }

  /// A run of [postId] is starting. Call it as soon as the person acts: Android only
  /// lets a visible app begin. Never waits, never throws.
  void begin(String postId) {
    final run = _runs[postId];
    if (run != null) {
      run.holds++;
      return;
    }
    _runs[postId] = _KeptRun(postId);
    // First: native takes `update` only for a run it knows.
    unawaited(_begin(postId, const [], first: true));
    _send(force: true);
  }

  Future<void> _begin(String postId, List<PublishHostNetwork> networks, {bool first = false}) async {
    final title = _surface().headline;
    bool started;
    try {
      started = await _host.begin(postId: postId, title: title, networks: networks);
    } on Object catch (e) {
      debugPrint('publish-host begin failed: ${e.runtimeType}');
      started = false;
    }
    debugPrint('publish-host begin started=$started');
    if (!started && first && _runs.containsKey(postId) && !_hidden) onRefused?.call();
  }

  /// The run's targets are known: their share of the bar goes to native.
  void planned(String postId, PublishRunPlan plan) {
    if (!_runs.containsKey(postId)) return;
    final networks = [
      for (final t in plan.targets)
        PublishHostNetwork(id: t.accountId, name: t.name, bytes: math.max(t.shape.plannedBytes, _kLeastShareBytes)),
    ];
    unawaited(_begin(postId, networks));
  }

  /// A tracker for [postId]'s run that feeds this keeper.
  PublishProgressTracker tracker(String postId) => PublishProgressTracker(postId: postId, onChange: (p) => progress(postId, p), clock: _now);

  void progress(String postId, PostProgress progress) {
    final run = _runs[postId];
    if (run == null) return;
    run.progress = progress;
    _send();
  }

  /// The run is doing something the tracker does not see (making a smaller video).
  void alive(String postId) {
    if (_runs.containsKey(postId)) _send();
  }

  PublishSurfaceState _surface() => publishRunSurface(
        _runs.isEmpty ? null : _runs.values.first.progress,
        lifecycle: _lifecycle(),
        window: windowState,
        now: _now(),
        otherRuns: _runs.isEmpty ? 0 : _runs.length - 1,
      );

  void _send({bool force = false}) {
    final snapshot = _surface().toSnapshot();
    final text = snapshot.toString();
    final now = _now();
    final last = _lastSentAt;
    if (!force && text == _lastSent && last != null && now.difference(last) < resendAfter) return;
    _lastSent = text;
    _lastSentAt = now;
    unawaited(_quietly('update', () => _host.update(snapshot)));
  }

  /// The hold on [postId] is over. Also fine after a failed [begin]. At the last hold
  /// the host stops, after a hidden app has saved what it must: with no service left
  /// Android may freeze the process at any time.
  Future<void> end(String postId, {PostProgress? finalProgress}) async {
    final run = _runs[postId];
    if (run == null) return;
    if (--run.holds > 0) return;
    final summary = publishRunSurface(finalProgress ?? run.progress, lifecycle: _lifecycle(), window: windowState, now: _now()).headline;
    if (_runs.length == 1 && (_hidden || windowState != PublishWindowState.open)) {
      try {
        await beforeReleaseHidden?.call().timeout(const Duration(seconds: 30));
      } on Object catch (e) {
        debugPrint('Before releasing the run: ${e.runtimeType}');
      }
      // A new hold came in meanwhile: this run stays on.
      if (run.holds > 0) return;
    }
    _runs.remove(postId);
    await _quietly('end', () => _host.end(postId: postId, summary: summary));
    if (_runs.isNotEmpty) {
      _send(force: true);
    } else {
      _lastSent = null;
      _lastSentAt = null;
    }
  }

  bool get _hidden {
    final state = _lifecycle();
    return state != null && state != AppLifecycleState.resumed && state != AppLifecycleState.inactive;
  }

  Future<void> _quietly(String what, Future<void> Function() call) async {
    try {
      await call();
    } on Object catch (e) {
      debugPrint('publish-host $what failed: ${e.runtimeType}');
    }
  }

  void dispose() {
    unawaited(_signals.cancel());
    _host.dispose();
  }
}

/// Words for a keep-alive Android refused. They say what to do and promise nothing.
const String kPublishKeepAliveRefused = 'Android would not let this post go on in the background. Keep NEFORUM open until it finishes.';

/// Counts the refused keep-alives; the app shell shows [kPublishKeepAliveRefused].
class PublishKeepAliveRefused extends Notifier<int> {
  @override
  int build() => 0;
  void refused() => state++;
}

final publishKeepAliveRefusedProvider = NotifierProvider<PublishKeepAliveRefused, int>(PublishKeepAliveRefused.new);

/// The host for this workspace. Tests put a fake here.
final publishHostProvider = Provider<PublishHost>((ref) => createPublishHost(demo: ref.watch(isDemoProvider)));

final publishRunKeeperProvider = Provider<PublishRunKeeper>((ref) {
  final services = ref.watch(servicesProvider);
  final keeper = PublishRunKeeper(
    host: ref.watch(publishHostProvider),
    onCancel: (id) => cancelPublishRun(ref, id),
    onOpenPost: NotificationService.instance.openPost,
    onLimitReached: (title, body, id) => unawaited(NotificationService.instance.show(key: 'result:$id', title: title, body: body, payload: 'post:$id')),
    beforeReleaseHidden: () async {
      await services.cloudSync.syncNow();
    },
    onRefused: () => ref.read(publishKeepAliveRefusedProvider.notifier).refused(),
  );
  ref.onDispose(keeper.dispose);
  return keeper;
});
