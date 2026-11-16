import 'dart:convert';

import '../../http/neforum_http.dart';
import '../../model/media.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import '../platform_adapter.dart';

/// A board the signed-in user can pin to (from `GET /v5/boards`).
class PinterestBoard {
  const PinterestBoard({required this.id, required this.name, this.privacy});

  final String id;
  final String name;
  final String? privacy;
}

/// The signed-in user (from `GET /v5/user_account`).
class PinterestUser {
  const PinterestUser({required this.username, this.id, this.accountType, this.profileImage, this.businessName});

  final String username;
  final String? id;

  /// `BUSINESS` or `PINNER`.
  final String? accountType;
  final String? profileImage;
  final String? businessName;
}

/// Thin client for the parts of Pinterest API v5 NEFORUM uses.
///
/// Endpoints and shapes follow the official OpenAPI description
/// (pinterest/api-description v5, 5.28.0).
///
/// [sandbox] sends every call to Pinterest's API Sandbox
/// (`api-sandbox.pinterest.com`): "Sandbox calls are the same as production
/// calls, except the subdomain" (developers.pinterest.com/docs/developer-tools/sandbox/,
/// read 2026-11-16). Apps with Trial access may create Pins only there; a
/// sandbox token does not work in production, nor the other way round.
class PinterestApi {
  PinterestApi({
    required this.ctx,
    required this.accessToken,
    this.sandbox = false,
    this.videoPollInterval = const Duration(seconds: 5),
    this.videoPollAttempts = 60,
  });

  static final Uri productionBase = Uri.parse('https://api.pinterest.com/v5/');
  static final Uri sandboxBase = Uri.parse('https://api-sandbox.pinterest.com/v5/');
  static final Uri authorizationEndpoint = Uri.parse('https://www.pinterest.com/oauth/');

  /// Production token endpoint.
  static final Uri tokenEndpoint = productionBase.resolve('oauth/token');

  /// "Generate a Sandbox token by inserting `-sandbox` into the request URL
  /// path" (set-up-authentication-and-authorization, read 2026-11-16).
  static final Uri sandboxTokenEndpoint = sandboxBase.resolve('oauth/token');

  static Uri baseFor({required bool sandbox}) => sandbox ? sandboxBase : productionBase;
  static Uri tokenEndpointFor({required bool sandbox}) => sandbox ? sandboxTokenEndpoint : tokenEndpoint;

  /// How long a sandbox token made with "Generate access token" on the app
  /// page lasts ("lasts 30 days", the sandbox page). It has no refresh token.
  static const Duration sandboxTokenLife = Duration(days: 30);

  /// Pinterest error `code` for "Apps with Trial access may not create Pins in
  /// production https://api.pinterest.com - use API Sandbox
  /// https://api-sandbox.pinterest.com instead."
  static const int trialProductionRefused = 29;

  /// `boards:write` and `pins:read` are listed by the OpenAPI security block of
  /// `POST /v5/pins`; Pinterest rejects pin creation without `boards:write`.
  static const List<String> scopes = [
    'boards:read',
    'boards:write',
    'pins:read',
    'pins:write',
    'user_accounts:read',
  ];

  /// Pinterest error `code` returned with HTTP 401 for apps whose Trial
  /// access is pending or denied ("consumer type is not supported").
  static const int consumerTypeNotSupported = 3;

  final AdapterContext ctx;
  final String accessToken;
  final bool sandbox;
  final Duration videoPollInterval;
  final int videoPollAttempts;

  Map<String, String> get _auth => {'Authorization': 'Bearer $accessToken', 'Accept': 'application/json'};

  /// [path] on this client's host: the sandbox or production.
  Uri endpoint(String path, [Map<String, String>? query]) {
    final u = baseFor(sandbox: sandbox).resolve(path);
    return query == null ? u : u.replace(queryParameters: query);
  }

  /// Public URL of a Pin.
  static String pinUrl(String id) => 'https://www.pinterest.com/pin/$id/';

  // ---------------------------------------------------------------- reads

  Future<PinterestUser> userAccount() async {
    final res = await ctx.http.get(endpoint('user_account'), headers: _auth);
    final j = res.jsonMap;
    return PinterestUser(
      username: (j['username'] as String?) ?? '',
      id: j['id']?.toString(),
      accountType: j['account_type'] as String?,
      profileImage: j['profile_image'] as String?,
      businessName: j['business_name'] as String?,
    );
  }

  /// Every board the user owns or collaborates on (follows `bookmark`
  /// pagination, at most [maxPages] pages of 250).
  ///
  /// In the sandbox Pinterest filters production boards out after it fetched
  /// each page, so a page can come back empty with a bookmark while sandbox
  /// boards follow (the sandbox page). There the default walks further.
  Future<List<PinterestBoard>> boards({int? maxPages}) async {
    final pages = maxPages ?? (sandbox ? 40 : 10);
    final out = <PinterestBoard>[];
    String? bookmark;
    for (var page = 0; page < pages; page++) {
      final res = await ctx.http.get(
        endpoint('boards', {'page_size': '250', if (bookmark != null) 'bookmark': bookmark}),
        headers: _auth,
      );
      final j = res.jsonMap;
      for (final item in (j['items'] as List? ?? const [])) {
        if (item is! Map) continue;
        final id = item['id']?.toString();
        if (id == null || id.isEmpty) continue;
        out.add(PinterestBoard(
          id: id,
          name: (item['name'] as String?) ?? id,
          privacy: item['privacy'] as String?,
        ));
      }
      bookmark = j['bookmark'] as String?;
      if (bookmark == null || bookmark.isEmpty) break;
    }
    return out;
  }

  // --------------------------------------------------------------- writes

  /// `POST /v5/boards`: a new board named [name]. Used in the sandbox, where
  /// the person's production boards do not exist.
  Future<PinterestBoard> createBoard(String name, {String? description}) async {
    final res = await ctx.http.postJson(
      endpoint('boards'),
      {'name': name, if (description != null) 'description': description},
      headers: _auth,
    );
    final j = res.jsonMap;
    final id = j['id']?.toString();
    if (id == null || id.isEmpty) {
      throw AdapterException(PublishError.platform('Pinterest did not return a board id', raw: _snippet(res.body)));
    }
    return PinterestBoard(id: id, name: (j['name'] as String?) ?? name, privacy: j['privacy'] as String?);
  }

  /// `POST /v5/pins`. Returns the new Pin's id.
  ///
  /// An inline image makes this POST an upload that is also the post
  /// ([inlineImages]). If the body never went out whole, Pinterest cannot have
  /// made the Pin. Once it has, a lost answer leaves that open, so it is not
  /// retried.
  Future<String> createPin(Map<String, Object?> body, {bool inlineImages = false}) async {
    final NeforumResponse res;
    try {
      res = await ctx.creating('Creating the Pin', () => ctx.http.postJson(endpoint('pins'), body, headers: _auth), uploads: inlineImages);
    } on AdapterException {
      rethrow;
    } on Exception catch (e) {
      final trace = NeforumHttp.uploadTrace(e);
      if (trace == null) rethrow;
      throw AdapterException(
          PublishError.network('${NeforumHttp.transportMessage(e)} This Pin was not created.', raw: NeforumHttp.transportDetails(e), uploadInterrupted: true));
    }
    final id = res.jsonMap['id']?.toString();
    if (id == null || id.isEmpty) {
      throw AdapterException(PublishError.platform('Pinterest did not return a Pin id', raw: _snippet(res.body)));
    }
    return id;
  }

  /// Image media source for one inline (base64) image.
  static Map<String, Object?> imageBase64Source(MediaAttachment m, List<int> bytes) => {
        'source_type': 'image_base64',
        'content_type': contentTypeOf(m),
        'data': base64Encode(bytes),
      };

  /// Carousel media source (2 to 5 inline images).
  static Map<String, Object?> multipleImageBase64Source(List<(MediaAttachment, List<int>)> images) => {
        'source_type': 'multiple_image_base64',
        'items': [
          for (final (m, bytes) in images) {'content_type': contentTypeOf(m), 'data': base64Encode(bytes)},
        ],
      };

  /// `image/jpeg` or `image/png`, the only values the API's ContentType enum
  /// accepts for base64 images.
  static String contentTypeOf(MediaAttachment m) {
    final t = m.mimeType.toLowerCase();
    if (t == 'image/png') return 'image/png';
    if (t == 'image/jpeg' || t == 'image/jpg' || t == 'image/pjpeg') return 'image/jpeg';
    throw AdapterException(PublishError.validation(
        '${m.fileName ?? m.id} is ${m.mimeType}; Pinterest only accepts JPEG or PNG uploads'));
  }

  /// Video upload: register (`POST /v5/media`), upload the file to the
  /// returned S3 URL with the signed form fields, then poll
  /// `GET /v5/media/{id}` until processing succeeded. Returns the media id.
  Future<String> uploadVideo(MediaAttachment video) async {
    final reg = await ctx.http.postJson(endpoint('media'), {'media_type': 'video'}, headers: _auth);
    final j = reg.jsonMap;
    final mediaId = j['media_id']?.toString();
    final uploadUrl = j['upload_url'] as String?;
    final params = (j['upload_parameters'] as Map? ?? const {})
        .map((k, v) => MapEntry(k.toString(), v.toString()));
    if (mediaId == null || uploadUrl == null) {
      throw AdapterException(PublishError.platform('Pinterest did not return a video upload slot', raw: _snippet(reg.body)));
    }

    final bytes = await ctx.readMedia(video);
    ctx.uploading(video, 'Uploading video to Pinterest');
    try {
      await ctx.http.multipart(
        Uri.parse(uploadUrl),
        fields: params,
        files: [
          HttpFilePart(
            field: 'file',
            bytes: bytes,
            fileName: video.fileName ?? '${video.id}.mp4',
            contentType: video.mimeType,
          ),
        ],
      );
    } on HttpFailure catch (e) {
      // S3 answers with XML; a 403 there means an expired upload policy, not
      // a Pinterest sign-in problem.
      throw AdapterException(e.statusCode >= 500
          ? PublishError.network('Video upload to Pinterest storage failed (HTTP ${e.statusCode})',
              raw: _snippet(e.body), statusCode: e.statusCode)
          : PublishError.platform('Video upload to Pinterest storage was refused (HTTP ${e.statusCode})',
              raw: _snippet(e.body), statusCode: e.statusCode, retryable: true));
    }

    ctx.serverWait('Waiting for Pinterest to process the video');
    for (var i = 0; i < videoPollAttempts; i++) {
      final res = await ctx.http.get(endpoint('media/$mediaId'), headers: _auth);
      final status = res.jsonMap['status'] as String?;
      if (status == 'succeeded') return mediaId;
      if (status == 'failed') {
        throw AdapterException(PublishError.validation(
            'Pinterest could not process the video (use MP4, H.264/H.265, 4 seconds to 5 minutes)',
            raw: _snippet(res.body)));
      }
      if (videoPollInterval > Duration.zero) await ctx.wait(videoPollInterval);
    }
    throw const AdapterException(PublishError.platform(
        'Pinterest is still processing the video; try publishing again in a few minutes',
        retryable: true));
  }

  // ------------------------------------------------------- error mapping

  /// Pinterest's answer to a Trial app creating a Pin in production (code
  /// [trialProductionRefused]): the app must use the API Sandbox.
  static bool isTrialProductionRefusal(HttpFailure f) {
    final j = f.response.jsonMap;
    final code = j['code'] is int ? j['code'] as int : int.tryParse('${j['code']}');
    if (code == trialProductionRefused) return true;
    final lower = ((j['message'] as String?) ?? '').toLowerCase();
    return lower.contains('api-sandbox') || (lower.contains('trial access') && lower.contains('production'));
  }

  /// What sandbox Pins are, in the words every message uses.
  static const String sandboxPinsNote = 'Sandbox Pins are test Pins: only you can see them, on your own profile. '
      'Public Pins need Standard access: click Upgrade on your app card at developers.pinterest.com/apps.';

  /// Maps a Pinterest HTTP failure (`{code, message}` body) onto a
  /// [PublishError].
  ///
  /// [trialAccess]: the account was connected as a Trial app. A Trial refusal
  /// then offers Reconnect, which moves the account to the API Sandbox; an
  /// account set up as Standard has the wrong access level and must be added
  /// again.
  static PublishError mapFailure(HttpFailure f, {String context = 'Pinterest', bool videoPin = false, bool trialAccess = true}) {
    final status = f.statusCode;
    final j = f.response.jsonMap;
    final code = j['code'] is int ? j['code'] as int : int.tryParse('${j['code']}');
    final message = (j['message'] as String?)?.trim() ?? '';
    final raw = _snippet(f.body);
    final detail = message.isEmpty ? 'HTTP $status' : message;
    final lower = message.toLowerCase();

    if (isTrialProductionRefusal(f)) {
      if (trialAccess) {
        return PublishError.auth(
            '$context: your Pinterest app has Trial access, and Pinterest lets Trial apps create Pins only in its '
            'API Sandbox. Reconnect Pinterest to move this account to the sandbox. $sandboxPinsNote',
            raw: raw,
            statusCode: status);
      }
      return PublishError(
        kind: PublishErrorKind.configuration,
        message: '$context: Pinterest says your app has Trial access, but this account was added as Standard access. '
            'In Accounts, remove this Pinterest account and add it again with Access level "trial" (or paste a '
            'sandbox token). $sandboxPinsNote',
        statusCode: status,
        raw: raw,
      );
    }

    if (status == 401 && (code == consumerTypeNotSupported || lower.contains('consumer type'))) {
      return PublishError(
        kind: PublishErrorKind.configuration,
        message: 'Your Pinterest developer app is not approved yet (Trial access pending or denied). '
            'Pinterest reviews apps on business days; check developers.pinterest.com/apps and try again later.',
        statusCode: status,
        raw: raw,
      );
    }
    if (status == 401) {
      if (videoPin) {
        return PublishError.auth(
            '$context: Pinterest refused the video Pin ($detail). Pinterest answers 401 when a video Pin has '
            'no usable cover image; if reconnecting does not help, set a cover image URL for the video.',
            raw: raw,
            statusCode: status);
      }
      return PublishError.auth('$context: your Pinterest sign-in expired or was revoked ($detail). Reconnect Pinterest.',
          raw: raw, statusCode: status);
    }
    if (status == 403) {
      if (lower.contains('scope') || lower.contains('missing')) {
        return PublishError.auth(
            '$context: NEFORUM lacks a Pinterest permission ($detail). Reconnect Pinterest and allow every permission.',
            raw: raw,
            statusCode: status,
            notAllowed: true);
      }
      return PublishError.platform('$context: Pinterest refused the request ($detail)', raw: raw, statusCode: status);
    }
    if (status == 404) {
      return PublishError(
        kind: PublishErrorKind.configuration,
        message: '$context: Pinterest could not find the board or media ($detail). '
            'Reconnect Pinterest and choose an existing board.',
        statusCode: status,
        raw: raw,
      );
    }
    if (status == 429) {
      return PublishError.quota('$context: Pinterest rate limit reached ($detail)',
          raw: raw, statusCode: status, retryAfter: f.response.retryAfter ?? _resetAfter(f.response));
    }
    if (status == 400 || status == 409 || status == 413 || status == 415 || status == 422) {
      return PublishError.validation('$context: Pinterest rejected the Pin ($detail)', raw: raw, statusCode: status);
    }
    if (status >= 500) {
      return PublishError.network('$context: Pinterest is having trouble (HTTP $status)',
          raw: raw, statusCode: status, retryAfter: f.response.retryAfter);
    }
    return f.toPublishError(context: context);
  }

  /// `x-ratelimit-reset` holds the seconds until the window resets.
  static Duration? _resetAfter(NeforumResponse r) {
    final v = r.headers['x-ratelimit-reset'];
    if (v == null) return null;
    final secs = int.tryParse(v.split(',').first.trim());
    return secs == null ? null : Duration(seconds: secs);
  }

  static String _snippet(String body) => body.length > 600 ? '${body.substring(0, 600)}…' : body;
}
