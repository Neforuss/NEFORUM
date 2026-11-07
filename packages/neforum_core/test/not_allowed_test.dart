// D12: an `auth` error that means "not allowed" rather than "expired" says so, so
// the advice stops saying the sign-in expired and the card stops asking for a
// reconnect. One row per way a network can say it, and the matching "expired"
// answer stays as it was.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/art/dribbble_api.dart' show DribbbleApi;
import 'package:neforum_core/src/adapters/blogs_a/ghost_api.dart' show mapGhostFailure;
import 'package:neforum_core/src/adapters/blogs_b/hashnode_api.dart' show HashnodeError, hashnodePublishError;
import 'package:neforum_core/src/adapters/facebook/facebook_api.dart' show mapGraphFailure;
import 'package:neforum_core/src/adapters/instagram/instagram_api.dart' show mapHttpFailure;
import 'package:neforum_core/src/adapters/lemmy/lemmy_api.dart' show lemmyPublishError;
import 'package:neforum_core/src/adapters/linkedin/linkedin_api.dart' show LinkedInApi;
import 'package:neforum_core/src/adapters/mastodon/mastodon_api.dart' show MastodonApi;
import 'package:neforum_core/src/adapters/misskey/misskey_api.dart' show misskeyPublishError;
import 'package:neforum_core/src/adapters/pinterest/pinterest_api.dart' show PinterestApi;
import 'package:neforum_core/src/adapters/reddit/reddit_api.dart' show RedditApi;
import 'package:neforum_core/src/adapters/threads/threads_api.dart' show threadsErrorFrom;
import 'package:neforum_core/src/adapters/tiktok/tiktok_api.dart' show mapTikTokError;
import 'package:neforum_core/src/adapters/tumblr/tumblr_api.dart' show TumblrApi;
import 'package:neforum_core/src/adapters/x/x_api.dart' show XApi;
import 'package:neforum_core/src/adapters/youtube/youtube_api.dart' show mapYouTubeError;
import 'package:test/test.dart';

final _now = DateTime.utc(2026, 11, 6, 12);

NeforumResponse _res(int status, Object? body) =>
    NeforumResponse(status, const {'content-type': 'application/json'}, Uint8List.fromList(utf8.encode(body is String ? body : jsonEncode(body))), Uri.parse('https://api.example/post'));

HttpFailure _f(int status, Object? body) => HttpFailure(_res(status, body));

Map<String, Object?> _graph(int code, {int? sub}) => {
      'error': {'message': 'nope', 'type': 'OAuthException', 'code': code, 'error_subcode': ?sub},
    };

Map<String, Object?> _google(String reason) => {
      'error': {
        'code': 403,
        'message': 'nope',
        'errors': [
          {'reason': reason, 'message': 'nope'},
        ],
      },
    };

void main() {
  group('these mean not allowed', () {
    final rows = <String, PublishError Function()>{
      'a generic 403': () => _f(403, '{}').toPublishError(context: 'post'),
      'Ghost 403': () => mapGhostFailure(_f(403, {'errors': [{'message': 'No permission', 'type': 'NoPermissionError'}]}), 'post'),
      'Hashnode FORBIDDEN': () => hashnodePublishError(const HashnodeError(message: 'Forbidden', code: 'FORBIDDEN', statusCode: 403), context: 'post'),
      'Tumblr 403': () => TumblrApi.mapFailure(_f(403, {'meta': {'status': 403, 'msg': 'Forbidden'}, 'errors': <Object>[]}), 'post'),
      'Threads permission denied': () => threadsErrorFrom(_f(403, _graph(10))),
      'Threads missing permission': () => threadsErrorFrom(_f(403, _graph(200))),
      'Threads OAuthException on a 403': () => threadsErrorFrom(_f(403, _graph(999))),
      'TikTok scope': () => mapTikTokError(code: 'scope_not_authorized', message: '', raw: '', status: 403, context: 'post'),
      'Facebook permission (10)': () => mapGraphFailure(_f(403, _graph(10))),
      'Facebook permission (200)': () => mapGraphFailure(_f(403, _graph(200))),
      'X not permitted': () => XApi.mapError(_f(403, {'detail': 'You are not permitted to perform this action.', 'title': 'Forbidden', 'status': 403}), now: _now),
      'Mastodon 403': () => MastodonApi.mapFailure(_f(403, {'error': 'This action is not allowed'})),
      'Pinterest missing scope': () => PinterestApi.mapFailure(_f(403, {'code': 403, 'message': 'Missing: [boards:write]'})),
      'Instagram permission (10)': () => mapHttpFailure(_f(403, _graph(10))),
      'Instagram permission (200)': () => mapHttpFailure(_f(403, _graph(200))),
      'Instagram restricted account': () => mapHttpFailure(_f(400, _graph(1, sub: 2207050))),
      'Instagram OAuthException on a 403': () => mapHttpFailure(_f(403, _graph(999))),
      'Reddit 403': () => RedditApi.mapHttpError(_f(403, {'message': 'Forbidden'})),
      'YouTube permissions': () => mapYouTubeError(_res(403, _google('insufficientPermissions')), context: 'post', now: _now),
      'Dribbble 403': () => DribbbleApi.mapFailure(_f(403, {'message': 'You are not allowed to upload shots'})),
      'LinkedIn 403': () => LinkedInApi.mapFailure(_f(403, {'status': 403, 'code': 'ACCESS_DENIED', 'message': 'Not enough permissions'}), 'post', _now),
      'Misskey PERMISSION_DENIED': () => misskeyPublishError(_f(403, {'error': {'code': 'PERMISSION_DENIED', 'message': 'no', 'id': 'x', 'kind': 'permission'}}), context: 'post'),
      'Lemmy unverified email': () => lemmyPublishError(_f(400, {'error': 'email_not_verified'}), context: 'post'),
      'Lemmy pending application': () => lemmyPublishError(_f(400, {'error': 'registration_application_is_pending'}), context: 'post'),
      'Lemmy denied application': () => lemmyPublishError(_f(400, {'error': 'registration_denied'}), context: 'post'),
    };
    rows.forEach((name, map) {
      test(name, () {
        final e = map();
        expect(e.kind, PublishErrorKind.auth, reason: 'no new enum value');
        expect(e.notAllowed, isTrue);
        expect(refusesSignIn(e), isFalse, reason: 'the card does not ask for a reconnect');
      });
    });
  });

  group('these mean the sign-in ended, as before', () {
    final rows = <String, PublishError Function()>{
      'a generic 401': () => _f(401, '{}').toPublishError(context: 'post'),
      'Ghost 401': () => mapGhostFailure(_f(401, {'errors': [{'message': 'Bad key', 'type': 'UnauthorizedError'}]}), 'post'),
      'Hashnode UNAUTHENTICATED': () => hashnodePublishError(const HashnodeError(message: 'No', code: 'UNAUTHENTICATED', statusCode: 401), context: 'post'),
      'Tumblr 401': () => TumblrApi.mapFailure(_f(401, {'meta': {'status': 401, 'msg': 'Unauthorized'}, 'errors': <Object>[]}), 'post'),
      'Threads 190': () => threadsErrorFrom(_f(401, _graph(190))),
      'TikTok invalid token': () => mapTikTokError(code: 'access_token_invalid', message: '', raw: '', status: 401, context: 'post'),
      'Facebook 190': () => mapGraphFailure(_f(401, _graph(190))),
      'X 401': () => XApi.mapError(_f(401, {'detail': 'Unauthorized', 'title': 'Unauthorized', 'status': 401}), now: _now),
      'Mastodon 401': () => MastodonApi.mapFailure(_f(401, {'error': 'The access token is invalid'})),
      'Pinterest 401': () => PinterestApi.mapFailure(_f(401, {'code': 2, 'message': 'Authentication failed.'})),
      'Instagram 190': () => mapHttpFailure(_f(400, _graph(190))),
      'Reddit 401': () => RedditApi.mapHttpError(_f(401, {'message': 'Unauthorized'})),
      'YouTube 401': () => mapYouTubeError(_res(401, _google('authError')), context: 'post', now: _now),
      'Dribbble 401': () => DribbbleApi.mapFailure(_f(401, {'message': 'Bad credentials'})),
      'LinkedIn 401': () => LinkedInApi.mapFailure(_f(401, {'status': 401, 'code': 'EXPIRED_ACCESS_TOKEN', 'message': 'expired'}), 'post', _now),
      'Misskey AUTHENTICATION_FAILED': () => misskeyPublishError(_f(401, {'error': {'code': 'AUTHENTICATION_FAILED', 'message': 'no', 'id': 'x', 'kind': 'client'}}), context: 'post'),
      'Lemmy signed out': () => lemmyPublishError(_f(400, {'error': 'not_logged_in'}), context: 'post'),
    };
    rows.forEach((name, map) {
      test(name, () {
        final e = map();
        expect(e.kind, PublishErrorKind.auth);
        expect(e.notAllowed, isNull);
        expect(refusesSignIn(e), isTrue);
      });
    });
  });

  test('a mapper that rewrites a 403 keeps what it means', () {
    // Facebook with a code it has no rule for: its own message on the generic kind.
    expect(mapGraphFailure(_f(403, _graph(999))).notAllowed, isTrue);
    expect(LinkedInApi.mapFailure(_f(404, {'message': 'gone'}), 'post', _now).notAllowed, isNull);
  });

  test('every copy of an error in the source keeps notAllowed: a rewrapped 403 cannot start saying the sign-in expired', () {
    final copy = RegExp(r'kind: [^,\n]*\b(\w+)\.kind,');
    final offenders = <String>[];
    var copies = 0;
    for (final root in ['lib/src/adapters', 'lib/src/publish']) {
      for (final f in Directory(root).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        final text = f.readAsStringSync();
        for (final m in copy.allMatches(text)) {
          copies++;
          // The field sits among the constructor's arguments, right there.
          final window = text.substring(m.start, (m.end + 200).clamp(0, text.length));
          if (!window.contains('notAllowed: ${m[1]}.notAllowed')) offenders.add('${f.path}: ${m[0]}');
        }
      }
    }
    expect(copies, greaterThan(20), reason: 'the scan found the copies');
    expect(offenders, isEmpty);
  });
}
