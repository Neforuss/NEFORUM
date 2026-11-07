// Font downloads on the real desktop engine, the way NEFORUM ships. The two
// font services are a server on this computer, reached by the real HTTP client;
// nothing goes to the real services. What is checked is what only the real
// engine can tell: which file really draws a script, and that a file that
// draws nothing is refused.
//
//   flutter drive --profile -d windows --driver=test_driver/integration_test.dart --target=integration_test/font_downloads_test.dart
//
// With NEFORUM_FONT_FIXTURES set to a folder holding gf-notocoloremoji.ttf (the
// COLRv1 Noto Color Emoji of github.com/google/fonts, 25 MB, too big to commit)
// and fs-inter-latin-400.woff2, those real files go through the same gates.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:neforum_app/media/caption_fonts.dart';
import 'package:neforum_app/media/caption_style.dart';
import 'package:neforum_app/media/font_catalog.dart';
import 'package:neforum_app/media/font_draw_check.dart';
import 'package:neforum_app/media/font_files.dart';
import 'package:neforum_app/media/font_installer.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/platform/desktop.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/font_downloads.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/font_picker_sheet.dart';

import '../test/font_fixtures.dart';

Future<Uint8List> _asset(String path) async => (await rootBundle.load(path)).buffer.asUint8List();

double _width(String text, TextStyle style) {
  final tp = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)..layout();
  final w = tp.width;
  tp.dispose();
  return w;
}

/// The two services on a local port. Sends the files in small pieces, gzipped
/// where the client asks, as a CDN does.
class _LocalServices {
  _LocalServices(this.server, this.routes);
  final HttpServer server;
  final Map<String, List<int>> routes;
  final List<String> asked = [];

  static Future<_LocalServices> start(Map<String, List<int>> routes) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final services = _LocalServices(server, routes);
    server.listen((request) async {
      services.asked.add(request.uri.path);
      final body = routes[request.uri.path];
      if (body == null) {
        request.response.statusCode = 404;
      } else {
        request.response.headers.contentType = ContentType.binary;
        final accepts = request.headers.value(HttpHeaders.acceptEncodingHeader) ?? '';
        final out = accepts.contains('gzip') ? gzip.encode(body) : body;
        if (accepts.contains('gzip')) request.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
        for (var i = 0; i < out.length; i += 16384) {
          request.response.add(out.sublist(i, i + 16384 > out.length ? out.length : i + 16384));
          await request.response.flush();
        }
      }
      await request.response.close();
    });
    return services;
  }

  String get _base => 'http://${server.address.address}:${server.port}';

  FontEndpoints get endpoints => FontEndpoints(api: '$_base/v1/fonts', files: '$_base/fontsource/fonts', packages: '$_base/npm/@fontsource');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('search, one-tap install, the subset chain and the draw test on the real engine', (tester) async {
    final dir = await Directory.systemTemp.createTemp('neforum-fonts-');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Windows may still hold a file open; the OS cleans temp later.
      }
    });
    await DesktopIntegration.instance.initWindow();

    final interBytes = await _asset(kInterRegular);
    final boldBytes = await _asset(kInterBold);
    final monoBytes = await _asset(kMono);
    List<int> json(Object? o) => utf8.encode(jsonEncode(o));

    final latin = subsetOf(interBytes, isLatin);
    final cyrillic = subsetOf(monoBytes, isCyrillic);
    final services = await _LocalServices.start({
      '/v1/fonts': json(fontListFixture()),
      '/v1/fonts/inter': json(fontDetailFixture('inter', 'Inter', variants: {
        400: ['latin', 'cyrillic'],
        700: ['latin'],
      }, numbered: 3)),
      '/fontsource/fonts/inter@5.3.0/latin-400-normal.ttf': latin,
      '/fontsource/fonts/inter@5.3.0/latin-700-normal.ttf': subsetOf(boldBytes, isLatin),
      '/fontsource/fonts/inter@5.3.0/cyrillic-400-normal.ttf': cyrillic,
      '/npm/@fontsource/inter@5.3.0/LICENSE': utf8.encode(kLicenseFixture),
      '/v1/fonts/blank': json(fontDetailFixture('blank', 'Blank Sans', variants: {400: ['latin']})),
      '/fontsource/fonts/blank@5.3.0/latin-400-normal.ttf': blankOutlinesOf(latin),
      '/npm/@fontsource/blank@5.3.0/LICENSE': utf8.encode(kLicenseFixture),
      '/v1/fonts/webfont': json(fontDetailFixture('webfont', 'Web Font', variants: {400: ['latin']})),
      '/fontsource/fonts/webfont@5.3.0/latin-400-normal.ttf': [...'wOF2'.codeUnits, ...latin.skip(4)],
      '/npm/@fontsource/webfont@5.3.0/LICENSE': utf8.encode(kLicenseFixture),
    });
    addTearDown(() => services.server.close(force: true));

    final storage = await openAppStorage(overrideDir: dir.path);
    await storage.writeJson('settings.json', {'fontDownloads': 'on', 'onboarded': true});
    final s = await AppServices.create(demo: true, storage: storage);
    final client = http.Client();
    addTearDown(client.close);
    debugInstalledFontCatalog = InstalledFontCatalog.empty;
    addTearDown(debugResetCaptionFonts);

    FontChoice? picked;
    var closed = false;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        servicesProvider.overrideWithValue(s),
        fontDownloadClientProvider.overrideWithValue(client),
        fontEndpointsProvider.overrideWithValue(services.endpoints),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await showFontChoiceSheet(context, current: const FontChoice(TextCardFont.original), platformId: 'instagram');
                closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    Future<void> pumpUntil(bool Function() done, String what) async {
      for (var i = 0; i < 600 && !done(); i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(done(), isTrue, reason: 'waited for $what');
    }

    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('open'));
    await pumpUntil(() => find.byKey(const Key('font-search')).evaluate().isNotEmpty, 'the picker');
    await pumpUntil(() => services.asked.contains('/v1/fonts'), 'the list to be asked for');
    await tester.enterText(find.byKey(const Key('font-search')), 'inter');
    await pumpUntil(() => find.byKey(const ValueKey('font-catalog-inter')).evaluate().isNotEmpty, 'the search to find it');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('font-catalog-inter')));
    await pumpUntil(() => closed, 'one tap to install it and return it');

    final font = picked!.customFont!;
    stdout.writeln('U5 installed family=${font.family} id=${font.source?.id} version=${font.source?.version} bytes=${font.source?.sizeBytes}');
    stdout.writeln('U5 asked=${services.asked.join(' ')}');
    expect(font.source!.id, 'inter');
    expect(services.asked.where((p) => RegExp(r'/\d+-').hasMatch(p)), isEmpty, reason: 'no numbered slices');
    expect(captionFontSubsetAliases(font), ['${font.alias}/cyrillic']);

    final style = CaptionStyle(customFont: font).textStyle(TextCardFont.original, 100);
    final viaChain = _width('Привет', style);
    final alone = _width('Привет', TextStyle(fontFamily: font.alias, fontSize: 100));
    final latinWidth = _width('Hamburgefonts', style);
    final boldWidth = _width('Hamburgefonts', style.copyWith(fontWeight: FontWeight.w700));
    stdout.writeln('U5 widths cyrillicViaChain=$viaChain cyrillicAlone=$alone latin=$latinWidth bold=$boldWidth');
    expect(viaChain, closeTo(360, 2), reason: 'Cyrillic drawn by the Cyrillic file: 6 x 0.6 em');
    expect(alone, isNot(closeTo(360, 2)));
    expect(boldWidth, greaterThan(latinWidth), reason: 'weights of a subset merge under one name');

    // A second run of NEFORUM with the network gone.
    await services.server.close(force: true);
    debugResetCaptionFonts();
    debugInstalledFontCatalog = InstalledFontCatalog.empty;
    expect(await prepareCaptionFont(storage, font), isTrue, reason: 'installed fonts need no network');
    expect(_width('Привет', CaptionStyle(customFont: font).textStyle(TextCardFont.original, 100)), closeTo(360, 2));

    final card = await renderTextCardJpeg(text: 'Hello Привет', theme: TextCardTheme.light, size: const Size(540, 675), customFont: font);
    stdout.writeln('U5 card bytes=${card.length}');
    expect(card.length, greaterThan(1000));

    // The draw test, on this engine.
    expect(await fontFileDraws(latin), isTrue);
    expect(await fontFileDraws(cyrillic), isTrue, reason: 'it samples what the file maps, not "Ag"');
    expect(await fontFileDraws(blankOutlinesOf(latin)), isFalse);

    final fixtures = Platform.environment['NEFORUM_FONT_FIXTURES'];
    if (fixtures != null) {
      final emoji = File('$fixtures/gf-notocoloremoji.ttf');
      final woff2 = File('$fixtures/fs-inter-latin-400.woff2');
      if (emoji.existsSync()) {
        final bytes = emoji.readAsBytesSync();
        final whole = isWholeFontFile(bytes);
        final draws = await fontFileDraws(bytes);
        stdout.writeln('U5 real NotoColorEmoji whole=$whole draws=$draws sample=${fontSampleCodePoints(bytes).map((c) => c.toRadixString(16)).join(',')}');
      }
      if (woff2.existsSync()) {
        final whole = isWholeFontFile(woff2.readAsBytesSync());
        stdout.writeln('U5 real WOFF2 whole=$whole');
        expect(whole, isFalse);
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a blank font and a WOFF2 are refused through the real client, leaving nothing', (tester) async {
    final dir = await Directory.systemTemp.createTemp('neforum-fonts-');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Windows may still hold a file open; the OS cleans temp later.
      }
    });
    final interBytes = await _asset(kInterRegular);
    final latin = subsetOf(interBytes, isLatin);
    List<int> json(Object? o) => utf8.encode(jsonEncode(o));
    final services = await _LocalServices.start({
      '/v1/fonts/blank': json(fontDetailFixture('blank', 'Blank Sans', variants: {400: ['latin']})),
      '/fontsource/fonts/blank@5.3.0/latin-400-normal.ttf': blankOutlinesOf(latin),
      '/npm/@fontsource/blank@5.3.0/LICENSE': utf8.encode(kLicenseFixture),
      '/v1/fonts/webfont': json(fontDetailFixture('webfont', 'Web Font', variants: {400: ['latin']})),
      '/fontsource/fonts/webfont@5.3.0/latin-400-normal.ttf': [...'wOF2'.codeUnits, ...latin.skip(4)],
      '/npm/@fontsource/webfont@5.3.0/LICENSE': utf8.encode(kLicenseFixture),
    });
    addTearDown(() => services.server.close(force: true));
    final client = http.Client();
    addTearDown(client.close);
    final installer = FontInstaller(client: client, dataDir: dir.path, endpoints: services.endpoints);
    for (final id in ['blank', 'webfont']) {
      Object? thrown;
      try {
        await installer.install(await installer.plan(id));
      } on FontDownloadException catch (e) {
        thrown = e;
      }
      stdout.writeln('U5 refused $id: $thrown');
      expect(thrown, isA<FontDownloadException>());
      expect(await listDownloadedFonts(dir.path), isEmpty);
    }
    expect(Fonts.body, isNotEmpty);
  });
}
