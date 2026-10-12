// The connect form: a pasted token is the main route, so the redirect box
// starts folded, and a failed attempt's error goes away once a field changes.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/demo.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/accounts/connect_form.dart';
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

/// Every connect attempt fails the way a token from the wrong Meta app does.
class _RejectingAdapter extends DemoAdapter {
  _RejectingAdapter(super.inner);

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async =>
      throw const ConnectException('This token was made for a different Meta app.');
}

void main() {
  testWidgets('Facebook: redirect folded, stale error cleared on edit', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
    final registry = AdapterRegistry([_RejectingAdapter(builtinRegistry().require('facebook'))]);
    await tester.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services), registryProvider.overrideWithValue(registry)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConnectForm(platformId: 'facebook', tier: PlatformTier.byokApi, onConnected: (_) {}),
          ),
        ),
      ),
    ));
    await tester.pump();

    // Browser sign-in is the fallback: its redirect box starts folded.
    const unfold = 'Browser sign-in instead? Show the redirect URI';
    expect(find.text(unfold), findsOneWidget);
    expect(find.text('Redirect URI'), findsNothing);
    await tester.tap(find.text(unfold));
    await tester.pump();
    expect(find.text('Redirect URI'), findsOneWidget);
    expect(find.text(unfold), findsNothing);

    // Fill every field (the token first, which switches the button to Connect).
    final fields = find.byType(TextFormField);
    for (var i = 0; i < fields.evaluate().length; i++) {
      await tester.enterText(fields.at(i), 'value$i');
    }
    await tester.pump();
    expect(find.text('Redirect URI'), findsNothing, reason: 'no browser sign-in once a token is pasted');

    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump();
    expect(find.text('This token was made for a different Meta app.'), findsOneWidget);

    // Changing any field means the error no longer describes the form.
    await tester.enterText(fields.first, 'a fresh token');
    await tester.pump();
    expect(find.text('This token was made for a different Meta app.'), findsNothing);
  });
}
