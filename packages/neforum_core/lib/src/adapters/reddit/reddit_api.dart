import 'dart:async';
import 'dart:typed_data';

import '../../http/neforum_http.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import '../platform_adapter.dart';

/// Endpoints of the Reddit Data API used by the Reddit adapter. Sign-in and
/// token calls go to `www.reddit.com`; everything else to `oauth.reddit.com`.
class RedditEndpoints {
  RedditEndpoints._();

  static final Uri authorize = Uri.parse('https://www.reddit.com/api/v1/authorize');

  /// Small-screen variant of the consent page, used on phones.
  static final Uri authorizeCompact = Uri.parse('https://www.reddit.com/api/v1/authorize.compact');
  static final Uri token = Uri.parse('https://www.reddit.com/api/v1/access_token');
  static final Uri revoke = Uri.parse('https://www.reddit.com/api/v1/revoke_token');
  static final Uri me = Uri.parse('https://oauth.reddit.com/api/v1/me');
  static final Uri submit = Uri.parse('https://oauth.reddit.com/api/submit');
  static final Uri submitGallery = Uri.parse('https://oauth.reddit.com/api/submit_gallery_post.json');
  static final Uri mediaAsset = Uri.parse('https://oauth.reddit.com/api/media/asset.json');
  static final Uri comment = Uri.parse('https://oauth.reddit.com/api/comment');
}

/// The signed-in Reddit user, from `GET /api/v1/me`.
class RedditUser {
  const RedditUser({required this.id, required this.name, this.avatarUrl});

  final String id;
  final String name;
  final String? avatarUrl;
}

/// What `/api/submit` or `/api/submit_gallery_post.json` returned. Image and
/// video submissions usually carry no id, only a [websocketUrl] that reports
/// the final post once Reddit has processed the media.
class RedditSubmission {
  const RedditSubmission({this.id, this.url, this.websocketUrl, this.userSubmittedPage});

  /// Base-36 post id without the `t3_` prefix.
  final String? id;
  final String? url;
  final Uri? websocketUrl;
  final String? userSubmittedPage;

  RedditSubmission withPost(String id, String? url) =>
      RedditSubmission(id: id, url: url ?? this.url, websocketUrl: websocketUrl, userSubmittedPage: userSubmittedPage);
}

/// A file uploaded through the media lease flow.
class RedditUploadedMedia {
  const RedditUploadedMedia({required this.assetId, required this.url, this.websocketUrl});

  /// Used as `media_id` in galleries.
  final String assetId;

  /// `https:{action}/{key}`; used as `url` / `video_poster_url` in `/api/submit`.
  final String url;
  final Uri? websocketUrl;
}

/// Thin, stateless wrapper over the Reddit calls NEFORUM needs. Throws
/// [HttpFailure] / [AdapterException]; the adapter converts them.
class RedditApi {
  RedditApi(this.ctx, String accessToken, {required this.userAgent})
      : _headers = {'Authorization': 'bearer $accessToken', 'User-Agent': userAgent};

  final AdapterContext ctx;

  /// Reddit wants `<platform>:<app id>:<version> (by /u/<username>)` on every
  /// request, including the S3 upload.
  final String userAgent;
  final Map<String, String> _headers;

  Future<RedditUser> me() async {
    final res = await ctx.http.get(RedditEndpoints.me, headers: _headers);
    final j = res.jsonMap;
    final id = _str(j['id']);
    final name = _str(j['name']);
    if (id == null || name == null) {
      throw const AdapterException(PublishError.platform('Reddit did not return the signed-in user'));
    }
    final icon = _str(j['icon_img']) ?? _str(j['snoovatar_img']);
    return RedditUser(id: id, name: name, avatarUrl: icon?.replaceAll('&amp;', '&'));
  }

  /// `POST /api/submit` (form encoded). Reddit answers HTTP 200 even when the
  /// post was refused, so `json.errors` is checked here.
  Future<RedditSubmission> submit(Map<String, String> form) async {
    final res = await ctx.http.postForm(RedditEndpoints.submit, form, headers: _headers);
    return _submission(res);
  }

  /// `POST /api/submit_gallery_post.json` (JSON body).
  Future<RedditSubmission> submitGallery(Map<String, Object?> body) async {
    final res = await ctx.http.postJson(RedditEndpoints.submitGallery, body, headers: _headers);
    return _submission(res);
  }

  /// `POST /api/comment`; returns the new comment's id.
  Future<String?> comment(String thingId, String text) async {
    final res = await ctx.http.postForm(
      RedditEndpoints.comment,
      {'api_type': 'json', 'thing_id': thingId, 'text': text},
      headers: _headers,
    );
    final json = _map(res.jsonMap['json']);
    _throwOnErrors(json, res);
    final things = _map(json['data'])['things'];
    if (things is List && things.isNotEmpty) return _str(_map(_map(things.first)['data'])['id']);
    return null;
  }

  /// Media lease flow: ask Reddit for an S3 upload slot, then POST the file
  /// to S3 with every lease field in order and the file part last.
  Future<RedditUploadedMedia> uploadMedia(Uint8List bytes, {required String fileName, required String mimeType}) async {
    final lease = await ctx.http.postForm(
      RedditEndpoints.mediaAsset,
      {'filepath': fileName, 'mimetype': mimeType},
      headers: _headers,
    );
    final j = lease.jsonMap;
    // Refusals (e.g. RATELIMIT) come back as HTTP 200 with json.errors.
    _throwOnErrors(_map(j['json']), lease);
    final args = _map(j['args']);
    final asset = _map(j['asset']);
    final action = _str(args['action']);
    final assetId = _str(asset['asset_id']);
    final fields = <String, String>{};
    final rawFields = args['fields'];
    if (rawFields is List) {
      for (final f in rawFields) {
        final m = _map(f);
        final name = m['name'];
        if (name is String) fields[name] = '${m['value'] ?? ''}';
      }
    }
    final key = fields['key'];
    if (action == null || assetId == null || key == null) {
      throw AdapterException(
          PublishError.platform('Reddit did not hand out a media upload slot', raw: _snippet(lease.body)));
    }
    final target = action.startsWith('//') ? 'https:$action' : action;
    final res = await ctx.http.multipart(
      Uri.parse(target),
      fields: fields,
      files: [HttpFilePart(field: 'file', bytes: bytes, fileName: fileName, contentType: mimeType)],
      headers: {'User-Agent': userAgent},
      throwOnError: false,
    );
    if (!res.ok) throw AdapterException(_s3Error(res));
    final ws = _str(asset['websocket_url']);
    return RedditUploadedMedia(assetId: assetId, url: '$target/$key', websocketUrl: ws == null ? null : Uri.tryParse(ws));
  }

  RedditSubmission _submission(NeforumResponse res) {
    final json = _map(res.jsonMap['json']);
    _throwOnErrors(json, res);
    final data = _map(json['data']);
    var id = _str(data['id']);
    final name = _str(data['name']);
    if (id == null && name != null && name.startsWith('t3_')) id = name.substring(3);
    final ws = _str(data['websocket_url']);
    final sub = RedditSubmission(
      id: id,
      url: _str(data['url']),
      websocketUrl: ws == null ? null : Uri.tryParse(ws),
      userSubmittedPage: _str(data['user_submitted_page']),
    );
    if (sub.id == null && sub.websocketUrl == null && sub.url == null) {
      throw AdapterException(PublishError.platform('Reddit accepted the request but returned no post', raw: _snippet(res.body)));
    }
    return sub;
  }

  static void _throwOnErrors(Map<String, dynamic> json, NeforumResponse res) {
    final errors = json['errors'];
    if (errors is List && errors.isNotEmpty) {
      throw AdapterException(mapApiErrors(errors, ratelimitSeconds: json['ratelimit'], raw: _snippet(res.body)));
    }
  }

  // ---------------------------------------------------------------------
  // Error mapping
  // ---------------------------------------------------------------------

  static const Set<String> _validationCodes = {
    'ALREADY_SUB',
    'DOMAIN_BANNED',
    'INVALID_OPTION',
    'IN_TIMEOUT',
    'NO_LINKS',
    'NO_SELFS',
    'NO_TEXT',
    'NO_URL',
    'OVERSOLD',
    'TOO_LONG',
    'TOO_SHORT',
  };

  /// Maps Reddit's `json.errors` (`[[CODE, message, field], ...]`) onto a
  /// [PublishError]: `RATELIMIT` -> quota with `retryAfter`, `USER_REQUIRED`
  /// -> auth, CAPTCHA -> platform, rule violations -> validation.
  static PublishError mapApiErrors(List<Object?> errors, {Object? ratelimitSeconds, String? raw}) {
    final first = errors.first;
    String code;
    String message;
    String? field;
    if (first is List && first.isNotEmpty) {
      code = '${first[0]}';
      message = first.length > 1 ? '${first[1]}' : code;
      field = first.length > 2 && first[2] != null ? '${first[2]}' : null;
    } else {
      final m = _map(first);
      code = _str(m['code']) ?? _str(m['error']) ?? 'ERROR';
      message = _str(m['message']) ?? _str(m['explanation']) ?? code;
      field = _str(m['field']);
    }
    final all = errors.length > 1 ? ' (and ${errors.length - 1} more)' : '';
    final text = 'Reddit refused the post: $message${field == null ? '' : ' [$field]'}$all';
    if (code == 'RATELIMIT') {
      return PublishError.quota(text, raw: raw, retryAfter: _ratelimitWait(ratelimitSeconds, message));
    }
    if (code == 'USER_REQUIRED') {
      return PublishError.auth('Reddit says you are not signed in; reconnect the account. ($message)', raw: raw);
    }
    if (code.contains('CAPTCHA')) {
      return PublishError.platform(
          'Reddit wants a CAPTCHA for this account (common for new accounts); post this one via hand-off. ($message)',
          raw: raw);
    }
    if (_validationCodes.contains(code) ||
        code.startsWith('SUBMIT_VALIDATION') ||
        code.startsWith('SUBREDDIT_') ||
        code.startsWith('BAD_') ||
        code.contains('FLAIR')) {
      return PublishError.validation(text, raw: raw);
    }
    return PublishError.platform(text, raw: raw);
  }

  /// Turns an HTTP failure from oauth.reddit.com into a [PublishError].
  static PublishError mapHttpError(HttpFailure f) {
    final status = f.statusCode;
    final body = f.response.jsonMap;
    final raw = _snippet(f.body);
    if (status >= 400 && status < 500 && status != 401 && status != 429) {
      // Some endpoints (galleries among them) refuse with an HTTP 4xx whose
      // body is {"reason": CODE, "explanation": ..., "fields": [...]} (PRAW
      // turns it into RedditAPIException), or with the usual json.errors.
      final errors = _map(body['json'])['errors'];
      if (errors is List && errors.isNotEmpty) {
        return _withStatus(mapApiErrors(errors, ratelimitSeconds: _map(body['json'])['ratelimit'], raw: raw), status);
      }
      final reason = _str(body['reason']);
      if (reason != null) {
        final fields = body['fields'];
        final field = fields is List && fields.isNotEmpty ? _str(fields.first) : null;
        return _withStatus(
            mapApiErrors([
              [reason, _str(body['explanation']) ?? _str(body['message']) ?? reason, field],
            ], raw: raw),
            status);
      }
    }
    final detail = _str(body['explanation']) ?? _str(body['message']) ?? _str(body['error']) ?? 'HTTP $status';
    if (status == 401) {
      return PublishError.auth('Reddit rejected the sign-in (token expired or revoked); reconnect the account. ($detail)',
          raw: raw, statusCode: status);
    }
    if (status == 403) {
      return PublishError.auth(
        'Reddit refused access (HTTP 403: $detail). The sign-in may lack a permission, the account may be suspended, '
        'or your Reddit app is not approved for API access. Reconnect the account; if that fails, use hand-off.',
        raw: raw,
        statusCode: status,
      );
    }
    if (status == 429) {
      return PublishError.quota('Reddit rate limit reached (100 requests per minute per app). ($detail)',
          raw: raw, statusCode: status, retryAfter: rateLimitReset(f.response));
    }
    if (status == 400 || status == 404 || status == 413 || status == 415 || status == 422) {
      return PublishError.validation('Reddit rejected the request (HTTP $status): $detail', raw: raw, statusCode: status);
    }
    if (status >= 500) {
      return PublishError.network('Reddit is having trouble (HTTP $status)',
          raw: raw, statusCode: status, retryAfter: f.response.retryAfter);
    }
    return f.toPublishError(context: 'Reddit');
  }

  static PublishError _withStatus(PublishError e, int status) => PublishError(
        kind: e.kind,
        message: e.message,
        retryable: e.retryable,
        statusCode: status,
        raw: e.raw,
        retryAfter: e.retryAfter,
      );

  /// `X-Ratelimit-Reset` is the number of seconds until the window resets.
  static Duration? rateLimitReset(NeforumResponse res) {
    final reset = double.tryParse(res.headers['x-ratelimit-reset'] ?? '');
    if (reset != null) return Duration(seconds: reset.ceil());
    return res.retryAfter;
  }

  static PublishError _s3Error(NeforumResponse res) {
    final code = RegExp(r'<Code>([^<]*)</Code>').firstMatch(res.body)?.group(1) ?? 'HTTP ${res.statusCode}';
    final message = RegExp(r'<Message>([^<]*)</Message>').firstMatch(res.body)?.group(1) ?? '';
    final raw = _snippet(res.body);
    if (code == 'EntityTooLarge') {
      final max = RegExp(r'<MaxSizeAllowed>(\d+)</MaxSizeAllowed>').firstMatch(res.body)?.group(1);
      final limit = max == null ? '' : ' (limit ${(int.parse(max) / (1024 * 1024)).toStringAsFixed(0)} MB)';
      return PublishError.validation('The file is too large for Reddit$limit', raw: raw, statusCode: res.statusCode);
    }
    if (res.statusCode >= 500) {
      return PublishError.network('Reddit\'s media storage is having trouble ($code)', raw: raw, statusCode: res.statusCode);
    }
    return PublishError.platform('Reddit\'s media storage refused the upload: $code $message'.trim(),
        raw: raw, statusCode: res.statusCode);
  }

  /// `RATELIMIT` comes with `json.ratelimit` (seconds) and/or a message like
  /// "you are doing that too much. try again in 9 minutes."
  static Duration? _ratelimitWait(Object? seconds, String message) {
    if (seconds is num) return Duration(seconds: seconds.ceil());
    final m = RegExp(r'(\d+)\s*(millisecond|second|minute|hour)s?', caseSensitive: false).firstMatch(message);
    if (m == null) return null;
    final n = int.parse(m.group(1)!);
    return switch (m.group(2)!.toLowerCase()) {
      'millisecond' => Duration(milliseconds: n),
      'second' => Duration(seconds: n),
      'hour' => Duration(hours: n),
      _ => Duration(minutes: n),
    };
  }
}

/// Shortens a response body for [PublishError.raw].
String _snippet(String s) => s.length > 600 ? '${s.substring(0, 600)}…' : s;

/// `v` as a JSON object, or an empty map.
Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

/// `v` as a non-empty string (numbers are stringified), else `null`.
String? _str(Object? v) {
  if (v is String) return v.isEmpty ? null : v;
  if (v is num) return v.toString();
  return null;
}
