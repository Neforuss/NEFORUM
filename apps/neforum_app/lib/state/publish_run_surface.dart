import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';
import 'package:neforum_core/neforum_core.dart' show PostProgress, ProgressStage, TargetOutcome, TargetProgress;

/// Where the app's window stands, beside the OS lifecycle.
enum PublishWindowState {
  /// The window exists, whether or not it is on screen.
  open,

  /// The OS is taking the window away (`windowClosing` from native).
  closing,

  /// The run goes on with no window at all.
  gone,
}

/// What a run outside the app says it is doing. Plain names: they cross the
/// `neforum/publish_host` channel as they are.
enum PublishSurfacePhase {
  /// The post is being saved and its files made, before any network is reached.
  preparing,
  posting,

  /// The network has the file and is working on it. Nothing here can measure that.
  waiting,

  /// A hand-off that waits for the person.
  waitingForYou,
  finished,
}

/// One network's row in a run.
@immutable
class PublishSurfaceNetwork {
  const PublishSurfaceNetwork({required this.id, required this.state, this.permille});

  final String id;

  /// `pending`, `active`, `waiting`, `waitingForYou`, `posted`, `failed`, `cancelled` or `skipped`.
  final String state;

  /// Null when nothing about this network can be measured.
  final int? permille;

  Map<String, Object?> toSnapshot() => {'id': id, 'state': state, 'permille': permille};
}

/// One moment of a run, as every surface outside the app words it. It never holds
/// the post's text: lock screens are public.
@immutable
class PublishSurfaceState {
  const PublishSurfaceState({
    required this.phase,
    required this.headline,
    required this.detail,
    required this.postPermille,
    required this.posted,
    required this.failed,
    required this.total,
    required this.currentNetwork,
    required this.stageLabel,
    required this.networks,
    required this.appVisible,
  });

  final PublishSurfacePhase phase;

  /// The notification's title.
  final String headline;

  /// Its second line. Null when the title says it all.
  final String? detail;

  /// Null when no honest figure exists: the post is being prepared, or no network
  /// of the run can be measured.
  final int? postPermille;
  final int posted;
  final int failed;
  final int total;
  final String? currentNetwork;
  final String? stageLabel;
  final List<PublishSurfaceNetwork> networks;

  /// Whether the person can see NEFORUM right now.
  final bool appVisible;

  /// The `snapshot` of D5, plus the two lines of words.
  Map<String, Object?> toSnapshot() => {
        'phase': phase.name,
        'headline': headline,
        'detail': detail,
        'postPermille': postPermille,
        'posted': posted,
        'failed': failed,
        'total': total,
        'currentNetwork': currentNetwork,
        'stageLabel': stageLabel,
        'networks': [for (final n in networks) n.toSnapshot()],
      };
}

/// Told when Android ends a run at its limit for background work.
const String kPublishLimitTitle = 'Posting stopped';
const String kPublishLimitBody = "Android's limit for background uploads was reached. Open NEFORUM and retry.";

/// Pure: the same input gives the same output, so every line of it is gate-tested.
/// All wording outside the app comes from here. [progress] is null until the run's
/// plan is known. [otherRuns] counts further runs in progress beside this one.
///
/// It never says the run will survive anything. A notification states what is
/// happening, and what happens next is for the OS to decide.
PublishSurfaceState publishRunSurface(
  PostProgress? progress, {
  required AppLifecycleState? lifecycle,
  required PublishWindowState window,
  required DateTime now,
  int otherRuns = 0,
}) {
  final visible = window == PublishWindowState.open && (lifecycle == null || lifecycle == AppLifecycleState.resumed || lifecycle == AppLifecycleState.inactive);
  String more(String alone) => otherRuns > 0 ? 'Posting ${otherRuns + 1} posts' : alone;

  if (progress == null) {
    return PublishSurfaceState(
      phase: PublishSurfacePhase.preparing,
      headline: more('Getting your post ready'),
      detail: null,
      postPermille: null,
      posted: 0,
      failed: 0,
      total: 0,
      currentNetwork: null,
      stageLabel: null,
      networks: const [],
      appVisible: visible,
    );
  }

  final networks = [for (final t in progress.targets) PublishSurfaceNetwork(id: t.accountId, state: _stateOf(t), permille: t.permille)];
  // Nothing measurable in the whole run: a figure would only be made up.
  final measurable = progress.targets.any((t) => t.permille != null);
  final count = progress.total > 1 ? 'Posted to ${progress.posted} of ${progress.total}' : null;

  if (progress.finished) {
    return PublishSurfaceState(
      phase: PublishSurfacePhase.finished,
      headline: more(publishRunSummary(progress)),
      detail: null,
      postPermille: progress.permille,
      posted: progress.posted,
      failed: progress.failed,
      total: progress.total,
      currentNetwork: null,
      stageLabel: null,
      networks: networks,
      appVisible: visible,
    );
  }

  final current = progress.current;
  final label = current?.label;
  final phase = switch (current?.stage) {
    ProgressStage.serverProcessing => PublishSurfacePhase.waiting,
    ProgressStage.handingOff => PublishSurfacePhase.waitingForYou,
    _ => PublishSurfacePhase.posting,
  };
  final String headline;
  if (current == null) {
    headline = 'Posting';
  } else if (phase == PublishSurfacePhase.waiting) {
    headline = 'Waiting for ${current.name}';
  } else if (phase == PublishSurfacePhase.waitingForYou) {
    headline = 'Waiting for you';
  } else {
    headline = 'Posting to ${current.name}';
  }
  final parts = <String>[?label, ?count];
  return PublishSurfaceState(
    phase: phase,
    headline: more(headline),
    detail: parts.isEmpty ? null : parts.join(' · '),
    postPermille: measurable ? progress.permille : null,
    posted: progress.posted,
    failed: progress.failed,
    total: progress.total,
    currentNetwork: current?.name,
    stageLabel: label,
    networks: networks,
    appVisible: visible,
  );
}

/// The words for a run that has ended.
String publishRunSummary(PostProgress p) {
  final waiting = p.targets.where((t) => t.outcome == TargetOutcome.awaitingUser).length;
  final stopped = p.targets.any((t) => t.outcome == TargetOutcome.cancelled);
  final base = p.posted == p.total && p.total > 0
      ? 'Posted to ${p.total} ${p.total == 1 ? 'network' : 'networks'}'
      : 'Posted to ${p.posted} of ${p.total}';
  return [
    base,
    if (p.failed > 0) '${p.failed} failed',
    if (waiting > 0) '$waiting waiting for you',
    if (stopped) 'cancelled',
  ].join(', ');
}

String _stateOf(TargetProgress t) => switch (t.outcome) {
      TargetOutcome.published || TargetOutcome.handedOff => 'posted',
      TargetOutcome.awaitingUser => 'waitingForYou',
      TargetOutcome.failed => 'failed',
      TargetOutcome.cancelled => 'cancelled',
      TargetOutcome.skipped || TargetOutcome.notThisRun => 'skipped',
      null => switch (t.stage) {
          null => 'pending',
          ProgressStage.serverProcessing => 'waiting',
          ProgressStage.handingOff => 'waitingForYou',
          _ => 'active',
        },
    };
