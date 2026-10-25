import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../auth/auth_broker.dart';
import '../../auth/oauth2_pkce.dart';
import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../model/account.dart';
import '../../model/media.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'youtube_api.dart';
import 'youtube_descriptor.dart';

/// YouTube: the YouTube Data API v3 with the user's own Google Cloud OAuth
/// client ("Desktop app", loopback sign-in), plus a hand-off to the YouTube
/// app / upload page.
///
/// `PostVariant.extra` knobs (byokApi):
/// * `privacyStatus`: `public`, `unlisted` or `private`. Defaults from the
///   post visibility (public -> public, unlisted -> unlisted, else private).
///
/// Server-side scheduling: when `scheduledAt` lies in the future the video
/// is uploaded as `private` with `status.publishAt` (the API only accepts
/// `publishAt` on private, never-published videos) and YouTube makes it
/// PUBLIC at that time; [publish] then returns [PublishResult.scheduled] and
/// [cancelScheduled] deletes the held video. Because YouTube's scheduler can
/// only go public, unlisted/private posts, accounts whose sign-in cannot
/// delete videos, and accounts flagged as locked-private keep the schedule on
/// the device (NEFORUM uploads at the scheduled time). A `scheduledAt` that
/// has already passed is uploaded straight away.
/// * `categoryId`: YouTube category id, e.g. `'22'` (People & Blogs).
/// * `notifySubscribers`: default true; false skips subscriber notifications.
/// * `madeForKids`: default false (`status.selfDeclaredMadeForKids`).
/// * `containsSyntheticMedia`: disclose realistic AI-altered content.
class YouTubeAdapter extends PlatformAdapter {
  YouTubeAdapter({this.maxResumes = 3, this.resumeDelay = const Duration(seconds: 2)});

  /// How often an interrupted upload is resumed before giving up.
  final int maxResumes;

  /// Wait before each resume attempt.
  final Duration resumeDelay;

  static const privacyStatuses = {'public', 'unlisted', 'private'};

  @override
  PlatformDescriptor get descriptor => youtubeDescriptor;

  @override
  List<ConnectSpec> get connectSpecs => youtubeConnectSpecs;

  // ---------------------------------------------------------------- connect

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier == PlatformTier.handoff) {
      final name = (input['display_name'] ?? '').trim();
      return ConnectResult(
        account: ConnectedAccount(
          id: const Uuid().v4(),
          platformId: id,
          tier: tier,
          displayName: name.isEmpty ? 'YouTube' : name,
          createdAt: ctx.now(),
        ),
      );
    }
    if (tier != PlatformTier.byokApi) throw ConnectException('YouTube does not support the ${tier.label} tier');

    final clientId = (input['client_id'] ?? '').trim();
    final clientSecret = (input['client_secret'] ?? '').trim();
    if (clientId.isEmpty) {
      throw const ConnectException('Enter the Client ID of your Google OAuth client', field: 'client_id');
    }
    if (!clientId.endsWith('.apps.googleusercontent.com')) {
      throw const ConnectException('A Google Client ID ends in ".apps.googleusercontent.com"; copy it again',
          field: 'client_id');
    }

    final AuthBroker broker;
    try {
      broker = ctx.requireBroker();
    } on StateError {
      throw const ConnectException('Connecting YouTube needs a browser sign-in, which is not available here');
    }
    final spec = specFor(PlatformTier.byokApi);
    final redirect = broker.chooseRedirectUri(
      loopbackOk: spec.loopbackRedirectOk,
      customSchemeOk: spec.customSchemeRedirectOk,
      fixed: spec.fixedRedirectUri,
    );
    if (!_isLoopback(redirect)) {
      throw ConnectException('Google only accepts http://127.0.0.1 sign-ins for "Desktop app" clients '
          '(this device offered $redirect). Connect YouTube from NEFORUM on Windows or macOS.');
    }

    final client = _oauthClient(clientId, clientSecret);
    final OAuthTokens tokens;
    try {
      final request = client.buildAuthorizationUrl(redirectUri: redirect);
      final back = await broker.authorize(request.url, redirect);
      final code = client.extractCode(back, request);
      tokens = await client.exchangeCode(ctx.http,
          code: code, redirectUri: redirect, pkce: request.pkce, now: ctx.now());
    } on OAuthException catch (e) {
      throw ConnectException(_oauthMessage(e));
    } on AuthCancelled {
      rethrow;
    } on Object catch (e) {
      if (!isNetworkException(e)) rethrow;
      throw ConnectException('Could not reach Google ($e); check your connection and try again');
    }
    final granted = tokens.scope;
    if (granted != null && !granted.split(' ').contains(youtubeScopes.first)) {
      throw const ConnectException('Google did not grant the YouTube upload permission. Connect again and tick '
          'every YouTube box on the consent screen.');
    }

    final channel = await _channel(tokens.accessToken, ctx);
    final channelId = channel['id'] as String;
    final snip = _map(channel['snippet']);
    final title = (snip['title'] as String?) ?? '';
    final handle = snip['customUrl'] as String?;
    final thumbs = _map(snip['thumbnails']);
    final avatar = (_map(thumbs['default'])['url'] as String?) ?? (_map(thumbs['medium'])['url'] as String?);

    return ConnectResult(
      account: ConnectedAccount(
        id: 'youtube:$channelId',
        platformId: id,
        tier: PlatformTier.byokApi,
        displayName: title.isEmpty ? 'YouTube channel' : title,
        handle: handle,
        avatarUrl: avatar,
        profileUrl: 'https://www.youtube.com/channel/$channelId',
        createdAt: ctx.now(),
        config: {
          YouTubeConfigKeys.clientId: clientId,
          YouTubeConfigKeys.channelId: channelId,
          YouTubeConfigKeys.redirectUri: redirect.toString(),
          // Google returns the granted scopes; users may untick boxes.
          YouTubeConfigKeys.canDeleteVideos: granted == null || scopesAllowDelete(granted),
        },
      ),
      secrets: _tokensToSecrets(tokens, {if (clientSecret.isNotEmpty) YouTubeSecretKeys.clientSecret: clientSecret}, ctx),
    );
  }

  Future<Map<String, dynamic>> _channel(String token, AdapterContext ctx) async {
    final NeforumResponse res;
    try {
      res = await ctx.http.get(YouTubeEndpoints.channelsMine,
          headers: {'Authorization': 'Bearer $token'}, throwOnError: false);
    } on Object catch (e) {
      if (!isNetworkException(e)) rethrow;
      throw ConnectException('Signed in, but could not reach YouTube ($e); try again');
    }
    if (!res.ok) {
      final err = mapYouTubeError(res, context: 'Reading your YouTube channel', now: ctx.now());
      throw ConnectException('Signed in, but YouTube refused to show your channel: ${err.message}');
    }
    final items = res.jsonMap['items'];
    if (items is! List || items.isEmpty || items.first is! Map) {
      throw const ConnectException('This Google account has no YouTube channel. Create one at '
          'https://www.youtube.com/create_channel (or pick the right account when signing in) and connect again.');
    }
    final channel = Map<String, dynamic>.from(items.first as Map);
    if (channel['id'] is! String) throw const ConnectException('YouTube returned a channel without an id');
    return channel;
  }

  static OAuth2Client _oauthClient(String clientId, String clientSecret) => OAuth2Client(
        authorizationEndpoint: YouTubeEndpoints.authorize,
        tokenEndpoint: YouTubeEndpoints.token,
        clientId: clientId,
        clientSecret: clientSecret.isEmpty ? null : clientSecret,
        scopes: youtubeScopes,
        // Google installed-app flow: PKCE S256, client id/secret in the body.
        usePkce: true,
        clientAuth: ClientAuth.body,
        // Ask for a refresh token every time, also when re-connecting.
        extraAuthorizationParams: const {'access_type': 'offline', 'prompt': 'consent'},
      );

  static Map<String, String> _tokensToSecrets(OAuthTokens t, Map<String, String> existing, AdapterContext ctx) {
    final out = t.toSecrets(existing);
    final rexp = t.raw['refresh_token_expires_in'];
    final secs = rexp is int ? rexp : int.tryParse('${rexp ?? ''}');
    if (secs != null) {
      out[YouTubeSecretKeys.refreshExpiresAt] = ctx.now().add(Duration(seconds: secs)).toUtc().toIso8601String();
    }
    return out;
  }

  static String _oauthMessage(OAuthException e) {
    final code = e.error ?? '';
    final d = '$code ${e.description ?? ''}'.toLowerCase();
    if (code == 'access_denied') return 'You declined the Google sign-in. Connect again and allow access.';
    if (d.contains('redirect_uri')) {
      return 'Google rejected the sign-in address. Make sure the OAuth client type is "Desktop app" '
          '(Web or Android clients do not accept $youtubeLoopbackRedirect).';
    }
    if (code == 'invalid_client' || code == 'unauthorized_client' || d.contains('client_secret')) {
      return 'Google did not accept the Client ID / Client secret. Copy both again from Google Auth Platform > Clients.';
    }
    final detail = [e.error, e.description].whereType<String>().where((s) => s.isNotEmpty).join(': ');
    return 'Google sign-in failed${detail.isEmpty ? '' : ' ($detail)'}';
  }

  static bool _isLoopback(Uri u) =>
      u.scheme == 'http' && (u.host == '127.0.0.1' || u.host == '::1' || u.host == 'localhost') && u.hasPort;

  // ---------------------------------------------------------------- refresh

  @override
  Future<Map<String, String>?> refreshSecrets(
      ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.byokApi) return null;
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) throw const AdapterException(PublishError.auth(_notSignedIn));
    final now = ctx.now();
    if (!tokens.isExpired(now: now, leeway: const Duration(minutes: 5))) return null;

    final refresh = tokens.refreshToken;
    final clientId = account.configString(YouTubeConfigKeys.clientId);
    final refreshExp = DateTime.tryParse(secrets[YouTubeSecretKeys.refreshExpiresAt] ?? '');
    if (refresh == null || refresh.isEmpty || clientId.isEmpty || (refreshExp != null && !refreshExp.isAfter(now))) {
      throw const AdapterException(PublishError.auth(_expired));
    }
    ctx.log.info('Refreshing Google access token');
    try {
      final fresh = await _oauthClient(clientId, secrets[YouTubeSecretKeys.clientSecret] ?? '')
          .refresh(ctx.http, refreshToken: refresh, now: now);
      return _tokensToSecrets(fresh, secrets, ctx);
    } on OAuthException catch (e) {
      // invalid_grant (revoked, unused for 6 months, 7-day Testing expiry)
      // means reconnect; 429 and outages are retried later.
      final err = e.toRefreshError('Google');
      if (err.kind == PublishErrorKind.auth) {
        throw AdapterException(PublishError.auth(_expired, raw: e.toString(), statusCode: e.statusCode));
      }
      throw AdapterException(err);
    } on Object catch (e) {
      if (!isNetworkException(e)) rethrow;
      throw AdapterException(PublishError.network('Could not reach Google to refresh the sign-in ($e)'));
    }
  }

  static const _notSignedIn = 'YouTube is not signed in. Reconnect YouTube in Accounts.';
  static const _expired = 'Your Google sign-in for YouTube expired or was revoked. Reconnect YouTube in Accounts. '
      '(If your Google Cloud app is still in "Testing", Google ends sign-ins after 7 days: publish it to '
      '"In production" under Google Auth Platform > Audience.)';

  @override
  Future<void> disconnect(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.byokApi) return;
    final token = secrets[OAuthTokens.keyRefreshToken] ?? secrets[OAuthTokens.keyAccessToken];
    if (token == null || token.isEmpty) return;
    try {
      await ctx.http.postForm(YouTubeEndpoints.revoke, {'token': token}, throwOnError: false);
    } on Object catch (e) {
      ctx.log.warn('Google token revoke failed: $e');
    }
  }

  // --------------------------------------------------------------- validate

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = super.validate(variant, account);
    final videos = variant.media.where((m) => m.isVideo).toList();
    if (variant.media.isNotEmpty && videos.isEmpty) {
      issues.add(const ValidationIssue.error('youtube.video_required', 'YouTube posts need a video', field: 'media'));
    }
    if (_hasAngle(variant.title ?? '')) {
      issues.add(const ValidationIssue.warning(
          'youtube.title_angle_brackets', 'YouTube titles cannot contain < or >; they will be replaced by ‹ ›',
          field: 'title'));
    }
    if (_hasAngle(variant.text)) {
      issues.add(const ValidationIssue.warning('youtube.description_angle_brackets',
          'YouTube descriptions cannot contain < or >; they will be replaced by ‹ ›', field: 'text'));
      // ‹ › take 3 bytes each where < > took 1, against a 5000-byte limit.
      const max = 5000;
      final bytes = utf8.encode(sanitizeYouTubeText(variant.text)).length;
      if (bytes > max && utf8.encode(variant.text).length <= max) {
        issues.add(ValidationIssue.error('youtube.description_too_long',
            'With < and > replaced the description uses $bytes/5000 bytes on YouTube', field: 'text'));
      }
    }
    final tagLength = youtubeTagsLength(cleanTags(variant.tags));
    if (tagLength > 500) {
      issues.add(ValidationIssue.error(
          'youtube.tags_too_long', 'Tags use $tagLength/500 characters on YouTube (commas and quotes count)',
          field: 'tags'));
    }
    for (final v in videos) {
      if (v.durationMs != null && v.durationMs! > 15 * 60 * 1000) {
        issues.add(const ValidationIssue.info('youtube.long_video',
            'Videos over 15 minutes need a phone-verified YouTube channel', field: 'media'));
      }
    }
    if (account.tier != PlatformTier.byokApi) return issues;

    final privacy = variant.extraAs<String>('privacyStatus');
    if (privacy != null && !privacyStatuses.contains(privacy)) {
      issues.add(ValidationIssue.error(
          'youtube.privacy_invalid', 'Unknown YouTube privacy "$privacy" (use public, unlisted or private)',
          field: 'account'));
    }
    // Only a schedule that is still ahead is handed to YouTube; a passed one
    // means "upload now" (the local scheduler's fallback), so no clock-free
    // check here could be right. Errors make the service keep the schedule
    // on this device.
    final at = variant.scheduledAt;
    if (at != null && at.isAfter(DateTime.now())) {
      final refusal = _scheduleRefusal(variant, account);
      issues.add(refusal == null
          ? const ValidationIssue.info('youtube.scheduled',
              'YouTube holds the video as private and makes it public at the scheduled time', field: 'scheduledAt')
          : ValidationIssue.error(refusal.$1, refusal.$2, field: 'scheduledAt'));
    }
    if (_privacyFor(variant) != 'private') {
      issues.add(const ValidationIssue.info('youtube.unaudited_private',
          'YouTube may lock uploads from your own (unaudited) Google Cloud project as private; '
          'NEFORUM warns you if that happens', field: 'account'));
    }
    return issues;
  }

  static bool _hasAngle(String s) => s.contains('<') || s.contains('>');

  /// Why YouTube must not hold this post (code, message), or `null` when it
  /// can. [scope] is the granted OAuth scope string when known (publish);
  /// validate only has the account config.
  static (String, String)? _scheduleRefusal(PostVariant v, ConnectedAccount account, {String? scope}) {
    final privacy = _privacyFor(v);
    if (privacy != 'public') {
      return (
        'youtube.schedule_not_public',
        'YouTube\'s own scheduler can only make a video public; NEFORUM uploads this $privacy video at the '
            'scheduled time instead'
      );
    }
    if (account.config[YouTubeConfigKeys.uploadsLockedPrivate] == true) {
      return (
        'youtube.schedule_locked_private',
        'YouTube locks this project\'s uploads as private, so a video held for later would never go public; '
            'NEFORUM uploads it at the scheduled time instead'
      );
    }
    final canDelete = scope != null ? scopesAllowDelete(scope) : account.config[YouTubeConfigKeys.canDeleteVideos] == true;
    if (!canDelete) {
      return (
        'youtube.schedule_needs_delete_permission',
        'To let YouTube hold scheduled videos, reconnect YouTube and allow NEFORUM to manage your videos (needed to '
            'take a held video back when you edit or cancel the post). Until then NEFORUM uploads at the scheduled time'
      );
    }
    return null;
  }

  /// The time YouTube should hold the video until, or `null` to publish now
  /// (no schedule, or one that has already passed).
  static DateTime? heldUntil(PostVariant v, DateTime now) {
    final at = v.scheduledAt;
    return at != null && at.isAfter(now) ? at : null;
  }

  // ---------------------------------------------------------------- publish

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.byokApi) {
      return PublishResult.failure(const PublishError.unsupported(
          'This YouTube account uses hand-off; NEFORUM opens YouTube instead of uploading through the API'));
    }
    try {
      return await _publish(variant, account, secrets, ctx);
    } on AdapterException catch (e) {
      return PublishResult.failure(e.error);
    } on Error {
      rethrow; // programming errors only
    } on Object catch (e) {
      return PublishResult.failure(youtubeNetworkError(e, 'YouTube', ctx.now()) ?? _unexpected(e));
    }
  }

  /// Non-network exceptions: a missing/unreadable video file (recognised by
  /// name, dart:io is off limits) or something else the user cannot fix.
  static PublishError _unexpected(Object e) {
    final text = e.toString();
    if (text.startsWith('FileSystemException') || text.contains('PathNotFoundException')) {
      return PublishError.configuration('The video file for this post is missing or unreadable; re-attach it ($text)');
    }
    return PublishError.platform('YouTube upload failed: $text', raw: text);
  }

  Future<PublishResult> _publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) throw const AdapterException(PublishError.auth(_notSignedIn));
    final videos = variant.media.where((m) => m.isVideo).toList();
    if (videos.isEmpty) throw const AdapterException(PublishError.validation('YouTube posts need a video'));
    if (videos.length > 1 || variant.media.length > 1) {
      throw const AdapterException(PublishError.validation('YouTube takes exactly one video per post'));
    }
    final video = videos.single;
    final now = ctx.now();
    final holdUntil = heldUntil(variant, now);
    if (holdUntil != null) {
      final refusal = _scheduleRefusal(variant, account, scope: tokens.scope);
      if (refusal != null) throw AdapterException(PublishError.unsupported(refusal.$2));
    }
    final metadata = buildMetadata(variant, now: now);

    ctx.progress('Reading video');
    final bytes = await ctx.readMedia(video);
    final uploader = YouTubeResumableUpload(
        ctx: ctx, accessToken: tokens.accessToken, maxResumes: maxResumes, resumeDelay: resumeDelay);
    final resource = await uploader.upload(
      metadata: metadata,
      bytes: bytes,
      mimeType: _uploadMime(video),
      notifySubscribers: variant.extraAs<bool>('notifySubscribers') ?? true,
    );

    final videoId = resource['id'];
    if (videoId is! String || videoId.isEmpty) {
      throw const AdapterException(PublishError.platform('YouTube finished the upload but returned no video id'));
    }
    _checkStatus(resource, metadata, videoId, ctx);
    final url = 'https://youtu.be/$videoId';
    if (holdUntil != null) {
      if (_map(resource['status'])['publishAt'] == null) {
        ctx.log.warn('YouTube did not echo publishAt for video $videoId; check in YouTube Studio that it is scheduled');
      }
      ctx.log.info('YouTube holds video $videoId as private until ${rfc3339(holdUntil)}');
      return PublishResult.scheduled(remoteId: videoId, scheduledFor: holdUntil, remoteUrl: url);
    }
    return PublishResult.ok(remoteId: videoId, remoteUrl: url, publishedAt: ctx.now());
  }

  // ------------------------------------------------------------- scheduled

  /// Deletes the video YouTube holds for a scheduled post (`videos.delete`,
  /// needs `youtube.force-ssl`). A video that is already gone (404
  /// `videoNotFound`) counts as removed.
  @override
  Future<void> cancelScheduled(
      PublishResult held, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.byokApi) {
      throw const AdapterException(PublishError.unsupported('Hand-off YouTube accounts have no scheduled uploads'));
    }
    final videoId = held.remoteId?.trim() ?? '';
    if (videoId.isEmpty) {
      throw const AdapterException(PublishError.platform(
          'NEFORUM does not know which YouTube video holds this post; delete it in YouTube Studio'));
    }
    // The caller passes fresh secrets; refresh anyway if they are about to
    // lapse (Google keeps the same refresh token, so nothing is lost).
    final current = await refreshSecrets(account, secrets, ctx) ?? secrets;
    final tokens = OAuthTokens.fromSecrets(current);
    if (tokens == null) throw const AdapterException(PublishError.auth(_notSignedIn));
    final NeforumResponse res;
    try {
      res = await ctx.http.delete(YouTubeEndpoints.video(videoId),
          headers: {'Authorization': 'Bearer ${tokens.accessToken}'}, throwOnError: false);
    } on Object catch (e) {
      if (!isNetworkException(e)) rethrow;
      throw AdapterException(PublishError.network('Could not reach YouTube to delete the scheduled video ($e)'));
    }
    if (res.ok) {
      ctx.log.info('Deleted scheduled YouTube video $videoId');
      return;
    }
    final (reason, _) = googleErrorReason(res);
    if (res.statusCode == 404 && (reason == 'videoNotFound' || reason == 'notFound')) {
      ctx.log.info('Scheduled YouTube video $videoId was already gone');
      return;
    }
    throw AdapterException(mapYouTubeError(res, context: 'Deleting the scheduled YouTube video', now: ctx.now()));
  }

  /// Builds the `videos.insert` JSON body (`snippet` + `status`).
  Map<String, dynamic> buildMetadata(PostVariant v, {required DateTime now}) {
    final title = _title(v);
    final tags = cleanTags(v.tags);
    final tagLength = youtubeTagsLength(tags);
    if (tagLength > 500) {
      throw AdapterException(PublishError.validation('Tags use $tagLength/500 characters on YouTube'));
    }
    final category = v.extra['categoryId'];
    final categoryId = category is int || category is String ? '$category'.trim() : '';
    final language = (v.language ?? '').trim();

    final privacyOverride = v.extraAs<String>('privacyStatus');
    if (privacyOverride != null && !privacyStatuses.contains(privacyOverride)) {
      throw AdapterException(PublishError.validation('Unknown YouTube privacy "$privacyOverride"'));
    }
    // publishAt is only accepted on private videos; a time that has passed
    // means "publish now", so it is not sent at all.
    final scheduled = heldUntil(v, now);
    final synthetic = v.extraAs<bool>('containsSyntheticMedia');

    return {
      'snippet': {
        'title': title,
        'description': sanitizeYouTubeText(v.text),
        if (tags.isNotEmpty) 'tags': tags,
        if (categoryId.isNotEmpty) 'categoryId': categoryId,
        if (language.isNotEmpty) 'defaultLanguage': language,
      },
      'status': {
        'privacyStatus': scheduled != null ? 'private' : _privacyFor(v),
        if (scheduled != null) 'publishAt': rfc3339(scheduled),
        'selfDeclaredMadeForKids': v.extraAs<bool>('madeForKids') ?? false,
        if (synthetic != null) 'containsSyntheticMedia': synthetic,
      },
    };
  }

  static String _privacyFor(PostVariant v) {
    final explicit = v.extraAs<String>('privacyStatus');
    if (explicit != null && privacyStatuses.contains(explicit)) return explicit;
    return switch (v.visibility) {
      Visibility.public => 'public',
      Visibility.unlisted => 'unlisted',
      Visibility.followers || Visibility.private => 'private',
    };
  }

  static String _title(PostVariant v) {
    var t = sanitizeYouTubeText(v.title ?? '').trim();
    if (t.isEmpty) {
      t = sanitizeYouTubeText(v.text)
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    }
    if (t.isEmpty) throw const AdapterException(PublishError.validation('YouTube videos need a title'));
    final runes = t.runes.toList();
    if (runes.length > 100) t = '${String.fromCharCodes(runes.take(99))}…';
    return t;
  }

  static String _uploadMime(MediaAttachment m) => m.mimeType.startsWith('video/') ? m.mimeType : 'application/octet-stream';

  void _checkStatus(Map<String, dynamic> resource, Map<String, dynamic> metadata, String videoId, AdapterContext ctx) {
    final status = _map(resource['status']);
    final upload = status['uploadStatus'] as String?;
    if (upload == 'rejected') {
      final reason = status['rejectionReason'] as String? ?? 'unknown';
      throw AdapterException(PublishError.validation('YouTube rejected the video ($reason)', raw: '$resource'));
    }
    if (upload == 'failed') {
      final reason = status['failureReason'] as String? ?? 'unknown';
      throw AdapterException(PublishError.platform('YouTube could not process the video ($reason)', raw: '$resource'));
    }
    final requested = _map(metadata['status'])['privacyStatus'];
    final actual = status['privacyStatus'];
    if (requested != 'private' && actual == 'private') {
      ctx.log.warn('YouTube set video $videoId to PRIVATE although "$requested" was requested. Uploads from '
          'unaudited Google Cloud projects are locked private; re-upload it in YouTube or use hand-off.');
      ctx.progress('Uploaded, but YouTube made the video private (unaudited API project)');
    }
  }

  // ------------------------------------------------------------ hand-off

  /// YouTube's upload page. It forwards to the upload dialog of YouTube
  /// Studio (studio.youtube.com), where the browser extension fills in the
  /// video, title and description.
  static const String uploadUrl = 'https://www.youtube.com/upload';

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final title = sanitizeYouTubeText(variant.title ?? '').trim();
    final description = sanitizeYouTubeText(variant.text).trim();
    final tags = cleanTags(variant.tags);
    final hasVideo = variant.media.any((m) => m.isVideo);
    // The description is the text to paste; the title and tags are separate
    // fields, so they are snippets (copied one by one, filled in by the
    // browser extension on YouTube Studio's upload page).
    final paste = [
      if (title.isNotEmpty) 'Paste the title listed below into **Title**.',
      if (description.isNotEmpty) 'Paste the description into **Description**: it is on the clipboard.',
      if (tags.isNotEmpty) 'Under **Show more**, paste the tags listed below into **Tags**.',
    ];
    final steps = [
      hasVideo
          ? 'Pick **YouTube** in the share sheet (on a computer, drop the file onto the YouTube upload page).'
          : 'YouTube needs a video; add one in NEFORUM or pick it on the YouTube upload page.',
      ...paste,
      hasVideo
          ? 'Choose who the video is for and the visibility (and the schedule, if any), then tap **Upload** / **Publish**.'
          : 'Choose who the video is for and the visibility, then click **Publish**.',
    ];
    final composerSteps = [
      'YouTube Studio opens its upload page (sign in if asked), and the NEFORUM browser extension adds '
          '${[if (hasVideo) 'your video', if (title.isNotEmpty) 'the title', if (description.isNotEmpty) 'the description', if (tags.isNotEmpty) 'the tags'].join(', ')}.',
      'Answer **Is this video made for kids?**: YouTube requires your own answer.',
      'Go through the next screens, choose the visibility, then click **Publish** (or **Save**).',
    ];
    return HandoffPlan(
      platformId: id,
      preferred: hasVideo ? HandoffMethod.shareSheet : HandoffMethod.manual,
      clipboardText: description.isEmpty ? null : description,
      shareFiles: variant.media.where((m) => m.isVideo).toList(),
      androidPackage: 'com.google.android.youtube',
      iosScheme: 'youtube://',
      desktopUrl: uploadUrl,
      instructions: [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n'),
      snippets: [
        if (title.isNotEmpty) HandoffSnippet('Title', title),
        if (tags.isNotEmpty) HandoffSnippet('Tags', tags.join(', ')),
      ],
      mediaNote: 'YouTube takes only the video file from the share sheet and has no link that prefills a title or '
          'description, so NEFORUM copies them for you one by one. Schedule and thumbnail are set in YouTube.',
      composerUrl: hasVideo ? Uri.parse(uploadUrl) : null,
      composerInstructions: hasVideo ? [for (var i = 0; i < composerSteps.length; i++) '${i + 1}. ${composerSteps[i]}'].join('\n') : null,
    );
  }
}

// --------------------------------------------------------------- helpers

Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

/// YouTube forbids `<` and `>` in titles, descriptions and tags; swap them
/// for look-alike single guillemets instead of failing the upload.
String sanitizeYouTubeText(String s) => s.replaceAll('<', '‹').replaceAll('>', '›');

/// Tags without `#`, angle brackets or duplicates.
List<String> cleanTags(List<String> tags) {
  final seen = <String>{};
  final out = <String>[];
  for (final raw in tags) {
    final t = raw.trim().replaceFirst(RegExp('^#'), '').replaceAll(RegExp('[<>]'), '').trim();
    if (t.isEmpty || !seen.add(t.toLowerCase())) continue;
    out.add(t);
  }
  return out;
}

/// Length of [tags] as YouTube counts it against the 500-character limit:
/// commas between tags count, and a tag containing a space counts as if
/// wrapped in quotation marks.
int youtubeTagsLength(List<String> tags) {
  if (tags.isEmpty) return 0;
  var n = tags.length - 1;
  for (final t in tags) {
    n += t.runes.length + (t.contains(' ') ? 2 : 0);
  }
  return n;
}

/// RFC 3339 UTC timestamp without milliseconds, e.g. `2026-10-08T15:00:00Z`.
String rfc3339(DateTime t) {
  final u = t.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
      'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
}
