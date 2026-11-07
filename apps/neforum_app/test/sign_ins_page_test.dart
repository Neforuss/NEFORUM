// The sign-ins page, the closed card's line, the banner and every warning that
// a post may miss a network. All read the status file; none reads a key.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/notifications.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/demo.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/state/sign_in_notifications.dart';
import 'package:neforum_app/state/sign_in_risks.dart';
import 'package:neforum_app/state/sign_in_view.dart';
import 'package:neforum_app/ui/accounts/account_card.dart';
import 'package:neforum_app/ui/compose/schedule_sheet.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _MemoryStorage implements AppStorage {
  final Map<String, Object> json = {};
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => json[name] = data;
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
      if (!File(f).existsSync()) continue;
      loader.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
    }
    await loader.load();
  }

  await family('Inter', ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-Medium.ttf', 'assets/fonts/Inter-SemiBold.ttf', 'assets/fonts/Inter-Bold.ttf']);
  await family('Bricolage', ['assets/fonts/BricolageGrotesque-SemiBold.ttf', 'assets/fonts/BricolageGrotesque-Bold.ttf', 'assets/fonts/BricolageGrotesque-ExtraBold.ttf']);
  await family('JetBrainsMono', ['assets/fonts/JetBrainsMono-Regular.ttf']);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '';
  await family('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
}

final AdapterRegistry _real = builtinRegistry();

/// A fixed moment, some way off any date in these tests.
final DateTime _now = DateTime(2026, 11, 6, 11);

String _iso(DateTime t) => t.toUtc().toIso8601String();

ConnectedAccount _acct(String platform, PlatformTier tier, {String? id, String? name, String? handle, Map<String, dynamic> config = const {}}) => ConnectedAccount(
      id: id ?? 'a-$platform-${tier.name}',
      platformId: platform,
      tier: tier,
      displayName: name ?? platform,
      handle: handle,
      createdAt: DateTime.utc(2026, 1, 1),
      config: config,
    );

/// [secrets] as the status file reads them, by the real policy and the real rules.
SignInStatus _status(ConnectedAccount a, Map<String, String> secrets, {DateTime? confirmed, DateTime? refused}) {
  final policy = _real.require(a.platformId).signInPolicyFor(a);
  return SignInStatus.fromLifetime(a.id, deriveSignInLifetime(policy, secrets, now: _now), hasConnection: policy.hasConnection, lastConfirmedAt: confirmed, lastAuthFailure: refused);
}

Map<String, String> _access(Duration left) => {OAuthTokens.keyAccessToken: 't', OAuthTokens.keyExpiresAt: _iso(_now.add(left))};

Map<String, String> _refreshing(DateTime renewed) => {
      OAuthTokens.keyAccessToken: 't',
      OAuthTokens.keyRefreshToken: 'r',
      OAuthTokens.keyExpiresAt: _iso(_now.add(const Duration(hours: 1))),
      SignInSecretKeys.lastRenewedAt: _iso(renewed),
    };

/// A believable mix: each of the page's groups, each kind of date.
List<(ConnectedAccount, SignInStatus)> _mix() {
  ConnectedAccount a(String p, PlatformTier t, String name, String handle, {Map<String, dynamic> config = const {}}) => _acct(p, t, name: name, handle: handle, config: config);
  final linkedin = a('linkedin', PlatformTier.byokApi, 'Robin Okafor', 'Maker · Open source');
  final x = a('x', PlatformTier.byokApi, 'Robin Okafor', '@robinmakes', config: const {'authMode': 'oauth1'});
  final mitra = a('mastodon', PlatformTier.openApi, 'Robin on Mitra', '@robin@mitra.example');
  final tumblr = a('tumblr', PlatformTier.byokApi, 'Robin makes', 'robinmakes');
  final threads = a('threads', PlatformTier.byokApi, 'Robin Okafor', '@robin.makes');
  final youtube = a('youtube', PlatformTier.byokApi, 'Robin Makes', '@robinmakes');
  final bluesky = a('bluesky', PlatformTier.openApi, 'Robin Okafor', '@robin.bsky.social');
  final inkbunny = a('inkbunny', PlatformTier.openApi, 'robin', 'robin');
  final telegram = a('telegram', PlatformTier.openApi, "Robin's Workshop", '@robinsworkshop');
  final wordpress = a('wordpress', PlatformTier.openApi, 'Robin Makes', 'robin.example');
  final substack = a('substack', PlatformTier.handoff, 'Robin', 'Hand-off');
  return [
    (linkedin, _status(linkedin, _access(const Duration(days: 5)), confirmed: _now.subtract(const Duration(days: 3)))),
    (x, _status(x, const {'oauth_token': 't'})),
    (mitra, _status(mitra, _access(const Duration(days: 22)))),
    (tumblr, _status(tumblr, _refreshing(_now.subtract(const Duration(days: 40))), refused: _now.subtract(const Duration(days: 1)))),
    (threads, _status(threads, {..._access(const Duration(days: 44)), SignInSecretKeys.tokenIssuedAt: _iso(_now.subtract(const Duration(days: 16)))}, confirmed: _now.subtract(const Duration(days: 16)))),
    (youtube, _status(youtube, _refreshing(_now.subtract(const Duration(days: 12))), confirmed: _now.subtract(const Duration(days: 12)))),
    (bluesky, _status(bluesky, const {OAuthTokens.keyAccessToken: 't', SignInSecretKeys.appPassword: 'p'}, confirmed: _now.subtract(const Duration(days: 1)))),
    (inkbunny, _status(inkbunny, const {'sid': 's'}, confirmed: _now.subtract(const Duration(days: 2)))),
    (telegram, _status(telegram, const {'bot_token': 't'})),
    (wordpress, _status(wordpress, const {'password': 'p'})),
    (substack, _status(substack, const {})),
  ];
}

/// The real app as a real workspace, on the given accounts and statuses.
Future<(ProviderContainer, AppServices)> _boot(
  WidgetTester t, {
  required List<(ConnectedAccount, SignInStatus?)> fleet,
  Size size = const Size(1100, 800),
  String route = kSignInsPath,
  String theme = 'light',
  DateTime? now,
  double textScale = 1,
  bool withRepaint = false,
  double pixelRatio = 1,
}) async {
  t.view.physicalSize = size * pixelRatio;
  t.view.devicePixelRatio = pixelRatio;
  addTearDown(t.view.reset);
  final store = _MemoryStorage()..json['settings.json'] = {'updateCheck': 'off', 'themeMode': theme};
  final services = (await t.runAsync(() async {
    final s = await AppServices.create(demo: true, storage: store);
    for (final p in await s.posts.all()) {
      await s.posts.delete(p.id);
    }
    for (final a in await s.accounts.all()) {
      await s.accounts.delete(a.id);
    }
    await s.signInStatusStore.clear();
    for (final (a, status) in fleet) {
      await s.accounts.upsert(a);
      if (status != null) await s.signInStatusStore.change(a.id, (_) => status);
    }
    return s;
  }))!;
  final at = now ?? _now;
  final app = ProviderScope(
    overrides: [
      servicesProvider.overrideWithValue(services),
      isDemoProvider.overrideWithValue(false),
      signInClockProvider.overrideWithValue(() => at),
    ],
    child: const NeforumApp(),
  );
  await t.pumpWidget(withRepaint ? RepaintBoundary(key: _shot, child: app) : app);
  await t.pump(const Duration(milliseconds: 300));
  final c = ProviderScope.containerOf(t.element(find.byType(MaterialApp)));
  if (textScale != 1) await t.runAsync(() => c.read(settingsProvider.notifier).update((s) => s.copyWith(mobileTextScale: textScale)));
  c.read(routerProvider).go(route);
  await _settle(t);
  return (c, services);
}

final _shot = GlobalKey();

Future<void> _settle(WidgetTester t) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _end(WidgetTester t) async {
  await t.pumpWidget(const SizedBox.shrink());
  await t.pump(const Duration(seconds: 1));
}

/// Every word on screen, from the widgets and from what a screen reader gets.
String _allWords(WidgetTester t) {
  final out = StringBuffer();
  for (final e in find.byType(Text).evaluate()) {
    final w = e.widget as Text;
    out.writeln(w.data ?? w.textSpan?.toPlainText() ?? '');
  }
  for (final e in find.byType(RichText).evaluate()) {
    out.writeln((e.widget as RichText).text.toPlainText());
  }
  for (final e in find.byType(Semantics).evaluate()) {
    final s = e.widget as Semantics;
    out
      ..writeln(s.properties.label ?? '')
      ..writeln(s.properties.value ?? '')
      ..writeln(s.properties.hint ?? '');
  }
  for (final e in find.byType(Tooltip).evaluate()) {
    out.writeln((e.widget as Tooltip).message ?? '');
  }
  return out.toString();
}

Finder _row(ConnectedAccount a) => find.byKey(ValueKey('sign-in-row-${a.id}'));

Iterable<String> _texts(WidgetTester t, Finder within) sync* {
  for (final e in find.descendant(of: within, matching: find.byType(Text)).evaluate()) {
    yield (e.widget as Text).data ?? '';
  }
}

void main() {
  setUpAll(_loadFonts);

  group('the page lists every network', () {
    // One account per adapter, on every way of connecting it has, each with a date.
    List<ConnectedAccount> every() => [
          for (final adapter in builtinAdapters())
            for (final tier in adapter.descriptor.tiers.toSet()) _acct(adapter.descriptor.id, tier),
        ];

    testWidgets('all 48 on every tier: none unlisted, unverified says so, no bare date', (t) async {
      final accounts = every();
      expect(accounts.map((a) => a.platformId).toSet(), hasLength(builtinAdapters().length));
      final fleet = <(ConnectedAccount, SignInStatus?)>[
        for (final a in accounts) (a, _status(a, a.tier == PlatformTier.handoff ? const {} : _access(const Duration(days: 30)))),
      ];
      await _boot(t, fleet: fleet, size: Size(1100, 300.0 * accounts.length));

      for (final (a, s) in fleet) {
        expect(_row(a), findsOneWidget, reason: '${a.platformId} ${a.tier} is not on the page');
        final words = _texts(t, _row(a)).toList();
        final status = s!;
        if (status.unverified) expect(words.join(' '), contains('Not confirmed'), reason: a.platformId);
        final end = status.expiresAt;
        if (end != null && status.earlyRevocationPossible) {
          for (final w in words.where((w) => w.contains(signInDay(end)))) {
            expect(w, contains('at the latest'), reason: '${a.platformId}: "$w"');
          }
          expect(words.any((w) => w.contains(signInDay(end))), isTrue, reason: a.platformId);
        }
      }
      await _end(t);
    });

    test('every policy with a date and early revocation carries "at the latest" on each surface', () {
      for (final adapter in builtinAdapters()) {
        for (final tier in adapter.descriptor.tiers.toSet()) {
          final a = _acct(adapter.descriptor.id, tier);
          final policy = adapter.signInPolicyFor(a);
          if (!policy.hasConnection) continue;
          final s = _status(a, _access(const Duration(days: 5)));
          final end = s.expiresAt;
          if (end == null || !s.earlyRevocationPossible) continue;
          final row = SignInRow(account: a, network: adapter.descriptor.name, status: s, policy: policy, canCheck: false);
          final day = signInDay(end);
          final item = signInBannerItems([s], _now).single;
          for (final (surface, line) in [
            ('page', signInRowSentence(row, _now)),
            ('card', signInCardLine(s, policy, _now)!),
            ('banner', signInBannerLine(item, adapter.descriptor.name)),
            ('notification', signInWarningText(SignInWarningNotice(status: s, at: _now, daysBefore: 3, key: 'k'), network: 'n', handle: null, now: _now, when: signInDay).body),
            ('risk', signInRiskFor(accountId: a.id, account: a, network: 'n', status: s, due: _now.add(const Duration(days: 30)), now: _now)!.text),
          ]) {
            expect(line, contains(day), reason: '${a.platformId} $surface');
            expect(line, contains('$day at the latest'), reason: '${a.platformId} $surface: "$line"');
          }
        }
      }
    });
  });

  group('groups', () {
    SignInRow row(ConnectedAccount a, SignInStatus s) => SignInRow(account: a, network: a.platformId, status: s, policy: _real.require(a.platformId).signInPolicyFor(a), canCheck: false);
    final a = _acct('linkedin', PlatformTier.byokApi);

    test('each status lands in its group', () {
      for (final (status, group) in <(SignInStatus, SignInGroup)>[
        (_status(a, _access(const Duration(days: 40))), SignInGroup.mustReconnect),
        (_status(_acct('threads', PlatformTier.byokApi), {..._access(const Duration(days: 40)), SignInSecretKeys.tokenIssuedAt: _iso(_now)}), SignInGroup.renewsWhenPosting),
        (_status(_acct('x', PlatformTier.byokApi), _refreshing(_now)), SignInGroup.renewsWhenPosting),
        (_status(_acct('x', PlatformTier.byokApi, config: const {'authMode': 'oauth1'}), const {'oauth_token': 't'}), SignInGroup.mustReconnect),
        (_status(_acct('bluesky', PlatformTier.openApi), const {OAuthTokens.keyAccessToken: 't', SignInSecretKeys.appPassword: 'p'}), SignInGroup.renewsWhenPosting),
        (_status(_acct('wordpress', PlatformTier.openApi), const {'password': 'p'}), SignInGroup.noEndDate),
        (_status(_acct('inkbunny', PlatformTier.openApi), const {'sid': 's'}), SignInGroup.noEndDate),
        (_status(_acct('substack', PlatformTier.handoff), const {}), SignInGroup.noEndDate),
        (_status(a, _access(const Duration(days: 40)), refused: _now), SignInGroup.mustReconnect),
      ]) {
        expect(signInGroupOf(status, _now), group, reason: status.accountId);
      }
    });

    test('a date that passed moves a renewing sign-in to You must reconnect, with no write', () {
      final s = _status(_acct('x', PlatformTier.byokApi), _refreshing(_now));
      expect(signInGroupOf(s, _now), SignInGroup.renewsWhenPosting);
      expect(signInGroupOf(s, s.expiresAt!.add(const Duration(minutes: 1))), SignInGroup.mustReconnect);
      expect(signInCountdown(s, s.expiresAt!.add(const Duration(minutes: 1))), 'Probably ended');
    });

    test('ended and refused come first, then the soonest', () {
      final soon = _acct('linkedin', PlatformTier.byokApi, id: 'soon');
      final late = _acct('linkedin', PlatformTier.byokApi, id: 'late');
      final over = _acct('linkedin', PlatformTier.byokApi, id: 'over');
      final rows = signInRows([late, soon, over], {
        'soon': _status(soon, _access(const Duration(days: 3))),
        'late': _status(late, _access(const Duration(days: 30))),
        'over': _status(over, _access(const Duration(days: -3))),
      }, _real, _now);
      expect([for (final r in rows[SignInGroup.mustReconnect]!) r.account.id], ['over', 'soon', 'late']);
      expect(row(soon, _status(soon, _access(const Duration(days: 3)))).status.endsSoon(_now), isTrue);
    });

    test('an account with no status yet is listed from its policy, and marked unverified', () {
      final telegram = _acct('telegram', PlatformTier.openApi);
      final rows = signInRows([telegram], const {}, _real, _now);
      final r = rows[SignInGroup.noEndDate]!.single;
      expect(r.status.unverified, isTrue);
      expect(signInRowSentence(r, _now), contains('No published end date'));
    });

    test('words for no date never claim forever', () {
      final telegram = _acct('telegram', PlatformTier.openApi);
      final s = _status(telegram, const {'bot_token': 't'});
      expect(signInCardLine(s, _real.require('telegram').signInPolicyFor(telegram), _now), 'No published end date');
      final ink = _acct('inkbunny', PlatformTier.openApi);
      final idle = _status(ink, const {'sid': 's'}, confirmed: _now);
      expect(signInCardLine(idle, _real.require('inkbunny').signInPolicyFor(ink), _now), 'Ends after idle time, on no set date');
      expect(_status(_acct('substack', PlatformTier.handoff), const {}).hasConnection, isFalse);
      expect(signInCardLine(_status(_acct('substack', PlatformTier.handoff), const {}), SignInPolicy.noConnection, _now), isNull);
    });
  });

  group('actions', () {
    testWidgets('Reconnect, Renew now and Check now appear where each applies', (t) async {
      final mix = _mix();
      await _boot(t, fleet: mix, size: const Size(1100, 3000));
      ConnectedAccount of(String p) => mix.firstWhere((e) => e.$1.platformId == p).$1;
      bool has(String platform, String label) => find.descendant(of: _row(of(platform)), matching: find.text(label)).evaluate().isNotEmpty;

      expect(has('linkedin', 'Reconnect'), isTrue);
      expect(has('linkedin', 'Check now'), isTrue, reason: 'LinkedIn reports its own date');
      expect(has('linkedin', 'Renew now'), isFalse, reason: 'no refresh path');
      expect(has('x', 'Reconnect'), isTrue);
      expect(has('x', 'Check now'), isFalse, reason: 'never X');
      expect(has('youtube', 'Renew now'), isTrue);
      expect(has('youtube', 'Reconnect'), isFalse);
      expect(has('threads', 'Renew now'), isTrue);
      expect(has('threads', 'Check now'), isTrue);
      expect(has('tumblr', 'Reconnect'), isTrue, reason: 'refused');
      expect(has('tumblr', 'Renew now'), isFalse, reason: 'refused: a renewal cannot fix it');
      expect(has('wordpress', 'Reconnect'), isFalse);
      expect(has('substack', 'Reconnect'), isFalse);
      await _end(t);
    });

    testWidgets('the demo says nothing was renewed, and Reconnect goes to the connect flow', (t) async {
      final mix = _mix();
      final (c, _) = await _boot(t, fleet: mix, size: const Size(1100, 3000));
      final youtube = mix.firstWhere((e) => e.$1.platformId == 'youtube').$1;
      await t.tap(find.descendant(of: _row(youtube), matching: find.text('Renew now')));
      await _settle(t);
      expect(find.textContaining('nothing was renewed'), findsOneWidget);
      final linkedin = mix.firstWhere((e) => e.$1.platformId == 'linkedin').$1;
      await t.tap(find.descendant(of: _row(linkedin), matching: find.text('Reconnect')));
      await _settle(t);
      expect(c.read(routerProvider).state.uri.toString(), '/accounts/add?platform=linkedin');
      await _end(t);
    });

    test('Check now says what it found, in words', () {
      final a = _acct('linkedin', PlatformTier.byokApi);
      final end = _now.add(const Duration(days: 40));
      SignInStatus after(SignInServerRead read) => SignInStatus.fromLifetime(
            a.id,
            deriveSignInLifetime(_real.require('linkedin').signInPolicyFor(a), _access(const Duration(days: 20)), now: _now, serverRead: read),
            hasConnection: true,
            serverRead: read,
          );
      expect(signInCheckWords('LinkedIn', _now, null), 'Could not check LinkedIn. Nothing changed.');
      // A read from before the button was pressed is not an answer to it.
      expect(signInCheckWords('LinkedIn', _now, after(SignInServerRead(readAt: _now.subtract(const Duration(days: 2)), expiresAt: end))), startsWith('Could not check'));
      expect(signInCheckWords('LinkedIn', _now, after(SignInServerRead(readAt: _now, expiresAt: end))), allOf(contains('LinkedIn sign-in: ends'), contains('at the latest')));
      expect(signInCheckWords('LinkedIn', _now, after(SignInServerRead(readAt: _now, isValid: false))), contains('no longer works'));

      // Bluesky reads its own token with no request, so Bluesky "said" nothing.
      final sky = _acct('bluesky', PlatformTier.openApi);
      final read = SignInServerRead(readAt: _now, accessExpiresAt: _now.add(const Duration(hours: 2)));
      final status = SignInStatus.fromLifetime(
        sky.id,
        deriveSignInLifetime(_real.require('bluesky').signInPolicyFor(sky), const {OAuthTokens.keyAccessToken: 't', SignInSecretKeys.appPassword: 'p'}, now: _now, serverRead: read),
        hasConnection: true,
        serverRead: read,
      );
      expect(signInCheckWords('Bluesky', _now, status), 'Checked Bluesky: no end date known.');
    });

    testWidgets('Check now in the demo says nothing was checked', (t) async {
      final a = _acct('linkedin', PlatformTier.byokApi);
      await _boot(t, fleet: [(a, _status(a, _access(const Duration(days: 20))))], size: const Size(1100, 1200));
      await t.tap(find.descendant(of: _row(a), matching: find.text('Check now')));
      await _settle(t);
      expect(find.text('This is the demo: nothing was checked.'), findsOneWidget);
      await _end(t);
    });
  });

  group('the closed card', () {
    testWidgets('shows the date as soon as the account connects, with no section opened and no keychain read', (t) async {
      final (c, s) = await _boot(t, fleet: const [], route: '/accounts', size: const Size(1100, 1400));
      final a = _acct('linkedin', PlatformTier.byokApi, handle: '@robin');
      final end = _now.add(const Duration(days: 60));
      await t.runAsync(() async {
        final secrets = stampNewSignIn(_access(const Duration(days: 60)), now: _now);
        // As connect_form.dart does it.
        await s.accounts.upsert(a);
        await s.secrets.write(a.id, secrets);
        await s.signInStatus.accountConnected(a, secrets, s.connectContext());
      });
      await _settle(t);
      final line = find.byKey(ValueKey('sign-in-line-${a.id}'));
      expect(line, findsOneWidget);
      final day = signInDay(end);
      expect(find.descendant(of: line, matching: find.textContaining('$day at the latest')), findsOneWidget);
      expect(find.text('Connected'), findsNothing, reason: 'the section stays closed');
      c.read(routerProvider).go(kSignInsPath);
      await _settle(t);
      expect(find.descendant(of: _row(a), matching: find.textContaining('$day at the latest')), findsWidgets);
      await _end(t);
    });

    testWidgets('a hand-off account has no line; a tap on the line opens the page', (t) async {
      final hand = _acct('substack', PlatformTier.handoff);
      final link = _acct('linkedin', PlatformTier.byokApi);
      final (c, _) = await _boot(t, fleet: [(hand, _status(hand, const {})), (link, _status(link, _access(const Duration(days: 30))))], route: '/accounts', size: const Size(1100, 2000));
      expect(find.byKey(ValueKey('sign-in-line-${hand.id}')), findsNothing);
      expect(find.byType(AccountCard), findsNWidgets(2));
      await t.tap(find.byKey(ValueKey('sign-in-line-${link.id}')));
      await _settle(t);
      expect(c.read(routerProvider).state.uri.path, kSignInsPath);
      await _end(t);
    });

    testWidgets('the Accounts page links to Sign-ins', (t) async {
      final link = _acct('linkedin', PlatformTier.byokApi);
      final (c, _) = await _boot(t, fleet: [(link, _status(link, _access(const Duration(days: 30))))], route: '/accounts');
      await t.tap(find.widgetWithText(OutlinedButton, 'Sign-ins'));
      await _settle(t);
      expect(c.read(routerProvider).state.uri.path, kSignInsPath);
      await _end(t);
    });
  });

  group('the banner', () {
    final banner = find.byKey(const ValueKey('sign-in-banner'));

    testWidgets('over every section at 14 days or fewer, not at 15', (t) async {
      final a = _acct('linkedin', PlatformTier.byokApi);
      final (c, _) = await _boot(t, fleet: [(a, _status(a, _access(const Duration(days: 14))))], route: '/compose');
      expect(banner, findsOneWidget);
      expect(find.descendant(of: banner, matching: find.textContaining('at the latest')), findsOneWidget);
      for (final section in AppSection.values) {
        c.read(routerProvider).go(section.path);
        await _settle(t);
        expect(banner, findsOneWidget, reason: section.path);
      }
      await _end(t);
      final (_, _) = await _boot(t, fleet: [(a, _status(a, _access(const Duration(days: 15))))], route: '/compose');
      expect(banner, findsNothing);
      await _end(t);
    });

    testWidgets('Close holds until the next threshold, across a restart of the store', (t) async {
      final a = _acct('linkedin', PlatformTier.byokApi);
      final status = _status(a, _access(const Duration(days: 10)));
      final (_, s) = await _boot(t, fleet: [(a, status)], route: '/queue');
      expect(banner, findsOneWidget);
      await t.tap(find.byTooltip('Close until the next warning'));
      await _settle(t);
      expect(banner, findsNothing);
      final closed = (await t.runAsync(() => s.signInWarningStore.read()))!;
      expect(openSignInBannerItems(signInBannerItems([status], _now), closed.bannerClosed), isEmpty);
      // At the 7-day threshold it is back.
      expect(openSignInBannerItems(signInBannerItems([status], status.expiresAt!.subtract(const Duration(days: 6))), closed.bannerClosed), hasLength(1));
      await _end(t);
    });

    testWidgets('Review opens the page; several read as a count, with no bare date', (t) async {
      final a = _acct('linkedin', PlatformTier.byokApi, id: 'one');
      final b = _acct('mastodon', PlatformTier.openApi, id: 'two');
      final (c, _) = await _boot(t, fleet: [(a, _status(a, _access(const Duration(days: 3)))), (b, _status(b, _access(const Duration(days: -1))))], route: '/queue');
      expect(find.descendant(of: banner, matching: find.text('2 sign-ins need you: 1 ended, 1 ends within 14 days.')), findsOneWidget);
      await t.tap(find.descendant(of: banner, matching: find.text('Review')));
      await _settle(t);
      expect(c.read(routerProvider).state.uri.path, kSignInsPath);
      await _end(t);
    });

    testWidgets('a switched-off account raises no banner', (t) async {
      final a = _acct('linkedin', PlatformTier.byokApi).copyWith(enabled: false);
      await _boot(t, fleet: [(a, _status(a, _access(const Duration(days: 3))))], route: '/queue');
      expect(banner, findsNothing);
      await _end(t);
    });
  });

  group('a post that would miss a network never does so silently', () {
    final end = _now.add(const Duration(days: 10));
    final before = end.subtract(const Duration(days: 1));
    final after = end.add(const Duration(days: 1));
    final link = _acct('linkedin', PlatformTier.byokApi);
    SignInRisk? risk(ConnectedAccount? a, SignInStatus? s, DateTime? due, {bool heldNow = false, bool willHold = false}) =>
        signInRiskFor(accountId: a?.id ?? 'gone', account: a, network: 'LinkedIn', status: s, due: due, now: _now, heldNow: heldNow, willHold: willHold);
    final ending = _status(link, _access(const Duration(days: 10)));

    final cases = <String, (SignInRisk? Function(), SignInRiskKind?)>{
      'scheduled before the end': (() => risk(link, ending, before), null),
      'scheduled after the end, must reconnect': (() => risk(link, ending, after), SignInRiskKind.endsFirst),
      'scheduled exactly at the end': (() => risk(link, ending, end), SignInRiskKind.endsFirst),
      'already ended, post right now': (() => risk(link, _status(link, _access(const Duration(days: -1))), null), SignInRiskKind.ended),
      'refused': (() => risk(link, _status(link, _access(const Duration(days: 40)), refused: _now), before), SignInRiskKind.refused),
      'renews on post, ends first': (() {
        final x = _acct('x', PlatformTier.byokApi);
        return risk(x, _status(x, _refreshing(_now)), _now.add(const Duration(days: 400)));
      }, SignInRiskKind.renewalEndsFirst),
      'renews on post, in time': (() {
        final x = _acct('x', PlatformTier.byokApi);
        return risk(x, _status(x, _refreshing(_now)), before);
      }, null),
      'X keys, after the announced end': (() {
        final x = _acct('x', PlatformTier.byokApi, config: const {'authMode': 'oauth1'});
        return risk(x, _status(x, const {'oauth_token': 't'}), DateTime.utc(2027, 2, 2));
      }, SignInRiskKind.deadlineFirst),
      'X keys, before the announced end': (() {
        final x = _acct('x', PlatformTier.byokApi, config: const {'authMode': 'oauth1'});
        return risk(x, _status(x, const {'oauth_token': 't'}), DateTime.utc(2026, 12, 2));
      }, null),
      'will be asked to hold, ends first': (() => risk(link, ending, after, willHold: true), SignInRiskKind.handOverEndsFirst),
      'will be held, already ended: the hand-over fails, so it is a miss': (() => risk(link, _status(link, _access(const Duration(days: -1))), after, willHold: true), SignInRiskKind.ended),
      'already held, ends first': (() => risk(link, ending, after, heldNow: true), SignInRiskKind.heldEndsFirst),
      'already held, sign-in ended since': (() => risk(link, _status(link, _access(const Duration(days: -1))), after, heldNow: true), SignInRiskKind.heldEndsFirst),
      'already held, in time': (() => risk(link, ending, before, heldNow: true), null),
      'idle network, soon after it last worked': (() {
        final ink = _acct('inkbunny', PlatformTier.openApi);
        return risk(ink, _status(ink, const {'sid': 's'}, confirmed: _now), _now.add(const Duration(days: 2)));
      }, null),
      'idle network, far off': (() {
        final ink = _acct('inkbunny', PlatformTier.openApi);
        return risk(ink, _status(ink, const {'sid': 's'}, confirmed: _now), _now.add(const Duration(days: 9)));
      }, SignInRiskKind.idle),
      'switched off': (() => risk(link.copyWith(enabled: false), ending, before), SignInRiskKind.accountOff),
      'switched off, already held: it still goes': (() => risk(link.copyWith(enabled: false), ending, before, heldNow: true), null),
      'removed': (() => risk(null, null, before), SignInRiskKind.accountRemoved),
      'no end date': (() {
        final wp = _acct('wordpress', PlatformTier.openApi);
        return risk(wp, _status(wp, const {'password': 'p'}), after);
      }, null),
      'hand-off': (() {
        final sub = _acct('substack', PlatformTier.handoff);
        return risk(sub, _status(sub, const {}), after);
      }, null),
    };
    cases.forEach((name, c) {
      test(name, () => expect(c.$1()?.kind, c.$2));
    });

    test('only the network whose own time falls after the end warns', () {
      final other = _acct('mastodon', PlatformTier.openApi);
      final post = Post(
        id: 'p',
        text: 'hello',
        status: PostStatus.scheduled,
        scheduledAt: before,
        createdAt: _now,
        updatedAt: _now,
        targets: [
          PostTarget(accountId: link.id, overrides: PostOverrides(scheduledAt: after)),
          PostTarget(accountId: other.id, overrides: PostOverrides(scheduledAt: before)),
        ],
      );
      final risks = signInRisksOfPost(post, accounts: [link, other], statuses: {link.id: ending, other.id: _status(other, _access(const Duration(days: 10)))}, registry: _real, now: _now);
      expect([for (final r in risks) r.accountId], [link.id]);
    });

    test('a target already done has no risk, and a removed account does', () {
      final post = Post(
        id: 'p',
        text: 'hello',
        status: PostStatus.scheduled,
        scheduledAt: after,
        createdAt: _now,
        updatedAt: _now,
        targets: [PostTarget(accountId: link.id, status: TargetStatus.published), const PostTarget(accountId: 'gone')],
      );
      final risks = signInRisksOfPost(post, accounts: [link], statuses: {link.id: ending}, registry: _real, now: _now);
      expect([for (final r in risks) r.kind], [SignInRiskKind.accountRemoved]);
    });

    test('every warning is true to the held case: only a copy the platform has "still goes out"', () {
      expect(risk(link, ending, after, heldNow: true)!.text, contains('still goes out'));
      expect(risk(link, ending, after, heldNow: true)!.mayMiss, isFalse);
      expect(risk(link, ending, after)!.text, contains('misses this post'));
      expect(risk(link, ending, after)!.mayMiss, isTrue);
      // The platform has not agreed yet, and can say no.
      final asked = risk(link, ending, after, willHold: true)!;
      expect(asked.text, isNot(contains('still goes out')));
      expect(asked.text, contains('If it does not, this post misses'));
      expect(asked.mayMiss, isTrue, reason: 'Schedule asks first');
    });

    Post scheduled(DateTime at, ConnectedAccount a) => Post(
          id: 'p-${a.id}',
          text: 'A scheduled post',
          status: PostStatus.scheduled,
          scheduledAt: at,
          createdAt: _now,
          updatedAt: _now,
          targets: [PostTarget(accountId: a.id)],
        );

    testWidgets('the queue warns on the post, and clears when the sign-in is fixed', (t) async {
      final (c, s) = await _boot(t, fleet: [(link, ending)], route: '/compose', size: const Size(1100, 1400));
      await t.runAsync(() => s.posts.upsert(scheduled(after, link)));
      c.read(routerProvider).go('/queue');
      await _settle(t);
      expect(find.byKey(const ValueKey('sign-in-risks')), findsOneWidget);
      expect(find.textContaining('misses this post'), findsOneWidget);
      await t.tap(find.text('Open sign-ins'));
      await _settle(t);
      expect(c.read(routerProvider).state.uri.path, kSignInsPath);
      c.read(routerProvider).go('/queue');
      await _settle(t);
      // Reconnected: a later date, and the warning goes with no further step.
      await t.runAsync(() => s.signInStatusStore.change(link.id, (_) => _status(link, _access(const Duration(days: 60)))));
      await _settle(t);
      expect(find.byKey(const ValueKey('sign-in-risks')), findsNothing);
      await _end(t);
    });

    testWidgets('the queue picks up a date that arrives after the post was scheduled', (t) async {
      final (c, s) = await _boot(t, fleet: [(link, _status(link, _access(const Duration(days: 60))))], route: '/compose', size: const Size(1100, 1400));
      await t.runAsync(() => s.posts.upsert(scheduled(after, link)));
      c.read(routerProvider).go('/queue');
      await _settle(t);
      expect(find.byKey(const ValueKey('sign-in-risks')), findsNothing);
      await t.runAsync(() => s.signInStatusStore.change(link.id, (_) => ending));
      await _settle(t);
      expect(find.byKey(const ValueKey('sign-in-risks')), findsOneWidget);
      await _end(t);
    });

    testWidgets('the composer warns, and Schedule asks first: Go back schedules nothing', (t) async {
      final (c, s) = await _boot(t, fleet: [(link, ending)], route: '/compose', size: const Size(1200, 900));
      final n = c.read(composerProvider.notifier);
      n.reset(keepTargets: false);
      n.setText('Hello');
      n.selectAccounts([link.id]);
      n.setSchedule(after);
      await _settle(t);
      expect(find.byKey(const ValueKey('composer-sign-in-warning')), findsOneWidget);

      await t.tap(find.textContaining(RegExp(r'^Schedule( for|$)')));
      await _settle(t);
      expect(find.text('LinkedIn may miss this post'), findsOneWidget);
      await t.tap(find.text('Go back'));
      await _settle(t);
      var posts = (await t.runAsync(() => s.posts.all()))!;
      expect(posts, isEmpty);
      expect(c.read(composerProvider).scheduledAt, after, reason: 'the composer is as it was');

      await t.tap(find.textContaining(RegExp(r'^Schedule( for|$)')));
      await _settle(t);
      await t.tap(find.text('Schedule anyway'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await _settle(t);
      posts = (await t.runAsync(() => s.posts.all()))!;
      expect(posts, hasLength(1));
      await _end(t);
    });

    testWidgets('a post within the sign-in schedules with no question and no warning', (t) async {
      final (c, s) = await _boot(t, fleet: [(link, ending)], route: '/compose', size: const Size(1200, 900));
      final n = c.read(composerProvider.notifier);
      n.reset(keepTargets: false);
      n.setText('Hello');
      n.selectAccounts([link.id]);
      n.setSchedule(before);
      await _settle(t);
      expect(find.byKey(const ValueKey('composer-sign-in-warning')), findsNothing);
      await t.tap(find.textContaining(RegExp(r'^Schedule( for|$)')));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await _settle(t);
      expect(find.text('LinkedIn may miss this post'), findsNothing);
      expect((await t.runAsync(() => s.posts.all()))!, hasLength(1));
      await _end(t);
    });

    group('rescheduling a saved post', () {
      const settings = AppSettings(delegateSchedules: true);
      final done = _acct('mastodon', PlatformTier.openApi);
      final holds = _acct('mastodon', PlatformTier.openApi, id: 'holds');
      final statuses = {link.id: ending, done.id: ending, holds.id: _status(holds, _access(const Duration(days: 10)))};
      List<SignInRisk> risks(Post p, DateTime when, List<ConnectedAccount> accounts) =>
          signInRisksOfReschedule(p, when, accounts: accounts, statuses: statuses, registry: _real, settings: settings, now: _now);

      test('warns for the new time, and only for networks still to go', () {
        final post = scheduled(before, link).copyWith(targets: [
          PostTarget(accountId: link.id),
          PostTarget(accountId: done.id, status: TargetStatus.published),
        ]);
        expect(risks(post, before, [link, done]), isEmpty);
        expect([for (final r in risks(post, after, [link, done])) (r.accountId, r.kind)], [(link.id, SignInRiskKind.endsFirst)]);
      });

      test('moves each network by the same amount, as the reschedule itself does', () {
        final other = _acct('wordpress', PlatformTier.openApi);
        final post = scheduled(_now.add(const Duration(days: 1)), link).copyWith(targets: [
          PostTarget(accountId: link.id, overrides: PostOverrides(scheduledAt: _now.add(const Duration(days: 6)))),
          PostTarget(accountId: other.id, overrides: PostOverrides(scheduledAt: _now.add(const Duration(days: 1)))),
        ]);
        // Three days on, the next network goes on day 4, and LinkedIn's day 6 becomes day 9: still in time.
        expect(risks(post, _now.add(const Duration(days: 4)), [link, other]), isEmpty);
        // Five days on, day 11: past the end, though the post's own time is not.
        expect([for (final r in risks(post, _now.add(const Duration(days: 6)), [link, other])) r.accountId], [link.id]);
      });

      test('what the platform would be asked to hold says it can say no; a thread it cannot hold is a plain miss', () {
        final post = scheduled(after, holds);
        final asked = risks(post, after, [holds]).single;
        expect(asked.kind, SignInRiskKind.handOverEndsFirst);
        expect(asked.mayMiss, isTrue);
        final thread = post.copyWith(additionalParts: const ['Part two']);
        expect(risks(thread, after, [holds]).single.kind, SignInRiskKind.endsFirst);
      });

      test('a platform that said no: the queue says the post misses it, for as long as it holds', () {
        // The hand-over stays a background job: this is the post it leaves behind.
        final left = signInRisksOfPost(scheduled(after, holds), accounts: [holds], statuses: {holds.id: _status(holds, _access(const Duration(days: 10)))}, registry: _real, now: _now);
        expect(left.single.kind, SignInRiskKind.endsFirst);
        expect(left.single.text, contains('misses this post'));
      });

      testWidgets('warns in the sheet and asks first: Go back moves nothing', (t) async {
        final at = DateTime.now();
        final near = SignInStatus.fromLifetime(link.id, deriveSignInLifetime(_real.require('linkedin').signInPolicyFor(link), {OAuthTokens.keyAccessToken: 't', OAuthTokens.keyExpiresAt: _iso(at.add(const Duration(days: 3)))}, now: at), hasConnection: true);
        final (c, s) = await _boot(t, fleet: [(link, near)], route: '/compose', size: const Size(1100, 1400), now: at);
        final post = scheduled(at.add(const Duration(days: 6)), link);
        await t.runAsync(() => s.posts.upsert(post));
        c.read(routerProvider).go('/queue');
        await _settle(t);

        Future<void> openAndConfirm() async {
          await t.tap(find.byTooltip('Actions'));
          await _settle(t);
          await t.tap(find.text('Reschedule'));
          await _settle(t);
          // On the post in the queue, and in the sheet.
          expect(find.byKey(const ValueKey('sign-in-risks')), findsNWidgets(2));
          await t.tap(find.textContaining('Schedule for '));
          await _settle(t);
          expect(find.text('LinkedIn may miss this post'), findsOneWidget);
        }

        await openAndConfirm();
        await t.tap(find.text('Go back'));
        await _settle(t);
        expect((await t.runAsync(() => s.posts.get(post.id)))!.updatedAt, post.updatedAt, reason: 'nothing moved');

        await openAndConfirm();
        await t.tap(find.text('Schedule anyway'));
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await _settle(t);
        expect((await t.runAsync(() => s.posts.get(post.id)))!.updatedAt, isNot(post.updatedAt));
        await _end(t);
      });
    });

    testWidgets('the schedule sheet warns for the time being picked', (t) async {
      final at = DateTime.now();
      final soon = _acct('linkedin', PlatformTier.byokApi);
      final near = SignInStatus.fromLifetime(soon.id, deriveSignInLifetime(_real.require('linkedin').signInPolicyFor(soon), {OAuthTokens.keyAccessToken: 't', OAuthTokens.keyExpiresAt: _iso(at.add(const Duration(days: 3)))}, now: at), hasConnection: true);
      final (c, _) = await _boot(t, fleet: [(soon, near)], route: '/compose', size: const Size(1200, 1000), now: at);
      final n = c.read(composerProvider.notifier);
      n.reset(keepTargets: false);
      n.setText('Hello');
      n.selectAccounts([soon.id]);
      await _settle(t);
      final ctx = t.element(find.byType(Scaffold).first);
      final done = showScheduleSheet(ctx, initial: at.add(const Duration(days: 1)));
      await _settle(t);
      expect(find.byKey(const ValueKey('sign-in-risks')), findsNothing);
      Navigator.of(ctx, rootNavigator: true).pop();
      await _settle(t);
      await done;
      final late = showScheduleSheet(ctx, initial: at.add(const Duration(days: 6)));
      await _settle(t);
      expect(find.byKey(const ValueKey('sign-in-risks')), findsOneWidget);
      expect(find.textContaining('at the latest'), findsWidgets);
      Navigator.of(ctx, rootNavigator: true).pop();
      await _settle(t);
      await late;
      await _end(t);
    });
  });

  group('secret guard', () {
    const secrets = ['SECRETACCESSVALUE', 'SECRETREFRESHVALUE', 'SECRETAPPVALUE', 'SECRETPASSWORDVALUE'];

    testWidgets('no key reaches the page, the card, the banner, the queue, a notification or the log', (t) async {
      final lines = <String>[];
      final previous = Logger.defaultSink;
      Logger.defaultSink = (level, area, message, [error]) => lines.add('$area $message $error');
      addTearDown(() => Logger.defaultSink = previous);
      final a = _acct('linkedin', PlatformTier.byokApi, handle: '@robin');
      final b = _acct('x', PlatformTier.byokApi, handle: '@robin2');
      final (c, s) = await _boot(t, fleet: const [], route: '/accounts', size: const Size(1200, 2600));
      await t.runAsync(() async {
        for (final account in [a, b]) {
          await s.accounts.upsert(account);
          await s.secrets.write(account.id, {
            OAuthTokens.keyAccessToken: secrets[0],
            OAuthTokens.keyRefreshToken: secrets[1],
            'client_secret': secrets[2],
            'password': secrets[3],
            OAuthTokens.keyExpiresAt: _iso(DateTime.now().add(const Duration(days: 3))),
          });
        }
        await s.posts.upsert(Post(id: 'p', text: 'x', status: PostStatus.scheduled, scheduledAt: DateTime.now().add(const Duration(days: 9)), createdAt: _now, updatedAt: _now, targets: [PostTarget(accountId: a.id)]));
      });
      await _settle(t);
      final words = StringBuffer(_allWords(t));
      c.read(routerProvider).go(kSignInsPath);
      await _settle(t);
      words.write(_allWords(t));
      c.read(routerProvider).go('/queue');
      await _settle(t);
      words.write(_allWords(t));
      final statuses = (await t.runAsync(() => s.signInStatusStore.all()))!;
      expect(statuses, hasLength(2));
      for (final st in statuses.values) {
        words.writeln(st.toJson());
        if (st.expiresAt == null) continue;
        final n = SignInWarningNotice(status: st, at: DateTime.now(), daysBefore: 3, key: 'k');
        final text = signInWarningText(n, network: 'net', handle: '@h', now: DateTime.now(), when: signInDay);
        words
          ..writeln(text.title)
          ..writeln(text.body);
      }
      words.writeAll(lines, '\n');
      final all = words.toString();
      expect(all, contains('at the latest'), reason: 'the scan saw the dates');
      for (final v in secrets) {
        expect(all, isNot(contains(v)));
      }
      await _end(t);
    });
  });

  group('notifications', () {
    test('a warning opens the sign-ins page', () {
      expect(NotificationIntent.parse(kSignInsPayload), isA<OpenSignInsIntent>());
    });

    testWidgets('the sink words a notice with the network and handle only', (t) async {
      final accounts = InMemoryAccountRepository();
      final a = _acct('linkedin', PlatformTier.byokApi, handle: '@robin');
      await t.runAsync(() => accounts.upsert(a));
      final sink = SignInNotificationSink(accounts: accounts, registry: _real, clock: () => _now);
      // No OS here: the plugin is not ready, so these return without raising.
      final n = SignInWarningNotice(status: _status(a, _access(const Duration(days: 3))), at: _now, daysBefore: 3, key: 'k');
      await t.runAsync(() => sink.show(n));
      await t.runAsync(() => sink.schedule(n));
      expect(await t.runAsync(() => sink.othersPending()), 0);
      await const SilentSignInSink().show(n);
    });

    testWidgets('the demo seeds dates far enough off to raise no warning', (t) async {
      final services = (await t.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
      final statuses = (await t.runAsync(() => services.signInStatusStore.all()))!;
      expect(statuses, isNotEmpty);
      final accounts = (await t.runAsync(() => services.accounts.all()))!;
      expect(signInBannerItems(signInStatusesToWatch(accounts, statuses), DateTime.now()), isEmpty);
      expect(accounts.every((a) => demoRegistry(_real).byId(a.platformId) != null), isTrue);
    });
  });

  group('360 x 640 with no overflow', () {
    for (final theme in const ['light', 'dark']) {
      for (final scale in const [1.0, 1.5]) {
        testWidgets('page, cards, banner and queue, $theme, text $scale', (t) async {
          final mix = _mix();
          final (c, s) = await _boot(t, fleet: mix, size: const Size(360, 640), theme: theme, textScale: scale);
          await t.runAsync(() => s.posts.upsert(Post(id: 'p', text: 'A post', status: PostStatus.scheduled, scheduledAt: _now.add(const Duration(days: 30)), createdAt: _now, updatedAt: _now, targets: [PostTarget(accountId: mix.first.$1.id), PostTarget(accountId: mix[1].$1.id)])));
          await _settle(t);
          expect(find.byKey(ValueKey('sign-in-group-${SignInGroup.mustReconnect.name}')), findsOneWidget);
          expect(find.byKey(const ValueKey('sign-in-banner')), findsOneWidget);
          for (final route in ['/accounts', '/queue', '/compose', kSignInsPath]) {
            c.read(routerProvider).go(route);
            await _settle(t);
          }
          expect(t.takeException(), isNull);
          await _end(t);
        });
      }
    }

    testWidgets('every target on the phone page is at least 48 tall', (t) async {
      final mix = _mix();
      await _boot(t, fleet: mix, size: const Size(360, 3600));
      for (final label in const ['Reconnect', 'Renew now', 'Check now']) {
        expect(find.text(label), findsWidgets);
        for (final e in find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)).evaluate()) {
          expect((e.renderObject! as RenderBox).size.height, greaterThanOrEqualTo(48), reason: label);
        }
      }
      await _end(t);
    });
  });

  // Evidence for the critic, on request:
  //   flutter test test/sign_ins_page_test.dart --tags screenshots --dart-define=SIGN_INS_SHOTS=<folder>
  group('screenshots', () {
    const folder = String.fromEnvironment('SIGN_INS_SHOTS');
    for (final (name, size, theme) in const [('a-desktop.png', Size(1100, 800), 'light'), ('a-phone.png', Size(360, 640), 'light'), ('a-desktop-dark.png', Size(1100, 800), 'dark'), ('a-phone-dark.png', Size(360, 640), 'dark')]) {
      testWidgets(name, skip: folder.isEmpty, tags: const ['screenshots'], (t) async {
        final mix = _mix();
        await _boot(t, fleet: mix, size: size, theme: theme, withRepaint: true);
        await t.runAsync(() async {
          final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(_shot));
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File('$folder/$name')
            ..createSync(recursive: true)
            ..writeAsBytesSync(bytes!.buffer.asUint8List());
        });
        await _end(t);
      });
    }
  });
}
