import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/media/caption_fonts.dart';
import 'package:neforum_app/media/caption_style.dart';
import 'package:neforum_app/media/font_files.dart';
import 'package:neforum_app/media/font_storage_io.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/captioned_photos.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/render_warnings.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/font_picker_sheet.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

// ---------------------------------------------------------------------------
// Synthetic font files: just enough of the sfnt structure for the 'name' and
// 'OS/2' tables.
// ---------------------------------------------------------------------------

/// A 'name' table: records of (platform, encoding, language, name id, bytes).
Uint8List _nameTable(List<(int, int, int, int, List<int>)> records) {
  final header = 6 + records.length * 12;
  final b = BytesBuilder();
  final strings = BytesBuilder();
  final h = ByteData(header)
    ..setUint16(0, 0)
    ..setUint16(2, records.length)
    ..setUint16(4, header);
  for (var i = 0; i < records.length; i++) {
    final (platform, encoding, language, id, bytes) = records[i];
    final r = 6 + i * 12;
    h
      ..setUint16(r, platform)
      ..setUint16(r + 2, encoding)
      ..setUint16(r + 4, language)
      ..setUint16(r + 6, id)
      ..setUint16(r + 8, bytes.length)
      ..setUint16(r + 10, strings.length);
    strings.add(bytes);
  }
  b
    ..add(h.buffer.asUint8List())
    ..add(strings.takeBytes());
  return b.takeBytes();
}

List<int> _utf16(String s) => [for (final c in s.codeUnits) ...[c >> 8, c & 0xFF]];

(int, int, int, int, List<int>) _win(int id, String s, {int language = 0x409}) => (3, 1, language, id, _utf16(s));

Uint8List _os2({int weight = 400, bool italic = false}) {
  final d = ByteData(78)
    ..setUint16(4, weight)
    ..setUint16(62, italic ? 1 : 0x40);
  return d.buffer.asUint8List();
}

/// The tables of one face: tag -> bytes.
Map<String, Uint8List> _faceTables(String family, {String subfamily = 'Regular', int weight = 400, bool italic = false, String? typographic}) => {
      'name': _nameTable([
        _win(1, family),
        _win(2, subfamily),
        if (typographic != null) _win(16, typographic),
        (3, 1, 0x407, 1, _utf16('Deutsch $family')),
      ]),
      'OS/2': _os2(weight: weight, italic: italic),
    };

int _tag(String t) => t.codeUnits.fold(0, (a, c) => a << 8 | c);

/// Writes a face's offset table at [at] (table data placed from [dataAt]);
/// returns the bytes of the offset table and of the data.
(Uint8List, Uint8List) _layoutFace(Map<String, Uint8List> tables, int dataAt) {
  final n = tables.length;
  final dir = ByteData(12 + n * 16)
    ..setUint32(0, 0x00010000)
    ..setUint16(4, n);
  final data = BytesBuilder();
  var i = 0;
  for (final e in tables.entries) {
    final r = 12 + i * 16;
    dir
      ..setUint32(r, _tag(e.key))
      ..setUint32(r + 4, 0)
      ..setUint32(r + 8, dataAt + data.length)
      ..setUint32(r + 12, e.value.length);
    data.add(e.value);
    while (data.length % 4 != 0) {
      data.addByte(0);
    }
    i++;
  }
  return (dir.buffer.asUint8List(), data.takeBytes());
}

Uint8List _font(Map<String, Uint8List> tables) {
  final (dir, data) = _layoutFace(tables, 12 + tables.length * 16);
  return Uint8List.fromList([...dir, ...data]);
}

Uint8List _collection(List<Map<String, Uint8List>> faces) {
  final header = 12 + faces.length * 4;
  final dirs = <Uint8List>[];
  final datas = <Uint8List>[];
  final offsets = <int>[];
  var dirAt = header;
  for (final f in faces) {
    offsets.add(dirAt);
    dirAt += 12 + f.length * 16;
  }
  var dataAt = dirAt;
  for (final f in faces) {
    final (dir, data) = _layoutFace(f, dataAt);
    dirs.add(dir);
    datas.add(data);
    dataAt += data.length;
  }
  final h = ByteData(header)
    ..setUint32(0, _tag('ttcf'))
    ..setUint32(4, 0x00010000)
    ..setUint32(8, faces.length);
  for (var i = 0; i < faces.length; i++) {
    h.setUint32(12 + i * 4, offsets[i]);
  }
  return Uint8List.fromList([...h.buffer.asUint8List(), for (final d in dirs) ...d, for (final d in datas) ...d]);
}

const String _monoPath = 'assets/fonts/JetBrainsMono-Regular.ttf';

Future<AppStorage> _tempStorage() async {
  final dir = Directory.systemTemp.createTempSync('nf-fonts-');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // Still in use on Windows; the system cleans it up.
    }
  });
  return openAppStorage(overrideDir: dir.path);
}

void main() {
  tearDown(debugResetCaptionFonts);

  group('font files', () {
    test('reads the family, style, weight and slant of a font', () {
      final faces = readFontFacesFromBytes(_font(_faceTables('Fira Sans', subfamily: 'Bold Italic', weight: 700, italic: true)));
      expect(faces, [const FontFace(family: 'Fira Sans', subfamily: 'Bold Italic', weight: 700, italic: true)]);
    });

    test('prefers the typographic family and US English names', () {
      final faces = readFontFacesFromBytes(_font(_faceTables('Fira Sans Light', subfamily: 'Regular', weight: 300, typographic: 'Fira Sans')));
      expect(faces.single.family, 'Fira Sans');
      expect(faces.single.weight, 300);
    });

    test('reads Mac Roman names when there is nothing else', () {
      final faces = readFontFacesFromBytes(_font({
        'name': _nameTable([(1, 0, 0, 1, ascii.encode('Old Mac Face')), (1, 0, 0, 2, ascii.encode('Italic'))]),
      }));
      expect(faces.single.family, 'Old Mac Face');
      expect(faces.single.italic, isTrue, reason: 'from the style name, without an OS/2 table');
    });

    test("leaves out macOS's hidden system faces", () {
      expect(readFontFacesFromBytes(_font(_faceTables('.SF NS'))), isEmpty);
    });

    test('reads every face of a collection, and takes one out as a font of its own', () {
      final ttc = _collection([_faceTables('Collection Sans'), _faceTables('Collection Serif', subfamily: 'Bold', weight: 700)]);
      final faces = readFontFacesFromBytes(ttc);
      expect(faces.map((f) => (f.family, f.index)), [('Collection Sans', 0), ('Collection Serif', 1)]);

      final second = extractFontFace(ttc, 1)!;
      final alone = readFontFacesFromBytes(second);
      expect(alone.single.family, 'Collection Serif');
      expect(alone.single.index, 0);
      expect(alone.single.weight, 700);
      expect(extractFontFace(ttc, 2), isNull);
      final single = _font(_faceTables('Plain'));
      expect(identical(extractFontFace(single, 0), single), isTrue, reason: 'a plain font is already one face');
    });

    test('never throws on files that are not fonts, or cut short', () {
      final rnd = math.Random(7);
      for (var i = 0; i < 200; i++) {
        final junk = Uint8List.fromList(List.generate(rnd.nextInt(400), (_) => rnd.nextInt(256)));
        expect(readFontFacesFromBytes(junk), isEmpty);
        expect(extractFontFace(junk, 0), isNull);
      }
      final good = _font(_faceTables('Cut Sans'));
      for (var n = 0; n < good.length; n += 3) {
        expect(() => readFontFacesFromBytes(Uint8List.sublistView(good, 0, n)), returnsNormally);
      }
      final ttc = _collection([_faceTables('A'), _faceTables('B')]);
      for (var n = 0; n < ttc.length; n += 5) {
        final cut = Uint8List.sublistView(ttc, 0, n);
        expect(() => readFontFacesFromBytes(cut), returnsNormally);
        expect(() => extractFontFace(cut, 1), returnsNormally);
      }
      // A table directory that claims tables beyond the end of the file.
      final lying = Uint8List.fromList(good);
      ByteData.sublistView(lying).setUint32(12 + 8, 0x7FFFFFF0);
      expect(readFontFacesFromBytes(lying), isEmpty);
    });

    test('reads a real font file', () {
      final faces = readFontFacesFromBytes(File(_monoPath).readAsBytesSync());
      expect(faces.single.family, 'JetBrains Mono');
      expect(faces.single.weight, 400);
      expect(faces.single.italic, isFalse);
    });

    test('picks the regular and the bold face of a family', () {
      const faces = [
        FontFace(family: 'F', subfamily: 'Light', weight: 300),
        FontFace(family: 'F', subfamily: 'Italic', italic: true),
        FontFace(family: 'F', subfamily: 'Book', weight: 450),
        FontFace(family: 'F', subfamily: 'Black', weight: 900),
        FontFace(family: 'F', subfamily: 'Bold', weight: 700),
      ];
      expect(regularFaceOf(faces)!.subfamily, 'Book');
      expect(boldFaceOf(faces)!.subfamily, 'Bold');
      expect(boldFaceOf(faces.take(3)), isNull);
      expect(regularFaceOf(const [FontFace(family: 'F', italic: true)])!.italic, isTrue, reason: 'an italic face when there is nothing else');
    });

    test('scans folders, skips what is not a font and reuses unchanged files', () {
      final dir = Directory.systemTemp.createTempSync('nf-scan-');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(_monoPath).copySync('${dir.path}/mono.ttf');
      Directory('${dir.path}/nested').createSync();
      File('${dir.path}/nested/coll.ttc').writeAsBytesSync(_collection([_faceTables('Nested One'), _faceTables('Nested Two')]));
      File('${dir.path}/broken.otf').writeAsBytesSync([1, 2, 3]);
      File('${dir.path}/readme.txt').writeAsStringSync('not a font');

      final first = scanFontDirectories(FontScanJob(directories: [dir.path, '${dir.path}/missing']));
      expect(first, hasLength(3));
      final catalog = InstalledFontCatalog.fromEntries(first);
      expect(catalog.families.keys, ['JetBrains Mono', 'Nested One', 'Nested Two']);
      expect(catalog.facesOf('nested two').single.face.index, 1);

      final again = scanFontDirectories(FontScanJob(directories: [dir.path], previous: {for (final e in first) e['path'] as String: e}));
      for (final e in again) {
        expect(first.any((f) => identical(f, e)), isTrue, reason: '${e['path']} was not read again');
      }
      expect(jsonDecode(jsonEncode(first)), first, reason: 'the cache is plain JSON');
    });
  });

  group('caption style with a font of its own', () {
    const font = CaptionFont(family: 'JetBrains Mono', path: r'C:\Windows\Fonts\JetBrainsMono-Regular.ttf');

    test('older styles read and write as before', () {
      final old = const CaptionStyle(font: TextCardFont.arial, bold: true).toJson();
      expect(old.containsKey('customFont'), isFalse);
      final read = CaptionStyle.fromJson(old);
      expect(read.customFont, isNull);
      expect(read.toJson(), old);
      expect(CaptionStyle.fromJson(const {'customFont': 'nonsense'}).customFont, isNull);
      expect(CaptionStyle.fromJson(const {'customFont': {'family': ' '}}).customFont, isNull);
    });

    test('round-trips the family and where it came from', () {
      const style = CaptionStyle(customFont: font);
      expect(CaptionStyle.fromJson(jsonDecode(jsonEncode(style.toJson())) as Map<String, dynamic>), style);
      const imported = CaptionFont(family: 'Mine', fileId: 'abc.otf');
      expect(CaptionFont.tryParse(imported.toJson()), imported);
      expect(style.copyWith(clearCustomFont: true), const CaptionStyle());
      expect(style == const CaptionStyle(), isFalse);
    });

    test('draws the built-in font until the chosen one is loaded, then that one with fallbacks', () {
      const style = CaptionStyle(customFont: font, bold: true);
      final resolved = TextCardFont.tiktokSans;
      final before = style.textStyle(resolved, 60);
      expect(before, const CaptionStyle(bold: true).textStyle(resolved, 60), reason: 'missing: exactly the default');

      debugMarkCaptionFontRegistered(font);
      final after = style.textStyle(resolved, 60);
      expect(after.fontFamily, font.alias);
      expect(after.fontWeight, FontWeight.w800);
      expect(after.fontVariations, isNull, reason: "TikTok Sans's axis is not sent to another font");
      expect(after.fontFamilyFallback, containsAllInOrder(['TikTok Sans', 'Segoe UI Emoji', 'Apple Color Emoji', 'Noto Color Emoji']));
    });
  });

  group('loading', () {
    testWidgets('loads an installed family by name when its file is elsewhere, and draws it', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      final dir = Directory(storage.dataDir!);
      final mono = File(_monoPath).copySync('${dir.path}/elsewhere.ttf');
      debugInstalledFontCatalog = InstalledFontCatalog.fromEntries([
        {'path': mono.path, 'faces': [const FontFace(family: 'JetBrains Mono').toJson()]},
      ]);
      const font = CaptionFont(family: 'JetBrains Mono', path: '/Library/Fonts/NotHere.ttf');
      final revision = captionFontsRevision.value;
      expect((await tester.runAsync(() => prepareCaptionFont(storage, font)))!, isTrue);
      expect(registeredCaptionFontAlias(font), font.alias);
      expect(captionFontsRevision.value, greaterThan(revision), reason: 'previews repaint');

      // JetBrains Mono's advance is 0.6 em; the test font's squares are 1 em.
      double width(TextStyle s) {
        final tp = TextPainter(text: TextSpan(text: 'Hello', style: s), textDirection: TextDirection.ltr)..layout();
        final w = tp.width;
        tp.dispose();
        return w;
      }

      final drawn = width(const CaptionStyle(customFont: font).textStyle(TextCardFont.original, 100));
      expect(drawn, closeTo(300, 2));
    });

    testWidgets('a font that is nowhere on this device is not loaded', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      debugInstalledFontCatalog = InstalledFontCatalog.empty;
      const font = CaptionFont(family: 'Nowhere Sans', path: '/no/such/font.ttf', fileId: 'gone.ttf');
      expect((await tester.runAsync(() => prepareCaptionFont(storage, font)))!, isFalse);
      expect(registeredCaptionFontAlias(font), isNull);
    });

    testWidgets('imports a font file into the data folder, and refuses anything else', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      await tester.runAsync(() async {
        await expectLater(importCaptionFont(storage, 'notes.ttf', Uint8List.fromList(utf8.encode('hello'))), throwsA(isA<FontImportException>()));
        await expectLater(importCaptionFont(storage, 'mono.png', File(_monoPath).readAsBytesSync()), throwsA(isA<FontImportException>()));
        final font = await importCaptionFont(storage, 'JetBrainsMono-Regular.ttf', File(_monoPath).readAsBytesSync());
        expect(font.family, 'JetBrains Mono');
        expect(font.fileId, endsWith('.ttf'));
        expect(File(importedFontPath(storage.dataDir, font.fileId!)!).existsSync(), isTrue);
        final listed = await loadImportedFonts(storage);
        expect(listed.single.font, font);
        expect(importedFontPath(storage.dataDir, '../settings.json'), isNull, reason: 'an id is a plain file name');
      });
    });

    testWidgets('the picker lists built-in and installed fonts, searches, and returns the choice', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final storage = (await tester.runAsync(_tempStorage))!;
      final s = (await tester.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
      final mono = File(_monoPath).absolute.path;
      debugInstalledFontCatalog = InstalledFontCatalog.fromEntries([
        {'path': mono, 'faces': [const FontFace(family: 'JetBrains Mono').toJson()]},
        {'path': '/fonts/a.ttf', 'faces': [const FontFace(family: 'Alpha Grotesk').toJson()]},
      ]);
      CaptionStyle? picked;
      await tester.pumpWidget(ProviderScope(
        overrides: [servicesProvider.overrideWithValue(s)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AccentChoice.neforum),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => picked = await showFontPickerSheet(context, style: const CaptionStyle(), platformId: 'tiktok'),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('TikTok Sans'), findsOneWidget);
      expect(find.text('Alpha Grotesk'), findsOneWidget);
      expect(find.text('On this device'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('font-search')), 'jet');
      await tester.pump();
      expect(find.text('Alpha Grotesk'), findsNothing);
      expect(find.text('TikTok Sans'), findsNothing);
      await tester.tap(find.text('JetBrains Mono'));
      await tester.pumpAndSettle();
      expect(picked?.customFont, CaptionFont(family: 'JetBrains Mono', path: mono));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a caption whose font is missing uses the default, says so once, and is marked for later', (tester) async {
      final storage = (await tester.runAsync(_tempStorage))!;
      debugInstalledFontCatalog = InstalledFontCatalog.empty;
      final s = (await tester.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
      final tiktok = (await tester.runAsync(() => s.accounts.all()))!.firstWhere((a) => a.platformId == 'tiktok');
      final warnings = <String>[];
      final sub = renderWarnings.listen(warnings.add);
      addTearDown(sub.cancel);
      final photo = (await tester.runAsync(
          () => s.media.importBytes(img.encodeJpg(img.Image(width: 300, height: 400)..clear(img.ColorRgb8(30, 90, 160))), fileName: 'p.jpg')))!;
      final now = DateTime(2026, 10, 28);
      var post = Post(id: 'p-font', text: 'In my own font', media: [photo], targets: [PostTarget(accountId: tiktok.id)], createdAt: now, updatedAt: now);
      final style = const CaptionStyle(customFont: CaptionFont(family: 'Nowhere Sans', path: '/no/such.ttf')).toJson();
      await tester.runAsync(() async {
        post = await attachCaptionedPhotos(s, post, s.settings, choices: const {'tiktok': true}, style: style);
        await Future<void>.delayed(Duration.zero);
      });
      final copy = post.media.singleWhere(isCaptionedCopy);
      expect(copy.renderParameters!['fontFallback'], isTrue);
      expect(copy.renderParameters!['style']['customFont']['family'], 'Nowhere Sans');
      expect(warnings.where((w) => w.contains('Nowhere Sans')), hasLength(1));

      // Saved again, as the composer does: the target lists the photo again.
      await tester.runAsync(() async {
        post = await attachCaptionedPhotos(s, post.withTarget(PostTarget(accountId: tiktok.id)), s.settings, choices: const {'tiktok': true}, style: style);
        await Future<void>.delayed(Duration.zero);
      });
      expect(post.media.singleWhere(isCaptionedCopy).id, copy.id, reason: 'reused');
      expect(warnings.where((w) => w.contains('Nowhere Sans')), hasLength(1), reason: 'told once');
    });
  });
}
