import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/audio_links.dart';
import 'package:neforum_core/src/adapters/blogs_a/ghost_adapter.dart';
import 'package:neforum_core/src/adapters/blogs_a/wordpress_adapter.dart';
import 'package:neforum_core/src/adapters/chat/discord_adapter.dart';
import 'package:neforum_core/src/adapters/chat/matrix_adapter.dart';
import 'package:neforum_core/src/adapters/chat/telegram_adapter.dart';
import 'package:neforum_core/src/adapters/lemmy/lemmy_adapter.dart';
import 'package:neforum_core/src/adapters/mastodon/mastodon_descriptor.dart';
import 'package:neforum_core/src/adapters/mastodon/mastodon_instance.dart';
import 'package:neforum_core/src/adapters/video_sites/odysee_adapter.dart';
import 'package:test/test.dart';

import 'support/test_context.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: jsonHeaders);

MediaAttachment _sound({
  String id = 'snd1',
  String mimeType = AudioMimeTypes.mp3,
  String? codec = AudioCodecs.mp3,
  String? fileName,
  int sizeBytes = 4 * 1024 * 1024,
  int? durationMs = 184000,
  bool generated = false,
  String? derivedFrom,
}) =>
    MediaAttachment(
      id: id,
      path: '/tmp/$id.${audioExtensionFor(mimeType)}',
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      durationMs: durationMs,
      fileName: fileName ?? 'Demo track.${audioExtensionFor(mimeType)}',
      audioCodec: codec,
      generated: generated,
      derivedFrom: derivedFrom,
    );

MediaAttachment _flac() => _sound(id: 'flac1', mimeType: AudioMimeTypes.flac, codec: AudioCodecs.flac, sizeBytes: 30 * 1024 * 1024);

/// A media host whose links expire, like litterbox.
class _TemporaryHost extends FakeMediaHost {
  @override
  String get name => 'Temporary host';

  @override
  Future<HostedMedia> upload(MediaAttachment media, Uint8List bytes, {Duration? ttl}) async {
    uploaded.add(media);
    return HostedMedia(hostId: id, url: Uri.parse('https://tmp.example.test/${media.id}'), expiresAt: testNow.add(const Duration(hours: 1)));
  }
}

const _tgToken = '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw';
const _ghostKey = '6489d8a1b2c3d4e5f6a7b8c9:${'0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'}';

void main() {
  group('sound file model', () {
    test('MIME aliases fold to one canonical type each', () {
      expect(canonicalAudioMimeType('audio/x-wav'), AudioMimeTypes.wav);
      expect(canonicalAudioMimeType('audio/vnd.wave'), AudioMimeTypes.wav);
      expect(canonicalAudioMimeType('audio/x-m4a'), AudioMimeTypes.m4a);
      expect(canonicalAudioMimeType('audio/x-flac'), AudioMimeTypes.flac);
      expect(canonicalAudioMimeType('audio/x-aiff'), AudioMimeTypes.aiff);
      expect(canonicalAudioMimeType('audio/ogg; codecs=opus'), AudioMimeTypes.ogg);
      expect(canonicalAudioMimeType('audio/mp3'), AudioMimeTypes.mp3);
      expect(canonicalAudioMimeType('audio/midi'), isNull);
      expect(canonicalAudioMimeType('video/mp4'), isNull);
    });

    test('lossless: WAV, AIFF, FLAC and Apple Lossless; never MP3 or AAC', () {
      expect(_flac().isLosslessAudio, isTrue);
      expect(_sound(mimeType: AudioMimeTypes.wav, codec: AudioCodecs.pcm).isLosslessAudio, isTrue);
      expect(_sound(mimeType: AudioMimeTypes.aiff, codec: null).isLosslessAudio, isTrue, reason: 'container alone');
      expect(_sound(mimeType: AudioMimeTypes.m4a, codec: AudioCodecs.alac).isLosslessAudio, isTrue);
      expect(_sound(mimeType: AudioMimeTypes.m4a, codec: AudioCodecs.aac).isLosslessAudio, isFalse);
      expect(_sound(mimeType: AudioMimeTypes.m4a, codec: null).isLosslessAudio, isFalse, reason: 'unknown M4A is not claimed lossless');
      expect(_sound(mimeType: AudioMimeTypes.wav, codec: AudioCodecs.mp3).isLosslessAudio, isFalse, reason: 'MP3 inside a WAV');
      expect(_sound().isLosslessAudio, isFalse);
      expect(_sound().isMp3, isTrue);
      expect(fakeImage().isLosslessAudio, isFalse);
      expect(_sound().noun, 'sound file');
    });

    test('codec and quality survive JSON; Standard is not written', () {
      final m = MediaAttachment.fromJson(_sound(mimeType: AudioMimeTypes.m4a, codec: AudioCodecs.alac).toJson());
      expect(m.audioCodec, AudioCodecs.alac);
      expect(m.isAudio, isTrue);
      final post = Post(id: 'p', text: 'x', createdAt: testNow, updatedAt: testNow, audioQuality: AudioQuality.lossless);
      expect(post.toJson()['audioQuality'], 'lossless');
      expect(Post.fromJson(post.toJson()).audioQuality, AudioQuality.lossless);
      final standard = post.copyWith(audioQuality: AudioQuality.standard);
      expect(standard.toJson().containsKey('audioQuality'), isFalse);
      expect(Post.fromJson({...standard.toJson(), 'audioQuality': 'surround'}).audioQuality, AudioQuality.standard);
    });

    test('link labels name the track and its type', () {
      expect(audioLinkLabel(_flac()), 'Demo track (FLAC)');
      expect(audioLinkLabel(_sound(mimeType: AudioMimeTypes.m4a, codec: AudioCodecs.alac, fileName: 'Mix [final].m4a')), 'Mix final (Apple Lossless)');
      expect(audioLinkLabel(_sound(fileName: '')), 'Listen (MP3)');
    });
  });

  group('rules per network', () {
    final registry = builtinRegistry();
    MediaRules media(String id) => registry.byId(id)!.descriptor.media;

    test('networks that take sound as sound', () {
      for (final id in ['telegram', 'discord', 'matrix', 'mastodon', 'misskey', 'wordpress', 'ghost', 'odysee']) {
        final m = media(id);
        expect(m.supportsAudio, isTrue, reason: id);
        expect(m.audioMimeTypes, contains(AudioMimeTypes.mp3), reason: id);
        expect(m.audioAsVideo || m.audioAsLink, isFalse, reason: id);
      }
      expect(media('telegram').audioMaxBytes, 50 * 1024 * 1024);
      expect(media('discord').audioMaxBytes, discordFileMaxBytes);
      expect(media('mastodon').keepsAudioBytes, isFalse, reason: 'Mastodon makes its own MP3');
      expect(media('mastodon').audioMimeTypes, isNot(contains(AudioMimeTypes.aiff)));
      expect(media('ghost').audioMimeTypes, isNot(contains(AudioMimeTypes.flac)));
      for (final id in ['telegram', 'discord', 'matrix', 'misskey', 'wordpress', 'ghost', 'odysee']) {
        expect(media(id).keepsAudioBytes, isTrue, reason: id);
      }
      expect(media('telegram').audioWithOtherMedia, isFalse);
      expect(media('discord').audioWithOtherMedia, isTrue);
    });

    test('video-only networks take the track as a video', () {
      for (final id in ['x', 'bluesky', 'instagram', 'threads', 'facebook', 'tiktok', 'youtube', 'linkedin', 'pinterest']) {
        final m = media(id);
        expect(m.audioAsVideo, isTrue, reason: id);
        expect(m.supportsAudio, isFalse, reason: id);
        expect(m.maxVideos, greaterThan(0), reason: id);
      }
    });

    test('link-only networks take the track as a link', () {
      for (final id in ['nostr', 'lemmy', 'reddit', 'devto', 'hashnode', 'micropub', 'writefreely', 'tumblr']) {
        expect(media(id).audioAsLink, isTrue, reason: id);
        expect(media(id).supportsAudio, isFalse, reason: id);
      }
    });

    test('a Mastodon-API server takes the sound types it lists, else a video', () {
      final listed = MastodonInstanceProfile(
          baseUrl: 'https://m.example', domain: 'm.example', supportedMimeTypes: const ['image/png', 'video/mp4', 'audio/wave', 'audio/x-m4a', 'audio/mpeg']);
      final d = mastodonDescriptorFor(listed).media;
      expect(d.audioMimeTypes, {AudioMimeTypes.wav, AudioMimeTypes.m4a, AudioMimeTypes.mp3});
      expect(d.supportsAudio, isTrue);
      final silent = MastodonInstanceProfile(
          baseUrl: 'https://g.example', domain: 'g.example', supportedMimeTypes: const ['image/png', 'video/mp4']);
      final g = mastodonDescriptorFor(silent).media;
      expect(g.supportsAudio, isFalse);
      expect(g.audioAsVideo, isTrue);
    });
  });

  group('resolver and checks', () {
    const resolver = VariantResolver();
    Post post(List<MediaAttachment> media) => Post(id: 'p', text: 'New track', createdAt: testNow, updatedAt: testNow, media: media);
    const target = PostTarget(accountId: 'a');
    final registry = builtinRegistry();

    PostVariant resolve(String id, List<MediaAttachment> media) => resolver.resolve(post(media), target, registry.byId(id)!.descriptor);
    List<ValidationIssue> check(String id, PostVariant v) => RulesValidator.validate(v, registry.byId(id)!.descriptor);

    test('a network that takes sound keeps it; photos go when they cannot share the post', () {
      final tg = resolve('telegram', [fakeImage(), _sound()]);
      expect(tg.media.map((m) => m.id), ['snd1']);
      expect(tg.issues.map((i) => i.code), contains('media.audio_alone'));
      expect(check('telegram', tg).hasErrors, isFalse);
      final discord = resolve('discord', [fakeImage(), _sound()]);
      expect(discord.media.map((m) => m.id), ['img1', 'snd1']);
    });

    test('a type the network refuses stays, and the check says why', () {
      final aiff = _sound(id: 'a1', mimeType: AudioMimeTypes.aiff, codec: AudioCodecs.pcm);
      final v = resolve('mastodon', [aiff]);
      expect(v.media, [aiff]);
      expect(check('mastodon', v).map((i) => (i.code, i.message)), contains(('media.audio_type', 'Mastodon does not take AIFF files')));
    });

    test('too large and too many', () {
      final big = _sound(sizeBytes: 60 * 1024 * 1024);
      expect(check('telegram', PostVariant(text: 'x', media: [big])).map((i) => i.code), contains('media.audio_too_large'));
      final two = resolve('telegram', [_sound(), _sound(id: 'snd2')]);
      expect(two.media, hasLength(1));
      expect(two.issues.map((i) => i.code), contains('media.audio_dropped'));
    });

    test('video-only: the track waits for its video; still sound means the device could not make it', () {
      final v = resolve('bluesky', [_sound()]);
      expect(v.media.single.isAudio, isTrue);
      final issues = check('bluesky', v);
      expect(issues.errors.map((i) => i.message), ["Bluesky takes sound only as a video; this device can't make one"]);
    });

    test('link-only: kept for the adapter, with a notice', () {
      final v = resolve('lemmy', [_sound()]);
      expect(v.media.single.isAudio, isTrue);
      expect(check('lemmy', v).map((i) => i.code), contains('media.audio_link'));
      expect(check('lemmy', v).hasErrors, isFalse);
    });

    test('no way to take sound at all: left out with a warning', () {
      final v = resolve('snapchat', [_sound()]);
      expect(v.media, isEmpty);
      expect(v.issues.map((i) => i.code), contains('media.audio_dropped'));
    });

    test('sound checks count each post of a thread, like photos and videos', () {
      PostVariant thread(List<MediaAttachment> media) => resolver.resolve(
          Post(
              id: 'p',
              text: 'Part one',
              additionalParts: const ['Part two'],
              media: media,
              mediaParts: const {'s1': 1},
              createdAt: testNow,
              updatedAt: testNow),
          target,
          mastodonDescriptor);
      // A photo in part one and the sound file in part two: fine per post.
      final mixed = thread([fakeImage(id: 'i1'), _sound(id: 's1')]);
      expect(mixed.mediaPartIndexes, [0, 1]);
      expect(RulesValidator.validate(mixed, mastodonDescriptor).errors, isEmpty);
      // One sound file in each part.
      final two = thread([_sound(id: 's0'), _sound(id: 's1')]);
      expect(two.media, hasLength(2));
      expect(RulesValidator.validate(two, mastodonDescriptor).errors, isEmpty);
      // Two in one post is still too many.
      final crowded = PostVariant(text: 'x', media: [_sound(id: 's0'), _sound(id: 's1')]);
      expect(RulesValidator.validate(crowded, mastodonDescriptor).map((i) => i.code), contains('media.too_many_audios'));
    });

    test('video-only: the track counts as the video it becomes, and the first photo as its picture', () {
      final video = MediaAttachment(id: 'v1', path: '/tmp/v1.mp4', mimeType: 'video/mp4', sizeBytes: 1024);
      // Bluesky takes one video per post and does not mix it with photos:
      // the second video goes on in the next post of the thread (1.3.4).
      final withVideo = resolve('bluesky', [_sound(), video]);
      expect(withVideo.media.map((m) => m.id), ['snd1', 'v1']);
      expect(withVideo.mediaOfPart(0).map((m) => m.id), ['snd1']);
      expect(withVideo.mediaOfPart(1).map((m) => m.id), ['v1']);
      expect(withVideo.threadParts, hasLength(2));
      expect(withVideo.issues.map((i) => i.code), isNot(contains('media.dropped')));
      final withPicture = resolve('bluesky', [fakeImage(id: 'cover'), _sound()]);
      expect(withPicture.media.map((m) => m.id), ['cover', 'snd1'], reason: 'the picture is part of the video, not a mix');
      expect(withPicture.issues.map((i) => i.code), isNot(contains('media.dropped')));
    });

    test('sound never asks for alt text', () {
      final issues = check('mastodon', PostVariant(text: 'x', media: [_sound()]));
      expect(issues.map((i) => i.code), isNot(contains('media.no_alt')));
    });
  });

  group('Telegram', () {
    final adapter = TelegramAdapter();
    final account = fakeAccount('telegram', config: {'chatId': '-1001234567890', 'chatUsername': 'mychan', 'formatting': 'markdown'});

    test('MP3 and AAC play in the chat; lossless and Ogg go as documents', () {
      expect(telegramPlaysAudio(_sound()), isTrue);
      expect(telegramPlaysAudio(_sound(mimeType: AudioMimeTypes.m4a, codec: AudioCodecs.aac)), isTrue);
      expect(telegramPlaysAudio(_sound(mimeType: AudioMimeTypes.m4a, codec: AudioCodecs.alac)), isFalse);
      expect(telegramPlaysAudio(_flac()), isFalse);
      expect(telegramPlaysAudio(_sound(mimeType: AudioMimeTypes.ogg, codec: AudioCodecs.opus)), isFalse);
    });

    test('MP3: sendAudio with title and duration', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'ok': true, 'result': {'message_id': 70}});
      });
      final res = await adapter.publish(PostVariant(text: 'New song', media: [_sound()], sensitive: true), account, {'bot_token': _tgToken}, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(calls.single.url.path, endsWith('/sendAudio'));
      expect(multipartFieldsOf(calls.single), {
        'chat_id': '-1001234567890',
        'caption': 'New song',
        'duration': '184',
        'title': 'Demo track',
        'audio': '<Demo track.mp3>',
      });
    });

    test('FLAC: sendDocument, unchanged, without type detection', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'ok': true, 'result': {'message_id': 71}});
      });
      final res = await adapter.publish(PostVariant(text: 'Master', media: [_flac()]), account, {'bot_token': _tgToken}, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(calls.single.url.path, endsWith('/sendDocument'));
      expect(multipartFieldsOf(calls.single), {
        'chat_id': '-1001234567890',
        'caption': 'Master',
        'disable_content_type_detection': 'true',
        'document': '<Demo track.flac>',
      });
    });
  });

  group('Matrix', () {
    test('a sound file is an m.audio event with its duration', () {
      final content = matrixMediaContent(_flac(), 'mxc://hs.example/abc');
      expect(content['msgtype'], 'm.audio');
      expect(content['url'], 'mxc://hs.example/abc');
      expect(content['body'], 'Demo track.flac');
      expect(content['info'], {'mimetype': 'audio/flac', 'size': 30 * 1024 * 1024, 'duration': 184000});
    });
  });

  group('WordPress', () {
    final wp = WordPressAdapter();
    final account = fakeAccount('wordpress', config: {
      'site': 'https://example.com',
      'restBase': 'https://example.com/wp-json/',
      'username': 'alice',
      'canPublish': true,
      'canUpload': true,
    });

    test('upload, then an audio block in the post', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path == '/wp-json/wp/v2/media') return _json({'id': 77, 'source_url': 'https://example.com/wp-content/uploads/demo.flac'}, 201);
        return _json({'id': 5, 'link': 'https://example.com/?p=5', 'status': 'publish'}, 201);
      });
      final res = await wp.publish(PostVariant(title: 'Release', text: 'Out now.', media: [_flac()]), account, const {'app_password': 'abcdefghijklmnopqrstuvwx'}, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(calls.map((c) => '${c.method} ${c.url.path}'), ['POST /wp-json/wp/v2/media', 'POST /wp-json/wp/v2/posts']);
      expect(calls[0].headers['content-type'], 'audio/flac');
      expect(calls[0].headers['content-disposition'], 'attachment; filename="Demo-track.flac"');
      final body = bodyOf(calls[1]);
      expect(body['content'], '<p>Out now.</p>\n\n${wordPressAudioBlock(77, 'https://example.com/wp-content/uploads/demo.flac')}');
      expect(body.containsKey('featured_media'), isFalse, reason: 'a sound file is never the featured image');
      expect(wordPressAudioBlock(77, 'https://x.test/a.mp3'),
          '<!-- wp:audio {"id":77} -->\n<figure class="wp-block-audio"><audio controls src="https://x.test/a.mp3"></audio></figure>\n<!-- /wp:audio -->');
    });
  });

  group('Ghost', () {
    final ghost = GhostAdapter();
    final account = fakeAccount('ghost', config: {'apiUrl': 'https://blog.example.com', 'site': 'https://blog.example.com/'});

    test('media upload, then the player in an HTML card', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path == '/ghost/api/admin/media/upload/') {
          return _json({'media': [{'url': 'https://blog.example.com/content/media/demo.mp3', 'ref': 'x'}]}, 201);
        }
        return _json({'posts': [{'id': 'p1', 'url': 'https://blog.example.com/release/', 'status': 'published'}]}, 201);
      });
      final res = await ghost.publish(PostVariant(title: 'Release', text: 'Out now.', media: [_sound()]), account, const {'admin_api_key': _ghostKey}, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(calls.map((c) => '${c.method} ${c.url.path}'), ['POST /ghost/api/admin/media/upload/', 'POST /ghost/api/admin/posts/']);
      expect(multipartFieldsOf(calls[0]), {'ref': 'Demo-track.mp3', 'file': '<Demo-track.mp3>'});
      final post = (bodyOf(calls[1])['posts'] as List).single as Map;
      expect(post['html'], '<p>Out now.</p>\n\n${ghostAudioHtml('https://blog.example.com/content/media/demo.mp3')}');
      expect(post.containsKey('feature_image'), isFalse);
      expect(ghostAudioHtml('https://x.test/a.mp3'), startsWith('<!--kg-card-begin: html-->'));
      expect(ghostAudioHtml('https://x.test/a.mp3', htmlCard: false), startsWith('<figure class="kg-card kg-audio-card">'));
    });
  });

  group('Odysee', () {
    test('a sound file is published from its file, as it is', () async {
      final params = <Map<String, dynamic>>[];
      final ctx = testContext(handler: (r) async {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        params.add(Map<String, dynamic>.from(body['params'] as Map));
        return _json({'result': {'outputs': [{'claim_id': 'c1', 'name': 'release'}]}});
      });
      final account = fakeAccount('odysee', config: {'daemon': 'http://localhost:5279', 'bid': '0.001'});
      final res = await OdyseeAdapter().publish(PostVariant(text: 'Out now', title: 'Release', media: [_flac()]), account, const {}, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(params.single['file_path'], '/tmp/flac1.flac');
      expect(params.single.containsKey('optimize_file'), isFalse, reason: 'no re-encoding');
    });
  });

  group('links on link-only networks', () {
    test('the file goes on the media host and its link ends the text', () async {
      final host = FakeMediaHost();
      final ctx = testContext(handler: (_) async => _json({}), mediaHost: host);
      final v = await withAudioLinks(PostVariant(text: 'New track', media: [fakeImage(), _flac()]), ctx, platform: 'Lemmy', markdown: true);
      expect(host.uploaded.map((m) => m.id), ['flac1']);
      expect(v.text, 'New track\n\n[Demo track (FLAC)](https://cdn.example.test/flac1)');
      expect(v.media.map((m) => m.id), ['img1']);
    });

    test('a thread gets the link in its last part', () async {
      final ctx = testContext(handler: (_) async => _json({}), mediaHost: FakeMediaHost());
      final v = await withAudioLinks(PostVariant(text: 'one', threadParts: const ['one', 'two'], media: [_sound()]), ctx, platform: 'Nostr');
      expect(v.threadParts, ['one', 'two\n\nhttps://cdn.example.test/snd1']);
      expect(v.text, 'one');
    });

    test('the photos of a thread keep their parts when the sound file leaves', () async {
      final ctx = testContext(handler: (_) async => _json({}), mediaHost: FakeMediaHost());
      final v = await withAudioLinks(
          PostVariant(
              text: 'one',
              threadParts: const ['one', 'two', 'three'],
              media: [fakeImage(id: 'a'), _sound(), fakeImage(id: 'b')],
              mediaPartIndexes: const [0, 1, 2]),
          ctx,
          platform: 'Nostr');
      expect(v.media.map((m) => m.id), ['a', 'b']);
      expect(v.mediaPartIndexes, [0, 2]);
      expect(v.mediaOfPart(2).map((m) => m.id), ['b']);
    });

    test('no media host, or one with temporary links: a clear failure', () async {
      final none = testContext(handler: (_) async => _json({}));
      expect(
          () => withAudioLinks(PostVariant(text: 'x', media: [_sound()]), none, platform: 'Reddit'),
          throwsA(isA<AdapterException>()
              .having((e) => e.error.message, 'message', contains('Reddit takes a sound file only as a link'))
              .having((e) => e.error.kind, 'kind', PublishErrorKind.configuration)));
      final host = _TemporaryHost();
      final temp = testContext(handler: (_) async => _json({}), mediaHost: host);
      await expectLater(
          () => withAudioLinks(PostVariant(text: 'x', media: [_sound()]), temp, platform: 'Reddit'),
          throwsA(isA<AdapterException>().having((e) => e.error.message, 'message', contains('only makes temporary links'))));
      expect(host.deleted, hasLength(1), reason: 'the temporary copy is removed');
      final unchanged = PostVariant(text: 'x', media: [fakeImage()]);
      expect(await withAudioLinks(unchanged, none, platform: 'Reddit'), same(unchanged));
    });

    test('Lemmy posts the link in the body', () async {
      final calls = <http.Request>[];
      final ctx = testContext(
          handler: (r) async {
            calls.add(r);
            return _json({'post_view': {'post': {'id': 9, 'ap_id': 'https://lemmy.example/post/9'}}});
          },
          mediaHost: FakeMediaHost());
      final account = fakeAccount('lemmy', config: {'instance': 'https://lemmy.example', 'community': 'music@lemmy.example', 'communityId': 12});
      final res = await LemmyAdapter().publish(PostVariant(title: 'New track', text: 'Listen', media: [_sound()]), account,
          const {'access_token': 'JWT123', 'token_type': 'Bearer'}, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(calls.single.url.path, '/api/v3/post');
      expect(bodyOf(calls.single)['body'], 'Listen\n\n[Demo track (MP3)](https://cdn.example.test/snd1)');
    });
  });
}
