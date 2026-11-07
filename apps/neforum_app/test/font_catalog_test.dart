import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_app/media/caption_fonts.dart';
import 'package:neforum_app/media/font_catalog.dart';
import 'package:neforum_app/media/font_files.dart';
import 'package:neforum_app/media/font_storage_io.dart' as files;
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/settings.dart';

import 'font_fixtures.dart';

Future<AppStorage> _tempStorage() async {
  final dir = Directory.systemTemp.createTempSync('nf-font-catalog-');
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
  final now = DateTime.utc(2026, 11, 6, 12);

  group('the list', () {
    test('keeps the families with an allowed licence, hides everything else', () {
      final list = FontCatalog.fromFontsource(fontListFixture(), now);
      expect(list.entries.map((e) => e.id), ['42dot-sans', 'inter', 'lobster', 'noto-sans-jp', 'fragment-mono', 'ubuntu']);
    });

    test('a new licence string is hidden, not shown', () {
      for (final license in ['ITF-FFL', 'GPL-3.0', '', 'OFL', 'proprietary']) {
        expect(FontCatalogEntry.tryParse({'id': 'x', 'family': 'X', 'category': 'serif', 'license': license, 'subsets': ['latin'], 'weights': [400]}), isNull, reason: license);
      }
      for (final license in ['OFL-1.1', 'Apache-2.0', 'UFL-1.0', 'CC0-1.0', 'Unlicense', 'mit', 'MIT']) {
        expect(isAllowedFontLicense(license), isTrue, reason: license);
      }
    });

    test('an answer with nothing usable is an error, so it never replaces a good list', () {
      expect(() => FontCatalog.fromFontsource({'error': 'x'}, now), throwsFormatException);
      expect(() => FontCatalog.fromFontsource([{'not': 'a row'}], now), throwsFormatException);
    });

    test('searches by name, kind and script', () {
      final list = FontCatalog.fromFontsource(fontListFixture(), now);
      expect(list.search('INT').map((e) => e.id), ['inter']);
      expect(list.search('').length, 6);
      expect(list.search('', category: 'monospace').map((e) => e.id), ['fragment-mono']);
      expect(list.search('', subset: 'japanese').map((e) => e.id), ['noto-sans-jp']);
      expect(list.search('no such font'), isEmpty);
    });

    test('survives being saved', () {
      final list = FontCatalog.fromFontsource(fontListFixture(), now);
      final back = FontCatalog.tryFromJson(jsonDecode(jsonEncode(list.toJson())) as Map<String, dynamic>)!;
      expect(back.fetchedAt, list.fetchedAt);
      expect(back.entries.map((e) => e.id), list.entries.map((e) => e.id));
      expect(back.entries[1].subsets, list.entries[1].subsets);
      expect(FontCatalog.tryFromJson(const {'rows': 'x'}), isNull);
      expect(FontCatalog.tryFromJson(null), isNull);
    });

    test('a preview is one small file: Latin where there is Latin, nearest to 400', () {
      final list = FontCatalog.fromFontsource(fontListFixture(), now);
      expect(list.entries.firstWhere((e) => e.id == 'inter').previewFile, 'latin-400-normal.ttf');
      final other = FontCatalogEntry.tryParse({'id': 'x', 'family': 'X', 'category': 'serif', 'license': 'mit', 'subsets': ['arabic'], 'weights': [300, 700], 'defSubset': 'arabic'})!;
      expect(other.previewFile, 'arabic-300-normal.ttf');
    });
  });

  group('reading and keeping the list', () {
    test('is read once, then from the saved copy for 14 days, and again after that', () async {
      final storage = await _tempStorage();
      final fake = FakeFontServices();
      final first = await loadFontCatalog(storage, fake.client, clock: () => now);
      expect(first.refreshFailed, isFalse);
      expect(fake.paths, ['/v1/fonts']);
      expect(File('${storage.dataDir}/$kFontCatalogFile').existsSync(), isTrue);

      await loadFontCatalog(storage, fake.client, clock: () => now.add(const Duration(days: 14)));
      expect(fake.paths, hasLength(1), reason: 'still fresh');
      await loadFontCatalog(storage, fake.client, clock: () => now.add(const Duration(days: 14, minutes: 1)));
      expect(fake.paths, hasLength(2), reason: 'old now');
      await loadFontCatalog(storage, fake.client, clock: () => now.subtract(const Duration(days: 1)));
      expect(fake.paths, hasLength(3), reason: 'a saved time in the future counts as old');
    });

    test('keeps the old copy when it cannot be read again, and says so', () async {
      final storage = await _tempStorage();
      final fake = FakeFontServices();
      await loadFontCatalog(storage, fake.client, clock: () => now);
      fake.offline = true;
      final later = await loadFontCatalog(storage, fake.client, clock: () => now.add(const Duration(days: 30)));
      expect(later.refreshFailed, isTrue);
      expect(later.catalog.entries, hasLength(6));
      expect(later.catalog.fetchedAt, now, reason: 'the time of the copy it really is');

      fake
        ..offline = false
        ..list = {'error': 'bad gateway'};
      final junk = await loadFontCatalog(storage, fake.client, clock: () => now.add(const Duration(days: 30)));
      expect(junk.refreshFailed, isTrue);
      expect((await loadFontCatalog(storage, fake.client, clock: () => now)).catalog.entries, hasLength(6), reason: 'a bad answer did not replace it');
    });

    test('with no copy and no network it says so in plain words', () async {
      final storage = await _tempStorage();
      final fake = FakeFontServices()..offline = true;
      await expectLater(
        loadFontCatalog(storage, fake.client, clock: () => now),
        throwsA(isA<FontDownloadException>().having((e) => e.message, 'message', allOf(contains('could not reach'), isNot(contains('Failed host lookup'))))),
      );
    });
  });

  group('one family', () {
    final detail = fontDetailFixture('inter', 'Inter', variants: {
      400: ['latin', 'cyrillic', 'latin-ext'],
      700: ['latin', 'cyrillic', 'latin-ext'],
    }, numbered: 3);

    test('leaves numbered slices out and puts Latin first', () {
      final d = FontFamilyDetail.parse(jsonDecode(jsonEncode(detail)), expectedId: 'inter');
      expect(d.version, '5.3.0');
      expect(d.defaultWeights, [400, 700]);
      expect(d.filesFor(d.defaultWeights).map((f) => f.fileName), [
        'latin-400-normal.ttf',
        'latin-700-normal.ttf',
        'latin-ext-400-normal.ttf',
        'latin-ext-700-normal.ttf',
        'cyrillic-400-normal.ttf',
        'cyrillic-700-normal.ttf',
      ]);
    });

    test('a family with only numbered slices is refused, not installed in pieces', () {
      final numbers = fontDetailFixture('slices', 'Slices', variants: {400: const []}, numbered: 100);
      expect(() => FontFamilyDetail.parse(numbers, expectedId: 'slices'), throwsA(isA<FontDownloadException>()));
    });

    test('takes the nearest weights, and a bold only when there is one', () {
      List<int> weights(List<int> have) {
        final d = FontFamilyDetail.parse(fontDetailFixture('x', 'X', variants: {for (final w in have) w: const ['latin']}), expectedId: 'x');
        return d.defaultWeights;
      }

      expect(weights([100, 300, 500, 800]), [300, 800], reason: 'on a tie, the lighter; a bold is 600 or more');
      expect(weights([400]), [400]);
      expect(weights([300, 500]), [300]);
      expect(weights([900]), [900]);
      expect(weights([400, 600, 900]), [400, 600]);
    });

    test('the rules of the list apply again: a synced style can name anything', () {
      expect(() => FontFamilyDetail.parse(fontDetailFixture('x', 'X', license: 'ITF-FFL', variants: {400: const ['latin']}), expectedId: 'x'), throwsA(isA<FontDownloadException>()));
      expect(() => FontFamilyDetail.parse(fontDetailFixture('noto-color-emoji', 'E', variants: {400: const ['emoji']}), expectedId: 'noto-color-emoji'), throwsA(isA<FontDownloadException>()));
      expect(() => FontFamilyDetail.parse(fontDetailFixture('x', 'X', category: 'icons', variants: {400: const ['latin']}), expectedId: 'x'), throwsA(isA<FontDownloadException>()));
      expect(() => FontFamilyDetail.parse(fontDetailFixture('other', 'X', variants: {400: const ['latin']}), expectedId: 'x'), throwsA(isA<FontDownloadException>()), reason: 'an answer about another family');
      expect(() => FontFamilyDetail.parse(fontDetailFixture('x', 'X', version: '../../evil', variants: {400: const ['latin']}), expectedId: 'x'), throwsA(isA<FontDownloadException>()));
      expect(() => FontFamilyDetail.parse('nonsense', expectedId: 'x'), throwsA(isA<FontDownloadException>()));
    });

    test('Latin first, then the default subset, then its extension, then by name', () {
      expect(orderSubsets({'vietnamese', 'latin-ext', 'japanese', 'latin', 'cyrillic'}, 'japanese'), ['latin', 'japanese', 'latin-ext', 'cyrillic', 'vietnamese']);
      expect(orderSubsets({'hebrew', 'arabic'}, 'hebrew'), ['hebrew', 'arabic']);
    });

    test('is big only when a big subset is known to be, or cannot be sized', () {
      final d = FontFamilyDetail.parse(fontDetailFixture('jp', 'JP', variants: {400: const ['latin', 'japanese']}), expectedId: 'jp');
      final files = d.filesFor(d.defaultWeights);
      expect(FontInstallPlan(detail: d, files: files).isLarge, isTrue, reason: 'unknown size');
      expect(FontInstallPlan(detail: d, files: files, knownLargeBytes: kLargeFontBytes).isLarge, isFalse);
      expect(FontInstallPlan(detail: d, files: files, knownLargeBytes: kLargeFontBytes + 1).isLarge, isTrue);
      final plain = FontFamilyDetail.parse(fontDetailFixture('p', 'P', variants: {400: const ['latin']}), expectedId: 'p');
      expect(FontInstallPlan(detail: plain, files: plain.filesFor(plain.defaultWeights)).isLarge, isFalse);
    });
  });

  group('requests', () {
    Uint8List bytes(int n) => Uint8List(n);

    test('every request names NEFORUM only, with no version', () async {
      final seen = <http.BaseRequest>[];
      final client = MockClient((r) async {
        seen.add(r);
        return http.Response.bytes(bytes(4), 200);
      });
      await fetchFontBytes(client, Uri.parse('https://cdn.example/a'), maxBytes: 10);
      expect(seen.single.headers['User-Agent'], kFontDownloadUserAgent);
      expect(kFontDownloadUserAgent, isNot(matches(RegExp(r'\d'))));
    });

    test('stops at the size limit', () async {
      final client = MockClient((r) async => http.Response.bytes(bytes(11), 200));
      await expectLater(fetchFontBytes(client, Uri.parse('https://cdn.example/a'), maxBytes: 10), throwsA(isA<FontDownloadException>()));
    });

    test('a refusal and a lost connection are plain words, with no raw error', () async {
      final refused = MockClient((r) async => http.Response('', 503));
      await expectLater(fetchFontBytes(refused, Uri.parse('https://cdn.example/a'), maxBytes: 10), throwsA(isA<FontDownloadException>().having((e) => e.message, 'message', contains('could not reach'))));
      final gone = MockClient((r) async => http.Response('', 404));
      await expectLater(fetchFontBytes(gone, Uri.parse('https://cdn.example/a'), maxBytes: 10), throwsA(isA<FontDownloadException>().having((e) => e.message, 'message', contains('no longer has'))));
      final lost = MockClient((r) async => throw const SocketException('errno = 10053'));
      await expectLater(fetchFontBytes(lost, Uri.parse('https://cdn.example/a'), maxBytes: 10), throwsA(isA<FontDownloadException>().having((e) => e.message, 'message', isNot(contains('10053')))));
    });

    test('cancelling stops at the next chunk', () async {
      final cancel = FontInstallCancel()..cancelled = true;
      final client = MockClient((r) async => http.Response.bytes(bytes(4), 200));
      await expectLater(fetchFontBytes(client, Uri.parse('https://cdn.example/a'), maxBytes: 10, cancel: cancel), throwsA(isA<FontInstallCancelled>()));
    });

    test('sizes a file from its ETag when the ETag says, and only then', () async {
      Future<int?> size(Map<String, String> headers, {int status = 200}) => fetchFontFileSize(MockClient((r) async {
            expect(r.method, 'HEAD');
            return http.Response('', status, headers: headers);
          }), Uri.parse('https://cdn.example/a'));
      expect(await size({'etag': 'W/"299ea4-5d12d5a4b9994492"'}), 2727588, reason: 'noto-sans-jp japanese-400, measured');
      expect(await size({'etag': '"10560-gZQQ"'}), 66912);
      expect(await size({'etag': 'W/"something else"'}), isNull);
      expect(await size({}), isNull);
      expect(await size({'etag': '"10-x"'}, status: 404), isNull);
    });

    test('previews: at most 20 a minute', () {
      var t = now;
      final limiter = FontPreviewLimiter(clock: () => t);
      for (var i = 0; i < 20; i++) {
        expect(limiter.tryStart(), isTrue, reason: 'preview $i');
      }
      expect(limiter.tryStart(), isFalse);
      t = t.add(const Duration(seconds: 59));
      expect(limiter.tryStart(), isFalse);
      t = t.add(const Duration(seconds: 1));
      expect(limiter.tryStart(), isTrue);
    });

    test('addresses are pinned to the version, built here', () {
      const e = FontEndpoints();
      expect(e.file('inter', '5.3.0', 'latin-400-normal.ttf').toString(), 'https://cdn.jsdelivr.net/fontsource/fonts/inter@5.3.0/latin-400-normal.ttf');
      expect(e.license('inter', '5.3.0').toString(), 'https://cdn.jsdelivr.net/npm/@fontsource/inter@5.3.0/LICENSE');
      expect(e.detail('inter').toString(), 'https://api.fontsource.org/v1/fonts/inter');
    });
  });

  group('a style naming a downloaded font', () {
    const source = CatalogFontSource(id: 'inter', version: '5.3.0', sizeBytes: 481216);
    const font = CaptionFont(family: 'Inter', source: source);

    test('round-trips, with no path', () {
      final json = jsonDecode(jsonEncode(font.toJson())) as Map<String, dynamic>;
      expect(json, {'family': 'Inter', 'source': {'provider': 'fontsource', 'id': 'inter', 'version': '5.3.0', 'bytes': 481216}});
      final back = CaptionFont.tryParse(json)!;
      expect(back, font);
      expect(back.source!.sizeBytes, 481216);
      expect(back.hashCode, font.hashCode);
      expect(back == const CaptionFont(family: 'Inter'), isFalse);
    });

    test('older styles read and write as before', () {
      const old = CaptionFont(family: 'Mine', fileId: 'a.otf');
      expect(old.toJson(), {'family': 'Mine', 'fileId': 'a.otf'});
      expect(CaptionFont.tryParse(old.toJson()), old);
      expect(CaptionFont.tryParse({'family': 'Mine', 'source': 7}), const CaptionFont(family: 'Mine'));
    });

    test('a source from a synced file that could reach a path or address is dropped', () {
      for (final bad in [
        {'provider': 'fontsource', 'id': '../../evil', 'version': '5.3.0'},
        {'provider': 'fontsource', 'id': 'inter', 'version': '../5.3.0'},
        {'provider': 'fontsource', 'id': 'inter', 'version': 'latest'},
        {'provider': 'elsewhere', 'id': 'inter', 'version': '5.3.0'},
        {'provider': 'fontsource', 'id': 'Inter/x', 'version': '5.3.0'},
        {'id': 'inter', 'version': '5.3.0'},
      ]) {
        expect(CaptionFont.tryParse({'family': 'Inter', 'source': bad})!.source, isNull, reason: '$bad');
      }
    });

    test('a manifest that names a file outside its folder is not a font', () {
      final good = {
        'provider': 'fontsource',
        'id': 'inter',
        'version': '5.3.0',
        'family': 'Inter',
        'category': 'sans-serif',
        'license': 'OFL-1.1',
        'subsets': ['latin'],
        'files': [
          {'subset': 'latin', 'weight': 400, 'file': 'latin-400-normal.ttf', 'bytes': 10, 'sha256': 'a' * 64},
        ],
      };
      expect(DownloadedFont.tryParse(good)!.folder, 'inter@5.3.0');
      final escaping = {
        ...good,
        'files': [
          {'subset': 'latin', 'weight': 400, 'file': '../../settings.json', 'bytes': 10, 'sha256': 'a' * 64},
        ],
      };
      expect(DownloadedFont.tryParse(escaping), isNull);
      expect(DownloadedFont.tryParse({...good, 'id': '../x'}), isNull);
      expect(DownloadedFont.tryParse({...good, 'subsets': ['greek']}), isNull, reason: 'the first subset must have a file');
      expect(DownloadedFont.tryParse('nonsense'), isNull);
    });
  });

  group('the setting', () {
    test('asks by default, and stays on the device', () {
      expect(const AppSettings().fontDownloads, FontDownloadMode.ask);
      expect(AppSettings.fromJson(const {}).fontDownloads, FontDownloadMode.ask);
      expect(AppSettings.fromJson(const {'fontDownloads': 'nonsense'}).fontDownloads, FontDownloadMode.ask);
      expect(AppSettings.fromJson(const {'fontDownloads': 'off'}).fontDownloads, FontDownloadMode.off);
      expect(const AppSettings(fontDownloads: FontDownloadMode.on).toJson()['fontDownloads'], 'on');
      expect(kDeviceOnlySettings.containsKey('fontDownloads'), isTrue);
      expect(kExportableSettings.contains('fontDownloads'), isFalse);
      expect(exportableSettings(const AppSettings(fontDownloads: FontDownloadMode.on)).containsKey('fontDownloads'), isFalse);
      expect(syncedSettings(const AppSettings(fontDownloads: FontDownloadMode.on)).containsKey('fontDownloads'), isFalse);
      expect(withImportedSettings(const AppSettings(), {'fontDownloads': 'on'}).fontDownloads, FontDownloadMode.ask, reason: 'another device never turns it on here');
    });
  });

  group('on disk', () {
    final ttf = File(kMono).readAsBytesSync();

    test('downloaded fonts and previews are not imported fonts', () async {
      final storage = await _tempStorage();
      await files.saveImportedFont(storage.dataDir, 'mine.ttf', ttf);
      await files.saveCatalogFont(storage.dataDir, 'inter@5.3.0', {'latin-400-normal.ttf': ttf, 'manifest.json': Uint8List(0)});
      await files.saveFontPreview(storage.dataDir, 'lobster', ttf);
      final listed = await files.listImportedFonts(storage.dataDir);
      expect(listed.map((e) => e.$1), ['mine.ttf']);
      expect((await loadImportedFonts(storage)).single.font.fileId, 'mine.ttf');
    });

    test('a folder appears whole or not at all', () async {
      final storage = await _tempStorage();
      await expectLater(files.saveCatalogFont(storage.dataDir, 'inter@5.3.0', {'latin-400-normal.ttf': ttf, '../escape.ttf': ttf}), throwsArgumentError);
      final root = Directory(files.catalogFontsDirectory(storage.dataDir)!);
      expect(root.listSync(), isEmpty, reason: 'no folder and no staging left');
      expect(File('${storage.dataDir}/fonts/escape.ttf').existsSync(), isFalse);
      await expectLater(files.saveCatalogFont(storage.dataDir, '../evil', {'a.ttf': ttf}), throwsArgumentError);
    });

    test('a new version replaces the old one', () async {
      final storage = await _tempStorage();
      await files.saveCatalogFont(storage.dataDir, 'inter@5.2.0', {'latin-400-normal.ttf': ttf});
      await files.saveCatalogFont(storage.dataDir, 'inter@5.3.0', {'latin-400-normal.ttf': ttf}, replacing: ['inter@5.2.0', 'inter@5.3.0']);
      final names = Directory(files.catalogFontsDirectory(storage.dataDir)!).listSync().map((e) => e.path.split(Platform.pathSeparator).last);
      expect(names, ['inter@5.3.0']);
    });

    test('previews stay under the cap, the least recently used going first', () async {
      final storage = await _tempStorage();
      final dir = storage.dataDir;
      Uint8List sized(int n) => Uint8List(n);
      await files.saveFontPreview(dir, 'a', sized(40), maxBytes: 100);
      await files.saveFontPreview(dir, 'b', sized(40), maxBytes: 100);
      final previews = files.fontPreviewsDirectory(dir)!;
      File('$previews/a.ttf').setLastModifiedSync(now.subtract(const Duration(hours: 2)));
      File('$previews/b.ttf').setLastModifiedSync(now.subtract(const Duration(hours: 3)));
      // c does not fit beside both: the one used longest ago goes.
      await files.saveFontPreview(dir, 'c', sized(40), maxBytes: 100);
      expect(File('$previews/b.ttf').existsSync(), isFalse, reason: 'least recently used');
      expect(File('$previews/a.ttf').existsSync(), isTrue);
      expect(File('$previews/c.ttf').existsSync(), isTrue);

      expect(await files.readFontPreview(dir, 'a'), hasLength(40));
      expect(File('$previews/a.ttf').statSync().modified.isAfter(now.subtract(const Duration(hours: 1))), isTrue, reason: 'marked as just used');
      expect(await files.readFontPreview(dir, 'nothing'), isNull);
    });

    test('a file that is no longer the one that was checked is not read', () async {
      final storage = await _tempStorage();
      await files.saveCatalogFont(storage.dataDir, 'inter@5.3.0', {'latin-400-normal.ttf': ttf});
      final right = await files.sha256OfFontFile(ttf);
      expect(right, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(await files.readCatalogFontFile(storage.dataDir, 'inter@5.3.0', 'latin-400-normal.ttf', right), hasLength(ttf.length));
      expect(await files.readCatalogFontFile(storage.dataDir, 'inter@5.3.0', 'latin-400-normal.ttf', 'a' * 64), isNull);
      expect(await files.readCatalogFontFile(storage.dataDir, '..', 'settings.json', right), isNull);
    });
  });

  group('what the documents say', () {
    test('the README names everyone NEFORUM can contact, the update check included', () {
      final readme = File('../../README.md').readAsStringSync();
      final privacy = readme.substring(readme.indexOf('## Privacy'), readme.indexOf('## License'));
      expect(privacy, contains('neforus.com if you turn on the update check'));
      expect(privacy, contains('api.fontsource.org and cdn.jsdelivr.net if you turn on font downloads'));
      expect(privacy, contains('see your IP address and the font names you look up, never your posts'));
      expect(privacy, contains('downloaded fonts'), reason: 'what Delete everything removes');
      expect(readme.substring(readme.indexOf('## License')), contains('keeps its own open licence'));
    });

    test('the sync and backup guides say font files do not travel', () {
      expect(File('../../docs/sync.md').readAsStringSync(), contains('| Fonts | No: each device keeps its own font files.'));
      expect(File('../../docs/sync.md').readAsStringSync(), contains('font downloads, Sync itself) | No |'));
      expect(File('../../docs/backup.md').readAsStringSync(), contains('| Font files | Never.'));
    });
  });

  group('checking a font file', () {
    final real = File(kInterRegular).readAsBytesSync();

    test('reads a real character map', () {
      final map = readCharacterMap(real);
      expect(map[0x41], isNotNull);
      expect(map[0x416], isNotNull, reason: 'Inter has Cyrillic');
      final latin = subsetOf(real, isLatin);
      final cut = readCharacterMap(latin);
      expect(cut[0x41], map[0x41], reason: 'format 12, as written by the fixture');
      expect(cut[0x416], isNull);
    });

    test('samples only what the file maps, without spaces or format characters', () {
      final sample = fontSampleCodePoints(subsetOf(real, isCyrillic));
      expect(sample, hasLength(kFontSampleSize));
      expect(sample.every(isCyrillic), isTrue, reason: 'never a character a fallback font would draw');
      expect(fontSampleCodePoints(real).take(2), [0x41, 0x67]);
      expect(fontSampleCodePoints(subsetOf(real, (c) => c == 0x20 || c == 0xA0 || c == 0x200B)), isEmpty, reason: 'nothing drawable');
    });

    test('takes a whole real font, and nothing else', () {
      expect(isWholeFontFile(real), isTrue);
      expect(isWholeFontFile(subsetOf(real, isLatin)), isTrue);
      expect(isWholeFontFile(Uint8List.fromList([...'wOF2'.codeUnits, ...real.skip(4)])), isFalse, reason: 'WOFF2');
      expect(isWholeFontFile(Uint8List.fromList([...'wOFF'.codeUnits, ...real.skip(4)])), isFalse, reason: 'WOFF');
      expect(isWholeFontFile(Uint8List.fromList(utf8.encode('<!doctype html><html>Bad gateway</html>'))), isFalse, reason: 'an error page');
      expect(isWholeFontFile(Uint8List.sublistView(real, 0, real.length ~/ 2)), isFalse, reason: 'cut short');
      expect(isWholeFontFile(Uint8List(0)), isFalse);
      expect(isWholeFontFile(Uint8List.fromList([...'ttcf'.codeUnits, ...real.skip(4)])), isFalse, reason: 'a collection');
      expect(isWholeFontFile(subsetOf(real, (_) => false)), isFalse, reason: 'maps nothing');
    });

    test('never throws on junk', () {
      for (var n = 0; n < real.length; n += real.length ~/ 97) {
        final cut = Uint8List.sublistView(real, 0, n);
        expect(() => isWholeFontFile(cut), returnsNormally);
        expect(() => readCharacterMap(cut), returnsNormally);
        expect(() => fontSampleCodePoints(cut), returnsNormally);
      }
    });
  });
}
