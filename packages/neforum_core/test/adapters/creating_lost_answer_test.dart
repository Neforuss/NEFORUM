// The grep in creating_coverage_test.dart proves each adapter calls `creating`. This
// proves the call does its job on every adapter: a helper that turns a transport error
// into its own error inside the callback would hide the lost answer from `creating`,
// and the target would come back for a retry that posts twice.
//
// Each request made inside `creating` loses its answer. Everything else is answered,
// so each real adapter gets as far as its own post call.

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/instagram/instagram_adapter.dart';
import 'package:neforum_core/src/adapters/threads/threads_adapter.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

class _Inside implements CreateRecorder {
  bool now = false;
  int entered = 0;

  @override
  Future<void> begin() async {
    now = true;
    entered++;
  }

  @override
  Future<void> end({required bool mayBeLive}) async => now = false;
}

/// Enough of every network's answers for its calls before the post.
const Map<String, Object?> _answer = {
  'id': '1',
  'url': 'https://x.example/1',
  'ok': true,
  'stat': 'ok',
  'data': {
    'id': '1',
    'publish_id': 'pub1',
    'upload_url': 'https://upload.example/u',
    'privacy_level_options': ['PUBLIC_TO_EVERYONE', 'SELF_ONLY'],
    'creator_username': 'u',
    'max_video_post_duration_sec': 600,
    'publication': {'id': 'pub'},
    'publishPost': {'post': {'id': '1', 'url': 'https://x.example/1'}},
    'createImageUpload': {'url': 'https://upload.example/i', 'fields': <String, String>{}, 'key': 'k'},
    // EmDash: an uploaded file and a created draft.
    'item': {'id': '1', 'url': '/_emdash/api/media/file/1.jpg', 'slug': 'a-title', 'status': 'draft'},
  },
  'status': 'FINISHED',
  'status_code': 'FINISHED',
  'media_id': 'm1',
  'media_key': 'mk',
  'itemid': 1,
  'sid': 's',
  'submission_id': '5',
  'photoid': {'_content': '1'},
  'communities': <Object>[],
  'community_view': {'community': {'id': 12}},
  'post_view': {'post': {'id': 1, 'ap_id': 'https://x.example/1'}},
  'createdNote': {'id': 'n1'},
  'event_id': r'$e',
  'result': {'message_id': 1, 'chat': {'id': 1}},
  'uri': 'at://did/app.bsky.feed.post/1',
  'cid': 'c',
  'value': 'urn:li:x:1',
};

class _Case {
  const _Case(this.id, this.config, this.secrets, this.variant, {this.tier = PlatformTier.openApi, this.adapter, this.hosted = false, this.exempt = false, this.what = ''});

  final String id;
  final Map<String, dynamic> config;
  final Map<String, String> secrets;
  final PostVariant Function() variant;
  final PlatformTier tier;
  final PlatformAdapter? adapter;
  final bool hosted;

  /// A real dedupe key: sending it again is the same post.
  final bool exempt;

  /// Which of the network's post calls, when it has several.
  final String what;
}

PostVariant _text() => const PostVariant(text: 'Hello', title: 'A title');
PostVariant _photo() => PostVariant(text: 'Hello', title: 'A title', media: [fakeImage()]);
PostVariant _art() => PostVariant(text: 'Hello', title: 'A title', media: [fakeImage(width: 800, height: 600)], artwork: const ArtworkDetails(), tags: const ['a', 'b', 'c', 'd']);
PostVariant _clip() => PostVariant(text: 'Hello', title: 'A title', media: [fakeVideo(sizeBytes: 64)]);

const _bearer = {'access_token': 't', 'token_type': 'Bearer'};
const _mastodon = <String, dynamic>{'instance': 'https://m.example', 'domain': 'm.example', 'software': 'mastodon', 'maxCharacters': 500, 'maxMediaAttachments': 4, 'descriptionLimit': 1500};

final _oauth = {'access_token': 't', 'refresh_token': 'r', 'token_type': 'Bearer', 'expires_at': testNow.add(const Duration(days: 30)).toUtc().toIso8601String()};

final List<_Case> _cases = [
  _Case('mastodon', _mastodon, const {'client_id': 'c', 'client_secret': 's', ..._bearer}, _text, exempt: true),
  _Case('pixelfed', const {'instance': 'https://pix.example', 'domain': 'pix.example', 'software': 'pixelfed', 'maxCharacters': 500, 'maxMediaAttachments': 4, 'descriptionLimit': 1500}, const {'client_id': 'c', 'client_secret': 's', ..._bearer}, _art, exempt: true),
  _Case('bluesky', const {'did': 'did:plc:abc', 'pds': 'https://pds.example', 'handle': 'a.example'}, const {'access_token': 'x', 'refresh_token': 'y', 'accessJwt': 'x', 'refreshJwt': 'y'}, _text),
  _Case('misskey', const {'instance': 'https://misskey.example', 'host': 'misskey.example', 'maxNoteTextLength': 3000}, const {'access_token': 't'}, _text),
  _Case('lemmy', const {'instance': 'https://lemmy.example', 'community': 'music@lemmy.example', 'communityId': 12}, const {'jwt': 'j', 'access_token': 'j'}, _text),
  _Case('matrix', const {'homeserver': 'https://matrix.example.org', 'userId': '@a:example.org', 'roomId': '!r:example.org'}, const {'access_token': 't'}, _text),
  _Case('x', const {'clientId': 'c', 'confidentialClient': false, 'userId': '42'}, _oauth, _text, tier: PlatformTier.byokApi),
  _Case('threads', const {'app_id': '111', 'user_id': '123', 'redirect_uri': 'https://127.0.0.1:52771/callback'}, _oauth, _text, tier: PlatformTier.byokApi, adapter: ThreadsAdapter(delay: (_) async {})),
  _Case('facebook', const {'page_id': '123', 'app_id': '987654321', 'page_name': 'P'}, const {'access_token': 't', 'app_secret': 's'}, _text, tier: PlatformTier.byokApi),
  _Case('facebook', const {'page_id': '123', 'app_id': '987654321', 'page_name': 'P'}, const {'access_token': 't', 'app_secret': 's'}, _photo, tier: PlatformTier.byokApi, what: ' photo'),
  _Case('facebook', const {'page_id': '123', 'app_id': '987654321', 'page_name': 'P'}, const {'access_token': 't', 'app_secret': 's'}, _clip, tier: PlatformTier.byokApi, what: ' video'),
  _Case('telegram', const {'chatId': '-1001', 'chatType': 'channel', 'formatting': 'plain'}, const {'bot_token': '1:a'}, _photo, tier: PlatformTier.byokApi, what: ' photo'),
  _Case('discord', const {'guildId': 'g', 'channelId': 'c'}, const {'webhook_url': 'https://discord.com/api/webhooks/123456/abcdefghijklmnopqrstuvwxyz'}, _photo, tier: PlatformTier.byokApi, what: ' photo'),
  _Case('tumblr', const {'consumerKey': 'k', 'blogName': 'b', 'blogUuid': 't:u', 'username': 'u'}, _oauth, _photo, tier: PlatformTier.byokApi, what: ' photo'),
  _Case('micropub', const {'micropubEndpoint': 'https://alice.example/micropub'}, const {'access_token': 't'}, _photo, what: ' photo in the post'),
  _Case('x', const {'clientId': 'c', 'confidentialClient': false, 'userId': '42'}, _oauth, _photo, tier: PlatformTier.byokApi, what: ' photo'),
  _Case('threads', const {'app_id': '111', 'user_id': '123', 'redirect_uri': 'https://127.0.0.1:52771/callback'}, _oauth, _photo, tier: PlatformTier.byokApi, adapter: ThreadsAdapter(delay: (_) async {}), hosted: true, what: ' photo'),
  _Case('misskey', const {'instance': 'https://misskey.example', 'host': 'misskey.example', 'maxNoteTextLength': 3000}, const {'access_token': 't'}, _photo, what: ' photo'),
  _Case('linkedin', const {'authorUrn': 'urn:li:person:1', 'personUrn': 'urn:li:person:1'}, _oauth, _text, tier: PlatformTier.byokApi),
  _Case('reddit', const {'username': 'u', 'subreddit': 'test', 'defaultSubreddit': 'test'}, _oauth, _text, tier: PlatformTier.byokApi),
  _Case('tumblr', const {'consumerKey': 'k', 'blogName': 'b', 'blogUuid': 't:u', 'username': 'u'}, _oauth, _text, tier: PlatformTier.byokApi),
  _Case('instagram', const {'igUserId': '1784100', 'username': 'n'}, _oauth, _photo, tier: PlatformTier.byokApi, adapter: InstagramAdapter(sleep: (_) async {}), hosted: true),
  _Case('tiktok', const {'clientKey': 'ck', 'openId': 'o'}, _oauth, _clip, tier: PlatformTier.byokApi),
  _Case('tiktok', const {'clientKey': 'ck', 'openId': 'o'}, _oauth, _photo, tier: PlatformTier.byokApi, hosted: true, what: ' photos'),
  _Case('pinterest', const {'appId': 'a', 'boardId': '5', 'boardName': 'b', 'username': 'u', 'accessLevel': 'standard'}, _oauth, _photo, tier: PlatformTier.byokApi),
  _Case('youtube', const {'clientId': 'c'}, _oauth, _clip, tier: PlatformTier.byokApi, adapter: YouTubeAdapter(resumeDelay: Duration.zero)),
  _Case('odysee', const {'daemon': 'http://localhost:5279', 'channelId': 'c', 'bid': '0.01'}, const {}, _clip),
  _Case('telegram', const {'chatId': '-1001', 'chatType': 'channel', 'formatting': 'plain'}, const {'bot_token': '1:a'}, _text, tier: PlatformTier.byokApi),
  _Case('discord', const {'guildId': 'g', 'channelId': 'c'}, const {'webhook_url': 'https://discord.com/api/webhooks/123456/abcdefghijklmnopqrstuvwxyz'}, _text, tier: PlatformTier.byokApi),
  _Case('wordpress', const {'restBase': 'https://blog.example/wp-json/', 'username': 'u', 'site': 'https://blog.example'}, const {'app_password': 'p', 'username': 'u', 'application_password': 'p'}, _text),
  _Case('ghost', const {'apiUrl': 'https://blog.example.com', 'site': 'https://blog.example.com/'}, const {'admin_api_key': 'abcdef012345:00112233445566778899aabbccddeeff'}, _text),
  _Case('emdash', const {'site': 'https://blog.example'}, const {'access_token': 'ec_pat_abcdefghijklmnopqrstuvwxyz'}, _text),
  _Case('emdash', const {'site': 'https://blog.example'}, const {'access_token': 'ec_pat_abcdefghijklmnopqrstuvwxyz'}, _photo, what: ' photo'),
  _Case('emdash', const {'site': 'https://blog.example', 'defaultStatus': 'draft'}, const {'access_token': 'ec_pat_abcdefghijklmnopqrstuvwxyz'}, _text, what: ' draft'),
  _Case('writefreely', const {'instance': 'https://write.as', 'anonymous': true}, const {}, _text),
  _Case('micropub', const {'micropubEndpoint': 'https://alice.example/micropub'}, const {'access_token': 't'}, _text),
  _Case('devto', const {'instance': 'https://dev.to', 'username': 'u'}, const {'access_token': 'k', 'token_type': 'Bearer'}, _text),
  _Case('hashnode', const {'publicationId': 'pub', 'host': 'a.hashnode.dev'}, const {'pat': 'k', 'token': 'k', 'access_token': 'k'}, _text, tier: PlatformTier.byokApi),
  _Case('deviantart', const {'username': 'u'}, _oauth, _art, tier: PlatformTier.byokApi),
  _Case('dribbble', const {'clientId': 'cid'}, _oauth, _art, tier: PlatformTier.byokApi),
  _Case('flickr', const {'userNsid': '12345@N01'}, const {OAuth1Credentials.keyConsumerKey: 'k', OAuth1Credentials.keyConsumerSecret: 's', OAuth1Credentials.keyToken: 't', OAuth1Credentials.keyTokenSecret: 's'}, _art, tier: PlatformTier.byokApi),
  _Case('inkbunny', const {'username': 'painter'}, const {'sid': 's'}, _art),
];

void main() {
  final lost = http.ClientException('Connection closed before full header was received');

  group('a lost answer on the post call', () {
    for (final c in _cases) {
      test('${c.id}${c.what}: ${c.exempt ? 'exempt, it has a real dedupe key' : 'outcome unknown, not retryable'}', () async {
        final inside = _Inside();
        final ctx = AdapterContext(
          http: NeforumHttp(
            client: _mock((r) async {
              if (inside.now) throw lost;
              return http.Response(jsonEncode(_answer), 200, headers: {...jsonHeaders, 'location': 'https://upload.example/session'});
            }),
            maxRetries: 0,
          ),
          mediaHost: c.hosted ? FakeMediaHost() : null,
          clock: () => testNow,
          log: Logger('t', sink: (l, a, m, [e]) {}),
          readMedia: (_) async => fakeJpegBytes,
          networkName: c.id,
          createRecorder: inside,
        );
        final adapter = c.adapter ?? builtinAdapters().firstWhere((a) => a.id == c.id);
        final account = fakeAccount(c.id, tier: c.tier, config: c.config);
        PublishError? error;
        try {
          final r = await adapter.publish(c.variant(), account, c.secrets, ctx);
          error = r.error;
        } on AdapterException catch (e) {
          error = e.error;
        } on Object catch (e) {
          // PublishService maps this to a plain retryable failure.
          error = PublishError.network('escaped as ${e.runtimeType}');
        }
        expect(inside.entered, greaterThan(0), reason: '${c.id} never reached its post call: $error');
        if (c.exempt) {
          expect(error?.outcomeUnknown, isNot(isTrue), reason: '$error');
        } else {
          expect(error?.outcomeUnknown, isTrue, reason: '$error');
          expect(error?.retryable, isFalse, reason: '$error');
          expect(error?.message, contains('Check ${c.id} before retrying'), reason: '$error');
        }
      });
    }

    test('the table holds 30 of the 31: Nostr posts over a socket and has its own test', () {
      final api = {for (final a in builtinAdapters()) if (a.descriptor.tiers.any((t) => t != PlatformTier.handoff)) a.id};
      expect(api.difference({for (final c in _cases) c.id}), {'nostr'});
    });
  });
}

http.Client _mock(Future<http.Response> Function(http.Request r) handler) => _Mock(handler);

class _Mock extends http.BaseClient {
  _Mock(this.handler);

  final Future<http.Response> Function(http.Request r) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    final copy = http.Request(request.method, request.url)
      ..bodyBytes = bytes
      ..headers.addAll(request.headers);
    final res = await handler(copy);
    return http.StreamedResponse(Stream.value(res.bodyBytes), res.statusCode, headers: res.headers, request: request);
  }
}
