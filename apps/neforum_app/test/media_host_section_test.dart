// Settings > Media hosting: the optional fallback host.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/settings/media_host_section.dart';

class _MemoryStorage implements AppStorage {
  _MemoryStorage(Map<String, Object> settings) : _json = {'settings.json': settings};
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
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => const SizedBox();
}

Future<AppServices> _pump(WidgetTester tester, Map<String, Object> settings) async {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage(settings))))!;
  await tester.pumpWidget(ProviderScope(
    overrides: [servicesProvider.overrideWithValue(services)],
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AccentChoice.neforum),
      home: const Scaffold(body: SingleChildScrollView(child: MediaHostSection())),
    ),
  ));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pump();
  return services;
}

void main() {
  testWidgets('no main host: no fallback choice yet', (tester) async {
    await _pump(tester, {});
    expect(find.text('Fallback host'), findsNothing);
  });

  testWidgets('with a main host, a fallback can be added; the same account-free host is not offered', (tester) async {
    await _pump(tester, {'mediaHostId': 'litterbox', 'mediaHostConfig': <String, String>{}});
    expect(find.text('Fallback host'), findsOneWidget);
    expect(find.text('None'), findsOneWidget);
    await tester.tap(find.text('Add a fallback host'));
    await tester.pump();
    // The editor reads its saved values (none yet) before showing the choices.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('Litterbox (temporary, free)'), findsOneWidget, reason: 'only in the main host grid');
    expect(find.text('Catbox (permanent, free)'), findsNWidgets(2));
    await tester.tap(find.text('Catbox (permanent, free)').last);
    await tester.pump();
    expect(find.text('Save fallback'), findsOneWidget);
  });

  testWidgets('a saved fallback shows as ready, with the last time it stepped in', (tester) async {
    final services = await _pump(tester, {
      'mediaHostId': 'litterbox',
      'mediaHostConfig': <String, String>{},
      'fallbackMediaHostId': 'catbox',
      'fallbackMediaHostConfig': <String, String>{},
    });
    expect(find.text('Catbox · ready'), findsOneWidget);
    expect(find.text('Remove fallback'), findsOneWidget);
    services.lastMediaHostFallback.value = (at: DateTime(2026, 10, 11, 14, 5), message: 'Litterbox failed, so Catbox stored img1.jpg.');
    await tester.pump();
    expect(find.textContaining('The fallback stepped in at'), findsOneWidget);
    expect(find.textContaining('Litterbox failed, so Catbox stored img1.jpg.'), findsOneWidget);
  });
}
