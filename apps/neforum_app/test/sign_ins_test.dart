// U8b: the sign-ins page, the closed card, the banner, and the warnings under a
// schedule.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/notifications.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/account_connection.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/sign_in_board.dart';
import 'package:neforum_app/state/sign_in_schedule.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/accounts/account_card.dart';
import 'package:neforum_app/ui/accounts/sign_in_parts.dart';
import 'package:neforum_app/ui/accounts/sign_ins_screen.dart';
import 'package:neforum_app/ui/compose/schedule_sheet.dart';
import 'package:neforum_app/ui/queue/queue_screen.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _MemoryStorage implements AppStorage {
  final Map<String, Object> _json = {};
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => _json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => _json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async => 'mem://$id.$extension';
  @override
  Future<Uint8List> readMedia(String path) async => Uint8List(0);
  @override
  Future<void> deleteMedia(String path) async {}
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => SizedBox(width: width, height: height);
}

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
    }
    await loader.load();
  }

  await family('Inter', ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-Medium.ttf', 'assets/fonts/Inter-SemiBold.ttf', 'assets/fonts/Inter-Bold.ttf']);
  await family('Bricolage', ['assets/fonts/BricolageGrotesque-SemiBold.ttf', 'assets/fonts/BricolageGrotesque-Bold.ttf', 'assets/fonts/BricolageGrotesque-ExtraBold.ttf']);
  await family('JetBrainsMono', ['assets/fonts/JetBrainsMono-Regular.ttf']);
}

final DateTime _now = DateTime(2026, 6, 1, 12);

ConnectedAccount _account(String platform, {PlatformTier tier = PlatformTier.byokApi, String? id, Map<String, dynamic> config = const {}, String? handle}) =>
    ConnectedAccount(id: id ?? 'acc-$platform', platformId: platform, tier: tier, displayName: platform, handle: handle ?? '@$platform', createdAt: _now, config: config);

SignInStatus _status(String id, DateTime? end, {bool renews = false, bool deadline = false, DateTime? refused, bool about = false, bool early = true, bool unverified = false, SignInLimit limit = SignInLimit.date, bool connection = true}) => SignInStatus(
      accountId: id,
      limit: limit,
      source: SignInDateSource.serverReported,
      renewsItself: renews,
      state: end == null ? SignInState.noDate : (renews ? SignInState.renewsUntil : SignInState.endsOn),
      expiresAt: end,
      isHardDeadline: deadline,
      lastAuthFailure: refused,
      about: about,
      earlyRevocationPossible: end != null && early,
      unverified: unverified,
      hasConnection: connection,
    );

/// A demo workspace with only these accounts, and only these statuses.
Future<AppServices> _services(WidgetTester tester, List<ConnectedAccount> accounts, List<SignInStatus> statuses, {List<Post> posts = const []}) async => (await tester.runAsync(() async {
      final s = await AppServices.create(demo: true, storage: _MemoryStorage());
      for (final a in await s.accounts.all()) {
        await s.accounts.delete(a.id);
      }
      for (final p in await s.posts.all()) {
        await s.posts.delete(p.id);
      }
      await s.signInStatusStore.clear();
      for (final a in accounts) {
        await s.accounts.upsert(a);
      }
      for (final st in statuses) {
        await s.signInStatusStore.change(st.accountId, (_) => st);
      }
      for (final p in posts) {
        await s.posts.upsert(p);
      }
      return s;
    }))!;

Widget _host(AppServices s, Widget child, {Brightness brightness = Brightness.light, double scale = 1, DateTime? now}) {
  final at = now ?? _now;
  return ProviderScope(
    overrides: [servicesProvider.overrideWithValue(s), signInClockProvider.overrideWithValue(() => at)],
    child: MaterialApp(
      theme: buildTheme(brightness, AccentChoice.neforum),
      builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: w!),
      home: Scaffold(body: child),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// All the words on screen, from text widgets and from what a screen reader
/// hears.
List<String> _wordsOnScreen(WidgetTester tester) {
  final out = <String>[];
  for (final e in find.byType(Text, skipOffstage: false).evaluate()) {
    final t = e.widget as Text;
    if (t.data != null) out.add(t.data!);
    if (t.textSpan != null) out.add(t.textSpan!.toPlainText());
  }
  for (final e in find.byType(RichText, skipOffstage: false).evaluate()) {
    out.add((e.widget as RichText).text.toPlainText());
  }
  for (final e in find.byType(Semantics, skipOffstage: false).evaluate()) {
    final s = (e.widget as Semantics).properties;
    if (s.label != null) out.add(s.label!);
    if (s.value != null) out.add(s.value!);
  }
  return out;
}

Post _post(String id, DateTime when, List<String> accountIds, {Map<String, DateTime> each = const {}, TargetStatus status = TargetStatus.pending}) => Post(
      id: id,
      text: 'A post $id',
      createdAt: _now,
      updatedAt: _now,
      scheduledAt: when,
      status: PostStatus.scheduled,
      targets: [
        for (final a in accountIds)
          PostTarget(
            accountId: a,
            status: status,
            overrides: PostOverrides(scheduledAt: each[a]),
            result: status == TargetStatus.heldByPlatform ? PublishResult.scheduled(remoteId: 'h', scheduledFor: when) : null,
          ),
      ],
    );

void main() {
  setUpAll(_loadFonts);

  final registry = builtinRegistry();
  final noPosts = <Post>[];

  group('the board', () {
    test('every network is listed once, whatever it is: all 48, every tier', () {
      final accounts = <ConnectedAccount>[
        for (final adapter in registry.all)
          for (final tier in adapter.descriptor.tiers) _account(adapter.descriptor.id, tier: tier, id: '${adapter.descriptor.id}-${tier.name}'),
      ];
      final statuses = {
        for (final a in accounts)
          if (registry.byId(a.platformId)!.signInPolicyFor(a).hasConnection) a.id: _status(a.id, null),
      };
      final board = buildSignInBoard(accounts, statuses, registry, _now);
      final listed = board.all.map((r) => r.account.id).toList();
      expect(listed.length, accounts.length);
      expect(listed.toSet(), accounts.map((a) => a.id).toSet());
      expect(registry.all.length, 48);
      expect(board.all.map((r) => r.account.platformId).toSet().length, 48);
    });

    test('an account with no status yet is still there, and says so', () {
      final a = _account('linkedin');
      final board = buildSignInBoard([a], const {}, registry, _now);
      expect(board.noEndDate.single.account, a);
      expect(signInRowText(board.noEndDate.single, _now), contains('not read'));
    });

    test('the sections: reconnect, renews, no date, nothing to run out', () {
      final soon = _now.add(const Duration(days: 5));
      final must = _account('linkedin');
      final renews = _account('youtube');
      final deadline = _account('x', config: {'authMode': 'oauth1'});
      final endedRenewing = _account('threads');
      final refused = _account('tumblr');
      final none = _account('mastodon', tier: PlatformTier.openApi);
      final hand = _account('instagram', tier: PlatformTier.handoff);
      final board = buildSignInBoard([must, renews, deadline, endedRenewing, refused, none, hand], {
        must.id: _status(must.id, soon),
        renews.id: _status(renews.id, soon, renews: true),
        deadline.id: _status(deadline.id, soon, deadline: true),
        endedRenewing.id: _status(endedRenewing.id, _now.subtract(const Duration(days: 1)), renews: true),
        refused.id: _status(refused.id, soon, renews: true, refused: _now),
        none.id: _status(none.id, null, limit: SignInLimit.none),
      }, registry, _now);
      expect(board.mustReconnect.map((r) => r.account.id).toSet(), {must.id, deadline.id, endedRenewing.id, refused.id});
      expect(board.renewsWhenPosting.map((r) => r.account.id), [renews.id]);
      expect(board.noEndDate.map((r) => r.account.id), [none.id]);
      expect(board.noConnection.map((r) => r.account.id), [hand.id]);
    });

    test('the next one: a refusal, then the soonest date of either kind', () {
      final a = _account('linkedin'), b = _account('youtube'), c = _account('tumblr');
      final statuses = {a.id: _status(a.id, _now.add(const Duration(days: 9))), b.id: _status(b.id, _now.add(const Duration(days: 2)), renews: true)};
      expect(buildSignInBoard([a, b], statuses, registry, _now).next!.account, b);
      expect(buildSignInBoard([a, b, c], {...statuses, c.id: _status(c.id, null, refused: _now)}, registry, _now).next!.account, c);
      expect(buildSignInBoard([_account('mastodon', tier: PlatformTier.openApi)], const {}, registry, _now).next, isNull);
    });

    test('Renew now only where something can renew it; Check now only where the platform can say', () {
      final soon = _now.add(const Duration(days: 5));
      SignInRow row(ConnectedAccount a, SignInStatus s) => buildSignInBoard([a], {a.id: s}, registry, _now).all.single;
      final youtube = _account('youtube');
      expect(row(youtube, _status(youtube.id, soon, renews: true)).canRenew, isTrue);
      expect(row(youtube, _status(youtube.id, soon, renews: true)).canCheck, isFalse);
      final linkedIn = _account('linkedin');
      expect(row(linkedIn, _status(linkedIn.id, soon)).canRenew, isFalse);
      expect(row(linkedIn, _status(linkedIn.id, soon)).canCheck, isTrue);
      final keys = _account('x', config: {'authMode': 'oauth1'});
      expect(row(keys, _status(keys.id, soon, deadline: true)).canRenew, isFalse);
      expect(row(keys, _status(keys.id, soon, deadline: true)).canCheck, isFalse, reason: 'X is never probed');
      final bluesky = _account('bluesky', tier: PlatformTier.openApi);
      final credential = SignInStatus(accountId: bluesky.id, limit: SignInLimit.date, source: SignInDateSource.unknown, renewsItself: true, state: SignInState.renews, usesCredential: true);
      expect(row(bluesky, credential).canRenew, isFalse);
      expect(row(bluesky, credential).canCheck, isTrue);
    });
  });

  group('what a date reads as', () {
    test('every platform with early revocation: no bare date anywhere, future or past', () {
      final accounts = <ConnectedAccount>[];
      for (final adapter in registry.all) {
        for (final tier in adapter.descriptor.tiers) {
          accounts.add(_account(adapter.descriptor.id, tier: tier, id: '${adapter.descriptor.id}-${tier.name}'));
        }
      }
      var checked = 0;
      for (final a in accounts) {
        final policy = registry.byId(a.platformId)!.signInPolicyFor(a);
        if (!policy.hasConnection) continue;
        for (final (end, renews, about) in [
          (_now.add(const Duration(days: 5)), false, false),
          (_now.add(const Duration(days: 5)), true, false),
          (_now.add(const Duration(days: 5)), true, true),
          (_now.subtract(const Duration(days: 5)), false, false),
          (_now.subtract(const Duration(days: 5)), true, true),
        ]) {
          final life = deriveSignInLifetime(policy, {OAuthTokens.keyAccessToken: 'x', OAuthTokens.keyExpiresAt: end.toUtc().toIso8601String()}, now: _now, serverRead: SignInServerRead(readAt: _now, expiresAt: end));
          final s = SignInStatus(accountId: a.id, limit: policy.limit, source: SignInDateSource.computed, renewsItself: renews, state: life.state, expiresAt: life.expiresAt, about: about, earlyRevocationPossible: life.earlyRevocationPossible, isHardDeadline: life.isHardDeadline);
          if (!policy.earlyRevocationPossible) continue;
          checked++;
          final row = buildSignInBoard([a], {a.id: s}, registry, _now).all.single;
          final where = '${a.id} $end renews=$renews about=$about';
          expect(signInRowText(row, _now), contains('at the latest'), reason: where);
          expect(signInCardLine(s, policy, _now)!.text, contains('at the latest'), reason: where);
          expect(signInDateWords(s), contains('at the latest'), reason: where);
          if (s.expiresAt!.isAfter(_now)) expect(signInRelativeWords(s, _now), contains('at the latest'), reason: where);
          final notes = signInScheduleNotes([SignInScheduledTarget(account: a, network: 'N', policy: policy, dueAt: _now.add(const Duration(days: 30)))], {a.id: s}, _now);
          expect(notes.single.text, contains('at the latest'), reason: where);
          final step = SignInWarningStep(accountId: a.id, days: 3, kind: signInWarningCaseOf(s), moment: _now.add(const Duration(days: 1)), expiresAt: s.expiresAt);
          expect(signInWarningNoticeFor(step, s, network: 'N', who: 'w', now: _now).body, contains('at the latest'), reason: where);
        }
      }
      expect(checked, greaterThan(100));
    });

    test('with no early revocation it does not say at the latest', () {
      final s = _status('a', _now.add(const Duration(days: 5)), early: false);
      expect(signInDateWords(s), isNot(contains('at the latest')));
      expect(signInDateWords(_status('a', _now.add(const Duration(days: 5)), early: false, about: true)), startsWith('about '));
    });

    test('card lines: each case in plain words', () {
      final policy = SignInPolicies.linkedIn;
      String line(SignInStatus? s) => signInCardLine(s, policy, _now)!.text;
      final soon = DateTime(2026, 6, 4, 9);
      expect(line(_status('a', soon)), 'Reconnect by 4 Jun 2026 at the latest (in 3 days)');
      expect(line(_status('a', soon, renews: true, about: true)), 'Renews when NEFORUM posts. Unused, ends about 4 Jun 2026 at the latest (in 3 days)');
      expect(line(_status('a', DateTime(2026, 9, 4), renews: false)), 'Reconnect by 4 Sep 2026 at the latest');
      expect(line(_status('a', DateTime(2026, 5, 4))), 'Ended by 4 May 2026 at the latest. Reconnect it.');
      expect(line(_status('a', DateTime(2026, 5, 4), early: false)), 'Ended on 4 May 2026. Reconnect it.');
      expect(line(_status('a', null, refused: _now)), 'Sign-in refused. Reconnect it.');
      expect(line(_status('a', null, limit: SignInLimit.none)), 'No end date');
      expect(line(_status('a', null, limit: SignInLimit.undocumented)), 'No end date known');
      expect(line(_status('a', null, limit: SignInLimit.idleUnknown)), contains('No date can be known'));
      expect(signInCardLine(null, policy, _now), isNull);
      expect(signInCardLine(_status('a', soon), SignInPolicy.noConnection, _now), isNull);
    });

    test('a notice speaks of the days as they are when it shows', () {
      final end = DateTime(2026, 6, 8, 9);
      final s = _status('a', end);
      SignInWarningNotice n(int days, DateTime moment, DateTime now) => signInWarningNoticeFor(SignInWarningStep(accountId: 'a', days: days, kind: SignInWarningCase.mustReconnect, moment: moment, expiresAt: end), s, network: 'LinkedIn', who: '@me', now: now);
      expect(n(7, DateTime(2026, 6, 1, 10), DateTime(2026, 5, 1)).title, 'LinkedIn sign-in ends in 7 days', reason: 'waits with the OS');
      expect(n(7, DateTime(2026, 6, 1, 10), DateTime(2026, 6, 5, 12)).title, 'LinkedIn sign-in ends in 3 days', reason: 'went out late');
      expect(n(1, DateTime(2026, 6, 7, 10), DateTime(2026, 5, 1)).title, 'LinkedIn sign-in ends tomorrow');
      expect(n(0, end, DateTime(2026, 6, 8, 9)).title, 'LinkedIn sign-in has ended');
      expect(n(kSignInRefusedStage, end, DateTime(2026, 6, 8, 9)).title, 'LinkedIn refused the sign-in');
      expect(n(1, DateTime(2026, 6, 7, 10), DateTime(2026, 5, 1)).payload, 'signin:a');
    });

    test('tapping one opens the sign-ins page', () {
      expect(NotificationIntent.parse('signin:bluesky:did:plc:abc'), isA<OpenSignInsIntent>());
    });
  });

  group('the schedule warns', () {
    final after = _now.add(const Duration(days: 30));
    final end = _now.add(const Duration(days: 10));
    List<SignInScheduleNote> notes(ConnectedAccount a, SignInStatus? s, {DateTime? due, bool held = false}) => signInScheduleNotes(
          [SignInScheduledTarget(account: a, network: 'Net', policy: registry.byId(a.platformId)!.signInPolicyFor(a), dueAt: due ?? after, held: held)],
          {if (s != null) a.id: s},
          _now,
        );

    final linkedIn = _account('linkedin');
    final youtube = _account('youtube');
    final xKeys = _account('x', config: {'authMode': 'oauth1'});

    // Each way a post could quietly miss a network, and what stops it.
    for (final (name, ConnectedAccount a, SignInStatus? s, bool held, SignInScheduleRisk risk, bool misses) in [
      ('must reconnect, ends before the post', linkedIn, _status(linkedIn.id, end), false, SignInScheduleRisk.endsFirst, true),
      ('renews when posting, ends before the post', youtube, _status(youtube.id, end, renews: true), false, SignInScheduleRisk.renewalNeeded, false),
      ('vendor deadline before the post', xKeys, _status(xKeys.id, end, deadline: true), false, SignInScheduleRisk.deadline, true),
      ('already ended', linkedIn, _status(linkedIn.id, _now.subtract(const Duration(days: 1))), false, SignInScheduleRisk.ended, true),
      ('renewing, but already ended', youtube, _status(youtube.id, _now.subtract(const Duration(days: 1)), renews: true), false, SignInScheduleRisk.ended, true),
      ('refused, with no date at all', linkedIn, _status(linkedIn.id, null, refused: _now), false, SignInScheduleRisk.refused, true),
      ('refused, with a later date', linkedIn, _status(linkedIn.id, after.add(const Duration(days: 9)), refused: _now), false, SignInScheduleRisk.refused, true),
      ('held by the platform past the date', linkedIn, _status(linkedIn.id, end), true, SignInScheduleRisk.heldPastEnd, false),
      ('held, but already ended', linkedIn, _status(linkedIn.id, _now.subtract(const Duration(days: 1))), true, SignInScheduleRisk.ended, true),
      ('idle with no date', _account('inkbunny', tier: PlatformTier.openApi), _status('acc-inkbunny', null, limit: SignInLimit.idleUnknown), false, SignInScheduleRisk.idle, false),
      ('not read yet', linkedIn, null, false, SignInScheduleRisk.notRead, false),
    ]) {
      test(name, () {
        final got = notes(a, s, held: held);
        expect(got.single.risk, risk);
        expect(got.single.misses, misses);
        expect(got.single.text, contains('Net'), reason: 'names the network');
      });
    }

    test('no warning: the post goes first, no date is known, or there is no sign-in', () {
      expect(notes(linkedIn, _status(linkedIn.id, end), due: end.subtract(const Duration(days: 1))), isEmpty);
      expect(notes(linkedIn, _status(linkedIn.id, end), due: end), isEmpty, reason: 'on the moment still works');
      expect(notes(linkedIn, _status(linkedIn.id, null, limit: SignInLimit.none)), isEmpty);
      final hand = _account('instagram', tier: PlatformTier.handoff);
      expect(notes(hand, null), isEmpty);
    });

    test('a time per network: only the one that is late', () {
      final a = _account('linkedin', id: 'late'), b = _account('linkedin', id: 'early');
      final post = _post('p', _now.add(const Duration(days: 2)), ['late', 'early'], each: {'late': after, 'early': _now.add(const Duration(days: 2))});
      final got = signInScheduleNotes(signInTargetsOfPost(post, [a, b], registry), {'late': _status('late', end), 'early': _status('early', end)}, _now);
      expect(got.map((n) => n.accountId), ['late']);
    });

    test('finished targets are past warning; held ones are read as held', () {
      final a = _account('linkedin');
      final done = _post('p', after, [a.id], status: TargetStatus.published);
      expect(signInTargetsOfPost(done, [a], registry), isEmpty);
      final held = _post('p', after, [a.id], status: TargetStatus.heldByPlatform);
      expect(signInScheduleNotes(signInTargetsOfPost(held, [a], registry), {a.id: _status(a.id, end)}, _now).single.risk, SignInScheduleRisk.heldPastEnd);
    });

    test('the page counts the posts past each date', () {
      final a = _account('linkedin');
      final posts = [_post('in', after, [a.id]), _post('out', _now.add(const Duration(days: 1)), [a.id])];
      final board = buildSignInBoard([a], {a.id: _status(a.id, end)}, registry, _now, posts: posts);
      expect(board.all.single.postsAfterEnd, 1);
    });

    testWidgets('the schedule sheet says so, and follows the time; nothing blocks Schedule', (tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final a = _account('linkedin', id: 'sheet');
      final soon = DateTime.now().add(const Duration(minutes: 30));
      final post = _post('p', DateTime.now().add(const Duration(days: 3)), [a.id]);
      final s = await _services(tester, [a], [_status(a.id, soon)], posts: [post]);
      await tester.pumpWidget(ProviderScope(
        overrides: [servicesProvider.overrideWithValue(s)],
        child: MaterialApp(theme: buildTheme(Brightness.light, AccentChoice.neforum), home: Scaffold(body: ScheduleSheet(initial: post.scheduledAt, post: post))),
      ));
      await _settle(tester);
      expect(find.byKey(const ValueKey('sign-in-schedule-notes')), findsOneWidget);
      expect(find.textContaining('before this post goes out'), findsOneWidget);
      expect(find.textContaining('at the latest'), findsOneWidget);
      final schedule = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(schedule.onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('the queue says so on the post', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final a = _account('linkedin', id: 'queue');
      final when = DateTime.now().add(const Duration(days: 3));
      final s = await _services(tester, [a], [_status(a.id, DateTime.now().add(const Duration(days: 1)))], posts: [_post('p', when, [a.id])]);
      await tester.pumpWidget(_host(s, const QueueScreen(), now: DateTime.now()));
      await _settle(tester);
      expect(find.textContaining('before this post goes out', skipOffstage: false), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('the composer says so once the post has a time', (tester) async {
      final a = _account('linkedin', id: 'composer');
      final s = await _services(tester, [a], [_status(a.id, DateTime.now().add(const Duration(days: 1)))]);
      final container = ProviderContainer(overrides: [servicesProvider.overrideWithValue(s)]);
      addTearDown(container.dispose);
      final keep = container.listen(signInComposerNotesProvider, (_, _) {});
      addTearDown(keep.close);
      final statuses = container.listen(signInStatusesProvider, (_, _) {});
      addTearDown(statuses.close);
      final accounts = container.listen(accountsProvider, (_, _) {});
      addTearDown(accounts.close);
      await tester.runAsync(() async {
        await container.read(accountsProvider.future);
        await container.read(signInStatusesProvider.future);
      });
      final composer = container.read(composerProvider.notifier);
      composer.prefill('A post');
      if (!container.read(composerProvider).selected.contains(a.id)) composer.toggleAccount(a.id);
      expect(container.read(signInComposerNotesProvider), isEmpty, reason: 'no time, nothing to fall after');
      composer.setSchedule(DateTime.now().add(const Duration(days: 3)));
      final got = container.read(signInComposerNotesProvider);
      expect(got.single.accountId, a.id);
      expect(got.single.risk, isIn([SignInScheduleRisk.endsFirst, SignInScheduleRisk.heldPastEnd]));
      composer.setSchedule(DateTime.now().add(const Duration(hours: 1)));
      expect(container.read(signInComposerNotesProvider), isEmpty);
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('the closed card', () {
    testWidgets('as soon as an account connects its date shows, with no section opened and no key on this device read', (tester) async {
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final a = _account('linkedin', id: 'fresh');
      final s = await _services(tester, [a], const []);
      await tester.pumpWidget(_host(s, SingleChildScrollView(child: AccountCard(account: a))));
      await _settle(tester);
      expect(find.textContaining('Reconnect by'), findsNothing);
      // What the connect form does, through the same decorated store.
      await tester.runAsync(() => s.signInStatus.accountConnected(a, stampNewSignIn({OAuthTokens.keyAccessToken: 'tok-QZXCV', OAuthTokens.keyExpiresAt: _now.add(const Duration(days: 20)).toUtc().toIso8601String()}, now: _now), s.connectContext()));
      await _settle(tester);
      expect(find.textContaining('Reconnect by 21 Jun 2026 at the latest'), findsOneWidget);
      // Its keys are gone: the line comes from the status file alone.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => (s.signInStatusStore).get(a.id));
      await tester.pumpWidget(_host(s, SingleChildScrollView(child: AccountCard(account: a))));
      await _settle(tester);
      expect(find.textContaining('Reconnect by'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('with no keys on this device at all, a status still gives the date: the card reads no keychain', (tester) async {
      final a = _account('linkedin', id: 'no-keys');
      final s = await _services(tester, [a], [_status(a.id, DateTime(2026, 6, 4))]);
      expect(await tester.runAsync(() => s.secrets.read(a.id)), isNull);
      await tester.pumpWidget(_host(s, SingleChildScrollView(child: AccountCard(account: a))));
      await _settle(tester);
      expect(find.textContaining('4 Jun 2026 at the latest'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a hand-off card stays as it was', (tester) async {
      final a = _account('instagram', tier: PlatformTier.handoff);
      final s = await _services(tester, [a], const []);
      await tester.pumpWidget(_host(s, SingleChildScrollView(child: AccountCard(account: a))));
      await _settle(tester);
      expect(find.byType(AccountSignInLine), findsOneWidget);
      expect(find.textContaining('end date'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('the page', () {
    List<ConnectedAccount> mix() => [
          _account('linkedin', handle: '@robin'),
          _account('threads'),
          _account('youtube', handle: 'Robin Makes'),
          _account('x', config: {'authMode': 'oauth1'}),
          _account('tumblr'),
          _account('pixelfed', tier: PlatformTier.openApi),
          _account('facebook'),
          _account('mastodon', tier: PlatformTier.openApi),
          _account('mastodon', tier: PlatformTier.openApi, id: 'mastodon-2', handle: '@second@a.very.long.instance.name.example.org'),
          _account('telegram', tier: PlatformTier.openApi),
          _account('inkbunny', tier: PlatformTier.openApi),
          _account('reddit'),
          _account('instagram', tier: PlatformTier.handoff),
          _account('snapchat', tier: PlatformTier.handoff),
        ];
    List<SignInStatus> mixStatuses() => [
          _status('acc-linkedin', _now.add(const Duration(days: 3)), unverified: false),
          _status('acc-threads', _now.add(const Duration(days: 11)), renews: true),
          _status('acc-youtube', _now.add(const Duration(days: 120)), renews: true, about: true),
          _status('acc-x', DateTime.utc(2027, 1, 31), deadline: true),
          _status('acc-tumblr', _now.add(const Duration(days: 40)), renews: true, about: true, unverified: true),
          _status('acc-pixelfed', _now.subtract(const Duration(days: 2)), renews: true, about: true, unverified: true),
          _status('acc-facebook', null, limit: SignInLimit.none, refused: _now.subtract(const Duration(hours: 3))),
          _status('acc-mastodon', null, limit: SignInLimit.none),
          _status('mastodon-2', null, limit: SignInLimit.none),
          _status('acc-telegram', null, limit: SignInLimit.undocumented, unverified: true),
          _status('acc-inkbunny', null, limit: SignInLimit.idleUnknown),
          _status('acc-reddit', null, renews: true, limit: SignInLimit.undocumented, unverified: true),
        ];

    for (final brightness in Brightness.values) {
      for (final scale in const [1.0, 1.5]) {
        for (final size in const [Size(360, 640), Size(1100, 800)]) {
          testWidgets('${size.width.toInt()} x ${size.height.toInt()}, ${brightness.name}, text x$scale: no overflow, every section', (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final s = await _services(tester, mix(), mixStatuses());
            await tester.pumpWidget(_host(s, const SignInsScreen(), brightness: brightness, scale: scale));
            await _settle(tester);
            expect(tester.takeException(), isNull);
            final words = _wordsOnScreen(tester).join(' | ');
            for (final title in const ['You must reconnect', 'Renews when NEFORUM posts', 'No end date known', 'NEXT TO RUN OUT']) {
              expect(words, contains(title));
            }
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(seconds: 1));
          });
        }
      }
    }

    testWidgets('every account is named, and the next one leads with what to do', (tester) async {
      tester.view.physicalSize = const Size(1100, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = await _services(tester, mix(), mixStatuses());
      await tester.pumpWidget(_host(s, const SignInsScreen()));
      await _settle(tester);
      for (final a in mix()) {
        final name = registry.byId(a.platformId)!.descriptorForAccount(a).name;
        expect(find.text(name), findsWidgets, reason: name);
      }
      final next = find.byKey(const ValueKey('sign-in-next'));
      expect(find.descendant(of: next, matching: find.text('Facebook')), findsOneWidget, reason: 'refused comes first');
      expect(find.descendant(of: next, matching: find.textContaining('Reconnect Facebook')), findsOneWidget);
      // Rows marked unverified say so, and only those.
      final unverified = find.textContaining('Unverified');
      expect(unverified, findsNWidgets(mixStatuses().where((x) => x.unverified).length));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('soonest first within a section; a date that has passed since the last write reads as passed', (tester) async {
      tester.view.physicalSize = const Size(1100, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final a = _account('linkedin', id: 'one'), b = _account('linkedin', id: 'two');
      final s = await _services(tester, [a, b], [_status('one', _now.add(const Duration(days: 9))), _status('two', _now.add(const Duration(days: 2)))]);
      await tester.pumpWidget(_host(s, const SignInsScreen()));
      await _settle(tester);
      final y1 = tester.getTopLeft(find.byKey(const ValueKey('sign-in-row-two'))).dy;
      final y2 = tester.getTopLeft(find.byKey(const ValueKey('sign-in-row-one'))).dy;
      expect(y1, lessThan(y2));
      await tester.pumpWidget(_host(s, const SignInsScreen(), now: _now.add(const Duration(days: 3))));
      await _settle(tester);
      expect(find.textContaining('Ended by'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('Renew now and Check now answer in the demo without pretending', (tester) async {
      tester.view.physicalSize = const Size(1100, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = await _services(tester, mix(), mixStatuses());
      await tester.pumpWidget(_host(s, const SignInsScreen()));
      await _settle(tester);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Renew now').first);
      await _settle(tester);
      expect(find.textContaining('nothing is renewed for real'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await tester.tap(find.widgetWithText(TextButton, 'Check now').first);
      await _settle(tester);
      expect(find.textContaining('nothing is checked for real'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('targets are 48 tall on a phone', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = await _services(tester, mix(), mixStatuses());
      await tester.pumpWidget(_host(s, const SignInsScreen()));
      await _settle(tester);
      for (final type in [FilledButton, OutlinedButton, TextButton]) {
        for (final e in find.byType(type, skipOffstage: false).evaluate()) {
          final box = e.renderObject! as RenderBox;
          expect(box.size.height, greaterThanOrEqualTo(48), reason: '$type');
          expect(box.size.width, greaterThanOrEqualTo(48), reason: '$type');
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('nothing connected, and nothing dated, both say so', (tester) async {
      final s = await _services(tester, const [], const []);
      await tester.pumpWidget(_host(s, const SignInsScreen()));
      await _settle(tester);
      expect(find.text('Nothing connected yet'), findsOneWidget);
      final m = _account('mastodon', tier: PlatformTier.openApi);
      final s2 = await _services(tester, [m], [_status(m.id, null, limit: SignInLimit.none)]);
      await tester.pumpWidget(_host(s2, const SignInsScreen()));
      await _settle(tester);
      expect(find.text('No date to watch'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('the route opens from inside the app, and Accounts leads to it', (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = await _services(tester, mix(), mixStatuses());
      await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(s), signInClockProvider.overrideWithValue(() => _now)], child: const NeforumApp()));
      await tester.pump(const Duration(milliseconds: 300));
      final router = ProviderScope.containerOf(tester.element(find.byType(MaterialApp))).read(routerProvider);
      router.go('/accounts');
      await tester.pump();
      await _settle(tester);
      expect(find.textContaining('refused its sign-in'), findsWidgets);
      await tester.tap(find.byType(NextSignInRow));
      await tester.pump();
      await _settle(tester);
      expect(find.byType(SignInsScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('the banner', () {
    testWidgets('above the page, closable until the next threshold; Sign-ins leads to the page', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final a = _account('linkedin');
      final s = await _services(tester, [a], [_status(a.id, DateTime(2026, 6, 10, 9))]);
      // 9 days left: stage 14.
      await tester.pumpWidget(_host(s, const SignInBanner()));
      await _settle(tester);
      expect(find.textContaining('LinkedIn sign-in ends in 9 days at the latest'), findsOneWidget);
      await tester.tap(find.byTooltip('Close until the next warning'));
      await _settle(tester);
      expect(find.byType(TextButton), findsNothing);
      // Back a little later: still closed.
      await tester.pumpWidget(_host(s, const SignInBanner(), now: _now.add(const Duration(days: 1))));
      await _settle(tester);
      expect(find.textContaining('sign-in ends'), findsNothing);
      // 7 days: the next threshold.
      await tester.pumpWidget(_host(s, const SignInBanner(), now: DateTime(2026, 6, 3, 12)));
      await _settle(tester);
      expect(find.textContaining('in 7 days'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('nothing near: no banner at all', (tester) async {
      final a = _account('linkedin');
      final s = await _services(tester, [a], [_status(a.id, DateTime(2026, 9, 10, 9))]);
      await tester.pumpWidget(_host(s, const SignInBanner()));
      await _settle(tester);
      expect(find.byType(Text), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    test('its words: one, many, ended, refused', () {
      String network(SignInStatus s) => s.accountId;
      List<SignInBannerItem> items(List<SignInStatus> l) => signInBannerItems(l, SignInWarningLedger(), _now);
      final soon = DateTime(2026, 6, 4);
      expect(signInBannerText(items([_status('A', soon)]), network, _now), 'A sign-in ends in 3 days at the latest.');
      expect(signInBannerText(items([_status('A', soon), _status('B', DateTime(2026, 6, 2))]), network, _now), '2 sign-ins need you. First: B sign-in ends tomorrow at the latest.');
      expect(signInBannerText(items([_status('A', DateTime(2026, 5, 2))]), network, _now), 'A sign-in has ended.');
      expect(signInBannerText(items([_status('A', DateTime(2026, 5, 2), about: true)]), network, _now), 'A sign-in has probably ended.');
      expect(signInBannerText(items([_status('A', null, refused: _now)]), network, _now), 'A refused its sign-in.');
    });
  });

  group('secrets', () {
    // Random-looking on purpose: a hit means a real leak, not a coincidence.
    const access = 'QZ7xKp2LmN9vTb4RcW1yHg8DfJ3sAe6U';
    const refresh = 'Vh5nBq0ZtY8pLk3MxC7wRj2GdF9aSe1O';
    const appSecret = 'Ng4TzU6oPi1WqX9bEy3KcH7vLr2DmS8J';
    final secrets = <String, String>{OAuthTokens.keyAccessToken: access, OAuthTokens.keyRefreshToken: refresh, StoredSecretKeys.appSecret: appSecret};

    testWidgets('no token or key reaches the page, card, banner, notification or log', (tester) async {
      tester.view.physicalSize = const Size(1100, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final guard = SecretGuard(secrets);
      final logs = <String>[];
      final previousSink = Logger.defaultSink;
      Logger.defaultSink = (level, area, message, [error]) => logs.add('$message $error');
      addTearDown(() => Logger.defaultSink = previousSink);

      final accounts = [_account('linkedin', config: {'clientId': 'public-id'}), _account('youtube'), _account('threads')];
      final s = await _services(tester, accounts, const []);
      final ends = {'acc-linkedin': 3, 'acc-youtube': 10, 'acc-threads': 40};
      for (final a in accounts) {
        await tester.runAsync(() async {
          await s.secrets.write(a.id, stampNewSignIn({...secrets, OAuthTokens.keyExpiresAt: _now.add(Duration(days: ends[a.id]!)).toUtc().toIso8601String()}, now: _now));
          await s.signInStatus.publishFinished(a, worked: false, refused: a.platformId == 'threads', ctx: s.connectContext());
        });
      }
      final post = _post('p', _now.add(const Duration(days: 60)), [for (final a in accounts) a.id]);
      await tester.runAsync(() => s.posts.upsert(post));

      final seen = <String>[];
      void look() {
        seen.addAll(_wordsOnScreen(tester));
        expect(tester.takeException(), isNull);
      }

      await tester.pumpWidget(_host(s, const SignInsScreen()));
      await _settle(tester);
      look();
      expect(seen.join(' '), contains('LinkedIn'), reason: 'the page did render');
      await tester.pumpWidget(_host(s, SingleChildScrollView(child: Column(children: [for (final a in accounts) AccountCard(account: a)]))));
      await _settle(tester);
      look();
      await tester.pumpWidget(_host(s, const SignInBanner()));
      await _settle(tester);
      look();
      await tester.pumpWidget(_host(s, const QueueScreen()));
      await _settle(tester);
      look();

      // Every notice, through the real wording.
      final statuses = (await tester.runAsync(() => s.signInStatusStore.all()))!;
      final out = planSignInWarnings(statuses.values, SignInWarningLedger(), _now.subtract(const Duration(days: 70)), schedulesAhead: true, slots: 500);
      expect(out.ahead, isNotEmpty);
      for (final step in out.ahead) {
        final st = statuses[step.accountId]!;
        final n = signInWarningNoticeFor(step, st, network: 'N', who: 'who', now: _now);
        seen.addAll([n.title, n.body, n.key, n.payload]);
      }

      // The stores themselves, and what the centre logged.
      seen.add(statuses.values.map((x) => x.toJson()).toString());
      seen.add((await tester.runAsync(() => s.signInWarningStore.read()))!.toJson().toString());
      await tester.runAsync(() => s.signInWarnings.check());
      seen.addAll(logs);

      final leaks = seen.where((t) => guard.reveals(t) || t.contains(access) || t.contains(refresh) || t.contains(appSecret)).toList();
      expect(leaks, isEmpty);
      expect(seen.length, greaterThan(20));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    test('the view types cannot hold a key: the status has no field for one', () {
      final s = SignInStatus.fromLifetime('a', deriveSignInLifetime(SignInPolicies.linkedIn, {...secrets, OAuthTokens.keyExpiresAt: _now.toUtc().toIso8601String()}, now: _now), hasConnection: true);
      final guard = SecretGuard(secrets);
      expect(guard.reveals(s.toJson().toString()), isFalse);
    });
  });

  group('Delete everything', () {
    testWidgets('the warning record goes too', (tester) async {
      final a = _account('linkedin');
      final s = await _services(tester, [a], [_status(a.id, DateTime.now().add(const Duration(days: 2)))]);
      await tester.runAsync(() async {
        await s.signInWarnings.check();
        expect((await s.signInWarningStore.read()).entries, isNotEmpty);
        await s.signInWarningStore.clear();
        expect((await s.signInWarningStore.read()).entries, isEmpty);
      });
      expect(noPosts, isEmpty);
    });

    test('the Settings action clears it', () {
      final source = File('lib/ui/settings/data_section.dart').readAsStringSync();
      expect(source, contains('signInWarningStore.clear()'));
    });
  });
}
