import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/chat/chat_common.dart';
import 'package:neforum_core/src/adapters/chat/discord_adapter.dart';
import 'package:neforum_core/src/adapters/chat/matrix_adapter.dart';
import 'package:neforum_core/src/adapters/chat/telegram_adapter.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

http.Response _json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {...jsonHeaders, ...headers});

String _line(http.Request r) => '${r.method} ${r.url}';

void main() {
  group('markdown converter', () {
    test('returns null for plain text', () {
      expect(chatMarkdownToHtml('Hello world, 5 * 3 = 15 and snake_case_name'), isNull);
    });
    test('converts the supported subset and escapes HTML', () {
      expect(chatMarkdownToHtml('**bold** and *it* <x> & `a<b`'),
          '<b>bold</b> and <i>it</i> &lt;x&gt; &amp; <code>a&lt;b</code>');
      expect(chatMarkdownToHtml('see [docs](https://example.org/a_b_c) ~~old~~'),
          'see <a href="https://example.org/a_b_c">docs</a> <s>old</s>');
      expect(chatMarkdownToHtml('```dart\nvar x = 1;\n```'), '<pre><code class="language-dart">var x = 1;</code></pre>');
    });
    test('does not touch underscores in bare URLs', () {
      expect(chatMarkdownToHtml('**x** https://example.org/_a_'), '<b>x</b> https://example.org/_a_');
    });
    test('line breaks and quotes', () {
      expect(chatMarkdownToHtml('**a**\nb', brLineBreaks: true), '<b>a</b><br>b');
      expect(chatMarkdownToHtml('> quoted\nafter'), '<blockquote>quoted</blockquote>\nafter');
    });
  });

  telegramTests();
  discordTests();
  matrixTests();
}

// ===================================================================== Telegram

const _tgToken = '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw';
const _tgBase = 'https://api.telegram.org/bot$_tgToken';

ConnectedAccount _tgAccount({Map<String, dynamic> extra = const {}}) => fakeAccount('telegram', config: {
      'chatId': '-1001234567890',
      'chatType': 'channel',
      'chatTitle': 'My Channel',
      'chatUsername': 'mychan',
      'botId': '999',
      'formatting': 'markdown',
      ...extra,
    });

http.Response _tgOk(Object? result) => _json({'ok': true, 'result': result});

void telegramTests() {
  final adapter = TelegramAdapter();

  group('telegram descriptor', () {
    test('limits match the Bot API', () {
      final d = adapter.descriptor;
      expect(d.id, 'telegram');
      expect(d.tiers, {PlatformTier.openApi, PlatformTier.handoff});
      expect(d.text.maxLength, 4096);
      expect(d.text.counting, CountingRule.utf16);
      expect(d.text.supportsThreads, isTrue);
      expect(d.text.titleSupported, isFalse);
      expect(d.media.maxImages, 10);
      expect(d.media.imageMaxBytes, 10 * 1024 * 1024);
      expect(d.media.videoMaxBytes, 50 * 1024 * 1024);
      expect(d.media.allowsMixedImageVideo, isTrue);
      expect(d.media.requiresPublicMediaUrl, isFalse);
      expect(d.defaultQuotas.single.id, 'telegram.messages_per_minute_per_chat');
      expect(d.defaultQuotas.single.limit, 20);
      expect(d.setupGuide, 'docs/platforms/telegram.md');
      expect(d.serverSideScheduling, isFalse);
      final spec = adapter.specFor(PlatformTier.openApi);
      expect(spec.fields.firstWhere((f) => f.key == 'bot_token').secret, isTrue);
      expect(spec.usesBrowser, isFalse);
      expect(spec.intro, contains('@BotFather'));
    });

    test('chat normalisation', () {
      expect(normalizeTelegramChat('@mychan'), '@mychan');
      expect(normalizeTelegramChat('mychan'), '@mychan');
      expect(normalizeTelegramChat('https://t.me/mychan/12'), '@mychan');
      expect(normalizeTelegramChat(' -1001234567890 '), '-1001234567890');
      expect(() => normalizeTelegramChat('https://t.me/+AbCdEf'), throwsA(isA<ConnectException>()));
      expect(() => normalizeTelegramChat('a b'), throwsA(isA<ConnectException>()));
    });
  });

  group('telegram connect', () {
    test('getMe, getChat, getChatMember; stores config and token', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return switch (r.url.pathSegments.last) {
          'getMe' => _tgOk({'id': 999, 'is_bot': true, 'username': 'neforum_test_bot', 'first_name': 'N'}),
          'getChat' => _tgOk({'id': -1001234567890, 'type': 'channel', 'title': 'My Channel', 'username': 'mychan'}),
          'getChatMember' => _tgOk({'status': 'administrator', 'can_post_messages': true}),
          _ => _json({'ok': false, 'error_code': 404, 'description': 'Not Found'}, 404),
        };
      });
      final res = await adapter.connect(PlatformTier.openApi, {'bot_token': ' $_tgToken ', 'chat': '@mychan'}, ctx);
      expect(calls.map(_line), [
        'GET $_tgBase/getMe',
        'GET $_tgBase/getChat?chat_id=%40mychan',
        'GET $_tgBase/getChatMember?chat_id=-1001234567890&user_id=999',
      ]);
      expect(res.secrets, {'bot_token': _tgToken});
      expect(res.account.id, 'telegram:999:-1001234567890');
      expect(res.account.config['chatId'], '-1001234567890');
      expect(res.account.config['chatUsername'], 'mychan');
      expect(res.account.config['formatting'], 'markdown');
      expect(res.account.profileUrl, 'https://t.me/mychan');
      expect(res.account.displayName, 'My Channel (via @neforum_test_bot)');
    });

    test('bot that is not a channel admin is refused', () async {
      final ctx = testContext(handler: (r) async => switch (r.url.pathSegments.last) {
            'getMe' => _tgOk({'id': 999, 'is_bot': true, 'username': 'b_bot'}),
            'getChat' => _tgOk({'id': -100555, 'type': 'channel', 'title': 'C'}),
            _ => _tgOk({'status': 'member'}),
          });
      expect(
          adapter.connect(PlatformTier.openApi, {'bot_token': _tgToken, 'chat': '-100555'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('not an administrator'))));
    });

    test('rejected token maps to the token field', () async {
      final ctx = testContext(
          handler: (r) async => _json({'ok': false, 'error_code': 401, 'description': 'Unauthorized'}, 401));
      expect(adapter.connect(PlatformTier.openApi, {'bot_token': _tgToken, 'chat': '@mychan'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'bot_token')));
    });

    test('malformed token is refused without a request', () async {
      final ctx = testContext(handler: (r) async => fail('no request expected'));
      expect(adapter.connect(PlatformTier.openApi, {'bot_token': 'abc', 'chat': '@mychan'}, ctx),
          throwsA(isA<ConnectException>()));
    });
  });

  group('telegram validate', () {
    test('album size, photo dimensions and caption split', () {
      final many = List.generate(11, (i) => fakeImage(id: 'i$i'));
      expect(adapter.validate(PostVariant(text: 'x', media: many), _tgAccount()).map((i) => i.code),
          contains('media.too_many'));
      final tall = fakeImage(width: 100, height: 2500);
      expect(adapter.validate(PostVariant(text: 'x', media: [tall]), _tgAccount()).map((i) => i.code),
          contains('media.dimensions'));
      final long = PostVariant(text: 'a' * 1500, media: [fakeImage()]);
      final issues = adapter.validate(long, _tgAccount());
      expect(issues.map((i) => i.code), contains('text.caption_split'));
      expect(issues.hasErrors, isFalse);
      expect(adapter.validate(PostVariant(text: 'a' * 4097), _tgAccount()).map((i) => i.code), contains('text.too_long'));
    });
  });

  group('telegram publish', () {
    test('text: sendMessage with HTML from markdown', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _tgOk({'message_id': 42});
      });
      final res = await adapter.publish(const PostVariant(text: 'Hello **world**'), _tgAccount(), {'bot_token': _tgToken}, ctx);
      expect(res.success, isTrue);
      expect(res.remoteId, '42');
      expect(res.remoteUrl, 'https://t.me/mychan/42');
      expect(calls.map(_line), ['POST $_tgBase/sendMessage']);
      expect(bodyOf(calls.single), {'chat_id': '-1001234567890', 'text': 'Hello <b>world</b>', 'parse_mode': 'HTML'});
    });

    test('plain formatting sends text untouched; private channel link', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _tgOk({'message_id': 7});
      });
      final account = fakeAccount('telegram', config: {'chatId': '-1009876', 'formatting': 'plain'});
      final res = await adapter.publish(const PostVariant(text: '**raw**'), account, {'bot_token': _tgToken}, ctx);
      expect(bodyOf(calls.single), {'chat_id': '-1009876', 'text': '**raw**'});
      expect(res.remoteUrl, 'https://t.me/c/9876/7');
    });

    test('single photo with caption: multipart sendPhoto', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _tgOk({'message_id': 50});
      });
      final res = await adapter.publish(
          PostVariant(text: 'A caption', media: [fakeImage()], sensitive: true), _tgAccount(), {'bot_token': _tgToken}, ctx);
      expect(res.success, isTrue);
      expect(calls.map(_line), ['POST $_tgBase/sendPhoto']);
      expect(multipartFieldsOf(calls.single),
          {'chat_id': '-1001234567890', 'caption': 'A caption', 'has_spoiler': 'true', 'photo': '<img1.jpg>'});
    });

    test('single video goes to sendVideo', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _tgOk({'message_id': 51});
      });
      await adapter.publish(PostVariant(text: 'clip', media: [fakeVideo()]), _tgAccount(), {'bot_token': _tgToken}, ctx);
      final f = multipartFieldsOf(calls.single);
      expect(calls.single.url.path, endsWith('/sendVideo'));
      expect(f['video'], '<vid1.mp4>');
      expect(f['supports_streaming'], 'true');
      expect(f['duration'], '15');
      expect(f['width'], '1080');
    });

    test('album + text longer than a caption: sendMediaGroup then sendMessage', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path.endsWith('/sendMediaGroup')) {
          return _tgOk([
            {'message_id': 60},
            {'message_id': 61},
          ]);
        }
        return _tgOk({'message_id': 62});
      });
      final long = 'x' * 1500;
      final res = await adapter.publish(PostVariant(text: long, media: [fakeImage(id: 'a'), fakeVideo(id: 'b')]),
          _tgAccount(), {'bot_token': _tgToken}, ctx);
      expect(res.success, isTrue);
      expect(calls.map(_line), ['POST $_tgBase/sendMediaGroup', 'POST $_tgBase/sendMessage']);
      final f = multipartFieldsOf(calls[0]);
      expect(f['chat_id'], '-1001234567890');
      expect(f['file0'], '<a.jpg>');
      expect(f['file1'], '<b.mp4>');
      final media = (jsonDecode(f['media']!) as List).cast<Map<String, dynamic>>();
      expect(media[0], {'type': 'photo', 'media': 'attach://file0'});
      expect(media[1]['type'], 'video');
      expect(media[1]['media'], 'attach://file1');
      expect(bodyOf(calls[1]), {'chat_id': '-1001234567890', 'text': long});
      expect(res.remoteId, '60');
      expect(res.threadRemoteIds, ['60', '62']);
    });

    test('thread: parts are replies; media caption is part 1', () async {
      final calls = <http.Request>[];
      var next = 100;
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _tgOk({'message_id': next++});
      });
      final res = await adapter.publish(
          PostVariant(text: 'one', threadParts: const ['one', 'two', 'three'], media: [fakeImage()]),
          _tgAccount(),
          {'bot_token': _tgToken},
          ctx);
      expect(calls.map((c) => c.url.pathSegments.last), ['sendPhoto', 'sendMessage', 'sendMessage']);
      expect(multipartFieldsOf(calls[0])['caption'], 'one');
      expect(bodyOf(calls[1])['reply_parameters'], {'message_id': 100, 'allow_sending_without_reply': true});
      expect(bodyOf(calls[2])['reply_parameters'], {'message_id': 101, 'allow_sending_without_reply': true});
      expect(res.threadRemoteIds, ['100', '101', '102']);
      expect(res.remoteId, '100');
    });

    test('error mapping', () async {
      Future<PublishResult> run(http.Response response) => adapter.publish(
          const PostVariant(text: 'x'), _tgAccount(), {'bot_token': _tgToken}, testContext(handler: (r) async => response));

      final flood = await run(_json({
        'ok': false,
        'error_code': 429,
        'description': 'Too Many Requests: retry after 17',
        'parameters': {'retry_after': 17},
      }, 429));
      expect(flood.error!.kind, PublishErrorKind.quota);
      expect(flood.error!.retryAfter, const Duration(seconds: 17));

      final unauthorized = await run(_json({'ok': false, 'error_code': 401, 'description': 'Unauthorized'}, 401));
      expect(unauthorized.error!.kind, PublishErrorKind.auth);
      expect(unauthorized.error!.message, isNot(contains(_tgToken)));

      final kicked = await run(
          _json({'ok': false, 'error_code': 403, 'description': 'Forbidden: bot is not a member of the channel chat'}, 403));
      expect(kicked.error!.kind, PublishErrorKind.auth);

      final tooLong = await run(_json({'ok': false, 'error_code': 400, 'description': 'Bad Request: message is too long'}, 400));
      expect(tooLong.error!.kind, PublishErrorKind.validation);

      final notFound = await run(_json({'ok': false, 'error_code': 400, 'description': 'Bad Request: chat not found'}, 400));
      expect(notFound.error!.kind, PublishErrorKind.configuration);

      final server = await run(http.Response('bad gateway', 502));
      expect(server.error!.kind, PublishErrorKind.network);
    });

    test('missing token is an auth failure', () async {
      final res = await adapter.publish(
          const PostVariant(text: 'x'), _tgAccount(), const {}, testContext(handler: (r) async => fail('no request')));
      expect(res.error!.kind, PublishErrorKind.auth);
    });
  });

  group('telegram hand-off', () {
    test('share URL with the text', () {
      final plan = adapter.buildHandoff(const PostVariant(text: 'Hello world & more'))!;
      expect(plan.webIntent.toString(), 'https://t.me/share/url?url=Hello%20world%20%26%20more');
      expect(plan.preferred, HandoffMethod.webIntent);
      expect(plan.clipboardText, 'Hello world & more');
      expect(plan.androidPackage, 'org.telegram.messenger');
      expect(plan.iosScheme, 'tg://');
    });
    test('link goes into url, rest into text; media prefers share sheet', () {
      final plan = adapter.buildHandoff(PostVariant(
          text: 'Read this https://example.org/post', link: 'https://example.org/post', media: [fakeImage()]))!;
      expect(plan.webIntent!.queryParameters, {'url': 'https://example.org/post', 'text': 'Read this'});
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.shareFiles, hasLength(1));
      expect(plan.mediaNote, isNotNull);
    });
  });
}

// ====================================================================== Discord

const _hookId = '123456789012345678';
const _hookToken = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcdefghij';
const _hookUrl = 'https://discord.com/api/v10/webhooks/$_hookId/$_hookToken';

ConnectedAccount _dcAccount({Map<String, dynamic> extra = const {}}) => fakeAccount('discord', config: {
      'webhookId': _hookId,
      'channelId': '555',
      'guildId': '777',
      ...extra,
    });

void discordTests() {
  final adapter = DiscordAdapter();
  const secrets = {'webhook_url': _hookUrl};

  group('discord descriptor & URL parsing', () {
    test('limits match the docs', () {
      final d = adapter.descriptor;
      expect(d.id, 'discord');
      expect(d.tiers, {PlatformTier.openApi});
      expect(d.text.maxLength, 2000);
      expect(d.text.supportsThreads, isTrue);
      expect(d.media.maxImages, 10);
      expect(d.media.imageMaxBytes, 20 * 1024 * 1024);
      expect(d.media.supportsAltText, isTrue);
      expect(d.defaultQuotas.single.id, 'discord.webhook_messages_per_minute');
      expect(d.setupGuide, 'docs/platforms/discord.md');
      expect(adapter.specFor(PlatformTier.openApi).fields.first.secret, isTrue);
      expect(adapter.buildHandoff(const PostVariant(text: 'x')), isNull);
    });

    test('webhook URL variants', () {
      for (final raw in [
        'https://discord.com/api/webhooks/$_hookId/$_hookToken',
        'https://discordapp.com/api/webhooks/$_hookId/$_hookToken/',
        'https://canary.discord.com/api/v9/webhooks/$_hookId/$_hookToken',
      ]) {
        expect(DiscordWebhook.parse(raw).url.toString(), _hookUrl);
      }
      expect(DiscordWebhook.parse('https://discord.com/api/webhooks/$_hookId/$_hookToken?thread_id=42').threadId, '42');
      expect(() => DiscordWebhook.parse('https://example.org/api/webhooks/1/2'), throwsA(isA<ConnectException>()));
    });
  });

  group('discord connect', () {
    test('GET webhook; stores normalised URL as the secret', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({
          'type': 1,
          'id': _hookId,
          'name': 'NEFORUM',
          'avatar': null,
          'channel_id': '555',
          'guild_id': '777',
          'application_id': null,
          'token': _hookToken,
        });
      });
      final res = await adapter.connect(PlatformTier.openApi,
          {'webhook_url': 'https://discordapp.com/api/webhooks/$_hookId/$_hookToken', 'username': 'Alice', 'forum': 'false'}, ctx);
      expect(calls.map(_line), ['GET $_hookUrl']);
      expect(calls.single.headers.containsKey('Authorization'), isFalse);
      expect(res.secrets, {'webhook_url': _hookUrl});
      expect(res.account.id, 'discord:$_hookId');
      expect(res.account.config, {
        'webhookId': _hookId,
        'webhookName': 'NEFORUM',
        'channelId': '555',
        'guildId': '777',
        'username': 'Alice',
        'forum': false,
      });
      expect(res.account.profileUrl, 'https://discord.com/channels/777/555');
    });

    test('unknown webhook', () async {
      final ctx = testContext(handler: (r) async => _json({'message': 'Unknown Webhook', 'code': 10015}, 404));
      expect(adapter.connect(PlatformTier.openApi, {'webhook_url': _hookUrl}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'webhook_url')));
    });
  });

  group('discord validate', () {
    test('file count and total size', () {
      final many = List.generate(11, (i) => fakeImage(id: 'i$i'));
      expect(adapter.validate(PostVariant(text: 'x', media: many), _dcAccount()).map((i) => i.code), contains('media.too_many'));
      final big = [fakeVideo(id: 'a', sizeBytes: 15 * 1024 * 1024), fakeVideo(id: 'b', sizeBytes: 15 * 1024 * 1024)];
      expect(adapter.validate(PostVariant(text: 'x', media: big), _dcAccount()).map((i) => i.code),
          contains('media.total_too_large'));
      expect(adapter.validate(PostVariant(text: 'a' * 2001), _dcAccount()).map((i) => i.code), contains('text.too_long'));
    });
  });

  group('discord publish', () {
    test('text: JSON to ?wait=true with mentions disabled', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'id': '9001', 'channel_id': '555'});
      });
      final res = await adapter.publish(
          const PostVariant(text: 'Hello @everyone'), _dcAccount(extra: {'username': 'Alice'}), secrets, ctx);
      expect(res.success, isTrue);
      expect(calls.map(_line), ['POST $_hookUrl?wait=true']);
      expect(bodyOf(calls.single), {
        'content': 'Hello @everyone',
        'username': 'Alice',
        'allowed_mentions': {'parse': <String>[]},
      });
      expect(res.remoteId, '9001');
      expect(res.remoteUrl, 'https://discord.com/channels/777/555/9001');
    });

    test('media: multipart payload_json + files[n] with alt text and spoilers', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'id': '9002', 'channel_id': '555'});
      });
      final res = await adapter.publish(
          PostVariant(text: 'pics', media: [fakeImage(id: 'a'), fakeImage(id: 'b', altText: null)], sensitive: true),
          _dcAccount(),
          secrets,
          ctx);
      expect(res.success, isTrue);
      final f = multipartFieldsOf(calls.single);
      expect(f.keys.toSet(), {'payload_json', 'files[0]', 'files[1]'});
      expect(f['files[0]'], '<SPOILER_a.jpg>');
      final payload = jsonDecode(f['payload_json']!) as Map<String, dynamic>;
      expect(payload['content'], 'pics');
      expect(payload['attachments'], [
        {'id': 0, 'filename': 'SPOILER_a.jpg', 'description': 'A test image'},
        {'id': 1, 'filename': 'SPOILER_b.jpg'},
      ]);
    });

    test('thread parts become consecutive messages, media on the first', () async {
      final calls = <http.Request>[];
      var n = 0;
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'id': '${++n}', 'channel_id': '555'});
      });
      final res = await adapter.publish(
          PostVariant(text: 'a', threadParts: const ['a', 'b'], media: [fakeImage()]), _dcAccount(), secrets, ctx);
      expect(calls, hasLength(2));
      expect(multipartFieldsOf(calls[0]).containsKey('files[0]'), isTrue);
      expect(bodyOf(calls[1])['content'], 'b');
      expect(res.threadRemoteIds, ['1', '2']);
    });

    test('forum channel: thread_name first, then thread_id', () async {
      final calls = <http.Request>[];
      var n = 0;
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'id': '${++n}', 'channel_id': '8888'});
      });
      await adapter.publish(const PostVariant(text: 'Title line\nbody', threadParts: ['Title line\nbody', 'more']),
          _dcAccount(extra: {'forum': true}), secrets, ctx);
      expect(bodyOf(calls[0])['thread_name'], 'Title line');
      expect(calls[1].url.queryParameters, {'wait': 'true', 'thread_id': '8888'});
      expect(bodyOf(calls[1]).containsKey('thread_name'), isFalse);
    });

    test('error mapping', () async {
      Future<PublishError> run(http.Response r) async => (await adapter.publish(
              const PostVariant(text: 'x'), _dcAccount(), secrets, testContext(handler: (_) async => r)))
          .error!;

      final limited = await run(_json({'message': 'You are being rate limited.', 'retry_after': 1.5, 'global': false}, 429));
      expect(limited.kind, PublishErrorKind.quota);
      expect(limited.retryAfter, const Duration(milliseconds: 1500));
      expect((await run(_json({'message': 'Unknown Webhook', 'code': 10015}, 404))).kind, PublishErrorKind.auth);
      expect((await run(_json({'message': 'Invalid Webhook Token', 'code': 50027}, 401))).kind, PublishErrorKind.auth);
      expect((await run(_json({'message': 'Invalid Form Body', 'code': 50035}, 400))).kind, PublishErrorKind.validation);
      expect((await run(_json({'message': 'Request entity too large', 'code': 40005}, 413))).kind,
          PublishErrorKind.validation);
      expect((await run(http.Response('oops', 503))).kind, PublishErrorKind.network);
    });
  });
}

// ======================================================================= Matrix

const _mxBase = 'https://matrix.example.org';
const _roomId = '!abc123:example.org';

ConnectedAccount _mxAccount({Map<String, dynamic> extra = const {}}) => fakeAccount('matrix', config: {
      'homeserver': _mxBase,
      'userId': '@alice:example.org',
      'roomId': _roomId,
      'authMethod': 'token',
      'formatting': 'markdown',
      ...extra,
    });

void matrixTests() {
  var txn = 0;
  final adapter = MatrixAdapter(newTxnId: () => 'txn-${++txn}');
  setUp(() => txn = 0);

  /// A homeserver: .well-known on example.org pointing at matrix.example.org.
  Future<http.Response> Function(http.Request) server(List<http.Request> calls,
      {bool joined = true, bool encrypted = false, List<String> flows = const ['m.login.password']}) {
    return (r) async {
      calls.add(r);
      final p = r.url.path;
      if (r.url.host == 'example.org' && p == '/.well-known/matrix/client') {
        return _json({
          'm.homeserver': {'base_url': '$_mxBase/'},
        });
      }
      if (p == '/_matrix/client/versions') return _json({'versions': ['v1.11', 'v1.19']});
      if (p == '/_matrix/client/v3/account/whoami') return _json({'user_id': '@alice:example.org', 'device_id': 'DEV1'});
      if (p == '/_matrix/client/v3/login' && r.method == 'GET') {
        return _json({'flows': [for (final f in flows) {'type': f}]});
      }
      if (p == '/_matrix/client/v3/login') {
        return _json({'user_id': '@alice:example.org', 'access_token': 'syt_new', 'device_id': 'NEFDEV'});
      }
      if (p.startsWith('/_matrix/client/v3/directory/room/')) return _json({'room_id': _roomId, 'servers': ['example.org']});
      if (p == '/_matrix/client/v3/joined_rooms') return _json({'joined_rooms': joined ? [_roomId] : <String>[]});
      if (p.startsWith('/_matrix/client/v3/join/')) return _json({'room_id': _roomId});
      if (p.endsWith('/state/m.room.encryption')) {
        return encrypted
            ? _json({'algorithm': 'm.megolm.v1.aes-sha2'})
            : _json({'errcode': 'M_NOT_FOUND', 'error': 'Event not found.'}, 404);
      }
      if (p.endsWith('/state/m.room.name')) return _json({'name': 'NEFORUM test room'});
      if (p == '/_matrix/client/v1/media/config') return _json({'m.upload.size': 104857600});
      if (p == '/_matrix/client/v3/logout') return _json({});
      return _json({'errcode': 'M_UNRECOGNIZED', 'error': 'Unrecognized request'}, 404);
    };
  }

  group('matrix descriptor', () {
    test('no text limit, media limits, guide', () {
      final d = adapter.descriptor;
      expect(d.id, 'matrix');
      expect(d.tiers, {PlatformTier.openApi});
      expect(d.text.maxLength, isNull);
      expect(d.text.supportsThreads, isFalse);
      expect(d.text.supportsMarkdown, isTrue);
      expect(d.media.imageMaxBytes, 50 * 1024 * 1024);
      expect(d.media.maxImages, 10);
      expect(d.defaultQuotas.single.id, 'matrix.messages_per_minute');
      expect(d.setupGuide, 'docs/platforms/matrix.md');
      final spec = adapter.specFor(PlatformTier.openApi);
      expect(spec.fields.where((f) => f.secret).map((f) => f.key), ['access_token', 'password']);
      expect(adapter.buildHandoff(const PostVariant(text: 'x')), isNull);
    });
  });

  group('matrix connect', () {
    test('token: discovery, whoami, alias, membership, encryption, media config', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: server(calls));
      final res = await adapter.connect(PlatformTier.openApi,
          {'homeserver': 'example.org', 'access_token': 'syt_tok', 'room': '#neforum:example.org'}, ctx);
      expect(calls.map(_line), [
        'GET https://example.org/.well-known/matrix/client',
        'GET $_mxBase/_matrix/client/versions',
        'GET $_mxBase/_matrix/client/v3/account/whoami',
        'GET $_mxBase/_matrix/client/v3/directory/room/%23neforum:example.org',
        'GET $_mxBase/_matrix/client/v3/joined_rooms',
        'GET $_mxBase/_matrix/client/v3/rooms/!abc123:example.org/state/m.room.encryption',
        'GET $_mxBase/_matrix/client/v3/rooms/!abc123:example.org/state/m.room.name',
        'GET $_mxBase/_matrix/client/v1/media/config',
      ]);
      expect(calls[2].headers['Authorization'], 'Bearer syt_tok');
      expect(res.secrets['access_token'], 'syt_tok');
      expect(res.secrets.containsKey('password'), isFalse);
      expect(res.account.id, 'matrix:@alice:example.org:$_roomId');
      expect(res.account.config['homeserver'], _mxBase);
      expect(res.account.config['roomId'], _roomId);
      expect(res.account.config['roomAlias'], '#neforum:example.org');
      expect(res.account.config['maxUploadBytes'], 104857600);
      expect(res.account.config['authMethod'], 'token');
      expect(res.account.displayName, 'NEFORUM test room (@alice:example.org)');
    });

    test('password: login flows, m.login.password, joins the room', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: server(calls, joined: false));
      final res = await adapter.connect(PlatformTier.openApi,
          {'user_id': '@alice:example.org', 'password': 'hunter2', 'room': _roomId}, ctx);
      final login = calls.firstWhere((c) => c.method == 'POST' && c.url.path == '/_matrix/client/v3/login');
      expect(bodyOf(login), {
        'type': 'm.login.password',
        'identifier': {'type': 'm.id.user', 'user': '@alice:example.org'},
        'password': 'hunter2',
        'initial_device_display_name': 'NEFORUM',
      });
      expect(login.headers.containsKey('Authorization'), isFalse);
      final join = calls.firstWhere((c) => c.url.path.contains('/join/'));
      expect(_line(join), 'POST $_mxBase/_matrix/client/v3/join/!abc123:example.org');
      expect(res.secrets['access_token'], 'syt_new');
      expect(res.secrets.values, isNot(contains('hunter2')));
      expect(res.account.config['authMethod'], 'password');
      expect(res.account.config['deviceId'], 'NEFDEV');
    });

    test('password sign-in unavailable (OAuth-only server)', () async {
      final ctx = testContext(handler: server([], flows: ['m.login.sso']));
      expect(
          adapter.connect(PlatformTier.openApi, {'user_id': '@alice:example.org', 'password': 'x', 'room': _roomId}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'password')));
    });

    test('encrypted rooms are refused (and the password device is signed out)', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: server(calls, encrypted: true));
      await expectLater(
          adapter.connect(PlatformTier.openApi, {'user_id': '@alice:example.org', 'password': 'x', 'room': _roomId}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('encrypted'))));
      expect(calls.last.url.path, '/_matrix/client/v3/logout');
    });

    test('bad input', () {
      final ctx = testContext(handler: (r) async => fail('no request'));
      expect(adapter.connect(PlatformTier.openApi, {'homeserver': 'example.org', 'access_token': 't', 'room': 'general'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'room')));
      expect(adapter.connect(PlatformTier.openApi, {'homeserver': 'example.org', 'room': _roomId}, ctx),
          throwsA(isA<ConnectException>()));
    });
  });

  group('matrix validate', () {
    test('per-server upload size and event size', () {
      final big = fakeVideo(sizeBytes: 60 * 1024 * 1024);
      expect(adapter.validate(PostVariant(text: 'x', media: [big]), _mxAccount()).map((i) => i.code),
          contains('media.video_too_large'));
      expect(
          adapter
              .validate(PostVariant(text: 'x', media: [big]), _mxAccount(extra: {'maxUploadBytes': 100 * 1024 * 1024}))
              .hasErrors,
          isFalse);
      expect(adapter.validate(PostVariant(text: 'a' * 70000), _mxAccount()).map((i) => i.code),
          contains('text.event_too_large'));
    });
  });

  group('matrix publish', () {
    test('uploads media, sends m.text then m.image', () async {
      final calls = <http.Request>[];
      var ev = 0;
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path == '/_matrix/media/v3/upload') return _json({'content_uri': 'mxc://example.org/media1'});
        return _json({'event_id': '\$ev${++ev}'});
      });
      final res = await adapter.publish(
          PostVariant(text: 'Hello **Matrix**', media: [fakeImage()]), _mxAccount(), {'access_token': 'syt_tok'}, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(calls.map(_line), [
        'POST $_mxBase/_matrix/media/v3/upload?filename=img1.jpg',
        'PUT $_mxBase/_matrix/client/v3/rooms/!abc123:example.org/send/m.room.message/txn-1',
        'PUT $_mxBase/_matrix/client/v3/rooms/!abc123:example.org/send/m.room.message/txn-2',
      ]);
      expect(calls[0].headers['Authorization'], 'Bearer syt_tok');
      expect(calls[0].headers['content-type'], 'image/jpeg');
      expect(calls[0].bodyBytes, fakeJpegBytes);
      expect(bodyOf(calls[1]), {
        'msgtype': 'm.text',
        'body': 'Hello **Matrix**',
        'format': 'org.matrix.custom.html',
        'formatted_body': 'Hello <b>Matrix</b>',
        'm.mentions': <String, dynamic>{},
      });
      expect(bodyOf(calls[2]), {
        'msgtype': 'm.image',
        'body': 'img1.jpg',
        'filename': 'img1.jpg',
        'url': 'mxc://example.org/media1',
        'info': {'mimetype': 'image/jpeg', 'size': 64, 'w': 1200, 'h': 800},
        'm.mentions': <String, dynamic>{},
      });
      expect(res.remoteId, '\$ev1');
      expect(res.threadRemoteIds, ['\$ev1', '\$ev2']);
      expect(res.remoteUrl, 'https://matrix.to/#/!abc123%3Aexample.org/%24ev1?via=example.org');
    });

    test('plain text without markdown has no formatted_body; video info has duration', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path.endsWith('/upload')) return _json({'content_uri': 'mxc://example.org/v'});
        return _json({'event_id': '\$e'});
      });
      await adapter.publish(PostVariant(text: 'just text', media: [fakeVideo()]), _mxAccount(), {'access_token': 't'}, ctx);
      expect(bodyOf(calls[1]).containsKey('formatted_body'), isFalse);
      final video = bodyOf(calls[2]);
      expect(video['msgtype'], 'm.video');
      expect((video['info'] as Map)['duration'], 15000);
    });

    test('error mapping', () async {
      Future<PublishError> run(http.Response r) async => (await adapter.publish(
              const PostVariant(text: 'x'), _mxAccount(), {'access_token': 't'}, testContext(handler: (_) async => r)))
          .error!;
      expect((await run(_json({'errcode': 'M_UNKNOWN_TOKEN', 'error': 'Invalid token', 'soft_logout': true}, 401))).kind,
          PublishErrorKind.auth);
      final limited = await run(_json({'errcode': 'M_LIMIT_EXCEEDED', 'error': 'Too many', 'retry_after_ms': 2000}, 429));
      expect(limited.kind, PublishErrorKind.quota);
      expect(limited.retryAfter, const Duration(seconds: 2));
      final header = await run(_json({'errcode': 'M_LIMIT_EXCEEDED'}, 429, {'retry-after': '5'}));
      expect(header.retryAfter, const Duration(seconds: 5));
      expect((await run(_json({'errcode': 'M_FORBIDDEN', 'error': 'not in room'}, 403))).kind, PublishErrorKind.auth);
      expect((await run(_json({'errcode': 'M_TOO_LARGE'}, 413))).kind, PublishErrorKind.validation);
      expect((await run(http.Response('', 502))).kind, PublishErrorKind.network);
    });
  });

  group('matrix refresh', () {
    test('nothing to do without refresh token or when still valid', () async {
      final ctx = testContext(handler: (r) async => fail('no request'));
      expect(await adapter.refreshSecrets(_mxAccount(), {'access_token': 't'}, ctx), isNull);
      final valid = OAuthTokens(accessToken: 't', refreshToken: 'r', expiresAt: testNow.add(const Duration(hours: 1)));
      expect(await adapter.refreshSecrets(_mxAccount(), valid.toSecrets(), ctx), isNull);
    });

    test('expired token is refreshed via /refresh', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'access_token': 'new_at', 'refresh_token': 'new_rt', 'expires_in_ms': 300000});
      });
      final old = OAuthTokens(accessToken: 'old', refreshToken: 'old_rt', expiresAt: testNow.subtract(const Duration(minutes: 1)));
      final s = await adapter.refreshSecrets(_mxAccount(), old.toSecrets(), ctx);
      expect(calls.map(_line), ['POST $_mxBase/_matrix/client/v3/refresh']);
      expect(bodyOf(calls.single), {'refresh_token': 'old_rt'});
      expect(s!['access_token'], 'new_at');
      expect(s['refresh_token'], 'new_rt');
      expect(DateTime.parse(s['expires_at']!), testNow.add(const Duration(minutes: 5)));
    });

    test('dead refresh token means reconnect', () async {
      final ctx = testContext(handler: (r) async => _json({'errcode': 'M_UNKNOWN_TOKEN', 'error': 'gone'}, 401));
      final old = OAuthTokens(accessToken: 'old', refreshToken: 'rt', expiresAt: testNow);
      expect(adapter.refreshSecrets(_mxAccount(), old.toSecrets(), ctx),
          throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)));
    });
  });

  group('matrix disconnect', () {
    test('logs out only devices NEFORUM created', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({});
      });
      await adapter.disconnect(_mxAccount(), {'access_token': 't'}, ctx);
      expect(calls, isEmpty);
      await adapter.disconnect(_mxAccount(extra: {'authMethod': 'password'}), {'access_token': 't'}, ctx);
      expect(calls.map(_line), ['POST $_mxBase/_matrix/client/v3/logout']);
    });
  });
}
