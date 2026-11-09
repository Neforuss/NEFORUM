// NEFORUM 1.4.2: Accounts > Add account links each platform's own site, so
// someone with no account there yet can make one first.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/accounts/connect_form.dart';
import 'package:neforum_app/ui/accounts/platform_picker.dart';
import 'package:neforum_app/widgets/platform_site_link.dart';
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
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => const SizedBox();
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1200, 8000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
  await tester.pumpWidget(ProviderScope(
    overrides: [servicesProvider.overrideWithValue(services)],
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AccentChoice.neforum),
      home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(24), child: child)),
    ),
  ));
  await tester.pump();
}

void main() {
  late List<Uri> opened;
  setUp(() {
    opened = [];
    PlatformSiteLink.open = (url) async {
      opened.add(url);
      return true;
    };
  });

  test('the link reads as the plain address', () {
    expect(PlatformSiteLink.labelOf('https://www.tumblr.com'), 'tumblr.com');
    expect(PlatformSiteLink.labelOf('https://www.facebook.com'), 'facebook.com');
    expect(PlatformSiteLink.labelOf('https://write.as'), 'write.as');
    expect(PlatformSiteLink.labelOf('https://www.newgrounds.com/art'), 'newgrounds.com/art');
    expect(PlatformSiteLink.labelOf('https://rumble.com/'), 'rumble.com');
    expect(PlatformSiteLink.labelOf(null), isNull);
  });

  testWidgets('every platform in the gallery links its site, and the link opens the site instead of the setup', (tester) async {
    final picked = <String>[];
    await _pump(tester, PlatformPicker(onPick: picked.add));
    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await tester.pumpAndSettle();

    final descriptors = builtinRegistry().descriptors;
    for (final d in descriptors) {
      expect(find.byKey(ValueKey('site-link-${d.id}')), findsOneWidget, reason: '${d.id} has no site link');
    }

    await tester.tap(find.byKey(const ValueKey('site-link-tumblr')));
    await tester.pump();
    expect(opened, [Uri.parse('https://www.tumblr.com')]);
    expect(picked, isEmpty, reason: 'opening the site is not picking the platform');
    expect(find.descendant(of: find.byKey(const ValueKey('site-link-tumblr')), matching: find.text('tumblr.com')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('site-link-writefreely')));
    await tester.pump();
    expect(opened.last, Uri.parse('https://write.as'));

    await tester.tap(find.text('Tumblr'));
    await tester.pump();
    expect(picked, ['tumblr'], reason: 'the rest of the card still picks the platform');
  });

  testWidgets('the connect form says where to make an account first', (tester) async {
    await _pump(tester, ConnectForm(platformId: 'facebook', tier: PlatformTier.byokApi, onConnected: (_) {}));
    expect(find.text('No Facebook account yet?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('site-link-facebook')));
    await tester.pump();
    expect(opened, [Uri.parse('https://www.facebook.com')]);
  });
}
