import 'dart:typed_data';

import '../../http/neforum_http.dart';
import '../../model/media.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import 'art_api_common.dart';

/// The signed-in Dribbble user (from `GET /v2/user`).
class DribbbleUser {
  const DribbbleUser({required this.login, this.id, this.name, this.avatarUrl, this.profileUrl, this.canUploadShot});

  final String login;
  final String? id;
  final String? name;
  final String? avatarUrl;
  final String? profileUrl;

  /// False while the account may not upload shots (not yet a player or
  /// team).
  final bool? canUploadShot;
}

/// Thin client for the parts of Dribbble API v2 NEFORUM uses.
///
/// Endpoints and fields follow developer.dribbble.com/v2 (OAuth, Shots,
/// User; read 2026-10-25).
class DribbbleApi {
  DribbbleApi({required this.ctx, required this.accessToken});

  static final Uri authorizationEndpoint = Uri.parse('https://dribbble.com/oauth/authorize');
  static final Uri tokenEndpoint = Uri.parse('https://dribbble.com/oauth/token');
  static final Uri userEndpoint = Uri.parse('https://api.dribbble.com/v2/user');
  static final Uri shotsEndpoint = Uri.parse('https://api.dribbble.com/v2/shots');

  /// `public` reads the profile; `upload` creates shots.
  static const List<String> scopes = ['public', 'upload'];

  final AdapterContext ctx;
  final String accessToken;

  Map<String, String> get _headers => {'Authorization': 'Bearer $accessToken', 'Accept': 'application/json'};

  /// Public address of a shot.
  static String shotUrl(String id) => 'https://dribbble.com/shots/$id';

  Future<DribbbleUser> user() async {
    final res = await ctx.http.get(userEndpoint, headers: _headers);
    final j = res.jsonMap;
    final can = j['can_upload_shot'];
    return DribbbleUser(
      login: (j['login'] as String?) ?? '',
      id: j['id']?.toString(),
      name: j['name'] as String?,
      avatarUrl: j['avatar_url'] as String?,
      profileUrl: j['html_url'] as String?,
      canUploadShot: can is bool ? can : null,
    );
  }

  /// `POST /v2/shots`. Dribbble answers 202 with the new shot's address in
  /// `Location` while it processes the image; returns the shot id, or null
  /// when the address carries none.
  Future<String?> createShot(
    MediaAttachment image,
    Uint8List bytes, {
    required String title,
    required String description,
    required List<String> tags,
  }) async {
    final body = MultipartBody()..field('title', title);
    if (description.isNotEmpty) body.field('description', description);
    for (final t in tags) {
      body.field('tags[]', t);
    }
    body.file('image', bytes, fileName: image.fileName ?? 'shot', contentType: image.mimeType);
    final res = await ctx.http.send(
      'POST',
      shotsEndpoint,
      headers: {..._headers, 'Content-Type': body.contentType},
      bytes: body.bytes,
    );
    return shotIdFrom(res.headers['location']);
  }

  /// `https://api.dribbble.com/v2/shots/123` (or `/shots/123-title`) ->
  /// `123`.
  static String? shotIdFrom(String? location) {
    final segments = Uri.tryParse(location ?? '')?.pathSegments.where((s) => s.isNotEmpty).toList() ?? const [];
    final i = segments.lastIndexOf('shots');
    if (i < 0 || i + 1 >= segments.length) return null;
    final id = RegExp(r'^\d+').stringMatch(segments[i + 1]);
    return id;
  }

  /// What Dribbble wrote in an error body: `message`, then each of
  /// `errors[].message`.
  static String? errorText(NeforumResponse r) {
    final j = r.jsonMap;
    final parts = <String>[
      if (j['message'] is String && (j['message'] as String).trim().isNotEmpty) (j['message'] as String).trim(),
      for (final e in (j['errors'] as List? ?? const []))
        if (e is Map && e['message'] is String) [if (e['attribute'] is String) e['attribute'], e['message']].join(' '),
      if (j['error_description'] is String) j['error_description'] as String,
    ];
    return parts.isEmpty ? null : parts.join('; ');
  }

  static PublishError mapFailure(HttpFailure f, {String? context}) {
    final base = f.toPublishError(context: context);
    final prefix = context == null ? '' : '$context: ';
    final text = errorText(f.response) ?? 'HTTP ${f.statusCode}';
    final raw = base.raw;
    switch (f.statusCode) {
      case 401:
        return PublishError.auth('${prefix}Dribbble refused the sign-in ($text). Reconnect Dribbble in Accounts.',
            raw: raw, statusCode: 401);
      case 403:
        return PublishError.auth(
            '${prefix}Dribbble does not let this account upload shots yet ($text). Shots need an approved Designer '
            'account (a player) or a team.',
            raw: raw,
            statusCode: 403);
      case 429:
        return PublishError.quota('${prefix}Dribbble allows 60 requests a minute and 1,440 a day; NEFORUM tries again later',
            raw: raw, statusCode: 429, retryAfter: f.response.retryAfter);
      case 400:
      case 422:
        return PublishError.validation('$prefix$text', raw: raw, statusCode: f.statusCode);
      default:
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
}
