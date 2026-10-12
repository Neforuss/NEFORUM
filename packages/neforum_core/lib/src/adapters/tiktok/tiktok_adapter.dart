import 'dart:async';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../auth/oauth2_pkce.dart';
import '../../handoff/handoff_plan.dart';
import '../../media_hosts/media_host.dart';
import '../../model/account.dart';
import '../../model/media.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'tiktok_api.dart';
import 'tiktok_descriptor.dart';

/// TikTok: hand-off (share sheet / TikTok Studio) for everyone, plus the
/// Content Posting API with the user's own (usually unaudited, therefore
/// private-only) developer app.
///
/// `PostVariant.extra` knobs (byokApi):
/// * `privacyLevel`: `SELF_ONLY` (default), `PUBLIC_TO_EVERYONE`,
///   `MUTUAL_FOLLOW_FRIENDS`, `FOLLOWER_OF_CREATOR`; must be offered by
///   TikTok's creator_info for the account.
/// * `postMode`: `direct` (default) or `draft` (send to the TikTok inbox;
///   the user finishes the post in the app; video drafts carry no caption).
/// * `allowComments`, `allowDuet`, `allowStitch`: default false, as TikTok's
///   content-sharing guidelines require opt-in.
/// * `coverTimestampMs`, `photoCoverIndex`, `autoAddMusic`, `brandContent`
///   (paid partnership), `brandOrganic` (own business), `isAigc`.
class TikTokAdapter extends PlatformAdapter {
  TikTokAdapter({this.pollInterval = const Duration(seconds: 5), this.maxPolls = 60});

  /// Delay between `status/fetch` polls (limit is 30 per minute).
  final Duration pollInterval;

  /// Polls before giving up waiting; the post then keeps processing on
  /// TikTok's side and is reported as submitted.
  final int maxPolls;

  static const privacyLevels = {'PUBLIC_TO_EVERYONE', 'MUTUAL_FOLLOW_FRIENDS', 'FOLLOWER_OF_CREATOR', 'SELF_ONLY'};

  @override
  PlatformDescriptor get descriptor => tiktokDescriptor;

  @override
  List<ConnectSpec> get connectSpecs => tiktokConnectSpecs;

  // ---------------------------------------------------------------- connect

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier == PlatformTier.handoff) {
      final name = (input['display_name'] ?? '').trim();
      return ConnectResult(account: _account(tier, ctx, displayName: name.isEmpty ? 'TikTok' : name));
    }
    if (tier != PlatformTier.byokApi) throw ConnectException('TikTok does not support the ${tier.label} tier');
    final clientKey = (input['client_key'] ?? '').trim();
    final clientSecret = (input['client_secret'] ?? '').trim();
    if (clientKey.isEmpty) throw const ConnectException('Enter the client key of your TikTok app', field: 'client_key');
    if (clientSecret.isEmpty) {
      throw const ConnectException('Enter the client secret of your TikTok app', field: 'client_secret');
    }

    final broker = ctx.requireBroker();
    final redirect = broker.chooseRedirectUri(loopbackOk: true, customSchemeOk: false);
    if (!_isLoopback(redirect)) {
      throw ConnectException('TikTok only accepts http://127.0.0.1:PORT redirects for apps like NEFORUM '
          '(got $redirect). Connect this account from NEFORUM on Windows or macOS.');
    }
    final request = buildTikTokAuthorizationRequest(clientKey: clientKey, redirectUri: redirect);
    final back = await broker.authorize(request.url, redirect);
    final String code;
    try {
      code = OAuth2Client(
        authorizationEndpoint: TikTokEndpoints.authorize,
        tokenEndpoint: TikTokEndpoints.token,
        clientId: clientKey,
        clientSecret: clientSecret,
        usePkce: false,
      ).extractCode(back, request);
    } on OAuthException catch (e) {
      throw ConnectException('TikTok sign-in failed: ${e.description ?? e.error ?? e.message}');
    }

    try {
      final tokens = await tiktokTokenRequest(ctx, {
        'client_key': clientKey,
        'client_secret': clientSecret,
        'code': code,
        'grant_type': 'authorization_code',
        'redirect_uri': redirect.toString(),
        'code_verifier': request.pkce!.verifier,
      });
      final user = await tiktokCall(ctx, 'GET', TikTokEndpoints.userInfo, tokens.accessToken,
          context: 'TikTok user info');
      final u = user['user'] is Map ? Map<String, dynamic>.from(user['user'] as Map) : const <String, dynamic>{};
      final openId = (u['open_id'] as String?) ?? (tokens.raw['open_id'] as String?) ?? '';
      final name = (u['display_name'] as String?) ?? '';
      return ConnectResult(
        account: _account(
          tier,
          ctx,
          displayName: name.isEmpty ? 'TikTok' : name,
          avatarUrl: u['avatar_url'] as String?,
          config: {'clientKey': clientKey, if (openId.isNotEmpty) 'openId': openId},
        ),
        secrets: tiktokTokensToSecrets(tokens, {TikTokSecretKeys.clientSecret: clientSecret}, ctx.now()),
      );
    } on AdapterException catch (e) {
      throw ConnectException(e.error.message);
    }
  }

  ConnectedAccount _account(PlatformTier tier, AdapterContext ctx,
          {required String displayName, String? avatarUrl, Map<String, dynamic> config = const {}}) =>
      ConnectedAccount(
        id: const Uuid().v4(),
        platformId: descriptor.id,
        tier: tier,
        displayName: displayName,
        createdAt: ctx.now(),
        avatarUrl: avatarUrl,
        config: config,
      );

  static bool _isLoopback(Uri u) =>
      (u.scheme == 'http' || u.scheme == 'https') && (u.host == '127.0.0.1' || u.host == 'localhost') && u.hasPort;

  // ---------------------------------------------------------------- refresh

  @override
  Future<Map<String, String>?> refreshSecrets(
      ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.byokApi) return null;
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) {
      throw const AdapterException(PublishError.auth('No TikTok token stored; reconnect the account'));
    }
    final now = ctx.now();
    if (!tokens.isExpired(now: now, leeway: const Duration(minutes: 10))) return null;
    final refresh = tokens.refreshToken;
    final refreshExp = DateTime.tryParse(secrets[TikTokSecretKeys.refreshExpiresAt] ?? '');
    if (refresh == null || refresh.isEmpty || (refreshExp != null && !refreshExp.isAfter(now))) {
      throw const AdapterException(PublishError.auth('TikTok sign-in expired; reconnect the account'));
    }
    final clientKey = account.configString('clientKey');
    final clientSecret = secrets[TikTokSecretKeys.clientSecret] ?? '';
    if (clientKey.isEmpty || clientSecret.isEmpty) {
      throw const AdapterException(PublishError.auth('TikTok client key/secret missing; reconnect the account'));
    }
    ctx.log.info('Refreshing TikTok access token');
    final fresh = await tiktokTokenRequest(ctx, {
      'client_key': clientKey,
      'client_secret': clientSecret,
      'grant_type': 'refresh_token',
      'refresh_token': refresh,
    });
    return tiktokTokensToSecrets(fresh, secrets, now);
  }

  @override
  Future<void> disconnect(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final token = secrets[OAuthTokens.keyAccessToken];
    final clientKey = account.configString('clientKey');
    final clientSecret = secrets[TikTokSecretKeys.clientSecret];
    if (account.tier != PlatformTier.byokApi || token == null || clientKey.isEmpty || clientSecret == null) return;
    try {
      await ctx.http.postForm(TikTokEndpoints.revoke,
          {'client_key': clientKey, 'client_secret': clientSecret, 'token': token}, throwOnError: false);
    } on Object catch (e) {
      ctx.log.warn('TikTok token revoke failed: $e');
    }
  }

  // --------------------------------------------------------------- validate

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = super.validate(variant, account);
    final hasVideo = variant.media.any((m) => m.isVideo);
    final images = variant.media.where((m) => m.isImage).toList();
    for (final v in variant.media.where((m) => m.isVideo)) {
      for (final side in [v.width, v.height]) {
        if (side != null && (side < 360 || side > 4096)) {
          issues.add(const ValidationIssue.error(
              'tiktok.video_resolution', 'TikTok needs videos between 360 and 4096 pixels on each side', field: 'media'));
          break;
        }
      }
    }
    if (account.tier != PlatformTier.byokApi) return issues;

    final privacy = variant.extraAs<String>('privacyLevel');
    if (privacy != null && !privacyLevels.contains(privacy)) {
      issues.add(ValidationIssue.error('tiktok.privacy_invalid', 'Unknown TikTok privacy level "$privacy"', field: 'account'));
    }
    if ((privacy ?? 'SELF_ONLY') == 'SELF_ONLY') {
      issues.add(const ValidationIssue.info('tiktok.private_only',
          'Posts from an unaudited TikTok app are private ("Only me"); your TikTok account must be private too',
          field: 'account'));
      if (variant.extraAs<bool>('brandContent') == true) {
        issues.add(const ValidationIssue.error(
            'tiktok.branded_private', 'TikTok does not allow paid-partnership posts to be private', field: 'account'));
      }
    }
    if (images.isNotEmpty) {
      issues.add(const ValidationIssue.warning('tiktok.photo_needs_host',
          'TikTok photo posts need a media host on a domain verified in your TikTok developer app',
          field: 'media'));
    }
    if (hasVideo && (variant.title ?? '').trim().isNotEmpty) {
      issues.add(const ValidationIssue.info(
          'tiktok.title_ignored', 'TikTok videos have no separate title; only the caption is used', field: 'title'));
    }
    if (hasVideo && _isDraft(variant) && variant.text.trim().isNotEmpty) {
      issues.add(const ValidationIssue.warning('tiktok.draft_no_caption',
          'TikTok video drafts carry no caption; NEFORUM cannot prefill it, type it in the TikTok app', field: 'text'));
    }
    return issues;
  }

  // ---------------------------------------------------------------- publish

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.byokApi) {
      return PublishResult.failure(const PublishError.unsupported(
          'This TikTok account uses hand-off; NEFORUM opens TikTok instead of posting through the API'));
    }
    try {
      return await _publish(variant, secrets, ctx);
    } on AdapterException catch (e) {
      return PublishResult.failure(e.error);
    } on MediaHostException catch (e) {
      return PublishResult.failure(PublishError(kind: e.temporary ? PublishErrorKind.network : PublishErrorKind.configuration, message: e.message, retryable: true));
    } on Object catch (e) {
      final err = networkErrorFor(e, 'TikTok');
      if (err == null) rethrow;
      return PublishResult.failure(err);
    }
  }

  Future<PublishResult> _publish(PostVariant variant, Map<String, String> secrets, AdapterContext ctx) async {
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) throw const AdapterException(PublishError.auth('No TikTok token stored; reconnect the account'));
    final token = tokens.accessToken;
    final videos = variant.media.where((m) => m.isVideo).toList();
    final images = variant.media.where((m) => m.isImage).toList();
    if (videos.isEmpty && images.isEmpty) {
      throw const AdapterException(PublishError.validation('TikTok posts need a video or photos'));
    }
    if (videos.isNotEmpty && images.isNotEmpty) {
      throw const AdapterException(PublishError.validation('TikTok cannot mix a video and photos in one post'));
    }
    if (videos.length > 1) throw const AdapterException(PublishError.validation('TikTok takes one video per post'));
    if (images.isNotEmpty && ctx.mediaHost == null) {
      throw const AdapterException(PublishError.unsupported(
          'TikTok photo posts need a public media host (TikTok cannot receive photo uploads directly); '
          'configure one whose domain is verified in your TikTok developer app, or post a video'));
    }
    final draft = _isDraft(variant);

    _CreatorInfo? creator;
    if (!draft) {
      ctx.progress('Checking TikTok creator settings');
      creator = _CreatorInfo(await tiktokCall(ctx, 'POST', TikTokEndpoints.creatorInfo, token,
          body: const <String, dynamic>{}, context: 'TikTok creator info'));
    }
    return videos.isNotEmpty
        ? _publishVideo(variant, videos.single, token, creator, ctx)
        : _publishPhotos(variant, images, token, creator, ctx);
  }

  Future<PublishResult> _publishVideo(
      PostVariant variant, MediaAttachment video, String token, _CreatorInfo? creator, AdapterContext ctx) async {
    final maxSec = creator?.maxVideoSeconds;
    if (maxSec != null && maxSec > 0 && video.durationMs != null && video.durationMs! > maxSec * 1000) {
      throw AdapterException(PublishError.validation(
          'Video is ${(video.durationMs! / 1000).round()}s; this TikTok account allows ${maxSec}s'));
    }
    final Uint8List bytes = await ctx.readMedia(video);
    final plan = planTikTokChunks(bytes.length);
    final init = await tiktokCall(
      ctx,
      'POST',
      creator == null ? TikTokEndpoints.inboxVideoInit : TikTokEndpoints.videoInit,
      token,
      body: {
        if (creator != null) 'post_info': _videoPostInfo(variant, creator),
        'source_info': plan.toSourceInfo(),
      },
      context: 'TikTok video init',
    );
    final publishId = init['publish_id'] as String?;
    final uploadUrl = Uri.tryParse((init['upload_url'] as String?) ?? '');
    if (publishId == null || uploadUrl == null || !uploadUrl.hasScheme) {
      throw const AdapterException(PublishError.platform('TikTok did not return an upload URL'));
    }

    for (var i = 0; i < plan.totalChunkCount; i++) {
      final (start, end) = plan.range(i);
      ctx.progress(plan.totalChunkCount == 1
          ? 'Uploading video to TikTok'
          : 'Uploading video chunk ${i + 1} of ${plan.totalChunkCount}');
      final res = await ctx.http.putBytes(uploadUrl, Uint8List.sublistView(bytes, start, end),
          headers: {'Content-Type': video.mimeType, 'Content-Range': 'bytes $start-${end - 1}/${plan.videoSize}'},
          throwOnError: false);
      if (res.statusCode != 201 && res.statusCode != 206) {
        throw AdapterException(chunkUploadError(res, i, plan.totalChunkCount));
      }
    }
    final status = await _poll(publishId, token, ctx);
    return _result(publishId, status, creator, kind: 'video', ctx: ctx);
  }

  Future<PublishResult> _publishPhotos(PostVariant variant, List<MediaAttachment> images, String token,
      _CreatorInfo? creator, AdapterContext ctx) async {
    final host = ctx.mediaHost!; // checked in _publish
    final hosted = <HostedMedia>[];
    // Keep the hosted files while TikTok may still be downloading them.
    var cleanup = true;
    try {
      for (var i = 0; i < images.length; i++) {
        ctx.progress('Uploading image ${i + 1} of ${images.length} to ${host.name}');
        final h = await host.upload(images[i], await ctx.readMedia(images[i]), ttl: const Duration(hours: 2));
        hosted.add(h);
        if (h.url.scheme != 'https') {
          throw const AdapterException(PublishError.configuration('TikTok only fetches photos over HTTPS'));
        }
      }
      final cover = variant.extraAs<int>('photoCoverIndex') ?? 0;
      final init = await tiktokCall(
        ctx,
        'POST',
        TikTokEndpoints.contentInit,
        token,
        body: {
          'post_info': _photoPostInfo(variant, creator),
          'source_info': {
            'source': 'PULL_FROM_URL',
            'photo_cover_index': cover.clamp(0, images.length - 1),
            'photo_images': [for (final h in hosted) h.url.toString()],
          },
          'post_mode': creator == null ? 'MEDIA_UPLOAD' : 'DIRECT_POST',
          'media_type': 'PHOTO',
          if (variant.extraAs<bool>('isAigc') == true) 'is_aigc': true,
        },
        context: 'TikTok photo init',
      );
      final publishId = init['publish_id'] as String?;
      if (publishId == null) throw const AdapterException(PublishError.platform('TikTok returned no publish_id'));
      final status = await _poll(publishId, token, ctx);
      cleanup = status.terminal;
      return _result(publishId, status, creator, kind: 'photo', ctx: ctx);
    } finally {
      if (cleanup) await _cleanup(host, hosted, ctx);
    }
  }

  Future<void> _cleanup(MediaHost host, List<HostedMedia> hosted, AdapterContext ctx) async {
    for (final h in hosted) {
      try {
        await host.delete(h);
      } on Object catch (e) {
        ctx.log.warn('Could not delete ${h.url} from ${host.name}: $e');
      }
    }
  }

  // ----------------------------------------------------------- post_info

  Map<String, dynamic> _videoPostInfo(PostVariant v, _CreatorInfo c) {
    final cover = v.extraAs<int>('coverTimestampMs');
    return {
      if (v.text.trim().isNotEmpty) 'title': v.text,
      'privacy_level': _privacy(v, c),
      'disable_duet': c.duetDisabled || v.extraAs<bool>('allowDuet') != true,
      'disable_comment': c.commentDisabled || v.extraAs<bool>('allowComments') != true,
      'disable_stitch': c.stitchDisabled || v.extraAs<bool>('allowStitch') != true,
      if (cover != null) 'video_cover_timestamp_ms': cover,
      'brand_content_toggle': v.extraAs<bool>('brandContent') ?? false,
      'brand_organic_toggle': v.extraAs<bool>('brandOrganic') ?? false,
      if (v.extraAs<bool>('isAigc') == true) 'is_aigc': true,
    };
  }

  Map<String, dynamic> _photoPostInfo(PostVariant v, _CreatorInfo? c) {
    final title = (v.title ?? '').trim();
    final text = {
      if (title.isNotEmpty) 'title': title,
      if (v.text.trim().isNotEmpty) 'description': v.text,
    };
    if (c == null) return text; // MEDIA_UPLOAD (draft): only title/description.
    return {
      ...text,
      'privacy_level': _privacy(v, c),
      'disable_comment': c.commentDisabled || v.extraAs<bool>('allowComments') != true,
      'auto_add_music': v.extraAs<bool>('autoAddMusic') ?? false,
      'brand_content_toggle': v.extraAs<bool>('brandContent') ?? false,
      'brand_organic_toggle': v.extraAs<bool>('brandOrganic') ?? false,
    };
  }

  String _privacy(PostVariant v, _CreatorInfo c) {
    final p = v.extraAs<String>('privacyLevel') ?? 'SELF_ONLY';
    if (c.privacyOptions.isNotEmpty && !c.privacyOptions.contains(p)) {
      throw AdapterException(PublishError.validation(
          'TikTok privacy "$p" is not available for this account (allowed: ${c.privacyOptions.join(', ')})'));
    }
    if (p == 'SELF_ONLY' && v.extraAs<bool>('brandContent') == true) {
      throw const AdapterException(PublishError.validation('TikTok does not allow paid-partnership posts to be private'));
    }
    return p;
  }

  static bool _isDraft(PostVariant v) => v.extraAs<String>('postMode') == 'draft';

  // ------------------------------------------------------------ polling

  Future<_Status> _poll(String publishId, String token, AdapterContext ctx) async {
    ctx.progress('Waiting for TikTok to process the post');
    for (var i = 0; i < maxPolls; i++) {
      await Future<void>.delayed(pollInterval);
      final data = await tiktokCall(ctx, 'POST', TikTokEndpoints.statusFetch, token,
          body: {'publish_id': publishId}, context: 'TikTok status');
      final status = data['status'] as String? ?? '';
      switch (status) {
        case 'PUBLISH_COMPLETE':
        case 'SEND_TO_USER_INBOX':
          final ids = data['publicaly_available_post_id'];
          return _Status(status, [if (ids is List) for (final id in ids) '$id']);
        case 'FAILED':
          throw AdapterException(mapFailReason(data['fail_reason'] as String? ?? 'unknown'));
      }
    }
    ctx.log.warn('TikTok is still processing $publishId after $maxPolls checks; reporting it as submitted');
    return const _Status('PROCESSING', []);
  }

  PublishResult _result(String publishId, _Status s, _CreatorInfo? c, {required String kind, required AdapterContext ctx}) {
    final postId = s.postIds.isEmpty ? null : s.postIds.first;
    final user = c?.username;
    return PublishResult.ok(
      remoteId: postId ?? publishId,
      remoteUrl: postId != null && user != null && user.isNotEmpty ? 'https://www.tiktok.com/@$user/$kind/$postId' : null,
      publishedAt: ctx.now(),
    );
  }

  // ------------------------------------------------------------ hand-off

  /// TikTok Studio's upload page on its video and photo tabs.
  static const String studioVideoUploadUrl = 'https://www.tiktok.com/tiktokstudio/upload?tab=video';
  static const String studioPhotoUploadUrl = 'https://www.tiktok.com/tiktokstudio/upload?tab=photo';

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final caption = variant.text.trim();
    final hasMedia = variant.media.isNotEmpty;
    // Photos, including the text card made for a words-only post, go on the
    // photo tab; anything with a video on the video tab.
    final photoPost = hasMedia && variant.media.every((m) => m.isImage);
    final kind = photoPost ? (variant.media.length == 1 ? 'photo' : 'photos') : 'video';
    return HandoffPlan(
      platformId: descriptor.id,
      preferred: hasMedia ? HandoffMethod.shareSheet : HandoffMethod.manual,
      clipboardText: caption.isEmpty ? null : caption,
      shareText: caption.isEmpty ? null : caption,
      shareFiles: variant.media,
      androidPackage: 'com.zhiliaoapp.musically',
      iosScheme: 'snssdk1233://',
      desktopUrl: photoPost ? studioPhotoUploadUrl : studioVideoUploadUrl,
      instructions: hasMedia
          ? '1. On a phone pick **TikTok** in the share sheet. On a computer NEFORUM opens TikTok Studio\'s '
              '${photoPost ? 'photo' : 'video'} upload: use **Save media to Downloads** and drag the $kind onto it '
              '(or click **Select** and pick ${variant.media.length == 1 ? 'it' : 'them'}).\n'
              '2. Your caption is on the clipboard: click the caption box and press Ctrl+V (⌘V on a Mac; on a phone '
              'long-press and paste).\n'
              '3. Choose who can watch, then **Post**.'
          : '1. TikTok posts need a video or photos; add one in NEFORUM or in TikTok.\n'
              '2. Your caption is on the clipboard: paste it into the caption box.\n'
              '3. Tap **Post**.',
      mediaNote: 'TikTok ignores text passed with shared files, so the caption is copied to your clipboard. '
          'TikTok has no web link that prefills a post.',
    );
  }
}

/// Parsed `creator_info/query` data.
class _CreatorInfo {
  _CreatorInfo(Map<String, dynamic> d)
      : username = d['creator_username'] as String?,
        privacyOptions = [for (final o in (d['privacy_level_options'] as List? ?? const [])) '$o'],
        commentDisabled = d['comment_disabled'] == true,
        duetDisabled = d['duet_disabled'] == true,
        stitchDisabled = d['stitch_disabled'] == true,
        maxVideoSeconds = (d['max_video_post_duration_sec'] as num?)?.toInt();

  final String? username;
  final List<String> privacyOptions;
  final bool commentDisabled;
  final bool duetDisabled;
  final bool stitchDisabled;
  final int? maxVideoSeconds;
}

class _Status {
  const _Status(this.status, this.postIds);
  final String status;
  final List<String> postIds;
  bool get terminal => status != 'PROCESSING';
}
