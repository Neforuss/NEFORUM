// Renders every screen of the demo workspace at phone, tablet and desktop
// sizes, in light and dark, and fails on any exception or layout overflow.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';

class _MemoryStorage implements AppStorage {
  final Map<String, Object> _json = {};
  final Map<String, Uint8List> _media = {};

  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => _json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => _json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async {
    final p = 'mem://$id.$extension';
    _media[p] = bytes;
    return p;
  }

  @override
  Future<Uint8List> readMedia(String path) async => _media[path]!;
  @override
  Future<void> deleteMedia(String path) async => _media.remove(path);
  @override
  Future<int> mediaBytes() async => _media.values.fold<int>(0, (s, b) => s + b.length);
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) =>
      SizedBox(width: width, height: height, child: const ColoredBox(color: Color(0xFF888888)));
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

const _routes = ['/compose', '/queue', '/activity', '/activity/post/demo-post-2', '/accounts', '/accounts/add', '/settings'];
const _sizes = {'phone': Size(360, 740), 'tablet': Size(900, 700), 'desktop': Size(1440, 900), 'wide': Size(2200, 1200)};

void main() {
  setUpAll(_loadFonts);

  for (final brightness in [Brightness.dark, Brightness.light]) {
    for (final size in _sizes.entries) {
      testWidgets('all screens render at ${size.key} (${brightness.name})', (tester) async {
        tester.view.physicalSize = size.value;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

        final services = await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage()));

        await tester.pumpWidget(ProviderScope(
          overrides: [servicesProvider.overrideWithValue(services!)],
          child: const NeforumApp(),
        ));
        await tester.pump(const Duration(milliseconds: 300));

        final router = ProviderScope.containerOf(tester.element(find.byType(MaterialApp))).read(routerProvider);
        final errors = <FlutterErrorDetails>[];
        final previous = FlutterError.onError;
        FlutterError.onError = errors.add;
        try {
          for (final route in _routes) {
            router.go(route);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 600));
            if (errors.isNotEmpty) {
              debugPrint('---- $route at ${size.key} ----\n${errors.first}');
              fail('${errors.length} error(s) on $route at ${size.key}: ${errors.first.exceptionAsString()}');
            }
          }
        } finally {
          FlutterError.onError = previous;
        }
        expect(find.byType(GoRouter, skipOffstage: false), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      });
    }
  }
}
