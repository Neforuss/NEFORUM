import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart'
    show Clock, Logger, Post, PostProgress, ProgressFamily, PublishPauseSignal, TargetOutcome, TargetProgress, TargetStatus, systemClock;

import '../platform/env.dart';
import '../platform/notifications.dart';
import '../platform/publish_host.dart';
import 'providers.dart' show activePublishingProvider, publishRunProvider, servicesProvider;
import 'publish_run_surface.dart';
import 'services.dart';

/// A notification the system delivers by itself if the app stops running. It needs
/// no code at that moment, which is the whole point: a frozen app cannot say so.
abstract interface class PublishDeadMan {
  /// Replaces the post's earlier one, so each heartbeat pushes it back.
  Future<void> arm(String postId, PublishSurfaceNotice notice, DateTime at);

  /// Also removes it from Notification Center if it was delivered.
  Future<void> disarm(String postId);
  Future<void> show(String postId, PublishSurfaceNotice notice);
}

/// [PublishDeadMan] through local notifications, under the key
/// [NotificationService.postKeys] lists, so deleting the post removes it.
class NotificationPublishDeadMan implements PublishDeadMan {
  const NotificationPublishDeadMan();

  static String key(String postId) => 'paused:$postId';

  @override
  Future<void> arm(String postId, PublishSurfaceNotice notice, DateTime at) =>
      NotificationService.instance.schedule(key: key(postId), when: at, title: notice.title, body: notice.body, payload: 'post:$postId');

  @override
  Future<void> disarm(String postId) => NotificationService.instance.cancel(key(postId));

  @override
  Future<void> show(String postId, PublishSurfaceNotice notice) =>
      NotificationService.instance.show(key: key(postId), title: notice.title, body: notice.body, payload: 'post:$postId');
}

/// Silent, for platforms with nothing to arm.
class NoPublishDeadMan implements PublishDeadMan {
  const NoPublishDeadMan();

  @override
  Future<void> arm(String postId, PublishSurfaceNotice notice, DateTime at) async {}

  @override
  Future<void> disarm(String postId) async {}

  @override
  Future<void> show(String postId, PublishSurfaceNotice notice) async {}
}

/// One run's life outside the app. It feeds the pure reducer from what really
/// happens (progress, the window, the system's calls) and passes the result on.
/// It never holds up the run: a failed host only means no surface.
class PublishRunSession {
  PublishRunSession({
    required this.postId,
    required this._host,
    required this._deadMan,
    required this.platform,
    required this._onCancel,
    this._onState,
    this._visible = true,
    Clock? clock,
    Logger? log,
  })  : _now = clock ?? systemClock,
        _log = log ?? Logger('publish-run') {
    _lastBeat = _now();
    _state = _reduce();
    _events = _host.events.listen(_onEvent);
  }

  /// How often a live process says so.
  static const heartbeatInterval = Duration(seconds: 15);

  /// A heartbeat this late means the process was not running. Also how far ahead
  /// the dead-man notification is set.
  static const frozenAfter = Duration(seconds: 45);

  /// How long "iOS paused NEFORUM. Continuing." stays.
  static const pausedNoticeFor = Duration(seconds: 5);

  final String postId;
  final PublishSurfacePlatform platform;

  /// While paused, no new request that makes a post starts. Uploads go on.
  final PublishPauseSignal pause = PublishPauseSignal();

  final PublishHost _host;
  final PublishDeadMan _deadMan;
  final void Function() _onCancel;
  final void Function(PublishSurfaceState state)? _onState;
  final Clock _now;
  final Logger _log;
  late final StreamSubscription<PublishHostEvent> _events;

  PublishRunLifecycle _lifecycle = PublishRunLifecycle.preparing;
  PostProgress? _progress;
  Set<String> _unknown = const {};
  bool _visible;
  DateTime? _pausedNoticeUntil;
  late DateTime _lastBeat;
  bool _wasFrozen = false;
  bool _armed = false;
  String? _armedText;
  String? _shownText;
  Timer? _timer;
  Timer? _noticeTimer;
  bool _ended = false;
  late PublishSurfaceState _state;
  List<PublishHostNetwork> _networks = const [];
  String _title = '';

  // The trace: one local line per run saying what kept it and how it ended.
  bool _keeperTookIt = false;
  int _freezes = 0;
  int _closings = 0;
  int _stops = 0;

  PublishSurfaceState get state => _state;
  bool get isEnded => _ended;

  PublishSurfaceState _reduce() => reducePublishSurface(
        _progress,
        _lifecycle,
        PublishWindowState(visible: _visible, pausedNoticeUntil: _pausedNoticeUntil),
        _now(),
        platform: platform,
        outcomeUnknown: _unknown,
      );

  /// Hands the run to the system's side at the person's tap, while NEFORUM is in
  /// front, and does not wait: the run starts at the tap whatever the answer.
  void begin({required String title, required List<PublishHostNetwork> networks}) {
    _title = title;
    _networks = networks;
    _timer ??= Timer.periodic(heartbeatInterval, (_) => beat());
    unawaited(_begin());
  }

  Future<void> _begin() async {
    final took = await _host.begin(postId: postId, title: _title, networks: _networks);
    _keeperTookIt = _keeperTookIt || took;
  }

  /// A new figure from the run's tracker.
  void progress(PostProgress p) {
    if (_ended) return;
    _progress = p;
    if (_lifecycle == PublishRunLifecycle.preparing) _lifecycle = PublishRunLifecycle.running;
    _publish();
  }

  /// Says the process is alive: pushes the dead-man back, and keeps the Live
  /// Activity from going stale. A frozen process makes no such call, which is what
  /// makes both of them tell the truth.
  void beat() {
    if (_ended) return;
    final now = _now();
    if (now.difference(_lastBeat) > frozenAfter) {
      _wasFrozen = true;
      _freezes++;
    }
    _lastBeat = now;
    if (_pausedNoticeUntil != null && !now.isBefore(_pausedNoticeUntil!)) _pausedNoticeUntil = null;
    _armed = false;
    _publish();
  }

  /// The window came forward or went away.
  void windowChanged({required bool visible}) {
    if (_ended || visible == _visible) return;
    _visible = visible;
    if (!visible) {
      _publish();
      return;
    }
    // A timer can run before this call, so a freeze is also noticed by beat().
    final now = _now();
    if (_wasFrozen || now.difference(_lastBeat) > frozenAfter) {
      if (!_wasFrozen) _freezes++;
      if (platform == PublishSurfacePlatform.ios) {
        _pausedNoticeUntil = now.add(pausedNoticeFor);
        _noticeTimer?.cancel();
        _noticeTimer = Timer(pausedNoticeFor, beat);
      }
    }
    _wasFrozen = false;
    _lastBeat = now;
    if (_lifecycle == PublishRunLifecycle.holding) _lifecycle = PublishRunLifecycle.running;
    // A stopped run waits for the person's answer: Continue or Cancel the rest.
    if (_lifecycle != PublishRunLifecycle.stopped) pause.resume();
    _publish();
  }

  void _onEvent(PublishHostEvent event) {
    if (_ended) return;
    switch (event) {
      case PublishHostCancelRequested(postId: final id):
        if (id == postId) _onCancel();
      case PublishHostWindowClosing():
        if (_visible || _lifecycle == PublishRunLifecycle.stopped) return;
        _closings++;
        _lifecycle = PublishRunLifecycle.holding;
        pause.pause();
        _publish();
      case PublishHostTimedOut():
        _stops++;
        _lifecycle = PublishRunLifecycle.stopped;
        pause.pause();
        _publish();
    }
  }

  /// The person's Continue. An explicit tap, so the system may give new time.
  void continueRun() {
    if (_ended || _lifecycle != PublishRunLifecycle.stopped) return;
    _lifecycle = _progress == null ? PublishRunLifecycle.preparing : PublishRunLifecycle.running;
    _shownText = null;
    pause.resume();
    unawaited(_begin());
    _publish();
  }

  void _publish() {
    final next = _reduce();
    _state = next;
    _onState?.call(next);
    unawaited(_host.update(next.toSnapshot()));
    _syncDeadMan(next);
  }

  void _syncDeadMan(PublishSurfaceState s) {
    final notice = s.deadMan;
    if (s.showNow case final now?) {
      _armed = false;
      _armedText = null;
      // Once: every heartbeat of a stopped run comes through here.
      if (_shownText != now.text) unawaited(_deadMan.show(postId, now));
      _shownText = now.text;
    } else if (notice == null) {
      if (_armedText != null) unawaited(_deadMan.disarm(postId));
      _armed = false;
      _armedText = null;
    } else if (!_armed || _armedText != notice.text) {
      // Set back on each heartbeat, and at once when the counts change.
      _armed = true;
      _armedText = notice.text;
      unawaited(_deadMan.arm(postId, notice, _now().add(frozenAfter)));
    }
  }

  /// The run has an outcome. [unknown] names the accounts whose post may be live
  /// although no answer says so.
  Future<PublishSurfaceState> finish(PostProgress? finalProgress, {Set<String> unknown = const {}, String? error}) async {
    if (_ended) return _state;
    _ended = true;
    if (finalProgress != null) _progress = finalProgress;
    _unknown = unknown;
    _lifecycle = PublishRunLifecycle.finished;
    _state = _reduce();
    _onState?.call(_state);
    _stopTimers();
    pause.resume();
    await _deadMan.disarm(postId);
    final summary = error != null || _progress == null ? 'Posting stopped' : (_state.resultSummary ?? 'Posting stopped');
    await _host.end(postId: postId, summary: summary);
    await _events.cancel();
    // Fields only: toString is minified in profile builds.
    _log.debug(
        'Run $postId: keeper ${_keeperTookIt ? 'took it' : 'not available'}, freezes $_freezes, closings $_closings, stops $_stops, ended ${_state.phase.name}');
    return _state;
  }

  void _stopTimers() {
    _timer?.cancel();
    _timer = null;
    _noticeTimer?.cancel();
    _noticeTimer = null;
  }

  /// Only for a run that goes no further with no outcome (tests, shutdown).
  void dispose() {
    _ended = true;
    _stopTimers();
    pause.resume();
    unawaited(_events.cancel());
  }
}

/// The host this app uses. Tests put their own here.
final publishHostProvider = Provider<PublishHost>((ref) => publishHostForPlatform(demo: ref.read(servicesProvider).demo));

/// The dead-man notification only exists on iOS: elsewhere the run keeps going.
final publishDeadManProvider = Provider<PublishDeadMan>((ref) => Env.isIOS && !ref.read(servicesProvider).demo ? const NotificationPublishDeadMan() : const NoPublishDeadMan());

/// Runs from a tap in this process, each with what its surfaces show.
class PublishSurfaceNotifier extends Notifier<PublishSurfaceState?> {
  final Map<String, PublishRunSession> _sessions = {};
  bool _visible = true;

  @override
  PublishSurfaceState? build() {
    ref.onDispose(() {
      for (final s in _sessions.values) {
        s.dispose();
      }
      _sessions.clear();
    });
    return null;
  }

  static PublishSurfacePlatform get _platform => Env.isIOS
      ? PublishSurfacePlatform.ios
      : Env.isAndroid
          ? PublishSurfacePlatform.android
          : PublishSurfacePlatform.none;

  /// Starts a run's session, replacing an earlier one for the same post.
  PublishRunSession start(String postId, {required String title, required List<PublishHostNetwork> networks}) {
    _sessions.remove(postId)?.dispose();
    final session = PublishRunSession(
      postId: postId,
      host: ref.read(publishHostProvider),
      deadMan: ref.read(publishDeadManProvider),
      platform: _platform,
      visible: _visible,
      onCancel: () => _cancel(postId),
      onState: (s) => state = s,
    );
    _sessions[postId] = session;
    session.begin(title: title, networks: networks);
    return session;
  }

  void _cancel(String postId) {
    ref.read(activePublishingProvider.notifier).cancel(postId);
    if (ref.read(publishRunProvider)?.postId == postId) ref.read(publishRunProvider.notifier).cancel();
  }

  /// The session has finished: its last state stays until the next run.
  void remove(String postId, PublishRunSession session) {
    if (identical(_sessions[postId], session)) _sessions.remove(postId);
  }

  /// The Continue button.
  void continueRun(String postId) => _sessions[postId]?.continueRun();

  void windowChanged({required bool visible}) {
    _visible = visible;
    for (final s in _sessions.values) {
      s.windowChanged(visible: visible);
    }
  }
}

final publishSurfaceProvider = NotifierProvider<PublishSurfaceNotifier, PublishSurfaceState?>(PublishSurfaceNotifier.new);

/// Tells running sessions when NEFORUM comes forward or goes away. `inactive` is
/// still in front (Notification Center pulled down, an incoming call): the app runs.
AppLifecycleListener publishWindowListener(WidgetRef ref) => AppLifecycleListener(onStateChange: (s) {
      ref.read(publishSurfaceProvider.notifier).windowChanged(visible: s == AppLifecycleState.resumed || s == AppLifecycleState.inactive);
    });

/// The networks of [post] a run left behind when its process ended (see
/// [AppServices.interruptedMessage]). A post that may be live is not among them:
/// it fails with its own words and is never sent again by itself.
Set<String> closedRunAccounts(Post post) => {
      for (final t in post.targets)
        if (t.status == TargetStatus.failed && t.result?.error?.message == AppServices.interruptedMessage) t.accountId,
    };

/// What Activity says about such a post at the next launch.
PublishSurfaceState closedRunSurface(Post post, DateTime now) {
  TargetOutcome? outcomeOf(TargetStatus s) => switch (s) {
        TargetStatus.published || TargetStatus.handedOff => TargetOutcome.published,
        TargetStatus.failed => TargetOutcome.failed,
        TargetStatus.cancelled => TargetOutcome.cancelled,
        TargetStatus.skipped => TargetOutcome.skipped,
        TargetStatus.awaitingHandoff => TargetOutcome.awaitingUser,
        _ => null,
      };
  final posted = post.targets.where((t) => outcomeOf(t.status) == TargetOutcome.published).length;
  final failed = post.targets.where((t) => t.status == TargetStatus.failed).length;
  return reducePublishSurface(
    PostProgress(
      postId: post.id,
      permille: 0,
      posted: posted,
      failed: failed,
      total: post.targets.length,
      at: now,
      targets: [
        for (final t in post.targets)
          TargetProgress(accountId: t.accountId, name: '', permille: null, family: ProgressFamily.opaque, stage: null, label: null, stageStartedAt: null, outcome: outcomeOf(t.status)),
      ],
    ),
    PublishRunLifecycle.closed,
    const PublishWindowState(visible: true),
    now,
    platform: PublishSurfacePlatform.ios,
  );
}
