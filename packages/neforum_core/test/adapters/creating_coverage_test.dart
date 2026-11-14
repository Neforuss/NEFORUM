// Every API adapter's post call goes through the one place that knows what a lost
// answer means. A grep over the source, because the point is that nobody can add a
// post call beside it and forget: a 31st API adapter fails here until it is listed.

import 'dart:io';

import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/art/pixelfed_adapter.dart';
import 'package:neforum_core/src/adapters/mastodon/mastodon_adapter.dart';
import 'package:test/test.dart';

/// Each API adapter by id, and the file that holds its post call.
const Map<String, String> _postCallIn = {
  'mastodon': 'mastodon/mastodon_adapter.dart',
  'pixelfed': 'mastodon/mastodon_adapter.dart', // Through its parent.
  'bluesky': 'bluesky/bluesky_adapter.dart',
  'misskey': 'misskey/misskey_adapter.dart',
  'nostr': 'nostr/nostr_adapter.dart',
  'lemmy': 'lemmy/lemmy_adapter.dart',
  'matrix': 'chat/matrix_adapter.dart',
  'x': 'x/x_adapter.dart',
  'threads': 'threads/threads_adapter.dart',
  'facebook': 'facebook/facebook_adapter.dart',
  'linkedin': 'linkedin/linkedin_adapter.dart',
  'reddit': 'reddit/reddit_adapter.dart',
  'tumblr': 'tumblr/tumblr_adapter.dart',
  'instagram': 'instagram/instagram_api.dart',
  'tiktok': 'tiktok/tiktok_adapter.dart',
  'pinterest': 'pinterest/pinterest_api.dart',
  'youtube': 'youtube/youtube_api.dart',
  'odysee': 'video_sites/odysee_adapter.dart',
  'telegram': 'chat/telegram_adapter.dart',
  'discord': 'chat/discord_adapter.dart',
  'wordpress': 'blogs_a/wordpress_adapter.dart',
  'ghost': 'blogs_a/ghost_adapter.dart',
  'writefreely': 'blogs_a/writefreely_adapter.dart',
  'micropub': 'blogs_b/micropub_adapter.dart',
  'devto': 'blogs_b/devto_adapter.dart',
  'hashnode': 'blogs_b/hashnode_adapter.dart',
  'deviantart': 'art/deviantart_adapter.dart',
  'dribbble': 'art/dribbble_adapter.dart',
  'flickr': 'art/flickr_adapter.dart',
  'inkbunny': 'art/inkbunny_adapter.dart',
};

String _source(String path) => File('lib/src/adapters/$path').readAsStringSync();

void main() {
  test('the list holds every adapter that can post through an API, all 30', () {
    final api = {for (final a in builtinAdapters()) if (a.descriptor.tiers.any((t) => t != PlatformTier.handoff)) a.id};
    expect(api, _postCallIn.keys.toSet());
    expect(api, hasLength(30));
    expect(builtinAdapters().length - api.length, 20, reason: 'the rest are hand-off only and refuse to publish');
  });

  for (final entry in _postCallIn.entries) {
    test('${entry.key} wraps its post call', () {
      expect(_source(entry.value), contains(RegExp(r'\.creating(<[^>]*>)?\(')), reason: '${entry.value} has no ctx.creating call');
    });
  }

  test('Pixelfed posts through Mastodon, so it is covered by its parent', () {
    expect(PixelfedAdapter(), isA<MastodonAdapter>());
    expect(_source('art/pixelfed_adapter.dart'), isNot(contains('/api/v1/statuses')));
  });

  test('only a real dedupe key is exempt: Mastodon\'s Idempotency-Key and YouTube\'s session', () {
    final exempt = {
      for (final dir in Directory('lib/src/adapters').listSync(recursive: true).whereType<File>())
        if (dir.path.endsWith('.dart') && dir.readAsStringSync().contains('idempotent: true')) dir.uri.pathSegments.last,
    };
    expect(exempt, {'mastodon_adapter.dart', 'youtube_api.dart'});
  });

  test('no poll sleeps past Cancel: no bare delay left in a publish path', () {
    const left = <String>[];
    final found = <String>[];
    for (final f in Directory('lib/src/adapters').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final text = f.readAsStringSync();
      if (text.contains('Future<void>.delayed(') && !f.path.endsWith('adapter_context.dart') && !f.path.contains('chat_common') && !f.path.contains('threads_api') && !f.path.contains('instagram_adapter') && !f.path.contains('nostr_relay')) {
        found.add(f.uri.pathSegments.last);
      }
    }
    expect(found, left);
  });

  test('every media host call in an adapter goes through the run', () {
    final found = <String>[];
    final call = RegExp(r'host!?\.upload\(([^;]*);');
    for (final f in Directory('lib/src/adapters').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      for (final m in call.allMatches(f.readAsStringSync())) {
        if (!m.group(1)!.contains('via: ctx.http')) found.add('${f.uri.pathSegments.last}: ${m.group(0)}');
      }
    }
    expect(found, isEmpty);
  });
}
