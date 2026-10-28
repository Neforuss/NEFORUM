import 'package:uuid/uuid.dart';

import '../../auth/auth_broker.dart';
import '../../auth/oauth2_pkce.dart';
import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../model/account.dart';
import '../../model/photo_fit.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../../text/rules_validator.dart';
import '../../text/text_counter.dart';
import '../../text/url_detector.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'linkedin_api.dart';

/// LinkedIn: posts to the signed-in member's own profile through the
/// self-serve "Share on LinkedIn" product (w_member_social) and the
/// versioned Posts API, or hands the post to LinkedIn's app / website.
///
/// Company pages need the vetted Community Management API and are not
/// supported.
class LinkedInAdapter extends PlatformAdapter {
  LinkedInAdapter({
    this.videoPollInterval = const Duration(seconds: 5),
    this.videoPollAttempts = 36,
  });

  /// Delay between video status checks after finalizeUpload.
  final Duration videoPollInterval;

  /// How many status checks before posting anyway (default: 3 minutes).
  final int videoPollAttempts;

  // Config keys (non-secret).
  static const cfgClientId = 'clientId';
  static const cfgApiVersion = 'apiVersion';
  static const cfgPersonUrn = 'personUrn';
  static const cfgSub = 'sub';
  static const cfgRedirectUri = 'redirectUri';

  // Secret keys (besides OAuthTokens' own).
  static const secretClientSecret = 'client_secret';

  /// Images API cap: images must have fewer than this many pixels.
  static const int maxImagePixels = 36152320;

  /// Videos API: 75 KB to 500 MB, 3 seconds to 30 minutes.
  static const int minVideoBytes = 75 * 1000;
  static const int minVideoSeconds = 3;
  static const int maxAltTextLength = 4086;
  static const int multiImageMin = 2;

  static const String desktopRedirect = 'http://127.0.0.1:52771/callback';

  static const PlatformDescriptor linkedInDescriptor = PlatformDescriptor(
    id: 'linkedin',
    name: 'LinkedIn',
    iconKey: 'linkedin',
    homepage: 'https://www.linkedin.com',
    tiers: {PlatformTier.byokApi, PlatformTier.handoff},
    defaultTier: PlatformTier.byokApi,
    text: TextRules(
      maxLength: 3000,
      counting: CountingRule.utf16,
      titleSupported: true,
      titleRequired: false,
      supportsThreads: false,
      supportsContentWarning: false,
      supportsMarkdown: false,
      supportsHashtags: true,
      hashtagsAsField: false,
      linkInText: true,
      notes: 'Up to 3000 characters. LinkedIn does not document the counting unit, so NEFORUM counts '
          'UTF-16 code units (emoji count as 2). Special characters ( ) [ ] { } < > @ | ~ _ * # are escaped '
          'automatically; the extra backslashes may count toward the limit. The title is only used as the '
          'link-card title or the video title. No threads, no content warnings.',
    ),
    media: MediaRules(
      // Sound goes as a video of one still picture, made by the app.
      audioAsVideo: true,
      maxImages: 20,
      maxVideos: 1,
      allowsMixedImageVideo: false,
      videoMaxBytes: 500 * 1000 * 1000,
      videoMaxSeconds: 30 * 60,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif'},
      videoMimeTypes: {'video/mp4'},
      supportsAltText: true,
      requiresPublicMediaUrl: false,
      notes: 'JPG, PNG or GIF (GIF up to 250 frames), fewer than 36,152,320 pixels; 1 image, or 2 to 20 images '
          'as a multi-image post. One MP4 video, 3 s to 30 min, 75 KB to 500 MB. Images and video cannot be mixed.',
    ),
    defaultQuotas: [
      QuotaRule(
        id: 'linkedin.requests_per_day',
        limit: 150,
        window: Duration(days: 1),
        note: 'API calls per member per day (resets 00:00 UTC); each image or video upload uses 2-3 extra calls',
        appliesToTier: PlatformTier.byokApi,
      ),
    ],
    personalAccountOk: true,
    accountRequirements: 'A normal LinkedIn profile is enough. For automatic posting you create a free LinkedIn '
        'developer app, which must be linked to a LinkedIn company Page you administer (creating a Page is free).',
    apiCostSummary: 'Free. LinkedIn allows about 150 API calls per member per day, and you must reconnect every '
        '60 days because LinkedIn sign-ins expire and cannot be renewed automatically.',
    setupGuide: 'docs/platforms/linkedin.md',
    serverSideScheduling: false,
    supportsLinkField: true,
  );

  @override
  PlatformDescriptor get descriptor => linkedInDescriptor;

  // ------------------------------------------------------------- connect

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.byokApi,
          usesBrowser: true,
          loopbackRedirectOk: true,
          customSchemeRedirectOk: false,
          redirectNote: 'Register exactly http://127.0.0.1:52771/callback under Auth > "Authorized redirect URLs '
              'for your app". LinkedIn does not accept app links such as neforum://callback, so connect LinkedIn '
              'from NEFORUM on a computer.',
          intro: _byokIntro,
          fields: [
            ConnectField(
              key: 'clientId',
              label: 'Client ID',
              help: 'Developer Portal > your app > **Auth** tab > "Client ID".',
              placeholder: '86abcdefghij12',
            ),
            ConnectField(
              key: 'clientSecret',
              label: 'Primary Client Secret',
              kind: FieldKind.password,
              secret: true,
              help: 'Same **Auth** tab, "Primary Client Secret" (click the eye icon to reveal it). '
                  'It stays on this device.',
            ),
            ConnectField(
              key: 'apiVersion',
              label: 'LinkedIn API version',
              required: false,
              defaultValue: LinkedInApi.defaultVersion,
              placeholder: LinkedInApi.defaultVersion,
              help: 'Month of the LinkedIn API to use (YYYYMM). Each version works for at least a year; '
                  'only change this if NEFORUM tells you the version is no longer supported.',
            ),
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.handoff,
          intro: 'No setup needed. NEFORUM copies your text, opens LinkedIn (app or website) and you press **Post** '
              'yourself. Photos and videos can be attached through the share sheet on phones.',
          fields: [
            ConnectField(
              key: 'displayName',
              label: 'Name to show in NEFORUM',
              required: false,
              placeholder: 'My LinkedIn',
            ),
          ],
        ),
      ];

  static const String _byokIntro = '''
**Post to your own LinkedIn profile automatically.** You need your own (free) LinkedIn developer app:

1. Go to <https://www.linkedin.com/developers/apps> and click **Create app**.
2. Enter an app name (e.g. "NEFORUM for <your name>"), pick a **LinkedIn Page** you administer (create a free one at <https://www.linkedin.com/company/setup/new/> if you have none), upload a logo, accept the terms and create the app.
3. On the app's **Settings** tab click **Verify** next to the Page and approve it (instant when you are the Page's admin).
4. On the **Products** tab click **Request access** for **Share on LinkedIn** and for **Sign In with LinkedIn using OpenID Connect**. Both are approved instantly.
5. On the **Auth** tab, under "Authorized redirect URLs for your app", add exactly `http://127.0.0.1:52771/callback` and save. Check that the scopes `openid`, `profile` and `w_member_social` are listed.
6. Copy the **Client ID** and **Primary Client Secret** from the Auth tab into the fields below, then click Connect and sign in to LinkedIn in your browser.

LinkedIn sign-ins expire after **60 days**; NEFORUM will ask you to reconnect then. Company Pages cannot be posted to with this setup.''';

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier == PlatformTier.handoff) {
      final name = (input['displayName'] ?? '').trim();
      return ConnectResult(
        account: ConnectedAccount(
          id: 'linkedin:handoff:${const Uuid().v4()}',
          platformId: id,
          tier: PlatformTier.handoff,
          displayName: name.isEmpty ? 'LinkedIn (hand-off)' : name,
          createdAt: ctx.now(),
        ),
      );
    }
    if (tier != PlatformTier.byokApi) {
      throw ConnectException('LinkedIn does not support the ${tier.label} tier');
    }

    final clientId = (input['clientId'] ?? '').trim();
    final clientSecret = (input['clientSecret'] ?? '').trim();
    final version = (input['apiVersion'] ?? '').trim().isEmpty ? LinkedInApi.defaultVersion : input['apiVersion']!.trim();
    if (clientId.isEmpty) throw const ConnectException('Enter the Client ID from your LinkedIn app', field: 'clientId');
    if (clientSecret.isEmpty) {
      throw const ConnectException('Enter the Primary Client Secret from your LinkedIn app', field: 'clientSecret');
    }
    if (!RegExp(r'^\d{6}$').hasMatch(version)) {
      throw const ConnectException('The API version must look like 202609 (year and month)', field: 'apiVersion');
    }

    final AuthBroker broker;
    try {
      broker = ctx.requireBroker();
    } on StateError {
      throw const ConnectException('Connecting LinkedIn needs a browser sign-in, which is not available here');
    }
    final spec = specFor(PlatformTier.byokApi);
    final redirect = broker.chooseRedirectUri(
      loopbackOk: spec.loopbackRedirectOk,
      customSchemeOk: spec.customSchemeRedirectOk,
      fixed: spec.fixedRedirectUri,
    );
    final client = _oauthClient(clientId, clientSecret);

    final OAuthTokens tokens;
    try {
      final request = client.buildAuthorizationUrl(redirectUri: redirect);
      final back = await broker.authorize(request.url, redirect);
      final code = client.extractCode(back, request);
      tokens = await client.exchangeCode(ctx.http, code: code, redirectUri: redirect, now: ctx.now());
    } on OAuthException catch (e) {
      throw ConnectException(_oauthMessage(e, redirect));
    }

    final Map<String, dynamic> info;
    try {
      final res = await ctx.http.get(LinkedInApi.userInfoEndpoint, headers: tokens.authorizationHeader);
      info = res.jsonMap;
    } on HttpFailure catch (e) {
      throw ConnectException('Signed in, but LinkedIn refused to share your profile (HTTP ${e.statusCode}). '
          'Make sure "Sign In with LinkedIn using OpenID Connect" is added to your app.');
    }
    final sub = info['sub'] as String?;
    if (sub == null || sub.isEmpty) {
      throw const ConnectException('LinkedIn did not return your member id; try connecting again');
    }
    final name = (info['name'] as String?) ??
        [info['given_name'], info['family_name']].whereType<String>().join(' ').trim();

    return ConnectResult(
      account: ConnectedAccount(
        id: 'linkedin:$sub',
        platformId: id,
        tier: PlatformTier.byokApi,
        displayName: name.isEmpty ? 'LinkedIn member' : name,
        avatarUrl: info['picture'] as String?,
        createdAt: ctx.now(),
        config: {
          cfgClientId: clientId,
          cfgApiVersion: version,
          cfgSub: sub,
          cfgPersonUrn: 'urn:li:person:$sub',
          cfgRedirectUri: redirect.toString(),
        },
      ),
      secrets: tokens.toSecrets({secretClientSecret: clientSecret}),
    );
  }

  static OAuth2Client _oauthClient(String clientId, String clientSecret) => OAuth2Client(
        authorizationEndpoint: LinkedInApi.authorizationEndpoint,
        tokenEndpoint: LinkedInApi.tokenEndpoint,
        clientId: clientId,
        clientSecret: clientSecret,
        scopes: LinkedInApi.scopes,
        // The standard (self-serve) flow uses the client secret; LinkedIn's
        // PKCE flow is a separate endpoint that LinkedIn must enable per app.
        usePkce: false,
        clientAuth: ClientAuth.body,
      );

  static String _oauthMessage(OAuthException e, Uri redirect) {
    final d = '${e.error ?? ''} ${e.description ?? ''}'.toLowerCase();
    if (d.contains('redirect')) {
      return 'LinkedIn rejected the redirect URL. Add exactly $redirect to your app\'s Auth tab '
          '("Authorized redirect URLs for your app") and try again.';
    }
    if (d.contains('scope') || d.contains('unauthorized_scope')) {
      return 'Your LinkedIn app is missing a permission. Add the products "Share on LinkedIn" and '
          '"Sign In with LinkedIn using OpenID Connect" on the Products tab, then try again.';
    }
    if (d.contains('client') && (d.contains('secret') || d.contains('invalid'))) {
      return 'LinkedIn did not accept the Client ID / Client Secret. Copy both again from the Auth tab.';
    }
    final detail = [e.error, e.description].whereType<String>().where((s) => s.isNotEmpty).join(': ');
    return 'LinkedIn sign-in failed${detail.isEmpty ? '' : ' ($detail)'}';
  }

  // ------------------------------------------------------------- refresh

  @override
  Future<Map<String, String>?> refreshSecrets(
      ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.byokApi) return null;
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) throw const AdapterException(PublishError.auth(_reconnectMessage));
    if (!tokens.isExpired(now: ctx.now())) return null;

    // Only partner (MDP) apps get refresh tokens; self-serve apps must
    // re-run the browser sign-in.
    final refresh = tokens.refreshToken;
    final clientSecret = secrets[secretClientSecret];
    final clientId = account.configString(cfgClientId);
    if (refresh == null || refresh.isEmpty || clientSecret == null || clientId.isEmpty) {
      throw const AdapterException(PublishError.auth(_expiredMessage));
    }
    try {
      final fresh = await _oauthClient(clientId, clientSecret).refresh(ctx.http, refreshToken: refresh, now: ctx.now());
      return fresh.toSecrets(secrets);
    } on OAuthException catch (e) {
      throw AdapterException(e.isGrantRejected ? PublishError.auth(_expiredMessage, raw: e.toString()) : e.toRefreshError('LinkedIn'));
    }
  }

  static const String _expiredMessage =
      'Your LinkedIn sign-in has expired (LinkedIn tokens last 60 days). Reconnect LinkedIn in Accounts.';
  static const String _reconnectMessage = 'LinkedIn is not signed in. Reconnect LinkedIn in Accounts.';

  // ------------------------------------------------------------ validate

  /// Photos must have fewer than [maxImagePixels] pixels.
  @override
  PhotoFit? photoFit(ConnectedAccount account, PostVariant variant) =>
      super.photoFit(account, variant)?.copyWith(maxPixels: maxImagePixels);

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = RulesValidator.validate(variant, descriptor, tier: account.tier);
    final t = descriptor.text;

    if (variant.isThread) {
      issues.add(const ValidationIssue.error(
          'thread.unsupported', 'LinkedIn has no threads; shorten the text to 3000 characters', field: 'text'));
    }

    if (account.tier == PlatformTier.byokApi) {
      if (account.configString(cfgPersonUrn).isEmpty && account.configString(cfgSub).isEmpty) {
        issues.add(const ValidationIssue.error(
            'account.not_connected', 'This LinkedIn account is not fully connected; reconnect it', field: 'account'));
      }
      final commentary = commentaryFor(variant);
      final raw = TextCounter.count(commentary, t);
      if (raw > t.maxLength! && !issues.any((i) => i.code == 'text.too_long')) {
        issues.add(ValidationIssue.error('text.too_long',
            'Text plus link is $raw/${t.maxLength} characters for LinkedIn', field: 'text'));
      } else {
        final escaped = LittleText.escape(commentary).length;
        if (raw <= t.maxLength! && escaped > t.maxLength!) {
          issues.add(const ValidationIssue.warning('text.escape_budget',
              'Special characters ( ) [ ] { } < > @ | ~ _ * need escaping on LinkedIn and may push the post over '
              '3000 characters; LinkedIn might refuse it',
              field: 'text'));
        }
      }
    }

    // --- media specifics ------------------------------------------------
    for (final m in variant.media) {
      if (m.isImage && m.width != null && m.height != null && m.width! * m.height! >= maxImagePixels) {
        issues.add(ValidationIssue.error('media.image_pixels',
            '${m.fileName ?? m.id} has ${m.width! * m.height!} pixels; LinkedIn allows fewer than 36,152,320',
            field: 'media'));
      }
      if (m.isVideo) {
        if (m.sizeBytes < minVideoBytes) {
          issues.add(ValidationIssue.error(
              'media.video_too_small', '${m.fileName ?? m.id} is smaller than LinkedIn\'s 75 KB minimum', field: 'media'));
        }
        if (m.durationMs != null && m.durationMs! < minVideoSeconds * 1000) {
          issues.add(const ValidationIssue.error(
              'media.video_too_short', 'LinkedIn videos must be at least 3 seconds long', field: 'media'));
        }
      }
      if ((m.altText ?? '').length > maxAltTextLength) {
        issues.add(const ValidationIssue.error(
            'media.alt_too_long', 'Alt text is longer than LinkedIn\'s 4086 characters', field: 'media'));
      }
    }

    // --- visibility / title ---------------------------------------------
    if (variant.visibility == Visibility.unlisted) {
      issues.add(const ValidationIssue.warning(
          'visibility.unlisted', 'LinkedIn has no unlisted posts; this will be public', field: 'visibility'));
    } else if (variant.visibility == Visibility.private) {
      issues.add(const ValidationIssue.warning('visibility.private',
          'LinkedIn has no private posts; this will be visible to your connections', field: 'visibility'));
    }
    final hasTitle = (variant.title ?? '').trim().isNotEmpty;
    final usesTitle = (_hasLink(variant) && !variant.hasMedia) || variant.media.any((m) => m.isVideo);
    if (hasTitle && !usesTitle) {
      issues.add(const ValidationIssue.info('title.unused',
          'LinkedIn only shows a title on link cards and videos; it will not appear in this post', field: 'title'));
    }
    return issues;
  }

  // ------------------------------------------------------------- publish

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    try {
      return await _publish(variant, account, secrets, ctx);
    } on AdapterException catch (e) {
      return PublishResult.failure(e.error);
    } on HttpFailure catch (e) {
      return PublishResult.failure(LinkedInApi.mapFailure(e, 'Posting', ctx.now()));
    }
  }

  Future<PublishResult> _publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier == PlatformTier.handoff) {
      return PublishResult.failure(
          const PublishError.unsupported('Hand-off LinkedIn accounts are posted through the share sheet'));
    }
    if (variant.isThread) {
      return PublishResult.failure(
          const PublishError.validation('LinkedIn has no threads; shorten the text to 3000 characters'));
    }
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) return PublishResult.failure(const PublishError.auth(_reconnectMessage));
    if (tokens.isExpired(now: ctx.now(), leeway: Duration.zero)) {
      return PublishResult.failure(const PublishError.auth(_expiredMessage));
    }
    final author = _authorUrn(account);
    if (author == null) {
      return PublishResult.failure(
          const PublishError.configuration('This LinkedIn account has no member id; reconnect it'));
    }

    final api = LinkedInApi(
      ctx: ctx,
      accessToken: tokens.accessToken,
      version: account.configString(cfgApiVersion, LinkedInApi.defaultVersion),
      videoPollInterval: videoPollInterval,
      videoPollAttempts: videoPollAttempts,
    );

    final content = await _content(variant, author, api, ctx);
    final body = <String, Object?>{
      'author': author,
      'commentary': LittleText.escape(commentaryFor(variant)),
      'visibility': visibilityFor(variant),
      'distribution': {
        'feedDistribution': 'MAIN_FEED',
        'targetEntities': <Object?>[],
        'thirdPartyDistributionChannels': <Object?>[],
      },
      if (content != null) 'content': content,
      'lifecycleState': 'PUBLISHED',
      'isReshareDisabledByAuthor': variant.extraAs<bool>('linkedinDisableReshare') ?? false,
    };
    ctx.progress('Publishing to LinkedIn');
    final urn = await api.createPost(body);
    return PublishResult.ok(remoteId: urn, remoteUrl: postUrl(urn), publishedAt: ctx.now());
  }

  Future<Map<String, Object?>?> _content(PostVariant v, String author, LinkedInApi api, AdapterContext ctx) async {
    final videos = v.media.where((m) => m.isVideo).toList();
    final images = v.media.where((m) => m.isImage).toList();
    if (videos.isNotEmpty) {
      ctx.progress('Uploading video');
      final urn = await api.uploadVideo(videos.first, author);
      final title = v.title?.trim();
      return {
        'media': {'id': urn, if (title != null && title.isNotEmpty) 'title': title},
      };
    }
    if (images.isNotEmpty) {
      final uploaded = <Map<String, Object?>>[];
      for (var i = 0; i < images.length; i++) {
        ctx.progress('Uploading image ${i + 1} of ${images.length}');
        final urn = await api.uploadImage(images[i], author);
        final alt = images[i].altText?.trim();
        uploaded.add({'id': urn, if (alt != null && alt.isNotEmpty) 'altText': alt});
      }
      return uploaded.length >= multiImageMin ? {'multiImage': {'images': uploaded}} : {'media': uploaded.single};
    }
    final link = v.link?.trim();
    if (link != null && link.isNotEmpty) {
      final description = v.extraAs<String>('linkDescription')?.trim();
      return {
        'article': {
          'source': link,
          'title': _articleTitle(v, link),
          if (description != null && description.isNotEmpty) 'description': description,
        },
      };
    }
    return null;
  }

  static String _articleTitle(PostVariant v, String link) {
    final t = (v.title ?? v.extraAs<String>('linkTitle'))?.trim();
    if (t != null && t.isNotEmpty) return t;
    final uri = Uri.tryParse(link);
    final host = uri?.host ?? '';
    return host.isEmpty ? link : host.replaceFirst(RegExp(r'^www\.'), '');
  }

  static String? _authorUrn(ConnectedAccount account) {
    final urn = account.configString(cfgPersonUrn);
    if (urn.isNotEmpty) return urn;
    final sub = account.configString(cfgSub);
    return sub.isEmpty ? null : 'urn:li:person:$sub';
  }

  static bool _hasLink(PostVariant v) => (v.link ?? '').trim().isNotEmpty;

  /// The plain (unescaped) commentary: the text, plus the link when the
  /// post carries media (a link card is only possible without media).
  static String commentaryFor(PostVariant v) {
    final text = v.text.trimRight();
    if (!_hasLink(v) || !v.hasMedia) return text;
    final link = v.link!.trim();
    if (_textContainsLink(text, link)) return text;
    return text.isEmpty ? link : '$text\n\n$link';
  }

  static bool _textContainsLink(String text, String link) {
    if (text.contains(link)) return true;
    final normalized = Uri.tryParse(link)?.toString();
    return UrlDetector.find(text).any((u) => u.text == link || u.normalized == normalized);
  }

  /// Maps NEFORUM visibility onto LinkedIn's. `extra['linkedinVisibility']`
  /// (PUBLIC / CONNECTIONS / LOGGED_IN) wins when set.
  static String visibilityFor(PostVariant v) {
    final forced = v.extraAs<String>('linkedinVisibility')?.toUpperCase();
    if (forced == 'PUBLIC' || forced == 'CONNECTIONS' || forced == 'LOGGED_IN') return forced!;
    return switch (v.visibility) {
      Visibility.public || Visibility.unlisted => 'PUBLIC',
      Visibility.followers || Visibility.private => 'CONNECTIONS',
    };
  }

  /// Public URL of a post URN (`urn:li:share:...` / `urn:li:ugcPost:...`).
  static String postUrl(String urn) => 'https://www.linkedin.com/feed/update/$urn/';

  // ------------------------------------------------------------- hand-off

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final link = variant.link?.trim();
    final hasLink = link != null && link.isNotEmpty;
    final text = variant.text.trimRight();
    final media = variant.media;

    // share-offsite is the documented intent but only takes a URL; the
    // undocumented feed/?shareActive=true&text= prefills the composer but
    // has been reported to open the article editor since 2026-10, so the
    // text always goes on the clipboard as well.
    final Uri webIntent;
    final String clipboard;
    if (hasLink && media.isEmpty) {
      webIntent = Uri.parse('https://www.linkedin.com/sharing/share-offsite/?url=${Uri.encodeComponent(link)}');
      clipboard = text;
    } else {
      final full = hasLink && !_textContainsLink(text, link) ? (text.isEmpty ? link : '$text\n\n$link') : text;
      webIntent = Uri.parse('https://www.linkedin.com/feed/?shareActive=true&text=${Uri.encodeComponent(full)}');
      clipboard = full;
    }
    final shareText = hasLink && !_textContainsLink(clipboard, link) ? '$clipboard\n\n$link'.trim() : clipboard;

    final instructions = media.isNotEmpty
        ? '1. Your text is on the clipboard.\n'
            '2. In the share sheet pick **LinkedIn** (on a computer, open linkedin.com and click **Start a post**).\n'
            '3. If the text is missing, long-press the text box and **Paste**; attach the media if needed.\n'
            '4. Tap **Post**.'
        : hasLink
            ? '1. LinkedIn opens with your link ready to share; your text is on the clipboard.\n'
                '2. Click into the text box above the link preview and **Paste**.\n'
                '3. Click **Post**.'
            : '1. LinkedIn opens with your text in a new post; it is also on the clipboard.\n'
                '2. If the box is empty or an article editor opens, go to linkedin.com, click **Start a post** and **Paste**.\n'
                '3. Click **Post**.';

    return HandoffPlan(
      platformId: id,
      instructions: instructions,
      webIntent: webIntent,
      clipboardText: clipboard,
      shareText: shareText,
      shareFiles: media,
      androidPackage: 'com.linkedin.android',
      iosScheme: 'linkedin://',
      desktopUrl: 'https://www.linkedin.com/feed/',
      preferred: media.isNotEmpty ? HandoffMethod.shareSheet : HandoffMethod.webIntent,
      mediaNote: media.isEmpty
          ? null
          : 'LinkedIn\'s website cannot receive photos or videos from another app. On a phone use the share sheet; '
              'on a computer attach the files yourself after pasting the text. On iPhone the LinkedIn app may only '
              'accept the text or link.',
    );
  }
}
