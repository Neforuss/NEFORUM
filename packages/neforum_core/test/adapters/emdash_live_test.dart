// NEFORUM 1.4.3: EmDash against a real EmDash site. Skipped unless both
// variables are set, so CI never needs a site:
//
//   NEFORUM_EMDASH_LIVE_URL=http://localhost:4321
//   NEFORUM_EMDASH_LIVE_TOKEN=ec_pat_...   (Content Read, Content Write, Media Write)
//
// Made for a local EmDash dev site (`npm create emdash`, blog template). It
// creates posts on the site it is pointed at, so never point it at a real blog.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/blogs_a/emdash_adapter.dart';
import 'package:test/test.dart';

final String? _site = Platform.environment['NEFORUM_EMDASH_LIVE_URL'];
final String? _token = Platform.environment['NEFORUM_EMDASH_LIVE_TOKEN'];

Uint8List _png(int r, int g, int b) => img.encodePng(img.Image(width: 64, height: 48)..clear(img.ColorRgb8(r, g, b)));

void main() {
  final skip = _site == null || _token == null ? 'set NEFORUM_EMDASH_LIVE_URL and NEFORUM_EMDASH_LIVE_TOKEN to run it' : false;
  final adapter = EmDashAdapter();
  final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
  final files = {'red': _png(220, 40, 40), 'blue': _png(40, 60, 220)};

  AdapterContext ctx({int maxRetries = 0}) => AdapterContext(
        http: NeforumHttp(maxRetries: maxRetries),
        readMedia: (m) async => files[m.id]!,
      );

  Future<Map<String, dynamic>> apiGet(String path) async {
    final r = await http.get(Uri.parse('$_site/_emdash/api/$path'), headers: {'Authorization': 'Bearer $_token'});
    expect(r.statusCode, 200, reason: '$path: ${r.body}');
    return Map<String, dynamic>.from((jsonDecode(r.body) as Map)['data'] as Map);
  }

  MediaAttachment photo(String id, String alt) => MediaAttachment(
        id: id,
        path: '/nowhere/$id.png',
        mimeType: 'image/png',
        sizeBytes: files[id]!.length,
        width: 64,
        height: 48,
        altText: alt,
        fileName: '$id.png',
      );

  late ConnectedAccount account;
  late Map<String, String> secrets;

  setUpAll(() async {
    if (skip != false) return;
    final result = await adapter.connect(PlatformTier.openApi, {'site': _site!, 'token': _token!}, ctx());
    account = result.account;
    secrets = result.secrets;
  });

  test('connect reads the site and keeps the token as an access token', () {
    expect(account.platformId, 'emdash');
    expect(account.config['site'], Uri.parse(_site!).replace(path: '').toString().replaceAll(RegExp(r'/$'), ''));
    expect(account.config['version'], isNotNull);
    expect(account.displayName, isNotEmpty);
    expect(secrets[OAuthTokens.keyAccessToken], _token);
  }, skip: skip);

  test('a post with Markdown, two photos and tags goes live and reads back as sent; a retry finishes it, never twice', () async {
    final title = 'NEFORUM live $stamp';
    final variant = PostVariant(
      title: title,
      text: '## Live check\n\nHello **bold** and *em* with [a link](https://example.com/live).\n\n'
          '- one\n- two\n\n> quoted\n\n```dart\nprint("x");\n```\n\n<b>not html</b>',
      tags: ['neforum-live', 'Brand New $stamp'],
      media: [photo('red', 'A red square'), photo('blue', 'A blue square')],
      sourcePostId: 'live-$stamp',
    );
    final first = await adapter.publish(variant, account, secrets, ctx());
    expect(first.success, isTrue, reason: '${first.error?.message} ${first.error?.raw}');
    expect(first.notice, isNull);
    final slug = emdashSlug(title);
    expect(first.remoteUrl, '${account.config['site']}/posts/$slug');

    final item = Map<String, dynamic>.from((await apiGet('content/posts/${first.remoteId}'))['item'] as Map);
    expect(item['status'], 'published');
    expect(item['slug'], slug);
    final data = Map<String, dynamic>.from(item['data'] as Map);
    expect(data['title'], title);
    final featured = Map<String, dynamic>.from(data['featured_image'] as Map);
    expect((featured['provider'], featured['alt'], featured['mimeType']), ('local', 'A red square', 'image/png'));
    final content = [for (final b in data['content'] as List) Map<String, dynamic>.from(b as Map)];
    expect([for (final b in content) b['_type']], ['block', 'block', 'block', 'block', 'block', 'code', 'block', 'image']);
    expect(content.first['style'], 'h2');
    final image = content.last;
    expect(image['alt'], 'A blue square');
    expect((image['asset'] as Map)['url'], startsWith('/_emdash/api/media/file/'));

    final terms = await apiGet('content/posts/${first.remoteId}/terms/tag');
    expect([for (final t in terms['terms'] as List) (t as Map)['slug']]..sort(), ['brand-new-$stamp', 'neforum-live']);

    final page = await http.get(Uri.parse(first.remoteUrl!));
    expect(page.statusCode, 200);
    expect(page.body, contains('<strong>bold</strong>'));
    expect(page.body, contains('href="https://example.com/live"'));
    expect(page.body, contains('&lt;b&gt;not html&lt;/b&gt;'));
    expect(page.body, isNot(contains('<b>not html</b>')));
    final file = await http.get(Uri.parse('$_site${(image['asset'] as Map)['url']}'));
    expect((file.statusCode, file.headers['content-type']), (200, 'image/png'));

    // The same post again, as a retry after a lost answer would send it.
    final again = await adapter.publish(variant, account, secrets, ctx());
    expect(again.success, isTrue, reason: '${again.error?.message} ${again.error?.raw}');
    expect(again.remoteId, first.remoteId);
    expect(again.remoteUrl, first.remoteUrl);
    expect(again.notice, contains('earlier try'));
    final listed = await apiGet('content/posts?q=${Uri.encodeQueryComponent(title)}&limit=10');
    expect([for (final p in listed['items'] as List) (p as Map)['id']], [first.remoteId], reason: 'one post, not two');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('a video plays in the post and an image line by address shows; the page still renders', () async {
    files['clip'] = Uint8List.fromList(List.filled(2048, 7));
    final variant = PostVariant(
      title: 'NEFORUM video $stamp',
      text: 'Before.\n\n![A remote picture](https://example.com/remote.png)\n\nAfter.',
      media: [MediaAttachment(id: 'clip', path: '/nowhere/clip.mp4', mimeType: 'video/mp4', sizeBytes: 2048, width: 640, height: 360, fileName: 'clip.mp4')],
      sourcePostId: 'video-$stamp',
    );
    final res = await adapter.publish(variant, account, secrets, ctx());
    expect(res.success, isTrue, reason: '${res.error?.message} ${res.error?.raw}');
    final data = Map<String, dynamic>.from((Map<String, dynamic>.from((await apiGet('content/posts/${res.remoteId}'))['item'] as Map))['data'] as Map);
    expect(data.containsKey('featured_image'), isFalse, reason: 'a video is never the featured image');
    expect([for (final b in data['content'] as List) (b as Map)['_type']], ['block', 'image', 'block', 'video']);
    final page = await http.get(Uri.parse(res.remoteUrl!));
    expect(page.statusCode, 200);
    expect(page.body, contains('<video'));
    expect(page.body, contains('https://example.com/remote.png'));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  test('a slug taken by another post: the post goes to the slug with its key, and a retry finds it there', () async {
    final title = 'NEFORUM taken $stamp';
    final slug = emdashSlug(title);
    final other = await http.post(Uri.parse('$_site/_emdash/api/content/posts'),
        headers: {'Authorization': 'Bearer $_token', 'Content-Type': 'application/json'},
        body: jsonEncode({
          'data': {'title': title},
          'slug': slug,
        }));
    expect(other.statusCode, 201, reason: other.body);
    final variant = PostVariant(title: title, text: 'Mine.', sourcePostId: 'taken-$stamp');
    final key = emdashPostKey(account, variant);
    final first = await adapter.publish(variant, account, secrets, ctx());
    expect(first.success, isTrue, reason: '${first.error?.message} ${first.error?.raw}');
    expect(first.remoteUrl, '${account.config['site']}/posts/${emdashFallbackSlug(slug, key)}');
    final again = await adapter.publish(variant, account, secrets, ctx());
    expect((again.success, again.remoteId), (true, first.remoteId));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  test('publish as draft leaves a draft and links its editor', () async {
    final draftAccount = account.copyWith(config: {...account.config, 'defaultStatus': 'draft'});
    final res = await adapter.publish(PostVariant(title: 'NEFORUM draft $stamp', text: 'Draft.', sourcePostId: 'draft-$stamp'), draftAccount, secrets, ctx());
    expect(res.success, isTrue, reason: '${res.error?.message} ${res.error?.raw}');
    expect(res.remoteUrl, '${account.config['site']}/_emdash/admin/content/posts/${res.remoteId}');
    final item = Map<String, dynamic>.from((await apiGet('content/posts/${res.remoteId}'))['item'] as Map);
    expect(item['status'], 'draft');
  }, skip: skip);

  test('a revoked or wrong token is refused at connect, on the token field', () async {
    await expectLater(
      adapter.connect(PlatformTier.openApi, {'site': _site!, 'token': 'ec_pat_${'x' * 40}'}, ctx()),
      throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'token')),
    );
  }, skip: skip);
}
