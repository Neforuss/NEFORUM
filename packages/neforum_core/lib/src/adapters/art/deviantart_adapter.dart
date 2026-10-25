import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../auth/auth_broker.dart';
import '../../auth/oauth2_pkce.dart';
import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../model/account.dart';
import '../../model/artwork.dart';
import '../../model/media.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'art_api_common.dart';
import 'deviantart_api.dart';

/// Limits NEFORUM applies to DeviantArt.
abstract final class DeviantArtLimits {
  /// DeviantArt's submission form takes titles of up to 50 characters.
  static const int titleMax = 50;

  /// Sta.sh publishes one file as one deviation.
  static const int apiImages = 1;

  /// A multi-image deviation on the website (100 with a Core membership).
  static const int handoffImages = 10;
}

const _text = TextRules(
  titleSupported: true,
  titleRequired: true,
  titleMax: DeviantArtLimits.titleMax,
  hashtagsAsField: true,
  notes: 'The title (up to 50 characters), the description and the tags each go in their own field. Tags take '
      'letters, digits and underscores only.',
);

const _imageTypes = {'image/jpeg', 'image/png', 'image/gif'};

/// Static description of DeviantArt (the API tier's media rules).
const PlatformDescriptor deviantArtDescriptor = PlatformDescriptor(
  id: 'deviantart',
  name: 'DeviantArt',
  iconKey: 'deviantart',
  homepage: 'https://www.deviantart.com',
  tiers: {PlatformTier.byokApi, PlatformTier.handoff},
  defaultTier: PlatformTier.byokApi,
  categories: {PlatformCategory.art},
  text: _text,
  media: MediaRules(
    maxImages: DeviantArtLimits.apiImages,
    requiresMedia: true,
    imageMimeTypes: _imageTypes,
    notes: 'One image per deviation through the API. By hand-off, up to 10 images in one deviation (100 with Core). '
        'DeviantArt publishes no file size limit.',
  ),
  accountRequirements: 'Any DeviantArt account with a verified email address, plus your own free DeviantArt app '
      '(registered in a minute, no review).',
  apiCostSummary: 'Free. DeviantArt has no fixed quota; it slows down apps that send too many requests.',
  setupGuide: 'docs/platforms/deviantart.md',
);

/// The hand-off tier: a multi-image deviation on the website.
const PlatformDescriptor _handoffDescriptor = PlatformDescriptor(
  id: 'deviantart',
  name: 'DeviantArt',
  iconKey: 'deviantart',
  homepage: 'https://www.deviantart.com',
  tiers: {PlatformTier.byokApi, PlatformTier.handoff},
  defaultTier: PlatformTier.byokApi,
  categories: {PlatformCategory.art},
  text: _text,
  media: MediaRules(
    maxImages: DeviantArtLimits.handoffImages,
    requiresMedia: true,
    imageMimeTypes: _imageTypes,
    notes: 'Up to 10 images in one deviation (100 with Core). DeviantArt publishes no file size limit.',
  ),
  accountRequirements: 'Any DeviantArt account. NEFORUM never signs in; you submit on deviantart.com.',
  apiCostSummary: 'Free.',
  setupGuide: 'docs/platforms/deviantart.md',
);

/// DeviantArt: publishes artwork through the user's own DeviantArt app
/// (OAuth 2.0 with PKCE, then Sta.sh submit and publish), or hands it to the
/// Studio submit page.
class DeviantArtAdapter extends PlatformAdapter {
  // Config keys (non-secret).
  static const cfgClientId = 'clientId';
  static const cfgRedirectUri = 'redirectUri';
  static const cfgUserId = 'userId';

  // Secret keys (besides OAuthTokens' own).
  static const secretClientSecret = 'client_secret';

  /// The Studio submit page (`/submit/` redirects there).
  static const String uploadUrl = 'https://www.deviantart.com/studio?new=1';

  @override
  PlatformDescriptor get descriptor => deviantArtDescriptor;

  @override
  PlatformDescriptor descriptorForAccount(ConnectedAccount account) =>
      account.tier == PlatformTier.handoff ? _handoffDescriptor : deviantArtDescriptor;

  /// DeviantArt replaces the refresh token on every renewal.
  @override
  bool rotatesRefreshTokensFor(ConnectedAccount account) => account.tier == PlatformTier.byokApi;

  // ------------------------------------------------------------- connect

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.byokApi,
          usesBrowser: true,
          loopbackRedirectOk: true,
          customSchemeRedirectOk: false,
          redirectNote: 'Add `http://127.0.0.1:52771/callback` to "OAuth2 Redirect URI Whitelist" in your DeviantArt '
              'app. It works on every device: phones and Macs pass it on to NEFORUM by themselves.',
          intro: _byokIntro,
          fields: [
            ConnectField(
              key: 'clientId',
              label: 'Client ID',
              help: 'deviantart.com/studio/apps > your app > "client_id".',
              placeholder: '12345',
            ),
            ConnectField(
              key: 'clientSecret',
              label: 'Client secret (only for a Confidential app)',
              kind: FieldKind.password,
              required: false,
              secret: true,
              help: 'Leave empty when your app\'s client type is **Public**. A Confidential app shows its '
                  '"client_secret" on the same page. It stays on this device.',
            ),
            ConnectField(
              key: 'redirectUri',
              label: 'Redirect URI (advanced)',
              kind: FieldKind.url,
              required: false,
              placeholder: 'http://127.0.0.1:52771/callback',
              help: 'Leave empty: NEFORUM uses http://127.0.0.1:52771/callback. Only if you whitelisted '
                  'http://localhost:52771/callback instead, enter that here.',
            ),
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.handoff,
          intro: 'No setup needed. NEFORUM opens DeviantArt\'s submit page, puts your description on the clipboard and '
              'lists the title and tags to copy. On a phone it shares your images to the DeviantArt app. You set the '
              'rating and press **Submit** yourself.',
          fields: [
            ConnectField(key: 'displayName', label: 'Name to show in NEFORUM', required: false, placeholder: 'My DeviantArt'),
          ],
        ),
      ];

  static const String _byokIntro = '''
**Publish deviations automatically.** You need your own (free) DeviantArt app:

1. Sign in to DeviantArt in your browser and open <https://www.deviantart.com/developers/register>.
2. Give the app a name (for example "NEFORUM for <your name>") and choose the client type **Public**.
3. Under "OAuth2 Redirect URI Whitelist" enter `http://127.0.0.1:52771/callback`. Save.
4. Copy the app's **client_id** into the field below and click Connect. Allow access in the browser.

NEFORUM asks for `basic`, `stash` and `publish`: read your username, put a file in your Sta.sh, and publish it.''';

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier == PlatformTier.handoff) {
      final name = (input['displayName'] ?? '').trim();
      return ConnectResult(
        account: ConnectedAccount(
          id: 'deviantart:handoff:${const Uuid().v4()}',
          platformId: id,
          tier: PlatformTier.handoff,
          displayName: name.isEmpty ? 'DeviantArt (hand-off)' : name,
          createdAt: ctx.now(),
        ),
      );
    }
    if (tier != PlatformTier.byokApi) throw ConnectException('DeviantArt does not support the ${tier.label} tier');

    final clientId = (input['clientId'] ?? '').trim();
    final clientSecret = (input['clientSecret'] ?? '').trim();
    if (clientId.isEmpty) throw const ConnectException('Enter the client_id of your DeviantArt app', field: 'clientId');

    final AuthBroker broker;
    try {
      broker = ctx.requireBroker();
    } on StateError {
      throw const ConnectException('Connecting DeviantArt needs a browser sign-in, which is not available here');
    }
    final redirect = _redirectUri(broker, (input['redirectUri'] ?? '').trim());
    final client = _oauthClient(clientId, clientSecret);

    final OAuthTokens tokens;
    try {
      final request = client.buildAuthorizationUrl(redirectUri: redirect);
      final back = await broker.authorize(request.url, redirect);
      final code = client.extractCode(back, request);
      tokens = await client.exchangeCode(ctx.http, code: code, redirectUri: redirect, pkce: request.pkce, now: ctx.now());
    } on OAuthException catch (e) {
      throw ConnectException(_oauthMessage(e, redirect));
    }

    final DeviantArtUser user;
    try {
      user = await DeviantArtApi(ctx: ctx, accessToken: tokens.accessToken).whoami();
    } on HttpFailure catch (e) {
      throw ConnectException('Signed in, but ${DeviantArtApi.mapFailure(e, context: 'DeviantArt').message}');
    }
    if (user.username.isEmpty) throw const ConnectException('DeviantArt did not return your username; try again');

    return ConnectResult(
      account: ConnectedAccount(
        id: 'deviantart:${user.id ?? user.username}',
        platformId: id,
        tier: PlatformTier.byokApi,
        displayName: user.username,
        handle: user.username,
        avatarUrl: user.icon,
        profileUrl: 'https://www.deviantart.com/${user.username}',
        createdAt: ctx.now(),
        config: {
          cfgClientId: clientId,
          cfgRedirectUri: redirect.toString(),
          if (user.id != null) cfgUserId: user.id,
        },
      ),
      secrets: tokens.toSecrets({if (clientSecret.isNotEmpty) secretClientSecret: clientSecret}),
    );
  }

  /// The address DeviantArt sends the browser back to: the user's override,
  /// else the loopback address the broker listens on.
  Uri _redirectUri(AuthBroker broker, String override) {
    if (override.isNotEmpty) {
      final u = Uri.tryParse(override);
      if (u == null || !u.hasScheme) {
        throw const ConnectException('The redirect URI must be a full address such as http://127.0.0.1:52771/callback',
            field: 'redirectUri');
      }
      return u;
    }
    final spec = specFor(PlatformTier.byokApi);
    return broker.chooseRedirectUri(
      loopbackOk: spec.loopbackRedirectOk,
      customSchemeOk: spec.customSchemeRedirectOk,
      fixed: spec.fixedRedirectUri,
    );
  }

  /// PKCE (S256) always; the secret only for a Confidential app.
  static OAuth2Client _oauthClient(String clientId, String clientSecret) => OAuth2Client(
        authorizationEndpoint: DeviantArtApi.authorizationEndpoint,
        tokenEndpoint: DeviantArtApi.tokenEndpoint,
        clientId: clientId,
        clientSecret: clientSecret.isEmpty ? null : clientSecret,
        scopes: DeviantArtApi.scopes,
        usePkce: true,
        clientAuth: ClientAuth.body,
      );

  static String _oauthMessage(OAuthException e, Uri redirect) {
    final detail = [e.error, e.description].whereType<String>().where((s) => s.isNotEmpty).join(': ');
    final said = detail.isEmpty ? '' : ' DeviantArt said: "$detail".';
    final d = detail.toLowerCase();
    if (d.contains('redirect')) {
      return 'DeviantArt refused the return address $redirect. Add exactly that address to "OAuth2 Redirect URI '
          'Whitelist" in your app at deviantart.com/studio/apps, save, and connect again.$said';
    }
    if (d.contains('access_denied')) return 'You did not allow NEFORUM to access DeviantArt.';
    if (d.contains('client')) {
      return 'DeviantArt did not accept the client_id (or client secret). Copy it again from deviantart.com/studio/apps. '
          'A Public app needs no secret.$said';
    }
    return 'DeviantArt sign-in failed.${said.isEmpty ? ' ${e.message}.' : said}';
  }

  // ------------------------------------------------------------- refresh

  @override
  Future<Map<String, String>?> refreshSecrets(
      ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.byokApi) return null;
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) throw const AdapterException(PublishError.auth(_reconnectMessage));
    final now = ctx.now();
    if (!tokens.isExpired(now: now)) return null;
    final refresh = tokens.refreshToken;
    final clientId = account.configString(cfgClientId);
    if (refresh == null || refresh.isEmpty || clientId.isEmpty) {
      throw const AdapterException(PublishError.auth(_expiredMessage));
    }
    try {
      final fresh = await _oauthClient(clientId, secrets[secretClientSecret] ?? '')
          .refresh(ctx.http, refreshToken: refresh, now: now);
      return fresh.toSecrets(secrets);
    } on OAuthException catch (e) {
      final err = e.toRefreshError('DeviantArt');
      if (err.kind == PublishErrorKind.auth) {
        throw AdapterException(PublishError.auth(_expiredMessage, raw: e.toString(), statusCode: e.statusCode));
      }
      throw AdapterException(err);
    }
  }

  static const String _expiredMessage =
      'Your DeviantArt sign-in has expired (it lapses after 3 months without use). Reconnect DeviantArt in Accounts.';
  static const String _reconnectMessage = 'DeviantArt is not signed in. Reconnect DeviantArt in Accounts.';

  @override
  Future<void> disconnect(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final token = secrets[OAuthTokens.keyAccessToken];
    if (token == null || token.isEmpty) return;
    try {
      await DeviantArtApi(ctx: ctx, accessToken: token).revoke(secrets[OAuthTokens.keyRefreshToken] ?? token);
    } on Object catch (e) {
      ctx.log.warn('Revoking the DeviantArt token failed', e);
    }
  }

  // ------------------------------------------------------------ validate

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = validateArtwork(variant, descriptorForAccount(account), tier: account.tier);
    final changed = variant.tags.where((t) => cleanTag(t) != t).toList();
    if (changed.isNotEmpty) {
      issues.add(ValidationIssue.info(
        'deviantart.tags',
        'DeviantArt tags take letters, digits and underscores only, so ${changed.map((t) => '"$t"').join(', ')} '
            '${changed.length == 1 ? 'loses' : 'lose'} the other characters',
        field: 'tags',
      ));
    }
    return issues;
  }

  /// A tag as DeviantArt takes it: letters, digits and underscores.
  static String cleanTag(String tag) => tag.replaceAll(RegExp(r'[^\p{L}\p{N}_]', unicode: true), '');

  // ------------------------------------------------------------- publish

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    try {
      return await _publish(variant, account, secrets, ctx);
    } on AdapterException catch (e) {
      return PublishResult.failure(e.error);
    } on HttpFailure catch (e) {
      return PublishResult.failure(DeviantArtApi.mapFailure(e, context: 'Posting to DeviantArt'));
    } on Error {
      rethrow; // programming errors only
    } on Object catch (e) {
      final text = e.toString();
      if (NeforumHttp.isTransportError(e)) {
        return PublishResult.failure(PublishError.network('Could not reach DeviantArt ($text)', raw: text));
      }
      return PublishResult.failure(PublishError.platform('DeviantArt publish failed: $text', raw: text));
    }
  }

  Future<PublishResult> _publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier == PlatformTier.handoff) {
      return PublishResult.failure(
          const PublishError.unsupported('This is a hand-off account; use the hand-off instead'));
    }
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) return PublishResult.failure(const PublishError.auth(_reconnectMessage));
    final rejection = artworkRejection(validate(variant, account));
    if (rejection != null) return PublishResult.failure(rejection);

    final art = variant.artwork!;
    final image = variant.media.firstWhere((m) => m.isImage);
    final bytes = await _read(image, ctx);
    final api = DeviantArtApi(ctx: ctx, accessToken: tokens.accessToken);

    ctx.progress('Uploading the image to Sta.sh');
    final itemId = await api.submit(
      image,
      bytes,
      title: artworkTitle(variant, max: DeviantArtLimits.titleMax),
      artistComments: artistComments(artworkDescription(variant)),
      tags: {for (final t in variant.tags.map(cleanTag)) if (t.isNotEmpty) t}.toList(),
      aiGenerated: art.aiGenerated,
      noAi: art.disallowAiTraining,
    );

    ctx.progress('Publishing the deviation');
    try {
      final deviation = await api.publish(publishForm(itemId, art));
      return PublishResult.ok(remoteId: deviation.id, remoteUrl: deviation.url, publishedAt: ctx.now());
    } on HttpFailure catch (e) {
      final err = DeviantArtApi.mapFailure(e, context: 'Publishing on DeviantArt', publishing: true);
      // The draft stays in Sta.sh; a retry submits the file again.
      return PublishResult.failure(PublishError(
        kind: err.kind,
        message: '${err.message}. The image waits in your Sta.sh (item $itemId); publish it there, or retry.',
        retryable: err.retryable,
        statusCode: err.statusCode,
        raw: err.raw,
        retryAfter: err.retryAfter,
      ));
    }
  }

  /// The `stash/publish` form for [itemId]: the rating as DeviantArt's
  /// mature flag and level (moderate for mature, strict for adult), and the
  /// AI labels.
  static Map<String, String> publishForm(String itemId, ArtworkDetails art) => {
        'itemid': itemId,
        'is_mature': '${art.maturity != ArtworkMaturity.general}',
        if (art.maturity == ArtworkMaturity.mature) 'mature_level': 'moderate',
        if (art.maturity == ArtworkMaturity.adult) 'mature_level': 'strict',
        'is_ai_generated': '${art.aiGenerated}',
        'noai': '${art.disallowAiTraining}',
      };

  /// The description as DeviantArt shows it: HTML, so the text is escaped
  /// and its line breaks kept.
  static String artistComments(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('\r\n', '\n')
      .replaceAll('\n', '<br />');

  static Future<Uint8List> _read(MediaAttachment m, AdapterContext ctx) async {
    try {
      return await ctx.readMedia(m);
    } on Exception catch (e) {
      throw AdapterException(PublishError.configuration('Could not read ${m.fileName ?? m.path}: $e'));
    }
  }

  // ------------------------------------------------------------- hand-off

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final art = variant.artwork;
    return artworkHandoff(
      variant,
      platformId: id,
      name: descriptor.name,
      uploadUrl: uploadUrl,
      hasApp: true,
      androidPackage: 'com.deviantart.android.damobile',
      titleMax: DeviantArtLimits.titleMax,
      ratingSteps: [
        if (art != null)
          switch (art.maturity) {
            ArtworkMaturity.general => 'Leave **Mature content** off.',
            ArtworkMaturity.mature => 'Turn on **Mature content** and choose **Moderate**.',
            ArtworkMaturity.adult => 'Turn on **Mature content** and choose **Strict**.',
          },
        if (art != null && art.aiGenerated) 'Turn on **Created using AI tools**.',
        if (art != null && art.disallowAiTraining) 'Keep **NoAI** on (it asks AI datasets to leave the work out).',
      ],
      finishStep: 'Press **Submit**.',
    );
  }
}
