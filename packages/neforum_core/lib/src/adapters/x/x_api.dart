import 'dart:async';
import 'dart:typed_data';

import '../../auth/oauth1.dart';
import '../../http/neforum_http.dart';
import '../../model/media.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import '../platform_adapter.dart';

/// Endpoints of the X API v2 used by the X adapter.
class XEndpoints {
  XEndpoints._();

  static final Uri authorize = Uri.parse('https://x.com/i/oauth2/authorize');
  static final Uri token = Uri.parse('https://api.x.com/2/oauth2/token');
  static final Uri revoke = Uri.parse('https://api.x.com/2/oauth2/revoke');
  static final Uri me = Uri.https('api.x.com', '/2/users/me', {'user.fields': 'profile_image_url'});
  static final Uri tweets = Uri.parse('https://api.x.com/2/tweets');
  static final Uri mediaUpload = Uri.parse('https://api.x.com/2/media/upload');
  static final Uri mediaInitialize = Uri.parse('https://api.x.com/2/media/upload/initialize');
  static final Uri mediaMetadata = Uri.parse('https://api.x.com/2/media/metadata');

  static Uri mediaAppend(String id) => Uri.parse('https://api.x.com/2/media/upload/$id/append');
  static Uri mediaFinalize(String id) => Uri.parse('https://api.x.com/2/media/upload/$id/finalize');
  static Uri mediaStatus(String id) =>
      Uri.https('api.x.com', '/2/media/upload', {'command': 'STATUS', 'media_id': id});
}

/// The authenticated X user, from `GET /2/users/me`.
class XUser {
  const XUser({required this.id, required this.username, required this.name, this.avatarUrl, this.accessLevel});

  final String id;
  final String username;
  final String name;
  final String? avatarUrl;

  /// X's `x-access-level` response header on OAuth 1.0a calls (`read`,
  /// `read-write`, `read-write-directmessages`), when X sends it.
  final String? accessLevel;
}

/// Thin, stateless wrapper over the X API v2 calls NEFORUM needs. Throws
/// [HttpFailure] / [AdapterException]; the adapter converts them.
///
/// Every call is authorized the same way: with the OAuth 2.0 user token as
/// a Bearer header ([XApi.new]), or signed with the user's OAuth 1.0a keys
/// ([XApi.oauth1]). X's API reference lists both ("OAuth2UserToken" and
/// "UserToken") for each endpoint used here.
class XApi {
  XApi(this.ctx, String accessToken)
      : _bearer = {'Authorization': 'Bearer $accessToken'},
        _signer = null;

  /// Signs every request with OAuth 1.0a; a fresh nonce per attempt.
  XApi.oauth1(this.ctx, OAuth1Credentials keys, {String Function()? nonce})
      : _bearer = const {},
        _signer = OAuth1Signer(keys, clock: ctx.now, nonce: nonce);

  /// Images up to this size go through the one-shot upload; larger GIFs and
  /// all videos use the chunked initialize/append/finalize flow.
  static const int simpleUploadMaxBytes = 5 * 1024 * 1024;

  /// Append segments must stay at or below 5 MB (server maximum 8 MB).
  static const int chunkBytes = 4 * 1024 * 1024;

  /// Alt text limit of `POST /2/media/metadata`.
  static const int altTextMax = 1000;

  static const int _maxPolls = 180;
  static const Duration _maxProcessingWait = Duration(minutes: 30);

  final AdapterContext ctx;
  final Map<String, String> _bearer;
  final OAuth1Signer? _signer;

  /// Sends one request with this API's authorization. Only JSON and
  /// multipart bodies are used, and neither is part of an OAuth 1.0a
  /// signature; query parameters (the STATUS poll) are signed.
  Future<NeforumResponse> _call(String method, Uri url,
      {Object? json, Map<String, String>? fields, List<HttpFilePart>? files}) {
    final signer = _signer;
    return ctx.http.send(
      method,
      url,
      headers: _bearer,
      signHeaders: signer == null ? null : () => signer.headers(method, url),
      jsonBody: json,
      fields: fields,
      files: files,
    );
  }

  Future<XUser> me() async {
    final res = await _call('GET', XEndpoints.me);
    final data = _map(res.jsonMap['data']);
    final id = _str(data['id']);
    final username = _str(data['username']);
    if (id == null || username == null) {
      throw const AdapterException(PublishError.platform('X did not return the signed-in user'));
    }
    return XUser(
      id: id,
      username: username,
      name: _str(data['name']) ?? username,
      avatarUrl: _str(data['profile_image_url']),
      accessLevel: res.headers['x-access-level'],
    );
  }

  /// Uploads every attachment (plus its alt text) and returns the media ids
  /// in order.
  Future<List<String>> uploadAll(List<MediaAttachment> media) async {
    final ids = <String>[];
    final videos = media.where((m) => m.isVideo).length;
    final images = media.length - videos;
    var imageNo = 0, videoNo = 0;
    for (final m in media) {
      final label = m.isVideo
          ? 'Uploading video ${++videoNo} of $videos'
          : 'Uploading image ${++imageNo} of $images';
      ctx.progress(label);
      final bytes = await _read(m);
      final id = (m.isVideo || bytes.length > simpleUploadMaxBytes)
          ? await _chunkedUpload(m, bytes)
          : await _simpleUpload(m, bytes);
      final alt = (m.altText ?? '').trim();
      if (alt.isNotEmpty) await _setAltText(id, alt);
      ids.add(id);
    }
    return ids;
  }

  /// `POST /2/tweets`; returns the new post id.
  Future<String> createPost({
    required String text,
    List<String> mediaIds = const [],
    String? inReplyTo,
    String? replySettings,
  }) async {
    final body = <String, Object>{
      if (text.isNotEmpty) 'text': text,
      if (mediaIds.isNotEmpty) 'media': {'media_ids': mediaIds},
      if (inReplyTo != null) 'reply': {'in_reply_to_tweet_id': inReplyTo},
      if (replySettings != null) 'reply_settings': replySettings,
    };
    final res = await _call('POST', XEndpoints.tweets, json: body);
    final id = _str(_map(res.jsonMap['data'])['id']);
    if (id == null) {
      throw AdapterException(PublishError.platform('X accepted the post but returned no id', raw: _snippet(res.body)));
    }
    return id;
  }

  // ---------------------------------------------------------------------
  // Media
  // ---------------------------------------------------------------------

  Future<Uint8List> _read(MediaAttachment m) async {
    try {
      return await ctx.readMedia(m);
    } on Exception catch (e) {
      throw AdapterException(PublishError.configuration('Could not read ${m.fileName ?? m.path}: $e'));
    }
  }

  Future<String> _simpleUpload(MediaAttachment m, Uint8List bytes) async {
    final res = await _call(
      'POST',
      XEndpoints.mediaUpload,
      fields: {'media_category': _category(m)},
      files: [HttpFilePart(field: 'media', bytes: bytes, fileName: _fileName(m), contentType: m.mimeType)],
    );
    final data = _map(res.jsonMap['data']);
    final id = _requireMediaId(data, res);
    await _awaitProcessing(id, data['processing_info']);
    return id;
  }

  Future<String> _chunkedUpload(MediaAttachment m, Uint8List bytes) async {
    final init = await _call(
      'POST',
      XEndpoints.mediaInitialize,
      json: {'media_type': m.mimeType, 'total_bytes': bytes.length, 'media_category': _category(m)},
    );
    final id = _requireMediaId(_map(init.jsonMap['data']), init);
    final segments = (bytes.length + chunkBytes - 1) ~/ chunkBytes;
    for (var i = 0; i < segments; i++) {
      if (segments > 1) ctx.progress('Uploading ${m.isVideo ? 'video' : 'GIF'}: part ${i + 1} of $segments');
      final end = (i + 1) * chunkBytes > bytes.length ? bytes.length : (i + 1) * chunkBytes;
      await _call(
        'POST',
        XEndpoints.mediaAppend(id),
        fields: {'segment_index': '$i'},
        files: [
          HttpFilePart(
            field: 'media',
            bytes: Uint8List.sublistView(bytes, i * chunkBytes, end),
            fileName: _fileName(m),
            contentType: 'application/octet-stream',
          ),
        ],
      );
    }
    final fin = await _call('POST', XEndpoints.mediaFinalize(id));
    await _awaitProcessing(id, _map(fin.jsonMap['data'])['processing_info']);
    return id;
  }

  /// Polls `GET /2/media/upload?command=STATUS` until X has processed the
  /// media. [info] is the `processing_info` of the last response.
  Future<void> _awaitProcessing(String id, Object? info) async {
    var current = info;
    var waited = Duration.zero;
    for (var poll = 0; poll <= _maxPolls; poll++) {
      if (current is! Map) return; // no processing_info: ready
      final p = Map<String, dynamic>.from(current);
      final state = _str(p['state']);
      if (state == null || state == 'succeeded') return;
      if (state == 'failed') {
        final err = _map(p['error']);
        final why = _str(err['message']) ?? _str(err['name']) ?? 'unknown reason';
        throw AdapterException(PublishError.validation('X could not process the media: $why'));
      }
      if (waited >= _maxProcessingWait) break;
      final secs = (_int(p['check_after_secs']) ?? 2).clamp(0, 30);
      final pct = _int(p['progress_percent']);
      ctx.progress('X is processing the video${pct == null ? '' : ' ($pct%)'}');
      await Future<void>.delayed(Duration(seconds: secs));
      waited += Duration(seconds: secs);
      final res = await _call('GET', XEndpoints.mediaStatus(id));
      current = _map(res.jsonMap['data'])['processing_info'];
    }
    throw const AdapterException(PublishError.network('X is still processing the media; try again later'));
  }

  /// Alt text is a nicety: a failure here must not lose the whole post.
  Future<void> _setAltText(String id, String alt) async {
    final text = alt.length > altTextMax ? alt.substring(0, altTextMax) : alt;
    try {
      await _call(
        'POST',
        XEndpoints.mediaMetadata,
        json: {
          'id': id,
          'metadata': {
            'alt_text': {'text': text},
          },
        },
      );
    } on HttpFailure catch (e) {
      if (e.statusCode == 401 || e.statusCode == 402 || e.statusCode == 429) rethrow;
      ctx.log.warn('X refused the alt text for media $id (HTTP ${e.statusCode}); posting without it');
    }
  }

  static String _category(MediaAttachment m) => switch (m.kind) {
        MediaKind.video => 'tweet_video',
        MediaKind.gif => 'tweet_gif',
        MediaKind.image => 'tweet_image',
        MediaKind.audio => throw ArgumentError('X does not take sound files; they go as a video'),
      };

  static String _fileName(MediaAttachment m) {
    final n = m.fileName;
    if (n != null && n.isNotEmpty) return n;
    final slash = m.path.replaceAll('\\', '/').lastIndexOf('/');
    return slash < 0 ? m.path : m.path.substring(slash + 1);
  }

  static String _requireMediaId(Map<String, dynamic> data, NeforumResponse res) {
    final id = _str(data['id']) ?? _str(data['media_id_string']);
    if (id == null) {
      throw AdapterException(PublishError.platform('X accepted the upload but returned no media id', raw: _snippet(res.body)));
    }
    return id;
  }

  // ---------------------------------------------------------------------
  // Error mapping
  // ---------------------------------------------------------------------

  /// Turns an X error response into a [PublishError] with the right kind.
  ///
  /// * 402 / `CreditsDepleted` -> quota (out of pay-per-use credits)
  /// * 429 / `UsageCapExceeded` -> quota with `retryAfter` from
  ///   `x-rate-limit-reset`
  /// * 401 -> auth
  /// * duplicate content (403) -> validation
  /// * 403 permission problems -> auth, other 403 -> platform
  /// * 400/413/415/422 -> validation, 5xx -> network
  static PublishError mapError(HttpFailure f, {required DateTime now}) {
    final status = f.statusCode;
    final body = f.response.jsonMap;
    final raw = _snippet(f.body);
    final detail = errorMessage(body) ?? 'HTTP $status';
    final title = _str(body['title']) ?? '';
    final lower = '$title ${_str(body['type']) ?? ''} $detail'.toLowerCase();

    if (status == 402 || title == 'CreditsDepleted') {
      return PublishError.quota(
        'Your X developer account has no API credits left. Top up at console.x.com (or post via hand-off). X said: $detail',
        raw: raw,
        statusCode: status,
      );
    }
    if (status == 429 || title == 'UsageCapExceeded') {
      return PublishError.quota(
        'X rate limit reached: $detail',
        raw: raw,
        statusCode: status,
        retryAfter: _resetAfter(f.response, now),
      );
    }
    if (status == 401) {
      return PublishError.auth('X rejected the sign-in (token expired or revoked); reconnect the account. X said: $detail',
          raw: raw, statusCode: status);
    }
    if (lower.contains('duplicate')) {
      return PublishError.validation('X refused this as a duplicate of a recent post: $detail', raw: raw, statusCode: status);
    }
    if (status == 403) {
      if (lower.contains('too long') || lower.contains('length')) {
        return PublishError.validation('X refused the post length (over 280 characters needs X Premium): $detail',
            raw: raw, statusCode: status);
      }
      if (RegExp(r'not permitted|permission|scope|oauth|unsupported authentication|not authorized')
          .hasMatch(lower)) {
        return PublishError.auth(
          'X does not let this app post for the account: $detail. Check that the app has "Read and write" '
          'permission and a funded pay-per-use project at console.x.com, then reconnect. With pasted keys, '
          'regenerate the Access Token and Secret after switching to "Read and write": old tokens keep the old permission.',
          raw: raw,
          statusCode: status,
        );
      }
      return PublishError.platform('X refused the request: $detail', raw: raw, statusCode: status);
    }
    if (status == 400 || status == 413 || status == 415 || status == 422) {
      return PublishError.validation('X rejected the post: $detail', raw: raw, statusCode: status);
    }
    if (status >= 500) {
      return PublishError.network('X is having trouble (HTTP $status): $detail',
          raw: raw, statusCode: status, retryAfter: f.response.retryAfter);
    }
    return f.toPublishError(context: 'X');
  }

  /// Best human-readable message from an X error body (problem+json, the
  /// `errors` array, or an OAuth error).
  static String? errorMessage(Map<String, dynamic> body) {
    final errors = body['errors'];
    String? first;
    if (errors is List && errors.isNotEmpty) {
      final e = _map(errors.first);
      first = _str(e['detail']) ?? _str(e['message']);
    }
    return _str(body['detail']) ??
        first ??
        _str(body['error_description']) ??
        _str(body['message']) ??
        _str(body['title']) ??
        _str(body['error']);
  }

  static Duration? _resetAfter(NeforumResponse res, DateTime now) {
    final reset = int.tryParse(res.headers['x-rate-limit-reset'] ?? '');
    if (reset != null) {
      final secs = reset - now.millisecondsSinceEpoch ~/ 1000;
      return Duration(seconds: secs < 0 ? 0 : secs);
    }
    return res.retryAfter;
  }
}

String _snippet(String s) => s.length > 600 ? '${s.substring(0, 600)}…' : s;

Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

String? _str(Object? v) {
  if (v is String) return v.isEmpty ? null : v;
  if (v is num) return v.toString();
  return null;
}

int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));
