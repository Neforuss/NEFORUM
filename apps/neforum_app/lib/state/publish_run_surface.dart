import 'dart:math' as math;
import 'dart:ui' show AppLifecycleState;

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

  /// iOS said the app's time is about to end: no new post starts, and the app
  /// expects to be frozen in a moment.
  holding,

  /// iOS took the time back, or the person pressed Stop in the system's own view.
  /// The two look alike to the app, so it asks instead of guessing.
  stopped,

  /// Seen at the next launch: the process ended during the run.
  closed,

  /// Every target has its outcome.
  finished,
}

/// The lifecycle a run with no session of its own is in: a scheduler run, whose
/// only facts are its figures.
PublishRunLifecycle publishLifecycleOf(PostProgress? progress) => progress == null
    ? PublishRunLifecycle.preparing
    : progress.finished
        ? PublishRunLifecycle.finished
        : PublishRunLifecycle.running;

/// Whether the person can see NEFORUM.
@immutable
class PublishWindowState {
  const PublishWindowState({required this.visible, this.pausedNoticeUntil});

  final bool visible;

  /// Set on return when the system froze the app while it was away.
  final DateTime? pausedNoticeUntil;
}

/// Where the app's window stands on Android, beside the OS lifecycle.
enum PublishWindowPresence {
  /// The window exists, whether or not it is on screen.
  open,

  /// The OS is taking the window away.
  closing,

  /// The run goes on with no window at all (`windowClosing` from native).
  gone,
}

/// Whether the person can see the app: the window is there and the OS has it in
/// front. No report yet means starting up, which is in front.
bool publishAppVisible(AppLifecycleState? lifecycle, PublishWindowPresence window) =>
    window == PublishWindowPresence.open && (lifecycle == null || lifecycle == AppLifecycleState.resumed || lifecycle == AppLifecycleState.inactive);

/// What the reducer says a run is doing. Never a new value in a synced model:
/// this is only for surfaces on this device. Plain names: they cross the channel.
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

  /// Null when nothing about this network can be measured, and during a wait the
  /// network sends no number for.
  final int? permille;

  Map<String, Object?> toMap() => {'id': id, 'state': state, 'permille': permille};
}

/// Everything every surface says about a run: the app, Android's notification,
/// iOS's Live Activity and the notifications. All wording comes from here: native
/// code only shows it.
@immutable
class PublishSurfaceState {
  const PublishSurfaceState({
    required this.postId,
    required this.phase,
    required this.headline,
    this.detail,
    this.inAppNotice,
    this.leaveWarning,
    this.actions = const [],
    this.activityLabel,
    this.activityShortLabel,
    this.pausedLabel,
    this.pausedShortLabel,
    this.activityFailedLabel,
    this.activityPaused = false,
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

  /// Android's notification title.
  final String headline;

  /// Its second line. Null when the title says it all.
  final String? detail;

  /// The line this state shows inside the app, if it has one of its own.
  final String? inAppNotice;

  /// The warning that leaving can stop the run. Only where that is true.
  final String? leaveWarning;
  final List<PublishSurfaceAction> actions;

  /// The Live Activity's line. Null means no Live Activity should be showing.
  final String? activityLabel;

  /// The count beside the camera ("2/5": posted of all). The compact island shows
  /// it at all times, beside the error badge when a network failed.
  final String? activityShortLabel;

  /// What the Live Activity reads once it has gone stale. The system flips it
  /// with no code running, so it is sent ahead with every update.
  final String? pausedLabel;

  /// The last count, kept once stale: the pause shape says it is not moving, and
  /// the count stays true.
  final String? pausedShortLabel;

  /// Set when a network failed ("1 failed"): the island's red badge beside the
  /// count, and the words VoiceOver and the Lock Screen give for it. A stale
  /// activity keeps it, since a failure stays true.
  final String? activityFailedLabel;

  /// Held back with the app about to be frozen: the activity shows the pause shape
  /// already, before iOS's own stale flip.
  final bool activityPaused;

  /// Made from the stage and the network's name, never from a target's own label:
  /// a lock screen is public.
  final String? stageLabel;
  final String? currentNetwork;

  /// Null when no figure can be shown: getting ready, or nothing in the run can be
  /// measured. A wait never moves it.
  final int? postPermille;
  final int posted;
  final int failed;
  final int total;
  final List<PublishSurfaceNetwork> networks;

  /// For iOS's own bar on a continued task, out of 1,000,000: this post's figure
  /// plus the poll requests really made in this wait (D6). Apple ends tasks that
  /// report nothing, and the extra stays under 0.1% of the bar.
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

  /// The `update` argument of `neforum/publish_host` (D5). Android reads `headline`,
  /// `detail`, `postPermille` and `networks`; iOS reads `postId`, the activity and
  /// paused labels, `activityFailedLabel`, `activityPaused`, `stageLabel`,
  /// `currentNetwork`, `postPermille`, `systemUnits`, `systemSubtitle` and
  /// `backgrounded`. Never the post's text.
  Map<String, Object?> toSnapshot() => {
        'postId': postId,
        'phase': phase.name,
        'headline': headline,
        'detail': detail,
        'postPermille': postPermille,
        'posted': posted,
        'failed': failed,
        'total': total,
        'currentNetwork': currentNetwork,
        'stageLabel': stageLabel,
        'networks': [for (final n in networks) n.toMap()],
        'activityLabel': activityLabel,
        'activityShortLabel': activityShortLabel,
        'pausedLabel': pausedLabel,
        'pausedShortLabel': pausedShortLabel,
        'activityFailedLabel': activityFailedLabel,
        'activityPaused': activityPaused,
        'systemUnits': systemUnits,
        'systemSubtitle': systemSubtitle,
        'backgrounded': backgrounded,
      };
}

/// What a title says when a run starts. The post's own text never goes here: a
/// Lock Screen is public.
String publishSurfaceTitle(int networks) => 'Posting to $networks ${networks == 1 ? 'network' : 'networks'}';

/// Told when Android ends a run at its limit for background work.
const String kPublishLimitTitle = 'Posting stopped';
const String kPublishLimitBody = "Android's limit for background uploads was reached. Open NEFORUM and retry.";

/// Android's one notification stands for every run going on: with more than one it
/// says how many instead of one run's words.
String publishRunsHeadline(String alone, int otherRuns) => otherRuns > 0 ? 'Posting ${otherRuns + 1} posts' : alone;

/// The words for a run that has ended. [unknown]: accounts whose post may be live
/// although no answer says so. They are named, never counted as failed or posted.
String publishRunSummary(PostProgress p, {Set<String> unknown = const {}}) {
  final targets = p.targets;
  final total = p.total;
  if (total == 0) return 'Nothing was posted';
  final failed = targets.where((t) => t.outcome == TargetOutcome.failed && !unknown.contains(t.accountId)).length;
  final notConfirmed = targets.where((t) => unknown.contains(t.accountId)).length;
  final cancelled = targets.where((t) => t.outcome == TargetOutcome.cancelled && !unknown.contains(t.accountId)).length;
  final waitingForYou = targets.where((t) => t.outcome == TargetOutcome.awaitingUser).length;
  final extras = [
    if (failed > 0) '$failed failed',
    if (notConfirmed > 0) '$notConfirmed not confirmed',
    if (cancelled > 0) '$cancelled cancelled',
    if (waitingForYou > 0) '$waitingForYou waiting for you',
  ];
  if (extras.isEmpty && p.posted == total) return 'Posted to $total ${total == 1 ? 'network' : 'networks'}';
  return ['Posted to ${p.posted} of $total', ...extras].join(', ');
}

/// Pure: the same input gives the same output, so every row of the design tables
/// (ios.md section 6, android.md section 4) lives in gate tests. [outcomeUnknown]
/// holds the accounts whose post may be live although no answer says so
/// ([PublishError.outcomeUnknown]): they read as not finished, never as posted or
/// failed. [otherRuns] counts further runs in progress beside this one.
///
/// It never says the run will survive anything. A surface states what is happening,
/// and what happens next is for the OS to decide.
PublishSurfaceState reducePublishSurface(
  PostProgress? progress,
  PublishRunLifecycle lifecycle,
  PublishWindowState window,
  DateTime now, {
  PublishSurfacePlatform platform = PublishSurfacePlatform.none,
  Set<String> outcomeUnknown = const {},
  int otherRuns = 0,
}) {
  final ios = platform == PublishSurfacePlatform.ios;
  String more(String alone) => publishRunsHeadline(alone, otherRuns);
  if (lifecycle == PublishRunLifecycle.preparing || progress == null) {
    final closed = lifecycle == PublishRunLifecycle.closed;
    return PublishSurfaceState(
      postId: progress?.postId,
      phase: closed ? PublishSurfacePhase.closed : PublishSurfacePhase.preparing,
      headline: more(closed ? 'NEFORUM was closed before this finished' : 'Getting your post ready'),
      inAppNotice: closed ? 'NEFORUM was closed before this finished.' : 'Getting your post ready…',
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
  // The island's count: live, stale and held back alike, so the compact island
  // never trades it for a word or a sign.
  final count = '$posted/$total';
  final networks = [for (final t in targets) _network(t, outcomeUnknown)];
  final unconfirmedLines = [for (final t in unknown) '${t.name}: NEFORUM could not confirm this. Check ${t.name} before retrying.'];
  // Nothing measurable in the whole run: a figure would only be made up.
  final measurable = targets.any((t) => t.permille != null);

  PublishSurfaceState build({
    required PublishSurfacePhase phase,
    required String headline,
    String? detail,
    String? inAppNotice,
    String? leaveWarning,
    List<PublishSurfaceAction> actions = const [],
    String? activityLabel,
    String? activityShortLabel,
    String? pausedLabel,
    String? pausedShortLabel,
    bool activityPaused = false,
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
        headline: more(headline),
        detail: detail,
        inAppNotice: inAppNotice,
        leaveWarning: leaveWarning,
        actions: actions,
        activityLabel: activityLabel,
        activityShortLabel: activityShortLabel,
        pausedLabel: pausedLabel,
        pausedShortLabel: pausedShortLabel,
        // Only beside an activity: with none showing there is no badge to word.
        activityFailedLabel: activityLabel != null && failed > 0 ? '$failed failed' : null,
        activityPaused: activityPaused,
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
        headline: 'NEFORUM was closed before this finished',
        inAppNotice: 'NEFORUM was closed before this finished. $postedLine.',
        actions: const [PublishSurfaceAction.continueRun],
      );
    case PublishRunLifecycle.stopped:
      return build(
        phase: PublishSurfacePhase.stopped,
        headline: 'Stopped',
        detail: '$postedLine.',
        inAppNotice: 'Stopped. $postedLine.',
        actions: const [PublishSurfaceAction.continueRun, PublishSurfaceAction.cancelRest],
        postPermille: progress.permille,
        showNow: window.visible ? null : const PublishSurfaceNotice('Stopped', 'Open NEFORUM to continue.'),
      );
    case PublishRunLifecycle.finished:
      final summary = publishRunSummary(progress, unknown: outcomeUnknown);
      return build(
        phase: total > 0 && posted == total ? PublishSurfacePhase.done : PublishSurfacePhase.partlyDone,
        headline: summary,
        inAppNotice: summary,
        actions: failed > 0 ? const [PublishSurfaceAction.retry] : const [],
        activityLabel: summary,
        activityShortLabel: count,
        pausedLabel: summary,
        pausedShortLabel: count,
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
  const pausedHeadline = 'Paused';
  final deadMan = ios && !window.visible ? PublishSurfaceNotice('Posting paused by iOS', '$posted of $total posted, $toGo to go. Open NEFORUM to finish.') : null;
  final current = progress.current;
  final waiting = current?.stage == ProgressStage.serverProcessing;
  final polls = waiting ? current!.waitPolls : 0;
  final units = progress.permille * 1000 + math.min<int>(999, polls);
  final figure = measurable ? progress.permille : null;

  if (lifecycle == PublishRunLifecycle.holding && !window.visible) {
    return build(
      phase: PublishSurfacePhase.paused,
      headline: pausedHeadline,
      detail: pausedText,
      activityLabel: pausedText,
      activityShortLabel: count,
      pausedLabel: pausedText,
      pausedShortLabel: count,
      activityPaused: true,
      stageLabel: pausedText,
      currentNetwork: current?.name,
      postPermille: figure,
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
  final String headline;
  if (current == null) {
    headline = 'Posting';
  } else if (waiting) {
    headline = 'Waiting for ${current.name}';
  } else if (current.stage == ProgressStage.handingOff) {
    headline = 'Waiting for you';
  } else {
    headline = 'Posting to ${current.name}';
  }
  final detailParts = <String>[
    if (stage != null && stage != headline) stage,
    if (total > 1) 'Posted to $posted of $total',
  ];
  final detail = detailParts.isEmpty ? null : detailParts.join(' · ');
  if (waiting) {
    return build(
      phase: PublishSurfacePhase.waiting,
      headline: headline,
      detail: detail,
      inAppNotice: justBack ? 'iOS paused NEFORUM. Continuing.' : (current!.label?.isNotEmpty ?? false ? current.label : '$name is processing.'),
      leaveWarning: justBack ? null : leave,
      activityLabel: '$name is processing',
      activityShortLabel: count,
      pausedLabel: pausedText,
      pausedShortLabel: count,
      stageLabel: stage,
      currentNetwork: name,
      postPermille: figure,
      systemUnits: units,
      systemSubtitle: 'Waiting for $name',
      deadMan: deadMan,
    );
  }
  return build(
    phase: PublishSurfacePhase.posting,
    headline: headline,
    detail: detail,
    inAppNotice: justBack ? 'iOS paused NEFORUM. Continuing.' : leave,
    leaveWarning: justBack ? null : leave,
    activityLabel: 'Posting $position of $total',
    activityShortLabel: count,
    pausedLabel: pausedText,
    pausedShortLabel: count,
    stageLabel: stage,
    currentNetwork: name,
    postPermille: figure,
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
