// NEFORUM 1.4.4: an article posted to a real WordPress as a draft, read back
// and its blocks parsed by WordPress itself. Skipped unless the variables are
// set, so CI never needs a site:
//
//   NEFORUM_WP_LIVE_URL=http://127.0.0.1:9400
//   NEFORUM_WP_LIVE_USER=admin
//   NEFORUM_WP_LIVE_PASSWORD=<application password>
//
// Made for WordPress Playground (`npx @wp-playground/cli@latest server` with a
// blueprint that sets WP_ENVIRONMENT_TYPE=local and makes an application
// password). It creates draft posts on the site it is pointed at, so never
// point it at a real blog.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/blogs_a/wordpress_adapter.dart';
import 'package:test/test.dart';

final String? _site = Platform.environment['NEFORUM_WP_LIVE_URL'];
final String? _user = Platform.environment['NEFORUM_WP_LIVE_USER'];
final String? _password = Platform.environment['NEFORUM_WP_LIVE_PASSWORD'];

Uint8List _png(int r, int g, int b) => img.encodePng(img.Image(width: 64, height: 48)..clear(img.ColorRgb8(r, g, b)));

void main() {
  final skip = _site == null || _user == null || _password == null ? 'set NEFORUM_WP_LIVE_URL, _USER and _PASSWORD to run it' : false;
  final wp = WordPressAdapter();
  final files = {'cover': _png(220, 40, 40), 'photo': _png(40, 60, 220), 'g1': _png(40, 200, 60), 'g2': _png(200, 200, 40)};
  AdapterContext ctx() => AdapterContext(http: NeforumHttp(maxRetries: 0), readMedia: (m) async => files[m.id]!);
  MediaAttachment photo(String id) => MediaAttachment(
      id: id, path: '/nowhere/$id.png', mimeType: 'image/png', sizeBytes: files[id]!.length, width: 64, height: 48, altText: 'Alt $id', fileName: '$id.png');

  test('a draft article goes in as blocks WordPress parses, featured image, excerpt, slug', () async {
    final connected = await wp.connect(PlatformTier.openApi, {'site': _site!, 'username': _user!, 'password': _password!}, ctx());
    final account = connected.account;
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final doc = ArticleDocument(
      status: ArticleStatus.draft,
      cover: const ArticleMediaRef('cover', caption: 'Cover'),
      excerpt: 'Excerpt $stamp',
      slug: 'neforum-article-$stamp',
      blocks: const [
        ArticleHeading('h', [ArticleSpan('Heading')]),
        ArticleParagraph('p', [ArticleSpan('Some '), ArticleSpan('bold', marks: {ArticleMark.bold}), ArticleSpan(' text.')]),
        ArticleImage('i', ArticleMediaRef('photo', caption: 'A caption', credit: 'Someone')),
        ArticleGallery('g', [ArticleMediaRef('g1'), ArticleMediaRef('g2')], caption: 'Two'),
        ArticleQuote('q', [ArticleSpan('Quoted')], citation: 'Who'),
        ArticleList('l', [
          [ArticleSpan('one')],
          [ArticleSpan('two')],
        ], ordered: true),
        ArticleCode('c', 'print(1);', language: 'dart'),
        ArticleDivider('d'),
        // No embed: WordPress fetches its oEmbed while saving, which
        // Playground's sandboxed PHP cannot do (the request hangs).
      ],
    );
    final post = Post(
      id: 'live-$stamp',
      text: 'short',
      title: 'NEFORUM article $stamp',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      media: [for (final id in files.keys) photo(id)],
      article: doc,
      targets: [PostTarget(accountId: account.id)],
    );
    final v = const VariantResolver().resolve(post, post.targets.single, wp.descriptor, account: account);
    final res = await wp.publish(v, account, connected.secrets, ctx());
    expect(res.success, isTrue, reason: '${res.error}');

    final auth = 'Basic ${base64Encode(utf8.encode('$_user:${connected.secrets['app_password']}'))}';
    final base = account.configString('restBase');
    final r = await http.get(Uri.parse('${base}wp/v2/posts/${res.remoteId}?context=edit'), headers: {'Authorization': auth});
    expect(r.statusCode, 200, reason: r.body);
    final got = jsonDecode(r.body) as Map;
    expect(got['status'], 'draft');
    expect(got['slug'], 'neforum-article-$stamp');
    expect((got['excerpt'] as Map)['raw'], 'Excerpt $stamp');
    expect(got['featured_media'], isA<int>());
    expect(got['featured_media'], isNot(0));
    final content = got['content'] as Map;
    // Stored as sent, and WordPress itself reads it as blocks (block_version
    // is 1 only for content with block comments).
    expect(content['raw'], wp.descriptor.articleFormat == ArticleFormat.gutenberg ? isNotEmpty : isEmpty);
    expect(content['block_version'], 1);
    final rendered = content['rendered'] as String;
    expect(rendered, contains('<h2 class="wp-block-heading">Heading</h2>'));
    expect(rendered, contains('wp-block-gallery'));
    expect(rendered, contains('<figcaption class="wp-element-caption">A caption · Someone</figcaption>'));
    expect(rendered, contains('<cite>Who</cite>'));
    expect(rendered, contains('<ol class="wp-block-list">'));
    stdout.writeln('rendered:\n$rendered');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
