// An article from the post through the resolver to each network's request:
// which networks get it, what they get, and the request each adapter sends
// (fake servers, nothing real is reached).
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/blogs_a/emdash_adapter.dart';
import 'package:neforum_core/src/adapters/blogs_a/ghost_adapter.dart';
import 'package:neforum_core/src/adapters/blogs_a/wordpress_adapter.dart';
import 'package:neforum_core/src/adapters/blogs_a/writefreely_adapter.dart';
import 'package:neforum_core/src/adapters/blogs_b/devto_adapter.dart';
import 'package:neforum_core/src/adapters/blogs_b/hashnode_adapter.dart';
import 'package:neforum_core/src/adapters/blogs_b/micropub_adapter.dart';
import 'package:neforum_core/src/adapters/handoff_only/substack_adapter.dart';
import 'package:neforum_core/src/adapters/mastodon/mastodon_adapter.dart';
import 'package:neforum_core/src/adapters/network_options.dart' show kXArticleKey;
import 'package:neforum_core/src/adapters/tumblr/tumblr_adapter.dart';
import 'package:neforum_core/src/adapters/x/x_adapter.dart';
import 'package:test/test.dart';

import '../support/article_fixture.dart';
import '../support/test_context.dart';
import 'article_serializers_test.dart' show parseBlockMarkup;

http.Response _json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {...jsonHeaders, ...headers});

Post _post({ArticleDocument article = richArticle, List<PostOverrides> overrides = const [PostOverrides()], String? link}) => Post(
      id: 'post-1',
      text: 'The short version for social networks.',
      title: 'Rich title',
      link: link,
      createdAt: testNow,
      updatedAt: testNow,
      media: richMedia(),
      tags: const ['dart', 'news'],
      article: article,
      targets: [for (var i = 0; i < overrides.length; i++) PostTarget(accountId: 'acct-1', overrides: overrides[i])],
    );

PostVariant _resolve(PlatformAdapter a, ConnectedAccount account, {Post? post}) {
  final p = post ?? _post();
  return const VariantResolver().resolve(p, p.targets.first, a.descriptor, account: account);
}

void main() {
  group('the resolver', () {
    final wp = WordPressAdapter();
    final wpAccount = fakeAccount('wordpress', config: {'restBase': 'https://example.com/wp-json/', 'username': 'alice'});

    test('a blog gets the article, its files in reading order, its text as composer text', () {
      final v = _resolve(wp, wpAccount);
      expect(v.article, richArticle);
      expect(v.media.map((m) => m.id), ['c1', 'i1', 'g1', 'g2', 'g3', 'v1', 'a1']);
      expect(v.text, richArticle.toComposerText());
      expect(v.title, 'Rich title');
      expect(v.seriesPosts, isEmpty);
      expect(v.issues.where((i) => i.code == 'article.subtitle'), hasLength(1));
    });

    test('a social network keeps the post\'s own text and media', () {
      final v = _resolve(MastodonAdapter(), fakeAccount('mastodon', config: {'instance': 'https://m.example'}));
      expect(v.article, isNull);
      expect(v.text, startsWith('The short version for social networks.'));
      expect(v.issues.where((i) => i.code.startsWith('article.')), isEmpty);
    });

    test('a target with words of its own gets them, not the article', () {
      final v = _resolve(wp, wpAccount, post: _post(overrides: const [PostOverrides(text: 'Own words')]));
      expect(v.article, isNull);
      expect(v.text, 'Own words');
    });

    test('blocks the target leaves out are not sent, nor are their files', () {
      final v = _resolve(wp, wpAccount,
          post: _post(overrides: const [
            PostOverrides(excludedBlockIds: ['gal', 'vid', ArticleDocument.coverId]),
          ]));
      expect(v.article!.blockById('gal'), isNull);
      expect(v.article!.cover, isNull);
      expect(v.media.map((m) => m.id), ['i1', 'a1']);
    });

    test('the post\'s link goes at the end of the article, as it went at the end of the text', () {
      final v = _resolve(wp, wpAccount, post: _post(link: 'https://elsewhere.example/p'));
      final last = v.article!.blocks.last as ArticleParagraph;
      expect(last.spans.single.link, 'https://elsewhere.example/p');
    });

    test('an article is one post: no social count per post, never a series; a format\'s own limit is reported', () {
      final many = [for (var i = 0; i < 31; i++) fakeImage(id: 'p$i')];
      final doc = ArticleDocument(blocks: [for (final m in many) ArticleImage('b-${m.id}', ArticleMediaRef(m.id))]);
      final post = Post(
        id: 'x',
        text: 't',
        title: 'T',
        createdAt: testNow,
        updatedAt: testNow,
        media: many,
        article: doc,
        targets: const [PostTarget(accountId: 'a')],
      );
      final v = const VariantResolver().resolve(post, post.targets.single, wp.descriptor, account: wpAccount);
      // 20 photos per post is NEFORUM's count for a social-style post, not WordPress's.
      expect(v.media, hasLength(31));
      expect(v.seriesPosts, isEmpty);
      expect(v.issues.where((i) => i.isError), isEmpty);
      expect(wp.validate(v, wpAccount).where((i) => i.isError), isEmpty);
      final tumblr = TumblrAdapter();
      final t = const VariantResolver().resolve(post, post.targets.single, tumblr.descriptor, account: fakeAccount('tumblr', tier: PlatformTier.byokApi));
      expect(t.media, hasLength(31));
      expect(t.issues.where((i) => i.code == 'article.too_many_images').map((i) => i.message).single, contains('30 photos per post'));
    });

    test('a type the network refuses is left out before posting, and its block reported', () {
      final v = _resolve(GhostAdapter(), fakeAccount('ghost'));
      expect(v.media.map((m) => m.id), isNot(contains('v1')));
      expect(v.issues.map((i) => i.code), containsAll(['media.dropped', 'article.media_unavailable']));
    });

    test('a hand-off account gets the hand-off report', () {
      final v = _resolve(wp, fakeAccount('wordpress', tier: PlatformTier.handoff));
      expect(v.issues.map((i) => i.code), contains('article.media_by_hand'));
      expect(ArticleRenderer.reportFor(v, wp.descriptor, tier: PlatformTier.handoff).issues.map((i) => i.code), contains('media_by_hand'));
    });

    test('ArticleRenderer.reportFor gives the same report the variant\'s checks carry', () {
      final v = _resolve(wp, wpAccount);
      expect(ArticleRenderer.reportFor(v, wp.descriptor).toValidationIssues().map((i) => i.code),
          v.issues.where((i) => i.code.startsWith('article.')).map((i) => i.code));
    });

    test('the networks that take articles', () {
      final formats = {for (final a in builtinAdapters()) if (a.descriptor.articleFormat != null) a.descriptor.id: a.descriptor.articleFormat};
      expect(formats, {
        'wordpress': ArticleFormat.gutenberg,
        'ghost': ArticleFormat.ghostHtml,
        'emdash': ArticleFormat.portableText,
        'writefreely': ArticleFormat.writeFreelyMarkdown,
        'devto': ArticleFormat.devtoMarkdown,
        'hashnode': ArticleFormat.hashnodeMarkdown,
        'micropub': ArticleFormat.micropubHtml,
        'tumblr': ArticleFormat.tumblrNpf,
        'substack': ArticleFormat.handoffHtml,
        'x': ArticleFormat.xArticle,
      });
      expect([for (final a in builtinAdapters()) if (a.descriptor.articleOptionKey != null) a.descriptor.id], ['x']);
    });
  });

  group('WordPress request', () {
    final wp = WordPressAdapter();
    final account = fakeAccount('wordpress', config: {
      'site': 'https://example.com',
      'restBase': 'https://example.com/wp-json/',
      'username': 'alice',
      'canPublish': true,
      'canUpload': true,
    });

    Future<(PublishResult, Map<String, dynamic>)> publish(Post post) async {
      Map<String, dynamic>? sent;
      var mediaId = 100;
      final ctx = testContext(handler: (r) async {
        final p = r.url.path;
        if (p == '/wp-json/wp/v2/media' && r.method == 'POST') {
          mediaId++;
          return _json({'id': mediaId, 'source_url': 'https://example.com/up/$mediaId'}, 201);
        }
        if (p.startsWith('/wp-json/wp/v2/media/')) return _json({'id': 1});
        if (p.startsWith('/wp-json/wp/v2/tags') && r.method == 'GET') return _json(<Object>[]);
        if (p.startsWith('/wp-json/wp/v2/tags')) return _json({'id': 9}, 201);
        if (p == '/wp-json/wp/v2/posts') {
          sent = bodyOf(r);
          return _json({'id': 7, 'link': 'https://example.com/?p=7', 'status': sent!['status']}, 201);
        }
        return _json({'code': 'rest_no_route'}, 404);
      });
      final res = await wp.publish(_resolve(wp, account, post: post), account, const {'app_password': 'pw'}, ctx);
      return (res, sent!);
    }

    test('block markup, featured image from the cover, excerpt and slug from the article', () async {
      final (res, body) = await publish(_post());
      expect(res.success, isTrue, reason: '${res.error}');
      final parsed = parseBlockMarkup(body['content'] as String);
      expect(parsed.freeform, isEmpty);
      expect(parsed.blocks.first.name, 'core/heading');
      // Uploads in reading order: c1 = 101 is the featured image, i1 = 102 the first photo.
      expect(body['featured_media'], 101);
      expect(body['content'], contains('class="wp-image-102"'));
      expect(body['content'], contains('<!-- wp:video {"id":106} -->'));
      expect(body['content'], contains('<!-- wp:audio {"id":107} -->'));
      expect(body['excerpt'], 'The excerpt');
      expect(body['slug'], 'rich-article');
      expect(body['status'], 'publish');
      expect(body['title'], 'Rich title');
    });

    test('a draft article stays a draft; the post\'s own "Publish as" wins', () async {
      final draft = richArticle.copyWith(status: ArticleStatus.draft);
      expect((await publish(_post(article: draft))).$2['status'], 'draft');
      final forced = await publish(_post(article: draft, overrides: const [
        PostOverrides(extra: {'status': 'publish', 'excerpt': 'Mine'}),
      ]));
      expect(forced.$2['status'], 'publish');
      expect(forced.$2['excerpt'], 'Mine');
    });

    test('regression: a post without an article goes out exactly as before', () async {
      Map<String, dynamic>? sent;
      final ctx = testContext(handler: (r) async {
        if (r.url.path == '/wp-json/wp/v2/posts') {
          sent = bodyOf(r);
          return _json({'id': 7, 'status': 'publish'}, 201);
        }
        return _json(<Object>[]);
      });
      await wp.publish(const PostVariant(text: 'Hello\n\nWorld', title: 'T'), account, const {'app_password': 'pw'}, ctx);
      expect(sent!['content'], '<p>Hello</p>\n\n<p>World</p>');
    });

    test('hand-off: the article is on the clipboard as HTML too', () {
      final ho = fakeAccount('wordpress', tier: PlatformTier.handoff);
      final plan = wp.buildHandoff(_resolve(wp, ho), account: ho)!;
      expect(plan.clipboardHtml, startsWith('<p>[Photo: c1.jpg]</p>'));
      expect(plan.clipboardHtml, contains('<strong>bold</strong>'));
    });
  });

  group('Ghost request', () {
    final ghost = GhostAdapter();
    final account = fakeAccount('ghost', config: {'apiUrl': 'https://blog.example.com', 'site': 'https://blog.example.com/'});
    const secrets = {'admin_api_key': '6489d8a1b2c3d4e5f6a7b8c9:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'};

    test('card HTML, feature image with alt and caption, subtitle as the excerpt', () async {
      Map<String, dynamic>? post;
      final paths = <String>[];
      var n = 0;
      final ctx = testContext(handler: (r) async {
        paths.add('${r.method} ${r.url.path}${r.url.query.isEmpty ? '' : '?${r.url.query}'}');
        if (r.url.path.endsWith('/images/upload/')) return _json({'images': [{'url': 'https://blog.example.com/content/images/${n++}.jpg'}]}, 201);
        if (r.url.path.endsWith('/media/upload/')) return _json({'media': [{'url': 'https://blog.example.com/content/media/a.mp3'}]}, 201);
        post = Map<String, dynamic>.from((bodyOf(r)['posts'] as List).single as Map<String, dynamic>);
        return _json({'posts': [{'id': 'abc', 'status': 'published', 'url': 'https://blog.example.com/rich/'}]}, 201);
      });
      final noExcerpt = richArticle.copyWith(clearExcerpt: true);
      final v = _resolve(ghost, account, post: _post(article: noExcerpt));
      // Ghost takes no video: its block is reported before posting.
      expect(v.issues.map((i) => i.code), contains('article.media_unavailable'));
      final res = await ghost.publish(v, account, secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(paths.last, 'POST /ghost/api/admin/posts/?source=html');
      expect(post!['feature_image'], 'https://blog.example.com/content/images/0.jpg');
      expect(post!['feature_image_alt'], 'Cover alt');
      expect(post!['feature_image_caption'], 'Cover caption');
      expect(post!['custom_excerpt'], 'A subtitle');
      expect(post!['canonical_url'], 'https://origin.example/rich');
      expect(post!['slug'], 'rich-article');
      final html = post!['html'] as String;
      expect(html, contains('kg-gallery-card'));
      expect(html, contains('kg-audio-card'));
      expect(html, isNot(contains('<video')));
    });
  });

  group('EmDash request', () {
    final emdash = EmDashAdapter();
    final account = fakeAccount('emdash', config: {'site': 'https://blog.example'});
    const secrets = {'access_token': 'ec_pat_0123456789abcdefghijklmnopqrstuvwxyz', 'token_type': 'personal-access-token'};

    test('Portable Text with image, gallery and video blocks; the cover is the featured image', () async {
      Map<String, dynamic>? data;
      var n = 0;
      final ctx = testContext(handler: (r) async {
        final path = r.url.path;
        if (r.method == 'POST' && path == '/_emdash/api/media') {
          n++;
          return _json({'success': true, 'data': {'item': {'id': 'm$n', 'url': '/_emdash/api/media/file/m$n', 'filename': 'f$n', 'mimeType': 'image/jpeg'}}}, 201);
        }
        if (path == '/_emdash/api/taxonomies/tag/terms') return _json({'success': true, 'data': {'terms': <Object>[]}});
        if (path.startsWith('/_emdash/api/taxonomies')) return _json({'success': true, 'data': {'term': {'slug': 'x'}}}, 201);
        if (r.method == 'POST' && path == '/_emdash/api/content/posts') {
          data = Map<String, dynamic>.from(bodyOf(r)['data'] as Map<String, dynamic>);
          return _json({'success': true, 'data': {'item': {'id': 'P1', 'slug': 'rich-article', 'status': 'draft'}}}, 201);
        }
        return _json({'success': true, 'data': <String, Object>{}});
      });
      final v = _resolve(emdash, account);
      final res = await emdash.publish(v, account, secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      final content = (data!['content'] as List).cast<Map<String, dynamic>>();
      expect(content.map((b) => b['_type']).toSet(), {'block', 'image', 'gallery', 'video', 'code', 'break'});
      final prefix = emdashKeyPrefix(emdashPostKey(account, v));
      expect(content.every((b) => '${b['_key']}'.startsWith(prefix)), isTrue);
      expect((data!['featured_image'] as Map<String, dynamic>)['id'], 'm1');
      expect((data!['featured_image'] as Map<String, dynamic>)['alt'], 'Cover alt');
      expect(data!['excerpt'], 'The excerpt');
      expect(res.remoteUrl, 'https://blog.example/posts/rich-article');
    });
  });

  group('Markdown networks', () {
    test('WriteFreely: one Markdown body, photos on the media host, sound as a link, tags as hashtags', () async {
      final host = FakeMediaHost();
      Map<String, dynamic>? sent;
      final ctx = testContext(
          mediaHost: host,
          handler: (r) async {
            sent = bodyOf(r);
            return _json({'data': {'id': 'w1', 'slug': 'rich'}}, 201);
          });
      final account = fakeAccount('writefreely',
          config: {'instance': 'https://write.as', 'anonymous': false, 'alias': 'alice', 'collectionUrl': 'https://write.as/alice/'});
      final a = WriteFreelyAdapter();
      final res = await a.publish(_resolve(a, account), account, const {'access_token': 'tok', 'token_type': 'Token'}, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      final body = sent!['body'] as String;
      expect(body, startsWith('![Cover alt](https://cdn.example.test/c1)'));
      expect(body, contains('[The track](https://cdn.example.test/a1)'));
      expect(body, endsWith('#dart #news'));
      expect(sent!['slug'], 'rich-article');
      expect(host.uploaded.map((m) => m.id), ['c1', 'i1', 'g1', 'g2', 'g3', 'a1']);
    });

    test('DEV: body_markdown, the cover as main_image, the excerpt as description, a draft unpublished', () async {
      Map<String, dynamic>? article;
      final ctx = testContext(
          mediaHost: FakeMediaHost(),
          handler: (r) async {
            article = Map<String, dynamic>.from(bodyOf(r)['article'] as Map<String, dynamic>);
            return _json({'id': 5, 'url': 'https://dev.to/alice/rich'}, 201);
          });
      final account = fakeAccount('devto', config: {'base': 'https://dev.to'});
      final a = DevtoAdapter();
      final post = _post(article: richArticle.copyWith(status: ArticleStatus.draft));
      final res = await a.publish(_resolve(a, account, post: post), account, const {'access_token': 'K', 'token_type': 'api-key'}, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(article!['main_image'], 'https://cdn.example.test/c1');
      expect(article!['description'], 'The excerpt');
      expect(article!['canonical_url'], 'https://origin.example/rich');
      expect(article!['published'], isFalse);
      expect(article!['body_markdown'], contains('{% embed https://www.youtube.com/watch?v=dQw4w9WgXcQ %}'));
      expect(article!['body_markdown'], isNot(contains('cdn.example.test/c1')));
    });

    test('Hashnode: contentMarkdown with uploaded photos, subtitle, slug, originalArticleURL, cover', () async {
      Map<String, dynamic>? input;
      var k = 0;
      final ctx = testContext(
          mediaHost: FakeMediaHost(),
          handler: (r) async {
            if (r.method == 'PUT') return http.Response('', 200);
            final body = bodyOf(r);
            final q = body['query'] as String;
            if (q.contains('createImageUploadURL')) {
              k++;
              return _json({
                'data': {
                  'createImageUploadURL': {'presignedPut': {'url': 'https://s3.example.test/$k', 'cdnUrl': 'https://cdn.hashnode.com/$k', 'key': 'k$k'}},
                },
              });
            }
            if (q.contains('confirmImageUpload')) {
              return _json({'data': {'confirmImageUpload': {'ok': true, 'cdnUrl': 'https://cdn.hashnode.com/res/${((body['variables'] as Map<String, dynamic>)['input'] as Map<String, dynamic>)['key']}'}}});
            }
            input = Map<String, dynamic>.from((body['variables'] as Map<String, dynamic>)['input'] as Map<String, dynamic>);
            return _json({'data': {'publishPost': {'post': {'id': 'h1', 'url': 'https://alice.hashnode.dev/rich'}}}});
          });
      final account = fakeAccount('hashnode', tier: PlatformTier.byokApi, config: {'publicationId': 'pub1'});
      final a = HashnodeAdapter();
      final res = await a.publish(_resolve(a, account), account, const {'access_token': 'PAT', 'token_type': 'PAT'}, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(input!['coverImage'], 'https://cdn.hashnode.com/res/k1');
      expect(input!['subtitle'], 'A subtitle');
      expect(input!['slug'], 'rich-article');
      expect(input!['originalArticleURL'], 'https://origin.example/rich');
      final md = input!['contentMarkdown'] as String;
      expect(md, contains('![Ref alt](https://cdn.hashnode.com/res/k2)'));
      expect(md, contains('%[https://www.youtube.com/watch?v=dQw4w9WgXcQ]'));
    });
  });

  group('Micropub request', () {
    test('JSON syntax: content html with the files in place, name, summary, category, featured, mp-slug', () async {
      Map<String, dynamic>? sent;
      final uploads = <String>[];
      var n = 0;
      final ctx = testContext(handler: (r) async {
        if (r.url.path == '/media') {
          n++;
          uploads.add('$n');
          return http.Response('', 201, headers: {'location': 'https://alice.example/media/$n'});
        }
        expect(r.headers['content-type'], startsWith('application/json'));
        sent = bodyOf(r);
        return http.Response('', 201, headers: {'location': 'https://alice.example/2026/rich'});
      });
      final account = fakeAccount('micropub',
          config: {'micropubEndpoint': 'https://alice.example/micropub', 'mediaEndpoint': 'https://alice.example/media'});
      final a = MicropubAdapter();
      final post = _post(article: richArticle.copyWith(status: ArticleStatus.draft));
      final res = await a.publish(_resolve(a, account, post: post), account, const {'access_token': 'AT', 'token_type': 'Bearer'}, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteUrl, 'https://alice.example/2026/rich');
      expect(sent!['type'], ['h-entry']);
      final props = sent!['properties'] as Map<String, dynamic>;
      expect(props['name'], ['Rich title']);
      expect(props['summary'], ['The excerpt']);
      expect(props['category'], ['dart', 'news']);
      expect(props['featured'], ['https://alice.example/media/1']);
      expect(props['photo'], [
        {'value': 'https://alice.example/media/1', 'alt': 'Cover alt'},
      ]);
      expect(props['mp-slug'], ['rich-article']);
      expect(props['post-status'], ['draft']);
      final html = ((props['content'] as List).single as Map<String, dynamic>)['html'] as String;
      expect(html, contains('<img src="https://alice.example/media/2" alt="Ref alt">'));
      expect(html, contains('<video controls src="https://alice.example/media/6">'));
      expect(html, contains('<audio controls src="https://alice.example/media/7">'));
      expect(uploads, hasLength(7));
    });
  });

  group('Tumblr request', () {
    test('NPF content and layout, every file one multipart part, the article\'s slug and canonical source', () async {
      http.Request? sent;
      final ctx = testContext(
          mediaHost: FakeMediaHost(),
          handler: (r) async {
            sent = r;
            return _json({'meta': {'status': 201}, 'response': {'id': '99'}}, 201);
          });
      final account = fakeAccount('tumblr',
          tier: PlatformTier.byokApi,
          id: 'tumblr:t:x',
          config: {'consumerKey': 'ck', 'blogName': 'myblog', 'blogUuid': 't:x', 'redirectUri': 'http://127.0.0.1:52771/callback'});
      final secrets = {
        'consumer_secret': 'cs',
        'access_token': 'AT',
        'token_type': 'bearer',
        'expires_at': testNow.add(const Duration(minutes: 30)).toUtc().toIso8601String(),
        'refresh_token': 'RT',
      };
      final a = TumblrAdapter();
      final res = await a.publish(_resolve(a, account), account, secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      final fields = multipartFieldsOf(sent!);
      // Six files: the cover, the photo, three gallery photos, the video; the
      // sound file is a link on the media host.
      expect(fields.keys, ['json', 'media0', 'media1', 'media2', 'media3', 'media4', 'media5']);
      final json = Map<String, dynamic>.from(jsonDecode(fields['json']!) as Map<String, dynamic>);
      final content = (json['content'] as List).cast<Map<String, dynamic>>();
      expect(content.first, {'type': 'text', 'subtype': 'heading1', 'text': 'Rich title'});
      expect(content.where((b) => b['type'] == 'image'), hasLength(5));
      expect(content.where((b) => b['type'] == 'link').map((b) => b['url']), contains('https://cdn.example.test/a1'));
      expect(json['layout'], isNotNull);
      expect(json['slug'], 'rich-article');
      expect(json['source_url'], 'https://origin.example/rich');
      expect(json['tags'], 'dart,news');
    });
  });

  group('X Articles', () {
    final x = XAdapter();
    ConnectedAccount account({Map<String, dynamic> extra = const {}, PlatformTier tier = PlatformTier.byokApi}) => ConnectedAccount(
          id: 'x-42',
          platformId: 'x',
          tier: tier,
          displayName: 'Alice (@alice)',
          handle: '@alice',
          createdAt: testNow,
          config: {'authMode': 'oauth2', 'clientId': 'cid', 'userId': '42', ...extra},
        );
    final secrets = {
      'access_token': 'at-1',
      'refresh_token': 'rt-1',
      'expires_at': testNow.add(const Duration(days: 30)).toUtc().toIso8601String(),
      'token_type': 'bearer',
    };

    test('X gets the short version unless the target or the account opts into an Article', () {
      expect(_resolve(x, account()).article, isNull);
      final opted = _resolve(x, account(), post: _post(overrides: const [PostOverrides(extra: {kXArticleKey: true})]));
      expect(opted.article, isNotNull);
      // The 280-character limit is the short post's, not the Article's.
      expect(x.validate(opted, account()).where((i) => i.code == 'text.too_long'), isEmpty);
      final byAccount = _resolve(x, account(extra: {
        'postDefaults': {kXArticleKey: true},
      }));
      expect(byAccount.article, isNotNull);
      final turnedOff = _resolve(x, account(extra: {
        'postDefaults': {kXArticleKey: true},
      }), post: _post(overrides: const [PostOverrides(extra: {kXArticleKey: false})]));
      expect(turnedOff.article, isNull);
      expect(_resolve(x, account(tier: PlatformTier.handoff), post: _post(overrides: const [PostOverrides(extra: {kXArticleKey: true})])).article,
          isNull);
    });

    test('photos uploaded, the draft created with their media ids, then published as a post', () async {
      final calls = <String>[];
      Map<String, dynamic>? draft;
      var n = 0;
      final ctx = testContext(handler: (r) async {
        calls.add('${r.method} ${r.url.path}');
        if (r.url.path == '/2/media/upload') return _json({'data': {'id': 'm${++n}'}});
        if (r.url.path == '/2/articles/draft') {
          draft = bodyOf(r);
          return _json({'data': {'id': 'A1', 'title': 'Rich title'}}, 201);
        }
        if (r.url.path == '/2/articles/A1/publish') return _json({'data': {'post_id': '777'}});
        return _json({'title': 'Not Found'}, 404);
      });
      final v = _resolve(x, account(), post: _post(overrides: const [PostOverrides(extra: {kXArticleKey: true})]));
      final res = await x.publish(v, account(), secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteUrl, 'https://x.com/alice/status/777');
      expect(calls.where((c) => c == 'POST /2/media/upload'), hasLength(v.media.where((m) => m.isImage).length));
      expect(calls.sublist(calls.length - 2), ['POST /2/articles/draft', 'POST /2/articles/A1/publish']);
      expect(draft!['title'], 'Rich title');
      expect(draft!['cover_media'], {'media_category': 'tweet_image', 'media_id': 'm1'});
      final entities = ((draft!['content_state'] as Map<String, dynamic>)['entities'] as List).cast<Map<String, dynamic>>();
      final image = entities.firstWhere((e) => (e['value'] as Map<String, dynamic>)['type'] == 'image')['value'] as Map<String, dynamic>;
      expect((image['data'] as Map<String, dynamic>)['media_items'], [
        {'media_category': 'tweet_image', 'media_id': 'm2'},
      ]);
    });

    test('a draft article is saved as a draft and not published', () async {
      final calls = <String>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r.url.path);
        if (r.url.path == '/2/media/upload') return _json({'data': {'id': 'm1'}});
        return _json({'data': {'id': 'A2'}}, 201);
      });
      const doc = ArticleDocument(status: ArticleStatus.draft, blocks: [ArticleParagraph('p', [ArticleSpan('Hello')])]);
      final v = _resolve(x, account(), post: _post(article: doc, overrides: const [PostOverrides(extra: {kXArticleKey: true})]));
      final res = await x.publish(v, account(), secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteId, 'A2');
      expect(calls, ['/2/articles/draft']);
    });
  });

  group('Substack hand-off', () {
    test('an article: rich clipboard, Markdown fallback, title and subtitle to copy, numbered steps', () {
      final a = SubstackAdapter();
      final account = fakeAccount('substack', tier: PlatformTier.handoff);
      final plan = a.buildHandoff(_resolve(a, account), account: account)!;
      expect(plan.clipboardHtml, contains('<h2>Intro &amp; &lt;setup&gt;</h2>'));
      expect(plan.clipboardText, contains('## Intro & \\<setup\\>'));
      expect(plan.snippets.map((s) => '${s.label}: ${s.text}'), ['Title: Rich title', 'Subtitle: A subtitle']);
      expect(plan.instructions, startsWith('1. '));
      expect(plan.desktopUrl, SubstackAdapter.articleUrl);
    });

    test('a note without an article is unchanged', () {
      final a = SubstackAdapter();
      final plan = a.buildHandoff(const PostVariant(text: 'A note'))!;
      expect(plan.clipboardText, 'A note');
      expect(plan.clipboardHtml, isNull);
      expect(plan.desktopUrl, SubstackAdapter.desktopUrl);
    });
  });
}
