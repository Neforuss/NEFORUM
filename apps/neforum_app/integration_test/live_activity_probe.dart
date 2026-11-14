// A test entry for CI, built with -t and never shipped: it starts the real Live Activity
// through the real channel, in the words the real reducer gives, then stops updating it.
// tool/ci_live_activity_simulator.sh takes the screenshots.
//
// The run has a failed network, so the compact island must show the count with the
// red badge beside it. Brought back to the front once, the probe starts a second run:
// two activities share the island, which shows each in its minimal presentation.

import 'package:flutter/material.dart';
import 'package:neforum_app/platform/publish_host.dart';
import 'package:neforum_app/state/publish_run_surface.dart';

import 'live_activity_probe_runs.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('Live Activity probe')))));
  final host = ChannelPublishHost();
  final first = probeFirstRun(DateTime.now());
  final started = await host.begin(
    postId: 'probe',
    title: publishSurfaceTitle(5),
    networks: const [PublishHostNetwork(id: 'a', name: 'Mastodon', bytes: 1000)],
  );
  await host.update(first.toSnapshot());
  // Fields only: no toString in a profile build.
  debugPrint('PROBE_READY begin=$started label=${first.activityLabel} count=${first.activityShortLabel} failed=${first.activityFailedLabel} paused=${first.pausedLabel}');

  // iOS starts an activity only with the app in front: the second one waits for
  // the script to bring the probe back.
  var away = false;
  var second = false;
  Future<void> beginSecond() async {
    final now = DateTime.now();
    final again = probeFirstRun(now);
    final other = probeSecondRun(now);
    // The first is fresh again, so both are live in the minimal pictures.
    await host.update(again.toSnapshot());
    final begun = await host.begin(
      postId: 'probe-b',
      title: publishSurfaceTitle(3),
      networks: const [PublishHostNetwork(id: 'b', name: 'Pixelfed', bytes: 1000)],
    );
    await host.update(other.toSnapshot());
    debugPrint('PROBE_SECOND begin=$begun label=${other.activityLabel} count=${other.activityShortLabel}');
  }

  AppLifecycleListener(onStateChange: (state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) away = true;
    if (state != AppLifecycleState.resumed || !away || second) return;
    second = true;
    beginSecond();
  });
}
