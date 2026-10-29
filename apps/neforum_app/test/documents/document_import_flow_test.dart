// The document import dialog: it previews the parts and pictures, asks
// before replacing a post being written, and fills the composer's parts and
// media (each picture in its part). Nothing is posted.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/document_import.dart';

import 'document_test_support.dart';

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
    final path = 'mem://$id.$extension';
    _media[path] = bytes;
    return path;
  }

  @override
  Future<Uint8List> readMedia(String path) async => _media[path]!;
  @override
  Future<void> deleteMedia(String path) async => _media.remove(path);
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => SizedBox(width: width, height: height);
}

/// A web page with two sections and a picture in the second.
Uint8List _page() {
  final png = base64.encode(solidPng(0x2A9D3F));
  return Uint8List.fromList(utf8.encode('<html><body><h1>Intro</h1><p>The first section says hello.</p>'
      '<h2>Garden</h2><p>The second section shows the beds.</p><p><img src="data:image/png;base64,$png" alt="Green beds"></p></body></html>'));
}

Future<ProviderContainer> _pumpComposer(WidgetTester tester) async {
  final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
  final container = ProviderContainer(overrides: [servicesProvider.overrideWithValue(services)]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AccentChoice.neforum),
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) => Center(
            child: TextButton(
              onPressed: () => importDocumentAsThread(context, ref, name: 'garden.html', bytes: _page()),
              child: const Text('Import'),
            ),
          ),
        ),
      ),
    ),
  ));
  return container;
}

/// Lets real work (another isolate, image decoding) finish.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
}

void main() {
  testWidgets('previews the parts and fills the composer, each picture in its part', (tester) async {
    final container = await _pumpComposer(tester);
    await tester.tap(find.text('Import'));
    await _settle(tester);

    expect(find.text('Make a thread from garden.html'), findsOneWidget);
    expect(find.text('2 parts · 1 picture'), findsOneWidget);
    expect(find.text('Part 1'), findsOneWidget);
    expect(find.text('Part 2'), findsOneWidget);
    expect(container.read(composerProvider).text, isEmpty, reason: 'nothing changes before "Make a thread"');

    await tester.tap(find.text('Make a thread'));
    await _settle(tester);

    final c = container.read(composerProvider);
    expect(c.text, 'Intro\n\nThe first section says hello.');
    expect(c.additionalParts, ['Garden\n\nThe second section shows the beds.']);
    expect(c.media, hasLength(1));
    expect(c.media.single.altText, 'Green beds');
    expect(c.partOfMedia(c.media.single.id), 1);
  });

  testWidgets('asks before replacing a post being written, and Cancel keeps it', (tester) async {
    final container = await _pumpComposer(tester);
    container.read(composerProvider.notifier).setText('Words I was writing');
    await tester.tap(find.text('Import'));
    await _settle(tester);
    await tester.tap(find.text('Make a thread'));
    await _settle(tester);

    expect(find.text('Replace the post you are writing?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await _settle(tester);
    expect(container.read(composerProvider).text, 'Words I was writing');
    expect(container.read(composerProvider).media, isEmpty);
  });
}
