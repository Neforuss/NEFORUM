import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' show ClientException;
import 'package:uuid/uuid.dart';

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
/// developer app (OAuth 2.0 + PKCE), or through a hand-off to the X app /
/// `x.com/intent/tweet` composer.
class XAdapter extends PlatformAdapter {
  XAdapter();

  /// OAuth 2.0 scopes NEFORUM asks for. `offline.access` yields a refresh
  /// token; `media.write` is needed by the v2 media endpoints.
  static const List<String> scopes = ['tweet.read', 'tweet.write', 'users.read', 'media.write', 'offline.access'];

  /// Account config keys.
  static const String cfgClientId = 'clientId';
  static const String cfgConfidential = 'confidentialClient';
  static const String cfgUserId = 'userId';

  /// Secret key for a confidential client's secret.
  static const String secretClientSecret = 'client_secret';

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
      maxImages: 4,
      maxVideos: 1,
      // GIFs are "images" in the generic check; photos are held to 5 MB in validate().
      imageMaxBytes: _gifMaxBytes,
      videoMaxBytes: 8 * 1024 * 1024 * 1024,
      videoMaxSeconds: 20 * 60,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif', 'image/webp'},
      videoMimeTypes: {'video/mp4', 'video/quicktime'},
      supportsAltText: true,
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

  @override
  PlatformDescriptor get descriptor => _descriptor;

  static const String _byokIntro = '''
**Post automatically with your own X developer app.** X charges per post (about \$0.015, or \$0.20 when the post contains a link), paid from credits on *your* developer account. NEFORUM never sees any money.

1. Open **https://console.x.com** and sign in with your X account. Accept the Developer Agreement and the pay-per-use terms.
2. Add credits under billing (a few dollars last a long time for normal posting).
3. Create a **Project** and an **App** inside it.
4. In the app's **User authentication settings** turn on **OAuth 2.0** and choose:
   - App permissions: **Read and write**
   - Type of app: **Native App** (a public client, no secret needed)
   - Callback URI / Redirect URL: add **both** `$_desktopRedirect` and `$_mobileRedirect` exactly as written (no trailing slash; X does not accept `localhost`)
   - Website URL: any page about you or `https://github.com/Neforuss/NEFORUM`
5. Save, then copy the **OAuth 2.0 Client ID** from the app's *Keys and tokens* page and paste it below.
6. Press **Connect**: X opens in your browser, you approve NEFORUM, and you are done.

Only if you chose *Web App* or *Automated App or Bot* instead of Native App, also paste the **Client Secret**.''';

  static const String _handoffIntro = '''
**No developer account, no cost.** NEFORUM opens the X composer with your text already filled in (the X app on phones, x.com in the browser on computers) and you press **Post** yourself.

Photos and videos are attached through the share sheet on Android and iOS. On Windows and macOS the browser composer cannot receive files, so you attach them by hand.''';

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.byokApi,
          usesBrowser: true,
          intro: _byokIntro,
          redirectNote: 'Register both $_desktopRedirect (computers) and $_mobileRedirect (phones) as callback URLs '
              'in your X app. They must match exactly.',
          loopbackRedirectOk: true,
          customSchemeRedirectOk: true,
          fields: [
            ConnectField(
              key: 'client_id',
              label: 'OAuth 2.0 Client ID',
              placeholder: 'e.g. M1M5R3BMVy13QmpScXkzTUt5OE46MTpjaQ',
              help: 'console.x.com > your app > Keys and tokens > OAuth 2.0 Client ID and Client Secret.',
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
    final clientId = (input['client_id'] ?? '').trim();
    final clientSecret = (input['client_secret'] ?? '').trim();
    if (clientId.isEmpty) {
      throw const ConnectException('Paste the OAuth 2.0 Client ID of your X app', field: 'client_id');
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
    if (account.tier != PlatformTier.byokApi) return null;
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
    final gifs = variant.media.where((m) => m.kind == MediaKind.gif).toList();
    if (gifs.isNotEmpty && variant.media.length > 1) {
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
      if (account.configString(cfgClientId).isEmpty) {
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
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) {
      return PublishResult.failure(const PublishError.auth('No X sign-in stored for this account; reconnect it'));
    }
    final api = XApi(ctx, tokens.accessToken);
    final parts = variant.isThread ? variant.threadParts : [variant.text];
    final ids = <String>[];
    try {
      final mediaIds = variant.hasMedia ? await api.uploadAll(variant.media) : const <String>[];
      final replySettings = variant.extraAs<String>('replySettings');
      for (var i = 0; i < parts.length; i++) {
        if (parts.length > 1) ctx.progress('Posting part ${i + 1} of ${parts.length}');
        final id = await api.createPost(
          text: parts[i],
          mediaIds: i == 0 ? mediaIds : const [],
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
    );
  }

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------

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
