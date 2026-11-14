// The two runs integration_test/live_activity_probe.dart shows, in the real
// reducer's words. Apart from the probe so that test/ios_live_activity_project_test.dart
// can hold tool/ci_live_activity_simulator.sh to them without the platform channel.

import 'package:neforum_app/state/publish_run_surface.dart';
import 'package:neforum_core/neforum_core.dart' show PostProgress, ProgressFamily, ProgressStage, TargetOutcome, TargetProgress;

TargetProgress _target(String name, DateTime now, {TargetOutcome? outcome, ProgressStage? stage}) => TargetProgress(
      accountId: name,
      name: name,
      permille: outcome == null ? 300 : 1000,
      family: ProgressFamily.direct,
      stage: stage,
      label: null,
      stageStartedAt: stage == null ? null : now,
      outcome: outcome,
    );

PublishSurfaceState _state(String postId, int permille, List<TargetProgress> targets, DateTime now) => reducePublishSurface(
      PostProgress(
        postId: postId,
        permille: permille,
        posted: targets.where((t) => t.outcome == TargetOutcome.published).length,
        failed: targets.where((t) => t.outcome == TargetOutcome.failed).length,
        total: targets.length,
        at: now,
        targets: targets,
      ),
      PublishRunLifecycle.running,
      const PublishWindowState(visible: true),
      now,
      platform: PublishSurfacePlatform.ios,
    );

/// Two posted, one failed, one sending, one to come: "2/5" with the badge.
PublishSurfaceState probeFirstRun(DateTime now) => _state(
      'probe',
      550,
      [
        _target('Mastodon', now, outcome: TargetOutcome.published),
        _target('Bluesky', now, outcome: TargetOutcome.published),
        _target('Threads', now, outcome: TargetOutcome.failed),
        _target('X', now, stage: ProgressStage.uploading),
        _target('LinkedIn', now),
      ],
      now,
    );

/// The second activity, for the minimal presentation: "0/3", no failure.
PublishSurfaceState probeSecondRun(DateTime now) => _state(
      'probe-b',
      200,
      [
        _target('Pixelfed', now, stage: ProgressStage.uploading),
        _target('Lemmy', now),
        _target('Tumblr', now),
      ],
      now,
    );
