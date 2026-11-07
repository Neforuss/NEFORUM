import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' show Clock, PostProgress, PublishRunPlan, systemClock;

import '../platform/env.dart';
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

  /// What the run's own [PublishRunSession] says, when it has one. It knows more
  /// than the figures do (iOS's pause, a stop, posts that may be live).
  Map<String, Object?>? snapshot;

  /// The title native was given, kept for later `begin` calls.
  String? title;

  /// How the run ended, from whoever ended it first.
  String? summary;

  String? lastSent;
  DateTime? lastSentAt;
}

/// The one caller of [PublishHost]: every run of this process goes through it. A
/// failure of the host never reaches a run: every call to it is caught, and nothing
/// waits for one.
///
/// Holds are counted per post. The host hears `begin` at the first hold and `end`
/// at the last, so two callers on one post, or two posts at once, never stop the
/// keep-alive under each other. Each run sends its own snapshot, oldest first:
/// Android's one notification shows the oldest, iOS gives each its Live Activity.
///
/// A run with a session ([KeptPublishHost]) sends the session's snapshot; a run
/// without one (the scheduler's) is worded here from its figures.
class PublishRunKeeper {
  PublishRunKeeper({
    required PublishHost host,
    required this.onCancel,
    this.onOpenPost,
    this.onLimitReached,
    this.beforeReleaseHidden,
    this.onRefused,
    this.platform = PublishSurfacePlatform.none,
    this.timeoutCancelsRuns = true,
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

  /// Whose words the runs without a session get.
  final PublishSurfacePlatform platform;

  /// Android: `timedOut` is the service's limit, and the process ends seconds
  /// later, so every run stops with Retry. On iOS the run's session asks the
  /// person instead.
  final bool timeoutCancelsRuns;
  final AppLifecycleState? Function() _lifecycle;
  final Clock _now;
  late final StreamSubscription<PublishHostSignal> _signals;

  /// An unchanged picture still goes out this often while events arrive: each one
  /// tells native the run is alive, and a run that goes silent loses its wake lock.
  final Duration resendAfter;

  final Map<String, _KeptRun> _runs = {};
  PublishWindowPresence _window = PublishWindowPresence.open;

  /// What native says, for a run's session.
  Stream<PublishHostSignal> get signals => _host.signals;

  /// Posts being kept alive, oldest first.
  Iterable<String> get activePosts => _runs.keys;

  int holdsOf(String postId) => _runs[postId]?.holds ?? 0;

  PublishWindowPresence get windowState {
    final state = _lifecycle();
    if (state != AppLifecycleState.resumed && state != AppLifecycleState.inactive) return _window;
    // A window on screen is open, and stays so until native says it goes again.
    return _window = PublishWindowPresence.open;
  }

  void _onSignal(PublishHostSignal signal) {
    switch (signal) {
      case PublishHostCancelRequested(:final postId):
        if (_runs.containsKey(postId)) onCancel(postId);
      case PublishHostTimedOut():
        if (!timeoutCancelsRuns) return;
        // A few seconds to stop, or Android ends the process. Networks not reached
        // become cancelled, with Retry.
        for (final id in _runs.keys.toList()) {
          onCancel(id);
          onLimitReached?.call(kPublishLimitTitle, kPublishLimitBody, id);
        }
      case PublishHostWindowClosing():
        _window = PublishWindowPresence.gone;
      case PublishHostOpenPost(:final postId):
        onOpenPost?.call(postId);
    }
  }

  /// A run of [postId] is starting. Call it as soon as the person acts: Android only
  /// lets a visible app begin. Never waits, never throws.
  void begin(String postId) => unawaited(hold(postId));

  /// [begin] with the native answer: true when the OS took the run on. A further
  /// hold on a post already kept asks native again only when it brings a [title] or
  /// [networks].
  Future<bool> hold(String postId, {String? title, List<PublishHostNetwork> networks = const []}) {
    final run = _runs[postId];
    if (run != null) {
      run.holds++;
      if (title == null && networks.isEmpty) return Future.value(true);
      return retake(postId, title: title, networks: networks);
    }
    _runs[postId] = _KeptRun(postId)..title = title;
    // First: native takes `update` only for a run it knows.
    final started = _begin(postId, networks, first: true);
    _send(force: true);
    return started;
  }

  /// Asks native again for a run already kept: new networks for Android's bar, or
  /// new time on iOS after a stop (the person's Continue). Adds no hold.
  Future<bool> retake(String postId, {String? title, List<PublishHostNetwork> networks = const []}) {
    final run = _runs[postId];
    if (run == null) return Future.value(false);
    if (title != null) run.title = title;
    return _begin(postId, networks);
  }

  Future<bool> _begin(String postId, List<PublishHostNetwork> networks, {bool first = false}) async {
    final run = _runs[postId];
    final title = run?.title ?? (run == null ? '' : _snapshotOf(run, 0)['headline'] as String? ?? '');
    bool started;
    try {
      started = await _host.begin(postId: postId, title: title, networks: networks);
    } on Object catch (e) {
      debugPrint('publish-host begin failed: ${e.runtimeType}');
      started = false;
    }
    debugPrint('publish-host begin started=$started');
    if (!started && first && _runs.containsKey(postId) && !_hidden) onRefused?.call();
    return started;
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

  /// A new figure of [postId]'s run: pass it as the `onChange` of the run's one
  /// tracker (`PublishProgressNotifier.begin`), so the screens and native agree.
  void progress(String postId, PostProgress progress) {
    final run = _runs[postId];
    if (run == null) return;
    run.progress = progress;
    _send();
  }

  /// What [postId]'s session says now, to send in its own words.
  void sessionUpdate(String postId, Map<String, Object?> snapshot) {
    final run = _runs[postId];
    if (run == null) return;
    run.snapshot = snapshot;
    _send();
  }

  /// The run is doing something the tracker does not see (making a smaller video).
  void alive(String postId) {
    if (_runs.containsKey(postId)) _send();
  }

  bool get _visible => publishAppVisible(_lifecycle(), windowState);

  Map<String, Object?> _snapshotOf(_KeptRun run, int otherRuns) {
    final own = run.snapshot;
    if (own != null) {
      return otherRuns == 0 ? own : {...own, 'headline': publishRunsHeadline(own['headline'] as String? ?? '', otherRuns)};
    }
    final state = reducePublishSurface(
      run.progress,
      publishLifecycleOf(run.progress),
      PublishWindowState(visible: _visible),
      _now(),
      platform: platform,
      otherRuns: otherRuns,
    );
    return {...state.toSnapshot(), 'postId': run.postId};
  }

  void _send({bool force = false}) {
    final now = _now();
    final others = _runs.length - 1;
    for (final run in _runs.values) {
      final snapshot = _snapshotOf(run, others);
      final text = snapshot.toString();
      final last = run.lastSentAt;
      if (!force && text == run.lastSent && last != null && now.difference(last) < resendAfter) continue;
      run.lastSent = text;
      run.lastSentAt = now;
      unawaited(_quietly('update', () => _host.update(snapshot)));
    }
  }

  /// The hold on [postId] is over. Also fine after a failed [begin]. At the last hold
  /// the host stops, after a hidden app has saved what it must: with no service left
  /// Android may freeze the process at any time. [summary] is how the run went, in
  /// the words of whoever knows best; the first one given is kept for the end.
  Future<void> end(String postId, {PostProgress? finalProgress, String? summary}) async {
    final run = _runs[postId];
    if (run == null) return;
    run.summary ??= summary;
    if (--run.holds > 0) return;
    final figures = finalProgress ?? run.progress;
    final text = run.summary ?? (figures == null ? 'Posting stopped' : publishRunSummary(figures));
    if (_runs.length == 1 && (_hidden || windowState != PublishWindowPresence.open)) {
      try {
        await beforeReleaseHidden?.call().timeout(const Duration(seconds: 30));
      } on Object catch (e) {
        debugPrint('Before releasing the run: ${e.runtimeType}');
      }
      // A new hold came in meanwhile: this run stays on.
      if (run.holds > 0) return;
    }
    _runs.remove(postId);
    await _quietly('end', () => _host.end(postId: postId, summary: text));
    if (_runs.isNotEmpty) _send(force: true);
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

/// One run's view of the host, for its `PublishRunSession`: its first `begin` takes
/// a hold on the keeper and its `end` lets it go, a later `begin` asks native again
/// (Continue), and what it sends goes out through the keeper beside every other run.
/// Its signals are what a session acts on; Cancel and a tap on Android's
/// notification are the keeper's.
class KeptPublishHost implements PublishHost {
  KeptPublishHost(this._keeper);

  final PublishRunKeeper _keeper;
  final Set<String> _held = {};

  @override
  Future<bool> begin({required String postId, required String title, required List<PublishHostNetwork> networks}) =>
      _held.add(postId) ? _keeper.hold(postId, title: title, networks: networks) : _keeper.retake(postId, title: title, networks: networks);

  @override
  Future<void> update(Map<String, Object?> snapshot) async {
    final postId = snapshot['postId'];
    if (postId is String && _held.contains(postId)) _keeper.sessionUpdate(postId, snapshot);
  }

  /// Does not wait for the keeper: a hidden app saves before it lets go, and the
  /// run's result must not wait on that.
  @override
  Future<void> end({required String postId, required String summary}) async {
    if (_held.remove(postId)) unawaited(_keeper.end(postId, summary: summary));
  }

  @override
  Stream<PublishHostSignal> get signals => _keeper.signals.where((s) => s is PublishHostTimedOut || s is PublishHostWindowClosing);

  @override
  void dispose() {}
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
    platform: Env.isIOS
        ? PublishSurfacePlatform.ios
        : Env.isAndroid
            ? PublishSurfacePlatform.android
            : PublishSurfacePlatform.none,
    timeoutCancelsRuns: !Env.isIOS,
  );
  ref.onDispose(keeper.dispose);
  return keeper;
});
