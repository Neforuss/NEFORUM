import 'dart:convert';

import 'package:convert/convert.dart' show hex;
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/blogs_a/blog_common.dart';
import 'package:neforum_core/src/adapters/blogs_a/ghost_adapter.dart';
import 'package:neforum_core/src/adapters/blogs_a/ghost_api.dart';
import 'package:neforum_core/src/adapters/blogs_a/wordpress_adapter.dart';
import 'package:neforum_core/src/adapters/blogs_a/writefreely_adapter.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

http.Response _json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {...jsonHeaders, ...headers});

String _basic(String user, String pass) => 'Basic ${base64Encode(utf8.encode('$user:$pass'))}';

Map<String, dynamic> _jwtPart(String token, int index) =>
    Map<String, dynamic>.from(jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[index])))) as Map);

const _ghostKeyId = '6489d8a1b2c3d4e5f6a7b8c9';
const _ghostSecret = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _ghostKey = '$_ghostKeyId:$_ghostSecret';

void main() {
  group('blog_common', () {
    test('parseBlogSiteUrl normalises addresses', () {
      expect(parseBlogSiteUrl('example.com').toString(), 'https://example.com');
      expect(parseBlogSiteUrl(' https://Example.com/blog/wp-admin/post-new.php ').toString(), 'https://example.com/blog');
      expect(parseBlogSiteUrl('https://x.ghost.io/ghost/#/dashboard').toString(), 'https://x.ghost.io');
      expect(parseBlogSiteUrl('http://localhost:8080').toString(), 'http://localhost:8080');
      expect(() => parseBlogSiteUrl('http://example.com'), throwsA(isA<ConnectException>()));
      expect(() => parseBlogSiteUrl(''), throwsA(isA<ConnectException>()));
      expect(() => parseBlogSiteUrl('notahost'), throwsA(isA<ConnectException>()));
    });

    test('plainTextToHtml builds paragraphs, lists, headings and links', () {
      final html = plainTextToHtml('## Intro\n\nHello <world> & co\nsecond line\n\n- one\n- two https://a.example/x\n\nSee https://example.com/page.');
      expect(html, '<h2>Intro</h2>\n\n'
          '<p>Hello &lt;world&gt; &amp; co<br>\nsecond line</p>\n\n'
          '<ul>\n<li>one</li>\n<li>two <a href="https://a.example/x">https://a.example/x</a></li>\n</ul>\n\n'
          '<p>See <a href="https://example.com/page">https://example.com/page</a>.</p>');
      expect(plainTextToHtml('   '), '');
    });
  });

  // ======================================================================
  group('WordPress', () {
    final wp = WordPressAdapter();
    final index = {
      'name': 'Alice Blog',
      'url': 'https://example.com',
      'home': 'https://example.com',
      'namespaces': ['oembed/1.0', 'wp/v2'],
      'authentication': {
        'application-passwords': {
          'endpoints': {'authorization': 'https://example.com/wp-admin/authorize-application.php'},
        },
      },
    };
    final me = {
      'id': 7,
      'name': 'Alice',
      'slug': 'alice',
      'avatar_urls': {'96': 'https://example.com/avatar96.png'},
      'capabilities': {'edit_posts': true, 'publish_posts': true, 'upload_files': true},
    };
    ConnectedAccount account({Map<String, dynamic> extra = const {}}) => fakeAccount('wordpress', config: {
          'site': 'https://example.com',
          'restBase': 'https://example.com/wp-json/',
          'username': 'alice',
          'canPublish': true,
          'canUpload': true,
          ...extra,
        });
    const secrets = {'app_password': 'abcdefghijklmnopqrstuvwx'};

    test('descriptor matches the research', () {
      final d = wp.descriptor;
      expect(d.id, 'wordpress');
      expect(d.tiers, {PlatformTier.openApi, PlatformTier.handoff});
      expect(d.text.maxLength, isNull);
      expect(d.text.titleSupported, isTrue);
      expect(d.text.titleRequired, isTrue);
      expect(d.text.hashtagsAsField, isTrue);
      expect(d.text.supportsThreads, isFalse);
      expect(d.media.supportsAltText, isTrue);
      expect(d.media.requiresPublicMediaUrl, isFalse);
      expect(d.media.imageMimeTypes, containsAll(['image/jpeg', 'image/png', 'image/gif', 'image/webp']));
      expect(d.serverSideScheduling, isTrue);
      expect(d.defaultQuotas, isEmpty);
      expect(d.setupGuide, 'docs/platforms/wordpress.md');
      final spec = wp.specFor(PlatformTier.openApi);
      expect(spec.loopbackRedirectOk, isFalse);
      expect(spec.customSchemeRedirectOk, isTrue);
      expect(spec.fields.firstWhere((f) => f.key == 'password').secret, isTrue);
      expect(spec.intro, contains('Application Passwords'));
    });

    test('connect: discovers wp-json and verifies with Basic auth', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path == '/wp-json/') return _json(index);
        if (r.url.path == '/wp-json/wp/v2/users/me') return _json(me);
        return _json({'code': 'rest_no_route'}, 404);
      });
      final res = await wp.connect(PlatformTier.openApi,
          {'site': 'example.com', 'username': 'alice', 'password': 'abcd efgh ijkl mnop qrst uvwx'}, ctx);
      expect(calls.map((c) => '${c.method} ${c.url}'), [
        'GET https://example.com/wp-json/',
        'GET https://example.com/wp-json/wp/v2/users/me?context=edit',
      ]);
      expect(calls[0].headers['authorization'], isNull);
      expect(calls[1].headers['authorization'], _basic('alice', 'abcdefghijklmnopqrstuvwx'));
      expect(res.secrets, {'app_password': 'abcdefghijklmnopqrstuvwx'});
      expect(res.account.config['restBase'], 'https://example.com/wp-json/');
      expect(res.account.config['username'], 'alice');
      expect(res.account.config['canUpload'], isTrue);
      expect(res.account.displayName, 'Alice (Alice Blog)');
      expect(res.account.avatarUrl, 'https://example.com/avatar96.png');
    });

    test('connect: falls back to ?rest_route= on plain permalinks', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path == '/wp-json/') return http.Response('not found', 404);
        if (r.url.queryParameters['rest_route'] == '/') return _json(index);
        if (r.url.queryParameters['rest_route'] == '/wp/v2/users/me') return _json(me);
        return http.Response('?', 404);
      });
      final res = await wp.connect(PlatformTier.openApi, {'site': 'https://example.com', 'username': 'alice', 'password': 'x'}, ctx);
      expect(calls.last.url.toString(), 'https://example.com/?rest_route=%2Fwp%2Fv2%2Fusers%2Fme&context=edit');
      expect(res.account.config['restBase'], 'https://example.com/?rest_route=/');
    });

    test('connect: browser approval via authorize-application.php', () async {
      final broker = FakeAuthBroker(
        redirect: Uri.parse('neforum://callback'),
        extraParams: {'site_url': 'https://example.com', 'user_login': 'alice', 'password': 'WXYZ wxyz 1234'},
      );
      final calls = <http.Request>[];
      final ctx = testContext(broker: broker, handler: (r) async {
        calls.add(r);
        if (r.url.path == '/wp-json/') return _json(index);
        return _json(me);
      });
      final res = await wp.connect(PlatformTier.openApi, {'site': 'example.com'}, ctx);
      final auth = broker.lastAuthorizationUrl!;
      expect(auth.path, '/wp-admin/authorize-application.php');
      expect(auth.queryParameters['app_name'], 'NEFORUM');
      expect(auth.queryParameters['app_id'], wordPressAppId);
      expect(auth.queryParameters['success_url'], 'neforum://callback');
      expect(auth.queryParameters['reject_url'], 'neforum://callback?success=false');
      expect(calls.last.headers['authorization'], _basic('alice', 'WXYZwxyz1234'));
      expect(res.secrets['app_password'], 'WXYZwxyz1234');
    });

    test('connect: rejected credentials raise ConnectException', () async {
      final ctx = testContext(handler: (r) async {
        if (r.url.path == '/wp-json/') return _json(index);
        return _json({'code': 'incorrect_password', 'message': 'The provided password is an invalid application password.'}, 401);
      });
      expect(() => wp.connect(PlatformTier.openApi, {'site': 'example.com', 'username': 'alice', 'password': 'bad'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'password')));
    });

    test('validate: title required, role and status checks', () {
      final issues = wp.validate(const PostVariant(text: 'Body'), account());
      expect(issues.map((i) => i.code), contains('title.required'));
      final noUpload = wp.validate(PostVariant(text: 'b', title: 't', media: [fakeImage()]), account(extra: {'canUpload': false}));
      expect(noUpload.where((i) => i.isError).map((i) => i.code), contains('wordpress.cannot_upload'));
      final badStatus = wp.validate(const PostVariant(text: 'b', title: 't', extra: {'status': 'live'}), account());
      expect(badStatus.map((i) => i.code), contains('wordpress.bad_status'));
      final contributor = wp.validate(const PostVariant(text: 'b', title: 't'), account(extra: {'canPublish': false}));
      expect(contributor.map((i) => i.code), contains('wordpress.cannot_publish'));
      expect(wp.validate(PostVariant(text: 'b', title: 't', media: [fakeVideo()]), account()).hasErrors, isFalse);
    });

    test('publish: uploads, alt text, tags, featured image, scheduled post', () async {
      final calls = <http.Request>[];
      var mediaId = 54;
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        final p = r.url.path;
        if (p == '/wp-json/wp/v2/media' && r.method == 'POST') {
          mediaId++;
          return _json({'id': mediaId, 'source_url': 'https://example.com/wp-content/uploads/$mediaId.jpg'}, 201);
        }
        if (p.startsWith('/wp-json/wp/v2/media/')) return _json({'id': int.parse(p.split('/').last)});
        if (p == '/wp-json/wp/v2/tags' && r.method == 'GET') {
          return _json(r.url.queryParameters['search'] == 'news' ? [{'id': 3, 'name': 'News', 'slug': 'news'}] : <Object>[]);
        }
        if (p == '/wp-json/wp/v2/tags') return _json({'id': 9, 'name': 'Dart'}, 201);
        if (p == '/wp-json/wp/v2/posts') {
          return _json({'id': 101, 'link': 'https://example.com/?p=101', 'status': 'future'}, 201);
        }
        return _json({'code': 'rest_no_route'}, 404);
      });
      final at = DateTime.utc(2026, 10, 9, 8, 30);
      final variant = PostVariant(
        title: 'Hello & welcome',
        text: 'First paragraph.\n\nSecond https://neforum.app',
        tags: const ['news', 'Dart'],
        media: [fakeImage(), fakeImage(id: 'img2', altText: null)],
        scheduledAt: at,
        extra: const {'excerpt': 'Short'},
      );
      final res = await wp.publish(variant, account(), secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteId, '101');
      expect(res.remoteUrl, 'https://example.com/?p=101');
      // status future in the response: WordPress holds the post.
      expect(res.isHeldByPlatform, isTrue);
      expect(res.scheduledFor, at);

      expect(calls.map((c) => '${c.method} ${c.url}'), [
        'POST https://example.com/wp-json/wp/v2/media',
        'POST https://example.com/wp-json/wp/v2/media/55',
        'POST https://example.com/wp-json/wp/v2/media',
        'GET https://example.com/wp-json/wp/v2/tags?search=news&per_page=100&_fields=id%2Cname%2Cslug',
        'GET https://example.com/wp-json/wp/v2/tags?search=Dart&per_page=100&_fields=id%2Cname%2Cslug',
        'POST https://example.com/wp-json/wp/v2/tags',
        'POST https://example.com/wp-json/wp/v2/posts',
      ]);
      for (final c in calls) {
        expect(c.headers['authorization'], _basic('alice', 'abcdefghijklmnopqrstuvwx'));
      }
      final upload = calls[0];
      expect(upload.headers['content-type'], 'image/jpeg');
      expect(upload.headers['content-disposition'], 'attachment; filename="img1.jpg"');
      expect(upload.bodyBytes, fakeJpegBytes);
      expect(bodyOf(calls[1]), {'alt_text': 'A test image'});
      expect(bodyOf(calls[5]), {'name': 'Dart'});
      final post = bodyOf(calls[6]);
      expect(post['title'], 'Hello & welcome');
      expect(post['status'], 'future');
      expect(post['date_gmt'], '2026-10-09T08:30:00');
      expect(post.containsKey('date'), isFalse, reason: 'date is in the site time zone; only date_gmt is exact');
      expect(post['tags'], [3, 9]);
      expect(post['featured_media'], 55);
      expect(post['excerpt'], 'Short');
      expect(post['content'], contains('<p>First paragraph.</p>'));
      expect(post['content'], contains('<a href="https://neforum.app">https://neforum.app</a>'));
      expect(post['content'], contains('<img src="https://example.com/wp-content/uploads/56.jpg" alt=""/>'));
      expect(post['content'], isNot(contains('55.jpg')));
    });

    test('publish: existing term reported by term_exists is reused; categories by id and name', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        final p = r.url.path;
        if (r.method == 'GET') return _json(<Object>[]);
        if (p.endsWith('/tags')) {
          return _json({'code': 'term_exists', 'message': 'exists', 'data': {'status': 400, 'term_id': 12}}, 400);
        }
        if (p.endsWith('/categories')) return _json({'id': 4}, 201);
        return _json({'id': 5, 'link': 'https://example.com/hello/'}, 201);
      });
      final res = await wp.publish(
          const PostVariant(title: 'T', text: 'x', tags: ['café'], extra: {'categories': [2, 'Travel'], 'status': 'draft'}),
          account(), secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      final post = bodyOf(calls.last);
      expect(post['tags'], [12]);
      expect(post['categories'], [2, 4]);
      expect(post['status'], 'draft');
      expect(post.containsKey('date_gmt'), isFalse);
    });

    test('publish: schedule sent in local time zone is converted to date_gmt', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'id': 8, 'link': 'https://example.com/?p=8', 'status': 'future', 'date_gmt': '2026-10-09T08:30:00'}, 201);
      });
      final local = DateTime.utc(2026, 10, 9, 8, 30).toLocal();
      final res = await wp.publish(PostVariant(title: 'T', text: 'x', scheduledAt: local), account(), secrets, ctx);
      expect(bodyOf(calls.single)['date_gmt'], '2026-10-09T08:30:00');
      expect(res.scheduledFor, local);
    });

    test('publish: status publish in the response (date already past on the server) -> normal ok result', () async {
      final ctx = testContext(handler: (r) async => _json({'id': 9, 'link': 'https://example.com/live/', 'status': 'publish'}, 201));
      final res = await wp.publish(PostVariant(title: 'T', text: 'x', scheduledAt: DateTime.utc(2026, 10, 7, 11, 59)),
          account(), secrets, ctx);
      expect(res.success, isTrue);
      expect(res.isHeldByPlatform, isFalse);
      expect(res.scheduledFor, isNull);
      expect(res.remoteId, '9');
      expect(res.remoteUrl, 'https://example.com/live/');
      expect(res.publishedAt, testNow);
    });

    test('validate: a schedule only works when WordPress will publish the post', () {
      final at = DateTime.utc(2026, 10, 20, 9);
      List<ValidationIssue> errors(PostVariant v, ConnectedAccount a) =>
          wp.validate(v, a).where((i) => i.isError).toList();
      expect(errors(PostVariant(title: 't', text: 'b', scheduledAt: at), account()), isEmpty);
      for (final (v, a) in [
        (PostVariant(title: 't', text: 'b', scheduledAt: at, extra: const {'status': 'draft'}), account()),
        (PostVariant(title: 't', text: 'b', scheduledAt: at), account(extra: {'defaultStatus': 'draft'})),
        (PostVariant(title: 't', text: 'b', scheduledAt: at), account(extra: {'defaultStatus': 'pending'})),
        (PostVariant(title: 't', text: 'b', scheduledAt: at, visibility: Visibility.private), account()),
        (PostVariant(title: 't', text: 'b', scheduledAt: at), account(extra: {'canPublish': false})),
      ]) {
        final e = errors(v, a);
        expect(e.map((i) => i.code), ['wordpress.cannot_schedule']);
        expect(e.single.field, 'scheduledAt');
      }
      // Without a schedule a draft is fine.
      expect(errors(const PostVariant(title: 't', text: 'b', extra: {'status': 'draft'}), account()), isEmpty);
    });

    group('cancelScheduled', () {
      final held = PublishResult.scheduled(remoteId: '101', scheduledFor: DateTime.utc(2026, 10, 20, 9));

      test('DELETE /wp/v2/posts/{id}?force=true with Basic auth', () async {
        final calls = <http.Request>[];
        await wp.cancelScheduled(held, account(), secrets, testContext(handler: (r) async {
          calls.add(r);
          return _json({'deleted': true, 'previous': {'id': 101, 'status': 'future'}});
        }));
        expect('${calls.single.method} ${calls.single.url}', 'DELETE https://example.com/wp-json/wp/v2/posts/101?force=true');
        expect(calls.single.headers['authorization'], _basic('alice', 'abcdefghijklmnopqrstuvwx'));
      });

      test('uses ?rest_route= on plain permalinks', () async {
        final calls = <http.Request>[];
        await wp.cancelScheduled(held, account(extra: {'restBase': 'https://example.com/?rest_route=/'}), secrets,
            testContext(handler: (r) async {
          calls.add(r);
          return _json({'deleted': true});
        }));
        expect(calls.single.method, 'DELETE');
        expect(calls.single.url.path, '/');
        expect(calls.single.url.queryParameters, {'rest_route': '/wp/v2/posts/101', 'force': 'true'});
      });

      test('404 rest_post_invalid_id = already gone', () async {
        await wp.cancelScheduled(held, account(), secrets,
            testContext(handler: (r) async => _json({'code': 'rest_post_invalid_id', 'message': 'Invalid post ID.', 'data': {'status': 404}}, 404)));
      });

      Future<PublishError> cancelError(http.Response response) async {
        try {
          await wp.cancelScheduled(held, account(), secrets, testContext(handler: (r) async => response));
        } on AdapterException catch (e) {
          return e.error;
        }
        fail('expected AdapterException');
      }

      test('404 without the post route is not "gone"', () async {
        expect((await cancelError(_json({'code': 'rest_no_route', 'message': 'No route'}, 404))).kind,
            PublishErrorKind.configuration);
        expect((await cancelError(http.Response('<html>Not found</html>', 404, headers: {'content-type': 'text/html'}))).kind,
            PublishErrorKind.platform);
      });

      test('errors map to the right kind', () async {
        expect((await cancelError(_json({'code': 'incorrect_password', 'message': 'bad'}, 401))).kind, PublishErrorKind.auth);
        expect((await cancelError(_json({'code': 'rest_cannot_delete', 'message': 'Sorry'}, 403))).kind, PublishErrorKind.auth);
        final q = await cancelError(_json({'code': 'too_many'}, 429, {'retry-after': '30'}));
        expect(q.kind, PublishErrorKind.quota);
        expect(q.retryAfter, const Duration(seconds: 30));
        expect((await cancelError(_json({'code': 'internal'}, 503))).kind, PublishErrorKind.network);
      });

      test('missing id or password -> AdapterException without a request', () async {
        final ctx = testContext(handler: (r) async => fail500());
        await expectLater(wp.cancelScheduled(PublishResult.ok(), account(), secrets, ctx), throwsA(isA<AdapterException>()));
        await expectLater(wp.cancelScheduled(held, account(), const {}, ctx),
            throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)));
      });
    });

    test('connect: follows the home address the REST index reports (apex -> www)', () async {
      final calls = <http.Request>[];
      final wwwIndex = {...index, 'url': 'https://www.example.com', 'home': 'http://www.example.com/'};
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path == '/wp-json/') return _json(wwwIndex);
        if (r.url.path == '/wp-json/wp/v2/users/me') return _json(me);
        return _json({'code': 'rest_no_route'}, 404);
      });
      final res = await wp.connect(PlatformTier.openApi, {'site': 'example.com', 'username': 'alice', 'password': 'x'}, ctx);
      expect(calls.map((c) => '${c.method} ${c.url}'), [
        'GET https://example.com/wp-json/',
        'GET https://www.example.com/wp-json/',
        'GET https://www.example.com/wp-json/wp/v2/users/me?context=edit',
      ]);
      expect(res.account.config['restBase'], 'https://www.example.com/wp-json/');
      expect(res.account.config['site'], 'https://www.example.com');
    });

    test('connect: keeps the typed address when the home address does not answer', () async {
      final ctx = testContext(handler: (r) async {
        if (r.url.host == 'other.example.net') return http.Response('down', 503);
        if (r.url.path == '/wp-json/') return _json({...index, 'home': 'https://other.example.net'});
        return _json(me);
      });
      final res = await wp.connect(PlatformTier.openApi, {'site': 'example.com', 'username': 'alice', 'password': 'x'}, ctx);
      expect(res.account.config['restBase'], 'https://example.com/wp-json/');
    });

    test('publish: unreadable media -> failure result, not an exception', () async {
      final ctx = AdapterContext(
        http: NeforumHttp(client: MockClient((r) async => fail500()), maxRetries: 0),
        clock: () => testNow,
        readMedia: (m) async => throw Exception('file was moved'),
      );
      final res = await wp.publish(PostVariant(title: 'T', text: 'x', media: [fakeImage()]), account(), secrets, ctx);
      expect(res.isFailure, isTrue);
      expect(res.error!.kind, PublishErrorKind.configuration);
      expect(res.error!.message, contains('file was moved'));
    });

    test('publish: contributors are downgraded to pending', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'id': 5, 'link': 'https://example.com/?p=5'}, 201);
      });
      await wp.publish(const PostVariant(title: 'T', text: 'x'), account(extra: {'canPublish': false}), secrets, ctx);
      expect(bodyOf(calls.single)['status'], 'pending');
    });

    group('error mapping', () {
      Future<PublishResult> fail(int status, Object body, [Map<String, String> headers = const {}]) => wp.publish(
          const PostVariant(title: 'T', text: 'x'),
          account(),
          secrets,
          testContext(handler: (r) async => _json(body, status, headers)));

      test('401 -> auth', () async {
        final r = await fail(401, {'code': 'incorrect_password', 'message': 'bad'});
        expect(r.error!.kind, PublishErrorKind.auth);
      });
      test('429 -> quota with retryAfter', () async {
        final r = await fail(429, {'code': 'too_many'}, {'retry-after': '120'});
        expect(r.error!.kind, PublishErrorKind.quota);
        expect(r.error!.retryAfter, const Duration(seconds: 120));
      });
      test('400 rest_invalid_param -> validation', () async {
        final r = await fail(400, {'code': 'rest_invalid_param', 'message': 'Invalid parameter(s): status'});
        expect(r.error!.kind, PublishErrorKind.validation);
        expect(r.error!.message, contains('Invalid parameter'));
      });
      test('403 rest_cannot_publish -> validation', () async {
        final r = await fail(403, {'code': 'rest_cannot_publish', 'message': 'Sorry'});
        expect(r.error!.kind, PublishErrorKind.validation);
      });
      test('403 rest_cannot_create -> auth', () async {
        final r = await fail(403, {'code': 'rest_cannot_create', 'message': 'Sorry'});
        expect(r.error!.kind, PublishErrorKind.auth);
      });
      test('500 -> network', () async {
        final r = await fail(500, {'code': 'internal'});
        expect(r.error!.kind, PublishErrorKind.network);
      });
      test('missing password -> auth without a request', () async {
        final r = await wp.publish(const PostVariant(title: 'T', text: 'x'), account(), const {},
            testContext(handler: (r) async => fail500()));
        expect(r.error!.kind, PublishErrorKind.auth);
      });
    });

    test('handoff: self-hosted post-new.php is prefilled', () {
      final plan = wp.buildHandoff(const PostVariant(title: 'My title', text: 'Body text', tags: ['a']),
          account: fakeAccount('wordpress', tier: PlatformTier.handoff, config: {'site': 'https://example.com/blog'}))!;
      expect(plan.webIntent!.toString(),
          'https://example.com/blog/wp-admin/post-new.php?post_title=My+title&content=Body+text');
      expect(plan.preferred, HandoffMethod.webIntent);
      expect(plan.clipboardText, 'My title\n\nBody text');
      expect(plan.androidPackage, 'org.wordpress.android');
      expect(plan.instructions, startsWith('1. '));
    });

    test('handoff: WordPress.com Press This when no site is set', () {
      final plan = wp.buildHandoff(
          PostVariant(title: 'T', text: 'Hi', link: 'https://neforum.app', media: [fakeImage()]))!;
      final u = plan.webIntent!;
      expect(u.host, 'wordpress.com');
      expect(u.path, '/post/');
      expect(u.queryParameters, {'url': 'https://neforum.app', 'title': 'T', 'text': 'Hi', 'v': '5'});
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.shareFiles, hasLength(1));
      expect(plan.mediaNote, isNotNull);
    });
  });

  // ======================================================================
  group('Ghost', () {
    final ghost = GhostAdapter();
    ConnectedAccount account({Map<String, dynamic> extra = const {}}) => fakeAccount('ghost', config: {
          'apiUrl': 'https://blog.example.com',
          'site': 'https://blog.example.com/',
          ...extra,
        });
    const secrets = {'admin_api_key': _ghostKey};

    test('descriptor matches the research', () {
      final d = ghost.descriptor;
      expect(d.id, 'ghost');
      expect(d.text.titleRequired, isTrue);
      expect(d.text.titleMax, 255);
      expect(d.text.hashtagsAsField, isTrue);
      expect(d.media.maxVideos, 0);
      expect(d.media.imageMimeTypes, {'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/svg+xml'});
      expect(d.serverSideScheduling, isTrue);
      // ghost.org/pricing: Custom integrations / Admin API on Publisher, Business and Custom; not on Starter.
      expect(d.apiCostSummary, contains('Publisher'));
      expect(d.accountRequirements, contains('not in Starter'));
      expect(ghost.specFor(PlatformTier.openApi).intro, contains('Publisher plan and above'));
      final key = ghost.specFor(PlatformTier.openApi).fields.firstWhere((f) => f.key == 'adminKey');
      expect(key.secret, isTrue);
    });

    test('JWT: HS256, kid, iat/exp 5 minutes, aud /admin/, hex-decoded secret', () {
      final token = GhostAdminKey.parse(_ghostKey).token(testNow);
      final parts = token.split('.');
      expect(parts, hasLength(3));
      expect(_jwtPart(token, 0), {'alg': 'HS256', 'kid': _ghostKeyId, 'typ': 'JWT'});
      final iat = testNow.millisecondsSinceEpoch ~/ 1000;
      expect(_jwtPart(token, 1), {'iat': iat, 'exp': iat + 300, 'aud': '/admin/'});
      final expected = base64Url
          .encode(Hmac(sha256, hex.decode(_ghostSecret)).convert(ascii.encode('${parts[0]}.${parts[1]}')).bytes)
          .replaceAll('=', '');
      expect(parts[2], expected);
      expect(token, isNot(contains('=')));
    });

    test('key parsing rejects junk', () {
      expect(() => GhostAdminKey.parse('nocolon'), throwsFormatException);
      expect(() => GhostAdminKey.parse('abc:xyz'), throwsFormatException);
      expect(() => GhostAdminKey.parse('abc:abc'), throwsFormatException);
    });

    test('connect: site info then authenticated key check', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path == '/ghost/api/admin/site/') {
          return _json({'site': {'title': 'My Ghost', 'url': 'https://www.example.com/', 'version': '6.3'}});
        }
        if (r.url.path == '/ghost/api/admin/posts/') return _json({'posts': <Object>[]});
        return _json({'errors': <Object>[]}, 404);
      });
      final res = await ghost.connect(PlatformTier.openApi,
          {'apiUrl': 'https://blog.example.com/ghost/', 'adminKey': ' $_ghostKey ', 'defaultStatus': 'draft'}, ctx);
      expect(calls.map((c) => '${c.method} ${c.url}'), [
        'GET https://blog.example.com/ghost/api/admin/site/',
        'GET https://blog.example.com/ghost/api/admin/posts/?limit=1',
      ]);
      expect(calls[0].headers['accept-version'], 'v5.0');
      expect(calls[0].headers['authorization'], isNull);
      expect(calls[1].headers['authorization'], startsWith('Ghost '));
      expect(_jwtPart(calls[1].headers['authorization']!.substring(6), 0)['kid'], _ghostKeyId);
      expect(res.secrets, {'admin_api_key': _ghostKey});
      expect(res.account.config['apiUrl'], 'https://blog.example.com');
      expect(res.account.config['defaultStatus'], 'draft');
      expect(res.account.displayName, 'My Ghost');
      expect(res.account.handle, 'www.example.com');
    });

    test('connect: wrong key -> ConnectException on adminKey', () async {
      final ctx = testContext(handler: (r) async {
        if (r.url.path == '/ghost/api/admin/site/') return _json({'site': {'title': 'x'}});
        return _json({'errors': [{'message': 'Invalid token', 'type': 'UnauthorizedError'}]}, 401);
      });
      expect(() => ghost.connect(PlatformTier.openApi, {'apiUrl': 'blog.example.com', 'adminKey': _ghostKey}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'adminKey')));
      expect(() => ghost.connect(PlatformTier.openApi, {'apiUrl': 'blog.example.com', 'adminKey': 'content-key'}, ctx),
          throwsA(isA<ConnectException>()));
    });

    test('validate: videos and bad status', () {
      final v = ghost.validate(PostVariant(text: 'x', title: 't', media: [fakeVideo()]), account());
      expect(v.where((i) => i.isError).map((i) => i.code), contains('media.too_many_videos'));
      final s = ghost.validate(const PostVariant(text: 'x', title: 't', extra: {'status': 'live'}), account());
      expect(s.map((i) => i.code), contains('ghost.bad_status'));
      expect(ghost.validate(const PostVariant(text: 'x'), account()).map((i) => i.code), contains('title.required'));
    });

    test('publish: image upload then post with feature image and tags', () async {
      final calls = <http.Request>[];
      var n = 0;
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path == '/ghost/api/admin/images/upload/') {
          n++;
          return _json({'images': [{'url': 'https://blog.example.com/content/images/$n.jpg', 'ref': 'x'}]}, 201);
        }
        return _json({'posts': [{'id': 'p1', 'url': 'https://blog.example.com/hello/', 'status': 'published'}]}, 201);
      });
      final res = await ghost.publish(
          PostVariant(
            title: 'Hello',
            text: 'Body\n\nMore',
            tags: const ['News', 'Getting Started'],
            media: [fakeImage(), fakeImage(id: 'img2', altText: 'Second')],
            extra: const {'excerpt': 'Teaser', 'canonicalUrl': 'https://example.org/orig'},
          ),
          account(),
          secrets,
          ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteId, 'p1');
      expect(res.remoteUrl, 'https://blog.example.com/hello/');
      expect(calls.map((c) => '${c.method} ${c.url}'), [
        'POST https://blog.example.com/ghost/api/admin/images/upload/',
        'POST https://blog.example.com/ghost/api/admin/images/upload/',
        'POST https://blog.example.com/ghost/api/admin/posts/?source=html',
      ]);
      for (final c in calls) {
        expect(c.headers['authorization'], startsWith('Ghost '));
        expect(c.headers['accept-version'], 'v5.0');
      }
      expect(multipartFieldsOf(calls[0]), {'purpose': 'image', 'ref': 'img1.jpg', 'file': '<img1.jpg>'});
      final post = (bodyOf(calls[2])['posts'] as List).single as Map;
      expect(post['title'], 'Hello');
      expect(post['status'], 'published');
      expect(post['visibility'], 'public');
      expect(post['html'], startsWith('<p>Body</p>\n\n<p>More</p>'));
      expect(post['html'], contains('<img src="https://blog.example.com/content/images/2.jpg" alt="Second"/>'));
      expect(post['feature_image'], 'https://blog.example.com/content/images/1.jpg');
      expect(post['feature_image_alt'], 'A test image');
      expect(post['tags'], [
        {'name': 'News'},
        {'name': 'Getting Started'},
      ]);
      expect(post['custom_excerpt'], 'Teaser');
      expect(post['canonical_url'], 'https://example.org/orig');
      expect(post.containsKey('published_at'), isFalse);
    });

    test('publish: delegated schedule -> status scheduled + published_at', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'posts': [{'id': 'p2', 'url': 'https://blog.example.com/p/x/', 'status': 'scheduled'}]}, 201);
      });
      final at = DateTime.utc(2026, 10, 20, 9);
      final res = await ghost.publish(
          PostVariant(title: 'Later', text: 'x', scheduledAt: at, visibility: Visibility.followers),
          account(), secrets, ctx);
      expect(res.success, isTrue);
      expect(res.isHeldByPlatform, isTrue);
      expect(res.scheduledFor, at);
      expect(res.remoteId, 'p2');
      expect(res.remoteUrl, 'https://blog.example.com/p/x/');
      expect('${calls.single.method} ${calls.single.url}', 'POST https://blog.example.com/ghost/api/admin/posts/?source=html');
      final post = (bodyOf(calls.single)['posts'] as List).single as Map;
      expect(post['status'], 'scheduled');
      expect(post['published_at'], '2026-10-20T09:00:00.000Z');
      expect(post['visibility'], 'members');
    });

    test('publish: Ghost answering published -> normal ok result', () async {
      final ctx = testContext(
          handler: (r) async => _json({'posts': [{'id': 'p4', 'url': 'https://blog.example.com/now/', 'status': 'published'}]}, 201));
      final res = await ghost.publish(PostVariant(title: 'Now', text: 'x', scheduledAt: DateTime.utc(2026, 10, 20, 9)),
          account(), secrets, ctx);
      expect(res.success, isTrue);
      expect(res.isHeldByPlatform, isFalse);
      expect(res.publishedAt, testNow);
    });

    test('validate: drafts cannot be held by Ghost', () {
      final at = DateTime.utc(2026, 10, 20, 9);
      Iterable<ValidationIssue> errors(PostVariant v, ConnectedAccount a) => ghost.validate(v, a).where((i) => i.isError);
      expect(errors(PostVariant(title: 't', text: 'x', scheduledAt: at), account()), isEmpty);
      for (final (v, a) in [
        (PostVariant(title: 't', text: 'x', scheduledAt: at), account(extra: {'defaultStatus': 'draft'})),
        (PostVariant(title: 't', text: 'x', scheduledAt: at, extra: const {'status': 'draft'}), account()),
      ]) {
        final e = errors(v, a).toList();
        expect(e.map((i) => i.code), ['ghost.cannot_schedule']);
        expect(e.single.field, 'scheduledAt');
      }
    });

    group('cancelScheduled', () {
      final held = PublishResult.scheduled(remoteId: '6489d8a1b2c3d4e5f6a7b8d0', scheduledFor: DateTime.utc(2026, 10, 20, 9));

      test('DELETE /ghost/api/admin/posts/{id}/ with a fresh token (204)', () async {
        final calls = <http.Request>[];
        await ghost.cancelScheduled(held, account(), secrets, testContext(handler: (r) async {
          calls.add(r);
          return http.Response('', 204);
        }));
        final c = calls.single;
        expect('${c.method} ${c.url}', 'DELETE https://blog.example.com/ghost/api/admin/posts/6489d8a1b2c3d4e5f6a7b8d0/');
        expect(c.headers['authorization'], startsWith('Ghost '));
        expect(_jwtPart(c.headers['authorization']!.substring(6), 1)['aud'], '/admin/');
        expect(c.headers['accept-version'], 'v5.0');
      });

      test('404 NotFoundError = already gone', () async {
        await ghost.cancelScheduled(held, account(), secrets, testContext(handler: (r) async => _json({
              'errors': [{'message': 'Resource not found error, cannot delete post.', 'type': 'NotFoundError'}],
            }, 404)));
      });

      Future<PublishError> cancelError(http.Response response) async {
        try {
          await ghost.cancelScheduled(held, account(), secrets, testContext(handler: (r) async => response));
        } on AdapterException catch (e) {
          return e.error;
        }
        fail('expected AdapterException');
      }

      test('errors map to the right kind; an HTML 404 is not "gone"', () async {
        expect((await cancelError(http.Response('<html>404</html>', 404, headers: {'content-type': 'text/html; charset=utf-8'}))).kind,
            PublishErrorKind.configuration);
        expect((await cancelError(_json({'errors': [{'message': 'Invalid token', 'type': 'UnauthorizedError'}]}, 401))).kind,
            PublishErrorKind.auth);
        expect((await cancelError(_json({'errors': [{'message': 'No permission', 'type': 'NoPermissionError'}]}, 403))).kind,
            PublishErrorKind.auth);
        final q = await cancelError(_json({'errors': [{'type': 'TooManyRequestsError'}]}, 429, {'retry-after': '10'}));
        expect(q.kind, PublishErrorKind.quota);
        expect(q.retryAfter, const Duration(seconds: 10));
        expect((await cancelError(_json({'errors': [{'type': 'InternalServerError'}]}, 500))).kind, PublishErrorKind.network);
      });

      test('missing id or key -> AdapterException without a request', () async {
        final ctx = testContext(handler: (r) async => fail500());
        await expectLater(ghost.cancelScheduled(PublishResult.ok(), account(), secrets, ctx), throwsA(isA<AdapterException>()));
        await expectLater(ghost.cancelScheduled(held, account(), const {}, ctx),
            throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)));
      });
    });

    test('publish: raw HTML can be wrapped in an HTML card', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'posts': [{'id': 'p3', 'url': 'https://blog.example.com/p3/'}]}, 201);
      });
      await ghost.publish(const PostVariant(title: 'H', text: '<div class="x">hi</div>', extra: {'html': true, 'ghostHtmlCard': true}),
          account(), secrets, ctx);
      final post = (bodyOf(calls.single)['posts'] as List).single as Map;
      expect(post['html'], '<!--kg-card-begin: html-->\n<div class="x">hi</div>\n<!--kg-card-end: html-->');
    });

    group('error mapping', () {
      Future<PublishResult> fail(int status, Object body, [Map<String, String> headers = const {}]) => ghost.publish(
          const PostVariant(title: 'T', text: 'x'), account(), secrets, testContext(handler: (r) async => _json(body, status, headers)));

      test('401 -> auth', () async {
        final r = await fail(401, {'errors': [{'message': 'Invalid token', 'type': 'UnauthorizedError'}]});
        expect(r.error!.kind, PublishErrorKind.auth);
        expect(r.error!.message, contains('clock'));
      });
      test('429 -> quota with retryAfter', () async {
        final r = await fail(429, {'errors': [{'message': 'Too many', 'type': 'TooManyRequestsError'}]}, {'retry-after': '60'});
        expect(r.error!.kind, PublishErrorKind.quota);
        expect(r.error!.retryAfter, const Duration(seconds: 60));
      });
      test('422 ValidationError -> validation', () async {
        final r = await fail(422, {'errors': [{'message': 'Validation error', 'context': 'Title too long', 'type': 'ValidationError'}]});
        expect(r.error!.kind, PublishErrorKind.validation);
        expect(r.error!.message, contains('Title too long'));
      });
      test('404 -> configuration', () async {
        final r = await fail(404, {'errors': [{'message': 'Resource not found', 'type': 'NotFoundError'}]});
        expect(r.error!.kind, PublishErrorKind.configuration);
      });
      test('broken stored key -> auth', () async {
        final r = await ghost.publish(const PostVariant(title: 'T', text: 'x'), account(), const {'admin_api_key': 'x'},
            testContext(handler: (r) async => fail500()));
        expect(r.error!.kind, PublishErrorKind.auth);
      });
    });

    test('handoff: manual plan opens the editor', () {
      final plan = ghost.buildHandoff(const PostVariant(title: 'T', text: 'Body'), account: account())!;
      expect(plan.preferred, HandoffMethod.manual);
      expect(plan.webIntent, isNull);
      expect(plan.desktopUrl, 'https://blog.example.com/ghost/#/editor/post');
      expect(plan.clipboardText, 'Body');
      expect(plan.instructions, contains('"T"'));
    });
  });

  // ======================================================================
  group('WriteFreely', () {
    final wf = WriteFreelyAdapter();
    ConnectedAccount account({Map<String, dynamic> extra = const {}}) => fakeAccount('writefreely', config: {
          'instance': 'https://write.as',
          'anonymous': false,
          'username': 'alice',
          'alias': 'alice',
          'collectionUrl': 'https://write.as/alice/',
          ...extra,
        });
    const secrets = {'access_token': '00000000-1111-2222-3333-444444444444', 'token_type': 'Token'};

    test('descriptor matches the research', () {
      final d = wf.descriptor;
      expect(d.id, 'writefreely');
      expect(d.text.titleSupported, isTrue);
      expect(d.text.titleRequired, isFalse);
      expect(d.text.supportsMarkdown, isTrue);
      expect(d.text.hashtagsAsField, isFalse);
      expect(d.media.requiresPublicMediaUrl, isTrue);
      expect(d.media.maxVideos, 0);
      expect(d.serverSideScheduling, isFalse);
      final spec = wf.specFor(PlatformTier.openApi);
      expect(spec.fields.firstWhere((f) => f.key == 'instance').defaultValue, 'https://write.as');
      expect(spec.fields.firstWhere((f) => f.key == 'password').secret, isTrue);
    });

    test('connect: login then collections; token stored, password not', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path == '/api/auth/login') {
          return _json({'code': 200, 'data': {'access_token': 'tok-1', 'user': {'username': 'alice'}}});
        }
        return _json({'code': 200, 'data': [
          {'alias': 'alice', 'title': 'Alice', 'url': 'https://write.as/alice/'},
          {'alias': 'poems', 'title': 'Poems', 'url': 'https://write.as/poems/'},
        ]});
      });
      final res = await wf.connect(PlatformTier.openApi,
          {'instance': '', 'username': 'alice', 'password': 'pw', 'blog': 'Poems', 'snapAs': 'true'}, ctx);
      expect(calls.map((c) => '${c.method} ${c.url}'), [
        'POST https://write.as/api/auth/login',
        'GET https://write.as/api/me/collections',
      ]);
      expect(bodyOf(calls[0]), {'alias': 'alice', 'pass': 'pw'});
      expect(calls[1].headers['authorization'], 'Token tok-1');
      expect(res.secrets, {'access_token': 'tok-1', 'token_type': 'Token'});
      expect(res.secrets.values, isNot(contains('pw')));
      expect(res.account.config['alias'], 'poems');
      expect(res.account.config['collectionUrl'], 'https://write.as/poems/');
      expect(res.account.config['snapAs'], isTrue);
    });

    test('connect: wrong password and unknown blog', () async {
      final bad = testContext(handler: (r) async => _json({'code': 401, 'error_msg': 'Incorrect password.'}, 401));
      expect(() => wf.connect(PlatformTier.openApi, {'username': 'alice', 'password': 'x'}, bad),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('Incorrect password'))));
      final none = testContext(handler: (r) async => r.url.path == '/api/auth/login'
          ? _json({'data': {'access_token': 't'}})
          : _json({'data': [{'alias': 'alice', 'url': 'https://write.as/alice/'}]}));
      expect(() => wf.connect(PlatformTier.openApi, {'username': 'alice', 'password': 'x', 'blog': 'nope'}, none),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'blog')));
    });

    test('connect: 404 "User doesn\'t exist." points at the username, a bare 404 at the server', () async {
      final noUser = testContext(handler: (r) async => _json({'code': 404, 'error_msg': "User doesn't exist."}, 404));
      await expectLater(wf.connect(PlatformTier.openApi, {'username': 'alcie', 'password': 'x'}, noUser),
          throwsA(isA<ConnectException>()
              .having((e) => e.field, 'field', 'username')
              .having((e) => e.message, 'message', contains('alcie'))));
      final noApi = testContext(handler: (r) async => http.Response('<html>Not found</html>', 404, headers: {'content-type': 'text/html'}));
      await expectLater(wf.connect(PlatformTier.openApi, {'instance': 'blog.example.org', 'username': 'a', 'password': 'x'}, noApi),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'instance')));
    });

    test('connect: anonymous needs no request', () async {
      final ctx = testContext(handler: (r) async => throw StateError('no request expected'));
      final res = await wf.connect(PlatformTier.openApi, {'instance': 'write.as'}, ctx);
      expect(res.account.config['anonymous'], isTrue);
      expect(res.secrets, isEmpty);
    });

    test('publish: collection post with Markdown, lang and rtl', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'code': 201, 'data': {
          'id': 'rf3t35fkax0aw',
          'slug': 'my-title',
          'collection': {'alias': 'alice', 'url': 'https://write.as/alice/'},
        }}, 201);
      });
      final res = await wf.publish(const PostVariant(title: 'My title', text: 'مرحبا *world* #tag', language: 'ar-EG'),
          account(), secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteId, 'rf3t35fkax0aw');
      expect(res.remoteUrl, 'https://write.as/alice/my-title');
      final c = calls.single;
      expect('${c.method} ${c.url}', 'POST https://write.as/api/collections/alice/posts');
      expect(c.headers['authorization'], 'Token 00000000-1111-2222-3333-444444444444');
      expect(bodyOf(c), {'body': 'مرحبا *world* #tag', 'title': 'My title', 'lang': 'ar', 'rtl': true});
    });

    test('publish: anonymous post goes to /api/posts without auth', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'code': 201, 'data': {'id': 'abc123', 'slug': null, 'token': 'edit-token'}}, 201);
      });
      final res = await wf.publish(const PostVariant(text: 'Hello'),
          fakeAccount('writefreely', config: {'instance': 'https://write.as', 'anonymous': true}), const {}, ctx);
      expect(res.remoteUrl, 'https://write.as/abc123');
      expect('${calls.single.method} ${calls.single.url}', 'POST https://write.as/api/posts');
      expect(calls.single.headers['authorization'], isNull);
      expect(bodyOf(calls.single), {'body': 'Hello', 'rtl': false});
    });

    test('publish: images go through the media host and are embedded', () async {
      final calls = <http.Request>[];
      final host = FakeMediaHost();
      final ctx = testContext(mediaHost: host, handler: (r) async {
        calls.add(r);
        return _json({'data': {'id': 'x1', 'slug': 's'}}, 201);
      });
      final res = await wf.publish(PostVariant(text: 'Look', media: [fakeImage(altText: 'A [cat]')]), account(), secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(host.uploaded.single.id, 'img1');
      expect(bodyOf(calls.single)['body'], 'Look\n\n![A cat](https://cdn.example.test/img1)');
      expect(res.remoteUrl, 'https://write.as/alice/s');
    });

    test('publish: images without a host -> configuration; Snap.as when enabled', () async {
      final none = await wf.publish(PostVariant(text: 'x', media: [fakeImage()]), account(), secrets,
          testContext(handler: (r) async => fail500()));
      expect(none.error!.kind, PublishErrorKind.configuration);

      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.host == 'snap.as') {
          return _json({'code': 201, 'data': {'id': 'aB', 'url': 'https://i.snap.as/aB.jpeg'}}, 201);
        }
        return _json({'data': {'id': 'x2', 'slug': 'y'}}, 201);
      });
      final res = await wf.publish(PostVariant(text: 'x', media: [fakeImage()]), account(extra: {'snapAs': true}), secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect('${calls[0].method} ${calls[0].url}', 'POST https://snap.as/api/photos/upload');
      expect(calls[0].headers['authorization'], '00000000-1111-2222-3333-444444444444');
      expect(multipartFieldsOf(calls[0]), {'file': '<img1.jpg>'});
      expect(bodyOf(calls[1])['body'], 'x\n\n![A test image](https://i.snap.as/aB.jpeg)');
    });

    test('validate: media host warning and visibility', () {
      final v = wf.validate(PostVariant(text: 'x', media: [fakeImage()], visibility: Visibility.followers), account());
      expect(v.map((i) => i.code), containsAll(['writefreely.media_host', 'writefreely.visibility']));
      expect(wf.validate(PostVariant(text: 'x', media: [fakeImage()]), account(extra: {'snapAs': true})).map((i) => i.code),
          isNot(contains('writefreely.media_host')));
      expect(wf.validate(PostVariant(text: 'x', media: [fakeVideo()]), account()).hasErrors, isTrue);
    });

    group('error mapping', () {
      Future<PublishResult> fail(int status, Object body, [Map<String, String> headers = const {}]) => wf.publish(
          const PostVariant(text: 'x'), account(), secrets, testContext(handler: (r) async => _json(body, status, headers)));

      test('401 -> auth', () async {
        expect((await fail(401, {'code': 401, 'error_msg': 'Invalid token.'})).error!.kind, PublishErrorKind.auth);
      });
      test('429 -> quota with retryAfter', () async {
        final r = await fail(429, {'code': 429, 'error_msg': 'Slow down.'}, {'retry-after': '3600'});
        expect(r.error!.kind, PublishErrorKind.quota);
        expect(r.error!.retryAfter, const Duration(hours: 1));
      });
      test('400 -> validation', () async {
        final r = await fail(400, {'code': 400, 'error_msg': 'Post body is required.'});
        expect(r.error!.kind, PublishErrorKind.validation);
        expect(r.error!.message, contains('Post body is required.'));
      });
      test('403 -> auth', () async {
        final r = await fail(403, {'code': 403, 'error_msg': "You don't have permission to add to this collection."});
        expect(r.error!.kind, PublishErrorKind.auth);
        expect(r.error!.message, contains('permission'));
      });
      test('5xx -> network', () async {
        expect((await fail(502, {'code': 502, 'error_msg': 'Bad gateway'})).error!.kind, PublishErrorKind.network);
      });
    });

    test('disconnect revokes the token', () async {
      final calls = <http.Request>[];
      await wf.disconnect(account(), secrets, testContext(handler: (r) async {
        calls.add(r);
        return http.Response('', 204);
      }));
      expect('${calls.single.method} ${calls.single.url}', 'DELETE https://write.as/api/auth/me');
      expect(calls.single.headers['authorization'], 'Token 00000000-1111-2222-3333-444444444444');
    });

    test('handoff: manual with title as heading on the clipboard', () {
      final plan = wf.buildHandoff(const PostVariant(title: 'T', text: 'Body'),
          account: fakeAccount('writefreely', tier: PlatformTier.handoff, config: {'instance': 'https://blog.example.org'}))!;
      expect(plan.preferred, HandoffMethod.manual);
      expect(plan.clipboardText, '# T\n\nBody');
      expect(plan.desktopUrl, 'https://blog.example.org');
    });
  });
}

http.Response fail500() => throw StateError('no request expected');
