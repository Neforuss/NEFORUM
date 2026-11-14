// 1.4.3: a single long post whose paragraphs are linked to its photos and
// videos, resolved for each network and published with every request
// captured. Without links each network gets what it always got.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/chat/discord_adapter.dart';
import 'package:neforum_core/src/adapters/chat/telegram_adapter.dart';
import 'package:neforum_core/src/adapters/facebook/facebook_adapter.dart';
import 'package:neforum_core/src/adapters/instagram/instagram_adapter.dart';
import 'package:neforum_core/src/adapters/linkedin/linkedin_adapter.dart';
import 'package:neforum_core/src/adapters/tumblr/tumblr_adapter.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

const _text = 'Intro line.\n\nFirst place.\n\nSecond place, with two views.\n\nThanks for reading.';

/// Paragraph 1 refers to photo a, paragraph 2 to photos b and c. The user
/// attached them in another order.
const ParagraphMediaLinks _links = {1: ['a'], 2: ['b', 'c']};

Post _post({String text = _text, ParagraphMediaLinks links = _links, List<MediaAttachment>? media, PostOverrides overrides = const PostOverrides()}) =>
    Post(
      id: 'p',
      text: text,
      media: media ?? [fakeImage(id: 'c'), fakeImage(id: 'a'), fakeImage(id: 'b')],
      paragraphMedia: links,
      createdAt: testNow,
      updatedAt: testNow,
      targets: [PostTarget(accountId: 'acct-1', overrides: overrides)],
    );

PostVariant _resolve(PlatformAdapter adapter, Post post, ConnectedAccount account) =>
    const VariantResolver().resolve(post, post.targets.single, adapter.descriptorForAccount(account), account: account);

http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: jsonHeaders);

String _path(http.Request r) => r.url.path.split('/').last;

void main() {
  // ================================================================ Telegram
  group('Telegram', () {
    const token = '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw';
    final adapter = TelegramAdapter();
    final account = fakeAccount('telegram', config: {'chatId': '-1001234567890', 'chatUsername': 'mychan', 'formatting': 'plain'});

    Future<(PublishResult, List<http.Request>)> publish(PostVariant v) async {
      final calls = <http.Request>[];
      var next = 10;
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path.endsWith('/sendMediaGroup')) {
          return _json({'ok': true, 'result': [{'message_id': next++}, {'message_id': next++}]});
        }
        return _json({'ok': true, 'result': {'message_id': next++}});
      });
      final res = await adapter.publish(v, account, const {'bot_token': token}, ctx);
      return (res, calls);
    }

    test('each paragraph with its photos: a caption under each, in reading order', () async {
      final v = _resolve(adapter, _post(), account);
      expect(adapter.validate(v, account).hasErrors, isFalse);
      final (res, calls) = await publish(v);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(calls.map(_path), ['sendPhoto', 'sendMediaGroup', 'sendMessage']);
      final photo = multipartFieldsOf(calls[0]);
      expect(photo['photo'], '<a.jpg>');
      expect(photo['caption'], 'Intro line.\n\nFirst place.');
      final album = multipartFieldsOf(calls[1]);
      expect([album['file0'], album['file1']], ['<b.jpg>', '<c.jpg>']);
      final items = (jsonDecode(album['media']!) as List).cast<Map<String, dynamic>>();
      expect(items[0]['caption'], 'Second place, with two views.');
      expect(items[1].containsKey('caption'), isFalse);
      expect(bodyOf(calls[2])['text'], 'Thanks for reading.');
      expect(res.threadRemoteIds, ['10', '11', '13']);
      expect(adapter.progressShape(v, account).steps, 3);
    });

    test('a paragraph longer than a caption goes first, then its photo; a very long one is cut to messages', () async {
      final long = 'L ${'word ' * 300}'.trim(); // ~1500 characters
      final huge = 'H ${'word ' * 1000}'.trim(); // ~5000 characters
      final v = _resolve(adapter, _post(text: '$long\n\n$huge', links: const {0: ['a'], 1: ['b']}, media: [fakeImage(id: 'a'), fakeImage(id: 'b')]), account);
      expect(v.threadParts, isEmpty, reason: 'the adapter cuts the sections itself');
      expect(adapter.validate(v, account).hasErrors, isFalse);
      final (res, calls) = await publish(v);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(calls.map(_path), ['sendMessage', 'sendPhoto', 'sendMessage', 'sendMessage', 'sendPhoto']);
      expect(bodyOf(calls[0])['text'], long);
      expect(multipartFieldsOf(calls[1]).containsKey('caption'), isFalse);
      final pieces = [bodyOf(calls[2])['text'] as String, bodyOf(calls[3])['text'] as String];
      expect(pieces.every((p) => p.length <= telegramMaxText), isTrue);
      expect(pieces.join(' '), huge);
    });

    test('no links: album with the text as its caption, as before (regression)', () async {
      final v = _resolve(adapter, _post(links: const {}), account);
      expect(v.paragraphMedia, isEmpty);
      final (res, calls) = await publish(v);
      expect(res.success, isTrue);
      expect(calls.map(_path), ['sendMediaGroup']);
      final album = multipartFieldsOf(calls.single);
      expect([album['file0'], album['file1'], album['file2']], ['<c.jpg>', '<a.jpg>', '<b.jpg>']);
      expect(((jsonDecode(album['media']!) as List).first as Map)['caption'], _text);
    });

    test('a hand-off account ignores the links', () {
      final handoff = fakeAccount('telegram', tier: PlatformTier.handoff);
      expect(_resolve(adapter, _post(), handoff).paragraphMedia, isEmpty);
    });
  });

  // ================================================================= Discord
  group('Discord', () {
    const hook = 'https://discord.com/api/v10/webhooks/123456789012345678/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789';
    final adapter = DiscordAdapter();
    final account = fakeAccount('discord', config: {'webhookId': '123456789012345678', 'channelId': '555', 'guildId': '777'});

    Map<String, dynamic> payload(http.Request r) {
      final f = multipartFieldsOf(r);
      return f.containsKey('payload_json') ? jsonDecode(f['payload_json']!) as Map<String, dynamic> : bodyOf(r);
    }

    Future<(PublishResult, List<http.Request>)> publish(PostVariant v) async {
      final calls = <http.Request>[];
      var n = 0;
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'id': '${++n}', 'channel_id': '555'});
      });
      return (await adapter.publish(v, account, const {'webhook_url': hook}, ctx), calls);
    }

    test('messages in order, each paragraph with its files right under it', () async {
      final v = _resolve(adapter, _post(), account);
      final (res, calls) = await publish(v);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(calls.map(payload).map((p) => p['content']), ['Intro line.\n\nFirst place.', 'Second place, with two views.', 'Thanks for reading.']);
      expect(multipartFieldsOf(calls[0])['files[0]'], '<a.jpg>');
      expect([multipartFieldsOf(calls[1])['files[0]'], multipartFieldsOf(calls[1])['files[1]']], ['<b.jpg>', '<c.jpg>']);
      expect(calls[2].headers['content-type'], contains('application/json'));
      expect(res.threadRemoteIds, ['1', '2', '3']);
    });

    test('@everyone goes on the first message only', () async {
      final v = _resolve(adapter, _post(overrides: const PostOverrides(extra: {'mentionEveryone': true})), account);
      final (_, calls) = await publish(v);
      expect(payload(calls[0])['content'], '@everyone\nIntro line.\n\nFirst place.');
      expect(payload(calls[0])['allowed_mentions'], {'parse': ['everyone']});
      expect(payload(calls[1])['allowed_mentions'], {'parse': <String>[]});
      expect(multipartFieldsOf(calls[0])['files[0]'], '<a.jpg>');
    });

    test('no links: one message with every file, as before (regression)', () async {
      final v = _resolve(adapter, _post(links: const {}), account);
      final (res, calls) = await publish(v);
      expect(res.success, isTrue);
      expect(calls, hasLength(1));
      expect(payload(calls.single)['content'], _text);
      final f = multipartFieldsOf(calls.single);
      expect([f['files[0]'], f['files[1]'], f['files[2]']], ['<c.jpg>', '<a.jpg>', '<b.jpg>']);
    });
  });

  // ================================================================== Tumblr
  group('Tumblr', () {
    final adapter = TumblrAdapter();
    final account = fakeAccount('tumblr', tier: PlatformTier.byokApi, config: const {'blogName': 'myblog', 'blogUuid': 't:Abc'});
    final secrets = {
      'consumer_secret': 's',
      'access_token': 'AT',
      'token_type': 'bearer',
      'expires_at': testNow.add(const Duration(hours: 1)).toIso8601String(),
    };

    Future<List<Map<String, dynamic>>> content(PostVariant v) async {
      http.Request? sent;
      final ctx = testContext(handler: (r) async {
        sent = r;
        return _json({'meta': {'status': 201}, 'response': {'id': '42'}}, 201);
      });
      final res = await adapter.publish(v, account, secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      final json = jsonDecode(multipartFieldsOf(sent!)['json']!) as Map<String, dynamic>;
      return (json['content'] as List).cast<Map<String, dynamic>>();
    }

    String describe(Map<String, dynamic> b) =>
        b['type'] == 'text' ? 'text:${b['text']}' : '${b['type']}:${((b['media'] as List).first as Map)['identifier']}';

    test('NPF blocks interleave each paragraph and its media in order', () async {
      final v = _resolve(adapter, _post(), account);
      final blocks = await content(v);
      expect(blocks.map(describe), [
        'text:Intro line.',
        'text:First place.',
        'image:media0',
        'text:Second place, with two views.',
        'image:media1',
        'image:media2',
        'text:Thanks for reading.',
      ]);
      expect([for (final m in v.media) m.id], ['a', 'b', 'c']);
    });

    test('no links: media first, then the text, as before (regression)', () async {
      final blocks = await content(_resolve(adapter, _post(links: const {}), account));
      expect(blocks.map(describe), [
        'image:media0',
        'image:media1',
        'image:media2',
        'text:Intro line.',
        'text:First place.',
        'text:Second place, with two views.',
        'text:Thanks for reading.',
      ]);
    });
  });

  // ================================================================ Facebook
  group('Facebook', () {
    final adapter = FacebookAdapter();
    final account = fakeAccount('facebook', tier: PlatformTier.byokApi, config: const {'page_id': '123', 'app_id': '9', 'page_name': 'P'});

    Future<List<http.Request>> publish(PostVariant v) async {
      final calls = <http.Request>[];
      var n = 0;
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path.endsWith('/photos')) return _json({'id': 'p${++n}'});
        return _json({'id': '123_9'});
      });
      final res = await adapter.publish(v, account, const {'access_token': 'T', 'app_secret': 'S'}, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      return calls;
    }

    test('photos in paragraph order, numbered after their paragraphs', () async {
      final calls = await publish(_resolve(adapter, _post(), account));
      expect([for (final c in calls.take(3)) multipartFieldsOf(c)['source']], ['<a.jpg>', '<b.jpg>', '<c.jpg>']);
      expect(bodyOf(calls[3])['message'], 'Intro line.\n\nFirst place. (1/3)\n\nSecond place, with two views. (2-3/3)\n\nThanks for reading.');
    });

    test('no links: the photos and text as before (regression)', () async {
      final calls = await publish(_resolve(adapter, _post(links: const {}), account));
      expect([for (final c in calls.take(3)) multipartFieldsOf(c)['source']], ['<c.jpg>', '<a.jpg>', '<b.jpg>']);
      expect(bodyOf(calls[3])['message'], _text);
    });

    test('Post + Story: the story frames follow the paragraphs too', () {
      final v = _resolve(adapter, _post(overrides: const PostOverrides(extra: {'placement': 'feedAndStory'})), account);
      expect([for (final m in v.storyFrames) m.id], ['a', 'b', 'c']);
    });
  });

  // ================================================================ LinkedIn
  group('LinkedIn', () {
    final adapter = LinkedInAdapter();
    final account = fakeAccount('linkedin',
        tier: PlatformTier.byokApi, id: 'linkedin:abc', config: const {'clientId': 'cid', 'apiVersion': '202609', 'sub': 'abc', 'personUrn': 'urn:li:person:abc'});
    final secrets = {
      'client_secret': 'cs',
      'access_token': 'AT',
      'token_type': 'Bearer',
      'expires_at': testNow.add(const Duration(days: 30)).toIso8601String(),
    };

    Future<(Map<String, dynamic>, List<String>)> publish(PostVariant v) async {
      var n = 0;
      final uploaded = <String>[];
      http.Request? post;
      final ctx = testContext(handler: (r) async {
        if (r.url.path == '/rest/images') {
          n++;
          return _json({
            'value': {'uploadUrl': 'https://www.linkedin.com/dms-uploads/I$n/up', 'image': 'urn:li:image:I$n'}
          });
        }
        if (r.url.path.startsWith('/dms-uploads/')) {
          uploaded.add(r.url.path);
          return http.Response('', 201);
        }
        post = r;
        return http.Response('', 201, headers: {'x-restli-id': 'urn:li:share:1'});
      });
      final res = await adapter.publish(v, account, secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      return (jsonDecode(post!.body) as Map<String, dynamic>, uploaded);
    }

    test('images in paragraph order, numbered in the commentary', () async {
      final v = _resolve(adapter, _post(), account);
      expect([for (final m in v.media) m.id], ['a', 'b', 'c']);
      final (body, _) = await publish(v);
      expect(body['commentary'], contains(r'First place. \(1/3\)'));
      expect(body['commentary'], contains(r'two views. \(2-3/3\)'));
      expect((body['content'] as Map)['multiImage'], isNotNull);
      expect(LinkedInAdapter.commentaryFor(v), contains('First place. (1/3)\n\nSecond place, with two views. (2-3/3)\n\nThanks'));
    });

    test('no links: commentary and order as before (regression)', () async {
      final v = _resolve(adapter, _post(links: const {}), account);
      expect([for (final m in v.media) m.id], ['c', 'a', 'b']);
      expect(LinkedInAdapter.commentaryFor(v), _text);
    });
  });

  // =============================================================== Instagram
  group('Instagram', () {
    late InstagramAdapter adapter;
    setUp(() => adapter = InstagramAdapter(sleep: (_) async {}));
    final account = fakeAccount('instagram', tier: PlatformTier.byokApi, config: const {'igUserId': '1784100', 'username': 'u'});
    final secrets = {
      'access_token': 'LONG',
      'token_type': 'Bearer',
      'expires_at': testNow.add(const Duration(days: 50)).toIso8601String(),
      'refreshed_at': testNow.subtract(const Duration(days: 1)).toIso8601String(),
    };

    Future<List<Map<String, dynamic>>> publish(PostVariant v) async {
      final created = <Map<String, dynamic>>[];
      var n = 0;
      final ctx = testContext(
        mediaHost: FakeMediaHost(),
        handler: (r) async {
          if (r.url.path.endsWith('/media')) {
            created.add(bodyOf(r));
            return _json({'id': 'C${++n}'});
          }
          if (r.url.path.endsWith('/media_publish')) return _json({'id': 'M${++n}'});
          if (r.url.queryParameters['fields'] == 'permalink') return _json({'permalink': 'https://www.instagram.com/p/x/'});
          return _json({'status_code': 'FINISHED'});
        },
      );
      final res = await adapter.publish(v, account, secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      return created;
    }

    test('post: carousel in paragraph order, the caption numbered to match', () async {
      final created = await publish(_resolve(adapter, _post(), account));
      expect([for (final c in created.take(3)) c['image_url']], [
        'https://cdn.example.test/a',
        'https://cdn.example.test/b',
        'https://cdn.example.test/c',
      ]);
      expect(created[3]['media_type'], 'CAROUSEL');
      expect(created[3]['caption'], 'Intro line.\n\nFirst place. (1/3)\n\nSecond place, with two views. (2-3/3)\n\nThanks for reading.');
    });

    test('story: frames in paragraph order, a paragraph with two photos covering both', () async {
      // The story's own 9:16 copies, attached in another order (the app
      // writes each section's words on the first copy of its section).
      MediaAttachment story(String id, String from) => MediaAttachment(
          id: id, path: '/tmp/$id.jpg', mimeType: 'image/jpeg', sizeBytes: 64, width: 1080, height: 1920, generated: true, derivedFrom: from);
      final post = _post(
        media: [fakeImage(id: 'c'), fakeImage(id: 'a'), fakeImage(id: 'b'), story('s-c', 'c'), story('s-b', 'b'), story('s-a', 'a')],
        overrides: const PostOverrides(mediaIds: ['c', 'a', 'b'], storyMediaIds: ['s-c', 's-b', 's-a'], extra: {'placement': 'feedAndStory'}),
      );
      final v = _resolve(adapter, post, account);
      final created = await publish(v);
      final stories = [for (final c in created) if (c['media_type'] == 'STORIES') c['image_url']];
      expect(stories, ['https://cdn.example.test/s-a', 'https://cdn.example.test/s-b', 'https://cdn.example.test/s-c']);
      expect(ParagraphMedia.wordsByMedia(post.text, post.paragraphMedia, v.storyFrames), {
        's-a': 'Intro line.\n\nFirst place.',
        's-b': 'Second place, with two views.\n\nThanks for reading.',
      });
    });

    test('no links: carousel and caption as before (regression)', () async {
      final created = await publish(_resolve(adapter, _post(links: const {}), account));
      expect([for (final c in created.take(3)) c['image_url']], [
        'https://cdn.example.test/c',
        'https://cdn.example.test/a',
        'https://cdn.example.test/b',
      ]);
      expect(created[3]['caption'], _text);
    });
  });
}
