import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../auth/auth_broker.dart';
import '../../auth/oauth2_pkce.dart';
import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../model/account.dart';
import '../../model/artwork.dart';
import '../../model/media.dart';
import '../../model/photo_fit.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'art_api_common.dart';
import 'dribbble_api.dart';

/// Limits from developer.dribbble.com/v2/shots and the help center
/// (read 2026-10-25).
abstract final class DribbbleLimits {
  static const int maxTags = 12;

  /// The API takes one image of exactly one of [apiSizes], at most 8 MB.
  static const int apiImageMaxBytes = 8 * 1024 * 1024;
  static const List<({int width, int height})> apiSizes = [(width: 800, height: 600), (width: 400, height: 300)];

  /// The web uploader: images up to 10 MB, MOV or MP4 up to 20 MB.
  static const int webImageMaxBytes = 10 * 1024 * 1024;
  static const int webVideoMaxBytes = 20 * 1024 * 1024;

  /// Files NEFORUM hands over for one shot (the website adds them as blocks).
  static const int handoffFiles = 10;

  static const int requestsPerDay = 1440;
}

const _text = TextRules(
  titleSupported: true,
  titleRequired: true,
  hashtagsAsField: true,
  maxHashtags: DribbbleLimits.maxTags,
  notes: 'A shot has a title, a description and up to 12 tags, each in its own field.',
);

const _imageTypes = {'image/png', 'image/jpeg', 'image/gif'};

/// Static description of Dribbble (the hand-off tier, its default).
const PlatformDescriptor dribbbleDescriptor = PlatformDescriptor(
  id: 'dribbble',
  name: 'Dribbble',
  iconKey: 'dribbble',
  homepage: 'https://dribbble.com',
  tiers: {PlatformTier.handoff, PlatformTier.byokApi},
  defaultTier: PlatformTier.handoff,
  categories: {PlatformCategory.art},
  text: _text,
  media: MediaRules(
    maxImages: DribbbleLimits.handoffFiles,
    maxVideos: 1,
    requiresMedia: true,
    allowsMixedImageVideo: true,
    imageMaxBytes: DribbbleLimits.webImageMaxBytes,
    videoMaxBytes: DribbbleLimits.webVideoMaxBytes,
    imageMimeTypes: _imageTypes,
    videoMimeTypes: {'video/mp4', 'video/quicktime'},
    notes: 'On the website: PNG, JPG or GIF images up to 10 MB and MOV or MP4 video up to 20 MB, at least 1600 pixels '
        'wide recommended. Through the API: one image of exactly 800 x 600 or 400 x 300 pixels, up to 8 MB, no video.',
  ),
  defaultQuotas: [
    QuotaRule(
      id: 'dribbble.requests_per_day',
      limit: DribbbleLimits.requestsPerDay,
      window: Duration(days: 1),
      note: 'Dribbble allows 60 API requests a minute and 1,440 a day per user; a shot uses one.',
      appliesToTier: PlatformTier.byokApi,
    ),
  ],
  accountRequirements: 'Any Dribbble account for the hand-off. Posting through the API needs your own Dribbble app '
      'and an account that may upload shots (an approved Designer account or a team).',
  apiCostSummary: 'Free. The API allows 60 requests a minute and 1,440 a day, and Dribbble reviews every shot.',
  setupGuide: 'docs/platforms/dribbble.md',
);

/// The API tier: one image of an exact size, no video.
const PlatformDescriptor _apiDescriptor = PlatformDescriptor(
  id: 'dribbble',
  name: 'Dribbble',
  iconKey: 'dribbble',
  homepage: 'https://dribbble.com',
  tiers: {PlatformTier.handoff, PlatformTier.byokApi},
  defaultTier: PlatformTier.handoff,
  categories: {PlatformCategory.art},
  text: _text,
  media: MediaRules(
    maxImages: 1,
    requiresMedia: true,
    imageMaxBytes: DribbbleLimits.apiImageMaxBytes,
    imageMimeTypes: _imageTypes,
    notes: 'One PNG, JPG or GIF image of exactly 800 x 600 or 400 x 300 pixels, up to 8 MB. NEFORUM fits photos to '
        '800 x 600; GIFs must already have one of the sizes.',
  ),
  defaultQuotas: [
    QuotaRule(
      id: 'dribbble.requests_per_day',
      limit: DribbbleLimits.requestsPerDay,
      window: Duration(days: 1),
      note: 'Dribbble allows 60 API requests a minute and 1,440 a day per user; a shot uses one.',
      appliesToTier: PlatformTier.byokApi,
    ),
  ],
  accountRequirements: 'Your own Dribbble app and an account that may upload shots (an approved Designer account or '
      'a team).',
  apiCostSummary: 'Free. The API allows 60 requests a minute and 1,440 a day, and Dribbble reviews every shot.',
  setupGuide: 'docs/platforms/dribbble.md',
);

/// Dribbble: hands a shot to the web uploader, or creates it through API v2
/// with the user's own Dribbble app (OAuth 2.0 with the app's client id and
/// secret).
class DribbbleAdapter extends PlatformAdapter {
  // Config keys (non-secret).
  static const cfgClientId = 'clientId';
  static const cfgRedirectUri = 'redirectUri';
  static const cfgCanUploadShot = 'canUploadShot';

  /// The signed-in uploader.
  static const String uploadUrl = 'https://dribbble.com/uploads/new';

  @override
  PlatformDescriptor get descriptor => dribbbleDescriptor;

  @override
  PlatformDescriptor descriptorForAccount(ConnectedAccount account) =>
      account.tier == PlatformTier.byokApi ? _apiDescriptor : dribbbleDescriptor;

  /// The API takes only 800 x 600 and 400 x 300: photos are brought to 4:3
  /// and resized to 800 x 600.
  @override
  PhotoFit? photoFit(ConnectedAccount account, PostVariant variant) {
    if (account.tier != PlatformTier.byokApi) return super.photoFit(account, variant);
    return const PhotoFit(
      minAspect: 4 / 3,
      maxAspect: 4 / 3,
      mimeTypes: _imageTypes,
      maxBytes: DribbbleLimits.apiImageMaxBytes,
      exactSizes: DribbbleLimits.apiSizes,
      label: 'Dribbble',
    );
  }

  // ------------------------------------------------------------- connect

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.handoff,
          intro: 'No setup needed. NEFORUM opens Dribbble\'s uploader, puts your description on the clipboard and lists '
              'the title and tags to copy; you add the images and press **Publish** yourself. With the NEFORUM browser '
              'extension the uploader is filled in for you.',
          fields: [
            ConnectField(key: 'displayName', label: 'Name to show in NEFORUM', required: false, placeholder: 'My Dribbble'),
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.byokApi,
          usesBrowser: true,
          loopbackRedirectOk: true,
          customSchemeRedirectOk: false,
          redirectNote: 'Enter `http://127.0.0.1:52771/callback` as the Callback URL of your Dribbble app. It works on '
              'every device: phones and Macs pass it on to NEFORUM by themselves.',
          intro: _byokIntro,
          fields: [
            ConnectField(
              key: 'clientId',
              label: 'Client ID',
              help: 'dribbble.com/account/applications > your app > "Client ID".',
            ),
            ConnectField(
              key: 'clientSecret',
              label: 'Client Secret',
              kind: FieldKind.password,
              secret: true,
              help: 'Same page, "Client Secret". NEFORUM uses it once to sign in and does not keep it.',
            ),
            ConnectField(
              key: 'redirectUri',
              label: 'Redirect URI (advanced)',
              kind: FieldKind.url,
              required: false,
              placeholder: 'http://127.0.0.1:52771/callback',
              help: 'Leave empty: NEFORUM uses http://127.0.0.1:52771/callback. Only if your app\'s Callback URL is '
                  'http://localhost:52771/callback, enter that here.',
            ),
          ],
        ),
      ];

  static const String _byokIntro = '''
**Create shots automatically.** Only for still images that can be 800 x 600 pixels: the API takes nothing else (no video, no larger images). You need your own (free) Dribbble app:

1. Sign in to Dribbble and open <https://dribbble.com/account/applications/new>.
2. Fill in a name (for example "NEFORUM for <your name>"), a description and a website, and as **Callback URL** enter `http://127.0.0.1:52771/callback`. Register the application.
3. Copy the **Client ID** and **Client Secret** into the fields below and click Connect. Allow access in the browser.

NEFORUM asks for `public` and `upload`: read your profile and create shots. Shots from an account that is not yet an approved Designer stay visible only on your own profile.''';

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier == PlatformTier.handoff) {
      final name = (input['displayName'] ?? '').trim();
      return ConnectResult(
        account: ConnectedAccount(
          id: 'dribbble:handoff:${const Uuid().v4()}',
          platformId: id,
          tier: PlatformTier.handoff,
          displayName: name.isEmpty ? 'Dribbble (hand-off)' : name,
          createdAt: ctx.now(),
        ),
      );
    }
    if (tier != PlatformTier.byokApi) throw ConnectException('Dribbble does not support the ${tier.label} tier');

    final clientId = (input['clientId'] ?? '').trim();
    final clientSecret = (input['clientSecret'] ?? '').trim();
    if (clientId.isEmpty) throw const ConnectException('Enter the Client ID of your Dribbble app', field: 'clientId');
    if (clientSecret.isEmpty) {
      throw const ConnectException('Enter the Client Secret of your Dribbble app', field: 'clientSecret');
    }

    final AuthBroker broker;
    try {
      broker = ctx.requireBroker();
    } on StateError {
      throw const ConnectException('Connecting Dribbble needs a browser sign-in, which is not available here');
    }
    final redirect = _redirectUri(broker, (input['redirectUri'] ?? '').trim());
    final client = OAuth2Client(
      authorizationEndpoint: DribbbleApi.authorizationEndpoint,
      tokenEndpoint: DribbbleApi.tokenEndpoint,
      clientId: clientId,
      clientSecret: clientSecret,
      scopes: DribbbleApi.scopes,
      // Dribbble documents no PKCE; client_id and client_secret go in the
      // token request's body.
      usePkce: false,
      clientAuth: ClientAuth.body,
    );

    final OAuthTokens tokens;
    try {
      final request = client.buildAuthorizationUrl(redirectUri: redirect);
      final back = await broker.authorize(request.url, redirect);
      final code = client.extractCode(back, request);
      tokens = await client.exchangeCode(ctx.http, code: code, redirectUri: redirect, now: ctx.now());
    } on OAuthException catch (e) {
      throw ConnectException(_oauthMessage(e, redirect));
    }

    final DribbbleUser user;
    try {
      user = await DribbbleApi(ctx: ctx, accessToken: tokens.accessToken).user();
    } on HttpFailure catch (e) {
      throw ConnectException('Signed in, but ${DribbbleApi.mapFailure(e, context: 'Dribbble').message}');
    }
    if (user.login.isEmpty) throw const ConnectException('Dribbble did not return your username; try again');
    final name = user.name?.trim() ?? '';

    return ConnectResult(
      account: ConnectedAccount(
        id: 'dribbble:${user.id ?? user.login}',
        platformId: id,
        tier: PlatformTier.byokApi,
        displayName: name.isEmpty ? user.login : name,
        handle: user.login,
        avatarUrl: user.avatarUrl,
        profileUrl: user.profileUrl ?? 'https://dribbble.com/${user.login}',
        createdAt: ctx.now(),
        config: {
          cfgClientId: clientId,
          cfgRedirectUri: redirect.toString(),
          if (user.canUploadShot != null) cfgCanUploadShot: user.canUploadShot,
        },
      ),
      // Dribbble tokens do not expire and are never renewed, so the client
      // secret is not kept.
      secrets: tokens.toSecrets(),
    );
  }

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

  static String _oauthMessage(OAuthException e, Uri redirect) {
    final detail = [e.error, e.description].whereType<String>().where((s) => s.isNotEmpty).join(': ');
    final said = detail.isEmpty ? '' : ' Dribbble said: "$detail".';
    final d = detail.toLowerCase();
    if (d.contains('redirect')) {
      return 'Dribbble refused the return address $redirect. Enter exactly that address as the Callback URL of your app '
          'at dribbble.com/account/applications, save, and connect again.$said';
    }
    if (d.contains('access_denied')) return 'You did not allow NEFORUM to access Dribbble.';
    if (d.contains('client')) {
      return 'Dribbble did not accept the Client ID / Client Secret. Copy both again from '
          'dribbble.com/account/applications.$said';
    }
    return 'Dribbble sign-in failed.${said.isEmpty ? ' ${e.message}.' : said}';
  }

  /// Dribbble tokens do not expire; a missing one means reconnecting.
  @override
  Future<Map<String, String>?> refreshSecrets(
      ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.byokApi) return null;
    if (OAuthTokens.fromSecrets(secrets) == null) throw const AdapterException(PublishError.auth(_reconnectMessage));
    return null;
  }

  static const String _reconnectMessage = 'Dribbble is not signed in. Reconnect Dribbble in Accounts.';

  // ------------------------------------------------------------ validate

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = validateArtwork(variant, descriptorForAccount(account), tier: account.tier);
    final art = variant.artwork;
    if (art?.maturity == ArtworkMaturity.adult) {
      issues.add(const ValidationIssue.error('dribbble.adult', 'Dribbble does not accept adult (explicit) work',
          field: 'account'));
    } else if (art?.maturity == ArtworkMaturity.mature) {
      issues.add(const ValidationIssue.warning(
          'dribbble.mature', 'Dribbble\'s guidelines leave no room for mature work; the shot may be removed in review',
          field: 'account'));
    }
    if (art?.aiGenerated ?? false) {
      issues.add(const ValidationIssue.warning('dribbble.ai',
          'Dribbble does not accept work made entirely with AI; say in the description how AI helped', field: 'account'));
    }
    if (account.tier == PlatformTier.byokApi) {
      for (final m in variant.media.where((m) => m.isImage)) {
        final w = m.width, h = m.height;
        if (w != null && h != null && !DribbbleLimits.apiSizes.any((s) => s.width == w && s.height == h)) {
          issues.add(ValidationIssue.error(
            'dribbble.image_size',
            '${m.fileName ?? 'The image'} is $w x $h; Dribbble\'s API takes exactly 800 x 600 or 400 x 300 pixels. '
                '${m.kind == MediaKind.gif ? 'Resize the GIF, or use the hand-off.' : 'Turn on photo fitting in Settings, or use the hand-off.'}',
            field: 'media',
          ));
        }
      }
      if (account.config[cfgCanUploadShot] == false) {
        issues.add(const ValidationIssue.warning(
            'dribbble.cannot_upload',
            'When you connected, Dribbble did not yet let this account upload shots (it needs an approved Designer '
            'account or a team)',
            field: 'account'));
      }
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
      return PublishResult.failure(DribbbleApi.mapFailure(e, context: 'Posting to Dribbble'));
    } on Error {
      rethrow; // programming errors only
    } on Object catch (e) {
      final text = e.toString();
      if (NeforumHttp.isTransportError(e)) {
        return PublishResult.failure(PublishError.network('Could not reach Dribbble ($text)', raw: text));
      }
      return PublishResult.failure(PublishError.platform('Dribbble publish failed: $text', raw: text));
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

    final image = variant.media.firstWhere((m) => m.isImage);
    final bytes = await _read(image, ctx);
    if (bytes.length > DribbbleLimits.apiImageMaxBytes) {
      return PublishResult.failure(
          PublishError.validation('${image.fileName ?? 'The image'} is larger than Dribbble\'s 8 MB limit'));
    }
    ctx.progress('Uploading the shot');
    final shotId = await DribbbleApi(ctx: ctx, accessToken: tokens.accessToken).createShot(
      image,
      bytes,
      title: artworkTitle(variant),
      description: artworkDescription(variant),
      tags: variant.tags.take(DribbbleLimits.maxTags).toList(),
    );
    return PublishResult.ok(
      remoteId: shotId,
      remoteUrl: shotId == null ? account.profileUrl : DribbbleApi.shotUrl(shotId),
      publishedAt: ctx.now(),
    );
  }

  static Future<Uint8List> _read(MediaAttachment m, AdapterContext ctx) async {
    try {
      return await ctx.readMedia(m);
    } on Exception catch (e) {
      throw AdapterException(PublishError.configuration('Could not read ${m.fileName ?? m.path}: $e'));
    }
  }

  // ------------------------------------------------------------- hand-off

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) => artworkHandoff(
        variant,
        platformId: id,
        name: descriptor.name,
        uploadUrl: uploadUrl,
        browserExtensionFills: true,
        maxTags: DribbbleLimits.maxTags,
        openStep: 'Dribbble\'s uploader opens (sign in if asked). Under **Publish as**, choose yourself or your team.',
        descriptionStep: 'Add a **Text** block with the + button and paste the description (it is on the clipboard).',
        continueStep: 'Click **Continue** to open **Final Touches** and choose the thumbnail.',
        ratingSteps: [
          if (variant.artwork?.aiGenerated ?? false) 'Say in the description how AI helped: Dribbble refuses work made '
              'entirely with AI.',
        ],
        finishStep: 'Press **Publish**.',
      );
}
