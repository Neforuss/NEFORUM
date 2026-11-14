// Every word a publish run shows outside the app, and what it never says. The iOS
// rows are the state table of docs/design/ios-background.md (ios.md section 6); the
// Android rows are its notification's title and line (android.md section 4). One
// reducer words both.

import 'dart:ui' show AppLifecycleState;

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

// Android's rows: a run as the keeper sees it, from its figures alone.
TargetProgress _a(String id, String name, {ProgressStage? stage, String? label, int? permille = 0, TargetOutcome? outcome, int? serverPercent}) => TargetProgress(
      accountId: id,
      name: name,
      permille: permille,
      family: permille == null ? ProgressFamily.opaque : ProgressFamily.direct,
      stage: stage,
      label: label,
      stageStartedAt: stage == null ? null : _now,
      serverPercent: serverPercent,
      outcome: outcome,
    );

PostProgress _p(List<TargetProgress> targets, {int permille = 0}) => PostProgress(
      postId: 'p',
      permille: permille,
      posted: targets.where((t) => t.outcome == TargetOutcome.published || t.outcome == TargetOutcome.handedOff).length,
      failed: targets.where((t) => t.outcome == TargetOutcome.failed).length,
      total: targets.length,
      targets: targets,
      at: _now,
    );

PublishSurfaceState _android(PostProgress? p, {bool visible = true, int otherRuns = 0}) =>
    reducePublishSurface(p, publishLifecycleOf(p), PublishWindowState(visible: visible), _now, platform: PublishSurfacePlatform.android, otherRuns: otherRuns);

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
      expect(s.resultSummary, 'Posted to 5 networks');
      expect(s.activityLabel, 'Posted to 5 networks');
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
      expect(s.headline, isNot(contains('Posting')));
    });
  });

  group('the compact island', () {
    /// Two posted, one failed, one sending, one to come.
    PostProgress failedRun() => _run(targets: [
          _t('Mastodon', outcome: TargetOutcome.published),
          _t('Bluesky', outcome: TargetOutcome.published),
          _t('Threads', outcome: TargetOutcome.failed),
          _t('X', stage: ProgressStage.uploading, permille: 300),
          _t('LinkedIn'),
        ], permille: 550);

    test('a failure keeps the count and adds the badge\'s words beside it', () {
      final s = _ios(failedRun(), PublishRunLifecycle.running, _away);
      expect(s.activityShortLabel, '2/5');
      expect(s.activityFailedLabel, '1 failed');
      expect(s.activityLabel, 'Posting 4 of 5');
      expect(s.postPermille, 550, reason: 'the ring is drawn from it');
    });

    test('the count shows live, stale, held back, waiting and finished, never a word or a sign', () {
      final waiting = _run(targets: [
        _t('Mastodon', outcome: TargetOutcome.published),
        _t('Threads', outcome: TargetOutcome.failed),
        _t('Instagram', stage: ProgressStage.serverProcessing, permille: 600),
      ]);
      final finished = _run(targets: [_t('a', outcome: TargetOutcome.published), _t('b', outcome: TargetOutcome.failed)], permille: 1000);
      final cases = {
        'live': (_ios(failedRun(), PublishRunLifecycle.running, _away), '2/5'),
        'in front': (_ios(failedRun(), PublishRunLifecycle.running, _front), '2/5'),
        'held back': (_ios(failedRun(), PublishRunLifecycle.holding, _away), '2/5'),
        'waiting': (_ios(waiting, PublishRunLifecycle.running, _away), '1/3'),
        'finished': (_ios(finished, PublishRunLifecycle.finished, _away), '1/2'),
      };
      for (final MapEntry(key: name, value: (s, count)) in cases.entries) {
        expect(s.activityShortLabel, count, reason: '$name: live');
        expect(s.pausedShortLabel, count, reason: '$name: stale keeps the last count');
        expect(s.activityShortLabel, matches(RegExp(r'^\d+/\d+$')), reason: name);
        expect(s.activityFailedLabel, '1 failed', reason: '$name: a failure stays true');
      }
    });

    test('no badge without a failure, and none for a result nobody could confirm', () {
      expect(_ios(_run(), PublishRunLifecycle.running, _away).activityFailedLabel, isNull);
      final unknown = _ios(
          _run(targets: [_t('Threads', outcome: TargetOutcome.failed), _t('X', stage: ProgressStage.posting)]), PublishRunLifecycle.running, _away,
          unknown: {'id-Threads'});
      expect(unknown.activityFailedLabel, isNull);
      expect(unknown.activityShortLabel, '0/2');
    });

    test('the badge counts every failed network', () {
      final p = _run(targets: [
        _t('a', outcome: TargetOutcome.failed),
        _t('b', outcome: TargetOutcome.failed),
        _t('c', outcome: TargetOutcome.published),
        _t('d', stage: ProgressStage.posting),
      ]);
      final s = _ios(p, PublishRunLifecycle.running, _away);
      expect(s.activityFailedLabel, '2 failed');
      expect(s.activityShortLabel, '1/4');
    });

    test('no activity, no badge: stopped and closed end it', () {
      for (final l in [PublishRunLifecycle.stopped, PublishRunLifecycle.closed]) {
        final s = _ios(failedRun(), l, _away);
        expect(s.activityLabel, isNull, reason: l.name);
        expect(s.activityFailedLabel, isNull, reason: l.name);
      }
    });

    test('the pause shape before iOS\'s own stale flip only when held back with the app away', () {
      expect(_ios(failedRun(), PublishRunLifecycle.holding, _away).activityPaused, isTrue);
      expect(_ios(failedRun(), PublishRunLifecycle.holding, _front).activityPaused, isFalse, reason: 'in front it goes on posting');
      expect(_ios(failedRun(), PublishRunLifecycle.running, _away).activityPaused, isFalse);
      expect(_ios(failedRun(), PublishRunLifecycle.finished, _away).activityPaused, isFalse);
    });

    test('the badge\'s words say nothing the OS decides', () {
      final s = _ios(failedRun(), PublishRunLifecycle.running, _away);
      expect(s.activityFailedLabel, isNot(contains('—')));
      expect(s.activityFailedLabel, isNot(contains('!')));
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

  group('Android\'s notification', () {
    final rows = <(String, PostProgress?, PublishSurfacePhase, String, String?, int?)>[
      ('before the plan', null, PublishSurfacePhase.preparing, 'Getting your post ready', null, null),
      (
        'uploading, one network: the stage in NEFORUM\'s words, never the target\'s own label',
        _p([_a('a', 'Mastodon', stage: ProgressStage.uploading, label: 'Sending photo.jpg', permille: 420)], permille: 420),
        PublishSurfacePhase.posting,
        'Posting to Mastodon',
        'Sending to Mastodon',
        420,
      ),
      (
        'uploading, several networks say how many went',
        _p([
          _a('a', 'Bluesky', stage: ProgressStage.posting, label: 'Posting', permille: 1000, outcome: TargetOutcome.published),
          _a('b', 'Mastodon', stage: ProgressStage.uploading, label: 'Sending photo.jpg', permille: 100),
        ], permille: 550),
        PublishSurfacePhase.posting,
        'Posting to Mastodon',
        'Sending to Mastodon · Posted to 1 of 2',
        550,
      ),
      (
        'a server wait moves no number and says who it waits for',
        _p([_a('a', 'YouTube', stage: ProgressStage.serverProcessing, label: 'YouTube is processing the video', permille: 700)], permille: 700),
        PublishSurfacePhase.waiting,
        'Waiting for YouTube',
        null,
        700,
      ),
      (
        'a hand-off',
        _p([_a('a', 'Instagram', stage: ProgressStage.handingOff, label: 'Waiting for you', permille: 0)]),
        PublishSurfacePhase.posting,
        'Waiting for you',
        null,
        0,
      ),
      (
        'nothing measurable has no figure',
        _p([_a('a', 'Threads', stage: ProgressStage.posting, label: 'Posting', permille: null)]),
        PublishSurfacePhase.posting,
        'Posting to Threads',
        null,
        null,
      ),
      ('between two networks', _p([_a('a', 'Mastodon')]), PublishSurfacePhase.posting, 'Posting', null, 0),
      (
        'all posted',
        _p([_a('a', 'Mastodon', permille: 1000, outcome: TargetOutcome.published), _a('b', 'Bluesky', permille: 1000, outcome: TargetOutcome.published)], permille: 1000),
        PublishSurfacePhase.done,
        'Posted to 2 networks',
        null,
        1000,
      ),
      ('one posted', _p([_a('a', 'Mastodon', permille: 1000, outcome: TargetOutcome.published)], permille: 1000), PublishSurfacePhase.done, 'Posted to 1 network', null, 1000),
      (
        'partly',
        _p([_a('a', 'Mastodon', permille: 1000, outcome: TargetOutcome.published), _a('b', 'Bluesky', permille: 1000, outcome: TargetOutcome.failed)], permille: 1000),
        PublishSurfacePhase.partlyDone,
        'Posted to 1 of 2, 1 failed',
        null,
        1000,
      ),
      (
        'one waits for the person',
        _p([_a('a', 'Mastodon', permille: 1000, outcome: TargetOutcome.published), _a('b', 'TikTok', permille: 1000, outcome: TargetOutcome.awaitingUser)], permille: 1000),
        PublishSurfacePhase.partlyDone,
        'Posted to 1 of 2, 1 waiting for you',
        null,
        1000,
      ),
      (
        'cancelled',
        _p([_a('a', 'Mastodon', permille: 1000, outcome: TargetOutcome.cancelled)], permille: 1000),
        PublishSurfacePhase.partlyDone,
        'Posted to 0 of 1, 1 cancelled',
        null,
        1000,
      ),
    ];

    for (final (name, progress, phase, headline, detail, figure) in rows) {
      test(name, () {
        final s = _android(progress);
        expect(s.phase, phase);
        expect(s.headline, headline);
        expect(s.detail, detail);
        expect(s.postPermille, figure);
      });
    }

    test('network states', () {
      String state(TargetProgress t) => _android(_p([t])).networks.single.state;
      expect(state(_a('a', 'A')), 'pending');
      expect(state(_a('a', 'A', stage: ProgressStage.reading, label: 'x')), 'working');
      expect(state(_a('a', 'A', stage: ProgressStage.serverProcessing, label: 'x')), 'waiting');
      expect(state(_a('a', 'A', stage: ProgressStage.handingOff, label: 'x')), 'waitingForYou');
      expect(state(_a('a', 'A', outcome: TargetOutcome.published)), 'posted');
      expect(state(_a('a', 'A', outcome: TargetOutcome.handedOff)), 'posted');
      expect(state(_a('a', 'A', outcome: TargetOutcome.awaitingUser)), 'waitingForYou');
      expect(state(_a('a', 'A', outcome: TargetOutcome.failed)), 'failed');
      expect(state(_a('a', 'A', outcome: TargetOutcome.cancelled)), 'cancelled');
      expect(state(_a('a', 'A', outcome: TargetOutcome.skipped)), 'skipped');
    });

    test('two runs say so instead of one run\'s name', () {
      expect(_android(_p([_a('a', 'Mastodon', stage: ProgressStage.uploading, label: 'x')]), otherRuns: 1).headline, 'Posting 2 posts');
      expect(_android(null, otherRuns: 2).headline, 'Posting 3 posts');
      expect(publishRunsHeadline('Posting to Mastodon', 0), 'Posting to Mastodon');
    });

    test('whether the person can see the app', () {
      expect(publishAppVisible(AppLifecycleState.resumed, PublishWindowPresence.open), isTrue);
      expect(publishAppVisible(AppLifecycleState.inactive, PublishWindowPresence.open), isTrue);
      expect(publishAppVisible(null, PublishWindowPresence.open), isTrue, reason: 'no report yet: starting up');
      expect(publishAppVisible(AppLifecycleState.hidden, PublishWindowPresence.open), isFalse);
      expect(publishAppVisible(AppLifecycleState.paused, PublishWindowPresence.open), isFalse);
      expect(publishAppVisible(AppLifecycleState.detached, PublishWindowPresence.open), isFalse);
      expect(publishAppVisible(AppLifecycleState.resumed, PublishWindowPresence.gone), isFalse);
      expect(publishAppVisible(AppLifecycleState.resumed, PublishWindowPresence.closing), isFalse);
      expect(_android(null, visible: false).backgrounded, isTrue);
    });

    test('the lifecycle of a run with only its figures', () {
      expect(publishLifecycleOf(null), PublishRunLifecycle.preparing);
      expect(publishLifecycleOf(_p([_a('a', 'A', stage: ProgressStage.uploading)])), PublishRunLifecycle.running);
      expect(publishLifecycleOf(_p([_a('a', 'A', outcome: TargetOutcome.published)])), PublishRunLifecycle.finished);
    });

    test('no word promises what the OS decides, until the device run has shown it', () {
      final all = <String>[
        for (final (_, progress, _, _, _, _) in rows)
          for (final visible in [true, false]) ...[
            _android(progress, visible: visible).headline,
            ?_android(progress, visible: visible).detail,
          ],
        publishRunSummary(_p([_a('a', 'M', outcome: TargetOutcome.published)])),
      ];
      for (final text in all) {
        final lower = text.toLowerCase();
        for (final claim in ['keep', 'keeps', 'background', 'safe to', 'you can close', 'you can leave', 'even if', 'will finish', 'continue', 'received', 'live']) {
          expect(lower, isNot(contains(claim)), reason: text);
        }
        expect(text, isNot(contains('—')));
      }
    });
  });

  group('the snapshot', () {
    test('holds the fields of the native contract, in plain values', () {
      final m = _ios(_run(), PublishRunLifecycle.running, _away).toSnapshot();
      for (final key in [
        'postId', 'phase', 'headline', 'detail', 'postPermille', 'posted', 'failed', 'total', 'currentNetwork', 'stageLabel', 'networks', //
        'activityLabel', 'activityShortLabel', 'pausedLabel', 'pausedShortLabel', 'activityFailedLabel', 'activityPaused', //
        'systemUnits', 'systemSubtitle', 'backgrounded',
      ]) {
        expect(m.containsKey(key), isTrue, reason: key);
      }
      expect(m['postId'], 'post-1');
      expect(m['phase'], 'posting');
      expect(m['activityShortLabel'], '2/5');
      expect(m['pausedShortLabel'], '2/5');
      expect(m['activityFailedLabel'], isNull);
      expect(m['activityPaused'], isFalse);
      final held = _ios(_run(targets: [_t('A', outcome: TargetOutcome.failed), _t('B', stage: ProgressStage.posting)]), PublishRunLifecycle.holding, _away).toSnapshot();
      expect(held['activityFailedLabel'], '1 failed');
      expect(held['activityPaused'], isTrue);
      expect(held['activityShortLabel'], '0/2');
      expect(m['networks'], isA<List<Object?>>());
      expect((m['networks'] as List).first, {'id': 'id-Mastodon', 'state': 'posted', 'permille': 1000});
    });

    test('every field in plain channel types, for a mixed run', () {
      final snapshot = _android(_p([
        _a('a', 'Mastodon', stage: ProgressStage.serverProcessing, label: 'Waiting', permille: 300),
        _a('b', 'Bluesky', permille: 1000, outcome: TargetOutcome.failed),
        _a('c', 'Threads', permille: null),
      ], permille: 200))
          .toSnapshot();
      expect(snapshot['phase'], 'waiting');
      expect(snapshot['headline'], 'Waiting for Mastodon');
      expect(snapshot['detail'], 'Posted to 0 of 3');
      expect(snapshot['postPermille'], 200);
      expect(snapshot['posted'], 0);
      expect(snapshot['failed'], 1);
      expect(snapshot['total'], 3);
      expect(snapshot['currentNetwork'], 'Mastodon');
      expect(snapshot['stageLabel'], 'Waiting for Mastodon');
      expect(snapshot['networks'], [
        {'id': 'a', 'state': 'waiting', 'permille': null},
        {'id': 'b', 'state': 'failed', 'permille': 1000},
        {'id': 'c', 'state': 'pending', 'permille': null},
      ]);
    });

    test('never carries a target\'s own label: a Lock Screen is public', () {
      const secret = 'the words of the post';
      for (final platform in PublishSurfacePlatform.values) {
        final m = reducePublishSurface(_run(targets: [_t('X', stage: ProgressStage.posting, label: secret)]), PublishRunLifecycle.running, _away, _now, platform: platform)
            .toSnapshot();
        expect('$m', isNot(contains(secret)));
      }
    });

    test('what a Live Activity holds stays far under its 4 KB limit with 48 networks', () {
      final s = _ios(_run(targets: [for (var i = 0; i < 48; i++) _t('A rather long network name $i', stage: i == 0 ? ProgressStage.uploading : null)]), PublishRunLifecycle.running, _away);
      final held = [s.phase.name, s.activityLabel, s.activityShortLabel, s.pausedLabel, s.pausedShortLabel, s.activityFailedLabel, s.stageLabel, s.currentNetwork].join();
      expect(held.length, lessThan(1024));
    });

    test('the title counts networks and says nothing else', () {
      expect(publishSurfaceTitle(1), 'Posting to 1 network');
      expect(publishSurfaceTitle(5), 'Posting to 5 networks');
    });

    test('the same input gives the same output', () {
      final p = _p([_a('a', 'Mastodon', stage: ProgressStage.uploading, label: 'x', permille: 5)], permille: 5);
      expect(_android(p).toSnapshot(), _android(p).toSnapshot());
    });
  });

  group('the summary at the end', () {
    test('everything, part, nothing, and what may be live', () {
      expect(publishRunSummary(_p([_a('a', 'M', outcome: TargetOutcome.published)])), 'Posted to 1 network');
      expect(publishRunSummary(_p([])), 'Nothing was posted');
      expect(
          publishRunSummary(_p([_a('a', 'M', outcome: TargetOutcome.published), _a('b', 'T', outcome: TargetOutcome.failed)]), unknown: {'b'}), 'Posted to 1 of 2, 1 not confirmed');
    });
  });
}
