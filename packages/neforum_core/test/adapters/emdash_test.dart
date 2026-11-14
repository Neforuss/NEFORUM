// NEFORUM 1.4.3: the EmDash adapter against a fake EmDash 1.5. Request and
// answer shapes are read from EmDash's source and checked against a real dev
// site by emdash_live_test.dart.

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/blogs_a/emdash_adapter.dart';
import 'package:neforum_core/src/adapters/blogs_a/emdash_api.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

const _token = 'ec_pat_0123456789abcdefghijklmnopqrstuvwxyz';
const _secrets = {'access_token': _token, 'token_type': 'personal-access-token'};

http.Response _ok(Object data, [int status = 200]) => http.Response(jsonEncode({'success': true, 'data': data}), status, headers: jsonHeaders);
http.Response _err(String code, String message, int status) =>
    http.Response(jsonEncode({'success': false, 'error': {'code': code, 'message': message}}), status, headers: jsonHeaders);

/// A fake EmDash site: answers by method and path, records every request.
class _Site {
  _Site();

  final List<http.Request> calls = [];
  final Map<String, Map<String, dynamic>> postsBySlug = {};
  List<Map<String, dynamic>> terms = [
    {'id': 't1', 'name': 'tag', 'slug': 'webdev', 'label': 'Web Development', 'children': <Object>[]},
  ];
  bool tagTaxonomy = true;
  int mediaCount = 0;
  int created = 0;
  int published = 0;
  http.Response? Function(http.Request r)? override;

  List<String> get trail => [for (final c in calls) '${c.method} ${c.url.path}${c.url.hasQuery ? '?${c.url.query}' : ''}'];

  Future<http.Response> handle(http.Request r) async {
    calls.add(r);
    final o = override?.call(r);
    if (o != null) return o;
    final path = r.url.path;
    if (path == '/_emdash/api/health') return _ok({'product': 'emdash', 'version': '1.5.0', 'registry': false});
    if (path == '/' ) {
      return http.Response('<html><head><meta property="og:site_name" content="Robin &amp; Co"><title>Ignored</title></head></html>', 200,
          headers: {'content-type': 'text/html'});
    }
    if (r.headers['authorization'] != 'Bearer $_token') return _err('INVALID_TOKEN', 'Invalid or expired token', 401);
    if (r.method == 'GET' && path == '/_emdash/api/content/posts') return _ok({'items': <Object>[], 'nextCursor': null});
    if (r.method == 'POST' && path == '/_emdash/api/media') {
      mediaCount++;
      return _ok({
        'item': {'id': 'm$mediaCount', 'url': '/_emdash/api/media/file/m$mediaCount.jpg', 'filename': 'img$mediaCount.jpg', 'mimeType': 'image/jpeg', 'width': 1200, 'height': 800},
      }, 201);
    }
    if (path == '/_emdash/api/taxonomies/tag/terms') {
      if (!tagTaxonomy) return _err('NOT_FOUND', "Taxonomy 'tag' not found", 404);
      if (r.method == 'GET') return _ok({'terms': terms});
      final body = jsonDecode(r.body) as Map;
      if (terms.any((t) => t['slug'] == body['slug'])) return http.Response('', 409);
      final term = {'id': 't${terms.length + 1}', 'name': 'tag', 'slug': body['slug'], 'label': body['label'], 'children': <Object>[]};
      terms.add(term);
      return _ok({'term': term}, 201);
    }
    if (r.method == 'POST' && path == '/_emdash/api/content/posts') {
      final body = Map<String, dynamic>.from(jsonDecode(r.body) as Map);
      final slug = body['slug'] as String;
      if (postsBySlug.containsKey(slug)) return _err('SLUG_CONFLICT', "Slug '$slug' already exists in collection 'posts'", 409);
      created++;
      final item = {'id': 'p$created', 'type': 'posts', 'slug': slug, 'status': 'draft', 'data': body['data']};
      postsBySlug[slug] = item;
      return _ok({'item': item, '_rev': 'r'}, 201);
    }
    final get = RegExp(r'^/_emdash/api/content/posts/([^/]+)$').firstMatch(path);
    if (r.method == 'GET' && get != null) {
      final item = postsBySlug[Uri.decodeComponent(get.group(1)!)];
      return item == null ? _err('NOT_FOUND', 'Content item not found', 404) : _ok({'item': item, '_rev': 'r'});
    }
    final publish = RegExp(r'^/_emdash/api/content/posts/([^/]+)/publish$').firstMatch(path);
    if (r.method == 'POST' && publish != null) {
      published++;
      final item = postsBySlug.values.firstWhere((p) => p['id'] == publish.group(1));
      item['status'] = 'published';
      return _ok({'item': item});
    }
    return _err('NOT_FOUND', 'no route $path', 404);
  }
}

ConnectedAccount _account({Map<String, dynamic> extra = const {}}) =>
    fakeAccount('emdash', config: {'site': 'https://blog.example', 'siteTitle': 'Robin & Co', ...extra});

Map<String, dynamic> _json(http.Request r) => Map<String, dynamic>.from(jsonDecode(r.body) as Map);

void main() {
  final emdash = EmDashAdapter();

  group('descriptor and forms', () {
    test('describes EmDash: a titled blog with Markdown, photos, videos and tags, no sound', () {
      final d = emdash.descriptor;
      expect((d.id, d.name, d.homepage, d.setupGuide), ('emdash', 'EmDash', 'https://emdashcms.com', 'docs/platforms/emdash.md'));
      expect(d.tiers, {PlatformTier.openApi, PlatformTier.handoff});
      expect(d.defaultTier, PlatformTier.openApi);
      expect((d.text.titleRequired, d.text.supportsMarkdown, d.text.supportsHtml, d.text.hashtagsAsField), (true, true, false, true));
      expect((d.media.maxImages, d.media.maxVideos, d.media.maxAudios, d.media.supportsAltText), (20, 4, 0, true));
      expect(d.media.imageMimeTypes, {'image/jpeg', 'image/png', 'image/gif', 'image/webp'});
      expect(d.media.imageMaxBytes, 50 * 1024 * 1024);
      expect(d.serverSideScheduling, isFalse);
      expect(d.text.notes, isNot(contains('—')));
      expect(d.media.notes, isNot(contains('—')));
    });

    test('the connect form asks for the site and the token, kept secret; hand-off asks for the site only', () {
      final api = emdash.specFor(PlatformTier.openApi);
      expect([for (final f in api.fields) f.key], ['site', 'token', 'defaultStatus']);
      expect(api.fields.firstWhere((f) => f.key == 'token').secret, isTrue);
      expect(api.intro, contains('Settings > API Tokens'));
      expect(api.intro, contains('Content Read'));
      expect(api.intro, contains('Media Write'));
      expect([for (final f in emdash.specFor(PlatformTier.handoff).fields) f.key], ['site']);
    });

    test('the sign-in has no end date unless one was chosen, and can be revoked', () {
      final p = emdash.signInPolicyFor(_account());
      expect((p.limit, p.renewal, p.earlyRevocationPossible, p.unverified), (SignInLimit.none, SignInRenewal.notNeeded, true, false));
      expect(p.note, contains('end date'));
      expect(emdash.signInPolicyFor(fakeAccount('emdash', tier: PlatformTier.handoff)).hasConnection, isFalse);
    });
  });

  group('connect', () {
    test('checks the site is EmDash, proves the token with one read, names the account after the site', () async {
      final site = _Site();
      final res = await emdash.connect(PlatformTier.openApi,
          {'site': ' https://Blog.Example/_emdash/admin/settings ', 'token': ' $_token ', 'defaultStatus': 'draft'}, testContext(handler: site.handle));
      expect(site.trail, ['GET /_emdash/api/health', 'GET /_emdash/api/content/posts?limit=1', 'GET /']);
      expect(site.calls[0].headers['authorization'], isNull, reason: 'the health check needs no token');
      expect(site.calls[1].headers['authorization'], 'Bearer $_token');
      expect(site.calls[2].headers['authorization'], isNull, reason: 'the token never goes to a page');
      final a = res.account;
      expect((a.id, a.displayName, a.handle, a.profileUrl), ('emdash:blog.example', 'Robin & Co', 'blog.example', 'https://blog.example'));
      expect(a.config, {'site': 'https://blog.example', 'siteTitle': 'Robin & Co', 'version': '1.5.0', 'defaultStatus': 'draft'});
      expect(res.secrets[OAuthTokens.keyAccessToken], _token);
      expect(a.config.values.join(' '), isNot(contains('ec_pat_')), reason: 'no part of the token in the account');
    });

    test('a token pasted with "Bearer " in front still works; one that is not an EmDash token is refused before any request', () async {
      final site = _Site();
      await emdash.connect(PlatformTier.openApi, {'site': 'blog.example', 'token': 'Bearer $_token'}, testContext(handler: site.handle));
      for (final bad in ['', 'abc', 'ec_pat_short', 'ghost:123', 'ec_pat_0123456789abcdef ghi']) {
        final quiet = _Site();
        await expectLater(emdash.connect(PlatformTier.openApi, {'site': 'blog.example', 'token': bad}, testContext(handler: quiet.handle)),
            throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'token')), reason: bad);
        expect(quiet.calls, isEmpty, reason: bad);
      }
    });

    test('a site that is not EmDash, or plain http on a real host, is refused on the site field', () async {
      final notEmDash = _Site()..override = (r) => http.Response('<html>WordPress</html>', 404, headers: {'content-type': 'text/html'});
      await expectLater(emdash.connect(PlatformTier.openApi, {'site': 'blog.example', 'token': _token}, testContext(handler: notEmDash.handle)),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'site').having((e) => e.message, 'message', contains('does not run EmDash'))));
      final other = _Site()..override = (r) => _ok({'product': 'something-else'});
      await expectLater(emdash.connect(PlatformTier.openApi, {'site': 'blog.example', 'token': _token}, testContext(handler: other.handle)),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'site')));
      await expectLater(emdash.connect(PlatformTier.openApi, {'site': 'http://blog.example', 'token': _token}, testContext(handler: _Site().handle)),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'site')));
    });

    test('a rejected token and a token without Content Read are told apart', () async {
      final revoked = _Site()..override = (r) => r.url.path.contains('/content/') ? _err('INVALID_TOKEN', 'Invalid or expired token', 401) : null;
      await expectLater(emdash.connect(PlatformTier.openApi, {'site': 'blog.example', 'token': _token}, testContext(handler: revoked.handle)),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'token').having((e) => e.message, 'message', contains('did not accept'))));
      final narrow = _Site()..override = (r) => r.url.path.contains('/content/') ? _err('INSUFFICIENT_SCOPE', 'Token lacks required scope: content:read', 403) : null;
      await expectLater(emdash.connect(PlatformTier.openApi, {'site': 'blog.example', 'token': _token}, testContext(handler: narrow.handle)),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('Content Read'))));
    });

    test('a home page that cannot be read leaves the host as the name', () async {
      final site = _Site()..override = (r) => r.url.path == '/' ? http.Response('down', 503) : null;
      final res = await emdash.connect(PlatformTier.openApi, {'site': 'blog.example', 'token': _token}, testContext(handler: site.handle));
      expect(res.account.displayName, 'blog.example');
    });

    test('hand-off needs no token and makes no request', () async {
      final site = _Site();
      final res = await emdash.connect(PlatformTier.handoff, {'site': 'blog.example/_emdash/admin'}, testContext(handler: site.handle));
      expect(site.calls, isEmpty);
      expect((res.account.id, res.account.tier), ('emdash-handoff:blog.example', PlatformTier.handoff));
      expect(res.account.config, {'site': 'https://blog.example'});
      expect(res.secrets, isEmpty);
    });
  });

  group('publish', () {
    test('photos first, tags made sure of, the post as Portable Text, then published; the result is the post address', () async {
      final site = _Site();
      final v = PostVariant(
        title: 'Hello World',
        text: 'Some **bold** text.',
        tags: const ['#webdev', 'New Tag', 'web development'],
        media: [fakeImage(id: 'a', altText: 'First'), fakeImage(id: 'b', altText: 'Second')],
        sourcePostId: 'post-1',
        extra: const {'excerpt': 'Short.'},
      );
      final res = await emdash.publish(v, _account(), _secrets, testContext(handler: site.handle));
      expect(res.success, isTrue, reason: '${res.error}');
      expect(site.trail, [
        'POST /_emdash/api/media',
        'POST /_emdash/api/media',
        'GET /_emdash/api/taxonomies/tag/terms?includeCounts=false',
        'POST /_emdash/api/taxonomies/tag/terms',
        'POST /_emdash/api/content/posts',
        'POST /_emdash/api/content/posts/p1/publish',
      ]);
      expect(site.calls.every((c) => c.headers['authorization'] == 'Bearer $_token'), isTrue);
      expect(multipartFieldsOf(site.calls[0]), {'deduplicate': 'true', 'alt': 'First', 'width': '1200', 'height': '800', 'file': '<a.jpg>'});
      expect(_json(site.calls[3]), {'slug': 'new-tag', 'label': 'New Tag'});

      final body = _json(site.calls[4]);
      expect(body['slug'], 'hello-world');
      expect(body['taxonomies'], {'tag': ['webdev', 'new-tag']}, reason: '#webdev by slug, "web development" by name: one tag');
      final data = Map<String, dynamic>.from(body['data'] as Map);
      expect(data['title'], 'Hello World');
      expect(data['excerpt'], 'Short.');
      expect(data['featured_image'], {
        'provider': 'local',
        'id': 'm1',
        'src': '/_emdash/api/media/file/m1.jpg',
        'filename': 'img1.jpg',
        'mimeType': 'image/jpeg',
        'width': 1200,
        'height': 800,
        'alt': 'First',
      });
      final content = [for (final b in data['content'] as List) Map<String, dynamic>.from(b as Map)];
      final prefix = emdashKeyPrefix(emdashPostKey(_account(), v));
      expect(content.first['_key'], '${prefix}0');
      expect([for (final s in content.first['children'] as List) ((s as Map)['text'], (s['marks'] as List).join(','))], [
        ('Some ', ''),
        ('bold', 'strong'),
        (' text.', ''),
      ]);
      expect(content.last, {
        '_type': 'image',
        '_key': '${prefix}i0',
        'asset': {'_ref': 'm2', 'url': '/_emdash/api/media/file/m2.jpg'},
        'alt': 'Second',
        'width': 1200,
        'height': 800,
      });
      expect(site.calls[5].body, '{}');
      expect((res.remoteId, res.remoteUrl, res.notice), ('p1', 'https://blog.example/posts/hello-world', null));
    });

    test('featuredImage: false puts every photo in the post; a video becomes a video block', () async {
      final site = _Site();
      final v = PostVariant(title: 'T', text: 'x', media: [fakeImage(id: 'a'), fakeVideo(id: 'v')], extra: const {'featuredImage': false});
      final res = await emdash.publish(v, _account(), _secrets, testContext(handler: site.handle));
      expect(res.success, isTrue, reason: '${res.error}');
      final data = Map<String, dynamic>.from(_json(site.calls.firstWhere((c) => c.url.path == '/_emdash/api/content/posts'))['data'] as Map);
      expect(data.containsKey('featured_image'), isFalse);
      expect([for (final b in data['content'] as List) (b as Map)['_type']], ['block', 'image', 'video']);
      expect(((data['content'] as List).last as Map)['asset'], {'_ref': 'm2', 'url': '/_emdash/api/media/file/m2.jpg'});
    });

    test('the slug option is used, cleaned the EmDash way; a post with no tags sends no taxonomies', () async {
      final site = _Site();
      final res = await emdash.publish(const PostVariant(title: 'T', text: 'x', extra: {'slug': 'My Own_Slug!'}), _account(), _secrets, testContext(handler: site.handle));
      expect(res.remoteUrl, 'https://blog.example/posts/my-own-slug');
      final body = _json(site.calls.firstWhere((c) => c.url.path == '/_emdash/api/content/posts'));
      expect(body.containsKey('taxonomies'), isFalse);
      expect(site.trail.where((t) => t.contains('taxonomies')), isEmpty);
    });

    group('a retry never posts twice', () {
      test('the same post sent again finds the draft an earlier try made, and publishes that one', () async {
        final site = _Site();
        final v = const PostVariant(title: 'Retry Me', text: 'Body', sourcePostId: 'src-9');
        // The earlier try made the draft, then its publish call failed.
        site.override = (r) => r.url.path.endsWith('/publish') && site.published == 0 && site.created == 1 ? http.Response('gateway', 502) : null;
        final first = await emdash.publish(v, _account(), _secrets, testContext(handler: site.handle));
        expect(first.success, isFalse);
        expect(first.error!.retryable, isTrue, reason: 'a refused publish call made nothing live');
        site.override = null;
        site.calls.clear();

        final again = await emdash.publish(v, _account(), _secrets, testContext(handler: site.handle));
        expect(again.success, isTrue, reason: '${again.error}');
        expect(site.created, 1, reason: 'no second post');
        expect(site.trail, [
          'POST /_emdash/api/content/posts',
          'GET /_emdash/api/content/posts/retry-me',
          'POST /_emdash/api/content/posts/p1/publish',
        ]);
        expect((again.remoteId, again.remoteUrl), ('p1', 'https://blog.example/posts/retry-me'));
        expect(again.notice, contains('earlier try'));
      });

      test('a post the earlier try already published is not published again', () async {
        final site = _Site();
        const v = PostVariant(title: 'Done', text: 'Body', sourcePostId: 'src-10');
        expect((await emdash.publish(v, _account(), _secrets, testContext(handler: site.handle))).success, isTrue);
        site.calls.clear();
        final again = await emdash.publish(v, _account(), _secrets, testContext(handler: site.handle));
        expect(again.success, isTrue);
        expect(site.trail, ['POST /_emdash/api/content/posts', 'GET /_emdash/api/content/posts/done']);
        expect((site.created, site.published), (1, 1));
      });

      test('another post holding the slug: this one goes to the slug with its key, and its retry finds it there', () async {
        final site = _Site();
        site.postsBySlug['same-title'] = {
          'id': 'other',
          'slug': 'same-title',
          'status': 'published',
          'data': {
            'title': 'Same Title',
            'content': [
              {'_type': 'block', '_key': 'abc', 'children': <Object>[]},
            ],
          },
        };
        const v = PostVariant(title: 'Same Title', text: 'Mine', sourcePostId: 'src-11');
        final key = emdashPostKey(_account(), v);
        final res = await emdash.publish(v, _account(), _secrets, testContext(handler: site.handle));
        expect(res.success, isTrue, reason: '${res.error}');
        expect(res.remoteUrl, 'https://blog.example/posts/same-title-${key.substring(0, 6)}');
        expect(site.trail, [
          'POST /_emdash/api/content/posts',
          'GET /_emdash/api/content/posts/same-title',
          'POST /_emdash/api/content/posts',
          'POST /_emdash/api/content/posts/p1/publish',
        ]);
        site.calls.clear();
        final again = await emdash.publish(v, _account(), _secrets, testContext(handler: site.handle));
        expect((again.success, again.remoteId, site.created), (true, 'p1', 1));
      });

      test('an edited post is a new post, even under the same title', () async {
        final site = _Site();
        await emdash.publish(const PostVariant(title: 'Same', text: 'One', sourcePostId: 's1'), _account(), _secrets, testContext(handler: site.handle));
        final second = await emdash.publish(const PostVariant(title: 'Same', text: 'Two', sourcePostId: 's2'), _account(), _secrets, testContext(handler: site.handle));
        expect(second.success, isTrue, reason: '${second.error}');
        expect(site.created, 2);
        expect(second.remoteUrl, isNot('https://blog.example/posts/same'));
      });

      test('both slugs held by other posts: a clear error, nothing published', () async {
        final site = _Site();
        const v = PostVariant(title: 'Busy', text: 'x', sourcePostId: 's');
        final key = emdashPostKey(_account(), v);
        for (final slug in ['busy', emdashFallbackSlug('busy', key)]) {
          site.postsBySlug[slug] = {
            'id': slug,
            'slug': slug,
            'data': {
              'title': 'Busy',
              'content': [
                {'_key': 'theirs0'},
              ],
            },
          };
        }
        final res = await emdash.publish(v, _account(), _secrets, testContext(handler: site.handle));
        expect(res.success, isFalse);
        expect(res.error!.kind, PublishErrorKind.validation);
        expect(res.error!.message, contains('Set another slug'));
        expect(site.published, 0);
      });

      test('a lost answer on the create is a plain retryable failure: the retry finds the draft', () async {
        final site = _Site();
        site.override = (r) => r.url.path == '/_emdash/api/content/posts' && r.method == 'POST' ? throw http.ClientException('Connection closed before full header was received') : null;
        final res = await emdash.publish(const PostVariant(title: 'T', text: 'x', sourcePostId: 's'), _account(), _secrets, testContext(handler: site.handle));
        expect(res.success, isFalse);
        expect(res.error!.outcomeUnknown, isNot(isTrue), reason: 'a draft is not live, and the retry finds it');
        expect(res.error!.retryable, isTrue);
      });

      test('a lost answer on the publish call: the post may be live, so it is not retried by itself', () async {
        final site = _Site();
        site.override = (r) => r.url.path.endsWith('/publish') ? throw http.ClientException('Connection closed before full header was received') : null;
        final res = await emdash.publish(const PostVariant(title: 'T', text: 'x', sourcePostId: 's'), _account(), _secrets,
            AdapterContext(http: NeforumHttp(client: _client(site), maxRetries: 0), clock: () => testNow, networkName: 'EmDash'));
        expect(res.error!.outcomeUnknown, isTrue);
        expect(res.error!.retryable, isFalse);
      });
    });

    test('a lost upload answer: the file is sent again (EmDash keeps one copy of the same bytes) and the post is made once', () async {
      final site = _Site();
      var lost = 0;
      site.override = (r) {
        if (r.url.path == '/_emdash/api/media' && lost++ == 0) throw http.ClientException('Connection closed before full header was received');
        return null;
      };
      final res = await emdash.publish(PostVariant(title: 'T', text: 'x', media: [fakeImage()]), _account(), _secrets,
          testContext(handler: site.handle, maxRetries: 2));
      expect(res.success, isTrue, reason: '${res.error}');
      expect(site.trail.where((t) => t == 'POST /_emdash/api/media'), hasLength(2));
      expect(multipartFieldsOf(site.calls.firstWhere((c) => c.url.path == '/_emdash/api/media'))['deduplicate'], 'true');
      expect((site.created, site.published), (1, 1));
    });

    // 1.4.3 integration: "Publish as" in the Customize sheet. The post's own
    // choice wins, then the choice kept for the account from the sheet
    // (postDefaults), then the account's Default status, then published.
    test('Publish as: the post, then the kept choice, then Default status, then published', () async {
      Future<String> statusOf({Map<String, dynamic> config = const {}, Map<String, Object?> postChoice = const {}}) async {
        final site = _Site();
        final account = _account(extra: config);
        final post = Post(
          id: 'order',
          title: 'Order',
          text: 'x',
          targets: [PostTarget(accountId: account.id, overrides: PostOverrides(extra: postChoice))],
          createdAt: testNow,
          updatedAt: testNow,
        );
        final v = const VariantResolver().resolve(post, post.targets.single, emdash.descriptorForAccount(account), account: account);
        final res = await emdash.publish(v, account, _secrets, testContext(handler: site.handle));
        expect(res.success, isTrue, reason: '${res.error}');
        return site.published == 1 ? 'published' : 'draft';
      }

      const keptDraft = {'postDefaults': {'status': 'draft'}};
      const keptPublished = {'postDefaults': {'status': 'published'}};
      expect(await statusOf(), 'published', reason: 'nothing set');
      expect(await statusOf(config: {'defaultStatus': 'draft'}), 'draft', reason: 'Default status');
      expect(await statusOf(config: {'defaultStatus': 'draft', ...keptPublished}), 'published', reason: 'the kept choice beats Default status');
      expect(await statusOf(config: keptDraft), 'draft', reason: 'the kept choice beats published');
      expect(await statusOf(config: keptDraft, postChoice: {'status': 'published'}), 'published', reason: "the post's choice beats the kept one");
      expect(await statusOf(config: {'defaultStatus': 'draft'}, postChoice: {'status': 'published'}), 'published',
          reason: "the post's choice beats Default status");
      expect(await statusOf(config: keptPublished, postChoice: {'status': 'draft'}), 'draft');
    });

    test('publish as draft: no publish call, the result links the draft in the admin', () async {
      final site = _Site();
      final res = await emdash.publish(const PostVariant(title: 'Draft', text: 'x'), _account(extra: {'defaultStatus': 'draft'}), _secrets,
          testContext(handler: site.handle));
      expect(res.success, isTrue);
      expect(site.trail, ['POST /_emdash/api/content/posts']);
      expect(res.remoteUrl, 'https://blog.example/_emdash/admin/content/posts/p1');
      final override = await emdash.publish(const PostVariant(title: 'Live', text: 'x', extra: {'status': 'published'}),
          _account(extra: {'defaultStatus': 'draft'}), _secrets, testContext(handler: site.handle));
      expect(override.remoteUrl, 'https://blog.example/posts/live', reason: 'the per-post status wins');
    });

    test('a site with no Tags taxonomy posts without tags and says so', () async {
      final site = _Site()..tagTaxonomy = false;
      final res = await emdash.publish(const PostVariant(title: 'T', text: 'x', tags: ['a']), _account(), _secrets, testContext(handler: site.handle));
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.notice, contains('no Tags taxonomy'));
      expect(_json(site.calls.firstWhere((c) => c.url.path == '/_emdash/api/content/posts')).containsKey('taxonomies'), isFalse);
    });

    test('failures say what to do: a revoked token, a missing permission, a file too large', () async {
      Future<PublishError> fail(http.Response? Function(http.Request r) answer, {PostVariant? v}) async {
        final site = _Site()..override = answer;
        final res = await emdash.publish(v ?? PostVariant(title: 'T', text: 'x', media: [fakeImage()]), _account(), _secrets, testContext(handler: site.handle));
        expect(res.success, isFalse);
        return res.error!;
      }

      final revoked = await fail((r) => _err('INVALID_TOKEN', 'Invalid or expired token', 401));
      expect(revoked.kind, PublishErrorKind.auth);
      expect(revoked.message, contains('reconnect'));
      final scope = await fail((r) => _err('INSUFFICIENT_SCOPE', 'Token lacks required scope: media:write', 403));
      expect((scope.kind, scope.notAllowed), (PublishErrorKind.auth, true));
      expect(scope.message, contains('Media Write'));
      final big = await fail((r) => _err('PAYLOAD_TOO_LARGE', 'File exceeds maximum size of 50MB', 413));
      expect(big.kind, PublishErrorKind.validation);
      expect(big.message, contains('too large'));
      final gone = await fail((r) => r.url.path == '/_emdash/api/content/posts' ? _err('COLLECTION_NOT_FOUND', "Collection 'posts' not found", 404) : null,
          v: const PostVariant(title: 'T', text: 'x'));
      expect(gone.kind, PublishErrorKind.configuration);
      expect(gone.message, contains('no "posts" collection'));
    });

    test('nothing is sent without a title, without a token, or from a hand-off account', () async {
      final site = _Site();
      final ctx = testContext(handler: site.handle);
      expect((await emdash.publish(const PostVariant(text: 'x'), _account(), _secrets, ctx)).error!.kind, PublishErrorKind.validation);
      expect((await emdash.publish(const PostVariant(title: 'T', text: 'x'), fakeAccount('emdash', tier: PlatformTier.handoff), const {}, ctx)).success, isFalse);
      expect((await emdash.publish(const PostVariant(title: 'T', text: 'x'), _account(), const {}, ctx)).error!.kind, PublishErrorKind.auth);
      expect(site.calls, isEmpty);
    });

    test('a sound file is left out, as the composer warns; the photo still goes', () async {
      final site = _Site();
      final sound = MediaAttachment(id: 's', path: '/tmp/s.mp3', mimeType: 'audio/mpeg', sizeBytes: 10);
      final v = PostVariant(title: 'T', text: 'x', media: [sound, fakeImage()]);
      expect(emdash.validate(v, _account()).map((i) => i.code), contains('media.audio_unsupported'));
      final res = await emdash.publish(v, _account(), _secrets, testContext(handler: site.handle));
      expect(res.success, isTrue, reason: '${res.error}');
      expect(site.mediaCount, 1);
    });
  });

  group('validate and hand-off', () {
    test('validate flags an unknown status and a non-public post', () {
      final issues = emdash.validate(const PostVariant(title: 'T', text: 'x', visibility: Visibility.followers, extra: {'status': 'scheduled'}), _account());
      final codes = issues.map((i) => i.code).toSet();
      expect(codes, containsAll(['emdash.bad_status', 'emdash.public_only']));
      expect(emdash.validate(const PostVariant(title: 'T', text: 'x'), _account()).where((i) => i.code.startsWith('emdash.')), isEmpty);
    });

    test('hand-off opens a new post in the admin and lists numbered steps', () {
      final plan = emdash.buildHandoff(PostVariant(title: 'Hi', text: 'Body', tags: const ['a'], media: [fakeImage()]),
          account: fakeAccount('emdash', tier: PlatformTier.handoff, config: {'site': 'https://blog.example'}))!;
      expect(plan.desktopUrl, 'https://blog.example/_emdash/admin/content/posts/new');
      expect(plan.clipboardText, 'Body');
      expect(plan.instructions.split('\n').first, startsWith('1. '));
      expect(plan.instructions, contains('"Hi"'));
      expect(plan.mediaNote, isNotNull);
      expect(emdash.buildHandoff(const PostVariant(text: 'x'))!.desktopUrl, isNull);
    });
  });

  group('slugs and keys', () {
    test('slugs follow EmDash: NFKC, lower case, hyphens, letters of any script, 80 at most', () {
      expect(emdashSlug('Hello World'), 'hello-world');
      expect(emdashSlug('  Snake_case and  spaces!? '), 'snake-case-and-spaces');
      expect(emdashSlug('Café déjà vu'), 'café-déjà-vu');
      expect(emdashSlug('ﬁne Ｆｕｌｌ'), 'fine-full', reason: 'NFKC folds ligatures and full-width letters');
      expect(emdashSlug('日本語のタイトル'), '日本語のタイトル');
      expect(emdashSlug('!!!'), startsWith('post-'));
      expect(emdashSlug('a' * 100), 'a' * 80);
      expect(emdashSlug('${'a' * 79} b'), 'a' * 79, reason: 'no hyphen left at the end');
    });

    test('the post key is the same for a retry and different for any change; the fallback slug holds its start', () {
      final a = _account();
      const v = PostVariant(title: 'T', text: 'x', sourcePostId: 'p');
      expect(emdashPostKey(a, v), emdashPostKey(a, v));
      expect(emdashPostKey(a, v), isNot(emdashPostKey(a, const PostVariant(title: 'T', text: 'y', sourcePostId: 'p'))));
      expect(emdashPostKey(a, v), isNot(emdashPostKey(fakeAccount('emdash', id: 'other'), v)));
      expect(emdashPostKey(a, const PostVariant(title: 'T', text: 'x')), isNot(emdashPostKey(a, const PostVariant(title: 'T', text: 'x'))),
          reason: 'no source post: a random key');
      final key = emdashPostKey(a, v);
      expect(emdashKeyPrefix(key), 'nf${key.substring(0, 10)}');
      expect(emdashFallbackSlug('t' * 80, key), '${'t' * 72}-${key.substring(0, 6)}');
    });

    test('a post carries the mark when one of its keys does; an empty post only under the fallback slug, by title', () {
      Map<String, dynamic> post(List<Object> content, [String title = 'T']) => {'data': {'title': title, 'content': content}};
      expect(emdashCarriesMark(post([{'_key': 'nfabc0'}]), 'nfabc', 'T', fallbackSlug: false), isTrue);
      expect(emdashCarriesMark(post([{'_key': 'zz0'}]), 'nfabc', 'T', fallbackSlug: true), isFalse);
      expect(emdashCarriesMark(post([]), 'nfabc', 'T', fallbackSlug: false), isFalse);
      expect(emdashCarriesMark(post([]), 'nfabc', 'T', fallbackSlug: true), isTrue);
      expect(emdashCarriesMark(post([], 'Other'), 'nfabc', 'T', fallbackSlug: true), isFalse);
    });

    test('site addresses are cut back to the site; tokens must look like EmDash tokens', () {
      expect(parseEmDashSite('blog.example/_emdash/admin/content/posts').toString(), 'https://blog.example');
      expect(parseEmDashSite('https://example.com/blog/').toString(), 'https://example.com/blog');
      expect(parseEmDashSite('http://localhost:4321').toString(), 'http://localhost:4321');
      expect(parseEmDashToken('  Bearer $_token\n'), _token);
    });
  });
}

http.Client _client(_Site site) => _SiteClient(site);

class _SiteClient extends http.BaseClient {
  _SiteClient(this.site);
  final _Site site;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    final copy = http.Request(request.method, request.url)
      ..bodyBytes = bytes
      ..headers.addAll(request.headers);
    final res = await site.handle(copy);
    return http.StreamedResponse(Stream.value(res.bodyBytes), res.statusCode, headers: res.headers, request: request);
  }
}
