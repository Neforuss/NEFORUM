import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:neforum_core/neforum_core.dart' show PostProgress, ProgressStage, TargetOutcome, TargetProgress;

/// Which operating system's rules the wording follows.
enum PublishSurfacePlatform { ios, android, none }

/// Where a run stands, as far as this process can know.
enum PublishRunLifecycle {
  /// The post is being saved and its files made. No network has been touched.
  preparing,

  /// Going on, on screen or in time the system granted.
  running,

  /// The system said the app's time is about to end: no new post starts, and the
  /// app expects to be frozen in a moment.
  holding,

  /// The system took the time back, or the person pressed Stop in the system's
  /// own view. The two look alike to the app, so it asks instead of guessing.
  stopped,

  /// Seen at the next launch: the process ended during the run.
  closed,

  /// Every target has its outcome.
  finished,
}

/// Whether the person can see NEFORUM.
@immutable
class PublishWindowState {
  const PublishWindowState({required this.visible, this.pausedNoticeUntil});

  final bool visible;

  /// Set on return when the system froze the app while it was away.
  final DateTime? pausedNoticeUntil;
}

/// What the reducer says a run is doing. Never a new value in a synced model:
/// this is only for surfaces on this device.
enum PublishSurfacePhase { preparing, posting, waiting, paused, stopped, closed, done, partlyDone }

/// What the person can press.
enum PublishSurfaceAction { continueRun, cancelRest, retry }

/// A notification's words.
@immutable
class PublishSurfaceNotice {
  const PublishSurfaceNotice(this.title, this.body);

  final String title;
  final String body;

  String get text => '$title. $body';
}

/// One network in a host snapshot.
@immutable
class PublishSurfaceNetwork {
  const PublishSurfaceNetwork({required this.id, required this.state, required this.permille});

  final String id;

  /// pending, working, waiting, waitingForYou, posted, failed, unconfirmed,
  /// cancelled or skipped.
  final String state;
  final int? permille;

  Map<String, Object?> toJson() => {'id': id, 'state': state, 'permille': permille};
}

/// Everything every surface says about a run. All wording in the app, the Live
/// Activity and the notifications comes from here: native code only shows it.
@immutable
class PublishSurfaceState {
  const PublishSurfaceState({
    required this.postId,
    required this.phase,
    this.inAppNotice,
    this.leaveWarning,
    this.actions = const [],
    this.activityLabel,
    this.activityShortLabel,
    this.pausedLabel,
    this.pausedShortLabel,
    this.stageLabel,
    this.currentNetwork,
    this.postPermille,
    this.posted = 0,
    this.failed = 0,
    this.total = 0,
    this.networks = const [],
    this.systemUnits,
    this.systemSubtitle,
    this.backgrounded = false,
    this.deadMan,
    this.showNow,
    this.unconfirmedLines = const [],
    this.resultSummary,
  });

  final String? postId;
  final PublishSurfacePhase phase;

  /// The line this state shows inside the app, if it has one of its own.
  final String? inAppNotice;

  /// The warning that leaving can stop the run. Only where that is true.
  final String? leaveWarning;
  final List<PublishSurfaceAction> actions;

  /// The Live Activity's line. Null means no Live Activity should be showing.
  final String? activityLabel;
  final String? activityShortLabel;

  /// What the Live Activity reads once it has gone stale. The system flips it
  /// with no code running, so it is sent ahead with every update.
  final String? pausedLabel;
  final String? pausedShortLabel;
  final String? stageLabel;
  final String? currentNetwork;

  /// Null when no figure can be shown. A wait never moves it.
  final int? postPermille;
  final int posted;
  final int failed;
  final int total;
  final List<PublishSurfaceNetwork> networks;

  /// For iOS's own bar on a continued task, out of 1,000,000: this post's figure
  /// plus the poll requests really made in this wait. Apple ends tasks that report
  /// nothing, and the extra stays under 0.1% of the bar.
  final int? systemUnits;
  final String? systemSubtitle;
  final bool backgrounded;

  /// Delivered by the system if the app's heartbeat stops. Set means armed.
  final PublishSurfaceNotice? deadMan;

  /// To deliver right away.
  final PublishSurfaceNotice? showNow;

  /// One line per network whose post may be live although no answer says so.
  final List<String> unconfirmedLines;

  /// How the run ended, in a few words.
  final String? resultSummary;

  /// The line for the progress sheet. A waiting network's own words are on its
  /// row, and the sheet has its own words for getting ready.
  String? get sheetLine => switch (phase) {
        PublishSurfacePhase.preparing => null,
        PublishSurfacePhase.waiting => leaveWarning,
        _ => inAppNotice,
      };

  /// The `update` argument of `neforum/publish_host`. The fields after `networks`
  /// add to the contract: Android may ignore them. Never the post's text.
  Map<String, Object?> toSnapshot() => {
        'phase': phase.name,
        'postPermille': postPermille,
        'posted': posted,
        'failed': failed,
        'total': total,
        'currentNetwork': currentNetwork,
        'stageLabel': stageLabel,
        'networks': [for (final n in networks) n.toJson()],
        'postId': postId,
        'activityLabel': activityLabel,
        'activityShortLabel': activityShortLabel,
        'pausedLabel': pausedLabel,
        'pausedShortLabel': pausedShortLabel,
        'systemUnits': systemUnits,
        'systemSubtitle': systemSubtitle,
        'backgrounded': backgrounded,
      };
}

/// What a title says when a run starts. The post's own text never goes here: a
/// Lock Screen is public.
String publishSurfaceTitle(int networks) => 'Posting to $networks ${networks == 1 ? 'network' : 'networks'}';

/// Pure: the same input gives the same output, so every row of the design table
/// lives in gate tests. [outcomeUnknown] holds the accounts whose post may be live
/// although no answer says so ([PublishError.outcomeUnknown]): they read as not
/// finished, never as posted or failed.
PublishSurfaceState reducePublishSurface(
  PostProgress? progress,
  PublishRunLifecycle lifecycle,
  PublishWindowState window,
  DateTime now, {
  PublishSurfacePlatform platform = PublishSurfacePlatform.none,
  Set<String> outcomeUnknown = const {},
}) {
  final ios = platform == PublishSurfacePlatform.ios;
  if (lifecycle == PublishRunLifecycle.preparing || progress == null) {
    return PublishSurfaceState(
      postId: progress?.postId,
      phase: lifecycle == PublishRunLifecycle.closed ? PublishSurfacePhase.closed : PublishSurfacePhase.preparing,
      inAppNotice: lifecycle == PublishRunLifecycle.closed ? 'NEFORUM was closed before this finished.' : 'Getting your post ready…',
      backgrounded: !window.visible,
    );
  }

  final targets = progress.targets;
  final unknown = [for (final t in targets) if (outcomeUnknown.contains(t.accountId)) t];
  final posted = progress.posted;
  final failed = targets.where((t) => t.outcome == TargetOutcome.failed && !outcomeUnknown.contains(t.accountId)).length;
  final total = progress.total;
  final over = targets.where((t) => t.finished && !outcomeUnknown.contains(t.accountId)).length;
  final toGo = math.max(0, total - over);
  final postedLine = '$posted of $total posted';
  final networks = [for (final t in targets) _network(t, outcomeUnknown)];
  final unconfirmedLines = [for (final t in unknown) '${t.name}: NEFORUM could not confirm this. Check ${t.name} before retrying.'];

  PublishSurfaceState build({
    required PublishSurfacePhase phase,
    String? inAppNotice,
    String? leaveWarning,
    List<PublishSurfaceAction> actions = const [],
    String? activityLabel,
    String? activityShortLabel,
    String? pausedLabel,
    String? pausedShortLabel,
    String? stageLabel,
    String? currentNetwork,
    int? postPermille,
    int? systemUnits,
    String? systemSubtitle,
    PublishSurfaceNotice? deadMan,
    PublishSurfaceNotice? showNow,
    String? resultSummary,
  }) =>
      PublishSurfaceState(
        postId: progress.postId,
        phase: phase,
        inAppNotice: inAppNotice,
        leaveWarning: leaveWarning,
        actions: actions,
        activityLabel: activityLabel,
        activityShortLabel: activityShortLabel,
        pausedLabel: pausedLabel,
        pausedShortLabel: pausedShortLabel,
        stageLabel: stageLabel,
        currentNetwork: currentNetwork,
        postPermille: postPermille,
        posted: posted,
        failed: failed,
        total: total,
        networks: networks,
        systemUnits: systemUnits,
        systemSubtitle: systemSubtitle,
        backgrounded: !window.visible,
        deadMan: deadMan,
        showNow: showNow,
        unconfirmedLines: unconfirmedLines,
        resultSummary: resultSummary,
      );

  switch (lifecycle) {
    case PublishRunLifecycle.closed:
      return build(
        phase: PublishSurfacePhase.closed,
        inAppNotice: 'NEFORUM was closed before this finished. $postedLine.',
        actions: const [PublishSurfaceAction.continueRun],
      );
    case PublishRunLifecycle.stopped:
      return build(
        phase: PublishSurfacePhase.stopped,
        inAppNotice: 'Stopped. $postedLine.',
        actions: const [PublishSurfaceAction.continueRun, PublishSurfaceAction.cancelRest],
        postPermille: progress.permille,
        showNow: window.visible ? null : const PublishSurfaceNotice('Stopped', 'Open NEFORUM to continue.'),
      );
    case PublishRunLifecycle.finished:
      // Unconfirmed networks are counted as not finished, so they are named, never
      // added to what failed or what went out.
      final waitingForYou = targets.where((t) => t.outcome == TargetOutcome.awaitingUser).length;
      final cancelled = targets.where((t) => t.outcome == TargetOutcome.cancelled && !outcomeUnknown.contains(t.accountId)).length;
      final extras = [
        if (failed > 0) '$failed failed',
        if (unknown.isNotEmpty) '${unknown.length} not confirmed',
        if (cancelled > 0) '$cancelled cancelled',
        if (waitingForYou > 0) '$waitingForYou waiting for you',
      ];
      final summary = total == 0
          ? 'Nothing was posted'
          : extras.isEmpty
              ? 'Posted to $posted of $total'
              : 'Posted to $posted of $total, ${extras.join(', ')}';
      return build(
        phase: total > 0 && posted == total ? PublishSurfacePhase.done : PublishSurfacePhase.partlyDone,
        inAppNotice: summary,
        actions: failed > 0 ? const [PublishSurfaceAction.retry] : const [],
        activityLabel: summary,
        activityShortLabel: '$posted/$total',
        pausedLabel: summary,
        pausedShortLabel: '$posted/$total',
        postPermille: progress.permille,
        resultSummary: summary,
      );
    case PublishRunLifecycle.preparing:
    case PublishRunLifecycle.running:
    case PublishRunLifecycle.holding:
      break;
  }

  // The run is going on, or about to be frozen with the next post held back.
  final pausedText = ios ? 'Paused by iOS. $postedLine. Open NEFORUM to finish.' : 'Paused. $postedLine. Open NEFORUM to finish.';
  const pausedShort = 'Paused';
  final deadMan = ios && !window.visible ? PublishSurfaceNotice('Posting paused by iOS', '$posted of $total posted, $toGo to go. Open NEFORUM to finish.') : null;
  final current = progress.current;
  final waiting = current?.stage == ProgressStage.serverProcessing;
  final polls = waiting ? current!.waitPolls : 0;
  final units = progress.permille * 1000 + math.min<int>(999, polls);

  if (lifecycle == PublishRunLifecycle.holding && !window.visible) {
    return build(
      phase: PublishSurfacePhase.paused,
      activityLabel: pausedText,
      activityShortLabel: pausedShort,
      pausedLabel: pausedText,
      pausedShortLabel: pausedShort,
      stageLabel: pausedText,
      currentNetwork: current?.name,
      postPermille: progress.permille,
      systemUnits: units,
      systemSubtitle: pausedText,
      deadMan: deadMan,
    );
  }

  final name = current?.name;
  final position = math.min(total, targets.where((t) => t.finished).length + 1);
  final justBack = window.visible && window.pausedNoticeUntil != null && now.isBefore(window.pausedNoticeUntil!);
  final leave = ios && window.visible ? 'If you leave, iOS may pause this.' : null;
  final stage = _stageLabel(current);
  if (waiting) {
    return build(
      phase: PublishSurfacePhase.waiting,
      inAppNotice: justBack ? 'iOS paused NEFORUM. Continuing.' : (current!.label?.isNotEmpty ?? false ? current.label : '$name is processing.'),
      leaveWarning: justBack ? null : leave,
      activityLabel: '$name is processing',
      activityShortLabel: '$posted/$total',
      pausedLabel: pausedText,
      pausedShortLabel: pausedShort,
      stageLabel: stage,
      currentNetwork: name,
      postPermille: progress.permille,
      systemUnits: units,
      systemSubtitle: 'Waiting for $name',
      deadMan: deadMan,
    );
  }
  return build(
    phase: PublishSurfacePhase.posting,
    inAppNotice: justBack ? 'iOS paused NEFORUM. Continuing.' : leave,
    leaveWarning: justBack ? null : leave,
    activityLabel: 'Posting $position of $total',
    activityShortLabel: '$posted/$total',
    pausedLabel: pausedText,
    pausedShortLabel: pausedShort,
    stageLabel: stage,
    currentNetwork: name,
    postPermille: progress.permille,
    systemUnits: units,
    systemSubtitle: stage ?? 'Posting $position of $total',
    deadMan: deadMan,
  );
}

String? _stageLabel(TargetProgress? t) {
  if (t == null) return null;
  final name = t.name;
  return switch (t.stage) {
    ProgressStage.renewingSignIn => 'Checking the $name sign-in',
    ProgressStage.reading => 'Reading the file for $name',
    ProgressStage.uploading => 'Sending to $name',
    ProgressStage.serverProcessing => 'Waiting for $name',
    ProgressStage.posting => 'Posting to $name',
    ProgressStage.handingOff => 'Waiting for you',
    null => null,
  };
}

PublishSurfaceNetwork _network(TargetProgress t, Set<String> outcomeUnknown) {
  final String state;
  if (outcomeUnknown.contains(t.accountId)) {
    state = 'unconfirmed';
  } else {
    state = switch (t.outcome) {
      TargetOutcome.published || TargetOutcome.handedOff => 'posted',
      TargetOutcome.awaitingUser => 'waitingForYou',
      TargetOutcome.failed => 'failed',
      TargetOutcome.cancelled => 'cancelled',
      TargetOutcome.skipped || TargetOutcome.notThisRun => 'skipped',
      null => switch (t.stage) {
          null => 'pending',
          ProgressStage.serverProcessing => 'waiting',
          ProgressStage.handingOff => 'waitingForYou',
          _ => 'working',
        },
    };
  }
  // A wait shows no number unless the network sent one.
  final silentWait = t.outcome == null && t.stage == ProgressStage.serverProcessing && t.serverPercent == null;
  return PublishSurfaceNetwork(id: t.accountId, state: state, permille: silentWait ? null : t.permille);
}
