import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/lemmy/lemmy_adapter.dart';
import 'package:neforum_core/src/adapters/lemmy/lemmy_api.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

http.Response _json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {...jsonHeaders, ...headers});

http.Response _err(String code, [int status = 400]) => _json({'error': code}, status);

Map<String, dynamic> _site() => {
      'site_view': {
        'site': {'id': 1, 'name': 'Lemmy Example'},
      },
      'version': '0.19.20',
      'my_user': {
        'local_user_view': {
          'person': {
            'id': 42,
            'name': 'alice',
            'display_name': 'Alice',
            'avatar': 'https://lemmy.example/pictrs/image/avatar.webp',
          },
        },
      },
      'all_languages': [
        {'id': 0, 'code': 'und', 'name': 'Undetermined'},
        {'id': 37, 'code': 'en', 'name': 'English'},
        {'id': 32, 'code': 'de', 'name': 'Deutsch'},
        {'id': 99, 'code': 'fr', 'name': 'Français'},
      ],
      'discussion_languages': [0, 37, 32],
    };

Map<String, dynamic> _community(int id, String name, {String title = 'Technology'}) => {
      'community_view': {
        'community': {'id': id, 'name': name, 'title': title, 'actor_id': 'https://lemmy.world/c/$name'},
      },
    };

Map<String, dynamic> _postView(int id) => {
      'post_view': {
        'post': {'id': id, 'name': 'x', 'ap_id': 'https://lemmy.example/post/$id'},
      },
    };

ConnectedAccount _account({Map<String, dynamic> extra = const {}, PlatformTier tier = PlatformTier.openApi}) =>
    fakeAccount('lemmy', tier: tier, config: {
      'instance': 'https://lemmy.example',
      'host': 'lemmy.example',
      'username': 'alice',
      'community': 'technology@lemmy.world',
      'communityId': 7133,
      'languages': {'en': 37, 'de': 32},
      ...extra,
    });

const _secrets = {'access_token': 'JWT123', 'token_type': 'Bearer'};

PostVariant _post({
  String title = 'Hello Lemmy',
  String text = 'Some **markdown** body',
  String? link,
  List<MediaAttachment> media = const [],
  String? language,
  bool sensitive = false,
  Map<String, dynamic> extra = const {},
}) =>
    PostVariant(
      text: text,
      title: title,
      link: link,
      media: media,
      language: language,
      sensitive: sensitive,
      extra: extra,
    );

void main() {
  final adapter = LemmyAdapter();

  group('descriptor', () {
    test('limits match the research', () {
      final d = adapter.descriptor;
      expect(d.id, 'lemmy');
      expect(d.tiers, {PlatformTier.openApi, PlatformTier.handoff});
      expect(d.defaultTier, PlatformTier.openApi);
      expect(d.text.maxLength, 50000);
      expect(d.text.counting, CountingRule.utf16);
      expect(d.text.titleMax, 200);
      expect(d.text.titleRequired, isTrue);
      expect(d.text.titleSupported, isTrue);
      expect(d.text.supportsThreads, isFalse);
      expect(d.text.supportsContentWarning, isFalse);
      expect(d.text.supportsMarkdown, isTrue);
      expect(d.text.supportsHashtags, isFalse);
      expect(d.media.maxImages, 1);
      expect(d.media.allowsMixedImageVideo, isFalse);
      expect(d.media.imageMaxBytes, 20 * 1024 * 1024);
      expect(d.media.supportsAltText, isTrue);
      expect(d.media.requiresPublicMediaUrl, isFalse);
      final q = d.defaultQuotas.single;
      expect(q.id, 'lemmy.posts_per_10min');
      expect(q.limit, 6);
      expect(q.window, const Duration(minutes: 10));
      expect(q.appliesToTier, PlatformTier.openApi);
      expect(d.supportsLinkField, isTrue);
      expect(d.serverSideScheduling, isFalse);
      expect(d.personalAccountOk, isTrue);
      expect(d.setupGuide, 'docs/platforms/lemmy.md');
    });

    test('connect specs: password and 2FA are secret, no browser', () {
      final spec = adapter.specFor(PlatformTier.openApi);
      expect(spec.usesBrowser, isFalse);
      expect(spec.fields.map((f) => f.key), ['instance', 'username', 'password', 'totp', 'community']);
      expect(spec.fields.firstWhere((f) => f.key == 'password').secret, isTrue);
      final totp = spec.fields.firstWhere((f) => f.key == 'totp');
      expect(totp.secret, isTrue);
      expect(totp.required, isFalse);
      expect(adapter.specFor(PlatformTier.handoff).fields.map((f) => f.key), ['instance', 'community']);
    });
  });

  group('parsing', () {
    test('instance accepts hosts, URLs and handles', () {
      expect(parseLemmyInstance('lemmy.world').toString(), 'https://lemmy.world');
      expect(parseLemmyInstance(' https://Lemmy.World/c/technology ').toString(), 'https://lemmy.world');
      expect(parseLemmyInstance('@alice@lemmy.ml').toString(), 'https://lemmy.ml');
      expect(() => parseLemmyInstance(''), throwsA(isA<ConnectException>()));
      expect(() => parseLemmyInstance('http://lemmy.world'), throwsA(isA<ConnectException>()));
    });

    test('community spellings normalise', () {
      String? n(String s) => normalizeLemmyCommunity(s, homeHost: 'lemmy.example');
      expect(n('!technology@lemmy.world'), 'technology@lemmy.world');
      expect(n('technology@Lemmy.World'), 'technology@lemmy.world');
      expect(n('c/asklemmy'), 'asklemmy');
      expect(n('!asklemmy@lemmy.example'), 'asklemmy');
      expect(n('https://lemmy.world/c/technology'), 'technology@lemmy.world');
      expect(n('https://lemmy.example/c/linux@lemmy.ml'), 'linux@lemmy.ml');
      expect(n('https://kbin.earth/m/fediverse'), 'fediverse@kbin.earth');
      expect(n('not a community'), isNull);
      expect(n(''), isNull);
    });
  });

  group('connect', () {
    test('login, site, community lookup; stores jwt and config', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path == '/api/v3/user/login') {
          return _json({'jwt': 'JWT123', 'registration_created': false, 'verify_email_sent': false});
        }
        if (r.url.path == '/api/v3/site') return _json(_site());
        if (r.url.path == '/api/v3/community') return _json(_community(7133, 'technology'));
        return _json({}, 404);
      });
      final res = await adapter.connect(PlatformTier.openApi, {
        'instance': 'lemmy.example',
        'username': 'alice',
        'password': 'hunter2',
        'totp': '123 456',
        'community': '!technology@lemmy.world',
      }, ctx);

      expect(calls.map((c) => '${c.method} ${c.url.path}'), [
        'POST /api/v3/user/login',
        'GET /api/v3/site',
        'GET /api/v3/community',
      ]);
      expect(calls[0].url.host, 'lemmy.example');
      expect(bodyOf(calls[0]), {'username_or_email': 'alice', 'password': 'hunter2', 'totp_2fa_token': '123456'});
      expect(calls[0].headers.containsKey('Authorization'), isFalse);
      expect(calls[1].headers['Authorization'], 'Bearer JWT123');
      expect(calls[2].url.queryParameters, {'name': 'technology@lemmy.world'});

      expect(res.secrets, {'access_token': 'JWT123', 'token_type': 'Bearer'});
      expect(res.secrets.values, isNot(contains('hunter2')));
      final a = res.account;
      expect(a.id, 'lemmy:alice@lemmy.example');
      expect(a.handle, '@alice@lemmy.example');
      expect(a.displayName, 'Alice (lemmy.example)');
      expect(a.profileUrl, 'https://lemmy.example/u/alice');
      expect(a.config['instance'], 'https://lemmy.example');
      expect(a.config['personId'], 42);
      expect(a.config['version'], '0.19.20');
      expect(a.config['community'], 'technology@lemmy.world');
      expect(a.config['communityId'], 7133);
      expect(a.config['communityTitle'], 'Technology');
      expect(a.config['languages'], {'en': 37, 'de': 32}, reason: 'only discussion languages, no "und"');
    });

    test('2FA required -> ConnectException on totp', () async {
      final ctx = testContext(handler: (r) async => _err('missing_totp_token'));
      await expectLater(
        adapter.connect(PlatformTier.openApi, {'instance': 'lemmy.example', 'username': 'a', 'password': 'b'}, ctx),
        throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'totp')),
      );
    });

    test('wrong password (401 incorrect_login) -> ConnectException on password', () async {
      final ctx = testContext(handler: (r) async => _err('incorrect_login', 401));
      await expectLater(
        adapter.connect(PlatformTier.openApi, {'instance': 'lemmy.example', 'username': 'a', 'password': 'b'}, ctx),
        throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'password')),
      );
    });

    test('pending account (jwt null) -> ConnectException', () async {
      final ctx = testContext(handler: (r) async => _json({'jwt': null, 'registration_created': true}));
      await expectLater(
        adapter.connect(PlatformTier.openApi, {'instance': 'lemmy.example', 'username': 'a', 'password': 'b'}, ctx),
        throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('approval'))),
      );
    });

    test('PieFed server is recognised', () async {
      final ctx = testContext(handler: (r) async {
        if (r.url.path == '/api/alpha/site') return _json({'site': {'name': 'PieFed'}});
        return http.Response('not found', 404);
      });
      await expectLater(
        adapter.connect(PlatformTier.openApi, {'instance': 'piefed.example', 'username': 'a', 'password': 'b'}, ctx),
        throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('PieFed'))),
      );
    });

    test('unknown remote community falls back to resolve_object', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        switch (r.url.path) {
          case '/api/v3/user/login':
            return _json({'jwt': 'JWT123'});
          case '/api/v3/site':
            return _json(_site());
          case '/api/v3/community':
            return _err('couldnt_find_community', 404);
          case '/api/v3/resolve_object':
            return _json({'community': _community(555, 'rust')['community_view']});
        }
        return _json({}, 404);
      });
      final res = await adapter.connect(PlatformTier.openApi,
          {'instance': 'lemmy.example', 'username': 'alice', 'password': 'pw', 'community': 'rust@programming.dev'}, ctx);
      expect(calls.last.url.queryParameters, {'q': '!rust@programming.dev'});
      expect(calls.last.headers['Authorization'], 'Bearer JWT123');
      expect(res.account.config['communityId'], 555);
    });

    test('hand-off tier resolves the community without logging in', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json(_community(12, 'asklemmy', title: 'Ask Lemmy'));
      });
      final res = await adapter.connect(PlatformTier.handoff, {'instance': 'lemmy.example', 'community': 'asklemmy'}, ctx);
      expect(calls.single.url.path, '/api/v3/community');
      expect(res.secrets, isEmpty);
      expect(res.account.tier, PlatformTier.handoff);
      expect(res.account.config['communityId'], 12);
    });
  });

  group('validate', () {
    test('needs title and community; checks link scheme', () {
      final noCommunity = fakeAccount('lemmy', config: {'instance': 'https://lemmy.example'});
      final issues = adapter.validate(_post(title: '', link: 'ftp://x.example/file'), noCommunity);
      final codes = issues.map((i) => i.code).toList();
      expect(codes, containsAll(['title.required', 'lemmy.community_required', 'link.invalid']));
    });

    test('title too short / too long / newline', () {
      expect(adapter.validate(_post(title: 'Hi'), _account()).map((i) => i.code), contains('title.too_short'));
      expect(adapter.validate(_post(title: 'x' * 201), _account()).map((i) => i.code), contains('title.too_long'));
      final nl = adapter.validate(_post(title: 'Line one\nline two'), _account());
      expect(nl.firstWhere((i) => i.code == 'title.newline').severity, IssueSeverity.warning);
    });

    test('one image only; per-post community override satisfies the requirement', () {
      final two = adapter.validate(_post(media: [fakeImage(), fakeImage(id: 'img2')]), _account());
      expect(two.map((i) => i.code), contains('media.too_many_images'));
      final acct = fakeAccount('lemmy', config: {'instance': 'https://lemmy.example'});
      final ok = adapter.validate(_post(extra: {'community': '!linux@lemmy.ml'}), acct);
      expect(ok.where((i) => i.isError), isEmpty);
    });

    test('body over 50000 characters is an error', () {
      final issues = adapter.validate(_post(text: 'a' * 50001), _account());
      expect(issues.map((i) => i.code), contains('text.too_long'));
    });
  });

  group('publish', () {
    test('text + link post: POST /api/v3/post with cached community id', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json(_postView(901));
      });
      final res = await adapter.publish(
          _post(link: 'https://example.org/article', language: 'en-US', sensitive: true), _account(), _secrets, ctx);

      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteId, '901');
      expect(res.remoteUrl, 'https://lemmy.example/post/901');
      final c = calls.single;
      expect('${c.method} ${c.url}', 'POST https://lemmy.example/api/v3/post');
      expect(c.headers['Authorization'], 'Bearer JWT123');
      expect(bodyOf(c), {
        'name': 'Hello Lemmy',
        'community_id': 7133,
        'url': 'https://example.org/article',
        'body': 'Some **markdown** body',
        'nsfw': true,
        'language_id': 37,
      });
    });

    test('image post: upload to pict-rs, then url = image', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path == '/pictrs/image') {
          return _json({
            'msg': 'ok',
            'files': [
              {'file': 'abc123.jpeg', 'delete_token': 'del'},
            ],
          });
        }
        return _json(_postView(902));
      });
      final res = await adapter.publish(_post(media: [fakeImage(altText: 'A cat')]), _account(), _secrets, ctx);

      expect(res.success, isTrue, reason: '${res.error}');
      expect(calls.map((c) => '${c.method} ${c.url}'), [
        'POST https://lemmy.example/pictrs/image',
        'POST https://lemmy.example/api/v3/post',
      ]);
      expect(calls[0].headers['Authorization'], 'Bearer JWT123');
      expect(calls[0].headers['Cookie'], 'jwt=JWT123');
      expect(calls[0].headers['content-type'], startsWith('multipart/form-data'));
      expect(multipartFieldsOf(calls[0]), {'images[]': '<img1.jpg>'});
      expect(bodyOf(calls[1]), {
        'name': 'Hello Lemmy',
        'community_id': 7133,
        'url': 'https://lemmy.example/pictrs/image/abc123.jpeg',
        'body': 'Some **markdown** body',
        'alt_text': 'A cat',
        'nsfw': false,
      });
    });

    test('image + link: link in url, image embedded in body', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path == '/pictrs/image') {
          return _json({
            'msg': 'ok',
            'files': [
              {'file': 'pic.png', 'delete_token': 'd'},
            ],
          });
        }
        return _json(_postView(903));
      });
      await adapter.publish(
          _post(link: 'https://example.org', media: [fakeImage(altText: 'Chart')]), _account(), _secrets, ctx);
      final body = bodyOf(calls[1]);
      expect(body['url'], 'https://example.org');
      expect(body['body'], '![Chart](https://lemmy.example/pictrs/image/pic.png)\n\nSome **markdown** body');
      expect(body.containsKey('alt_text'), isFalse);
    });

    test('per-post community override is looked up first', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path == '/api/v3/community') return _json(_community(321, 'linux'));
        return _json(_postView(904));
      });
      final res = await adapter.publish(_post(extra: {'community': '!linux@lemmy.ml'}), _account(), _secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(calls.map((c) => '${c.method} ${c.url.path}'), ['GET /api/v3/community', 'POST /api/v3/post']);
      expect(calls[0].url.queryParameters, {'name': 'linux@lemmy.ml'});
      expect(bodyOf(calls[1])['community_id'], 321);
    });

    test('language_not_allowed retries once without language_id', () async {
      final bodies = <Map<String, dynamic>>[];
      final ctx = testContext(handler: (r) async {
        bodies.add(bodyOf(r));
        return bodies.length == 1 ? _err('language_not_allowed') : _json(_postView(905));
      });
      final res = await adapter.publish(_post(language: 'de'), _account(), _secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(bodies[0]['language_id'], 32);
      expect(bodies[1].containsKey('language_id'), isFalse);
    });

    test('newlines in the title become spaces', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json(_postView(906));
      });
      await adapter.publish(_post(title: ' Line one\n line two '), _account(), _secrets, ctx);
      expect(bodyOf(calls.single)['name'], 'Line one line two');
    });
  });

  group('error mapping', () {
    Future<PublishResult> run(http.Response response) =>
        adapter.publish(_post(), _account(), _secrets, testContext(handler: (r) async => response));

    test('not_logged_in (400) -> auth', () async {
      final res = await run(_err('not_logged_in'));
      expect(res.error!.kind, PublishErrorKind.auth);
    });

    test('401 -> auth', () async {
      final res = await run(_err('incorrect_login', 401));
      expect(res.error!.kind, PublishErrorKind.auth);
    });

    test('429 with Retry-After -> quota', () async {
      final res = await run(_json({'error': 'rate_limit_error'}, 429, {'retry-after': '120'}));
      expect(res.error!.kind, PublishErrorKind.quota);
      expect(res.error!.retryAfter, const Duration(seconds: 120));
    });

    test('Lemmy 0.19 rate limit (400 rate_limit_error) -> quota', () async {
      final res = await run(_err('rate_limit_error'));
      expect(res.error!.kind, PublishErrorKind.quota);
    });

    test('invalid_post_title / only mods -> validation', () async {
      expect((await run(_err('invalid_post_title'))).error!.kind, PublishErrorKind.validation);
      final mods = await run(_err('only_mods_can_post_in_community'));
      expect(mods.error!.kind, PublishErrorKind.validation);
      expect(mods.error!.message, contains('moderators'));
    });

    test('banned -> platform, 5xx -> network', () async {
      expect((await run(_err('banned_from_community'))).error!.kind, PublishErrorKind.platform);
      expect((await run(http.Response('oops', 502))).error!.kind, PublishErrorKind.network);
    });

    test('pict-rs 413 -> validation', () async {
      final ctx = testContext(handler: (r) async => http.Response('<html>413 Request Entity Too Large</html>', 413));
      final res = await adapter.publish(_post(media: [fakeImage()]), _account(), _secrets, ctx);
      expect(res.error!.kind, PublishErrorKind.validation);
      expect(res.error!.message, contains('larger'));
    });

    test('no stored jwt -> auth, no community -> configuration', () async {
      final ctx = testContext(handler: (r) async => _json({}));
      expect((await adapter.publish(_post(), _account(), const {}, ctx)).error!.kind, PublishErrorKind.auth);
      final noCommunity = fakeAccount('lemmy', config: {'instance': 'https://lemmy.example'});
      expect((await adapter.publish(_post(), noCommunity, _secrets, ctx)).error!.kind, PublishErrorKind.configuration);
    });
  });

  group('refreshSecrets / disconnect', () {
    test('jwt never expires: returns null; missing jwt -> auth', () async {
      final ctx = testContext(handler: (r) async => _json({}));
      expect(await adapter.refreshSecrets(_account(), _secrets, ctx), isNull);
      await expectLater(adapter.refreshSecrets(_account(), const {}, ctx), throwsA(isA<AdapterException>()));
    });

    test('disconnect logs out', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'success': true});
      });
      await adapter.disconnect(_account(), _secrets, ctx);
      expect('${calls.single.method} ${calls.single.url.path}', 'POST /api/v3/user/logout');
      expect(calls.single.headers['Authorization'], 'Bearer JWT123');
    });
  });

  group('hand-off', () {
    test('create_post URL with title, url, body, communityId, nsfw', () {
      final plan = adapter.buildHandoff(
        _post(link: 'https://example.org/a', sensitive: true, language: 'en'),
        account: _account(tier: PlatformTier.handoff),
      )!;
      final u = plan.webIntent!;
      expect('${u.scheme}://${u.host}${u.path}', 'https://lemmy.example/create_post');
      expect(u.queryParameters, {
        'title': 'Hello Lemmy',
        'url': 'https://example.org/a',
        'body': 'Some **markdown** body',
        'communityId': '7133',
        'languageId': '37',
        'nsfw': 'true',
      });
      expect(plan.preferred, HandoffMethod.webIntent);
      expect(plan.clipboardText, 'Some **markdown** body');
      expect(plan.instructions, startsWith('1. '));
      expect(plan.androidPackage, 'com.jerboa');
    });

    test('media -> share sheet with files; unknown override community is not prefilled', () {
      final plan = adapter.buildHandoff(
        _post(media: [fakeImage()], extra: {'community': '!linux@lemmy.ml'}),
        account: _account(),
      )!;
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.shareFiles, hasLength(1));
      expect(plan.webIntent!.queryParameters.containsKey('communityId'), isFalse);
      expect(plan.instructions, contains('!linux@lemmy.ml'));
      expect(plan.mediaNote, isNotNull);
    });

    test('very long body is left out of the URL but kept on the clipboard', () {
      final long = 'word ' * 3000;
      final plan = adapter.buildHandoff(_post(text: long), account: _account())!;
      expect(plan.webIntent!.queryParameters.containsKey('body'), isFalse);
      expect(plan.clipboardText, long.trim());
      expect(plan.instructions, contains('Paste the text'));
    });

    test('no account: manual plan', () {
      final plan = adapter.buildHandoff(_post())!;
      expect(plan.webIntent, isNull);
      expect(plan.preferred, HandoffMethod.manual);
    });
  });
}
