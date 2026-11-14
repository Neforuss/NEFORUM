// What the character panel inserts reaches every network as inserted: each
// adapter in the registry, through the resolver (where per-network transforms
// run) and, for hand-off networks, into the hand-off plan. No NFKC anywhere:
// ① Ⓐ 𝐁 ｆ ㎏ must not turn into 1 A B f kg. Kaomoji show as themselves on
// Markdown networks too.
import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../support/test_context.dart';
import 'catalog_files.dart';

/// The symbols NFKC would change, and every non-ASCII character a text style
/// makes (styled letters, upside-down letters, combining-mark styles).
/// Non-ASCII, so no Markdown network has anything to escape in them.
List<String> nfkcSensitiveProbe() {
  final catalog = bundledCatalog;
  final ts = catalog.textStyles;
  final out = <String>{};
  for (final g in catalog.groups(CharacterTab.symbols).where((g) => g.isBlock)) {
    for (final e in g.entries) {
      if (unorm.nfkc(e.text) != e.text) out.add(e.text);
    }
  }
  for (final kind in TextStyleKind.values) {
    for (final c in ts.apply(kind, 'AaZz09').characters) {
      if (c.runes.any((r) => r > 0x7F)) out.add(c);
    }
  }
  out.addAll(ts.upsideDownMap.values.where((v) => v.runes.any((r) => r > 0x7F)));
  return out.toList();
}

/// [items] packed into posts that each fit [rules] (and stay short), joined
/// with a space.
List<String> packed(List<String> items, TextRules rules, {int maxItems = 40}) {
  final posts = <String>[];
  var current = <String>[];
  bool fits(List<String> xs) => TextCounter.fits(xs.join(' '), rules);
  for (final item in items) {
    if (current.isNotEmpty && (current.length >= maxItems || !fits([...current, item]))) {
      posts.add(current.join(' '));
      current = [];
    }
    current.add(item);
  }
  if (current.isNotEmpty) posts.add(current.join(' '));
  return posts;
}

Post _post(String text) => Post(id: 'p', text: text, createdAt: testNow, updatedAt: testNow, targets: const [PostTarget(accountId: 'acct-1')]);

/// Every place a hand-off plan carries the post's text.
String _planText(HandoffPlan p) => [
      p.clipboardText ?? '',
      p.shareText ?? '',
      for (final s in p.snippets) s.text,
      if (p.webIntent != null) Uri.decodeFull(p.webIntent.toString()),
      if (p.composerUrl != null) Uri.decodeFull(p.composerUrl.toString()),
    ].join('\n');

/// API networks whose post call cannot be reached with text alone: they need
/// a photo or video first (or, for Nostr, a relay socket). The resolver and
/// validator tests above still cover their text.
const Set<String> _wireNeedsMoreThanText = {
  'nostr', 'instagram', 'tiktok', 'pinterest', 'youtube', 'odysee', //
  'deviantart', 'dribbble', 'pixelfed', 'flickr', 'inkbunny',
};

/// One account setting and one secret of every name the text-capable API
/// adapters read, so each gets to its post call without its connect flow.
const Map<String, Object> _wireConfig = {
  'instance': 'https://example.test',
  'host': 'example.test',
  'baseUrl': 'https://example.test',
  'site': 'https://example.test',
  'apiUrl': 'https://example.test',
  'restBase': 'https://example.test/wp-json/',
  'homeserver': 'https://example.test',
  'endpoint': 'https://example.test/micropub',
  'micropubEndpoint': 'https://example.test/micropub',
  'pds': 'https://pds.example.test',
  'service': 'https://pds.example.test',
  'did': 'did:plc:test',
  'handle': 'test.example.test',
  'chatId': '1',
  'roomId': '!room:example.test',
  'community': 'test',
  'communityId': 1,
  'publicationId': '1',
  'defaultSubreddit': 'test',
  'blogName': 'test',
  'user_id': '1',
  'page_id': '1',
  'personUrn': 'urn:li:person:1',
  'username': 'test',
  'alias': 'test',
};

const Map<String, String> _wireSecrets = {
  'access_token': 'token',
  'refresh_token': 'refresh',
  'expires_at': '2099-01-01T00:00:00Z',
  'token': 'token',
  'bot_token': '123:token',
  'webhook_url': 'https://discord.com/api/webhooks/123456789012345678/AbCdEfGhIjKlMnOpQrStUvWx',
  'jwt': 'token',
  'app_password': 'password',
  'client_id': 'client',
  'client_secret': 'secret',
  'admin_api_key': '0123456789abcdef01234567:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  'oauth_token': 'token',
  'oauth_token_secret': 'secret',
};

/// Everything a request carries, as text: the address (decoded), the body,
/// and a form body's values decoded.
String _requestText(http.Request r) {
  final out = StringBuffer(Uri.decodeFull(r.url.toString()))..writeln();
  out.writeln(utf8.decode(r.bodyBytes, allowMalformed: true));
  if ((r.headers['content-type'] ?? '').contains('x-www-form-urlencoded')) out.writeln(Uri.splitQueryString(r.body).values.join('\n'));
  return out.toString();
}

void main() {
  final adapters = builtinAdapters();
  final probe = nfkcSensitiveProbe();

  group('on the wire', () {
    final api = [for (final a in adapters) if (a.descriptor.tiers.any((t) => t != PlatformTier.handoff)) a];

    test('every API network is either sent the probe below or listed as needing media', () {
      expect(_wireNeedsMoreThanText.difference({for (final a in api) a.id}), isEmpty);
      expect(api.where((a) => !_wireNeedsMoreThanText.contains(a.id)).length, greaterThanOrEqualTo(19));
    });

    for (final a in api.where((a) => !_wireNeedsMoreThanText.contains(a.id))) {
      test('${a.id}: the post call carries every NFKC-sensitive character as inserted', () async {
        final tier = a.descriptor.defaultTier == PlatformTier.handoff ? a.descriptor.tiers.firstWhere((t) => t != PlatformTier.handoff) : a.descriptor.defaultTier;
        final account = fakeAccount(a.id, tier: tier, config: _wireConfig);
        final d = a.descriptorForAccount(account);
        for (final text in packed(probe, d.text)) {
          final sent = <String>[];
          final ctx = testContext(handler: (r) async {
            sent.add(_requestText(r));
            return http.Response(
                jsonEncode({'id': '1', 'uri': 'at://did:plc:test/app.bsky.feed.post/1', 'cid': 'c', 'ok': true, 'status': 'FINISHED', 'result': {'message_id': 1}, 'event_id': '1'}), 200,
                headers: jsonHeaders);
          });
          final post = Post(id: 'p', text: text, title: 'A title', createdAt: testNow, updatedAt: testNow, targets: const [PostTarget(accountId: 'acct-1')]);
          final v = const VariantResolver().resolve(post, post.targets.single, d, account: account);
          await a.publish(v, account, _wireSecrets, ctx);
          expect(sent, isNotEmpty, reason: 'no request was made');
          expect(sent.any((s) => s.contains(text)), isTrue, reason: 'the text did not go out as inserted');
        }
      });
    }
  });

  test('the probe is the hard case: over a thousand characters NFKC would change, and every styled one', () {
    expect(probe.where((c) => unorm.nfkc(c) != c).length, greaterThan(1000));
    expect(probe, containsAll(['①', 'Ⓐ', '\u{1D400}', 'ｆ', '㎏', '™', '½', '🅐', 'ᴀ', 'ɐ']));
    expect(probe.where((c) => c.runes.every((r) => r <= 0x7F)), isEmpty);
  });

  for (final a in adapters) {
    group(a.id, () {
      final d = a.descriptor;
      final tier = d.tiers.contains(PlatformTier.handoff) && d.tiers.length == 1 ? PlatformTier.handoff : d.defaultTier;
      final account = fakeAccount(a.id, tier: tier);

      test('every NFKC-sensitive character arrives unchanged', () {
        for (final text in packed(probe, a.descriptorForAccount(account).text)) {
          final v = const VariantResolver().resolve(_post(text), const PostTarget(accountId: 'acct-1'), a.descriptorForAccount(account), account: account);
          expect(v.isThread, isFalse);
          expect(v.text, text);
          expect(a.validate(v, account).where((i) => i.code == 'text.too_long'), isEmpty);
          if (d.tiers.contains(PlatformTier.handoff)) {
            final plan = a.buildHandoff(v, account: fakeAccount(a.id, tier: PlatformTier.handoff));
            if (plan != null && _planText(plan).trim().isNotEmpty) {
              expect(_planText(plan), contains(text), reason: 'the hand-off carries it as is');
            }
          }
        }
      });

      test('every kaomoji shows as itself', () {
        final dialect = NetworkTextTransforms.dialectOf(d);
        for (final text in packed(allKaomoji, a.descriptorForAccount(account).text, maxItems: 12)) {
          final v = const VariantResolver().resolve(_post(text), const PostTarget(accountId: 'acct-1'), a.descriptorForAccount(account), account: account);
          expect(v.isThread, isFalse);
          switch (dialect) {
            case MarkdownDialect.none:
            case MarkdownDialect.chat:
              expect(v.text, text);
            case MarkdownDialect.commonMark:
              expect(renderedCommonMark(v.text, gfm: true), text);
            case MarkdownDialect.mfm:
              expect(v.text.replaceAll('<plain>', '').replaceAll('</plain>', ''), text);
          }
        }
      });
    });
  }
}
