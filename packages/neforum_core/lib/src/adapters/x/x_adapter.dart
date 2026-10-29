import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' show ClientException;
import 'package:uuid/uuid.dart';

import '../../auth/oauth1.dart';
import '../../auth/oauth2_pkce.dart';
import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../model/account.dart';
import '../../model/media.dart';
import '../../model/photo_fit.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../../text/url_detector.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'x_api.dart';

/// X (formerly Twitter) through the official X API v2 with the user's own
/// developer app, or through a hand-off to the X app / `x.com/intent/tweet`
/// composer.
///
/// The API tier connects in one of two ways, chosen by what the user fills
/// in: the four OAuth 1.0a keys from the app's "Keys and tokens" page (no
/// browser; the keys never expire or change, so the account works on every
/// device at once), or OAuth 2.0 + PKCE in the browser (renewed every two
/// hours with a refresh token that X replaces each time, so only one device
/// stays connected). Both give the same account id.
class XAdapter extends PlatformAdapter {
  XAdapter();

  /// OAuth 2.0 scopes NEFORUM asks for. `offline.access` yields a refresh
  /// token; `media.write` is needed by the v2 media endpoints.
  static const List<String> scopes = ['tweet.read', 'tweet.write', 'users.read', 'media.write', 'offline.access'];

  /// Account config keys.
  static const String cfgClientId = 'clientId';
  static const String cfgConfidential = 'confidentialClient';
  static const String cfgUserId = 'userId';

  /// How the account signs its API calls: [authOAuth1] or [authOAuth2].
  /// Accounts connected before OAuth 1.0a was offered have no value, which
  /// means OAuth 2.0.
  static const String cfgAuthMode = 'authMode';
  static const String authOAuth1 = 'oauth1';
  static const String authOAuth2 = 'oauth2';

  /// Secret key for a confidential client's secret.
  static const String secretClientSecret = 'client_secret';

  /// Connect-form keys of the four OAuth 1.0a keys, in form order.
  static const String fieldApiKey = 'api_key';
  static const String fieldApiKeySecret = 'api_key_secret';
  static const String fieldAccessToken = 'access_token';
  static const String fieldAccessTokenSecret = 'access_token_secret';

  /// True when [account] signs with OAuth 1.0a keys.
  static bool usesOAuth1(ConnectedAccount account) => account.configString(cfgAuthMode) == authOAuth1;

  static const String _desktopRedirect = 'http://127.0.0.1:52771/callback';
  static const String _mobileRedirect = 'neforum://callback';
  static const int _photoMaxBytes = 5 * 1024 * 1024;
  static const int _gifMaxBytes = 15 * 1024 * 1024;
  static const Set<String> _replySettings = {'following', 'mentionedUsers', 'subscribers', 'verified'};

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'x',
    name: 'X (Twitter)',
    iconKey: 'x',
    homepage: 'https://x.com',
    tiers: {PlatformTier.byokApi, PlatformTier.handoff},
    defaultTier: PlatformTier.byokApi,
    text: TextRules(
      maxLength: 280,
      counting: CountingRule.weightedX,
      urlWeight: 23,
      supportsThreads: true,
      supportsHashtags: true,
      linkInText: true,
      notes: 'Weighted count: most Latin/Cyrillic characters count 1, CJK and emoji count 2, every link counts 23. '
          'Longer posts need X Premium on the posting account, so NEFORUM splits long text into a thread.',
    ),
    media: MediaRules(
      // Sound goes as a video of one still picture, made by the app.
      audioAsVideo: true,
      maxImages: 4,
      maxVideos: 1,
      // GIFs are "images" in the generic check; photos are held to 5 MB in validate().
      imageMaxBytes: _gifMaxBytes,
      videoMaxBytes: 8 * 1024 * 1024 * 1024,
      videoMaxSeconds: 20 * 60,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif', 'image/webp'},
      videoMimeTypes: {'video/mp4', 'video/quicktime'},
      supportsAltText: true,
      mediaPerThreadPart: true,
      notes: 'Up to 4 photos (5 MB each), or 1 animated GIF (15 MB), or 1 video (MP4/MOV, up to 20 minutes and 8 GB; '
          'longer with Premium). Alt text up to 1000 characters.',
    ),
    defaultQuotas: [
      QuotaRule(
        id: 'x.posts_per_15min',
        limit: 100,
        window: Duration(minutes: 15),
        note: 'posts per 15 minutes per user (X API rate limit)',
        appliesToTier: PlatformTier.byokApi,
      ),
      QuotaRule(
        id: 'x.posts_per_day_app',
        limit: 10000,
        window: Duration(hours: 24),
        note: 'posts per 24 hours per developer app (X API rate limit)',
        appliesToTier: PlatformTier.byokApi,
      ),
      QuotaRule(
        id: 'x.posts_per_month',
        limit: 500,
        window: Duration(days: 30),
        note: 'posts per 30 days; 500 mirrors the old X Free tier. Pay-per-use has no fixed cap, so raise this '
            'in the account settings to match the credits you buy',
        appliesToTier: PlatformTier.byokApi,
      ),
    ],
    personalAccountOk: true,
    accountRequirements: 'Any X account works. Automatic posting needs your own X developer app (created at '
        'console.x.com, no review) with credits on it; hand-off needs only the X app or website.',
    apiCostSummary: 'Since February 2026 new X developer accounts are pay-per-use with no free tier: each post '
        'costs about \$0.015, or \$0.20 if it contains a link, paid from credits you buy at console.x.com. '
        'Hand-off is free because you press Post yourself.',
    setupGuide: 'docs/platforms/x.md',
    serverSideScheduling: false,
    supportsLinkField: false,
  );

  /// Every OAuth 2.0 refresh returns a new refresh token and invalidates the
  /// old one.
  @override
  bool get rotatesRefreshTokens => true;

  /// OAuth 1.0a keys are never renewed, so only OAuth 2.0 accounts rotate.
  @override
  bool rotatesRefreshTokensFor(ConnectedAccount account) =>
      account.tier == PlatformTier.byokApi && !usesOAuth1(account);

  @override
  PlatformDescriptor get descriptor => _descriptor;

  static const String _byokIntro = '''
**Post automatically with your own X developer app.** X charges per post (about \$0.015, or \$0.20 when the post contains a link), paid from credits on *your* developer account. NEFORUM never sees any money.

Paste the four keys from the X developer portal (Keys and tokens: API Key and Secret, Access Token and Secret, with Read and write permission) to stay connected on every device; or leave them empty and sign in with the browser.

1. Open **https://console.x.com** and sign in with your X account. Accept the Developer Agreement and the pay-per-use terms.
2. Add credits under billing (a few dollars last a long time for normal posting).
3. Create a **Project** and an **App** inside it.
4. In the app's **User authentication settings** choose:
   - App permissions: **Read and write**
   - Type of app: **Native App** (a public client, no secret needed)
   - Callback URI / Redirect URL: add **both** `$_desktopRedirect` and `$_mobileRedirect` exactly as written (no trailing slash; X does not accept `localhost`)
   - Website URL: any page about you or `https://github.com/Neforuss/NEFORUM`
5. Save. Then either:
   - **Keys (every device):** on the app's *Keys and tokens* page copy the **API Key and Secret**, and generate the **Access Token and Secret** (regenerate them if they were made before you chose Read and write: old ones stay read-only). Paste all four below and press **Connect**. No browser needed, and the keys never expire.
   - **Browser sign-in (one device):** copy the **OAuth 2.0 Client ID** from *Keys and tokens*, paste it below and press **Sign in with X**. Only if you chose *Web App* or *Automated App or Bot* instead of Native App, also paste the **Client Secret**. X replaces this sign-in every time NEFORUM renews it, so it stays connected on only one device.''';

  static const String _handoffIntro = '''
**No developer account, no cost.** NEFORUM opens the X composer with your text already filled in (the X app on phones, x.com in the browser on computers) and you press **Post** yourself.

Photos and videos are attached through the share sheet on Android and iOS. On Windows and macOS the browser composer cannot receive files, so you attach them by hand.''';

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.byokApi,
          usesBrowser: true,
          intro: _byokIntro,
          redirectNote: 'Only for browser sign-in (not needed when you paste the four keys): register both '
              '$_desktopRedirect (computers) and $_mobileRedirect (phones) as callback URLs in your X app. They '
              'must match exactly.',
          loopbackRedirectOk: true,
          customSchemeRedirectOk: true,
          fields: [
            // Secret fields whose key contains "token" switch the app's form
            // from browser sign-in to Connect as soon as one is filled in.
            ConnectField(
              key: fieldApiKey,
              label: 'API Key',
              required: false,
              help: 'For staying connected on every device. console.x.com > your app > Keys and tokens > '
                  '**API Key and Secret** (also called Consumer Key and Secret). Leave the four keys empty to sign '
                  'in with the browser instead.',
            ),
            ConnectField(
              key: fieldApiKeySecret,
              label: 'API Key Secret',
              kind: FieldKind.password,
              required: false,
              secret: true,
            ),
            ConnectField(
              key: fieldAccessToken,
              label: 'Access Token',
              kind: FieldKind.password,
              required: false,
              secret: true,
              placeholder: 'starts with your numeric user id and a dash',
              help: 'Same page > **Access Token and Secret** > Generate. X must show them as made with **Read and '
                  'write** permission; regenerate them after changing the permission. Not the Bearer Token.',
            ),
            ConnectField(
              key: fieldAccessTokenSecret,
              label: 'Access Token Secret',
              kind: FieldKind.password,
              required: false,
              secret: true,
            ),
            ConnectField(
              key: 'client_id',
              label: 'OAuth 2.0 Client ID',
              required: false,
              placeholder: 'e.g. M1M5R3BMVy13QmpScXkzTUt5OE46MTpjaQ',
              help: 'Only for browser sign-in, with the four keys above left empty. console.x.com > your app > '
                  'Keys and tokens > OAuth 2.0 Client ID and Client Secret.',
            ),
            ConnectField(
              key: 'client_secret',
              label: 'Client Secret (only for Web App / Bot apps)',
              kind: FieldKind.password,
              required: false,
              secret: true,
              help: 'Leave empty for a Native App (recommended). Confidential apps send it with HTTP Basic auth.',
            ),
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.handoff,
          intro: _handoffIntro,
          fields: [
            ConnectField(
              key: 'handle',
              label: 'Your X username (optional)',
              required: false,
              placeholder: '@yourname',
              help: 'Only used to label this account in NEFORUM.',
            ),
          ],
        ),
      ];

  // ---------------------------------------------------------------------
  // Connect / refresh / disconnect
  // ---------------------------------------------------------------------

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier == PlatformTier.handoff) return _connectHandoff(input, ctx);
    if (tier != PlatformTier.byokApi) {
      throw ConnectException('X does not support the ${tier.label} tier in NEFORUM');
    }
    final keys = _pastedKeys(input);
    if (keys != null) return _connectOAuth1(keys, ctx);
    final clientId = (input['client_id'] ?? '').trim();
    final clientSecret = (input['client_secret'] ?? '').trim();
    if (clientId.isEmpty) {
      throw const ConnectException(
          'Paste the four keys (API Key and Secret, Access Token and Secret), or the OAuth 2.0 Client ID to sign in '
          'with the browser',
          field: 'client_id');
    }
    final client = _client(clientId, clientSecret);
    final broker = ctx.requireBroker();
    final redirect = broker.chooseRedirectUri(loopbackOk: true, customSchemeOk: true);

    final OAuthTokens tokens;
    try {
      final request = client.buildAuthorizationUrl(redirectUri: redirect);
      final back = await broker.authorize(request.url, redirect);
      final code = client.extractCode(back, request);
      tokens = await client.exchangeCode(ctx.http, code: code, redirectUri: redirect, pkce: request.pkce, now: ctx.now());
    } on OAuthException catch (e) {
      throw ConnectException(_oauthHint(e, redirect));
    }

    final XUser user;
    try {
      user = await XApi(ctx, tokens.accessToken).me();
    } on HttpFailure catch (e) {
      final err = XApi.mapError(e, now: ctx.now());
      throw ConnectException('Signed in, but X refused to read your profile: ${err.message}');
    } on AdapterException catch (e) {
      throw ConnectException(e.error.message);
    }

    final account = ConnectedAccount(
      id: 'x-${user.id}',
      platformId: id,
      tier: PlatformTier.byokApi,
      displayName: '${user.name} (@${user.username})',
      handle: '@${user.username}',
      avatarUrl: user.avatarUrl,
      profileUrl: 'https://x.com/${user.username}',
      createdAt: ctx.now(),
      config: {
        cfgAuthMode: authOAuth2,
        cfgClientId: clientId,
        cfgConfidential: clientSecret.isNotEmpty,
        cfgUserId: user.id,
      },
    );
    return ConnectResult(
      account: account,
      secrets: tokens.toSecrets({if (clientSecret.isNotEmpty) secretClientSecret: clientSecret}),
    );
  }

  /// The four OAuth 1.0a keys from the form, or null when all four are
  /// empty (browser sign-in). Some but not all filled in is a mistake worth
  /// naming, not a reason to open the browser.
  static OAuth1Credentials? _pastedKeys(Map<String, String> input) {
    String v(String key) => (input[key] ?? '').trim();
    const labels = {
      fieldApiKey: 'API Key',
      fieldApiKeySecret: 'API Key Secret',
      fieldAccessToken: 'Access Token',
      fieldAccessTokenSecret: 'Access Token Secret',
    };
    if (labels.keys.every((k) => v(k).isEmpty)) return null;
    for (final e in labels.entries) {
      if (v(e.key).isEmpty) {
        throw ConnectException(
            'Paste the ${e.value} too: the keys only work as a set of four. To sign in with the browser instead, '
            'clear all four.',
            field: e.key);
      }
    }
    // App-only Bearer Tokens start with a run of "A"s; they cannot post.
    if (v(fieldAccessToken).startsWith('AAAAAAAAAA')) {
      throw const ConnectException(
          'That is the Bearer Token. Paste the Access Token instead (Keys and tokens > Access Token and Secret).',
          field: fieldAccessToken);
    }
    return OAuth1Credentials(
      consumerKey: v(fieldApiKey),
      consumerSecret: v(fieldApiKeySecret),
      token: v(fieldAccessToken),
      tokenSecret: v(fieldAccessTokenSecret),
    );
  }

  /// Checks the keys by asking X who they belong to (`GET /2/users/me`,
  /// signed), then builds the same account the browser sign-in would.
  Future<ConnectResult> _connectOAuth1(OAuth1Credentials keys, AdapterContext ctx) async {
    final XUser user;
    try {
      user = await XApi.oauth1(ctx, keys).me();
    } on HttpFailure catch (e) {
      if (e.statusCode == 401) {
        final said = XApi.errorMessage(e.response.jsonMap) ?? 'HTTP 401';
        throw ConnectException('X did not accept the keys (X said: $said). Copy all four again from Keys and tokens '
            '(regenerating a key replaces the old one), and check that this device\'s date and time are right: '
            'X refuses signed requests from a clock that is off by more than a few minutes.');
      }
      throw ConnectException('X refused to read your profile with these keys: ${XApi.mapError(e, now: ctx.now()).message}');
    } on AdapterException catch (e) {
      throw ConnectException(e.error.message);
    }
    final level = (user.accessLevel ?? '').toLowerCase();
    if (level.isNotEmpty && !level.contains('write')) {
      throw ConnectException(
          'These keys can only read (X reports "${user.accessLevel}"), so NEFORUM could not post. In the app\'s User '
          'authentication settings choose "Read and write", save, then regenerate the Access Token and Secret and '
          'paste the new pair.',
          field: fieldAccessToken);
    }
    return ConnectResult(
      account: ConnectedAccount(
        // Same id as the browser sign-in: it is the same X account.
        id: 'x-${user.id}',
        platformId: id,
        tier: PlatformTier.byokApi,
        displayName: '${user.name} (@${user.username})',
        handle: '@${user.username}',
        avatarUrl: user.avatarUrl,
        profileUrl: 'https://x.com/${user.username}',
        createdAt: ctx.now(),
        config: {
          cfgAuthMode: authOAuth1,
          cfgUserId: user.id,
        },
      ),
      secrets: keys.toSecrets(),
    );
  }

  ConnectResult _connectHandoff(Map<String, String> input, AdapterContext ctx) {
    final handle = (input['handle'] ?? '').trim().replaceFirst(RegExp('^@'), '');
    if (handle.isNotEmpty && !RegExp(r'^[A-Za-z0-9_]{1,15}$').hasMatch(handle)) {
      throw const ConnectException('X usernames have 1-15 letters, digits or underscores', field: 'handle');
    }
    return ConnectResult(
      account: ConnectedAccount(
        id: 'x-handoff-${const Uuid().v4()}',
        platformId: id,
        tier: PlatformTier.handoff,
        displayName: handle.isEmpty ? 'X (hand-off)' : '@$handle (hand-off)',
        handle: handle.isEmpty ? null : '@$handle',
        profileUrl: handle.isEmpty ? null : 'https://x.com/$handle',
        createdAt: ctx.now(),
      ),
    );
  }

  @override
  Future<Map<String, String>?> refreshSecrets(
      ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    // OAuth 1.0a keys never expire: nothing to renew, and nothing that could
    // end the connection on another device.
    if (account.tier != PlatformTier.byokApi || usesOAuth1(account)) return null;
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) {
      throw const AdapterException(PublishError.auth('No X sign-in stored for this account; reconnect it'));
    }
    if (!tokens.isExpired(now: ctx.now())) return null;
    final refreshToken = tokens.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      throw const AdapterException(PublishError.auth('The X sign-in expired and cannot be renewed; reconnect the account'));
    }
    final clientId = account.configString(cfgClientId);
    if (clientId.isEmpty) {
      throw const AdapterException(PublishError.auth('This X account has no Client ID stored; reconnect it'));
    }
    final client = _client(clientId, secrets[secretClientSecret] ?? '');
    try {
      ctx.log.debug('Refreshing X access token for ${account.displayName}');
      final fresh = await client.refresh(ctx.http, refreshToken: refreshToken, now: ctx.now());
      // X rotates refresh tokens: the old one is dead now, so the new pair
      // must replace it (toSecrets keeps the old one only if none came back).
      return fresh.toSecrets(secrets);
    } on OAuthException catch (e) {
      // Only a rejected grant means "reconnect"; outages and 429s retry.
      throw AdapterException(e.toRefreshError('X'));
    } on TimeoutException catch (e) {
      throw AdapterException(PublishError.network('Could not reach X to renew the sign-in: $e'));
    } on ClientException catch (e) {
      throw AdapterException(PublishError.network('Could not reach X to renew the sign-in: ${e.message}'));
    }
  }

  @override
  Future<void> disconnect(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    // OAuth 1.0a keys are left alone: the same keys may be in use on the
    // user's other devices, and they are revoked or regenerated on the
    // app's Keys and tokens page, where they were made.
    if (usesOAuth1(account)) return;
    final tokens = OAuthTokens.fromSecrets(secrets);
    final clientId = account.configString(cfgClientId);
    if (account.tier != PlatformTier.byokApi || tokens == null || clientId.isEmpty) return;
    final secret = secrets[secretClientSecret] ?? '';
    final refresh = tokens.refreshToken;
    final form = <String, String>{
      'token': refresh ?? tokens.accessToken,
      'token_type_hint': refresh != null ? 'refresh_token' : 'access_token',
      'client_id': clientId,
    };
    try {
      await ctx.http.postForm(XEndpoints.revoke, form, headers: _basicHeader(clientId, secret));
    } on Object catch (e) {
      ctx.log.warn('Could not revoke the X token for ${account.displayName}', e);
    }
  }

  // ---------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------

  /// Photos up to 5 MB (GIFs keep the descriptor's larger limit).
  @override
  PhotoFit? photoFit(ConnectedAccount account, PostVariant variant) =>
      super.photoFit(account, variant)?.copyWith(maxBytes: _photoMaxBytes);

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = super.validate(variant, account);
    if (variant.mediaGroups.any((g) => g.length > 1 && g.any((m) => m.kind == MediaKind.gif))) {
      issues.add(const ValidationIssue.error(
          'x.gif_alone', 'An animated GIF must be the only media in an X post', field: 'media'));
    }
    for (final m in variant.media) {
      if (m.kind == MediaKind.image && m.sizeBytes > _photoMaxBytes) {
        issues.add(ValidationIssue.error(
            'media.image_too_large', '${m.fileName ?? m.id} is over the 5 MB X allows for photos', field: 'media'));
      }
      if ((m.altText ?? '').length > XApi.altTextMax) {
        issues.add(ValidationIssue.warning('x.alt_too_long',
            'Alt text of ${m.fileName ?? m.id} will be cut to ${XApi.altTextMax} characters', field: 'media'));
      }
      final ratio = m.aspectRatio;
      if (m.isVideo && ratio != null && (ratio < 1 / 3 || ratio > 3)) {
        issues.add(ValidationIssue.warning(
            'x.video_aspect', 'X expects videos between 1:3 and 3:1; ${m.fileName ?? m.id} may be refused', field: 'media'));
      }
      if (m.isVideo && m.sizeBytes > 512 * 1024 * 1024 && account.tier == PlatformTier.byokApi) {
        issues.add(ValidationIssue.warning('x.video_large',
            '${m.fileName ?? m.id} is very large; NEFORUM loads it into memory to upload, which may fail', field: 'media'));
      }
    }
    if (account.tier == PlatformTier.byokApi) {
      if (!usesOAuth1(account) && account.configString(cfgClientId).isEmpty) {
        issues.add(const ValidationIssue.error(
            'account.not_configured', 'This X account has no Client ID; reconnect it', field: 'account'));
      }
      final parts = variant.isThread ? variant.threadParts : [variant.text];
      final withLinks = parts.where((p) => UrlDetector.find(p).isNotEmpty).length;
      if (withLinks > 0) {
        issues.add(ValidationIssue.info(
          'x.link_cost',
          'X charges \$0.20 instead of \$0.015 for ${withLinks == 1 && parts.length == 1 ? 'a post' : '$withLinks post(s)'} '
              'containing a link',
          field: 'text',
        ));
      }
    }
    return issues;
  }

  // ---------------------------------------------------------------------
  // Publish
  // ---------------------------------------------------------------------

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.byokApi) {
      return PublishResult.failure(const PublishError.unsupported('This X account posts through hand-off, not the API'));
    }
    final api = _api(account, secrets, ctx);
    if (api == null) {
      return PublishResult.failure(PublishError.auth(usesOAuth1(account)
          ? 'The X keys of this account are missing; reconnect it and paste the four keys again'
          : 'No X sign-in stored for this account; reconnect it'));
    }
    final parts = variant.isThread ? variant.threadParts : [variant.text];
    final ids = <String>[];
    try {
      // Every part's media is uploaded before the first post goes up, so a
      // refused file stops the thread before anything is public.
      final mediaIds = [
        for (var i = 0; i < parts.length; i++)
          if (variant.mediaOfPart(i) case final m when m.isNotEmpty) await api.uploadAll(m) else const <String>[],
      ];
      final replySettings = variant.extraAs<String>('replySettings');
      for (var i = 0; i < parts.length; i++) {
        if (parts.length > 1) ctx.progress('Posting part ${i + 1} of ${parts.length}');
        final id = await api.createPost(
          text: parts[i],
          mediaIds: mediaIds[i],
          inReplyTo: i == 0 ? null : ids.last,
          replySettings: _replySettings.contains(replySettings) ? replySettings : null,
        );
        ids.add(id);
      }
    } on AdapterException catch (e) {
      return PublishResult.failure(_partial(e.error, ids, parts.length));
    } on HttpFailure catch (e) {
      return PublishResult.failure(_partial(XApi.mapError(e, now: ctx.now()), ids, parts.length));
    } on TimeoutException catch (e) {
      return PublishResult.failure(_partial(PublishError.network('X did not answer in time: $e'), ids, parts.length));
    } on ClientException catch (e) {
      return PublishResult.failure(_partial(PublishError.network('Could not reach X: ${e.message}'), ids, parts.length));
    }
    final handle = (account.handle ?? '').replaceFirst(RegExp('^@'), '');
    return PublishResult.ok(
      remoteId: ids.first,
      remoteUrl: handle.isEmpty ? 'https://x.com/i/web/status/${ids.first}' : 'https://x.com/$handle/status/${ids.first}',
      threadRemoteIds: parts.length > 1 ? ids : const [],
      publishedAt: ctx.now(),
    );
  }

  /// A thread that broke half-way must not be retried blindly: the parts
  /// already on X would be refused as duplicates.
  static PublishError _partial(PublishError e, List<String> posted, int total) {
    if (posted.isEmpty) return e;
    return PublishError(
      kind: e.kind,
      message: 'Part ${posted.length + 1} of $total failed after ${posted.length} part(s) were posted '
          '(ids ${posted.join(', ')}): ${e.message}',
      statusCode: e.statusCode,
      raw: e.raw,
      retryAfter: e.retryAfter,
    );
  }

  // ---------------------------------------------------------------------
  // Hand-off
  // ---------------------------------------------------------------------

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final text = variant.text;
    final link = (variant.link ?? '').trim();
    final linkInText = link.isEmpty || text.contains(link) || UrlDetector.find(text).any((u) => u.text == link);
    final intent = Uri.https('x.com', '/intent/tweet', {
      if (text.isNotEmpty) 'text': text,
      if (!linkInText) 'url': link,
    });
    final first = linkInText ? text : '$text\n\n$link'.trim();
    final full = variant.isThread ? variant.threadParts.join('\n\n') : first;
    final hasMedia = variant.hasMedia;
    final steps = <String>[
      '1. NEFORUM opens the X composer with your text filled in (it is also on your clipboard).',
      if (hasMedia) '2. Check that your photos or video are attached; on a computer, attach them yourself.',
      '${hasMedia ? 3 : 2}. Read it over and press **Post**.',
      if (variant.isThread) '${hasMedia ? 4 : 3}. For the rest of the thread, reply to your post and paste the next part.',
    ];
    final added = [
      if (hasMedia) 'your photos or video',
      if (variant.isThread) 'the other ${variant.threadParts.length - 1} parts of the thread',
    ];
    final composerSteps = <String>[
      added.isEmpty
          ? 'NEFORUM opens the X composer with your text filled in.'
          : 'NEFORUM opens the X composer with your text filled in, and the NEFORUM browser extension adds ${added.join(' and ')}.',
      'Read it over and press **${variant.isThread ? 'Post all' : 'Post'}**.',
    ];
    return HandoffPlan(
      platformId: id,
      instructions: steps.join('\n'),
      webIntent: intent,
      clipboardText: full,
      shareText: first,
      shareFiles: variant.media,
      androidPackage: 'com.twitter.android',
      iosScheme: 'twitter://',
      desktopUrl: intent.toString(),
      preferred: hasMedia ? HandoffMethod.shareSheet : HandoffMethod.webIntent,
      mediaNote: hasMedia
          ? 'The X website composer cannot receive files. On Android and iOS the share sheet attaches them; '
              'on a computer attach them by hand in the composer.'
          : null,
      // With the browser extension the same composer page also gets the
      // files and every part of a thread.
      composerUrl: intent,
      composerInstructions: [for (var i = 0; i < composerSteps.length; i++) '${i + 1}. ${composerSteps[i]}'].join('\n'),
    );
  }

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------

  /// The API with this account's credentials: signed with its OAuth 1.0a
  /// keys, or with its OAuth 2.0 token as a Bearer header. Null when they
  /// are not stored.
  static XApi? _api(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) {
    if (usesOAuth1(account)) {
      final keys = OAuth1Credentials.fromSecrets(secrets);
      return keys == null ? null : XApi.oauth1(ctx, keys);
    }
    final tokens = OAuthTokens.fromSecrets(secrets);
    return tokens == null ? null : XApi(ctx, tokens.accessToken);
  }

  /// Native App (public) clients authenticate with `client_id` in the body
  /// only; confidential clients use HTTP Basic (client_id stays in the body,
  /// which X tolerates).
  static OAuth2Client _client(String clientId, String clientSecret) => OAuth2Client(
        authorizationEndpoint: XEndpoints.authorize,
        tokenEndpoint: XEndpoints.token,
        clientId: clientId,
        clientSecret: clientSecret.isEmpty ? null : clientSecret,
        scopes: scopes,
        clientAuth: clientSecret.isEmpty ? ClientAuth.body : ClientAuth.basicAndBodyClientId,
      );

  static Map<String, String> _basicHeader(String clientId, String secret) => secret.isEmpty
      ? const {}
      : {'Authorization': 'Basic ${base64Encode(utf8.encode('$clientId:$secret'))}'};

  static String _oauthHint(OAuthException e, Uri redirect) {
    final why = e.description ?? e.error ?? e.message;
    final lower = '$why ${e.error ?? ''}'.toLowerCase();
    if (lower.contains('redirect') || lower.contains('callback')) {
      return 'X refused the sign-in: $why. Add $redirect to the Callback URLs of your X app (exact match).';
    }
    if (lower.contains('client')) {
      return 'X refused the sign-in: $why. Check the Client ID, and that the app type is Native App '
          '(or paste the Client Secret for Web App / Bot apps).';
    }
    return 'X refused the sign-in: $why';
  }
}
