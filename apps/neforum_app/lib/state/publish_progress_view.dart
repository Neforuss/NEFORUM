import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../platform/media_library.dart' show formatBytes;

/// The words and figures the progress screens show for a run. Pure: same input,
/// same output, and every number here came from [PostProgress] or the clock.

/// The headline while a run has no figure yet.
const String kGettingReady = 'Getting your post ready…';

/// The words for a run another isolate of this device is executing. It cannot
/// report from there, so there is no number.
const String kPostingInBackground = 'Posting in the background';

/// How long after the last report a time left or a speed may still show. Bytes
/// that stopped moving have no time left worth stating.
const Duration kRateStaleAfter = Duration(seconds: 20);

/// [permille] as the percentage on screen. Rounded down: the figure only ever
/// claims what the server confirmed.
String percentLabel(int permille) => '${permille ~/ 10}%';

/// What always sits beside the post's number, because a figure weighted by bytes
/// can hide that a small network just finished.
String postedLabel(PostProgress p) => 'Posted to ${p.posted} of ${p.total}';

/// Elapsed time on a wait: 0:07, 12:03, 1:02:03.
String elapsedLabel(Duration d) {
  final seconds = d.isNegative ? 0 : d.inSeconds;
  final h = seconds ~/ 3600;
  final m = seconds % 3600 ~/ 60;
  final s = (seconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// Time left, coarsely: a finer figure would claim more than the meter knows.
String timeLeftLabel(Duration d) {
  final minutes = (d.inSeconds + 59) ~/ 60;
  if (minutes <= 1) return 'about a minute left to send';
  if (minutes < 60) return 'about $minutes min left to send';
  final hours = (minutes + 30) ~/ 60;
  return hours == 1 ? 'about an hour left to send' : 'about $hours hours left to send';
}

/// One network's row while the run has not finished with it.
class TargetRowView {
  const TargetRowView({required this.line, this.percent, this.bar, this.activity = false});

  /// What is happening, with the elapsed time on a wait.
  final String line;

  /// The row's figure. Null during a wait unless the network sent a number, and
  /// null while the open upload has bytes on the way that the server has not
  /// confirmed any of.
  final String? percent;

  /// How full the row's bar is. Null when it has no bar: nothing started yet, a
  /// hand-off, or a network nothing can be measured on.
  final double? bar;

  /// Something is really going on that has no number: the small indicator beside
  /// the time, so the row does not look dead. Never for a target that is only
  /// queued or waiting for the person.
  final bool activity;
}

String _stageWords(TargetProgress t) => switch (t.stage) {
      ProgressStage.renewingSignIn => 'Checking the sign-in',
      ProgressStage.reading => 'Reading the file',
      ProgressStage.uploading => 'Uploading',
      ProgressStage.serverProcessing => 'Waiting for ${t.name}',
      ProgressStage.posting => 'Posting',
      ProgressStage.handingOff || null => 'Waiting for you',
    };

/// The row for [t] at [now]. [reportedAt] is when the figures were worked out,
/// which is how long ago bytes last moved.
TargetRowView targetRowView(TargetProgress t, DateTime now, {DateTime? reportedAt}) {
  final stage = t.stage;
  if (stage == null) return const TargetRowView(line: 'Waiting');
  if (stage == ProgressStage.handingOff) return const TargetRowView(line: 'Waiting for you');

  final permille = t.permille;
  final bar = permille == null ? null : permille / 1000;
  final label = (t.label == null || t.label!.isEmpty) ? _stageWords(t) : t.label!;

  TargetRowView waiting(String words, DateTime? since, {String? percent}) => TargetRowView(
        line: since == null ? words : '$words · ${elapsedLabel(now.difference(since))}',
        percent: percent,
        bar: bar,
        activity: true,
      );

  if (stage == ProgressStage.serverProcessing) {
    final reported = t.serverPercent;
    // Adapters usually say the network's number in their own words already.
    final words = reported == null || label.contains('%') ? label : '$label ($reported%)';
    return waiting(words, t.stageStartedAt, percent: reported == null ? null : '$reported%');
  }
  if (stage != ProgressStage.uploading) return waiting(label, t.stageStartedAt);

  // Bytes the connection took can sit in buffers for as long as the link needs
  // to carry them, so they are words and elapsed time, never a number. A number
  // shows once the server confirms part of the open upload (an answered chunk, a
  // resume offset), and it is the server's figure.
  final position = t.position;
  final total = t.slotTotal;
  final confirmed = t.confirmedPosition;
  final serverHasSome = confirmed != null && confirmed > 0;
  final figure = permille == null || !serverHasSome ? null : percentLabel(permille);
  if (t.resending) {
    return TargetRowView(line: 'Connection dropped, sending again', percent: figure, bar: bar, activity: figure == null);
  }
  if (position == null || total == null || total <= 0) return waiting(label, t.stageStartedAt);
  if (!serverHasSome) return waiting('$label · Sending ${formatBytes(total)} to ${t.name}', t.stageStartedAt);

  final fresh = reportedAt == null || now.difference(reportedAt) <= kRateStaleAfter;
  final speed = fresh ? t.bytesPerSecond : null;
  final left = fresh ? t.eta : null;
  return TargetRowView(
    line: [
      label,
      '${t.name} has ${formatBytes(confirmed < total ? confirmed : total)} of ${formatBytes(total)}',
      if (speed != null) '${formatBytes(speed)}/s',
      if (left != null) timeLeftLabel(left),
    ].join(' · '),
    percent: figure,
    bar: bar,
  );
}

/// The status a finished target shows. [saved] is the target as the run saved it,
/// which knows two things the outcome does not: a post a platform holds is
/// "published" to the run and held to the person, and a failure with a retry to
/// come goes back in the queue. The sheet says the same when the run ends.
TargetStatus statusOfOutcome(TargetOutcome outcome, {PostTarget? saved}) => switch (outcome) {
      TargetOutcome.published => saved?.status == TargetStatus.heldByPlatform ? TargetStatus.heldByPlatform : TargetStatus.published,
      TargetOutcome.handedOff => TargetStatus.handedOff,
      TargetOutcome.awaitingUser => TargetStatus.awaitingHandoff,
      TargetOutcome.failed => saved?.status == TargetStatus.pending && saved?.result?.error != null ? TargetStatus.pending : TargetStatus.failed,
      TargetOutcome.cancelled => TargetStatus.cancelled,
      TargetOutcome.skipped => TargetStatus.skipped,
      TargetOutcome.notThisRun => TargetStatus.pending,
    };

/// Whether [entry] is a run another isolate of this device is executing now: on
/// record by another owner, with a heartbeat this recent. A run that stopped, and a
/// run on another device (no entry here), do not qualify. Android's WorkManager and
/// iOS background tasks are the writers.
bool isBackgroundRun(PublishJournalEntry? entry, PublishJournal journal, DateTime now) =>
    entry != null && entry.owner != journal.owner && now.difference(entry.heartbeatAt) <= journal.heartbeatInterval * 2;
