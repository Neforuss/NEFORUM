// Downloads end to end, through the real engine: real outlines on disk, loaded
// with FontLoader, measured and drawn. The network is a MockClient.
//
// Set NEFORUM_FONT_FIXTURES to a folder of files really fetched from the
// services to also run the ones that cannot be committed: from jsDelivr
// fontsource/fonts/inter@5.3.0, saved as fs-inter-latin-400.ttf,
// fs-inter-latin-700.ttf, fs-inter-cyrillic-400.ttf and fs-inter-latin-400.woff2.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/media/caption_fonts.dart';
import 'package:neforum_app/media/caption_style.dart';
import 'package:neforum_app/media/card_design.dart';
import 'package:neforum_app/media/card_renderer.dart';
import 'package:neforum_app/media/card_templates.dart';
import 'package:neforum_app/media/font_catalog.dart';
import 'package:neforum_app/media/font_draw_check.dart';
import 'package:neforum_app/media/font_installer.dart';
import 'package:neforum_app/media/font_storage_io.dart' as files;
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/captioned_photos.dart';
import 'package:neforum_app/state/font_downloads.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/state/text_cards.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'font_fixtures.dart';

Future<AppStorage> _tempStorage() async {
  final dir = Directory.systemTemp.createTempSync('nf-font-install-');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // Still in use on Windows; the system cleans it up.
    }
  });
  return openAppStorage(overrideDir: dir.path);
}

double _width(String text, TextStyle style) {
  final tp = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)..layout();
  final w = tp.width;
  tp.dispose();
  return w;
}

void main() {
  tearDown(debugResetCaptionFonts);

  final interBytes = File(kInterRegular).readAsBytesSync();
  final interBoldBytes = File(kInterBold).readAsBytesSync();
  final interMediumBytes = File(kInterMedium).readAsBytesSync();
  final monoBytes = File(kMono).readAsBytesSync();

  /// A font with a Latin file in Inter and a Cyrillic file in JetBrains Mono,
  /// so it shows at a glance which file drew what: JetBrains Mono's advance is
  /// exactly 0.6 em.
  FakeFontServices servicesWithInter() {
    final fake = FakeFontServices();
    fake.details['inter'] = fontDetailFixture('inter', 'Inter', variants: {
      400: ['latin', 'cyrillic'],
      700: ['latin'],
    }, numbered: 2);
    fake.addFont('inter', '5.3.0', {
      'latin-400-normal.ttf': subsetOf(interBytes, isLatin),
      'latin-700-normal.ttf': subsetOf(interBoldBytes, isLatin),
      'cyrillic-400-normal.ttf': subsetOf(monoBytes, isCyrillic),
    });
    return fake;
  }

  Future<DownloadedFont> install(WidgetTester tester, AppStorage storage, FakeFontServices fake, String id, {void Function(FontInstallProgress)? onProgress}) async {
    final installer = FontInstaller(client: fake.client, dataDir: storage.dataDir, clock: () => DateTime.utc(2026, 11, 6));
    return (await tester.runAsync(() async => installer.install(await installer.plan(id), onProgress: onProgress)))!;
  }

  group('one-tap install', () {
    testWidgets('fetches pinned files only, keeps them with the licence, and draws each script from its own file', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final fake = servicesWithInter();
      final progress = <FontInstallProgress>[];
      final downloaded = await install(tester, storage, fake, 'inter', onProgress: progress.add);

      expect(fake.paths, [
        '/v1/fonts/inter',
        '/fontsource/fonts/inter@5.3.0/latin-400-normal.ttf',
        '/fontsource/fonts/inter@5.3.0/latin-700-normal.ttf',
        '/fontsource/fonts/inter@5.3.0/cyrillic-400-normal.ttf',
        '/npm/@fontsource/inter@5.3.0/LICENSE',
      ], reason: 'pinned URLs built here: the answer offered evil.example and numbered slices');
      expect(fake.requests.every((r) => r.url.host == 'api.fontsource.org' || r.url.host == 'cdn.jsdelivr.net'), isTrue);
      for (final r in fake.requests) {
        expect(r.url.hasQuery, isFalse, reason: 'no key in the address');
        expect(r.headers.keys.map((k) => k.toLowerCase()).toSet().difference({'user-agent'}), isEmpty, reason: 'no key, no account, nothing about the user: ${r.url}');
      }
      expect(downloaded.subsets, ['latin', 'cyrillic']);
      expect(downloaded.weights, [400, 700]);
      expect(progress.last.bytes, downloaded.totalBytes);

      final folder = '${files.catalogFontsDirectory(storage.dataDir)}/inter@5.3.0';
      expect(File('$folder/LICENSE').readAsStringSync(), kLicenseFixture, reason: 'the licence text is stored with the font');
      expect(jsonDecode(File('$folder/manifest.json').readAsStringSync())['license'], 'OFL-1.1');
      expect(File('$folder/latin-400-normal.ttf').lengthSync(), greaterThan(1000));

      final font = captionFontOf(downloaded);
      expect(font.path, isNull, reason: 'no per-user path goes into a synced style');
      expect(font.source!.sizeBytes, downloaded.totalBytes);
      expect((await tester.runAsync(() => prepareCaptionFont(storage, font)))!, isTrue);
      expect(captionFontSubsetAliases(font), ['${font.alias}/cyrillic']);

      final style = CaptionStyle(customFont: font).textStyle(TextCardFont.original, 100);
      expect(style.fontFamilyFallback!.first, '${font.alias}/cyrillic', reason: 'before any other font');
      expect(_width('Привет', style), closeTo(360, 2), reason: 'Cyrillic from the Cyrillic file: 6 x 0.6 em');
      final alone = _width('Привет', TextStyle(fontFamily: font.alias, fontSize: 100));
      expect(alone, isNot(closeTo(360, 2)), reason: 'without the chain, the Latin file has no Cyrillic');

      // The whole of Inter, to compare the Latin file with.
      const whole = CaptionFont(family: 'Whole Inter', fileId: 'whole.ttf');
      await tester.runAsync(() async {
        await files.saveImportedFont(storage.dataDir, 'whole.ttf', interBytes);
        await prepareCaptionFont(storage, whole);
      });
      final latin = _width('Hamburgefonts', style);
      expect(latin, closeTo(_width('Hamburgefonts', TextStyle(fontFamily: whole.alias, fontSize: 100)), 1), reason: 'Latin from the Latin file');
      expect(latin, isNot(closeTo(13 * 60, 2)), reason: 'not from the Cyrillic file');
      final bold = _width('Hamburgefonts', style.copyWith(fontWeight: FontWeight.w700));
      expect(bold, greaterThan(latin), reason: 'the bold file merged under the same name');
    });

    testWidgets('both the classic card and the designer draw through the chain', (tester) async {
      // Latin and Cyrillic of one font in two files against the whole font:
      // the pictures must be the same, down to the byte.
      final storage = (await tester.runAsync(_tempStorage))!;
      final fake = FakeFontServices();
      fake.details['mono'] = fontDetailFixture('mono', 'Split Mono', variants: {400: ['latin', 'cyrillic']});
      fake.addFont('mono', '5.3.0', {'latin-400-normal.ttf': subsetOf(monoBytes, isLatin), 'cyrillic-400-normal.ttf': subsetOf(monoBytes, isCyrillic)});
      final split = captionFontOf(await install(tester, storage, fake, 'mono'));
      const whole = CaptionFont(family: 'Whole Mono', fileId: 'whole.ttf');
      await tester.runAsync(() async {
        await files.saveImportedFont(storage.dataDir, 'whole.ttf', monoBytes);
        await prepareCaptionFont(storage, split);
        await prepareCaptionFont(storage, whole);
      });
      const words = 'Hello Привет';
      const size = Size(540, 675);
      Future<Uint8List> classic(CaptionFont f) async => (await tester.runAsync(() => renderTextCardJpeg(text: words, theme: TextCardTheme.light, size: size, customFont: f)))!;
      expect(await classic(split), await classic(whole));

      Future<Uint8List> designed(CaptionFont f) async {
        final template = cardTemplateById('neon')!.design(CardKind.text);
        final design = template.withBlock(0, (b) => b.copyWith(customFont: f));
        return (await tester.runAsync(() => renderCardDesign(CardRenderInput(design: design, size: size, texts: const {CardBlockRole.postText: words}), png: true)))!;
      }

      expect(await designed(split), await designed(whole));
    });

    testWidgets('adds weights to a font in use, of the version it has', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final fake = FakeFontServices();
      fake.details['inter'] = fontDetailFixture('inter', 'Inter', variants: {400: ['latin'], 500: ['latin'], 700: ['latin']});
      fake.addFont('inter', '5.3.0', {
        'latin-400-normal.ttf': subsetOf(interBytes, isLatin),
        'latin-500-normal.ttf': subsetOf(interMediumBytes, isLatin),
        'latin-700-normal.ttf': subsetOf(interBoldBytes, isLatin),
      });
      final downloaded = await install(tester, storage, fake, 'inter');
      expect(downloaded.weights, [400, 700], reason: 'an install takes two');
      final font = captionFontOf(downloaded);
      await tester.runAsync(() => prepareCaptionFont(storage, font));
      final before = _width('Hamburgefonts', TextStyle(fontFamily: font.alias, fontSize: 100, fontWeight: FontWeight.w500));

      final installer = FontInstaller(client: fake.client, dataDir: storage.dataDir);
      final (next, added) = (await tester.runAsync(() async => installer.addWeights(downloaded, await installer.detail('inter'), [500, 700])))!;
      expect(added.keys.map((f) => f.file), ['latin-500-normal.ttf'], reason: '700 is already here');
      expect(next.weights, [400, 500, 700]);
      expect((await tester.runAsync(() => listDownloadedFonts(storage.dataDir)))!.single.weights, [400, 500, 700], reason: 'on disk too');
      await tester.runAsync(() => registerAddedFontWeights(next, added));

      final after = _width('Hamburgefonts', TextStyle(fontFamily: font.alias, fontSize: 100, fontWeight: FontWeight.w500));
      expect(after, isNot(closeTo(before, 0.01)), reason: 'weight 500 now comes from its own file');
    });

    testWidgets('a big family says its size first; sizes only the big files', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final fake = FakeFontServices();
      fake.details['noto-sans-jp'] = fontDetailFixture('noto-sans-jp', 'Noto Sans JP', variants: {400: ['latin', 'japanese'], 700: ['latin', 'japanese']}, numbered: 120);
      fake.addFont('noto-sans-jp', '5.3.0', {
        'latin-400-normal.ttf': subsetOf(interBytes, isLatin),
        'latin-700-normal.ttf': subsetOf(interBoldBytes, isLatin),
        'japanese-400-normal.ttf': subsetOf(monoBytes, isCyrillic),
        'japanese-700-normal.ttf': subsetOf(monoBytes, isCyrillic),
      });
      fake.etags['noto-sans-jp@5.3.0/japanese-400-normal.ttf'] = 'W/"299ea4-a"';
      fake.etags['noto-sans-jp@5.3.0/japanese-700-normal.ttf'] = 'W/"299ea4-b"';
      final installer = FontInstaller(client: fake.client, dataDir: storage.dataDir);
      final plan = (await tester.runAsync(() => installer.plan('noto-sans-jp')))!;
      expect(plan.knownLargeBytes, 2727588 * 2);
      expect(plan.isLarge, isTrue);
      expect(fake.requests.where((r) => r.method == 'HEAD').map((r) => r.url.path.split('/').last), ['japanese-400-normal.ttf', 'japanese-700-normal.ttf']);
      expect(plan.files, hasLength(4), reason: 'no numbered slices');
    });
  });

  group('what is refused leaves nothing behind', () {
    Future<void> expectRefused(WidgetTester tester, AppStorage storage, FakeFontServices fake, String id, Matcher message) async {
      final installer = FontInstaller(client: fake.client, dataDir: storage.dataDir);
      Object? thrown;
      await tester.runAsync(() async {
        try {
          await installer.install(await installer.plan(id));
        } on Object catch (e) {
          thrown = e;
        }
      });
      expect(thrown, isA<FontDownloadException>());
      expect((thrown! as FontDownloadException).message, message);
      expect((await tester.runAsync(() => listDownloadedFonts(storage.dataDir)))!, isEmpty);
      final dir = Directory(files.catalogFontsDirectory(storage.dataDir)!);
      expect(dir.existsSync() ? dir.listSync() : const [], isEmpty, reason: 'not a file left');
    }

    FakeFontServices serving(Map<String, Uint8List> byFile, {String? license}) {
      final fake = FakeFontServices();
      fake.details['x'] = fontDetailFixture('x', 'X Sans', variants: {for (final f in byFile.keys) int.parse(RegExp(r'\d{3}').stringMatch(f)!): [f.split('-').first]});
      fake.addFont('x', '5.3.0', byFile, license: license ?? kLicenseFixture);
      return fake;
    }

    testWidgets('WOFF2 bytes under a .ttf name', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      await expectRefused(tester, storage, serving({'latin-400-normal.ttf': Uint8List.fromList([...'wOF2'.codeUnits, ...interBytes.skip(4)])}), 'x', contains('could not use the file'));
    });

    testWidgets('an error page with status 200', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      await expectRefused(tester, storage, serving({'latin-400-normal.ttf': Uint8List.fromList(utf8.encode('<html>Bad gateway</html>'))}), 'x', contains('could not use the file'));
    });

    testWidgets('a file cut short', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      await expectRefused(tester, storage, serving({'latin-400-normal.ttf': Uint8List.sublistView(interBytes, 0, interBytes.length ~/ 2)}), 'x', contains('could not use the file'));
    });

    testWidgets('a font that draws blank: loads, maps its characters, and draws nothing', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final blank = blankOutlinesOf(subsetOf(interBytes, isLatin));
      expect((await tester.runAsync(() => fontFileDraws(subsetOf(interBytes, isLatin))))!, isTrue);
      expect((await tester.runAsync(() => fontFileDraws(blank)))!, isFalse);
      await expectRefused(tester, storage, serving({'latin-400-normal.ttf': blank}), 'x', contains('cannot be drawn'));
    });

    testWidgets('the draw test asks for what the file maps: "Ag" would pass a blank Cyrillic font on its missing-glyph box', (tester) async {
      final blankCyrillic = blankExceptMissingGlyphOf(subsetOf(monoBytes, isCyrillic));
      expect((await tester.runAsync(() => fontFileDraws(blankCyrillic)))!, isFalse);
      expect((await tester.runAsync(() => fontFileDraws(subsetOf(monoBytes, isCyrillic))))!, isTrue, reason: 'the same font with its outlines');
    });

    testWidgets('a licence that cannot be fetched, or is an error page', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final noLicense = serving({'latin-400-normal.ttf': subsetOf(interBytes, isLatin)})..licenses.clear();
      await expectRefused(tester, storage, noLicense, 'x', contains('no longer has'));
      await expectRefused(tester, storage, serving({'latin-400-normal.ttf': subsetOf(interBytes, isLatin)}, license: '<html>Not found, sorry, try again later</html>'), 'x', contains('licence'));
    });

    testWidgets('a licence not on the list, whatever the list said', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final fake = FakeFontServices();
      fake.details['x'] = fontDetailFixture('x', 'X Sans', license: 'ITF-FFL', variants: {400: ['latin']});
      fake.addFont('x', '5.3.0', {'latin-400-normal.ttf': subsetOf(interBytes, isLatin)});
      final installer = FontInstaller(client: fake.client, dataDir: storage.dataDir);
      await tester.runAsync(() async {
        await expectLater(installer.plan('x'), throwsA(isA<FontDownloadException>().having((e) => e.message, 'message', contains('licence'))));
      });
      expect(fake.paths, ['/v1/fonts/x'], reason: 'not one file was fetched');
    });

    testWidgets('a blank second script is left out; the font stays and says what it has', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final fake = FakeFontServices();
      fake.details['x'] = fontDetailFixture('x', 'X Sans', variants: {400: ['latin', 'cyrillic']});
      fake.addFont('x', '5.3.0', {'latin-400-normal.ttf': subsetOf(interBytes, isLatin), 'cyrillic-400-normal.ttf': blankOutlinesOf(subsetOf(monoBytes, isCyrillic))});
      final downloaded = await install(tester, storage, fake, 'x');
      expect(downloaded.subsets, ['latin']);
      expect(downloaded.files.map((f) => f.file), ['latin-400-normal.ttf']);
      expect(File('${files.catalogFontsDirectory(storage.dataDir)}/x@5.3.0/cyrillic-400-normal.ttf').existsSync(), isFalse);
    });

    testWidgets('a cancelled download', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final fake = servicesWithInter();
      final installer = FontInstaller(client: fake.client, dataDir: storage.dataDir);
      final cancel = FontInstallCancel()..cancelled = true;
      await tester.runAsync(() async {
        await expectLater(installer.install(await installer.plan('inter'), cancel: cancel), throwsA(isA<FontInstallCancelled>()));
      });
      expect((await tester.runAsync(() => listDownloadedFonts(storage.dataDir)))!, isEmpty);
    });
  });

  group('with the network gone', () {
    testWidgets('an installed font loads and draws in a new run', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final fake = servicesWithInter();
      final font = captionFontOf(await install(tester, storage, fake, 'inter'));
      debugResetCaptionFonts();
      fake.offline = true;
      final calls = fake.requests.length;
      expect((await tester.runAsync(() => prepareCaptionFont(storage, font)))!, isTrue);
      expect(_width('Привет', CaptionStyle(customFont: font).textStyle(TextCardFont.original, 100)), closeTo(360, 2));
      expect(fake.requests.length, calls, reason: 'nothing tried the network');
    });

    testWidgets('a style that lost its source going through 1.3 still finds the font by name', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      await install(tester, storage, servicesWithInter(), 'inter');
      debugResetCaptionFonts();
      const old = CaptionFont(family: 'inter');
      expect((await tester.runAsync(() => prepareCaptionFont(storage, old)))!, isTrue);
    });

    testWidgets('a file changed on disk is not loaded, so it is offered again', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final font = captionFontOf(await install(tester, storage, servicesWithInter(), 'inter'));
      debugResetCaptionFonts();
      File('${files.catalogFontsDirectory(storage.dataDir)}/inter@5.3.0/latin-400-normal.ttf').writeAsBytesSync(monoBytes);
      File('${files.catalogFontsDirectory(storage.dataDir)}/inter@5.3.0/latin-700-normal.ttf').deleteSync();
      expect((await tester.runAsync(() => prepareCaptionFont(storage, font)))!, isFalse);
    });
  });

  group('a synced style on a device without the font', () {
    const missing = CaptionFont(family: 'Inter', source: CatalogFontSource(id: 'inter', version: '5.3.0', sizeBytes: 481216));

    testWidgets('renders the fallback with no network, offers it once, and cards regenerate after install', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final s = (await tester.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
      final instagram = (await tester.runAsync(() => s.accounts.all()))!.firstWhere((a) => a.platformId == 'instagram');
      final fake = servicesWithInter();
      final offers = <MissingFontOffer>[];
      final sub = missingFontOffers.listen(offers.add);
      addTearDown(sub.cancel);

      final at = DateTime(2026, 11, 6);
      var post = Post(id: 'p-synced', text: 'Scheduled on another device', targets: [PostTarget(accountId: instagram.id)], createdAt: at, updatedAt: at);
      const settings = AppSettings();
      final json = missing.toJson();
      await tester.runAsync(() async {
        post = await attachTextCards(s, post, settings, customFont: json);
        await Future<void>.delayed(Duration.zero);
      });
      final first = post.media.singleWhere(isRenderedTextCard);
      expect(first.renderParameters!['customFontFallback'], isTrue, reason: 'drawn in the default font, and marked');
      expect(fake.requests, isEmpty, reason: 'rendering never downloads');
      expect(offers.map((o) => (o.font, o.usage)), [(missing, 'the text card')], reason: 'offered, once');

      // Saved again, still without the font: the same card.
      await tester.runAsync(() async {
        post = await attachTextCards(s, post, settings, customFont: json);
        await Future<void>.delayed(Duration.zero);
      });
      expect(post.media.singleWhere(isRenderedTextCard).id, first.id);
      expect(offers, hasLength(1));

      await install(tester, storage, fake, 'inter');
      forgetDownloadedFont('Inter');
      await tester.runAsync(() async {
        post = await attachTextCards(s, post, settings, customFont: json);
        await Future<void>.delayed(Duration.zero);
      });
      final after = post.media.singleWhere(isRenderedTextCard);
      expect(after.id, isNot(first.id), reason: 'made again in the font');
      expect(after.renderParameters!.containsKey('customFontFallback'), isFalse);
    });

    testWidgets('a caption on a photo too', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final s = (await tester.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
      final tiktok = (await tester.runAsync(() => s.accounts.all()))!.firstWhere((a) => a.platformId == 'tiktok');
      final photo = (await tester.runAsync(() => s.media.importBytes(img.encodeJpg(img.Image(width: 300, height: 400)..clear(img.ColorRgb8(30, 90, 160))), fileName: 'p.jpg')))!;
      final at = DateTime(2026, 11, 6);
      var post = Post(id: 'p-caption', text: 'In the font', media: [photo], targets: [PostTarget(accountId: tiktok.id)], createdAt: at, updatedAt: at);
      final style = const CaptionStyle(customFont: missing).toJson();
      await tester.runAsync(() async {
        post = await attachCaptionedPhotos(s, post, s.settings, choices: const {'tiktok': true}, style: style);
        await Future<void>.delayed(Duration.zero);
      });
      final copy = post.media.singleWhere(isCaptionedCopy);
      expect(copy.renderParameters!['fontFallback'], isTrue);

      await install(tester, storage, servicesWithInter(), 'inter');
      await tester.runAsync(() async {
        post = await attachCaptionedPhotos(s, post.withTarget(PostTarget(accountId: tiktok.id)), s.settings, choices: const {'tiktok': true}, style: style);
        await Future<void>.delayed(Duration.zero);
      });
      final again = post.media.singleWhere(isCaptionedCopy);
      expect(again.id, isNot(copy.id));
      expect(again.renderParameters!.containsKey('fontFallback'), isFalse);
    });
  });

  group('after an install', () {
    const missing = CaptionFont(family: 'Inter', source: CatalogFontSource(id: 'inter', version: '5.3.0', sizeBytes: 481216));

    testWidgets('saved drafts and scheduled posts get their cards made again, with no save; others stay', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final s = (await tester.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
      final fake = servicesWithInter();
      final instagram = (await tester.runAsync(() => s.accounts.all()))!.firstWhere((a) => a.platformId == 'instagram');
      final at = DateTime(2026, 11, 6);
      Future<Post> saved(String id, PostStatus status) async {
        final bare = Post(id: id, text: 'Words of $id', status: status, targets: [PostTarget(accountId: instagram.id)], createdAt: at, updatedAt: at);
        final withCard = await attachTextCards(s, bare, const AppSettings(), customFont: missing.toJson());
        await s.posts.upsert(withCard);
        return withCard;
      }

      final draft = (await tester.runAsync(() => saved('p-draft', PostStatus.draft)))!;
      final scheduled = (await tester.runAsync(() => saved('p-scheduled', PostStatus.scheduled)))!;
      final out = (await tester.runAsync(() => saved('p-out', PostStatus.published)))!;
      final cardOf = {for (final p in [draft, scheduled, out]) p.id: p.media.singleWhere(isRenderedTextCard).id};
      expect(draft.media.single.renderParameters!['customFontFallback'], isTrue);

      final container = ProviderContainer(overrides: [
        servicesProvider.overrideWithValue(s),
        fontDownloadClientProvider.overrideWithValue(fake.client),
      ]);
      addTearDown(container.dispose);
      final n = container.read(fontDownloadsProvider.notifier);
      await tester.runAsync(() => n.setMode(FontDownloadMode.on));
      await tester.runAsync(() async => n.install(await n.plan('inter')));

      Future<MediaAttachment> card(String id) async => (await tester.runAsync(() => s.posts.get(id)))!.media.singleWhere(isRenderedTextCard);
      for (final id in ['p-draft', 'p-scheduled']) {
        final now = await card(id);
        expect(now.id, isNot(cardOf[id]), reason: id);
        expect(now.renderParameters!.containsKey('customFontFallback'), isFalse, reason: id);
        expect(now.renderParameters!['customFont']['source']['id'], 'inter', reason: 'the post keeps the choice it was saved with');
      }
      expect((await card('p-out')).id, cardOf['p-out'], reason: 'already out');
    });

    testWidgets('a post the platform already holds a copy of is left alone', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final s = (await tester.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
      final instagram = (await tester.runAsync(() => s.accounts.all()))!.firstWhere((a) => a.platformId == 'instagram');
      final at = DateTime(2026, 11, 6);
      final held = (await tester.runAsync(() async {
        final bare = Post(id: 'p-held', text: 'Held', status: PostStatus.scheduled, targets: [PostTarget(accountId: instagram.id, status: TargetStatus.heldByPlatform)], createdAt: at, updatedAt: at);
        final withCard = await attachTextCards(s, bare, const AppSettings(), customFont: missing.toJson());
        await s.posts.upsert(withCard);
        return withCard;
      }))!;
      expect(held.hasHeldTargets, isTrue);
      await install(tester, storage, servicesWithInter(), 'inter');
      expect((await tester.runAsync(() => remakePicturesDrawnWithout(s, 'Inter')))!, 0);
    });
  });

  group('the one door to the network', () {
    Future<(ProviderContainer, AppServices)> containerWith(WidgetTester tester, FakeFontServices fake, AppStorage storage) async {
      final s = (await tester.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
      final container = ProviderContainer(overrides: [servicesProvider.overrideWithValue(s), fontDownloadClientProvider.overrideWithValue(fake.client)]);
      addTearDown(container.dispose);
      return (container, s);
    }

    testWidgets('nothing goes out before the user says yes, whatever is asked', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final fake = FakeFontServices()..offline = true;
      final (container, _) = await containerWith(tester, fake, storage);
      final n = container.read(fontDownloadsProvider.notifier);
      expect(container.read(settingsProvider).fontDownloads, FontDownloadMode.ask);
      await tester.runAsync(() async {
        await n.openCatalog();
        await n.openCatalog(refresh: true);
        await n.requestPreview(FontCatalogEntry.tryParse(fontListFixture()[1])!);
      });
      expect(() => n.plan('inter'), throwsStateError);
      expect(() => n.detail('inter'), throwsStateError);
      expect(fake.requests, isEmpty);
      expect(container.read(fontDownloadsProvider).catalog, isNull);

      await tester.runAsync(() => n.setMode(FontDownloadMode.off));
      await tester.runAsync(() async {
        await n.openCatalog();
        await n.requestPreview(FontCatalogEntry.tryParse(fontListFixture()[1])!);
      });
      expect(() => n.plan('inter'), throwsStateError);
      expect(fake.requests, isEmpty);
    });

    testWidgets('previews are one file each, kept, gated, at most 20 a minute', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final fake = FakeFontServices();
      final (container, _) = await containerWith(tester, fake, storage);
      final n = container.read(fontDownloadsProvider.notifier);
      await tester.runAsync(() => n.setMode(FontDownloadMode.on));
      final latin = subsetOf(interBytes, isLatin);
      FontCatalogEntry entry(String id) => FontCatalogEntry.tryParse({'id': id, 'family': id, 'category': 'serif', 'license': 'mit', 'subsets': ['latin'], 'weights': [400]})!;
      for (var i = 0; i < 25; i++) {
        fake.files['f$i@latest/latin-400-normal.ttf'] = latin;
      }
      fake.files['bad@latest/latin-400-normal.ttf'] = Uint8List.fromList(utf8.encode('<html></html>'));
      await tester.runAsync(() async {
        await n.requestPreview(entry('bad'));
        for (var i = 0; i < 25; i++) {
          await n.requestPreview(entry('f$i'));
        }
      });
      expect(fake.requests.where((r) => r.url.path.contains('@latest/')), hasLength(20), reason: 'the 21st waits');
      expect(container.read(fontDownloadsProvider).previews.containsKey('bad'), isFalse, reason: 'not a font: never loaded');
      expect(container.read(fontDownloadsProvider).previews.length, 19);
      expect(File('${files.fontPreviewsDirectory(storage.dataDir)}/f0.ttf').existsSync(), isTrue);
      expect(File('${files.fontPreviewsDirectory(storage.dataDir)}/bad.ttf').existsSync(), isFalse);
    });

    testWidgets('Delete everything removes the fonts, the saved list and the previews, and asks again', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final fake = servicesWithInter();
      final (container, _) = await containerWith(tester, fake, storage);
      final n = container.read(fontDownloadsProvider.notifier);
      await tester.runAsync(() => n.setMode(FontDownloadMode.on));
      await tester.runAsync(() async {
        await n.openCatalog();
        await n.install(await n.plan('inter'));
        await files.saveFontPreview(storage.dataDir, 'lobster', subsetOf(interBytes, isLatin));
        await files.saveImportedFont(storage.dataDir, 'mine.ttf', monoBytes);
      });
      final data = storage.dataDir!;
      expect(File('$data/$kFontCatalogFile').existsSync(), isTrue);
      expect(Directory(files.catalogFontsDirectory(data)!).listSync(), isNotEmpty);
      expect(Directory(files.fontPreviewsDirectory(data)!).listSync(), isNotEmpty);
      const font = CaptionFont(family: 'Inter');
      expect(registeredCaptionFontAlias(font), isNotNull);

      await tester.runAsync(n.deleteAll);

      expect(File('$data/$kFontCatalogFile').existsSync(), isFalse);
      expect(Directory(files.catalogFontsDirectory(data)!).existsSync(), isFalse);
      expect(Directory(files.fontPreviewsDirectory(data)!).existsSync(), isFalse);
      expect(File('$data/fonts/mine.ttf').existsSync(), isTrue, reason: "an imported file is the user's own");
      expect(registeredCaptionFontAlias(font), isNull, reason: 'styles naming it draw the default font again');
      expect(captionFontSubsetAliases(font), isEmpty);
      expect(container.read(settingsProvider).fontDownloads, FontDownloadMode.ask);
      expect(container.read(fontDownloadsProvider).catalog, isNull);
      await tester.runAsync(() async => expect(await container.read(downloadedFontsProvider.future), isEmpty));
    });
  });

  // Files really fetched from the services, which cannot be committed.
  final fixtures = Platform.environment['NEFORUM_FONT_FIXTURES'];
  group('real files from the services', () {
    Uint8List real(String name) => File('$fixtures/$name').readAsBytesSync();

    testWidgets('Fontsource Latin and Cyrillic subsets draw through the chain', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final fake = FakeFontServices();
      fake.details['inter'] = fontDetailFixture('inter', 'Inter', variants: {400: ['latin', 'cyrillic'], 700: ['latin']});
      fake.addFont('inter', '5.3.0', {'latin-400-normal.ttf': real('fs-inter-latin-400.ttf'), 'latin-700-normal.ttf': real('fs-inter-latin-700.ttf'), 'cyrillic-400-normal.ttf': real('fs-inter-cyrillic-400.ttf')});
      final font = captionFontOf(await install(tester, storage, fake, 'inter'));
      await tester.runAsync(() => prepareCaptionFont(storage, font));
      final style = CaptionStyle(customFont: font).textStyle(TextCardFont.original, 100);
      expect(_width('Hamburgefonts', style), greaterThan(0));
      expect(_width('Привет', style), closeTo(_width('Привет', TextStyle(fontFamily: '${font.alias}/cyrillic', fontSize: 100)), 1));
    });

    testWidgets('a real WOFF2 is refused', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final fake = FakeFontServices();
      fake.details['inter'] = fontDetailFixture('inter', 'Inter', variants: {400: ['latin']});
      fake.addFont('inter', '5.3.0', {'latin-400-normal.ttf': real('fs-inter-latin-400.woff2')});
      final installer = FontInstaller(client: fake.client, dataDir: storage.dataDir);
      await tester.runAsync(() async {
        await expectLater(installer.install(await installer.plan('inter')), throwsA(isA<FontDownloadException>()));
      });
    });
  }, skip: fixtures == null ? 'Set NEFORUM_FONT_FIXTURES to run the files that cannot be committed' : null);
}
