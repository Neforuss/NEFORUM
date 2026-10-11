import 'dart:typed_data';

import '../../http/neforum_http.dart';
import '../../model/media.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import '../platform_adapter.dart';

/// Endpoints, headers and helpers for LinkedIn's versioned REST API
/// (`https://api.linkedin.com/rest/...`), shared by [LinkedInAdapter].
///
/// Kept separate from the adapter so the request plumbing (upload handshakes,
/// error mapping, `little` text escaping) can be read and tested on its own.
class LinkedInApi {
  LinkedInApi({
    required this.ctx,
    required this.accessToken,
    required this.version,
    this.videoPollInterval = const Duration(seconds: 5),
    this.videoPollAttempts = 36,
  });

  /// LinkedIn-Version header used when the account has no override.
  /// 202609 was the latest version on the official versioning page
  /// (updated 2026-09-16); every version lives for at least 12 months.
  static const String defaultVersion = '202609';

  static final Uri authorizationEndpoint = Uri.parse('https://www.linkedin.com/oauth/v2/authorization');
  static final Uri tokenEndpoint = Uri.parse('https://www.linkedin.com/oauth/v2/accessToken');
  static final Uri userInfoEndpoint = Uri.parse('https://api.linkedin.com/v2/userinfo');
  static final Uri postsEndpoint = Uri.parse('https://api.linkedin.com/rest/posts');
  static final Uri imagesInitEndpoint = Uri.parse('https://api.linkedin.com/rest/images?action=initializeUpload');
  static final Uri videosInitEndpoint = Uri.parse('https://api.linkedin.com/rest/videos?action=initializeUpload');
  static final Uri videosFinalizeEndpoint = Uri.parse('https://api.linkedin.com/rest/videos?action=finalizeUpload');

  /// Scopes of the two self-serve products ("Sign In with LinkedIn using
  /// OpenID Connect" + "Share on LinkedIn"). Never change this list for an
  /// existing app: LinkedIn invalidates earlier tokens when the scope set
  /// changes.
  static const List<String> scopes = ['openid', 'profile', 'w_member_social'];

  final AdapterContext ctx;
  final String accessToken;
  final String version;
  final Duration videoPollInterval;
  final int videoPollAttempts;

  Map<String, String> get _auth => {'Authorization': 'Bearer $accessToken'};

  /// Headers every `/rest/*` call needs.
  Map<String, String> get restHeaders => {
        ..._auth,
        'LinkedIn-Version': version,
        'X-Restli-Protocol-Version': '2.0.0',
      };

  // ---------------------------------------------------------------- posts

  /// Creates the post and returns its URN (from the `x-restli-id` header).
  Future<String> createPost(Map<String, Object?> body) async {
    final res = await _guard('Creating the post', () => ctx.http.postJson(postsEndpoint, body, headers: restHeaders));
    final id = res.headers['x-restli-id'] ?? (res.jsonMap['id'] as String?);
    if (id == null || id.isEmpty) {
      throw AdapterException(PublishError.platform(
        'LinkedIn accepted the post but did not return its id (HTTP ${res.statusCode})',
        raw: res.body,
        statusCode: res.statusCode,
      ));
    }
    return id;
  }

  // --------------------------------------------------------------- images

  /// initializeUpload -> PUT bytes (with Bearer, as the docs require for
  /// images). Returns the `urn:li:image:...`.
  Future<String> uploadImage(MediaAttachment media, String owner) async {
    final init = await _guard(
      'Preparing the image upload',
      () => ctx.http.postJson(imagesInitEndpoint, {
        'initializeUploadRequest': {'owner': owner},
      }, headers: restHeaders),
    );
    final value = _valueOf(init);
    final uploadUrl = value['uploadUrl'] as String?;
    final image = value['image'] as String?;
    if (uploadUrl == null || image == null) {
      throw AdapterException(PublishError.platform('LinkedIn returned no image upload URL', raw: init.body));
    }
    final bytes = await ctx.readMedia(media);
    await _guard(
      'Uploading the image',
      () => ctx.http.putBytes(Uri.parse(uploadUrl), bytes, headers: {..._auth, 'Content-Type': media.mimeType}),
    );
    return image;
  }

  // --------------------------------------------------------------- videos

  /// initializeUpload -> PUT each part (no Authorization header, as in the
  /// docs) collecting ETags -> finalizeUpload -> wait until AVAILABLE.
  /// Returns the `urn:li:video:...`.
  Future<String> uploadVideo(MediaAttachment media, String owner) async {
    final bytes = await ctx.readMedia(media);
    final init = await _guard(
      'Preparing the video upload',
      () => ctx.http.postJson(videosInitEndpoint, {
        'initializeUploadRequest': {
          'owner': owner,
          'fileSizeBytes': bytes.length,
          'uploadCaptions': false,
          'uploadThumbnail': false,
        },
      }, headers: restHeaders),
    );
    final value = _valueOf(init);
    final video = value['video'] as String?;
    final instructions = (value['uploadInstructions'] as List?) ?? const <Object?>[];
    if (video == null || instructions.isEmpty) {
      throw AdapterException(PublishError.platform('LinkedIn returned no video upload instructions', raw: init.body));
    }
    final etags = <String>[];
    for (var i = 0; i < instructions.length; i++) {
      final part = Map<String, dynamic>.from(instructions[i] as Map);
      final url = part['uploadUrl'] as String;
      final first = (part['firstByte'] as num?)?.toInt() ?? 0;
      final last = (part['lastByte'] as num?)?.toInt() ?? bytes.length - 1;
      final end = (last + 1).clamp(first, bytes.length);
      if (instructions.length > 1) ctx.progress('Uploading video part ${i + 1} of ${instructions.length}');
      final res = await _guard(
        'Uploading the video',
        () => ctx.http.putBytes(Uri.parse(url), Uint8List.sublistView(bytes, first, end),
            headers: {'Content-Type': 'application/octet-stream'}),
      );
      final etag = res.headers['etag'];
      if (etag == null || etag.isEmpty) {
        throw AdapterException(PublishError.platform('LinkedIn did not acknowledge video part ${i + 1} (no ETag)'));
      }
      etags.add(_unquote(etag));
    }
    await _guard(
      'Finishing the video upload',
      () => ctx.http.postJson(videosFinalizeEndpoint, {
        'finalizeUploadRequest': {
          'video': video,
          'uploadToken': (value['uploadToken'] as String?) ?? '',
          'uploadedPartIds': etags,
        },
      }, headers: restHeaders),
    );
    await _waitForVideo(video);
    return video;
  }

  /// Polls `GET /rest/videos/{urn}` until the video is AVAILABLE. A
  /// w_member_social-only token may not be allowed to read the asset; in
  /// that case (403/404) we stop polling and let the post call decide.
  Future<void> _waitForVideo(String urn) async {
    if (videoPollAttempts <= 0) return;
    final url = Uri.parse('https://api.linkedin.com/rest/videos/${Uri.encodeComponent(urn)}');
    for (var i = 0; i < videoPollAttempts; i++) {
      final res = await ctx.http.get(url, headers: restHeaders, throwOnError: false);
      if (!res.ok) {
        if (res.statusCode == 401) throw AdapterException(mapFailure(HttpFailure(res), 'Checking the video', ctx.now()));
        ctx.log.debug('Video status check returned HTTP ${res.statusCode}; continuing without it');
        return;
      }
      final status = res.jsonMap['status'] as String?;
      if (status == 'AVAILABLE') return;
      if (status == 'PROCESSING_FAILED') {
        final why = res.jsonMap['processingFailureReason'] as String? ?? 'unknown reason';
        throw AdapterException(PublishError.validation('LinkedIn could not process the video ($why)', raw: res.body));
      }
      if (i == 0) ctx.progress('Waiting for LinkedIn to process the video');
      await Future<void>.delayed(videoPollInterval);
    }
    ctx.log.warn('Video $urn still processing after $videoPollAttempts checks; posting anyway');
  }

  // -------------------------------------------------------------- helpers

  Future<NeforumResponse> _guard(String step, Future<NeforumResponse> Function() call) async {
    try {
      return await call();
    } on HttpFailure catch (e) {
      throw AdapterException(mapFailure(e, step, ctx.now()));
    }
  }

  static Map<String, dynamic> _valueOf(NeforumResponse res) {
    final v = res.jsonMap['value'];
    return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  }

  static String _unquote(String s) {
    final t = s.trim();
    return t.length >= 2 && t.startsWith('"') && t.endsWith('"') ? t.substring(1, t.length - 1) : t;
  }

  /// Turns a LinkedIn error response into a [PublishError] the pipeline can
  /// act on (reconnect, wait for the daily reset, fix the post, retry).
  static PublishError mapFailure(HttpFailure f, String step, DateTime now) {
    final status = f.statusCode;
    final json = f.response.jsonMap;
    final code = _errorCode(json);
    final detail = _errorMessage(json);
    final raw = f.body.length > 600 ? '${f.body.substring(0, 600)}…' : f.body;
    final suffix = detail == null ? '' : ': $detail';
    final lowerBody = f.body.toLowerCase();

    if (status == 401) {
      return PublishError.auth(
        'LinkedIn no longer accepts this sign-in$suffix. Reconnect LinkedIn in Accounts '
        '(LinkedIn tokens expire after 60 days and cannot be renewed automatically).',
        raw: raw,
        statusCode: status,
      );
    }
    if (status == 403) {
      return PublishError.auth(
        '$step: LinkedIn refused access$suffix. Check that your developer app has the '
        '"Share on LinkedIn" product (w_member_social) and reconnect LinkedIn.',
        raw: raw,
        statusCode: status,
      );
    }
    if (status == 429 || code == 'TOO_MANY_REQUESTS') {
      return PublishError.quota(
        'LinkedIn daily limit reached; it resets at midnight UTC',
        raw: raw,
        statusCode: status,
        retryAfter: f.response.retryAfter ?? untilNextUtcMidnight(now),
      );
    }
    final versionProblem = status == 426 ||
        (code != null && code.contains('VERSION')) ||
        (status == 400 && lowerBody.contains('version') && lowerBody.contains('not active'));
    if (versionProblem) {
      return PublishError.configuration(
        'LinkedIn no longer supports the API version this account uses$suffix. '
        'Edit the account and set a newer "LinkedIn API version" (format YYYYMM).',
      );
    }
    if (lowerBody.contains('duplicate')) {
      return PublishError.validation(
        'LinkedIn rejected this as a duplicate of a recent post. Change the text and try again.',
        raw: raw,
        statusCode: status,
      );
    }
    if (code == 'MEDIA_ASSET_WAITING_UPLOAD' || lowerBody.contains('media_asset_waiting_upload')) {
      return PublishError.network('LinkedIn is still processing the media; try again in a minute',
          raw: raw, statusCode: status, retryAfter: const Duration(minutes: 1));
    }
    if (status == 409) {
      return PublishError.network('$step: LinkedIn reported a write conflict; retrying should help',
          raw: raw, statusCode: status);
    }
    if (status == 400 || status == 413 || status == 415 || status == 422) {
      return PublishError.validation('$step: LinkedIn rejected the request$suffix', raw: raw, statusCode: status);
    }
    final base = f.toPublishError(context: 'LinkedIn');
    return detail == null
        ? base
        : PublishError(
            kind: base.kind,
            message: '${base.message}$suffix',
            retryable: base.retryable,
            statusCode: base.statusCode,
            raw: base.raw,
            retryAfter: base.retryAfter,
          );
  }

  /// LinkedIn's per-day limits reset at 00:00 UTC.
  static Duration untilNextUtcMidnight(DateTime now) {
    final u = now.toUtc();
    final next = DateTime.utc(u.year, u.month, u.day + 1);
    return next.difference(u);
  }

  static String? _errorCode(Map<String, dynamic> json) {
    final c = json['code'];
    if (c is String && c.isNotEmpty) return c;
    for (final e in _inputErrors(json)) {
      final ic = e['code'];
      if (ic is String && ic.isNotEmpty) return ic;
    }
    return null;
  }

  static String? _errorMessage(Map<String, dynamic> json) {
    final parts = <String>[];
    final m = json['message'];
    if (m is String && m.isNotEmpty) parts.add(m);
    for (final e in _inputErrors(json)) {
      final d = e['description'];
      if (d is String && d.isNotEmpty && !parts.contains(d)) parts.add(d);
    }
    return parts.isEmpty ? null : parts.join(' / ');
  }

  static Iterable<Map<String, dynamic>> _inputErrors(Map<String, dynamic> json) {
    final details = json['errorDetails'];
    if (details is! Map) return const [];
    final list = details['inputErrors'];
    if (list is! List) return const [];
    return list.whereType<Map<Object?, Object?>>().map(Map<String, dynamic>.from);
  }
}

/// LinkedIn's `little` text format used by the Posts API `commentary`.
///
/// Every reserved character (`\ | { } @ [ ] ( ) < > # * _ ~`) must be
/// backslash-escaped to be shown literally, otherwise the post fails or is
/// parsed as markup. Hashtags written as `#word` are kept as LinkedIn
/// hashtag elements (the Posts API documents `#coding` in commentary).
/// Mentions are not generated: they need member URNs NEFORUM cannot look up,
/// so `@` is always escaped.
class LittleText {
  LittleText._();

  static final RegExp _reserved = RegExp(r'[\\|{}@\[\]()<>#*_~]');
  static final RegExp _hashtag = RegExp(r'(?<![\p{L}\p{N}_\\])#([\p{L}\p{N}]+)', unicode: true);

  /// Escapes [text] for the `commentary` field.
  static String escape(String text) {
    final out = StringBuffer();
    var cursor = 0;
    for (final m in _hashtag.allMatches(text)) {
      out.write(_escapePlain(text.substring(cursor, m.start)));
      out.write('#${m.group(1)}');
      cursor = m.end;
    }
    out.write(_escapePlain(text.substring(cursor)));
    return out.toString();
  }

  static String _escapePlain(String s) => s.replaceAllMapped(_reserved, (m) => '\\${m[0]}');
}
