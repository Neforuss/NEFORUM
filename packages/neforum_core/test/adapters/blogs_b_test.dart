import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/blogs_b/devto_adapter.dart';
import 'package:neforum_core/src/adapters/blogs_b/hashnode_adapter.dart';
import 'package:neforum_core/src/adapters/blogs_b/micropub_adapter.dart';
import 'package:neforum_core/src/adapters/blogs_b/micropub_api.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

http.Response _json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {...jsonHeaders, ...headers});

/// Ordered (name, value) pairs of a form-encoded body (keeps repeats).
List<MapEntry<String, String>> _formPairs(http.Request r) => [
      for (final p in r.body.split('&').where((p) => p.isNotEmpty))
        MapEntry(Uri.decodeQueryComponent(p.split('=').first), Uri.decodeQueryComponent(p.split('=').skip(1).join('='))),
    ];

List<String> _values(List<MapEntry<String, String>> pairs, String key) =>
    pairs.where((e) => e.key == key).map((e) => e.value).toList();

Map<String, dynamic> _gqlBody(http.Request r) => Map<String, dynamic>.from(jsonDecode(r.body) as Map);

Map<String, dynamic> _gqlInput(http.Request r) =>
    Map<String, dynamic>.from((_gqlBody(r)['variables'] as Map)['input'] as Map);

void main() {
  micropubTests();
  devtoTests();
  hashnodeTests();
}

// =========================================================================
// Micropub
// =========================================================================

const _issuer = 'https://alice.example/';

http.Response _homePage({String extraHead = ''}) => http.Response(
      '<!doctype html><html><head><title>Alice</title>'
      '<link rel="indieauth-metadata" href="/.well-known/oauth-authorization-server">$extraHead</head><body></body></html>',
      200,
      headers: {
        'content-type': 'text/html; charset=utf-8',
        'link': '<https://alice.example/micropub>; rel="micropub", <https://alice.example/webmention>; rel="webmention"',
      },
    );

Map<String, dynamic> _metadata() => {
      'issuer': _issuer,
      'authorization_endpoint': 'https://alice.example/auth',
      'token_endpoint': 'https://alice.example/token',
      'revocation_endpoint': 'https://alice.example/revoke',
      'code_challenge_methods_supported': ['S256'],
      'authorization_response_iss_parameter_supported': true,
    };

ConnectedAccount _mpAccount({Map<String, dynamic> extra = const {}}) => fakeAccount('micropub', config: {
      'me': 'https://alice.example/',
      'micropubEndpoint': 'https://alice.example/micropub',
      'mediaEndpoint': 'https://alice.example/media',
      'authMethod': 'indieauth',
      'clientId': micropubDefaultClientId,
      'authorizationEndpoint': 'https://alice.example/auth',
      'tokenEndpoint': 'https://alice.example/token',
      'microblog': false,
      ...extra,
    });

const _mpSecrets = {'access_token': 'AT', 'token_type': 'Bearer'};

void micropubTests() {
  final adapter = MicropubAdapter();

  group('micropub descriptor', () {
    test('matches the spec research', () {
      final d = adapter.descriptor;
      expect(d.id, 'micropub');
      expect(d.tiers, {PlatformTier.openApi});
      expect(d.text.maxLength, isNull);
      expect(d.text.titleSupported, isTrue);
      expect(d.text.titleRequired, isFalse);
      expect(d.text.hashtagsAsField, isTrue);
      expect(d.text.supportsThreads, isFalse);
      expect(d.media.supportsAltText, isTrue);
      expect(d.media.requiresPublicMediaUrl, isFalse);
      expect(d.setupGuide, 'docs/platforms/micropub.md');
      final spec = adapter.specFor(PlatformTier.openApi);
      expect(spec.usesBrowser, isTrue);
      expect(spec.fields.first.key, 'me');
      expect(spec.fields.firstWhere((f) => f.key == 'token').secret, isTrue);
    });
  });

  group('micropub discovery helpers', () {
    test('canonicalMe', () {
      expect(canonicalMe('Alice.Example').toString(), 'https://alice.example/');
      expect(canonicalMe('https://alice.example/blog').toString(), 'https://alice.example/blog');
      expect(() => canonicalMe(''), throwsA(isA<ConnectException>()));
      expect(() => canonicalMe('ftp://x.example'), throwsA(isA<ConnectException>()));
    });
    test('Link header with several rels and relative targets', () {
      final links = parseLinkHeader('</auth>; rel="authorization_endpoint token_endpoint", <https://m.example/mp>; rel=micropub',
          Uri.parse('https://alice.example/'));
      expect(links.map((l) => '${l.rel} ${l.href}'), [
        'authorization_endpoint https://alice.example/auth',
        'token_endpoint https://alice.example/auth',
        'micropub https://m.example/mp',
      ]);
    });
    test('HTML link elements', () {
      final links = parseHtmlLinks("<link href='/mp?a=1&amp;b=2' rel='micropub'><LINK REL=\"me\" HREF=\"https://x.example\">",
          Uri.parse('https://alice.example/'));
      expect(links.first.href.toString(), 'https://alice.example/mp?a=1&b=2');
      expect(links.last.rel, 'me');
    });
  });

  group('micropub connect', () {
    test('IndieAuth: discovery, metadata, PKCE code flow, token, q=config', () async {
      final calls = <http.Request>[];
      final broker = FakeAuthBroker(extraParams: {'iss': _issuer});
      final ctx = testContext(broker: broker, handler: (r) async {
        calls.add(r);
        final u = r.url.toString();
        if (u == 'https://alice.example/') return _homePage();
        if (u == 'https://alice.example/.well-known/oauth-authorization-server') return _json(_metadata());
        if (u == 'https://alice.example/token') {
          return _json({
            'access_token': 'AT',
            'token_type': 'Bearer',
            'scope': 'create media',
            'me': 'https://alice.example/',
            'expires_in': 3600,
            'refresh_token': 'RT',
            'profile': {'name': 'Alice', 'photo': 'https://alice.example/me.jpg'},
          });
        }
        if (u == 'https://alice.example/micropub?q=config') {
          return _json({
            'media-endpoint': 'https://alice.example/media',
            'syndicate-to': [
              {'uid': 'https://social.example/@alice', 'name': 'Mastodon'},
            ],
          });
        }
        return _json({}, 404);
      });

      final res = await adapter.connect(PlatformTier.openApi, {'me': 'alice.example'}, ctx);

      expect(calls.map((c) => '${c.method} ${c.url}'), [
        'GET https://alice.example/',
        'GET https://alice.example/.well-known/oauth-authorization-server',
        'POST https://alice.example/token',
        'GET https://alice.example/micropub?q=config',
      ]);
      final auth = broker.lastAuthorizationUrl!;
      expect(auth.origin + auth.path, 'https://alice.example/auth');
      expect(auth.queryParameters['response_type'], 'code');
      expect(auth.queryParameters['client_id'], 'https://neforum.app/');
      expect(auth.queryParameters['redirect_uri'], 'http://127.0.0.1:52771/callback');
      expect(auth.queryParameters['scope'], 'create media');
      expect(auth.queryParameters['code_challenge_method'], 'S256');
      expect(auth.queryParameters['code_challenge'], isNotEmpty);
      expect(auth.queryParameters['me'], 'https://alice.example/');
      expect(auth.queryParameters['state'], isNotEmpty);

      final token = bodyOf(calls[2]);
      expect(token['grant_type'], 'authorization_code');
      expect(token['code'], 'test-code');
      expect(token['client_id'], 'https://neforum.app/');
      expect(token['redirect_uri'], 'http://127.0.0.1:52771/callback');
      expect((token['code_verifier'] as String).length, greaterThanOrEqualTo(43));
      expect(token.containsKey('client_secret'), isFalse);
      expect(calls[3].headers['Authorization'], 'Bearer AT');

      expect(res.account.id, 'micropub:https://alice.example/');
      expect(res.account.displayName, 'Alice (alice.example)');
      expect(res.account.avatarUrl, 'https://alice.example/me.jpg');
      expect(res.account.config['micropubEndpoint'], 'https://alice.example/micropub');
      expect(res.account.config['mediaEndpoint'], 'https://alice.example/media');
      expect(res.account.config['tokenEndpoint'], 'https://alice.example/token');
      expect(res.account.config['revocationEndpoint'], 'https://alice.example/revoke');
      expect(res.account.config['authMethod'], 'indieauth');
      expect(res.account.config['syndicateTargets'], [
        {'uid': 'https://social.example/@alice', 'name': 'Mastodon'},
      ]);
      expect(res.secrets['access_token'], 'AT');
      expect(res.secrets['refresh_token'], 'RT');
      expect(res.secrets['expires_at'], testNow.add(const Duration(hours: 1)).toIso8601String());
    });

    test('rejects a redirect whose iss does not match the issuer', () async {
      final ctx = testContext(broker: FakeAuthBroker(extraParams: {'iss': 'https://evil.example/'}), handler: (r) async {
        final u = r.url.toString();
        if (u == 'https://alice.example/') return _homePage();
        if (u.contains('oauth-authorization-server')) return _json(_metadata());
        return _json({}, 404);
      });
      await expectLater(adapter.connect(PlatformTier.openApi, {'me': 'alice.example'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('issuer'))));
    });

    test('rejects a returned me that uses another authorization server', () async {
      final ctx = testContext(broker: FakeAuthBroker(extraParams: {'iss': _issuer}), handler: (r) async {
        final u = r.url.toString();
        if (u == 'https://alice.example/') return _homePage();
        if (u.contains('oauth-authorization-server')) return _json(_metadata());
        if (u == 'https://alice.example/token') return _json({'access_token': 'AT', 'me': 'https://bob.example/'});
        if (u == 'https://bob.example/') {
          return http.Response('<link rel="authorization_endpoint" href="https://other.example/auth">', 200,
              headers: {'content-type': 'text/html'});
        }
        return _json({}, 404);
      });
      await expectLater(adapter.connect(PlatformTier.openApi, {'me': 'alice.example'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('same IndieAuth server'))));
    });

    test('Micro.blog app token skips the browser', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.toString() == 'https://alice.micro.blog/') {
          return http.Response('<link rel="micropub" href="https://micro.blog/micropub">', 200,
              headers: {'content-type': 'text/html'});
        }
        if (r.url.toString() == 'https://micro.blog/micropub?q=config') {
          return _json({
            'media-endpoint': 'https://micro.blog/micropub/media',
            'destination': [
              {'uid': 'https://alice.micro.blog/', 'name': 'alice.micro.blog'},
            ],
          });
        }
        return _json({}, 404);
      });
      final res = await adapter.connect(PlatformTier.openApi, {'me': 'alice.micro.blog', 'token': ' MBTOKEN '}, ctx);
      expect(calls.map((c) => '${c.method} ${c.url}'), [
        'GET https://alice.micro.blog/',
        'GET https://micro.blog/micropub?q=config',
      ]);
      expect(calls[1].headers['Authorization'], 'Bearer MBTOKEN');
      expect(res.secrets['access_token'], 'MBTOKEN');
      expect(res.account.config['microblog'], isTrue);
      expect(res.account.config['authMethod'], 'token');
      expect(res.account.config['mediaEndpoint'], 'https://micro.blog/micropub/media');
      expect(res.account.config['destinations'], [
        {'uid': 'https://alice.micro.blog/', 'name': 'alice.micro.blog'},
      ]);
    });

    test('bad pasted token is reported on the token field', () async {
      final ctx = testContext(handler: (r) async {
        if (r.url.path == '/') {
          return http.Response('<link rel="micropub" href="/micropub">', 200, headers: {'content-type': 'text/html'});
        }
        return _json({'error': 'unauthorized'}, 401);
      });
      await expectLater(adapter.connect(PlatformTier.openApi, {'me': 'alice.example', 'token': 'bad'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'token')));
    });
  });

  group('micropub validate', () {
    test('Micro.blog long untitled post gets a hint; bad postStatus is an error', () {
      final long = PostVariant(text: 'x' * 301, extra: const {'postStatus': 'scheduled'});
      final issues = adapter.validate(long, _mpAccount(extra: {'microblog': true}));
      expect(issues.map((i) => i.code), containsAll(['microblog.long_untitled', 'micropub.post_status']));
      expect(issues.firstWhere((i) => i.code == 'micropub.post_status').isError, isTrue);
      expect(adapter.validate(const PostVariant(text: 'short'), _mpAccount()).hasErrors, isFalse);
    });
  });

  group('micropub publish', () {
    test('uploads to the media endpoint, then form-encoded h=entry', () async {
      final calls = <http.Request>[];
      var n = 0;
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.toString() == 'https://alice.example/media') {
          n++;
          return http.Response('', 202, headers: {'location': '/media/$n.jpg'});
        }
        if (r.url.toString() == 'https://alice.example/micropub') {
          return http.Response('', 201, headers: {'location': 'https://alice.example/2026/10/hello'});
        }
        return _json({}, 404);
      });
      final variant = PostVariant(
        text: 'Hello **world**',
        title: 'Hello',
        tags: const ['indieweb', 'neforum'],
        media: [fakeImage(id: 'img1', altText: 'First'), fakeImage(id: 'img2', altText: 'Second')],
        extra: const {'syndicateTo': ['https://social.example/@alice'], 'slug': 'hello'},
      );
      final res = await adapter.publish(variant, _mpAccount(), _mpSecrets, ctx);

      expect(res.success, isTrue, reason: '${res.error}');
      expect(calls.map((c) => '${c.method} ${c.url}'), [
        'POST https://alice.example/media',
        'POST https://alice.example/media',
        'POST https://alice.example/micropub',
      ]);
      expect(calls[0].headers['Authorization'], 'Bearer AT');
      expect(multipartFieldsOf(calls[0]), {'file': '<img1.jpg>'});
      expect(multipartFieldsOf(calls[1]), {'file': '<img2.jpg>'});
      expect(calls[2].headers['content-type'], startsWith('application/x-www-form-urlencoded'));
      expect(calls[2].headers['Authorization'], 'Bearer AT');
      final pairs = _formPairs(calls[2]);
      expect(_values(pairs, 'h'), ['entry']);
      expect(_values(pairs, 'content'), ['Hello **world**']);
      expect(_values(pairs, 'name'), ['Hello']);
      expect(_values(pairs, 'category[]'), ['indieweb', 'neforum']);
      expect(_values(pairs, 'photo[]'), ['https://alice.example/media/1.jpg', 'https://alice.example/media/2.jpg']);
      expect(_values(pairs, 'mp-photo-alt[]'), ['First', 'Second']);
      expect(_values(pairs, 'mp-syndicate-to[]'), ['https://social.example/@alice']);
      expect(_values(pairs, 'mp-slug'), ['hello']);
      expect(res.remoteUrl, 'https://alice.example/2026/10/hello');
      expect(res.remoteId, 'https://alice.example/2026/10/hello');
    });

    test('without a media endpoint the photo rides along as multipart', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return http.Response('', 202, headers: {'location': 'https://alice.example/p/1'});
      });
      final account = fakeAccount('micropub', config: {'micropubEndpoint': 'https://alice.example/micropub'});
      final res = await adapter.publish(
          PostVariant(text: 'Pic', tags: const ['a'], media: [fakeImage(altText: 'Alt')]), account, _mpSecrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(calls.single.url.toString(), 'https://alice.example/micropub');
      expect(calls.single.headers['content-type'], startsWith('multipart/form-data; boundary='));
      final fields = multipartFieldsOf(calls.single);
      expect(fields['h'], 'entry');
      expect(fields['content'], 'Pic');
      expect(fields['category[]'], 'a');
      expect(fields['photo'], '<img1.jpg>');
      expect(fields['mp-photo-alt'], 'Alt');
    });

    test('Micro.blog draft answer without Location uses the JSON url', () async {
      final ctx = testContext(handler: (r) async => _json({'url': 'https://alice.micro.blog/2026/x.html', 'preview': 'https://micro.blog/preview'}, 202));
      final res = await adapter.publish(
          const PostVariant(text: 'Draft', extra: {'postStatus': 'draft'}), _mpAccount(extra: {'mediaEndpoint': ''}), _mpSecrets, ctx);
      expect(res.remoteUrl, 'https://alice.micro.blog/2026/x.html');
    });

    Future<PublishResult> failWith(http.Response response) => adapter.publish(
        const PostVariant(text: 'hi'), _mpAccount(), _mpSecrets, testContext(handler: (r) async => response));

    test('error mapping', () async {
      expect((await failWith(_json({'error': 'unauthorized'}, 401))).error!.kind, PublishErrorKind.auth);
      expect((await failWith(_json({'error': 'insufficient_scope', 'scope': 'create'}, 403))).error!.kind, PublishErrorKind.auth);
      final v = await failWith(_json({'error': 'invalid_request', 'error_description': 'content is missing'}, 400));
      expect(v.error!.kind, PublishErrorKind.validation);
      expect(v.error!.message, contains('content is missing'));
      final q = await failWith(http.Response('slow down', 429, headers: {'retry-after': '120'}));
      expect(q.error!.kind, PublishErrorKind.quota);
      expect(q.error!.retryAfter, const Duration(seconds: 120));
      expect((await failWith(http.Response('', 201))).error!.kind, PublishErrorKind.platform);
      final noToken = await adapter.publish(const PostVariant(text: 'hi'), _mpAccount(), const {}, testContext(handler: (r) async => _json({})));
      expect(noToken.error!.kind, PublishErrorKind.auth);
    });
  });

  group('micropub refreshSecrets', () {
    final expired = {
      ..._mpSecrets,
      'refresh_token': 'RT',
      'expires_at': testNow.subtract(const Duration(minutes: 1)).toIso8601String(),
    };

    test('refreshes an expired token at the token endpoint', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'access_token': 'AT2', 'refresh_token': 'RT2', 'expires_in': 3600, 'me': 'https://alice.example/'});
      });
      final out = await adapter.refreshSecrets(_mpAccount(), expired, ctx);
      expect(calls.single.url.toString(), 'https://alice.example/token');
      final body = bodyOf(calls.single);
      expect(body['grant_type'], 'refresh_token');
      expect(body['refresh_token'], 'RT');
      expect(body['client_id'], 'https://neforum.app/');
      expect(out!['access_token'], 'AT2');
      expect(out['refresh_token'], 'RT2');
    });

    test('returns null while the token is valid; auth error without refresh token', () async {
      final ctx = testContext(handler: (r) async => _json({}, 500));
      final valid = {..._mpSecrets, 'expires_at': testNow.add(const Duration(hours: 1)).toIso8601String()};
      expect(await adapter.refreshSecrets(_mpAccount(), valid, ctx), isNull);
      expect(await adapter.refreshSecrets(_mpAccount(), _mpSecrets, ctx), isNull);
      final noRefresh = {..._mpSecrets, 'expires_at': testNow.subtract(const Duration(hours: 1)).toIso8601String()};
      await expectLater(adapter.refreshSecrets(_mpAccount(), noRefresh, ctx),
          throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)));
    });

    test('refused refresh means reconnect', () async {
      final ctx = testContext(handler: (r) async => _json({'error': 'invalid_grant'}, 400));
      await expectLater(adapter.refreshSecrets(_mpAccount(), expired, ctx),
          throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)));
    });
  });

  group('micropub hand-off', () {
    test('Micro.blog uses the app scheme and share sheet', () {
      final plan = adapter.buildHandoff(const PostVariant(text: 'Hello world'), account: _mpAccount(extra: {'microblog': true}))!;
      expect(plan.iosScheme, 'microblog://post?text=Hello%20world');
      expect(plan.androidPackage, 'blog.micro.android');
      expect(plan.clipboardText, 'Hello world');
      expect(plan.preferred, HandoffMethod.shareSheet);
    });
    test('other sites: manual with the home page', () {
      final plan = adapter.buildHandoff(const PostVariant(text: 'Hi', title: 'T'), account: _mpAccount())!;
      expect(plan.preferred, HandoffMethod.manual);
      expect(plan.desktopUrl, 'https://alice.example/');
      expect(plan.instructions, contains('"T"'));
    });
  });
}

// =========================================================================
// DEV
// =========================================================================

ConnectedAccount _devAccount({PlatformTier tier = PlatformTier.openApi}) => fakeAccount('devto', tier: tier, config: {
      'base': 'https://dev.to',
      'userId': '123',
      'username': 'alice',
    });

const _devSecrets = {'access_token': 'DEVKEY', 'token_type': 'api-key'};

void devtoTests() {
  final adapter = DevtoAdapter();

  group('devto descriptor', () {
    test('limits match Forem', () {
      final d = adapter.descriptor;
      expect(d.id, 'devto');
      expect(d.tiers, {PlatformTier.openApi, PlatformTier.handoff});
      expect(d.text.titleRequired, isTrue);
      expect(d.text.titleMax, 128);
      expect(d.text.maxHashtags, 4);
      expect(d.text.hashtagsAsField, isTrue);
      expect(d.text.maxLength, 800 * 1024);
      expect(d.text.counting, CountingRule.utf8Bytes);
      expect(d.media.requiresPublicMediaUrl, isTrue);
      expect(d.media.maxVideos, 0);
      expect(d.defaultQuotas.single.id, 'devto.articles_per_30s');
      expect(d.defaultQuotas.single.limit, 10);
      expect(d.defaultQuotas.single.window, const Duration(seconds: 30));
      expect(adapter.specFor(PlatformTier.openApi).fields.first.secret, isTrue);
    });
  });

  group('devto connect', () {
    test('checks the key with GET /api/users/me', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'id': 123, 'username': 'alice', 'name': 'Alice', 'profile_image': 'https://dev.to/a.png'});
      });
      final res = await adapter.connect(PlatformTier.openApi, {'apiKey': ' DEVKEY '}, ctx);
      expect(calls.single.method, 'GET');
      expect(calls.single.url.toString(), 'https://dev.to/api/users/me');
      expect(calls.single.headers['api-key'], 'DEVKEY');
      expect(calls.single.headers['Accept'], 'application/vnd.forem.api-v1+json');
      expect(res.account.id, 'devto:123@dev.to');
      expect(res.account.handle, '@alice');
      expect(res.account.profileUrl, 'https://dev.to/alice');
      expect(res.secrets['access_token'], 'DEVKEY');
    });

    test('401 becomes a ConnectException on the key field', () async {
      final ctx = testContext(handler: (r) async => _json({'error': 'unauthorized', 'status': 401}, 401));
      await expectLater(adapter.connect(PlatformTier.openApi, {'apiKey': 'x'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'apiKey')));
    });

    test('hand-off needs no key', () async {
      final res = await adapter.connect(PlatformTier.handoff, const {}, testContext(handler: (r) async => _json({})));
      expect(res.account.tier, PlatformTier.handoff);
      expect(res.secrets, isEmpty);
    });
  });

  group('devto validate', () {
    test('title required, tag rules', () {
      final issues = adapter.validate(
          const PostVariant(text: 'Body', tags: ['Flutter', 'dart', 'web-dev', 'a', 'b']), _devAccount());
      expect(issues.map((i) => i.code), containsAll(['title.required', 'hashtags.too_many', 'devto.tag_cleaned', 'devto.tags_dropped']));
      final long = adapter.validate(PostVariant(text: 'B', title: 'x' * 129), _devAccount());
      expect(long.map((i) => i.code), contains('title.too_long'));
      final canon = adapter.validate(const PostVariant(text: 'B', title: 'T', extra: {'canonicalUrl': 'not a url'}), _devAccount());
      expect(canon.map((i) => i.code), contains('devto.canonical_url'));
    });
  });

  group('devto publish', () {
    test('hosts images, then POST /api/articles', () async {
      final calls = <http.Request>[];
      final host = FakeMediaHost();
      final ctx = testContext(mediaHost: host, handler: (r) async {
        calls.add(r);
        return _json({'id': 987, 'url': 'https://dev.to/alice/hello-1a2b', 'published': true}, 201);
      });
      final variant = PostVariant(
        text: 'Body text',
        title: 'Hello',
        tags: const ['Flutter', 'dart', 'web-dev', 'opensource', 'extra'],
        media: [fakeImage(id: 'img1'), fakeImage(id: 'img2', altText: 'Second')],
        extra: const {'canonicalUrl': 'https://alice.example/hello', 'series': 'Diary'},
      );
      final res = await adapter.publish(variant, _devAccount(), _devSecrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(host.uploaded.map((m) => m.id), ['img1', 'img2']);
      expect(calls.single.method, 'POST');
      expect(calls.single.url.toString(), 'https://dev.to/api/articles');
      expect(calls.single.headers['api-key'], 'DEVKEY');
      expect(calls.single.headers['Accept'], 'application/vnd.forem.api-v1+json');
      final article = Map<String, dynamic>.from(bodyOf(calls.single)['article'] as Map);
      expect(article['title'], 'Hello');
      expect(article['body_markdown'], 'Body text\n\n![Second](https://cdn.example.test/img2)');
      expect(article['published'], isTrue);
      expect(article['tags'], ['flutter', 'dart', 'webdev', 'opensource']);
      expect(article['main_image'], 'https://cdn.example.test/img1');
      expect(article['canonical_url'], 'https://alice.example/hello');
      expect(article['series'], 'Diary');
      expect(res.remoteId, '987');
      expect(res.remoteUrl, 'https://dev.to/alice/hello-1a2b');
    });

    test('draft flag and images without a media host', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'id': 1, 'url': 'https://dev.to/x'}, 201);
      });
      await adapter.publish(const PostVariant(text: 'B', title: 'T', extra: {'draft': true}), _devAccount(), _devSecrets, ctx);
      expect((bodyOf(calls.single)['article'] as Map)['published'], isFalse);
      final noHost = await adapter.publish(PostVariant(text: 'B', title: 'T', media: [fakeImage()]), _devAccount(), _devSecrets, ctx);
      expect(noHost.error!.kind, PublishErrorKind.configuration);
      final noTitle = await adapter.publish(const PostVariant(text: 'B'), _devAccount(), _devSecrets, ctx);
      expect(noTitle.error!.kind, PublishErrorKind.validation);
      expect(calls, hasLength(1));
    });

    Future<PublishResult> failWith(http.Response response) => adapter.publish(
        const PostVariant(text: 'B', title: 'T'), _devAccount(), _devSecrets, testContext(handler: (r) async => response));

    test('error mapping', () async {
      expect((await failWith(_json({'error': 'unauthorized', 'status': 401}, 401))).error!.kind, PublishErrorKind.auth);
      final v = await failWith(_json({'error': 'Title has already been used in the last five minutes', 'status': 422}, 422));
      expect(v.error!.kind, PublishErrorKind.validation);
      expect(v.error!.message, contains('last five minutes'));
      final q = await failWith(_json({'error': 'Rate limit reached', 'status': 429}, 429, {'retry-after': '27'}));
      expect(q.error!.kind, PublishErrorKind.quota);
      expect(q.error!.retryAfter, const Duration(seconds: 27));
      expect((await failWith(_json({}, 503))).error!.kind, PublishErrorKind.network);
    });
  });

  group('devto hand-off', () {
    test('dev.to/new?prefill with front matter', () {
      final plan = adapter.buildHandoff(const PostVariant(text: 'Body', title: 'Say "hi"', tags: ['Flutter', 'dart']))!;
      final intent = plan.webIntent!;
      expect(intent.origin + intent.path, 'https://dev.to/new');
      expect(intent.toString(), contains('prefill=---%0Atitle%3A%20'));
      expect(intent.queryParameters['prefill'],
          '---\ntitle: "Say \\"hi\\""\npublished: true\ntags: flutter, dart\n---\n\nBody');
      expect(plan.clipboardText, intent.queryParameters['prefill']);
      expect(plan.preferred, HandoffMethod.webIntent);
    });
  });
}

// =========================================================================
// Hashnode
// =========================================================================

ConnectedAccount _hnAccount({PlatformTier tier = PlatformTier.byokApi}) => fakeAccount('hashnode', tier: tier, config: {
      'publicationId': '650000000000000000000001',
      'publicationUrl': 'https://alice.hashnode.dev',
      'username': 'alice',
    });

const _hnSecrets = {'access_token': 'PAT123', 'token_type': 'PAT'};

Map<String, dynamic> _proError() => {
      'errors': [
        {
          'message': 'Publication does not have an active Pro plan. Upgrade in your dashboard to access this via the API.',
          'extensions': {'code': 'FORBIDDEN'},
        },
      ],
      'data': null,
    };

void hashnodeTests() {
  final adapter = HashnodeAdapter();

  group('hashnode descriptor', () {
    test('limits match the docs', () {
      final d = adapter.descriptor;
      expect(d.id, 'hashnode');
      expect(d.tiers, {PlatformTier.byokApi, PlatformTier.handoff});
      expect(d.defaultTier, PlatformTier.byokApi);
      expect(d.text.titleRequired, isTrue);
      expect(d.text.maxHashtags, 15);
      expect(d.media.imageMaxBytes, 8 * 1024 * 1024);
      expect(d.media.imageMimeTypes, isNot(contains('image/svg+xml')));
      expect(d.defaultQuotas.single.id, 'hashnode.mutations_per_minute');
      expect(d.defaultQuotas.single.limit, 500);
      expect(d.apiCostSummary, contains('Pro'));
    });
  });

  group('hashnode connect', () {
    test('me, then publication(host:)', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        final q = _gqlBody(r)['query'] as String;
        if (q.contains('me {')) {
          return _json({
            'data': {
              'me': {'id': 'u1', 'username': 'alice', 'name': 'Alice', 'profilePicture': 'https://cdn.hashnode.com/a.png', 'publications': {'edges': <Object>[]}},
            },
          });
        }
        return _json({
          'data': {
            'publication': {'id': '650000000000000000000001', 'title': 'Alice writes', 'url': 'https://alice.hashnode.dev'},
          },
        });
      });
      final res = await adapter.connect(PlatformTier.byokApi, {'token': 'PAT123', 'publication': 'https://alice.hashnode.dev/'}, ctx);
      expect(calls.map((c) => '${c.method} ${c.url}'), ['POST https://gql.hashnode.com', 'POST https://gql.hashnode.com']);
      expect(calls.first.headers['Authorization'], 'PAT123');
      expect(_gqlBody(calls[1])['query'], contains('publication(host: \$host)'));
      expect(_gqlBody(calls[1])['variables'], {'host': 'alice.hashnode.dev'});
      expect(res.account.id, 'hashnode:650000000000000000000001');
      expect(res.account.displayName, 'Alice writes');
      expect(res.account.config['publicationId'], '650000000000000000000001');
      expect(res.secrets['access_token'], 'PAT123');
    });

    test('single blog is picked automatically', () async {
      final ctx = testContext(handler: (r) async => _json({
            'data': {
              'me': {
                'id': 'u1',
                'username': 'alice',
                'name': 'Alice',
                'publications': {
                  'edges': [
                    {
                      'node': {'id': '650000000000000000000009', 'title': 'Only', 'url': 'https://only.hashnode.dev'},
                    },
                  ],
                },
              },
            },
          }));
      final res = await adapter.connect(PlatformTier.byokApi, {'token': 'PAT123'}, ctx);
      expect(res.account.config['publicationId'], '650000000000000000000009');
    });

    test('no Pro plan -> clear ConnectException', () async {
      final ctx = testContext(handler: (r) async => _json(_proError()));
      await expectLater(adapter.connect(PlatformTier.byokApi, {'token': 'PAT123', 'publication': 'alice.hashnode.dev'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('Pro'))));
    });
  });

  group('hashnode validate', () {
    test('title required, svg refused', () {
      final issues = adapter.validate(
          PostVariant(text: 'B', media: [fakeImage(mimeType: 'image/svg+xml')]), _hnAccount());
      expect(issues.map((i) => i.code), containsAll(['title.required', 'media.svg']));
      final big = adapter.validate(PostVariant(text: 'x' * (100 * 1024), title: 'T'), _hnAccount());
      expect(big.map((i) => i.code), contains('hashnode.too_large'));
    });
  });

  group('hashnode publish', () {
    test('uploads the cover, then publishPost', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.method == 'PUT') return http.Response('', 200);
        final q = _gqlBody(r)['query'] as String;
        if (q.contains('createImageUploadURL')) {
          return _json({
            'data': {
              'createImageUploadURL': {
                'presignedPut': {'url': 'https://s3.example.test/up?sig=1', 'cdnUrl': 'https://cdn.hashnode.com/res/k1.jpg', 'key': 'k1'},
              },
            },
          });
        }
        if (q.contains('confirmImageUpload')) {
          return _json({
            'data': {
              'confirmImageUpload': {'ok': true, 'cdnUrl': 'https://cdn.hashnode.com/res/k1.jpg'},
            },
          });
        }
        return _json({
          'data': {
            'publishPost': {
              'post': {'id': 'p1', 'slug': 'hello', 'url': 'https://alice.hashnode.dev/hello'},
            },
          },
        });
      });
      final variant = PostVariant(
        text: 'Body',
        title: 'Hello',
        tags: const ['Web Dev', 'dart'],
        media: [fakeImage()],
        extra: const {'canonicalUrl': 'https://alice.example/hello', 'subtitle': 'Sub'},
      );
      final res = await adapter.publish(variant, _hnAccount(), _hnSecrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(calls.map((c) => '${c.method} ${c.url}'), [
        'POST https://gql.hashnode.com',
        'PUT https://s3.example.test/up?sig=1',
        'POST https://gql.hashnode.com',
        'POST https://gql.hashnode.com',
      ]);
      expect(calls.first.headers['Authorization'], 'PAT123');
      expect(_gqlInput(calls[0]), {'contentType': 'image/jpeg'});
      expect(calls[1].headers['content-type'], 'image/jpeg');
      expect(calls[1].bodyBytes, fakeJpegBytes);
      expect(_gqlInput(calls[2]), {'key': 'k1'});
      expect(_gqlBody(calls[3])['query'], contains('publishPost(input: \$input)'));
      final input = _gqlInput(calls[3]);
      expect(input['publicationId'], '650000000000000000000001');
      expect(input['title'], 'Hello');
      expect(input['contentMarkdown'], 'Body');
      expect(input['tags'], [
        {'slug': 'web-dev', 'name': 'Web Dev'},
        {'slug': 'dart', 'name': 'dart'},
      ]);
      expect(input['coverImageOptions'], {'coverImageURL': 'https://cdn.hashnode.com/res/k1.jpg'});
      expect(input['originalArticleURL'], 'https://alice.example/hello');
      expect(input['subtitle'], 'Sub');
      expect(res.remoteId, 'p1');
      expect(res.remoteUrl, 'https://alice.hashnode.dev/hello');
    });

    test('falls back to coverImage when coverImageOptions is unknown', () async {
      final inputs = <Map<String, dynamic>>[];
      final ctx = testContext(handler: (r) async {
        inputs.add(_gqlInput(r));
        if (inputs.length == 1) {
          return _json({
            'errors': [
              {
                'message': 'Field "coverImageOptions" is not defined by type "PublishPostInput".',
                'extensions': {'code': 'GRAPHQL_VALIDATION_FAILED'},
              },
            ],
          }, 400);
        }
        return _json({
          'data': {
            'publishPost': {
              'post': {'id': 'p2', 'url': 'https://alice.hashnode.dev/x'},
            },
          },
        });
      });
      final res = await adapter.publish(
          const PostVariant(text: 'B', title: 'T', extra: {'coverImageUrl': 'https://img.example/c.png'}), _hnAccount(), _hnSecrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(inputs, hasLength(2));
      expect(inputs[1]['coverImage'], 'https://img.example/c.png');
      expect(inputs[1].containsKey('coverImageOptions'), isFalse);
    });

    Future<PublishResult> failWith(http.Response response) => adapter.publish(
        const PostVariant(text: 'B', title: 'T'), _hnAccount(), _hnSecrets, testContext(handler: (r) async => response));

    test('error mapping', () async {
      final unauth = await failWith(_json({
        'errors': [
          {'message': 'Invalid token', 'extensions': {'code': 'UNAUTHENTICATED'}},
        ],
      }));
      expect(unauth.error!.kind, PublishErrorKind.auth);
      final pro = await failWith(_json(_proError()));
      expect(pro.error!.kind, PublishErrorKind.configuration);
      expect(pro.error!.message, contains('Pro'));
      final bad = await failWith(_json({
        'errors': [
          {'message': 'Title is too long', 'extensions': {'code': 'BAD_USER_INPUT'}},
        ],
      }));
      expect(bad.error!.kind, PublishErrorKind.validation);
      expect(bad.error!.message, contains('Title is too long'));
      final q = await failWith(http.Response('Too many requests', 429, headers: {'retry-after': '60'}));
      expect(q.error!.kind, PublishErrorKind.quota);
      expect(q.error!.retryAfter, const Duration(seconds: 60));
      expect((await failWith(http.Response('', 401))).error!.kind, PublishErrorKind.auth);
      expect((await failWith(http.Response('oops', 502))).error!.kind, PublishErrorKind.network);
    });

    test('image refused by confirmImageUpload is a validation error', () async {
      final ctx = testContext(handler: (r) async {
        if (r.method == 'PUT') return http.Response('', 200);
        final q = _gqlBody(r)['query'] as String;
        if (q.contains('createImageUploadURL')) {
          return _json({
            'data': {
              'createImageUploadURL': {
                'presignedPut': {'url': 'https://s3.example.test/up', 'cdnUrl': 'https://cdn.example/k', 'key': 'k'},
              },
            },
          });
        }
        return _json({
          'data': {
            'confirmImageUpload': {'ok': false, 'cdnUrl': null},
          },
        });
      });
      final res = await adapter.publish(PostVariant(text: 'B', title: 'T', media: [fakeImage()]), _hnAccount(), _hnSecrets, ctx);
      expect(res.error!.kind, PublishErrorKind.validation);
    });
  });

  group('hashnode hand-off', () {
    test('manual with the article on the clipboard', () {
      final plan = adapter.buildHandoff(const PostVariant(text: 'Body', title: 'Hello', tags: ['dart']))!;
      expect(plan.preferred, HandoffMethod.manual);
      expect(plan.clipboardText, 'Body');
      expect(plan.desktopUrl, 'https://hashnode.com/');
      expect(plan.instructions, contains('"Hello"'));
      expect(plan.instructions, contains('dart'));
    });
  });
}
