import 'dart:typed_data';

import '../../http/neforum_http.dart';
import '../../model/media.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import '../platform_adapter.dart';
import 'art_api_common.dart';

/// The signed-in DeviantArt user (from `GET /user/whoami`).
class DeviantArtUser {
  const DeviantArtUser({required this.username, this.id, this.icon});

  final String username;
  final String? id;
  final String? icon;
}

/// What `stash/publish` hands back.
class DeviantArtDeviation {
  const DeviantArtDeviation({required this.id, required this.url});

  final String id;
  final String url;
}

/// Thin client for the parts of the DeviantArt API NEFORUM uses: the signed-in
/// user and the two-step Sta.sh post (submit a file as a private draft, then
/// publish it as a deviation).
///
/// Endpoints and fields follow deviantart.readme.io (stash/submit,
/// stash/publish, authentication, errors; read 2026-10-25). Every request
/// carries a User-Agent and accepts gzip, which DeviantArt requires (both
/// come from [NeforumHttp] and dart:io).
class DeviantArtApi {
  DeviantArtApi({required this.ctx, required this.accessToken});

  static final Uri authorizationEndpoint = Uri.parse('https://www.deviantart.com/oauth2/authorize');
  static final Uri tokenEndpoint = Uri.parse('https://www.deviantart.com/oauth2/token');
  static final Uri revokeEndpoint = Uri.parse('https://www.deviantart.com/oauth2/revoke');
  static final Uri whoamiEndpoint = Uri.parse('https://www.deviantart.com/api/v1/oauth2/user/whoami');
  static final Uri submitEndpoint = Uri.parse('https://www.deviantart.com/api/v1/oauth2/stash/submit');
  static final Uri publishEndpoint = Uri.parse('https://www.deviantart.com/api/v1/oauth2/stash/publish');

  /// `stash` for submit, `publish` for publish, `basic` for whoami.
  static const List<String> scopes = ['basic', 'stash', 'publish'];

  /// The API version NEFORUM was written against (`dA-minor-version`).
  static const String minorVersion = '20240701';

  final AdapterContext ctx;
  final String accessToken;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $accessToken',
        'Accept': 'application/json',
        'dA-minor-version': minorVersion,
      };

  Future<DeviantArtUser> whoami() async {
    final res = await ctx.http.get(whoamiEndpoint, headers: _headers);
    final j = res.jsonMap;
    return DeviantArtUser(
      username: (j['username'] as String?) ?? '',
      id: j['userid']?.toString(),
      icon: j['usericon'] as String?,
    );
  }

  /// `POST stash/submit`: puts one file in the user's Sta.sh as a private
  /// draft. Returns its `itemid`.
  Future<String> submit(
    MediaAttachment media,
    Uint8List bytes, {
    required String title,
    required String artistComments,
    required List<String> tags,
    required bool aiGenerated,
    required bool noAi,
  }) async {
    final body = MultipartBody()
      ..field('title', title)
      ..field('artist_comments', artistComments);
    for (final t in tags) {
      body.field('tags[]', t);
    }
    body
      ..field('is_ai_generated', '$aiGenerated')
      ..field('noai', '$noAi')
      ..file('file', bytes, fileName: media.fileName ?? 'artwork', contentType: media.mimeType);
    final res = await ctx.http.send(
      'POST',
      submitEndpoint,
      headers: {..._headers, 'Content-Type': body.contentType},
      bytes: body.bytes,
    );
    final id = res.jsonMap['itemid'];
    if (id == null) {
      throw AdapterException(PublishError.platform('DeviantArt accepted the file but returned no Sta.sh item', raw: res.body));
    }
    return '$id';
  }

  /// `POST stash/publish`: turns the Sta.sh item named in [form] (`itemid`)
  /// into a deviation.
  Future<DeviantArtDeviation> publish(Map<String, String> form) async {
    final res = await ctx.http.postForm(publishEndpoint, form, headers: _headers);
    final j = res.jsonMap;
    final url = j['url'] as String?;
    final id = j['deviationid']?.toString();
    if (url == null || id == null) {
      throw AdapterException(PublishError.platform('DeviantArt published the work but returned no address', raw: res.body));
    }
    return DeviantArtDeviation(id: id, url: url);
  }

  /// `POST /oauth2/revoke` (best effort).
  Future<void> revoke(String token) async {
    await ctx.http.postForm(revokeEndpoint, {'token': token}, headers: const {'Accept': 'application/json'}, throwOnError: false);
  }

  /// The words DeviantArt put in an error body (`error_description`, else
  /// `error`).
  static String? errorText(NeforumResponse r) {
    final j = r.jsonMap;
    for (final k in const ['error_description', 'error']) {
      final v = j[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  /// Turns a failed request into the right [PublishError], with what
  /// DeviantArt documents for its status codes and `error_code`s.
  static PublishError mapFailure(HttpFailure f, {String? context, bool publishing = false}) {
    final base = f.toPublishError(context: context);
    final prefix = context == null ? '' : '$context: ';
    final j = f.response.jsonMap;
    final text = errorText(f.response) ?? 'HTTP ${f.statusCode}';
    final error = (j['error'] as String?) ?? '';
    final code = j['error_code'] is int ? j['error_code'] as int : int.tryParse('${j['error_code']}');
    final raw = base.raw;
    if (error == 'unverified_account' || text.contains('unverified_account')) {
      return PublishError.auth(
        '${prefix}DeviantArt wants you to verify your email address first. Verify it on deviantart.com, then try again.',
        raw: raw,
        statusCode: f.statusCode,
      );
    }
    if (f.statusCode == 401 || error == 'invalid_token') {
      return PublishError.auth('${prefix}DeviantArt refused the sign-in ($text). Reconnect DeviantArt in Accounts.',
          raw: raw, statusCode: f.statusCode);
    }
    if (f.statusCode == 403 && error == 'insufficient_scope') {
      return PublishError.auth('${prefix}DeviantArt says NEFORUM may not post for you ($text). Reconnect DeviantArt and '
          'allow every permission.', raw: raw, statusCode: 403);
    }
    if (f.statusCode == 429) {
      return PublishError.quota('${prefix}DeviantArt is rate limiting requests; NEFORUM tries again later',
          raw: raw, statusCode: 429, retryAfter: f.response.retryAfter);
    }
    if (publishing && code != null) {
      final why = switch (code) {
        0 => 'you have to accept DeviantArt\'s submission policy first (submit once on deviantart.com)',
        1 => 'you have to accept DeviantArt\'s terms of service first (submit once on deviantart.com)',
        2 || 3 => 'DeviantArt did not accept the category ($text)',
        4 => 'DeviantArt did not accept the licence options ($text)',
        5 => 'the display resolution is larger than the image',
        8 => 'DeviantArt needs a preview image for this file',
        9 => 'this Sta.sh item is already published',
        _ => null,
      };
      if (why != null) return PublishError.validation('$prefix$why', raw: raw, statusCode: f.statusCode);
    }
    if (f.statusCode == 400) return PublishError.validation('$prefix$text', raw: raw, statusCode: 400);
    if (f.statusCode >= 500) {
      return PublishError.network('${prefix}DeviantArt had a problem ($text); NEFORUM tries again later',
          raw: raw, statusCode: f.statusCode, retryAfter: f.response.retryAfter);
    }
    return PublishError(
      kind: base.kind,
      message: '$prefix$text',
      retryable: base.retryable,
      statusCode: base.statusCode,
      raw: raw,
      retryAfter: base.retryAfter,
    );
  }
}
