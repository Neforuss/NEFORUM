// 1.4.4: paid plans per account (docs/paid-tiers.md), and the connect form's
// switch rows lined up with its text fields.
//
// The switch row (NfSwitchField) replaced a SwitchListTile with zero padding:
// its label sat flush against the row's left edge while the text fields'
// text starts after their content padding, and its switch hugged the right.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/state/subscription_view.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/accounts/connect_form.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_app/widgets/switch_field.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _MemoryStorage implements AppStorage {
  _MemoryStorage([Map<String, Object> settings = const {}]) : _json = {'settings.json': settings};
  final Map<String, Object> _json;
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

/// Every connect form with a switch: the network and the way it connects.
List<(String, PlatformTier)> _formsWithSwitches() => [
  for (final a in builtinAdapters())
    for (final s in a.connectSpecs)
      if (s.fields.any((f) => f.kind == FieldKind.boolean) && s.fields.any((f) => !f.secret && f.kind == FieldKind.text)) (a.id, s.tier),
];

Future<AppServices> _services(WidgetTester tester) async => (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;

Future<void> _pumpForm(
  WidgetTester tester,
  AppServices services,
  String platform,
  PlatformTier tier, {
  required ThemeData theme,
  required double width,
}) async {
  tester.view.physicalSize = Size(width, 2600);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: MaterialApp(
        theme: theme,
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(Space.lg),
            child: ConnectForm(key: ValueKey('$platform-$tier-${theme.brightness}-$width'), platformId: platform, tier: tier, onConnected: (_) {}),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('switch rows line up with the text fields', () {
    test('the connect forms with switches include Parler', () {
      expect(_formsWithSwitches(), contains(('parler', PlatformTier.handoff)));
    });

    testWidgets('label and switch inset like a text field, every theme, density, Seamless and width', (tester) async {
      addTearDown(tester.view.reset);
      final services = await _services(tester);
      final forms = _formsWithSwitches();
      var checked = 0;
      // Android (phones) and Windows (desktop visual density) builds.
      final looks = [
        for (final os in [TargetPlatform.android, TargetPlatform.windows])
          for (final brightness in Brightness.values)
            for (final seamless in [false, true]) (os, brightness, seamless),
      ];
      for (final (os, brightness, seamless) in looks) {
        debugDefaultTargetPlatformOverride = os;
        for (final density in InterfaceDensity.values) {
          final theme = buildTheme(brightness, AccentChoice.neforum, seamless: seamless, density: density);
          final pad = (theme.inputDecorationTheme.contentPadding! as EdgeInsets);
          for (final width in [390.0, 900.0]) {
            for (final (platform, tier) in forms) {
              await _pumpForm(tester, services, platform, tier, theme: theme, width: width);
              final where = '$platform ${tier.name} ${os.name} ${brightness.name} seamless=$seamless ${density.name} ${width.toInt()}px';
              // Where a plain text field's text starts: its EditableText. A
              // secret field adds a key icon, so the plain ones are the leftmost.
              final textLeft = [for (final e in find.byType(EditableText).evaluate()) tester.getTopLeft(find.byWidget(e.widget)).dx]
                  .reduce((a, b) => a < b ? a : b);
              final fieldLeft = tester.getTopLeft(find.byType(TextFormField).first).dx;
              for (final row in find.byType(NfSwitchField).evaluate()) {
                final field = find.byWidget(row.widget);
                final label = find.descendant(of: field, matching: find.text((row.widget as NfSwitchField).label));
                final rowRect = tester.getRect(field);
                final switchRect = tester.getRect(find.descendant(of: field, matching: find.byType(Switch)));
                expect(tester.getTopLeft(label).dx, moreOrLessEquals(textLeft, epsilon: 1), reason: '$where: label starts where field text starts');
                expect(rowRect.left, moreOrLessEquals(fieldLeft, epsilon: 1), reason: '$where: same left edge as the fields');
                // The switch's track sits centred in its box.
                final trackRight = switchRect.center.dx + NfSwitchField.trackWidth / 2;
                final labelInset = tester.getTopLeft(label).dx - rowRect.left;
                expect(
                  rowRect.right - trackRight,
                  moreOrLessEquals(labelInset, epsilon: 1),
                  reason: '$where: the switch as far from the right edge as the label from the left',
                );
                expect(tester.getTopLeft(label).dx - rowRect.left, greaterThanOrEqualTo(pad.left - 1), reason: '$where: never flush left');
                checked++;
              }
            }
          }
        }
      }
      debugDefaultTargetPlatformOverride = null;
      expect(checked, greaterThanOrEqualTo(2 * 2 * 2 * 2 * 2 * forms.length));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the whole row toggles, and the form sends the choice', (tester) async {
      addTearDown(tester.view.reset);
      final services = await _services(tester);
      await _pumpForm(tester, services, 'parler', PlatformTier.handoff, theme: buildTheme(Brightness.light, AccentChoice.neforum), width: 900);
      final row = find.byKey(const ValueKey('connect-switch-subscriptionTier'));
      expect(row, findsOneWidget);
      expect(tester.widget<Switch>(find.descendant(of: row, matching: find.byType(Switch))).value, isFalse);
      await tester.tap(find.descendant(of: row, matching: find.text('Parler Premium')));
      await tester.pump();
      expect(
        tester.widget<Switch>(find.descendant(of: row, matching: find.byType(Switch))).value,
        isTrue,
        reason: 'a tap on the label toggles',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('connect form', () {
    testWidgets('X by hand-off asks for the plan; X with keys says X reports it', (tester) async {
      addTearDown(tester.view.reset);
      final services = await _services(tester);
      final theme = buildTheme(Brightness.light, AccentChoice.neforum);
      await _pumpForm(tester, services, 'x', PlatformTier.handoff, theme: theme, width: 900);
      expect(find.text('X plan'), findsOneWidget);
      expect(find.byKey(const ValueKey('connect-plan-detected')), findsNothing);
      await _pumpForm(tester, services, 'x', PlatformTier.byokApi, theme: theme, width: 900);
      expect(find.byKey(const ValueKey('connect-plan-detected')), findsOneWidget);
      expect(find.textContaining('NEFORUM reads the plan from X when you connect'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('card line', () {
    final registry = builtinRegistry();
    ConnectedAccount acct(String platform, PlatformTier tier, Map<String, dynamic> config) =>
        ConnectedAccount(id: 'a', platformId: platform, tier: tier, displayName: 'Someone', createdAt: DateTime.utc(2026, 11, 1), config: config);

    test('says who set the plan and what it changes', () {
      final x = registry.require('x');
      final parler = registry.require('parler');
      final youtube = registry.require('youtube');
      final detected = acct(
        'x',
        PlatformTier.byokApi,
        AccountSubscription.entries('premium', source: SubscriptionSource.detected, at: DateTime.utc(2026, 11, 16, 12)),
      );
      expect(subscriptionCardLine(x, detected), 'Read from X on 16 Nov 2026. Posts up to 25,000 characters; videos up to 125 minutes and 16 GB.');
      expect(
        subscriptionCardLine(parler, acct('parler', PlatformTier.handoff, {'premium': true})),
        'Chosen by you. Posts up to 2000 characters.',
        reason: 'a 1.4.3 Premium switch counts as chosen',
      );
      expect(subscriptionCardLine(parler, acct('parler', PlatformTier.handoff, {})), startsWith('Not set: NEFORUM uses the free limits.'));
      expect(subscriptionCardLine(youtube, acct('youtube', PlatformTier.byokApi, {})), startsWith('YouTube has not said yet. Reconnect to ask'));
      expect(subscriptionCardLine(registry.require('bluesky'), acct('bluesky', PlatformTier.openApi, {})), '');
    });
  });

  testWidgets('the preview follows the plan: one long post with X Premium, a thread without', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = await _services(tester);
    final free = ConnectedAccount(
      id: 'x-free',
      platformId: 'x',
      tier: PlatformTier.byokApi,
      displayName: 'Free',
      createdAt: DateTime.utc(2026, 11, 1),
    );
    final paid = builtinRegistry()
        .require('x')
        .withSubscriptionTier(
          ConnectedAccount(id: 'x-paid', platformId: 'x', tier: PlatformTier.byokApi, displayName: 'Paid', createdAt: DateTime.utc(2026, 11, 1)),
          'premium',
        );
    await tester.runAsync(() async {
      await services.accounts.upsert(free);
      await services.accounts.upsert(paid);
    });
    await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
    await tester.pump(const Duration(milliseconds: 300));
    final c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    c.read(routerProvider).go('/compose');
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    final text = List.filled(40, 'A sentence that goes on for a while.').join(' ');
    c.read(composerProvider.notifier)
      ..setText(text)
      ..selectAccounts(['x-free', 'x-paid']);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    final previews = {for (final p in c.read(composerPreviewsProvider)) p.account.id: p};
    expect(previews['x-paid']!.variant.isThread, isFalse);
    expect(previews['x-paid']!.variant.text, text);
    expect(previews['x-paid']!.issues.map((i) => i.code), contains('x.long_post'));
    expect(previews['x-paid']!.descriptor.text.maxLength, 25000, reason: 'the card counts against 25,000');
    expect(previews['x-free']!.descriptor.text.maxLength, 280);
    expect(previews['x-free']!.variant.isThread, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  group('account card', () {
    Future<AppServices> pumpAccounts(WidgetTester tester, List<ConnectedAccount> accounts) async {
      tester.view.physicalSize = const Size(1440, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final services = (await tester.runAsync(() async {
        final s = await AppServices.create(demo: true, storage: _MemoryStorage({'themeMode': 'light'}));
        for (final a in await s.accounts.all()) {
          await s.accounts.delete(a.id);
        }
        for (final a in accounts) {
          await s.accounts.upsert(a);
        }
        return s;
      }))!;
      await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
      await tester.pump(const Duration(milliseconds: 300));
      ProviderScope.containerOf(tester.element(find.byType(MaterialApp))).read(routerProvider).go('/accounts');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      return services;
    }

    testWidgets('shows the plan, keeps a 1.4.3 Parler Premium, and changes it from the menu', (tester) async {
      final parler = ConnectedAccount(
        id: 'parler-1',
        platformId: 'parler',
        tier: PlatformTier.handoff,
        displayName: 'Parler',
        createdAt: DateTime.utc(2026, 11, 13),
        config: const {'premium': true},
      );
      final x = ConnectedAccount(
        id: 'x-1',
        platformId: 'x',
        tier: PlatformTier.byokApi,
        displayName: 'Robin',
        createdAt: DateTime.utc(2026, 11, 13),
        config: {
          'authMode': 'oauth1',
          ...AccountSubscription.entries('premium_plus', source: SubscriptionSource.detected, at: DateTime.utc(2026, 11, 16)),
        },
      );
      final bluesky = ConnectedAccount(
        id: 'bsky-1',
        platformId: 'bluesky',
        tier: PlatformTier.openApi,
        displayName: 'Sky',
        createdAt: DateTime.utc(2026, 11, 13),
      );
      final services = await pumpAccounts(tester, [parler, x, bluesky]);

      expect(find.byKey(const ValueKey('plan-parler-1')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('plan-parler-1')), matching: find.text('Parler Premium')), findsOneWidget);
      expect(find.text('Chosen by you. Posts up to 2000 characters.'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('plan-x-1')), matching: find.text('X Premium+')), findsOneWidget);
      expect(find.byKey(const ValueKey('plan-bsky-1')), findsNothing, reason: 'Bluesky has no plan that changes limits');

      final menu = find.byKey(const ValueKey('plan-menu-parler-1'));
      await Scrollable.ensureVisible(tester.element(menu), alignment: 0.5);
      await tester.pump();
      await tester.tap(menu);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, 'Parler free'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final saved = (await tester.runAsync(() => services.accounts.get('parler-1')))!;
      expect(saved.config['subscriptionTier'], 'free');
      expect(saved.config.containsKey('premium'), isFalse, reason: 'the 1.4.3 switch follows');
      expect(builtinRegistry().require('parler').descriptorForAccount(saved).text.maxLength, 300);
      expect(find.text('Chosen by you. Posts up to 300 characters.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
