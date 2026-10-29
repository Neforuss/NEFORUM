import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/audio_links.dart';
import 'package:neforum_core/src/adapters/blogs_a/ghost_adapter.dart';
import 'package:neforum_core/src/adapters/blogs_a/wordpress_adapter.dart';
import 'package:neforum_core/src/adapters/chat/discord_adapter.dart';
import 'package:neforum_core/src/adapters/chat/matrix_adapter.dart';
import 'package:neforum_core/src/adapters/chat/telegram_adapter.dart';
import 'package:neforum_core/src/adapters/mastodon/mastodon_adapter.dart';
import 'package:neforum_core/src/adapters/misskey/misskey_adapter.dart';
import 'package:neforum_core/src/adapters/video_sites/odysee_adapter.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: jsonHeaders);

/// A big cover, so Telegram's thumbnail has to be made smaller.
final Uint8List _cover = img.encodeJpg(img.Image(width: 1200, height: 900)..clear(img.ColorRgb8(200, 40, 40)), quality: 95);
final Uint8List _sound = Uint8List.fromList([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0, ...List.filled(64, 0)]);

const _tags = AudioTags(
  title: 'Night Drive',
  artist: 'Neon / Waves',
  album: 'Coastline',
  year: 2024,
  genre: 'Synthwave',
  trackNumber: 2,
  coverPath: '/media/cover.jpg',
  coverMimeType: 'image/jpeg',
);

const _mp3 = MediaAttachment(
  id: 'snd1',
  path: '/media/snd1.mp3',
  mimeType: AudioMimeTypes.mp3,
  sizeBytes: 74,
  durationMs: 184000,
  fileName: 'track01.mp3',
  audioTags: _tags,
);

/// Reads the cover from its path, every other file as the sound file.
AdapterContext _ctx(Future<http.Response> Function(http.Request r) handler) => AdapterContext(
      http: NeforumHttp(client: MockClient(handler), maxRetries: 0),
      clock: () => testNow,
      readMedia: (m) async => m.path == _tags.coverPath ? _cover : (m.isImage ? fakeJpegBytes : _sound),
    );

/// The file name of each file part of a multipart body, by field.
Map<String, String> _fileNames(http.Request r) => {
      for (final e in multipartFieldsOf(r).entries)
        if (e.value.startsWith('<')) e.key: e.value.substring(1, e.value.length - 1),
    };

/// The bytes of the multipart file part named [field].
Uint8List _filePart(http.Request r, String field) {
  final ct = r.headers['content-type']!;
  final boundary = RegExp(r'boundary=(.+)$').firstMatch(ct)!.group(1)!;
  final body = latin1.decode(r.bodyBytes);
  final part = body.split('--$boundary').firstWhere((p) => p.contains('name="$field"'));
  final start = part.indexOf('\r\n\r\n') + 4;
  return Uint8List.fromList(latin1.encode(part.substring(start, part.length - 2)));
}

void main() {
  group('variant resolution', () {
    final post = Post(
      id: 'p',
      text: 'New track',
      createdAt: testNow,
      updatedAt: testNow,
      media: [
        _mp3,
        const MediaAttachment(id: 'std', path: '/media/std.m4a', mimeType: AudioMimeTypes.m4a, sizeBytes: 1, generated: true, derivedFrom: 'snd1'),
        fakeImage(),
      ],
      audioDetails: const {'snd1': AudioTags(title: 'Night Drive (Edit)', genre: '')},
      targets: const [
        PostTarget(accountId: 'a', overrides: PostOverrides(mediaIds: ['std'])),
        PostTarget(accountId: 'b'),
      ],
    );

    test('every sound file and copy carries the file tags under the user edits', () {
      final d = TelegramAdapter().descriptor;
      final copy = const VariantResolver().resolve(post, post.targets.first, d).media.single;
      expect(copy.id, 'std');
      expect(copy.audioTags!.title, 'Night Drive (Edit)');
      expect(copy.audioTags!.artist, 'Neon / Waves');
      expect(copy.audioTags!.genre, isNull, reason: 'cleared by the user');
      expect(copy.audioTags!.coverPath, '/media/cover.jpg');
      // Discord takes a photo along with the sound file.
      final own = const VariantResolver().resolve(post, post.targets.last, DiscordAdapter().descriptor).media;
      expect(own, hasLength(2));
      expect(own.first.audioTags!.title, 'Night Drive (Edit)');
      expect(own.last.audioTags, isNull, reason: 'a photo has no track details');
      expect(identical(own.last, post.media.last), isTrue);
    });

    test('each sound file, and each copy of it, goes out with its own details', () {
      const second = MediaAttachment(
          id: 'snd2', path: '/media/snd2.mp3', mimeType: AudioMimeTypes.mp3, sizeBytes: 74, fileName: 'track02.mp3', audioTags: AudioTags(title: 'Coastline'));
      final two = Post(
        id: 'p2',
        text: 'Two tracks',
        createdAt: testNow,
        updatedAt: testNow,
        media: const [
          _mp3,
          second,
          MediaAttachment(id: 'std2', path: '/media/std2.mp3', mimeType: AudioMimeTypes.mp3, sizeBytes: 1, generated: true, derivedFrom: 'snd2'),
        ],
        audioDetails: const {'snd2': AudioTags(artist: 'Ana Lima')},
        targets: const [PostTarget(accountId: 'a', overrides: PostOverrides(mediaIds: ['snd1', 'std2']))],
      );
      expect(two.effectiveAudioTagsOf(_mp3), _tags, reason: 'the first file has no edits');
      expect(two.effectiveAudioTagsOf(second), const AudioTags(title: 'Coastline', artist: 'Ana Lima'));
      final media = const VariantResolver().resolve(two, two.targets.single, DiscordAdapter().descriptor).media;
      expect(media.map((m) => (m.id, m.audioTags?.title, m.audioTags?.artist)), [
        ('snd1', 'Night Drive', 'Neon / Waves'),
        ('std2', 'Coastline', 'Ana Lima'),
      ]);
      // Kept by media id through JSON.
      expect(Post.fromJson(two.toJson()).audioDetails, two.audioDetails);
    });

    test('the foundation\'s one set of details for the whole post applies to each sound file', () {
      final json = post.toJson()
        ..['media'] = [_mp3.toJson(), {..._mp3.toJson(), 'id': 'snd2'}, fakeImage().toJson()]
        ..['audioDetails'] = const AudioTags(title: 'Night Drive (Edit)', genre: '').toJson();
      final old = Post.fromJson(json);
      expect(old.audioDetails, {
        'snd1': const AudioTags(title: 'Night Drive (Edit)', genre: ''),
        'snd2': const AudioTags(title: 'Night Drive (Edit)', genre: ''),
      });
      expect(Post.fromJson(post.toJson()..remove('audioDetails')).audioDetails, isEmpty);
    });

    test('helpers: file name, caption, cover', () {
      expect(_mp3.audioTaggedFileName, 'Neon Waves - Night Drive.mp3');
      expect(_mp3.audioCaption, 'Neon / Waves – Night Drive');
      expect(_mp3.audioCover!.path, '/media/cover.jpg');
      expect(fakeImage().audioTaggedFileName, isNull);
      expect(safeAudioFileStem(' ..a:b*c?.. '), 'a b c');
    });

    test('the cover thumbnail fits Telegram: JPEG, 320 px, under 200 kB', () async {
      final thumb = (await audioThumbnailJpeg(_cover))!;
      final decoded = img.decodeJpg(thumb)!;
      expect(decoded.width, 320);
      expect(decoded.height, 240);
      expect(thumb.length, lessThan(200 * 1024));
      expect(await audioThumbnailJpeg(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });

  test('Telegram sendAudio: title, performer, duration, the cover as thumbnail', () async {
    final calls = <http.Request>[];
    final ctx = _ctx((r) async {
      calls.add(r);
      return _json({'ok': true, 'result': {'message_id': 7}});
    });
    final account = fakeAccount('telegram', config: {'chatId': '-1001', 'chatType': 'channel', 'formatting': 'plain'});
    final res = await TelegramAdapter().publish(const PostVariant(text: 'Out now', media: [_mp3]), account, {'bot_token': '1:x'}, ctx);
    expect(res.success, isTrue, reason: '${res.error}');
    expect(calls.single.url.path, endsWith('/sendAudio'));
    final f = multipartFieldsOf(calls.single);
    expect(f['title'], 'Night Drive');
    expect(f['performer'], 'Neon / Waves');
    expect(f['duration'], '184');
    expect(f['thumbnail'], 'attach://cover');
    expect(_fileNames(calls.single), {'audio': 'Neon Waves - Night Drive.mp3', 'cover': 'cover.jpg'});
    final thumb = img.decodeJpg(_filePart(calls.single, 'cover'))!;
    expect(thumb.width, lessThanOrEqualTo(320));
    expect(thumb.height, lessThanOrEqualTo(320));
  });

  test('Telegram without track details: the file name as title, no performer or thumbnail', () async {
    final calls = <http.Request>[];
    final ctx = _ctx((r) async {
      calls.add(r);
      return _json({'ok': true, 'result': {'message_id': 7}});
    });
    const plain = MediaAttachment(id: 's', path: '/media/s.mp3', mimeType: AudioMimeTypes.mp3, sizeBytes: 74, fileName: 'demo take.mp3');
    await TelegramAdapter().publish(const PostVariant(text: '', media: [plain]),
        fakeAccount('telegram', config: {'chatId': '-1001', 'chatType': 'channel'}), {'bot_token': '1:x'}, ctx);
    final f = multipartFieldsOf(calls.single);
    expect(f['title'], 'demo take');
    expect(f.containsKey('performer'), isFalse);
    expect(f.containsKey('thumbnail'), isFalse);
  });

  test('Mastodon: "Artist – Title" as the description and the cover as the thumbnail', () async {
    final calls = <http.Request>[];
    final ctx = _ctx((r) async {
      calls.add(r);
      if (r.url.path == '/api/v2/media') return _json({'id': 'm1', 'url': 'https://mastodon.example/m1.mp3'});
      return _json({'id': 's1', 'url': 'https://mastodon.example/@me/s1'});
    });
    final adapter = MastodonAdapter(mediaPollInterval: Duration.zero, maxMediaPolls: 1, clock: () => testNow);
    final account = fakeAccount('mastodon', config: {
      'instance': 'https://mastodon.example',
      'domain': 'mastodon.example',
      'software': 'mastodon',
      'maxCharacters': 500,
      'maxMediaAttachments': 4,
      'descriptionLimit': 1500,
    });
    final res = await adapter.publish(const PostVariant(text: 'Out now', media: [_mp3]), account, {'access_token': 'tok'}, ctx);
    expect(res.success, isTrue, reason: '${res.error}');
    final upload = calls.firstWhere((c) => c.url.path == '/api/v2/media');
    expect(multipartFieldsOf(upload)['description'], 'Neon / Waves – Night Drive');
    expect(_fileNames(upload)['thumbnail'], 'cover.jpg');
    expect(_filePart(upload, 'thumbnail'), _cover);
  });

  group('covers that need converting', () {
    final bmp = img.encodeBmp(img.Image(width: 40, height: 30)..clear(img.ColorRgb8(10, 120, 240)));
    final hugePng = img.encodePng(img.Image(width: 2800, height: 2100)..clear(img.ColorRgb8(240, 200, 10)));
    MediaAttachment withCover(String path, String mime) => MediaAttachment(
          id: 'snd2',
          path: '/media/snd2.mp3',
          mimeType: AudioMimeTypes.mp3,
          sizeBytes: 74,
          fileName: 'track02.mp3',
          audioTags: AudioTags(title: 'Night Drive', artist: 'Neon Waves', coverPath: path, coverMimeType: mime),
        );
    AdapterContext ctx(Map<String, Uint8List> covers, Future<http.Response> Function(http.Request r) handler) => AdapterContext(
          http: NeforumHttp(client: MockClient(handler), maxRetries: 0),
          clock: () => testNow,
          readMedia: (m) async => covers[m.path] ?? _sound,
        );
    final mastodon = fakeAccount('mastodon', config: {
      'instance': 'https://mastodon.example',
      'domain': 'mastodon.example',
      'software': 'mastodon',
      'maxCharacters': 500,
      'maxMediaAttachments': 4,
      'descriptionLimit': 1500,
    });
    String? contentTypeOf(http.Request r, String field) {
      final boundary = RegExp(r'boundary=(.+)$').firstMatch(r.headers['content-type']!)!.group(1)!;
      final part = latin1.decode(r.bodyBytes).split('--$boundary').where((p) => p.contains('name="$field"')).firstOrNull;
      final head = part?.substring(0, part.indexOf('\r\n\r\n'));
      return head == null ? null : RegExp(r'content-type: ([^\r\n]+)', caseSensitive: false).firstMatch(head)?.group(1);
    }

    test('Mastodon: a BMP cover goes as a JPEG, a huge PNG as a JPEG of at most 1400 px', () async {
      for (final (path, mime, picture) in [('/media/cover.bmp', 'image/bmp', bmp), ('/media/huge.png', 'image/png', hugePng)]) {
        final calls = <http.Request>[];
        final c = ctx({path: picture}, (r) async {
          calls.add(r);
          if (r.url.path == '/api/v2/media') return _json({'id': 'm1', 'url': 'https://mastodon.example/m1.mp3'});
          return _json({'id': 's1', 'url': 'https://mastodon.example/@me/s1'});
        });
        final adapter = MastodonAdapter(mediaPollInterval: Duration.zero, maxMediaPolls: 1, clock: () => testNow);
        final res = await adapter.publish(PostVariant(text: 'Out now', media: [withCover(path, mime)]), mastodon, {'access_token': 'tok'}, c);
        expect(res.success, isTrue, reason: '${res.error}');
        final upload = calls.firstWhere((r) => r.url.path == '/api/v2/media');
        expect(_fileNames(upload)['thumbnail'], 'cover.jpg', reason: mime);
        expect(contentTypeOf(upload, 'thumbnail'), 'image/jpeg', reason: mime);
        final jpeg = img.decodeJpg(_filePart(upload, 'thumbnail'))!;
        expect(math.max(jpeg.width, jpeg.height), lessThanOrEqualTo(kAudioCoverMaxSide), reason: mime);
      }
    });

    test('Mastodon: a cover the server refuses is dropped and the sound file uploaded again without it', () async {
      final calls = <http.Request>[];
      final c = ctx({'/media/cover.bmp': bmp}, (r) async {
        calls.add(r);
        if (r.url.path == '/api/v2/media') {
          return multipartFieldsOf(r).containsKey('thumbnail')
              ? _json({'error': 'Validation failed: Thumbnail content type is invalid'}, 422)
              : _json({'id': 'm1', 'url': 'https://mastodon.example/m1.mp3'});
        }
        return _json({'id': 's1', 'url': 'https://mastodon.example/@me/s1'});
      });
      final adapter = MastodonAdapter(mediaPollInterval: Duration.zero, maxMediaPolls: 1, clock: () => testNow);
      final res = await adapter.publish(PostVariant(text: 'Out now', media: [withCover('/media/cover.bmp', 'image/bmp')]), mastodon, {'access_token': 'tok'}, c);
      expect(res.success, isTrue, reason: '${res.error}');
      final uploads = calls.where((r) => r.url.path == '/api/v2/media').toList();
      expect(uploads.map((r) => _fileNames(r).keys.toSet()), [
        {'file', 'thumbnail'},
        {'file'},
      ]);
      // A refusal for another reason is not retried.
      calls.clear();
      final denied = ctx({'/media/cover.bmp': bmp}, (r) async {
        calls.add(r);
        return _json({'error': 'The access token is invalid'}, 401);
      });
      final failed = await adapter.publish(PostVariant(text: 'Out now', media: [withCover('/media/cover.bmp', 'image/bmp')]), mastodon, {'access_token': 'tok'}, denied);
      expect(failed.success, isFalse);
      expect(calls.where((r) => r.url.path == '/api/v2/media'), hasLength(1));
    });

    test('Ghost: a BMP cover goes as a JPEG; refused, the sound file goes again without it', () async {
      const key = '6489d8a1b2c3d4e5f6a7b8c9:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      final account = fakeAccount('ghost', config: {'apiUrl': 'https://blog.example.com', 'site': 'https://blog.example.com/'});
      for (final refuse in [false, true]) {
        final calls = <http.Request>[];
        final c = ctx({'/media/cover.bmp': bmp}, (r) async {
          calls.add(r);
          if (r.url.path == '/ghost/api/admin/media/upload/') {
            if (refuse && _fileNames(r).containsKey('thumbnail')) {
              return _json({'errors': [{'type': 'ValidationError', 'message': 'Please select a valid image file.'}]}, 422);
            }
            return _json({'media': [{'url': 'https://blog.example.com/c/a.mp3'}]}, 201);
          }
          return _json({'posts': [{'id': 'abc123', 'status': 'published', 'url': 'https://blog.example.com/new/'}]}, 201);
        });
        final res = await GhostAdapter().publish(PostVariant(title: 'New', text: 'Out now', media: [withCover('/media/cover.bmp', 'image/bmp')]), account, {'admin_api_key': key}, c);
        expect(res.success, isTrue, reason: '${res.error}');
        final uploads = calls.where((r) => r.url.path == '/ghost/api/admin/media/upload/').toList();
        expect(_fileNames(uploads.first)['thumbnail'], 'cover.jpg');
        expect(contentTypeOf(uploads.first, 'thumbnail'), 'image/jpeg');
        expect(img.decodeJpg(_filePart(uploads.first, 'thumbnail')), isNotNull);
        expect(uploads.map((r) => _fileNames(r).containsKey('thumbnail')), refuse ? [true, false] : [true]);
      }
    });

    test('a PNG or JPEG of a sane size goes as it is', () async {
      expect((await audioCoverForUpload(_cover))!, (_cover, 'image/jpeg'));
      final small = img.encodePng(img.Image(width: 300, height: 300));
      expect((await audioCoverForUpload(small))!.$2, 'image/png');
      expect(await audioCoverForUpload(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });

  test('Matrix: the cover as an m.image first, then m.audio with its caption and info', () async {
    final calls = <http.Request>[];
    var n = 0;
    final ctx = _ctx((r) async {
      calls.add(r);
      if (r.url.path.endsWith('/upload')) return _json({'content_uri': 'mxc://example.org/u${++n}'});
      return _json({'event_id': '\$e${calls.length}'});
    });
    final account = fakeAccount('matrix', config: {'homeserver': 'https://matrix.example.org', 'userId': '@a:example.org', 'roomId': '!r:example.org'});
    final res = await MatrixAdapter().publish(const PostVariant(text: '', media: [_mp3]), account, {'access_token': 'tok'}, ctx);
    expect(res.success, isTrue, reason: '${res.error}');
    final events = [for (final c in calls) if (c.method == 'PUT') jsonDecode(c.body) as Map<String, dynamic>];
    expect(events.map((e) => e['msgtype']), ['m.image', 'm.audio']);
    expect(events.first['body'], 'Neon / Waves – Night Drive');
    expect(events.first['url'], 'mxc://example.org/u1');
    final audio = events.last;
    expect(audio['body'], 'Neon / Waves – Night Drive');
    expect(audio['filename'], 'Neon Waves - Night Drive.mp3');
    expect(audio['info'], {'mimetype': 'audio/mpeg', 'size': 74, 'duration': 184000});
    expect(calls.where((c) => c.url.path.endsWith('/upload')).map((c) => c.url.queryParameters['filename']), ['cover.jpg', 'Neon Waves - Night Drive.mp3']);
  });

  test('Matrix: no cover message when the post has photos of its own', () async {
    final calls = <http.Request>[];
    final ctx = _ctx((r) async {
      calls.add(r);
      if (r.url.path.endsWith('/upload')) return _json({'content_uri': 'mxc://example.org/u'});
      return _json({'event_id': '\$e${calls.length}'});
    });
    final account = fakeAccount('matrix', config: {'homeserver': 'https://matrix.example.org', 'userId': '@a:example.org', 'roomId': '!r:example.org'});
    await MatrixAdapter().publish(PostVariant(text: '', media: [fakeImage(), _mp3]), account, {'access_token': 'tok'}, ctx);
    expect(calls.where((c) => c.url.path.endsWith('/upload')), hasLength(2));
  });

  test('Discord: the attachment is named "Artist - Title.mp3" and described', () async {
    final calls = <http.Request>[];
    final ctx = _ctx((r) async {
      calls.add(r);
      return _json({'id': '42', 'channel_id': '555'});
    });
    const hook = 'https://discord.com/api/v10/webhooks/123456789012345678/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcdefghij';
    final account = fakeAccount('discord', config: {'webhookId': '123456789012345678', 'channelId': '555', 'guildId': '777'});
    final res = await DiscordAdapter().publish(const PostVariant(text: 'Out now', media: [_mp3]), account, {'webhook_url': hook}, ctx);
    expect(res.success, isTrue, reason: '${res.error}');
    final f = multipartFieldsOf(calls.single);
    expect(f['files[0]'], '<Neon Waves - Night Drive.mp3>');
    final payload = jsonDecode(f['payload_json']!) as Map<String, dynamic>;
    expect(payload['attachments'], [
      {'id': 0, 'filename': 'Neon Waves - Night Drive.mp3', 'description': 'Neon / Waves – Night Drive'},
    ]);
  });

  test('Misskey: the Drive file name and comment', () async {
    final calls = <http.Request>[];
    final ctx = _ctx((r) async {
      calls.add(r);
      if (r.url.path == '/api/drive/files/create') return _json({'id': 'f1'});
      return _json({'createdNote': {'id': 'n1'}});
    });
    final account = fakeAccount('misskey', config: {'instance': 'https://misskey.example', 'host': 'misskey.example', 'maxNoteTextLength': 3000});
    final res = await MisskeyAdapter().publish(const PostVariant(text: 'Out now', media: [_mp3]), account, {'access_token': 'T'}, ctx);
    expect(res.success, isTrue, reason: '${res.error}');
    final f = multipartFieldsOf(calls.first);
    expect(f['name'], 'Neon Waves - Night Drive.mp3');
    expect(f['comment'], 'Neon / Waves – Night Drive');
  });

  test('WordPress: the media title, caption and the caption under the player', () async {
    final calls = <http.Request>[];
    final ctx = _ctx((r) async {
      calls.add(r);
      final p = r.url.path;
      if (p == '/wp-json/wp/v2/media') return _json({'id': 55, 'source_url': 'https://example.com/a.mp3'}, 201);
      if (p.startsWith('/wp-json/wp/v2/media/')) return _json({'id': 55});
      return _json({'id': 101, 'link': 'https://example.com/?p=101', 'status': 'publish'}, 201);
    });
    final account = fakeAccount('wordpress', config: {'site': 'https://example.com', 'restBase': 'https://example.com/wp-json/', 'username': 'a', 'canPublish': true, 'canUpload': true});
    final res = await WordPressAdapter().publish(const PostVariant(title: 'New', text: 'Out now', media: [_mp3]), account, {'app_password': 'abcdefghijklmnopqrstuvwx'}, ctx);
    expect(res.success, isTrue, reason: '${res.error}');
    final details = bodyOf(calls.firstWhere((c) => c.url.path == '/wp-json/wp/v2/media/55'));
    expect(details, {'title': 'Night Drive', 'caption': 'Neon / Waves – Night Drive (Coastline, 2024)', 'description': 'Neon / Waves – Night Drive (Coastline, 2024)'});
    final post = bodyOf(calls.last);
    expect(post['content'], contains('<figcaption class="wp-element-caption">Neon / Waves – Night Drive (Coastline, 2024)</figcaption>'));
  });

  test('Ghost: the cover goes up as the thumbnail; title and cover in the audio card', () async {
    final calls = <http.Request>[];
    final ctx = _ctx((r) async {
      calls.add(r);
      if (r.url.path == '/ghost/api/admin/media/upload/') {
        return _json({'media': [{'url': 'https://blog.example.com/c/a.mp3', 'thumbnail_url': 'https://blog.example.com/c/a.jpg'}]}, 201);
      }
      return _json({'posts': [{'id': 'abc123', 'status': 'published', 'url': 'https://blog.example.com/new/'}]}, 201);
    });
    final account = fakeAccount('ghost', config: {'apiUrl': 'https://blog.example.com', 'site': 'https://blog.example.com/'});
    const key = '6489d8a1b2c3d4e5f6a7b8c9:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    final res = await GhostAdapter().publish(const PostVariant(title: 'New', text: 'Out now', media: [_mp3]), account, {'admin_api_key': key}, ctx);
    expect(res.success, isTrue, reason: '${res.error}');
    expect(_fileNames(calls.first), {'file': 'Neon Waves - Night Drive.mp3', 'thumbnail': 'cover.jpg'});
    final html = ((bodyOf(calls.last)['posts'] as List).single as Map)['html'] as String;
    expect(html, contains('<img class="kg-audio-thumbnail" src="https://blog.example.com/c/a.jpg"'));
    expect(html, contains('<figcaption>Neon / Waves – Night Drive (Coastline, 2024)</figcaption>'));
  });

  test('Odysee: the track as title and description when the post has neither', () {
    const bare = PostVariant(text: '', media: [_mp3]);
    expect(OdyseeAdapter.odyseeTitle(bare), 'Neon / Waves – Night Drive');
    expect(OdyseeAdapter.odyseeDescription(bare), 'Neon / Waves – Night Drive (Coastline, 2024)');
    const written = PostVariant(text: 'My words', title: 'Mine', media: [_mp3]);
    expect(OdyseeAdapter.odyseeTitle(written), 'Mine');
    expect(OdyseeAdapter.odyseeDescription(written), 'My words');
  });

  test('Tumblr link card: the track as its title, the album as its description', () async {
    final host = FakeMediaHost();
    final ctx = AdapterContext(http: NeforumHttp(client: MockClient((r) async => _json({}))), mediaHost: host, readMedia: (m) async => _sound);
    final v = await withAudioLinks(const PostVariant(text: 'Out now', media: [_mp3]), ctx, platform: 'Tumblr', linkCard: true);
    expect(v.media, isEmpty);
    expect(v.text, 'Out now');
    expect(v.link, 'https://cdn.example.test/snd1');
    expect(v.extra['linkTitle'], 'Neon / Waves – Night Drive');
    expect(v.extra['linkDescription'], 'Coastline · 2024');
    // Without the card (and in Markdown), the link names the track.
    final md = await withAudioLinks(const PostVariant(text: 'x', media: [_mp3]), ctx, platform: 'WriteFreely', markdown: true);
    expect(md.text, 'x\n\n[Neon / Waves – Night Drive (MP3)](https://cdn.example.test/snd1)');
  });
}
