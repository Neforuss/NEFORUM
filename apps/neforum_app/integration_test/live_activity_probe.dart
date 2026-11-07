// A test entry for CI, built with -t and never shipped: it starts the real Live Activity
// through the real channel, in the words the real reducer gives, then stops updating it.
// tool/ci_live_activity_simulator.sh takes the screenshots.

import 'package:flutter/material.dart';
import 'package:neforum_app/platform/publish_host.dart';
import 'package:neforum_app/state/publish_run_surface.dart';
import 'package:neforum_core/neforum_core.dart' show PostProgress, ProgressFamily, ProgressStage, TargetOutcome, TargetProgress;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('Live Activity probe')))));
  final host = ChannelPublishHost();
  final now = DateTime.now();
  final started = await host.begin(
    postId: 'probe',
    title: publishSurfaceTitle(5),
    networks: const [PublishHostNetwork(id: 'a', name: 'Mastodon', bytes: 1000)],
  );
  TargetProgress target(String name, {TargetOutcome? outcome, ProgressStage? stage}) => TargetProgress(
        accountId: name,
        name: name,
        permille: outcome == null ? 300 : 1000,
        family: ProgressFamily.direct,
        stage: stage,
        label: null,
        stageStartedAt: stage == null ? null : now,
        outcome: outcome,
      );
  final state = reducePublishSurface(
    PostProgress(
      postId: 'probe',
      permille: 450,
      posted: 2,
      failed: 0,
      total: 5,
      at: now,
      targets: [
        target('Mastodon', outcome: TargetOutcome.published),
        target('Bluesky', outcome: TargetOutcome.published),
        target('Threads', stage: ProgressStage.uploading),
        target('X'),
        target('LinkedIn'),
      ],
    ),
    PublishRunLifecycle.running,
    const PublishWindowState(visible: true),
    now,
    platform: PublishSurfacePlatform.ios,
  );
  await host.update(state.toSnapshot());
  // Fields only: no toString in a profile build.
  debugPrint('PROBE_READY begin=$started label=${state.activityLabel} paused=${state.pausedLabel}');
}
