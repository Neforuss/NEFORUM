// Every row of the iOS state table, as a gate test: what the app, the Live Activity
// and the notifications say in each state. The table is docs/design/ios-background.md.

import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/state/publish_run_surface.dart';
import 'package:neforum_core/neforum_core.dart' show PostProgress, ProgressFamily, ProgressStage, TargetOutcome, TargetProgress;

final _now = DateTime.utc(2026, 11, 7, 12);

const _front = PublishWindowState(visible: true);
const _away = PublishWindowState(visible: false);

TargetProgress _t(
  String name, {
  TargetOutcome? outcome,
  ProgressStage? stage,
  int? permille = 0,
  String? label,
  int waitPolls = 0,
  int? serverPercent,
}) =>
    TargetProgress(
      accountId: 'id-$name',
      name: name,
      permille: outcome != null ? 1000 : permille,
      family: ProgressFamily.direct,
      stage: stage,
      label: label,
      stageStartedAt: stage == null ? null : _now,
      waitPolls: waitPolls,
      serverPercent: serverPercent,
      outcome: outcome,
    );

/// Five networks: two posted, one posting right now, two to come.
PostProgress _run({List<TargetProgress>? targets, int permille = 450}) {
  final list = targets ??
      [
        _t('Mastodon', outcome: TargetOutcome.published),
        _t('Bluesky', outcome: TargetOutcome.published),
        _t('Threads', stage: ProgressStage.uploading, permille: 300),
        _t('X'),
        _t('LinkedIn'),
      ];
  return PostProgress(
    postId: 'post-1',
    permille: permille,
    posted: list.where((t) => t.outcome == TargetOutcome.published || t.outcome == TargetOutcome.handedOff).length,
    failed: list.where((t) => t.outcome == TargetOutcome.failed).length,
    total: list.length,
    targets: list,
    at: _now,
  );
}

PublishSurfaceState _ios(PostProgress? p, PublishRunLifecycle l, PublishWindowState w, {Set<String> unknown = const {}}) =>
    reducePublishSurface(p, l, w, _now, platform: PublishSurfacePlatform.ios, outcomeUnknown: unknown);

void main() {
  group('the table in ios.md section 6', () {
    test('Preparing: words in the app, nothing outside it', () {
      final s = _ios(null, PublishRunLifecycle.preparing, _front);
      expect(s.phase, PublishSurfacePhase.preparing);
      expect(s.inAppNotice, 'Getting your post ready…');
      expect(s.activityLabel, isNull);
      expect(s.deadMan, isNull);
      expect(s.sheetLine, isNull, reason: 'the sheet has its own words for getting ready');
    });

    test('Posting, app open: warns that leaving can pause it, no notification', () {
      final s = _ios(_run(), PublishRunLifecycle.running, _front);
      expect(s.phase, PublishSurfacePhase.posting);
      expect(s.inAppNotice, 'If you leave, iOS may pause this.');
      expect(s.activityLabel, 'Posting 3 of 5');
      expect(s.currentNetwork, 'Threads');
      expect(s.deadMan, isNull);
    });

    test('Left, time granted: the same words, and the notification is armed, not shown', () {
      final s = _ios(_run(), PublishRunLifecycle.running, _away);
      expect(s.phase, PublishSurfacePhase.posting);
      expect(s.activityLabel, 'Posting 3 of 5');
      expect(s.deadMan, isNotNull);
      expect(s.showNow, isNull);
      expect(s.backgrounded, isTrue);
    });

    test('Waiting on a network: the network\'s words, no invented figure', () {
      final p = _run(targets: [
        _t('Mastodon', outcome: TargetOutcome.published),
        _t('Instagram', stage: ProgressStage.serverProcessing, permille: 600, label: 'Instagram is processing the video.'),
      ]);
      final s = _ios(p, PublishRunLifecycle.running, _away);
      expect(s.phase, PublishSurfacePhase.waiting);
      expect(s.inAppNotice, 'Instagram is processing the video.');
      expect(s.activityLabel, 'Instagram is processing');
      expect(s.systemSubtitle, 'Waiting for Instagram');
      expect(s.deadMan, isNotNull);
      expect(s.networks.last.permille, isNull, reason: 'a wait shows no number unless the network sent one');
      final reported = _ios(_run(targets: [_t('X', stage: ProgressStage.serverProcessing, permille: 600, serverPercent: 40)]), PublishRunLifecycle.running, _away);
      expect(reported.networks.single.permille, 600);
    });

    test('Paused by iOS: all three surfaces say so, in the table\'s words', () {
      final s = _ios(_run(), PublishRunLifecycle.running, _away);
      expect(s.pausedLabel, 'Paused by iOS. 2 of 5 posted. Open NEFORUM to finish.');
      expect(s.deadMan!.text, 'Posting paused by iOS. 2 of 5 posted, 3 to go. Open NEFORUM to finish.');
      final holding = _ios(_run(), PublishRunLifecycle.holding, _away);
      expect(holding.phase, PublishSurfacePhase.paused);
      expect(holding.activityLabel, 'Paused by iOS. 2 of 5 posted. Open NEFORUM to finish.');
      expect(holding.deadMan, isNotNull);
      final back = _ios(_run(), PublishRunLifecycle.running, PublishWindowState(visible: true, pausedNoticeUntil: _now.add(const Duration(seconds: 5))));
      expect(back.inAppNotice, 'iOS paused NEFORUM. Continuing.');
      expect(back.sheetLine, 'iOS paused NEFORUM. Continuing.');
    });

    test('Back in the app: "Posting" again, the notification gone, the notice over in time', () {
      final after = _ios(_run(), PublishRunLifecycle.running, PublishWindowState(visible: true, pausedNoticeUntil: _now));
      expect(after.activityLabel, 'Posting 3 of 5');
      expect(after.deadMan, isNull);
      expect(after.inAppNotice, 'If you leave, iOS may pause this.');
    });

    test('Stopped: asks instead of guessing, and iOS\'s own view is gone', () {
      final s = _ios(_run(), PublishRunLifecycle.stopped, _away);
      expect(s.phase, PublishSurfacePhase.stopped);
      expect(s.inAppNotice, 'Stopped. 2 of 5 posted.');
      expect(s.actions, [PublishSurfaceAction.continueRun, PublishSurfaceAction.cancelRest]);
      expect(s.activityLabel, isNull);
      expect(s.deadMan, isNull);
      expect(s.showNow!.text, 'Stopped. Open NEFORUM to continue.');
      expect(_ios(_run(), PublishRunLifecycle.stopped, _front).showNow, isNull, reason: 'the sheet says it');
    });

    test('Closed: names neither iOS nor the person, and Continue is a tap', () {
      final s = _ios(_run(), PublishRunLifecycle.closed, _front);
      expect(s.phase, PublishSurfacePhase.closed);
      expect(s.inAppNotice, 'NEFORUM was closed before this finished. 2 of 5 posted.');
      expect(s.actions, [PublishSurfaceAction.continueRun]);
      expect(s.activityLabel, isNull, reason: 'ended at the next launch');
      expect(s.deadMan, isNull, reason: 'it fired already');
    });

    test('Unknown result: named, counted as not finished, never retried by a button', () {
      final p = _run(targets: [
        _t('Mastodon', outcome: TargetOutcome.published),
        _t('Threads', outcome: TargetOutcome.failed),
      ]);
      final s = _ios(p, PublishRunLifecycle.finished, _front, unknown: {'id-Threads'});
      expect(s.unconfirmedLines, ['Threads: NEFORUM could not confirm this. Check Threads before retrying.']);
      expect(s.failed, 0);
      expect(s.posted, 1);
      expect(s.resultSummary, 'Posted to 1 of 2, 1 not confirmed');
      expect(s.actions, isEmpty);
      expect(s.networks.last.state, 'unconfirmed');
      // Mid-run it is still to go, not done.
      final going = _ios(
          _run(targets: [_t('Threads', outcome: TargetOutcome.failed), _t('X', stage: ProgressStage.posting)]), PublishRunLifecycle.running, _away,
          unknown: {'id-Threads'});
      expect(going.deadMan!.body, startsWith('0 of 2 posted, 2 to go'));
    });

    test('Done', () {
      final p = _run(targets: [for (final n in ['a', 'b', 'c', 'd', 'e']) _t(n, outcome: TargetOutcome.published)], permille: 1000);
      final s = _ios(p, PublishRunLifecycle.finished, _away);
      expect(s.phase, PublishSurfacePhase.done);
      expect(s.resultSummary, 'Posted to 5 of 5');
      expect(s.activityLabel, 'Posted to 5 of 5');
      expect(s.pausedLabel, s.activityLabel, reason: 'a finished run has nothing to go stale');
      expect(s.deadMan, isNull);
    });

    test('Partly done: with Retry', () {
      final p = _run(targets: [
        for (final n in ['a', 'b', 'c']) _t(n, outcome: TargetOutcome.published),
        for (final n in ['d', 'e']) _t(n, outcome: TargetOutcome.failed),
      ], permille: 1000);
      final s = _ios(p, PublishRunLifecycle.finished, _front);
      expect(s.phase, PublishSurfacePhase.partlyDone);
      expect(s.resultSummary, 'Posted to 3 of 5, 2 failed');
      expect(s.actions, [PublishSurfaceAction.retry]);
    });
  });

  group('what a stale activity can say', () {
    test('its paused words never say Posting', () {
      for (final l in [PublishRunLifecycle.running, PublishRunLifecycle.holding]) {
        for (final w in [_front, _away]) {
          final s = _ios(_run(), l, w);
          expect(s.pausedLabel, isNot(contains('Posting')));
          expect(s.pausedShortLabel, isNot(contains('Posting')));
        }
      }
    });

    test('once held back, the activity itself says Paused, not Posting', () {
      final s = _ios(_run(), PublishRunLifecycle.holding, _away);
      expect(s.activityLabel, isNot(contains('Posting')));
      expect(s.stageLabel, isNot(contains('Posting')));
    });
  });

  group('iOS\'s own bar', () {
    test('this post\'s figure plus the polls really made, under 0.1%', () {
      TargetProgress wait(int polls) => _t('Threads', stage: ProgressStage.serverProcessing, waitPolls: polls);
      PublishSurfaceState at(int polls) => _ios(_run(targets: [wait(polls)], permille: 420), PublishRunLifecycle.running, _away);
      expect(at(0).systemUnits, 420000);
      expect(at(7).systemUnits, 420007);
      expect(at(5000).systemUnits, 420999, reason: 'never past the next permille');
    });

    test('NEFORUM\'s own number does not move during a wait', () {
      final a = _ios(_run(targets: [_t('X', stage: ProgressStage.serverProcessing, waitPolls: 1)], permille: 420), PublishRunLifecycle.running, _away);
      final b = _ios(_run(targets: [_t('X', stage: ProgressStage.serverProcessing, waitPolls: 90)], permille: 420), PublishRunLifecycle.running, _away);
      expect(a.postPermille, b.postPermille);
      expect(a.activityLabel, b.activityLabel);
      expect(b.systemUnits! - a.systemUnits!, 89);
    });

    test('outside a wait there are no poll units', () {
      expect(_ios(_run(), PublishRunLifecycle.running, _front).systemUnits, 450000);
    });
  });

  group('other platforms', () {
    test('Android is never told that iOS may pause it', () {
      final s = reducePublishSurface(_run(), PublishRunLifecycle.running, _front, _now, platform: PublishSurfacePlatform.android);
      expect(s.leaveWarning, isNull);
      expect(s.inAppNotice, isNull);
      expect(s.activityLabel, 'Posting 3 of 5');
      expect(s.deadMan, isNull);
      expect(reducePublishSurface(_run(), PublishRunLifecycle.running, _away, _now, platform: PublishSurfacePlatform.android).deadMan, isNull);
    });
  });

  group('the snapshot', () {
    test('holds the fields of the native contract, in plain values', () {
      final m = _ios(_run(), PublishRunLifecycle.running, _away).toSnapshot();
      for (final key in ['phase', 'postPermille', 'posted', 'failed', 'total', 'currentNetwork', 'stageLabel', 'networks']) {
        expect(m.containsKey(key), isTrue, reason: key);
      }
      expect(m['phase'], 'posting');
      expect(m['networks'], isA<List<Object?>>());
      expect((m['networks'] as List).first, {'id': 'id-Mastodon', 'state': 'posted', 'permille': 1000});
    });

    test('never carries a target\'s own label: a Lock Screen is public', () {
      const secret = 'the words of the post';
      final m = _ios(_run(targets: [_t('X', stage: ProgressStage.posting, label: secret)]), PublishRunLifecycle.running, _away).toSnapshot();
      expect('$m', isNot(contains(secret)));
    });

    test('what a Live Activity holds stays far under its 4 KB limit with 48 networks', () {
      final s = _ios(_run(targets: [for (var i = 0; i < 48; i++) _t('A rather long network name $i', stage: i == 0 ? ProgressStage.uploading : null)]), PublishRunLifecycle.running, _away);
      final held = [s.phase.name, s.activityLabel, s.activityShortLabel, s.pausedLabel, s.pausedShortLabel, s.stageLabel, s.currentNetwork].join();
      expect(held.length, lessThan(1024));
    });

    test('the title counts networks and says nothing else', () {
      expect(publishSurfaceTitle(1), 'Posting to 1 network');
      expect(publishSurfaceTitle(5), 'Posting to 5 networks');
    });
  });
}
