import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../auth/auth_broker.dart';
import '../../auth/oauth2_pkce.dart';
import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../model/account.dart';
import '../../model/media.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'reddit_api.dart';
import 'reddit_descriptor.dart';
import 'reddit_media.dart';

/// Reddit through the official Data API with the user's own "installed app"
/// (OAuth 2.0 code flow, no PKCE, HTTP Basic with an empty secret), or
/// through a hand-off to Reddit's prefilled submit page.
///
/// Account config keys: `clientId`, `username`, `userId`,
/// `defaultSubreddit` (optional), `uaPlatform` (optional, the `<platform>`
/// part of the User-Agent, e.g. `android`).
///
/// Per-post `extra` keys: `subreddit`, `flairId`, `flairText`, `nsfw`,
/// `spoiler`, `sendReplies`, `resubmit`, `bodyAsComment`, `videoPoster`
/// (path of a thumbnail image), `videogif`.
class RedditAdapter extends PlatformAdapter {
  RedditAdapter({RedditSocketReader? socketReader, this.mediaSocketTimeout = const Duration(seconds: 90)})
      : _socketReader = socketReader ?? webSocketFirstMessage;

  final RedditSocketReader _socketReader;

  /// How long to wait for Reddit to report that an image/video post exists.
  final Duration mediaSocketTimeout;

  /// Scopes NEFORUM asks for.
  static const List<String> scopes = ['identity', 'submit', 'read', 'mysubreddits', 'flair'];

  static const String cfgClientId = 'clientId';
  static const String cfgUsername = 'username';
  static const String cfgUserId = 'userId';
  static const String cfgDefaultSubreddit = 'defaultSubreddit';
  static const String cfgUaPlatform = 'uaPlatform';

  /// Used as `<platform>` in the User-Agent when the app did not say which
  /// operating system it runs on.
  static const String defaultUaPlatform = 'cross-platform';

  static const String _desktopRedirect = 'http://127.0.0.1:52771/callback';
  static const String _mobileRedirect = 'neforum://callback';

  static final RegExp _subredditName = RegExp(r'^(u_[A-Za-z0-9_-]{3,20}|[A-Za-z0-9][A-Za-z0-9_]{1,20})$');

  /// `<platform>:org.neforum.app:v<version> (by /u/<username>)`, as the API
  /// rules ask. Before sign-in the username is unknown and left out.
  static String userAgent({String? username, String? platform}) {
    final p = (platform ?? '').trim().isEmpty ? defaultUaPlatform : platform!.trim();
    final by = (username ?? '').isEmpty ? '' : ' (by /u/$username)';
    return '$p:org.neforum.app:v$neforumVersion$by';
  }

  @override
  PlatformDescriptor get descriptor => redditDescriptor;

  static const String _apiIntro = '''
**Post automatically with your own Reddit app (free, non-commercial).**

> Since **11 November 2025** Reddit no longer hands out API access automatically: new apps need approval under its *Responsible Builder Policy*, and many requests are declined. If you already have an app at reddit.com/prefs/apps it keeps working. If you don't, use **Hand-off** instead.

1. Sign in to Reddit and open **https://www.reddit.com/prefs/apps** and press **create another app...**.
2. Name: `NEFORUM` (anything works). Type: choose **installed app** (not *script*, not *web app*).
3. Redirect uri: on a computer enter exactly `$_desktopRedirect`. A Reddit app has only one redirect uri, so for NEFORUM on a phone create a second installed app with `$_mobileRedirect`.
4. Press **create app**. The **client ID** is the short code under "installed app" at the top of the app box. Paste it below. There is no secret.
5. Press **Connect**: Reddit opens in your browser, you allow access, and you are done. NEFORUM asks for: identity, submit, read, mysubreddits, flair.''';

  static const String _handoffIntro = '''
**No app, no approval.** NEFORUM opens Reddit's "Create post" page with the title and text (or link) filled in, the text is also on your clipboard, and you press **Post** yourself.

On phones, images and videos go through the share sheet to the Reddit app. On a computer you attach them yourself.''';

  static const ConnectField _subredditField = ConnectField(
    key: 'default_subreddit',
    label: 'Default subreddit (optional)',
    required: false,
    placeholder: 'e.g. test  or  u_yourname for your profile',
    help: 'Used when a post does not name a subreddit. Without r/. You can choose another one per post.',
  );

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.byokApi,
          usesBrowser: true,
          intro: _apiIntro,
          redirectNote: 'Register $_desktopRedirect (computers) or $_mobileRedirect (phones) as the redirect uri of '
              'your Reddit installed app. Reddit allows one per app and compares it exactly.',
          loopbackRedirectOk: true,
          customSchemeRedirectOk: true,
          fields: [
            ConnectField(
              key: 'client_id',
              label: 'Client ID of your installed app',
              placeholder: 'e.g. p-jcoLKBynTLew',
              help: 'reddit.com/prefs/apps > your app > the code under "installed app".',
            ),
            _subredditField,
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.handoff,
          intro: _handoffIntro,
          fields: [
            ConnectField(
              key: 'username',
              label: 'Your Reddit username (optional)',
              required: false,
              placeholder: 'u/yourname',
              help: 'Only used to label this account in NEFORUM.',
            ),
            _subredditField,
          ],
        ),
      ];

  @override
  ConnectSpec specFor(PlatformTier tier) => super.specFor(_isApi(tier) ? PlatformTier.byokApi : tier);

  // ---------------------------------------------------------------------
  // Connect / refresh / disconnect
  // ---------------------------------------------------------------------

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    final defaultSr = _normalizeSubreddit(input['default_subreddit']);
    if (defaultSr != null && !_subredditName.hasMatch(defaultSr)) {
      throw const ConnectException('That is not a valid subreddit name (3-21 letters, digits or _)',
          field: 'default_subreddit');
    }
    if (tier == PlatformTier.handoff) return _connectHandoff(input, defaultSr, ctx);
    if (!_isApi(tier)) throw ConnectException('Reddit does not support the ${tier.label} tier in NEFORUM');

    final clientId = (input['client_id'] ?? '').trim();
    if (clientId.isEmpty) {
      throw const ConnectException('Paste the client ID of your Reddit installed app', field: 'client_id');
    }
    final uaPlatform = (input['ua_platform'] ?? '').trim();
    final AuthBroker broker;
    try {
      broker = ctx.requireBroker();
    } on StateError {
      throw const ConnectException('Connecting Reddit needs a browser sign-in, which is not available here');
    }
    final redirect = broker.chooseRedirectUri(loopbackOk: true, customSchemeOk: true);
    final client = _client(clientId, userAgent(platform: uaPlatform), compact: redirect.scheme != 'http');

    final OAuthTokens tokens;
    try {
      final request = client.buildAuthorizationUrl(redirectUri: redirect);
      final back = await broker.authorize(request.url, redirect);
      final code = client.extractCode(back, request);
      tokens = await client.exchangeCode(ctx.http, code: code, redirectUri: redirect, now: ctx.now());
    } on OAuthException catch (e) {
      throw ConnectException(_oauthHint(e, redirect));
    }

    final RedditUser user;
    try {
      user = await RedditApi(ctx, tokens.accessToken, userAgent: userAgent(platform: uaPlatform)).me();
    } on HttpFailure catch (e) {
      throw ConnectException('Signed in, but Reddit refused to read your profile: ${RedditApi.mapHttpError(e).message}');
    } on AdapterException catch (e) {
      throw ConnectException(e.error.message);
    }

    return ConnectResult(
      account: ConnectedAccount(
        id: 'reddit-${user.id}',
        platformId: id,
        tier: PlatformTier.byokApi,
        displayName: 'u/${user.name}',
        handle: 'u/${user.name}',
        avatarUrl: user.avatarUrl,
        profileUrl: 'https://www.reddit.com/user/${user.name}',
        createdAt: ctx.now(),
        config: {
          cfgClientId: clientId,
          cfgUsername: user.name,
          cfgUserId: user.id,
          if (defaultSr != null) cfgDefaultSubreddit: defaultSr,
          if (uaPlatform.isNotEmpty) cfgUaPlatform: uaPlatform,
        },
      ),
      secrets: tokens.toSecrets(),
    );
  }

  ConnectResult _connectHandoff(Map<String, String> input, String? defaultSr, AdapterContext ctx) {
    final name = (input['username'] ?? '').trim().replaceFirst(RegExp(r'^/?u/'), '');
    if (name.isNotEmpty && !RegExp(r'^[A-Za-z0-9_-]{3,20}$').hasMatch(name)) {
      throw const ConnectException('Reddit usernames have 3-20 letters, digits, - or _', field: 'username');
    }
    return ConnectResult(
      account: ConnectedAccount(
        id: 'reddit-handoff-${const Uuid().v4()}',
        platformId: id,
        tier: PlatformTier.handoff,
        displayName: name.isEmpty ? 'Reddit (hand-off)' : 'u/$name (hand-off)',
        handle: name.isEmpty ? null : 'u/$name',
        profileUrl: name.isEmpty ? null : 'https://www.reddit.com/user/$name',
        createdAt: ctx.now(),
        config: {
          if (name.isNotEmpty) cfgUsername: name,
          if (defaultSr != null) cfgDefaultSubreddit: defaultSr,
        },
      ),
    );
  }

  /// Access tokens last one hour. Reddit's refresh response carries no new
  /// refresh token, so the stored one is kept (toSecrets merges).
  @override
  Future<Map<String, String>?> refreshSecrets(
      ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (!_isApi(account.tier)) return null;
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) {
      throw const AdapterException(PublishError.auth('No Reddit sign-in stored for this account; reconnect it'));
    }
    if (!tokens.isExpired(now: ctx.now())) return null;
    final refresh = tokens.refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw const AdapterException(PublishError.auth('The Reddit sign-in expired and cannot be renewed; reconnect the account'));
    }
    final clientId = account.configString(cfgClientId);
    if (clientId.isEmpty) {
      throw const AdapterException(PublishError.auth('This Reddit account has no client ID stored; reconnect it'));
    }
    try {
      ctx.log.debug('Refreshing Reddit access token for ${account.displayName}');
      final fresh = await _client(clientId, _userAgentFor(account)).refresh(ctx.http, refreshToken: refresh, now: ctx.now());
      return fresh.toSecrets(secrets);
    } on OAuthException catch (e) {
      throw AdapterException(e.toRefreshError('Reddit'));
    } on Object catch (e) {
      if (NeforumHttp.isTransportError(e)) {
        throw AdapterException(PublishError.network('Could not reach Reddit to renew the sign-in: $e'));
      }
      rethrow;
    }
  }

  /// Revokes the refresh token (which also kills its access tokens).
  @override
  Future<void> disconnect(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final tokens = OAuthTokens.fromSecrets(secrets);
    final clientId = account.configString(cfgClientId);
    if (!_isApi(account.tier) || tokens == null || clientId.isEmpty) return;
    final refresh = tokens.refreshToken;
    try {
      await ctx.http.postForm(
        RedditEndpoints.revoke,
        {
          'token': refresh ?? tokens.accessToken,
          'token_type_hint': refresh != null ? 'refresh_token' : 'access_token',
        },
        headers: {'Authorization': _basic(clientId), 'User-Agent': _userAgentFor(account)},
      );
    } on Object catch (e) {
      ctx.log.warn('Could not revoke the Reddit token for ${account.displayName}', e);
    }
  }

  // ---------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = super.validate(variant, account);
    final api = _isApi(account.tier);
    final sr = subredditFor(variant, account);
    if (sr == null) {
      if (api) {
        issues.add(const ValidationIssue.error('reddit.subreddit_required',
            'Choose a subreddit for this post (or set a default subreddit on the account)', field: 'subreddit'));
      }
    } else if (!_subredditName.hasMatch(sr)) {
      issues.add(ValidationIssue.error('reddit.subreddit_invalid', '"$sr" is not a valid subreddit name', field: 'subreddit'));
    }
    final flairId = _extraString(variant, const ['flairId', 'flair_id']);
    if (flairId != null && flairId.length > redditFlairIdMax) {
      issues.add(const ValidationIssue.error('reddit.flair_id', 'Flair id is longer than 36 characters', field: 'flair'));
    }
    final flairText = _extraString(variant, const ['flairText', 'flair_text']);
    if (flairText != null && flairText.length > redditFlairTextMax) {
      issues.add(const ValidationIssue.error('reddit.flair_text', 'Flair text is longer than 64 characters', field: 'flair'));
    }
    if (variant.media.where((m) => m.isVideo).isNotEmpty && _extraString(variant, const ['videoPoster']) == null && api) {
      issues.add(const ValidationIssue.info('reddit.video_poster',
          'Reddit needs a video thumbnail; NEFORUM uploads a plain dark one unless you pick a poster image', field: 'media'));
    }
    final link = (variant.link ?? '').trim();
    if (link.isNotEmpty && variant.hasMedia) {
      issues.add(const ValidationIssue.info(
          'reddit.link_in_body', 'Media posts have no link field; the link is added to the text', field: 'link'));
    }
    final kind = _kindFor(variant);
    final body = _bodyFor(variant, kind);
    if (api && body.isNotEmpty && (kind == _Kind.link || kind == _Kind.image || kind == _Kind.video)) {
      if (_extraBool(variant, const ['bodyAsComment'], fallback: true)) {
        issues.add(const ValidationIssue.info('reddit.body_as_comment',
            'Link, image and video posts have no body; the text is posted as your first comment', field: 'text'));
        if (body.length > redditCommentMax) {
          issues.add(const ValidationIssue.error(
              'reddit.comment_too_long', 'The text is over the 10,000 characters a Reddit comment can hold', field: 'text'));
        }
      } else {
        issues.add(const ValidationIssue.warning(
            'reddit.body_dropped', 'Link, image and video posts have no body; the text will not be posted', field: 'text'));
      }
    }
    if (api && account.configString(cfgClientId).isEmpty) {
      issues.add(const ValidationIssue.error(
          'account.not_configured', 'This Reddit account has no client ID; reconnect it', field: 'account'));
    }
    return issues;
  }

  // ---------------------------------------------------------------------
  // Publish
  // ---------------------------------------------------------------------

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (!_isApi(account.tier)) {
      return PublishResult.failure(const PublishError.unsupported('This Reddit account posts through hand-off, not the API'));
    }
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) {
      return PublishResult.failure(const PublishError.auth('No Reddit sign-in stored for this account; reconnect it'));
    }
    final sr = subredditFor(variant, account);
    if (sr == null || !_subredditName.hasMatch(sr)) {
      return PublishResult.failure(PublishError.validation(sr == null
          ? 'Choose a subreddit for this Reddit post (or set a default subreddit on the account)'
          : '"$sr" is not a valid subreddit name'));
    }
    final title = (variant.title ?? '').trim();
    if (title.isEmpty) return PublishResult.failure(const PublishError.validation('Reddit posts need a title'));
    if (title.length > redditTitleMax) {
      return PublishResult.failure(PublishError.validation('The title is ${title.length}/$redditTitleMax characters'));
    }
    final api = RedditApi(ctx, tokens.accessToken, userAgent: _userAgentFor(account));
    try {
      return await _publish(variant, account, api, sr, title, ctx);
    } on AdapterException catch (e) {
      return PublishResult.failure(e.error);
    } on HttpFailure catch (e) {
      return PublishResult.failure(RedditApi.mapHttpError(e));
    } on Object catch (e) {
      if (NeforumHttp.isTransportError(e)) return PublishResult.failure(PublishError.network('Could not reach Reddit: $e'));
      if (e is FormatException) {
        return PublishResult.failure(PublishError.platform('Reddit sent a response NEFORUM did not understand: $e'));
      }
      rethrow;
    }
  }

  Future<PublishResult> _publish(
      PostVariant variant, ConnectedAccount account, RedditApi api, String sr, String title, AdapterContext ctx) async {
    final kind = _kindFor(variant);
    final body = _bodyFor(variant, kind);
    final common = _commonFields(variant, sr, title);
    final where = sr.startsWith('u_') ? 'your profile' : 'r/$sr';
    RedditSubmission sub;
    Uri? leaseSocket;
    switch (kind) {
      case _Kind.self:
        ctx.progress('Posting to $where');
        sub = await api.submit({...common, 'kind': 'self', 'text': body});
      case _Kind.link:
        ctx.progress('Posting to $where');
        sub = await api.submit({...common, 'kind': 'link', 'url': variant.link!.trim()});
      case _Kind.image:
        ctx.progress('Uploading image 1 of 1');
        final img = await _upload(api, variant.media.first, ctx);
        leaseSocket = img.websocketUrl;
        ctx.progress('Posting to $where');
        sub = await api.submit({...common, 'kind': 'image', 'url': img.url});
      case _Kind.gallery:
        sub = await _gallery(api, variant, common, body, where, ctx);
      case _Kind.video:
        ctx.progress('Uploading video');
        final video = await _upload(api, variant.media.firstWhere((m) => m.isVideo), ctx);
        leaseSocket = video.websocketUrl;
        ctx.progress('Uploading video thumbnail');
        final poster = await _uploadPoster(api, variant, ctx);
        ctx.progress('Posting to $where');
        sub = await api.submit({
          ...common,
          'kind': _extraBool(variant, const ['videogif']) ? 'videogif' : 'video',
          'url': video.url,
          'video_poster_url': poster.url,
        });
    }
    if (sub.id == null && (kind == _Kind.image || kind == _Kind.video)) {
      sub = await _awaitMedia(sub, leaseSocket, ctx);
    }
    final postId = sub.id;
    if (postId != null &&
        body.isNotEmpty &&
        kind != _Kind.self &&
        kind != _Kind.gallery &&
        _extraBool(variant, const ['bodyAsComment'], fallback: true)) {
      await _addBodyComment(api, postId, body, ctx);
    }
    if (postId == null) {
      ctx.log.warn('Reddit did not report the new post id; it was most likely created');
    }
    final username = account.configString(cfgUsername);
    return PublishResult.ok(
      remoteId: postId,
      remoteUrl: sub.url ??
          (postId != null ? 'https://www.reddit.com/comments/$postId' : null) ??
          sub.userSubmittedPage ??
          (username.isEmpty ? null : 'https://www.reddit.com/user/$username/submitted/'),
      publishedAt: ctx.now(),
    );
  }

  Future<RedditSubmission> _gallery(RedditApi api, PostVariant variant, Map<String, String> common, String body,
      String where, AdapterContext ctx) async {
    final images = variant.media.where((m) => m.isImage).toList();
    final items = <Map<String, Object?>>[];
    for (var i = 0; i < images.length; i++) {
      ctx.progress('Uploading image ${i + 1} of ${images.length}');
      final up = await _upload(api, images[i], ctx);
      items.add({'media_id': up.assetId, 'caption': '', 'outbound_url': ''});
    }
    ctx.progress('Posting to $where');
    return api.submitGallery({
      'api_type': 'json',
      'sr': common['sr'],
      'title': common['title'],
      'items': items,
      'nsfw': common['nsfw'] == 'true',
      'spoiler': common['spoiler'] == 'true',
      'sendreplies': common['sendreplies'] == 'true',
      'show_error_list': true,
      'validate_on_submit': true,
      if (common['flair_id'] != null) 'flair_id': common['flair_id'],
      if (common['flair_text'] != null) 'flair_text': common['flair_text'],
      if (body.isNotEmpty) 'text': body,
    });
  }

  /// Image/video submissions return no id; Reddit reports the post on a
  /// WebSocket once the media is processed. If that fails the post was most
  /// likely still created, so this never turns into a failure except when
  /// Reddit explicitly says processing failed.
  Future<RedditSubmission> _awaitMedia(RedditSubmission sub, Uri? leaseSocket, AdapterContext ctx) async {
    final ws = sub.websocketUrl ?? leaseSocket;
    if (ws == null) return sub;
    ctx.progress('Waiting for Reddit to process the media');
    String? message;
    try {
      message = await _socketReader(ws, mediaSocketTimeout);
    } on Object catch (e) {
      ctx.log.warn('Reddit media status socket failed; the post is probably still being created', e);
      return sub;
    }
    final status = message == null ? null : RedditMediaStatus.parse(message);
    if (status == null) return sub;
    if (status.failed) {
      throw AdapterException(PublishError.validation(
          'Reddit could not process the media${status.message == null ? '' : ': ${status.message}'}',
          raw: message));
    }
    final id = status.postId;
    return id == null ? sub : sub.withPost(id, status.redirect);
  }

  Future<void> _addBodyComment(RedditApi api, String postId, String body, AdapterContext ctx) async {
    ctx.progress('Adding your text as the first comment');
    try {
      await api.comment('t3_$postId', body);
    } on Object catch (e) {
      // The post exists; failing now would make a retry post it twice.
      ctx.log.warn('The post was created but Reddit refused the text as a comment', e);
    }
  }

  Future<RedditUploadedMedia> _upload(RedditApi api, MediaAttachment m, AdapterContext ctx) async {
    final mime = redditMimeType(m);
    final bytes = await _read(m, ctx);
    return api.uploadMedia(bytes, fileName: redditFileName(m, mime), mimeType: mime);
  }

  Future<RedditUploadedMedia> _uploadPoster(RedditApi api, PostVariant variant, AdapterContext ctx) async {
    final path = _extraString(variant, const ['videoPoster']);
    if (path == null) {
      return api.uploadMedia(placeholderPosterPng(), fileName: 'poster.png', mimeType: 'image/png');
    }
    final mime = posterMimeFor(path);
    final poster = MediaAttachment(id: 'poster', path: path, mimeType: mime, sizeBytes: 0);
    final bytes = await _read(poster, ctx);
    return api.uploadMedia(bytes, fileName: redditFileName(poster, mime), mimeType: mime);
  }

  static Future<Uint8List> _read(MediaAttachment m, AdapterContext ctx) async {
    try {
      return await ctx.readMedia(m);
    } on Exception catch (e) {
      throw AdapterException(PublishError.configuration('Could not read ${m.fileName ?? m.path}: $e'));
    }
  }

  Map<String, String> _commonFields(PostVariant v, String sr, String title) {
    final flairId = _extraString(v, const ['flairId', 'flair_id']);
    final flairText = _extraString(v, const ['flairText', 'flair_text']);
    return {
      'api_type': 'json',
      'sr': sr,
      'title': title,
      'nsfw': '${v.sensitive || _extraBool(v, const ['nsfw'])}',
      'spoiler': '${(v.contentWarning ?? '').trim().isNotEmpty || _extraBool(v, const ['spoiler'])}',
      'sendreplies': '${_extraBool(v, const ['sendReplies', 'sendreplies'], fallback: true)}',
      'resubmit': '${_extraBool(v, const ['resubmit'], fallback: true)}',
      'validate_on_submit': 'true',
      if (flairId != null) 'flair_id': flairId,
      if (flairText != null) 'flair_text': flairText,
    };
  }

  // ---------------------------------------------------------------------
  // Hand-off
  // ---------------------------------------------------------------------

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final sr = subredditFor(variant, account);
    final title = (variant.title ?? '').trim();
    final link = (variant.link ?? '').trim();
    final hasMedia = variant.hasMedia;
    final isLink = link.isNotEmpty && !hasMedia;
    final body = _bodyFor(variant, isLink ? _Kind.link : _Kind.self);
    final path = sr != null && _subredditName.hasMatch(sr) && !sr.startsWith('u_') ? '/r/$sr/submit' : '/submit';
    final intent = Uri.https('www.reddit.com', path, {
      if (title.isNotEmpty) 'title': title,
      if (isLink) 'url': link,
      if (!isLink && body.isNotEmpty) 'text': body,
    });
    final pickCommunity = path == '/submit';
    final steps = <String>[
      'NEFORUM opens Reddit\'s Create post page${pickCommunity ? '' : ' for r/$sr'} with the title filled in; '
          'your text is on the clipboard.',
      if (pickCommunity) 'Choose the community${sr != null && sr.startsWith('u_') ? ' (your profile)' : ''} to post in.',
      if (hasMedia) 'Attach your images or video (on phones the share sheet does it).',
      'Paste the text if it is missing, add flair if the community asks for it, and press **Post**.',
    ];
    return HandoffPlan(
      platformId: id,
      instructions: [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n'),
      webIntent: intent,
      clipboardText: body.isEmpty ? (isLink ? link : title) : body,
      shareText: [if (title.isNotEmpty) title, if (isLink) link else if (body.isNotEmpty) body].join('\n\n'),
      shareFiles: variant.media,
      androidPackage: 'com.reddit.frontpage',
      desktopUrl: intent.toString(),
      preferred: hasMedia ? HandoffMethod.shareSheet : HandoffMethod.webIntent,
      mediaNote: hasMedia
          ? 'Reddit\'s website cannot receive files from a link. On Android and iOS the share sheet hands them to '
              'the Reddit app (the title and text are on the clipboard); on a computer attach them yourself.'
          : null,
    );
  }

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------

  /// The target subreddit: `extra['subreddit']`, else the account default.
  /// Accepts `r/name`, `/r/name`, `u/name` (profile, becomes `u_name`).
  static String? subredditFor(PostVariant variant, ConnectedAccount? account) {
    final fromPost = _normalizeSubreddit(_extraString(variant, const ['subreddit', 'sr']));
    if (fromPost != null) return fromPost;
    final fromAccount = account?.config[cfgDefaultSubreddit];
    return fromAccount is String ? _normalizeSubreddit(fromAccount) : null;
  }

  static String? _normalizeSubreddit(String? raw) {
    var s = (raw ?? '').trim();
    if (s.isEmpty) return null;
    s = s.replaceFirst(RegExp(r'^https?://(www\.|old\.)?reddit\.com', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'/+$'), '');
    final user = RegExp(r'^/?(u|user)/([^/]+)$', caseSensitive: false).firstMatch(s);
    if (user != null) return 'u_${user.group(2)}';
    s = s.replaceFirst(RegExp(r'^/?r/', caseSensitive: false), '');
    return s.isEmpty ? null : s;
  }

  static _Kind _kindFor(PostVariant v) {
    final images = v.media.where((m) => m.isImage).length;
    if (v.media.any((m) => m.isVideo)) return _Kind.video;
    if (images >= 2) return _Kind.gallery;
    if (images == 1) return _Kind.image;
    if ((v.link ?? '').trim().isNotEmpty) return _Kind.link;
    return _Kind.self;
  }

  /// The Markdown body. For media posts the link (which has no field there)
  /// is appended; for link posts the link is the post itself.
  static String _bodyFor(PostVariant v, _Kind kind) {
    var text = (v.isThread ? v.threadParts.join('\n\n') : v.text).trim();
    final link = (v.link ?? '').trim();
    if (link.isNotEmpty && kind != _Kind.link && !text.contains(link)) {
      text = text.isEmpty ? link : '$text\n\n$link';
    }
    return text;
  }

  static String? _extraString(PostVariant v, List<String> keys) {
    for (final k in keys) {
      final x = v.extra[k];
      if (x is String && x.trim().isNotEmpty) return x.trim();
    }
    return null;
  }

  static bool _extraBool(PostVariant v, List<String> keys, {bool fallback = false}) {
    for (final k in keys) {
      final x = v.extra[k];
      if (x is bool) return x;
      if (x is String && (x == 'true' || x == 'false')) return x == 'true';
    }
    return fallback;
  }

  static bool _isApi(PlatformTier t) => t == PlatformTier.byokApi || t == PlatformTier.openApi;

  static String _userAgentFor(ConnectedAccount account) =>
      userAgent(username: account.configString(cfgUsername), platform: account.configString(cfgUaPlatform));

  static String _basic(String clientId) => 'Basic ${base64Encode(utf8.encode('$clientId:'))}';

  /// Installed apps are public clients: HTTP Basic with an empty secret, no
  /// PKCE (Reddit does not support it), `duration=permanent` for a refresh
  /// token, and the User-Agent on the token calls too.
  static OAuth2Client _client(String clientId, String ua, {bool compact = false}) => OAuth2Client(
        authorizationEndpoint: compact ? RedditEndpoints.authorizeCompact : RedditEndpoints.authorize,
        tokenEndpoint: RedditEndpoints.token,
        clientId: clientId,
        clientSecret: '',
        scopes: scopes,
        usePkce: false,
        clientAuth: ClientAuth.basic,
        extraAuthorizationParams: const {'duration': 'permanent'},
        extraHeaders: {'User-Agent': ua},
      );

  static String _oauthHint(OAuthException e, Uri redirect) {
    final why = e.description ?? e.error ?? e.message;
    final lower = '$why ${e.error ?? ''}'.toLowerCase();
    if (e.error == 'access_denied') return 'You did not allow NEFORUM on Reddit; press Connect to try again.';
    if (lower.contains('redirect')) {
      return 'Reddit refused the sign-in: $why. Set the redirect uri of your installed app to exactly $redirect.';
    }
    if (lower.contains('401') || lower.contains('client') || lower.contains('unauthorized')) {
      return 'Reddit refused the sign-in: $why. Check the client ID, that the app type is "installed app", and that '
          'your app is approved for API access (Reddit requires approval for new apps since November 2025).';
    }
    return 'Reddit refused the sign-in: $why';
  }
}

enum _Kind { self, link, image, gallery, video }
