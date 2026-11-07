// Every word a publish run shows outside the app, and what it never says.

import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/state/publish_run_surface.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

final _at = DateTime.utc(2026, 11, 7, 12);

TargetProgress _t(String id, String name, {ProgressStage? stage, String? label, int? permille = 0, TargetOutcome? outcome}) => TargetProgress(
      accountId: id,
      name: name,
      permille: permille,
      family: permille == null ? ProgressFamily.opaque : ProgressFamily.direct,
      stage: stage,
      label: label,
      stageStartedAt: stage == null ? null : _at,
      outcome: outcome,
    );

PostProgress _p(List<TargetProgress> targets, {int permille = 0}) => PostProgress(
      postId: 'p',
      permille: permille,
      posted: targets.where((t) => t.outcome == TargetOutcome.published || t.outcome == TargetOutcome.handedOff).length,
      failed: targets.where((t) => t.outcome == TargetOutcome.failed).length,
      total: targets.length,
      targets: targets,
      at: _at,
    );

PublishSurfaceState _s(PostProgress? p, {AppLifecycleState? lifecycle = AppLifecycleState.resumed, PublishWindowState window = PublishWindowState.open, int otherRuns = 0}) =>
    publishRunSurface(p, lifecycle: lifecycle, window: window, now: _at, otherRuns: otherRuns);

void main() {
  const uploading = 'Sending photo.jpg';

  final rows = <(String, PostProgress?, PublishSurfacePhase, String, String?, int?)>[
    ('before the plan', null, PublishSurfacePhase.preparing, 'Getting your post ready', null, null),
    (
      'uploading, one network',
      _p([_t('a', 'Mastodon', stage: ProgressStage.uploading, label: uploading, permille: 420)], permille: 420),
      PublishSurfacePhase.posting,
      'Posting to Mastodon',
      uploading,
      420,
    ),
    (
      'uploading, several networks say how many went',
      _p([
        _t('a', 'Bluesky', stage: ProgressStage.posting, label: 'Posting', permille: 1000, outcome: TargetOutcome.published),
        _t('b', 'Mastodon', stage: ProgressStage.uploading, label: uploading, permille: 100),
      ], permille: 550),
      PublishSurfacePhase.posting,
      'Posting to Mastodon',
      '$uploading · Posted to 1 of 2',
      550,
    ),
    (
      'a server wait moves no number and says who it waits for',
      _p([_t('a', 'YouTube', stage: ProgressStage.serverProcessing, label: 'YouTube is processing the video', permille: 700)], permille: 700),
      PublishSurfacePhase.waiting,
      'Waiting for YouTube',
      'YouTube is processing the video',
      700,
    ),
    (
      'a hand-off',
      _p([_t('a', 'Instagram', stage: ProgressStage.handingOff, label: 'Waiting for you', permille: 0)]),
      PublishSurfacePhase.waitingForYou,
      'Waiting for you',
      'Waiting for you',
      0,
    ),
    (
      'nothing measurable has no figure',
      _p([_t('a', 'Threads', stage: ProgressStage.posting, label: 'Posting', permille: null)]),
      PublishSurfacePhase.posting,
      'Posting to Threads',
      'Posting',
      null,
    ),
    ('between two networks', _p([_t('a', 'Mastodon')]), PublishSurfacePhase.posting, 'Posting', null, 0),
    (
      'all posted',
      _p([_t('a', 'Mastodon', permille: 1000, outcome: TargetOutcome.published), _t('b', 'Bluesky', permille: 1000, outcome: TargetOutcome.published)], permille: 1000),
      PublishSurfacePhase.finished,
      'Posted to 2 networks',
      null,
      1000,
    ),
    ('one posted', _p([_t('a', 'Mastodon', permille: 1000, outcome: TargetOutcome.published)], permille: 1000), PublishSurfacePhase.finished, 'Posted to 1 network', null, 1000),
    (
      'partly',
      _p([_t('a', 'Mastodon', permille: 1000, outcome: TargetOutcome.published), _t('b', 'Bluesky', permille: 1000, outcome: TargetOutcome.failed)], permille: 1000),
      PublishSurfacePhase.finished,
      'Posted to 1 of 2, 1 failed',
      null,
      1000,
    ),
    (
      'one waits for the person',
      _p([_t('a', 'Mastodon', permille: 1000, outcome: TargetOutcome.published), _t('b', 'TikTok', permille: 1000, outcome: TargetOutcome.awaitingUser)], permille: 1000),
      PublishSurfacePhase.finished,
      'Posted to 1 of 2, 1 waiting for you',
      null,
      1000,
    ),
    (
      'cancelled',
      _p([_t('a', 'Mastodon', permille: 1000, outcome: TargetOutcome.cancelled)], permille: 1000),
      PublishSurfacePhase.finished,
      'Posted to 0 of 1, cancelled',
      null,
      1000,
    ),
  ];

  for (final (name, progress, phase, headline, detail, figure) in rows) {
    test(name, () {
      final s = _s(progress);
      expect(s.phase, phase);
      expect(s.headline, headline);
      expect(s.detail, detail);
      expect(s.postPermille, figure);
    });
  }

  test('a snapshot has every field of the contract, in plain channel types', () {
    final snapshot = _s(_p([
      _t('a', 'Mastodon', stage: ProgressStage.serverProcessing, label: 'Waiting', permille: 300),
      _t('b', 'Bluesky', permille: 1000, outcome: TargetOutcome.failed),
      _t('c', 'Threads', permille: null),
    ], permille: 200))
        .toSnapshot();
    expect(snapshot['phase'], 'waiting');
    expect(snapshot['postPermille'], 200);
    expect(snapshot['posted'], 0);
    expect(snapshot['failed'], 1);
    expect(snapshot['total'], 3);
    expect(snapshot['currentNetwork'], 'Mastodon');
    expect(snapshot['stageLabel'], 'Waiting');
    expect(snapshot['networks'], [
      {'id': 'a', 'state': 'waiting', 'permille': 300},
      {'id': 'b', 'state': 'failed', 'permille': 1000},
      {'id': 'c', 'state': 'pending', 'permille': null},
    ]);
  });

  test('network states', () {
    String state(TargetProgress t) => _s(_p([t])).networks.single.state;
    expect(state(_t('a', 'A')), 'pending');
    expect(state(_t('a', 'A', stage: ProgressStage.reading, label: 'x')), 'active');
    expect(state(_t('a', 'A', stage: ProgressStage.handingOff, label: 'x')), 'waitingForYou');
    expect(state(_t('a', 'A', outcome: TargetOutcome.published)), 'posted');
    expect(state(_t('a', 'A', outcome: TargetOutcome.handedOff)), 'posted');
    expect(state(_t('a', 'A', outcome: TargetOutcome.awaitingUser)), 'waitingForYou');
    expect(state(_t('a', 'A', outcome: TargetOutcome.cancelled)), 'cancelled');
    expect(state(_t('a', 'A', outcome: TargetOutcome.skipped)), 'skipped');
  });

  test('two runs say so instead of one run\'s name', () {
    expect(_s(_p([_t('a', 'Mastodon', stage: ProgressStage.uploading, label: 'x')]), otherRuns: 1).headline, 'Posting 2 posts');
    expect(_s(null, otherRuns: 2).headline, 'Posting 3 posts');
  });

  test('whether the person can see the app', () {
    expect(_s(null).appVisible, isTrue);
    expect(_s(null, lifecycle: AppLifecycleState.inactive).appVisible, isTrue);
    expect(_s(null, lifecycle: null).appVisible, isTrue, reason: 'no report yet: starting up');
    expect(_s(null, lifecycle: AppLifecycleState.hidden).appVisible, isFalse);
    expect(_s(null, lifecycle: AppLifecycleState.paused).appVisible, isFalse);
    expect(_s(null, lifecycle: AppLifecycleState.detached).appVisible, isFalse);
    expect(_s(null, window: PublishWindowState.gone).appVisible, isFalse);
    expect(_s(null, window: PublishWindowState.closing).appVisible, isFalse);
  });

  test('the same input gives the same output', () {
    final p = _p([_t('a', 'Mastodon', stage: ProgressStage.uploading, label: 'x', permille: 5)], permille: 5);
    expect(_s(p).toSnapshot(), _s(p).toSnapshot());
  });

  test('no word promises what the OS decides, until the device run has shown it', () {
    final all = <String>[
      for (final (_, progress, _, _, _, _) in rows)
        for (final lifecycle in [AppLifecycleState.resumed, AppLifecycleState.paused, AppLifecycleState.detached]) ...[
          _s(progress, lifecycle: lifecycle, window: PublishWindowState.gone).headline,
          ?_s(progress, lifecycle: lifecycle, window: PublishWindowState.gone).detail,
        ],
      publishRunSummary(_p([_t('a', 'M', outcome: TargetOutcome.published)])),
    ];
    for (final text in all) {
      final lower = text.toLowerCase();
      for (final claim in ['keep', 'keeps', 'background', 'safe to', 'you can close', 'you can leave', 'even if', 'will finish', 'continue', 'received', 'live']) {
        expect(lower, isNot(contains(claim)), reason: text);
      }
      expect(text, isNot(contains('—')));
    }
  });
}
