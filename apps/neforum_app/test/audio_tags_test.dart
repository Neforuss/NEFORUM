// Track details (audio tags): read on import with the cover saved beside the
// file, kept through the composer, its draft and saved posts, written into
// the Standard copy and given to the still-picture video, kept by the media
// housekeeping, and edited in the track details sheet.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/platform/storage_maintenance.dart';
import 'package:neforum_app/state/audio_renditions.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/composer_draft.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/track_details_sheet.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

// ------------------------------------------------------------ test files

List<int> _syncsafe(int n) => [(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F];
List<int> _u32be(int n) => [n >> 24 & 0xFF, n >> 16 & 0xFF, n >> 8 & 0xFF, n & 0xFF];
List<int> _u32le(int n) => [n & 0xFF, n >> 8 & 0xFF, n >> 16 & 0xFF, n >> 24 & 0xFF];

/// Silent MPEG-1 Layer III frames (128 kbit/s, 44.1 kHz).
List<int> _frames([int n = 20]) => [for (var i = 0; i < n; i++) ...[0xFF, 0xFB, 0x90, 0x64, ...List.filled(413, 0)]];

/// An ID3v2.3 tag (ISO-8859-1 text) with a PNG front cover.
List<int> _id3({String title = 'Night Drive', String artist = 'Neon Waves', String album = 'Coastline', Uint8List? cover}) {
  List<int> frame(String id, List<int> content) => [...id.codeUnits, ..._u32be(content.length), 0, 0, ...content];
  final body = [
    ...frame('TIT2', [0, ...title.codeUnits]),
    ...frame('TPE1', [0, ...artist.codeUnits]),
    ...frame('TALB', [0, ...album.codeUnits]),
    ...frame('TYER', [0, ...'2024'.codeUnits]),
    if (cover != null) ...frame('APIC', [0, ...'image/png'.codeUnits, 0, 3, 0, ...cover]),
  ];
  return [...'ID3'.codeUnits, 3, 0, 0, ..._syncsafe(body.length), ...body];
}

/// A one-second silent WAV carrying [id3] in an `id3 ` chunk.
Uint8List _wav(List<int> id3) {
  final fmt = [...'fmt '.codeUnits, ..._u32le(16), 1, 0, 2, 0, ..._u32le(44100), ..._u32le(176400), 4, 0, 16, 0];
  final data = [...'data'.codeUnits, ..._u32le(176400), ...List.filled(176400, 0)];
  final tag = [...'id3 '.codeUnits, ..._u32le(id3.length), ...id3, if (id3.length.isOdd) 0];
  final body = [...'WAVE'.codeUnits, ...fmt, ...data, ...tag];
  return Uint8List.fromList([...'RIFF'.codeUnits, ..._u32le(body.length), ...body]);
}

final Uint8List _cover = img.encodePng(img.Image(width: 32, height: 32)..clear(img.ColorRgb8(20, 180, 60)));

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

const _fileTags = AudioTags(title: 'Night Drive', artist: 'Neon Waves', album: 'Coastline', year: 2024, coverPath: 'mem://cover.png', coverMimeType: 'image/png');
const _track = MediaAttachment(id: 'snd', path: 'mem://snd.mp3', mimeType: AudioMimeTypes.mp3, sizeBytes: 9, fileName: 'track01.mp3', audioTags: _fileTags);

void main() {
  group('import', () {
    late Directory dir;
    late AppStorage storage;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('neforum-audio-tags');
      storage = await openAppStorage(overrideDir: dir.path);
    });
    tearDown(() => dir.delete(recursive: true));

    test('a tagged file keeps its tags, its cover becomes a media file of its own', () async {
      final services = await AppServices.create(demo: true, storage: storage);
      final m = await services.media.importBytes(Uint8List.fromList([..._id3(cover: _cover), ..._frames()]), fileName: 'track.mp3');
      final t = m.audioTags!;
      expect((t.title, t.artist, t.album, t.year), ('Night Drive', 'Neon Waves', 'Coastline', 2024));
      expect(t.coverMimeType, 'image/png');
      expect(File(t.coverPath!).readAsBytesSync(), _cover);
      expect(p(t.coverPath!), isNot(p(m.path)));
      // Kept on the attachment through JSON.
      expect(MediaAttachment.fromJson(m.toJson()).audioTags, t);
    });

    test('a file without tags has none', () async {
      final services = await AppServices.create(demo: true, storage: storage);
      final m = await services.media.importBytes(Uint8List.fromList(_frames()), fileName: 'plain.mp3');
      expect(m.audioTags, isNull);
    });
  });

  group('housekeeping', () {
    test('covers named by a file\'s tags or by the user\'s details count as in use', () {
      final post = Post(
        id: 'p',
        text: '',
        media: const [_track],
        audioDetails: const AudioTags(coverPath: r'C:\data\media\Picked.JPG', coverMimeType: 'image/jpeg'),
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect(audioCoverPaths(post), ['mem://cover.png', r'C:\data\media\Picked.JPG']);
      final referenced = referencedFileNames([post.toJson()]);
      final old = DateTime(2026);
      final files = <StoredFile>[
        (path: '/data/media/cover.png', modified: old),
        (path: '/data/media/picked.jpg', modified: old),
        (path: '/data/media/snd.mp3', modified: old),
        (path: '/data/media/orphan.png', modified: old),
      ];
      expect(unreferencedMediaFiles(files, referenced, now: DateTime(2026, 2), grace: Duration.zero), ['/data/media/orphan.png']);
    });

    test('the startup sweep keeps covers, deleting a post deletes them', () async {
      final dir = await Directory.systemTemp.createTemp('neforum-audio-sweep');
      addTearDown(() => dir.delete(recursive: true));
      final storage = await openAppStorage(overrideDir: dir.path);
      final s = await AppServices.create(demo: false, storage: storage);
      final track = await s.media.importBytes(Uint8List.fromList([..._id3(cover: _cover), ..._frames()]), fileName: 'track.mp3');
      final picked = await s.media.saveCover(_cover, 'image/png');
      final orphan = await s.media.saveCover(_cover, 'image/png');
      final post = Post(
        id: 'p1',
        text: 'x',
        media: [track],
        audioDetails: AudioTags(coverPath: picked, coverMimeType: 'image/png'),
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      await s.posts.upsert(post);
      expect(await s.deleteUnreferencedMedia(grace: Duration.zero), 1);
      expect(File(orphan).existsSync(), isFalse);
      expect(File(picked).existsSync(), isTrue);
      expect(File(track.audioTags!.coverPath!).existsSync(), isTrue);

      await s.discardPosts([post]);
      expect(File(picked).existsSync(), isFalse);
      expect(File(track.audioTags!.coverPath!).existsSync(), isFalse);
      expect(File(track.path).existsSync(), isFalse);
      s.dispose();
    });
  });

  group('composer', () {
    late ProviderContainer c;
    setUp(() async {
      final services = await AppServices.create(demo: true, storage: _MemoryStorage());
      c = ProviderContainer(overrides: [servicesProvider.overrideWithValue(services)]);
      addTearDown(c.dispose);
    });

    test('details go through the post, the draft file and loading; removing the track drops them', () {
      final n = c.read(composerProvider.notifier);
      n.addMedia([_track]);
      n.setAudioDetails(const AudioTags(title: 'Night Drive (Edit)', artist: ''));
      final state = c.read(composerProvider);
      expect(state.effectiveAudioTags!.title, 'Night Drive (Edit)');
      expect(state.effectiveAudioTags!.artist, isNull);

      final post = state.toPost(id: 'p', status: PostStatus.draft, now: DateTime(2026));
      expect(Post.fromJson(post.toJson()).audioDetails, const AudioTags(title: 'Night Drive (Edit)', artist: ''));
      expect(composerDraftFromJson(composerDraftToJson(state))!.audioDetails, state.audioDetails);
      n.reset();
      expect(c.read(composerProvider).audioDetails, isNull);
      n.load(post);
      expect(c.read(composerProvider).audioDetails, post.audioDetails);

      n.setAudioDetails(AudioTags.none);
      expect(c.read(composerProvider).audioDetails, isNull);
      n.setAudioDetails(const AudioTags(genre: 'Synthwave'));
      n.removeMedia('snd');
      expect(c.read(composerProvider).audioDetails, isNull);
      expect(c.read(composerProvider).toPost(id: 'q', status: PostStatus.draft, now: DateTime(2026)).audioDetails, isNull);
    });

    test('"Use track details as the text" fills an empty text only', () {
      final n = c.read(composerProvider.notifier);
      expect(n.useTrackDetailsAsText(kDefaultAudioTextTemplate), isFalse, reason: 'no sound file');
      n.addMedia([_track]);
      expect(n.useTrackDetailsAsText(kDefaultAudioTextTemplate), isTrue);
      expect(c.read(composerProvider).text, 'Neon Waves – Night Drive (Coastline, 2024)');
      expect(n.useTrackDetailsAsText('{title}'), isFalse, reason: 'the text is not empty any more');
      n.setText('');
      n.setAudioDetails(const AudioTags(album: ''));
      n.useTrackDetailsAsText('{title} by {artist} ({album})');
      expect(c.read(composerProvider).text, 'Night Drive by Neon Waves');
    });

    test('edits are only what differs from the file', () {
      final values = {for (final d in TrackDetail.values) d: d.of(_fileTags)};
      expect(trackDetailsEdits(_fileTags, values), isNull);
      values[TrackDetail.title] = 'New';
      values[TrackDetail.album] = '';
      values[TrackDetail.year] = '';
      values[TrackDetail.trackNumber] = '4';
      values[TrackDetail.genre] = 'Synthwave';
      final e = trackDetailsEdits(_fileTags, values, coverPath: '')!;
      expect(e, const AudioTags(title: 'New', album: '', year: 0, trackNumber: 4, genre: 'Synthwave', coverPath: ''));
      final out = _fileTags.overriddenBy(e);
      expect((out.title, out.album, out.year, out.trackNumber, out.hasCover), ('New', null, null, 4, false));
    });

    test('the template setting round-trips and defaults', () {
      expect(const AppSettings().audioTextTemplate, kDefaultAudioTextTemplate);
      final s = const AppSettings().copyWith(audioTextTemplate: '{title}');
      expect(AppSettings.fromJson(s.toJson()).audioTextTemplate, '{title}');
      expect(AppSettings.fromJson(const {}).audioTextTemplate, kDefaultAudioTextTemplate);
    });

    test('the template moves and syncs with the other settings', () {
      final s = const AppSettings().copyWith(audioTextTemplate: '{artist}: {title}');
      expect(exportableSettings(s)['audioTextTemplate'], '{artist}: {title}');
      expect(withImportedSettings(const AppSettings(), {'audioTextTemplate': '{title}'}).audioTextTemplate, '{title}');
    });
  });

  group('renditions', () {
    final calls = <(String, Map<String, Object?>)>[];
    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('neforum/video'), (call) async {
        final args = call.arguments is Map ? Map<String, Object?>.from(call.arguments as Map) : const <String, Object?>{};
        switch (call.method) {
          case 'isSupported':
            return true;
          case 'audioFormats':
            return ['mp3'];
          case 'transcodeAudio':
            calls.add((call.method, args));
            // Like the system encoder: an MP3 without tags.
            File(args['outputPath']! as String).writeAsBytesSync(Uint8List.fromList(_frames()));
            return null;
          case 'audioVideo':
            calls.add((call.method, args));
            File(args['outputPath']! as String).writeAsBytesSync(Uint8List.fromList(List.filled(512, 1)));
            return null;
        }
        return null;
      });
    });
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('neforum/video'), null));

    testWidgets('the Standard copy carries the tags and cover; the video gets the cover; new details retag without converting again',
        (tester) async {
      final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('neforum-audio-tagged-copy')))!;
      addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));
      late AppServices s;
      late MediaAttachment track;
      final accounts = [
        for (final (id, platform) in const [('tg', 'telegram'), ('x', 'x')])
          ConnectedAccount(id: id, platformId: platform, tier: PlatformTier.handoff, displayName: id, createdAt: DateTime(2026, 10, 1)),
      ];
      await tester.runAsync(() async {
        s = await AppServices.create(demo: true, storage: await openAppStorage(overrideDir: dir.path));
        for (final a in accounts) {
          await s.accounts.upsert(a);
        }
        track = await s.media.importBytes(_wav(_id3(cover: _cover)), fileName: 'Master.wav');
      });
      expect(track.audioTags!.title, 'Night Drive');
      final now = DateTime(2026, 10, 29);
      var post = Post(
        id: 'p-tags',
        text: 'Out now',
        media: [track],
        audioDetails: const AudioTags(title: 'Night Drive (Edit)'),
        targets: [for (final a in accounts) PostTarget(accountId: a.id)],
        createdAt: now,
        updatedAt: now,
      );
      await tester.runAsync(() async => post = await attachAudioRenditions(s, post, s.settings));
      expect(calls.map((c) => c.$1), ['transcodeAudio', 'audioVideo']);
      final copy = post.media.singleWhere((m) => isAudioRendition(m) && m.isAudio);
      final read = readAudioTags(File(copy.path).readAsBytesSync());
      expect((read.tags.title, read.tags.artist, read.tags.album, read.tags.year), ('Night Drive (Edit)', 'Neon Waves', 'Coastline', 2024));
      expect(read.cover, _cover);
      expect(copy.sizeBytes, File(copy.path).lengthSync());
      // The video's picture is the cover (no photo in the post).
      final picture = img.decodePng(calls.last.$2['imagePng']! as Uint8List)!;
      final centre = picture.getPixel(picture.width ~/ 2, picture.height ~/ 2);
      expect((centre.r, centre.g, centre.b), (20, 180, 60));

      // New details: the copy is tagged again, not converted again.
      final before = copy;
      await tester.runAsync(() async {
        post = await attachAudioRenditions(s, withoutAudioRenditions(post, keepFiles: true).copyWith(audioDetails: const AudioTags(title: 'Final', coverPath: '')), s.settings);
      });
      expect(calls.where((c) => c.$1 == 'transcodeAudio'), hasLength(1));
      final retagged = post.media.singleWhere((m) => isAudioRendition(m) && m.isAudio);
      expect(retagged.id, isNot(before.id));
      expect(File(before.path).existsSync(), isFalse, reason: 'the old copy is deleted');
      final again = readAudioTags(File(retagged.path).readAsBytesSync());
      expect(again.tags.title, 'Final');
      expect(again.cover, isNull, reason: 'the user removed the cover');
      expect(post.targetFor('tg')!.overrides.mediaIds, [retagged.id]);

      // Saving again with the same details changes nothing.
      await tester.runAsync(() async => post = await attachAudioRenditions(s, withoutAudioRenditions(post, keepFiles: true), s.settings));
      expect(post.media.singleWhere((m) => isAudioRendition(m) && m.isAudio).id, retagged.id);
    });

    test('the tag-writing job works on plain data', () {
      final out = embedAudioTagsJob((Uint8List.fromList(_frames()), AudioMimeTypes.mp3, const AudioTags(title: 'T').toJson(), _cover, 'image/png'))!;
      final r = readAudioTags(out);
      expect(r.tags.title, 'T');
      expect(r.cover, _cover);
      expect(embedAudioTagsJob((Uint8List.fromList(_frames()), AudioMimeTypes.flac, const <String, dynamic>{}, null, null)), isNull);
      expect(audioTagsStamp(const AudioTags(title: 'T')), isNot(audioTagsStamp(const AudioTags(title: 'U'))));
    });
  });

  group('track details editor', () {
    Future<ProviderContainer> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
      await tester.pumpWidget(ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AccentChoice.neforum),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Column(children: [
                const TrackDetailsRow(),
                TextButton(onPressed: () => showTrackDetailsEditor(context), child: const Text('open')),
              ]),
            ),
          ),
        ),
      ));
      final c = ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
      c.read(composerProvider.notifier).addMedia([_track]);
      await tester.pump();
      return c;
    }

    testWidgets('shows what comes from the file, previews the text, saves the edits', (tester) async {
      final c = await open(tester);
      expect(find.text('Neon Waves – Night Drive'), findsOneWidget, reason: 'the row names the track');
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('From the file'), findsWidgets);
      expect(find.text('Neon Waves – Night Drive (Coastline, 2024)'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('track-title')), 'Night Drive (Edit)');
      await tester.enterText(find.byKey(const ValueKey('track-album')), '');
      await tester.pump();
      expect(find.text('Neon Waves – Night Drive (Edit) (2024)'), findsOneWidget);
      expect(find.textContaining('Edited · the file says'), findsWidgets);

      await tester.tap(find.text('Save and use as the text'));
      await tester.pumpAndSettle();
      final state = c.read(composerProvider);
      expect(state.audioDetails, const AudioTags(title: 'Night Drive (Edit)', album: ''));
      expect(state.text, 'Neon Waves – Night Drive (Edit) (2024)');
    });

    testWidgets('reset goes back to the file\'s tags; a new template is kept in Settings', (tester) async {
      final c = await open(tester);
      c.read(composerProvider.notifier).setAudioDetails(const AudioTags(artist: 'Someone else'));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Someone else'), findsOneWidget);
      await tester.tap(find.text('Reset to the file\'s tags'));
      await tester.pump();
      expect(find.text('Someone else'), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('track-template')), '{title} / {artist}');
      await tester.pump();
      expect(find.text('Night Drive / Neon Waves'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(c.read(composerProvider).audioDetails, isNull);
      expect(c.read(settingsProvider).audioTextTemplate, '{title} / {artist}');
    });
  });
}

String p(String path) => path.replaceAll(r'\', '/').split('/').last;
