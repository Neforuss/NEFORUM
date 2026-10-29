import 'package:characters/characters.dart';
import 'package:uuid/uuid.dart';

import '../../auth/auth_broker.dart';
import '../../auth/oauth2_pkce.dart';
import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../media_hosts/media_host.dart';
import '../../model/account.dart';
import '../../model/media.dart';
import '../../model/photo_fit.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../../text/rules_validator.dart';
import '../../text/url_detector.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'threads_api.dart';

/// Threads (Meta) through the official Threads API with the user's own Meta
/// app ("bring your own keys"), plus a hand-off tier that opens the Threads
/// web intent / app share sheet.
///
/// Publishing is Meta's two-step container flow: create a container
/// (`POST /{user}/threads`), wait until Meta reports it FINISHED (text
/// containers too), then `POST /{user}/threads_publish`, retrying a few
/// times when Meta answers "media not found". Media must be at a public URL,
/// so a configured [MediaHost] is required for images and video.
class ThreadsAdapter extends PlatformAdapter {
  /// [delay] is used between container-status polls and "media not found"
  /// retries (tests pass a no-op).
  ThreadsAdapter({ThreadsDelay delay = threadsDefaultDelay}) : _delay = delay;

  final ThreadsDelay _delay;

  static const String platformId = 'threads';

  /// Redirect URI NEFORUM suggests registering. Meta only accepts HTTPS
  /// redirect URIs; https://127.0.0.1 is accepted by the dashboard even
  /// though nothing listens there, so the user pastes the URL back.
  static final Uri suggestedRedirectUri = Uri.parse('https://127.0.0.1:52771/callback');

  static final Uri authorizationEndpoint = Uri.parse('https://threads.com/oauth/authorize');
  static final Uri tokenEndpoint = Uri.https(threadsGraphHost, '/oauth/access_token');
  static const List<String> scopes = ['threads_basic', 'threads_content_publish'];

  /// Values Meta accepts for `reply_control` on the API.
  static const Set<String> replyControlValues = {
    'everyone',
    'accounts_you_follow',
    'mentioned_only',
    'parent_post_author_only',
    'followers_only',
  };

  /// Subset accepted by the web intent's `reply_control`.
  static const Set<String> intentReplyControlValues = {
    'everyone',
    'accounts_you_follow',
    'mentioned_only',
    'followers_only',
  };

  static const int maxChars = 500;
  static const int maxCarouselItems = 20;
  static const int maxLinks = 5;
  static const int maxAltText = 1000;
  static const int maxTopicTag = 50;

  /// Secret keys (besides the [OAuthTokens] ones).
  static const String secretAppSecret = 'app_secret';
  static const String secretIssuedAt = 'token_issued_at';

  /// Config keys.
  static const String configAppId = 'app_id';
  static const String configUserId = 'user_id';
  static const String configRedirectUri = 'redirect_uri';
  static const String configUsername = 'username';

  /// `oauth` (browser sign-in) or `pasted` (token from the dashboard).
  static const String configTokenSource = 'token_source';

  /// Connect-form key of the optional pasted token.
  static const String fieldAccessToken = 'access_token';

  /// A pasted token that expires sooner than this is treated as a 1-hour
  /// token that must be exchanged for a 60-day one.
  static const Duration shortLivedThreshold = Duration(days: 1);

  /// [PostVariant.extra] keys.
  static const String extraReplyControl = 'reply_control';
  static const String extraTopicTag = 'topic_tag';

  static const _descriptor = PlatformDescriptor(
    id: platformId,
    name: 'Threads',
    iconKey: 'threads',
    homepage: 'https://www.threads.com',
    tiers: {PlatformTier.byokApi, PlatformTier.handoff},
    defaultTier: PlatformTier.byokApi,
    text: TextRules(
      maxLength: maxChars,
      counting: CountingRule.utf16,
      supportsThreads: true,
      supportsHashtags: true,
      linkInText: true,
      notes: '500 characters per post; Meta counts emoji as their UTF-8 byte length. '
          'One optional topic tag per post (extra "topic_tag"); at most 5 links.',
    ),
    media: MediaRules(
      // Sound goes as a video of one still picture, made by the app.
      audioAsVideo: true,
      maxImages: maxCarouselItems,
      maxVideos: maxCarouselItems,
      allowsMixedImageVideo: true,
      imageMaxBytes: 8 * 1024 * 1024,
      videoMaxBytes: 1024 * 1024 * 1024,
      videoMaxSeconds: 300,
      imageMimeTypes: {'image/jpeg', 'image/png'},
      videoMimeTypes: {'video/mp4', 'video/quicktime'},
      supportsAltText: true,
      requiresPublicMediaUrl: true,
      notes: 'JPEG/PNG up to 8 MB (320-1440 px wide, aspect ratio up to 10:1); MP4/MOV up to 1 GB and 5 minutes. '
          'Up to 20 items in a carousel. Meta downloads media from a public URL, so a media host is required.',
    ),
    defaultQuotas: [
      QuotaRule(
        id: 'threads.posts_per_day',
        limit: 250,
        window: Duration(hours: 24),
        note: 'posts per 24 hours (Threads API publishing limit; a carousel counts once)',
        appliesToTier: PlatformTier.byokApi,
      ),
    ],
    personalAccountOk: true,
    accountRequirements: 'Any Threads profile works. For automatic posting you create your own free Meta developer app '
        'with the "Access the Threads API" use case and add your profile as its Threads Tester, so no App Review '
        'is needed.',
    apiCostSummary: 'The Threads API is free. Each profile can publish up to 250 posts per day through it; '
        'images and videos must first be uploaded to a public media host you configure.',
    setupGuide: 'docs/platforms/threads.md',
    serverSideScheduling: false,
    supportsLinkField: false,
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  List<ConnectSpec> get connectSpecs => [_byokSpec, _handoffSpec];

  static final ConnectSpec _byokSpec = ConnectSpec(
    tier: PlatformTier.byokApi,
    usesBrowser: true,
    loopbackRedirectOk: false,
    customSchemeRedirectOk: false,
    fixedRedirectUri: suggestedRedirectUri,
    redirectNote: 'Register exactly https://127.0.0.1:52771/callback in your app under Use cases > '
        'Access the Threads API > Settings > Redirect Callback URLs (called Client OAuth Settings on some screens). '
        'Not needed when you paste a token.',
    intro: '''
**Post to your Threads profile through your own free Meta app** (about 10 minutes, once). Any Threads profile works; no App Review.

1. Open <https://developers.facebook.com/apps/creation/>, pick the use case **Access the Threads API** (add **Manage messaging & content on Instagram** too if you want one app for both) and finish the wizard. No business portfolio? Pick **I don't want to connect a business portfolio yet**.
2. **Use cases > Access the Threads API > Customize**: click **Add** next to `threads_content_publish` (`threads_basic` is already "Ready for testing").
3. **App roles > Roles > Add People**, choose **Threads Tester** and enter your Threads username. Accept the invite in Threads: **Settings > Account > Website permissions > Invites**.
4. Back in the use case open **Settings**. Below the app ID and secret, the **User Token Generator** lists your profile: click **Generate Access Token**, allow access in the pop-up, copy the token and paste it into the first field below. Your profile must be **public**. The token is long-lived (60 days) and NEFORUM renews it, so the app ID and secret can stay empty.
5. For images and videos, pick a **media host** in NEFORUM **Settings > Media hosting** (text-only posts need none). **Litterbox** needs no setup and is fine to start; for regular posting a bucket you own (Backblaze B2, Cloudflare R2, Amazon S3) is more reliable. The **Guide** button there explains each host.

**Browser sign-in instead of a token:** on the same Settings page add `https://127.0.0.1:52771/callback` under **Redirect Callback URLs** (some screens: **Client OAuth Settings**), put the same address in **Uninstall Callback URL** and **Delete Callback URL**, click **Save**, copy the **Threads app ID** and **Threads app secret** (not the Facebook App ID) into the fields below and press **Sign in**. After you allow access, paste the whole address of the page that does not load (`https://127.0.0.1:52771/callback?code=...`).
''',
    fields: [
      ConnectField(
        key: fieldAccessToken,
        label: 'Access token from the User Token Generator',
        kind: FieldKind.password,
        required: false,
        secret: true,
        help: '**Recommended.** Use cases > Access the Threads API > **Settings** > User Token Generator > '
            '**Generate Access Token**, for a public profile that has accepted its Threads Tester invite. The token '
            'is long-lived; NEFORUM checks it and renews it before it expires (60 days). With a token, the fields '
            'below can stay empty.',
      ),
      ConnectField(
        key: 'app_id',
        label: 'Threads app ID',
        required: false,
        placeholder: '1234567890123456',
        help: 'Use cases > Access the Threads API > **Settings** > Threads app ID (not the Facebook App ID). '
            'Only needed for browser sign-in.',
      ),
      ConnectField(
        key: secretAppSecret,
        label: 'Threads app secret',
        kind: FieldKind.password,
        required: false,
        secret: true,
        help: 'Same Settings page, next to the Threads app ID (click **Show**). Needed for browser sign-in. Not '
            'needed for a User Token Generator token (already long-lived); NEFORUM only asks for it if a pasted '
            'token lasts about an hour. Stays on this device.',
      ),
      ConnectField(
        key: configRedirectUri,
        label: 'Redirect URI you registered',
        kind: FieldKind.url,
        required: false,
        defaultValue: 'https://127.0.0.1:52771/callback',
        help: 'Only for browser sign-in. Must match the address under Redirect Callback URLs (some screens: '
            'Client OAuth Settings) exactly (watch for a trailing slash) and start with https://.',
      ),
    ],
  );

  static const ConnectSpec _handoffSpec = ConnectSpec(
    tier: PlatformTier.handoff,
    intro: '''
**Hand-off: no developer app needed.** NEFORUM opens the Threads composer with your text already
filled in (web intent on desktop, the Threads app on phones) and you tap **Post** yourself.
Images and videos cannot be prefilled on the web; on a phone they go through the share sheet.
''',
    fields: [
      ConnectField(
        key: 'username',
        label: 'Threads username (optional)',
        required: false,
        placeholder: 'yourname',
        help: 'Only used to label this account in NEFORUM.',
      ),
    ],
  );

  // ---- connect -----------------------------------------------------------

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier == PlatformTier.handoff) return _connectHandoff(input, ctx);
    if (tier != PlatformTier.byokApi) {
      throw ConnectException('Threads does not support the ${tier.label} tier');
    }
    final appId = (input[configAppId] ?? '').trim();
    final appSecret = (input[secretAppSecret] ?? '').trim();
    final pasted = (input[fieldAccessToken] ?? '').trim();
    if (appId.isNotEmpty && !RegExp(r'^\d+$').hasMatch(appId)) {
      throw const ConnectException('The Threads app ID is a number (copy it from Use cases > Access the Threads API > Settings)',
          field: configAppId);
    }
    if (pasted.isNotEmpty) return _connectWithToken(pasted, appId, appSecret, ctx);
    if (appId.isEmpty) {
      throw const ConnectException('Enter your Threads app ID, or paste a token from the User Token Generator',
          field: configAppId);
    }
    if (appSecret.isEmpty) throw const ConnectException('Enter your Threads app secret', field: secretAppSecret);
    final redirectInput = (input['redirect_uri'] ?? '').trim();
    final registered = redirectInput.isEmpty ? suggestedRedirectUri : Uri.tryParse(redirectInput);
    if (registered == null || registered.scheme != 'https' || registered.host.isEmpty) {
      throw const ConnectException('Meta only accepts redirect URIs that start with https://', field: 'redirect_uri');
    }
    if (ctx.broker == null) {
      throw const ConnectException('Connecting Threads needs a browser sign-in, which is not available here');
    }
    final broker = ctx.requireBroker();
    final redirect = broker.chooseRedirectUri(loopbackOk: false, customSchemeOk: false, fixed: registered);

    final client = OAuth2Client(
      authorizationEndpoint: authorizationEndpoint,
      tokenEndpoint: tokenEndpoint,
      clientId: appId,
      clientSecret: appSecret,
      scopes: scopes,
      scopeSeparator: ',',
      usePkce: false,
      clientAuth: ClientAuth.body,
    );
    final request = client.buildAuthorizationUrl(redirectUri: redirect);
    final back = await broker.authorize(request.url, redirect, timeout: const Duration(minutes: 10));
    final code = _extractCode(back, request);

    final now = ctx.now();
    final OAuthTokens short;
    try {
      short = await client.exchangeCode(ctx.http, code: code, redirectUri: redirect, now: now);
    } on OAuthException catch (e) {
      throw ConnectException('Threads refused the sign-in code (${e.description ?? e.error ?? e.message}). '
          'Check the app ID/secret and that the redirect URI matches exactly, then try again with a fresh code.');
    }
    final OAuthTokens long;
    final Map<String, dynamic> me;
    try {
      long = await ThreadsApi.exchangeForLongLived(ctx.http,
          clientSecret: appSecret, shortLivedToken: short.accessToken, now: now);
      me = await ThreadsApi(ctx.http, long.accessToken, delay: _delay, log: ctx.log).me();
    } on HttpFailure catch (f) {
      throw ConnectException('Threads did not accept the token: ${threadsErrorFrom(f).message}');
    } on AdapterException catch (e) {
      throw ConnectException('Threads did not accept the token: ${e.error.message}');
    }

    return ConnectResult(
      account: _apiAccount(me, now,
          fallbackUserId: short.raw['user_id'],
          config: {
            configAppId: appId,
            configRedirectUri: redirect.toString(),
            configTokenSource: 'oauth',
          }),
      secrets: long.toSecrets({
        secretAppSecret: appSecret,
        secretIssuedAt: now.toUtc().toIso8601String(),
      }),
    );
  }

  /// Connects with a token the user generated in the App Dashboard. Checks it
  /// with `GET /me`, reads its lifetime and permissions from `debug_token`
  /// when Meta answers, and swaps a 1-hour token for a 60-day one
  /// (`th_exchange_token`, which needs the app secret). The token is renewed
  /// later by [refreshSecrets] like an OAuth one.
  Future<ConnectResult> _connectWithToken(String token, String appId, String appSecret, AdapterContext ctx) async {
    final now = ctx.now();
    ctx.progress('Checking the Threads token');
    final Map<String, dynamic> me;
    try {
      me = await ThreadsApi(ctx.http, token, delay: _delay, log: ctx.log).me();
    } on AdapterException catch (e) {
      throw ConnectException('Threads did not accept the token: ${e.error.message}. Generate a new one and paste '
          'all of it.', field: fieldAccessToken);
    }
    final info = await ThreadsApi.debugToken(ctx.http, token, log: ctx.log);
    if (info != null && !info.isValid) {
      throw const ConnectException('Threads says this token is no longer valid; generate a new one.',
          field: fieldAccessToken);
    }
    if (info != null && info.scopes.isNotEmpty && !info.scopes.contains('threads_content_publish')) {
      throw const ConnectException('This token cannot publish: add threads_content_publish under Use cases > '
          'Access the Threads API > Customize, then generate a new token.', field: fieldAccessToken);
    }

    var tokens = OAuthTokens(accessToken: token, expiresAt: info?.expiresAt);
    var issuedAt = info?.issuedAt ?? now;
    final expiresAt = info?.expiresAt;
    final shortLived = expiresAt != null && expiresAt.difference(now) < shortLivedThreshold;
    if (shortLived && appSecret.isEmpty) {
      throw const ConnectException('This token only lasts about an hour. Also enter the Threads app secret so '
          'NEFORUM can swap it for a 60-day token.', field: secretAppSecret);
    }
    // When debug_token gave no answer the token's kind is unknown: try the
    // exchange if possible and keep the pasted token when Meta refuses it
    // (it is then most likely a 60-day token already).
    if (shortLived || (info == null && appSecret.isNotEmpty)) {
      try {
        ctx.progress('Exchanging for a 60-day token');
        tokens = await ThreadsApi.exchangeForLongLived(ctx.http,
            clientSecret: appSecret, shortLivedToken: token, now: now);
        issuedAt = now;
      } on HttpFailure catch (f) {
        if (shortLived) {
          throw ConnectException('Threads would not swap the token for a 60-day one '
              '(${threadsErrorFrom(f).message}). Check the Threads app secret.', field: secretAppSecret);
        }
        ctx.log.debug('Threads kept the pasted token as is: ${threadsErrorFrom(f).message}');
      } on AdapterException catch (e) {
        if (shortLived) throw ConnectException('Threads did not return a 60-day token: ${e.error.message}');
        ctx.log.debug('Threads kept the pasted token as is: ${e.error.message}');
      }
    }
    return ConnectResult(
      account: _apiAccount(me, now,
          fallbackUserId: info?.userId,
          config: {
            if (appId.isNotEmpty) configAppId: appId,
            configTokenSource: 'pasted',
          }),
      secrets: tokens.toSecrets({
        if (appSecret.isNotEmpty) secretAppSecret: appSecret,
        secretIssuedAt: issuedAt.toUtc().toIso8601String(),
      }),
    );
  }

  ConnectedAccount _apiAccount(Map<String, dynamic> me, DateTime now,
      {Object? fallbackUserId, required Map<String, dynamic> config}) {
    final userId = '${me['id'] ?? fallbackUserId ?? ''}';
    if (userId.isEmpty) throw const ConnectException('Threads did not return your user id');
    final username = me['username'] as String?;
    return ConnectedAccount(
      id: 'threads:$userId',
      platformId: platformId,
      tier: PlatformTier.byokApi,
      displayName: username == null ? 'Threads' : '@$username (Threads)',
      handle: username == null ? null : '@$username',
      avatarUrl: me['threads_profile_picture_url'] as String?,
      profileUrl: username == null ? null : 'https://www.threads.com/@$username',
      createdAt: now,
      config: {
        ...config,
        configUserId: userId,
        if (username != null) configUsername: username,
      },
    );
  }

  Future<ConnectResult> _connectHandoff(Map<String, String> input, AdapterContext ctx) async {
    final username = (input['username'] ?? '').trim().replaceFirst(RegExp('^@'), '');
    return ConnectResult(
      account: ConnectedAccount(
        id: 'threads-handoff:${username.isEmpty ? const Uuid().v4() : username.toLowerCase()}',
        platformId: platformId,
        tier: PlatformTier.handoff,
        displayName: username.isEmpty ? 'Threads (hand-off)' : '@$username (Threads hand-off)',
        handle: username.isEmpty ? null : '@$username',
        profileUrl: username.isEmpty ? null : 'https://www.threads.com/@$username',
        createdAt: ctx.now(),
        config: {if (username.isNotEmpty) configUsername: username},
      ),
    );
  }

  /// Reads the code from the redirect. Meta appends `#_`, which is not part
  /// of the code. A bare pasted code carries no state; that is accepted.
  static String _extractCode(Uri back, AuthorizationRequest request) {
    final q = {...back.queryParameters};
    if (q.isEmpty && back.fragment.isNotEmpty) q.addAll(Uri.splitQueryString(back.fragment));
    final error = q['error'];
    if (error != null) {
      if (error == 'access_denied') throw const AuthCancelled('You declined access on Threads');
      throw ConnectException('Threads refused the sign-in: ${q['error_description'] ?? q['error_reason'] ?? error}');
    }
    final state = q['state'];
    if (state != null && state != request.state) {
      throw const ConnectException('The pasted address belongs to a different sign-in attempt; please try again');
    }
    var code = (q['code'] ?? '').trim();
    if (code.endsWith('#_')) code = code.substring(0, code.length - 2);
    if (code.isEmpty) {
      throw const ConnectException('No sign-in code found. Paste the whole address your browser landed on.');
    }
    return code;
  }

  // ---- refresh -----------------------------------------------------------

  @override
  Future<Map<String, String>?> refreshSecrets(
      ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.byokApi) return null;
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) {
      throw const AdapterException(PublishError.auth('Threads is not connected; reconnect the account'));
    }
    final now = ctx.now();
    if (tokens.isExpired(now: now, leeway: Duration.zero)) {
      throw const AdapterException(PublishError.auth(
          'Your Threads sign-in expired (tokens last 60 days without use); reconnect the account'));
    }
    final issuedAt = DateTime.tryParse(secrets[secretIssuedAt] ?? '');
    // Meta only refreshes tokens that are at least 24 hours old.
    if (issuedAt != null && now.difference(issuedAt) < const Duration(hours: 24)) return null;
    try {
      ctx.log.debug('Refreshing Threads long-lived token');
      final fresh = await ThreadsApi.refreshLongLived(ctx.http, longLivedToken: tokens.accessToken, now: now);
      return fresh.toSecrets({...secrets, secretIssuedAt: now.toUtc().toIso8601String()});
    } on HttpFailure catch (f) {
      final err = threadsErrorFrom(f, context: 'Refreshing the Threads token');
      if (err.kind == PublishErrorKind.auth) throw AdapterException(err);
      ctx.log.warn('Threads token refresh failed; using the current token: ${err.message}');
      return null;
    } on AdapterException catch (e) {
      ctx.log.warn('Threads token refresh failed; using the current token: ${e.error.message}');
      return null;
    } on Exception catch (e) {
      ctx.log.warn('Threads token refresh failed; using the current token: $e');
      return null;
    }
  }

  // ---- validate ----------------------------------------------------------

  /// Photos from 1:10 to 10:1 besides the file types and size.
  @override
  PhotoFit? photoFit(ConnectedAccount account, PostVariant variant) =>
      super.photoFit(account, variant)?.copyWith(minAspect: 0.1, maxAspect: 10);

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = RulesValidator.validate(variant, descriptor, tier: account.tier);
    final parts = variant.isThread ? variant.threadParts : [variant.text];

    if (variant.media.length > maxCarouselItems) {
      issues.add(ValidationIssue.error('threads.too_many_items',
          '${variant.media.length} media items; a Threads carousel holds at most $maxCarouselItems', field: 'media'));
    }
    for (final m in variant.media) {
      final ratio = m.aspectRatio;
      final name = m.fileName ?? m.id;
      if (ratio != null) {
        final bad = m.isVideo ? (ratio > 10 || ratio < 0.01) : (ratio > 10 || ratio < 0.1);
        if (bad) {
          issues.add(ValidationIssue.error('threads.aspect_ratio',
              '$name has an aspect ratio Threads does not accept (limit 10:1)', field: 'media'));
        }
      }
      if (m.isImage && m.width != null && m.width! < 320) {
        issues.add(ValidationIssue.warning('threads.image_narrow',
            '$name is ${m.width} px wide; Threads scales images narrower than 320 px up', field: 'media'));
      }
      if ((m.altText ?? '').length > maxAltText) {
        issues.add(ValidationIssue.error('threads.alt_too_long',
            'Alt text for $name is ${m.altText!.length}/$maxAltText characters', field: 'media'));
      }
    }

    for (var i = 0; i < parts.length; i++) {
      final label = parts.length > 1 ? 'Part ${i + 1}' : 'The post';
      final links = _uniqueLinks(parts[i], i == _linkPartIndex(variant, parts) ? variant.link : null);
      if (links > maxLinks) {
        issues.add(ValidationIssue.error('threads.too_many_links',
            '$label has $links links; Threads allows at most $maxLinks', field: 'text'));
      }
      final strict = metaCount(parts[i]);
      if (strict > maxChars && parts[i].length <= maxChars) {
        issues.add(ValidationIssue.warning('threads.emoji_bytes',
            '$label counts as $strict/$maxChars on Threads, which counts each emoji as its UTF-8 bytes; it may be rejected',
            field: 'text'));
      }
    }

    final replyControl = variant.extraAs<String>(extraReplyControl);
    if (replyControl != null && !replyControlValues.contains(replyControl)) {
      issues.add(ValidationIssue.error('threads.reply_control',
          'Unknown reply setting "$replyControl" (use ${replyControlValues.join(', ')})', field: 'extra'));
    }
    final topic = variant.extraAs<String>(extraTopicTag);
    if (topic != null && topicTagProblem(topic) != null) {
      issues.add(ValidationIssue.error('threads.topic_tag', topicTagProblem(topic)!, field: 'extra'));
    }
    if (variant.isThread && variant.hasMedia && account.tier == PlatformTier.byokApi) {
      issues.add(const ValidationIssue.info('threads.thread_media', 'Media will be attached to the first post of the thread',
          field: 'media'));
    }
    return issues;
  }

  /// Why [tag] is not a valid topic tag, or `null` when it is.
  static String? topicTagProblem(String tag) {
    if (tag.isEmpty || tag.length > maxTopicTag) return 'Topic tags must be 1-$maxTopicTag characters';
    if (RegExp(r'[.&\n\t]').hasMatch(tag)) return 'Topic tags cannot contain ".", "&", tabs or line breaks';
    return null;
  }

  /// Conservative reading of Meta's rule: every character counts once,
  /// except emoji, which count as their UTF-8 byte length.
  static int metaCount(String text) {
    var n = 0;
    for (final cluster in text.characters) {
      n += _isEmoji(cluster) ? cluster.runes.fold<int>(0, (a, r) => a + _utf8Len(r)) : cluster.length;
    }
    return n;
  }

  static bool _isEmoji(String cluster) => cluster.runes.any((r) =>
      r >= 0x1F000 ||
      (r >= 0x2600 && r <= 0x27BF) ||
      r == 0xFE0F ||
      r == 0x200D ||
      r == 0x20E3);

  static int _utf8Len(int r) => r < 0x80 ? 1 : r < 0x800 ? 2 : r < 0x10000 ? 3 : 4;

  static int _uniqueLinks(String text, String? attachment) {
    final urls = UrlDetector.find(text).map((u) => u.normalized).toSet();
    if (attachment != null && attachment.isNotEmpty) urls.add(attachment);
    return urls.length;
  }

  /// Index of the thread part that should carry `link_attachment`.
  static int _linkPartIndex(PostVariant v, List<String> parts) {
    final link = v.link;
    if (link == null || link.isEmpty) return -1;
    final i = parts.indexWhere((p) => p.contains(link));
    return i < 0 ? 0 : i;
  }

  // ---- publish -----------------------------------------------------------

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final hosted = <HostedMedia>[];
    // Outside the try so a failure halfway through a thread can say which
    // parts are already live (and must not be retried).
    final ids = <String>[];
    final total = variant.isThread ? variant.threadParts.length : 1;
    PublishResult fail(PublishError e) => PublishResult.failure(e.asPartialThread(postedIds: ids, total: total));
    try {
      if (account.tier == PlatformTier.handoff) {
        throw const AdapterException(
            PublishError.unsupported('This Threads account uses hand-off; NEFORUM opens the composer instead'));
      }
      final tokens = OAuthTokens.fromSecrets(secrets);
      if (tokens == null) {
        throw const AdapterException(PublishError.auth('Threads is not connected; reconnect the account'));
      }
      final userId = account.configString(configUserId);
      if (userId.isEmpty) {
        throw const AdapterException(PublishError.auth('The Threads user id is missing; reconnect the account'));
      }
      if (variant.hasMedia && ctx.mediaHost == null) {
        throw const AdapterException(PublishError.configuration(
            'Threads downloads images and videos from a public web address. Set up a media host in '
            'Settings > Media hosting, or post text only.'));
      }
      final api = ThreadsApi(ctx.http, tokens.accessToken, delay: _delay, log: ctx.log);
      final parts = variant.isThread ? variant.threadParts : [variant.text];
      final linkPart = _linkPartIndex(variant, parts);
      String? replyTo;
      for (var i = 0; i < parts.length; i++) {
        final base = <String, String>{
          if (parts[i].trim().isNotEmpty) 'text': parts[i],
          if (replyTo != null) 'reply_to_id': replyTo,
          if (i == 0) ..._rootParams(variant),
        };
        final String containerId;
        if (i == 0 && variant.hasMedia) {
          // Waits until the (carousel) container is FINISHED.
          containerId = await _mediaContainer(api, userId, variant, base, hosted, ctx);
        } else {
          containerId = await api.createContainer(userId, {
            'media_type': 'TEXT',
            ...base,
            if (i == linkPart) 'link_attachment': variant.link!,
          }, onWait: ctx.progress);
          // Meta wants every container checked before publishing; publishing
          // one it has not finished fails with "media not found". A text
          // container is usually FINISHED at once (one GET, no wait).
          await api.waitUntilReady(containerId, onWait: ctx.progress, delays: threadsTextPollDelays, what: 'the post');
        }
        ctx.progress(parts.length > 1 ? 'Publishing part ${i + 1} of ${parts.length}' : 'Publishing to Threads');
        final id = await api.publishContainer(userId, containerId, onWait: ctx.progress);
        ids.add(id);
        replyTo = id;
      }
      final url = await api.permalink(ids.first);
      return PublishResult.ok(
        remoteId: ids.first,
        remoteUrl: url,
        threadRemoteIds: parts.length > 1 ? ids : const [],
        publishedAt: ctx.now(),
      );
    } on AdapterException catch (e) {
      return fail(e.error);
    } on HttpFailure catch (f) {
      return fail(threadsErrorFrom(f));
    } on MediaHostException catch (e) {
      return fail(e.toPublishError());
    } on Exception catch (e) {
      return fail(PublishError.network('Could not reach Threads: $e'));
    } finally {
      await _cleanup(hosted, ctx);
    }
  }

  /// Parameters that only apply to the first post of a thread.
  static Map<String, String> _rootParams(PostVariant v) {
    final rc = v.extraAs<String>(extraReplyControl);
    final topic = v.extraAs<String>(extraTopicTag);
    return {
      if (rc != null && replyControlValues.contains(rc)) 'reply_control': rc,
      if (topic != null && topicTagProblem(topic) == null) 'topic_tag': topic,
    };
  }

  Future<String> _mediaContainer(ThreadsApi api, String userId, PostVariant v, Map<String, String> base,
      List<HostedMedia> hosted, AdapterContext ctx) async {
    if (v.media.length == 1) {
      final m = v.media.single;
      final url = await _host(m, 1, 1, hosted, ctx);
      final id = await api.createContainer(userId, {..._mediaParams(m, url, v), ...base});
      await api.waitUntilReady(id, onWait: ctx.progress, mediaUrl: url);
      return id;
    }
    final children = <String>[];
    for (var i = 0; i < v.media.length; i++) {
      final m = v.media[i];
      final url = await _host(m, i + 1, v.media.length, hosted, ctx);
      // The spoiler flag belongs on the CAROUSEL container, not its items.
      final id = await api.createContainer(userId, {..._mediaParams(m, url, v, spoiler: false), 'is_carousel_item': 'true'});
      await api.waitUntilReady(id, onWait: ctx.progress, mediaUrl: url);
      children.add(id);
    }
    final id = await api.createContainer(userId, {
      'media_type': 'CAROUSEL',
      'children': children.join(','),
      if (v.sensitive) 'is_spoiler_media': 'true',
      ...base,
    });
    await api.waitUntilReady(id, onWait: ctx.progress);
    return id;
  }

  static Map<String, String> _mediaParams(MediaAttachment m, String url, PostVariant v, {bool spoiler = true}) => {
        'media_type': m.isVideo ? 'VIDEO' : 'IMAGE',
        if (m.isVideo) 'video_url': url else 'image_url': url,
        if ((m.altText ?? '').trim().isNotEmpty) 'alt_text': m.altText!.trim(),
        if (spoiler && v.sensitive) 'is_spoiler_media': 'true',
      };

  Future<String> _host(MediaAttachment m, int n, int total, List<HostedMedia> hosted, AdapterContext ctx) async {
    final host = ctx.mediaHost!;
    final kind = m.isVideo ? 'video' : 'image';
    ctx.progress('Uploading $kind $n of $total to ${host.name}');
    final bytes = await ctx.readMedia(m);
    final h = await host.upload(m, bytes, ttl: const Duration(hours: 6));
    hosted.add(h);
    return h.url.toString();
  }

  static Future<void> _cleanup(List<HostedMedia> hosted, AdapterContext ctx) async {
    final host = ctx.mediaHost;
    if (host == null) return;
    for (final h in hosted) {
      if (h.deleteHandle == null) continue;
      try {
        await host.delete(h);
      } on Exception catch (e) {
        ctx.log.warn('Could not delete ${h.url} from ${host.name}', e);
      }
    }
  }

  // ---- hand-off ----------------------------------------------------------

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final full = variant.isThread ? variant.threadParts.join('\n\n') : variant.text;
    final link = variant.link;
    final linkInText = link == null || link.isEmpty || variant.text.contains(link);
    final topic = variant.extraAs<String>(extraTopicTag);
    final rc = variant.extraAs<String>(extraReplyControl);
    final query = <String>[
      'text=${Uri.encodeComponent(variant.text)}',
      if (!linkInText) 'url=${Uri.encodeComponent(link)}',
      if (topic != null && topicTagProblem(topic) == null) 'tag=${Uri.encodeComponent(topic)}',
      if (rc != null && intentReplyControlValues.contains(rc)) 'reply_control=${Uri.encodeComponent(rc)}',
    ];
    final intent = Uri.parse('https://www.threads.com/intent/post?${query.join('&')}');
    final hasMedia = variant.hasMedia;
    final added = [
      if (hasMedia) 'your photos or videos',
      if (variant.isThread) 'the other ${variant.threadParts.length - 1} parts of the thread',
    ];
    return HandoffPlan(
      platformId: platformId,
      webIntent: intent,
      clipboardText: full,
      shareText: variant.text,
      shareFiles: variant.media,
      androidPackage: 'com.instagram.barcelona',
      iosScheme: 'barcelona://',
      desktopUrl: 'https://www.threads.com/',
      preferred: hasMedia ? HandoffMethod.shareSheet : HandoffMethod.webIntent,
      instructions: hasMedia
          ? '1. Pick **Threads** in the share sheet (your media is attached).\n'
              '2. If the caption is empty, long-press the text box and paste (it is on your clipboard).\n'
              '3. Tap **Post**.'
          : variant.isThread
              ? '1. The Threads composer opens with the first part filled in.\n'
                  '2. Tap **Add to thread** and paste the remaining parts from your clipboard.\n'
                  '3. Tap **Post**.'
              : '1. The Threads composer opens with your text filled in (sign in if asked).\n'
                  '2. Check the text and tap **Post**.',
      mediaNote: hasMedia
          ? 'Threads cannot prefill images or videos from a link. On a phone they travel through the share sheet; '
              'on a computer, drag the files into the composer. Your text is on the clipboard.'
          : null,
      // With the browser extension the composer page also gets the files and
      // every part of a thread.
      composerUrl: intent,
      composerInstructions: added.isEmpty
          ? '1. The Threads composer opens with your text filled in (sign in if asked).\n'
              '2. Check the text and select **Post**.'
          : '1. The Threads composer opens with your text filled in (sign in if asked), and the NEFORUM browser '
              'extension adds ${added.join(' and ')}.\n'
              '2. Check the post and select **Post**.',
    );
  }
}
