import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../auth/oauth2_pkce.dart';
import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
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
import 'instagram_api.dart';
import 'instagram_rules.dart';

/// Instagram: hand-off for every account (default), plus automatic posting
/// through "Instagram API with Instagram Login" for professional accounts
/// that bring their own Meta app.
///
/// The API cannot take uploads for photos: every file is first put on the
/// user's [MediaHost] and Instagram downloads it from there. Hosted copies
/// are deleted once the post is published (or failed).
class InstagramAdapter extends PlatformAdapter {
  InstagramAdapter({
    List<Duration> pollSchedule = defaultPollSchedule,
    Future<void> Function(Duration)? sleep,
  })  : _pollSchedule = pollSchedule,
        _sleep = sleep ?? ((d) => Future<void>.delayed(d));

  /// Redirect URI NEFORUM suggests registering. Meta only accepts HTTPS
  /// redirects (no http loopback, no custom scheme); `https://localhost`
  /// is accepted by the Instagram business-login settings.
  static const String defaultRedirectUri = 'https://localhost:52771/callback';

  /// Status polls: right away, then backing off to once a minute, about
  /// five minutes in total (Meta: "once per minute, for no more than 5
  /// minutes").
  static const List<Duration> defaultPollSchedule = [
    Duration.zero,
    Duration(seconds: 3),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(seconds: 60),
    Duration(seconds: 60),
    Duration(seconds: 60),
  ];

  /// Secret key holding when the token was last issued/refreshed.
  static const String keyRefreshedAt = 'refreshed_at';

  /// Instagram lets a long-lived token be refreshed once it is 24 h old.
  static const Duration minRefreshAge = Duration(hours: 24);

  /// NEFORUM refreshes weekly, well inside the 60-day lifetime.
  static const Duration refreshEvery = Duration(days: 7);
  static const Duration longLivedLifetime = Duration(days: 60);

  final List<Duration> _pollSchedule;
  final Future<void> Function(Duration) _sleep;

  @override
  PlatformDescriptor get descriptor => InstagramRules.descriptor;

  @override
  List<ConnectSpec> get connectSpecs => [
        const ConnectSpec(
          tier: PlatformTier.handoff,
          intro: _handoffIntro,
          loopbackRedirectOk: false,
          customSchemeRedirectOk: false,
          fields: [
            ConnectField(
              key: 'username',
              label: 'Instagram username (optional)',
              required: false,
              placeholder: 'yourname',
              help: 'Only used to label this account in NEFORUM.',
            ),
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.byokApi,
          usesBrowser: true,
          intro: _apiIntro,
          loopbackRedirectOk: false,
          customSchemeRedirectOk: false,
          fixedRedirectUri: Uri.parse(defaultRedirectUri),
          redirectNote: 'Only for browser sign-in (not needed when you paste a token): register exactly '
              '$defaultRedirectUri under API setup with Instagram login > Set up Instagram business login > '
              'Business login settings > OAuth redirect URIs. After you approve, the browser shows an error '
              'page: copy the whole address from the address bar and paste it into NEFORUM.',
          fields: const [
            ConnectField(
              key: 'access_token',
              label: 'Access token from "Generate token"',
              kind: FieldKind.password,
              required: false,
              secret: true,
              help: 'App Dashboard > **API setup with Instagram login** > **Generate access tokens** > '
                  '**Generate token** next to your account (listed once it has accepted its Instagram Tester '
                  'invite). Lasts 60 days; NEFORUM renews it automatically. With a token, leave the fields below '
                  'empty.',
            ),
            ConnectField(
              key: 'app_id',
              label: 'Instagram app ID',
              required: false,
              placeholder: '1234567890123456',
              help: 'Only for browser sign-in. Top of **API setup with Instagram login**: the ID of the `-IG` '
                  'app Meta created for you (not the Meta App ID under App settings > Basic).',
            ),
            ConnectField(
              key: 'app_secret',
              label: 'Instagram app secret',
              kind: FieldKind.password,
              required: false,
              secret: true,
              help: 'Only for browser sign-in. Next to the Instagram app ID, click **Show**. Used once while '
                  'connecting, never stored.',
            ),
            ConnectField(
              key: 'redirect_uri',
              label: 'Redirect URI',
              kind: FieldKind.url,
              required: false,
              defaultValue: defaultRedirectUri,
              help: 'Only for browser sign-in. Must match an address under **Business login settings > OAuth '
                  'redirect URIs** character for character (https only).',
            ),
          ],
        ),
      ];

  // --- connect ---------------------------------------------------------------

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier == PlatformTier.handoff) return _connectHandoff(input, ctx);
    if (tier != PlatformTier.byokApi) {
      throw ConnectException('Instagram does not support "${tier.label}"');
    }
    final api = _api(ctx);
    final pasted = (input['access_token'] ?? '').trim();
    try {
      final Map<String, String> secrets;
      final config = <String, dynamic>{};
      if (pasted.isNotEmpty) {
        secrets = _tokenSecrets(pasted, null, ctx.now());
        config['tokenSource'] = 'dashboard';
      } else {
        final (token, appId, redirect) = await _oauth(input, ctx, api);
        secrets = _tokenSecrets(token.accessToken, token.expiresIn ?? longLivedLifetime, ctx.now());
        config
          ..['tokenSource'] = 'oauth'
          ..['appId'] = appId
          ..['redirectUri'] = redirect.toString();
      }
      final profile = await api.me(secrets[OAuthTokens.keyAccessToken]!);
      final type = (profile.accountType ?? '').toUpperCase();
      if (type.isNotEmpty && type != 'BUSINESS' && type != 'MEDIA_CREATOR' && type != 'CREATOR') {
        throw const ConnectException('This is a personal Instagram account. Switch it to a professional account '
            '(free, in the Instagram app) or connect it with Hand-off instead.');
      }
      config
        ..['igUserId'] = profile.userId
        ..['username'] = profile.username
        ..['accountType'] = profile.accountType;
      return ConnectResult(
        account: ConnectedAccount(
          id: 'instagram-${profile.userId}',
          platformId: descriptor.id,
          tier: PlatformTier.byokApi,
          displayName: profile.name == null ? '@${profile.username}' : '${profile.name} (@${profile.username})',
          handle: '@${profile.username}',
          avatarUrl: profile.pictureUrl,
          profileUrl: 'https://www.instagram.com/${profile.username}/',
          createdAt: ctx.now(),
          config: config,
        ),
        secrets: secrets,
      );
    } on AdapterException catch (e) {
      // A pasted token is the only input the first call depends on, so point
      // the error at that field.
      throw ConnectException(
          pasted.isEmpty
              ? e.error.message
              : '${e.error.message}. Generate a new token for your account and paste all of it.',
          field: pasted.isEmpty ? null : 'access_token');
    } on OAuthException catch (e) {
      throw ConnectException('Instagram sign-in failed: ${e.description ?? e.error ?? e.message}');
    }
  }

  Future<ConnectResult> _connectHandoff(Map<String, String> input, AdapterContext ctx) async {
    final user = (input['username'] ?? '').trim().replaceFirst(RegExp('^@'), '');
    return ConnectResult(
      account: ConnectedAccount(
        id: 'instagram-handoff-${const Uuid().v4()}',
        platformId: descriptor.id,
        tier: PlatformTier.handoff,
        displayName: user.isEmpty ? 'Instagram (hand-off)' : '@$user',
        handle: user.isEmpty ? null : '@$user',
        profileUrl: user.isEmpty ? null : 'https://www.instagram.com/$user/',
        createdAt: ctx.now(),
        config: {if (user.isNotEmpty) 'username': user},
      ),
    );
  }

  /// Business Login for Instagram: browser → code → short-lived token →
  /// long-lived token. Returns the long-lived token, app id and redirect.
  Future<(InstagramLongToken, String, Uri)> _oauth(Map<String, String> input, AdapterContext ctx, InstagramApi api) async {
    final appId = (input['app_id'] ?? '').trim();
    final secret = (input['app_secret'] ?? '').trim();
    if (appId.isEmpty) {
      throw const ConnectException('Enter your Instagram app ID (or paste an access token instead)', field: 'app_id');
    }
    if (secret.isEmpty) throw const ConnectException('Enter your Instagram app secret', field: 'app_secret');
    final registered = Uri.tryParse((input['redirect_uri'] ?? '').trim().isEmpty
        ? defaultRedirectUri
        : input['redirect_uri']!.trim());
    if (registered == null || registered.scheme != 'https' || registered.host.isEmpty) {
      throw const ConnectException('Instagram only accepts https:// redirect URIs', field: 'redirect_uri');
    }
    final broker = ctx.broker;
    if (broker == null) throw const ConnectException('Connecting Instagram needs a browser');
    final redirect = broker.chooseRedirectUri(loopbackOk: false, customSchemeOk: false, fixed: registered);
    final client = OAuth2Client(
      authorizationEndpoint: instagramAuthorizeUrl,
      tokenEndpoint: instagramTokenUrl,
      clientId: appId,
      clientSecret: secret,
      scopes: instagramScopes,
      scopeSeparator: ',',
      usePkce: false,
    );
    final request = client.buildAuthorizationUrl(redirectUri: redirect);
    ctx.progress('Waiting for you to approve NEFORUM on Instagram…');
    final back = await broker.authorize(request.url, redirect);
    final code = extractCode(back, request.state);
    ctx.progress('Exchanging the Instagram code for a token…');
    final short = await api.exchangeCode(appId: appId, appSecret: secret, redirectUri: redirect, code: code);
    if (short.permissions.isNotEmpty && !short.permissions.contains('instagram_business_content_publish')) {
      throw const ConnectException('Instagram did not grant permission to publish. Connect again and keep '
          '"Publish content" switched on.');
    }
    final long = await api.exchangeLongLived(short.accessToken, secret);
    return (long, appId, redirect);
  }

  /// Pulls the code out of the redirect (or a pasted bare code). Instagram
  /// appends `#_` to the redirect; a pasted code may still carry it. A
  /// missing `state` is tolerated because paste-code brokers cannot carry
  /// it, a wrong one is not.
  static String extractCode(Uri redirect, String expectedState) {
    final q = {...redirect.queryParameters};
    if (q['error'] != null) {
      final why = q['error_description'] ?? q['error_reason'] ?? q['error'];
      throw ConnectException(q['error_reason'] == 'user_denied'
          ? 'You declined the Instagram permissions'
          : 'Instagram refused the sign-in: $why');
    }
    final state = q['state'];
    if (state != null && state != expectedState) {
      throw const ConnectException('The sign-in response did not match this request; try again');
    }
    var code = (q['code'] ?? '').trim();
    if (code.endsWith('#_')) code = code.substring(0, code.length - 2);
    if (code.isEmpty) throw const ConnectException('The address you pasted contains no Instagram code');
    return code;
  }

  // --- tokens ----------------------------------------------------------------

  Map<String, String> _tokenSecrets(String token, Duration? lifetime, DateTime now,
          [Map<String, String> existing = const {}]) =>
      {
        ...OAuthTokens(
          accessToken: token,
          expiresAt: lifetime == null ? null : now.add(lifetime),
        ).toSecrets({...existing}..remove(OAuthTokens.keyExpiresAt)),
        keyRefreshedAt: now.toUtc().toIso8601String(),
      };

  @override
  Future<Map<String, String>?> refreshSecrets(
      ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.byokApi) return null;
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) {
      throw const AdapterException(PublishError.auth('No Instagram token stored; reconnect the account'));
    }
    final now = ctx.now();
    final expiresAt = tokens.expiresAt;
    if (expiresAt != null && !now.isBefore(expiresAt)) {
      throw const AdapterException(PublishError.auth(
          'Your Instagram token expired (they last 60 days unless refreshed); reconnect the account'));
    }
    final refreshedAt = DateTime.tryParse(secrets[keyRefreshedAt] ?? '');
    final age = refreshedAt == null ? null : now.difference(refreshedAt);
    final expiringSoon = expiresAt != null && expiresAt.difference(now) < refreshEvery;
    if (age != null && age < minRefreshAge) return null;
    // A pasted "Generate token" token has no known expiry (it may already be
    // weeks old), so it is refreshed as soon as Instagram allows, which also
    // tells NEFORUM when it expires.
    if (age != null && age < refreshEvery && !expiringSoon && expiresAt != null) return null;
    try {
      ctx.progress('Refreshing the Instagram token…');
      final fresh = await _api(ctx).refresh(tokens.accessToken);
      return _tokenSecrets(fresh.accessToken, fresh.expiresIn ?? longLivedLifetime, now, secrets);
    } on AdapterException catch (e) {
      if (e.error.kind == PublishErrorKind.auth) rethrow;
      ctx.log.warn('Instagram token refresh failed; keeping the current token: ${e.error.message}');
      return null;
    }
  }

  // --- validation --------------------------------------------------------------

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) =>
      InstagramRules.check(variant, account.tier, super.validate(variant, account));

  // --- publishing ----------------------------------------------------------------

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.byokApi) {
      return PublishResult.failure(const PublishError.unsupported(
          'This Instagram account uses hand-off: NEFORUM prepares the post and you tap Share in Instagram'));
    }
    final hosted = <HostedMedia>[];
    try {
      return await _publishApi(variant, account, secrets, ctx, hosted);
    } on AdapterException catch (e) {
      return PublishResult.failure(e.error);
    } on HttpFailure catch (f) {
      return PublishResult.failure(mapHttpFailure(f));
    } on TimeoutException {
      return PublishResult.failure(const PublishError.network('Timed out talking to Instagram'));
    } on http.ClientException catch (e) {
      return PublishResult.failure(PublishError.network('Network error: ${e.message}'));
    } finally {
      await _cleanup(hosted, ctx);
    }
  }

  Future<PublishResult> _publishApi(PostVariant v, ConnectedAccount account, Map<String, String> secrets,
      AdapterContext ctx, List<HostedMedia> hosted) async {
    final host = ctx.mediaHost;
    if (host == null) {
      throw const AdapterException(PublishError.configuration(
          'Instagram downloads media from a public link: set up a media host in Settings first'));
    }
    final errors = validate(v, account).errors.toList();
    if (errors.isNotEmpty) throw AdapterException(PublishError.validation(errors.first.message));
    final token = OAuthTokens.fromSecrets(secrets)?.accessToken;
    if (token == null) throw const AdapterException(PublishError.auth('No Instagram token stored; reconnect'));
    final igUserId = account.configString('igUserId');
    if (igUserId.isEmpty) {
      throw const AdapterException(PublishError.configuration('Instagram account id missing; reconnect the account'));
    }

    final urls = await _hostAll(v.media, host, ctx, hosted);
    final api = _api(ctx);
    final caption = v.text.trim();
    final String containerId;
    if (InstagramRules.isStory(v)) {
      containerId = await _single(api, igUserId, token, {
        'media_type': 'STORIES',
        _urlField(v.media.first): urls.first,
      }, 'your story');
    } else if (v.media.length == 1) {
      containerId = await _single(api, igUserId, token, _singleFields(v, urls.first, caption),
          v.media.first.isVideo ? 'your Reel' : 'your photo');
    } else {
      containerId = await _carousel(api, igUserId, token, v, urls, caption, ctx);
    }
    ctx.progress('Publishing to Instagram…');
    final mediaId = await api.publish(igUserId, token, containerId);
    final link = await api.permalink(mediaId, token);
    return PublishResult.ok(remoteId: mediaId, remoteUrl: link, publishedAt: ctx.now());
  }

  Map<String, String> _singleFields(PostVariant v, String url, String caption) {
    final m = v.media.first;
    if (m.isVideo) {
      final shareToFeed = v.extraAs<bool>('shareToFeed');
      final thumbOffset = v.extraAs<int>('thumbOffsetMs');
      return {
        'media_type': 'REELS',
        'video_url': url,
        if (caption.isNotEmpty) 'caption': caption,
        if (shareToFeed != null) 'share_to_feed': '$shareToFeed',
        if (thumbOffset != null) 'thumb_offset': '$thumbOffset',
      };
    }
    return {
      'image_url': url,
      if (caption.isNotEmpty) 'caption': caption,
      if ((m.altText ?? '').trim().isNotEmpty) 'alt_text': m.altText!.trim(),
    };
  }

  Future<String> _single(InstagramApi api, String igUserId, String token, Map<String, String> fields, String label) async {
    api.ctx.progress('Sending $label to Instagram…');
    final id = await api.createContainer(igUserId, token, fields, label: label);
    await api.waitUntilFinished(id, token, label: label);
    return id;
  }

  Future<String> _carousel(InstagramApi api, String igUserId, String token, PostVariant v, List<String> urls,
      String caption, AdapterContext ctx) async {
    final children = <String>[];
    for (var i = 0; i < v.media.length; i++) {
      final m = v.media[i];
      final label = 'item ${i + 1} of ${v.media.length}';
      ctx.progress('Sending carousel $label to Instagram…');
      final id = await api.createContainer(igUserId, token, {
        'is_carousel_item': 'true',
        if (m.isVideo) 'media_type': 'VIDEO',
        _urlField(m): urls[i],
        if (m.isImage && (m.altText ?? '').trim().isNotEmpty) 'alt_text': m.altText!.trim(),
      }, label: 'carousel $label');
      await api.waitUntilFinished(id, token, label: 'carousel $label');
      children.add(id);
    }
    ctx.progress('Assembling the carousel…');
    final parent = await api.createContainer(igUserId, token, {
      'media_type': 'CAROUSEL',
      'children': children.join(','),
      if (caption.isNotEmpty) 'caption': caption,
    }, label: 'the carousel');
    await api.waitUntilFinished(parent, token, label: 'the carousel');
    return parent;
  }

  static String _urlField(MediaAttachment m) => m.isVideo ? 'video_url' : 'image_url';

  Future<List<String>> _hostAll(
      List<MediaAttachment> media, MediaHost host, AdapterContext ctx, List<HostedMedia> hosted) async {
    final urls = <String>[];
    for (var i = 0; i < media.length; i++) {
      final m = media[i];
      ctx.progress('Uploading ${m.isVideo ? 'video' : 'image'} ${i + 1} of ${media.length} to ${host.name}…');
      final bytes = await _read(ctx, m);
      try {
        final h = await host.upload(m, bytes, ttl: const Duration(hours: 24));
        hosted.add(h);
        urls.add(h.url.toString());
      } on MediaHostException catch (e) {
        throw AdapterException(e.toPublishError());
      } on HttpFailure catch (f) {
        final message = 'Your media host (${host.name}) refused the upload: HTTP ${f.statusCode}';
        throw AdapterException(f.statusCode >= 500 || f.statusCode == 429
            ? PublishError.network(message, statusCode: f.statusCode, retryAfter: f.response.retryAfter)
            : PublishError.configuration(message));
      } on AdapterException {
        rethrow;
      } on Object catch (e) {
        if (NeforumHttp.isTransportError(e)) {
          throw AdapterException(PublishError.network('Could not reach your media host (${host.name}): $e'));
        }
        throw AdapterException(PublishError.configuration('Your media host (${host.name}) failed: $e'));
      }
    }
    return urls;
  }

  static Future<Uint8List> _read(AdapterContext ctx, MediaAttachment m) async {
    try {
      return await ctx.readMedia(m);
    } on Object catch (e) {
      throw AdapterException(PublishError.configuration('Could not read ${m.fileName ?? m.path}: $e'));
    }
  }

  Future<void> _cleanup(List<HostedMedia> hosted, AdapterContext ctx) async {
    final host = ctx.mediaHost;
    if (host == null) return;
    for (final h in hosted) {
      try {
        await host.delete(h);
      } on Object catch (e) {
        ctx.log.warn('Could not delete ${h.url} from ${host.name}', e);
      }
    }
  }

  InstagramApi _api(AdapterContext ctx) => InstagramApi(ctx, sleep: _sleep, pollSchedule: _pollSchedule);

  // --- hand-off --------------------------------------------------------------------

  @override
  HandoffPlan buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final caption = variant.text.trim();
    final story = InstagramRules.isStory(variant);
    final hasCaption = caption.isNotEmpty && !story;
    final steps = <String>[
      if (hasCaption) 'Your caption is already on the clipboard.',
      'Choose **Instagram** in the share sheet (on a computer: open instagram.com, click **Create** and pick the files).',
      if (story)
        'Pick **Story** and add stickers or text if you like.'
      else if (hasCaption)
        'Pick Feed or Reel, then long-press the caption box and tap **Paste**.'
      else
        'Pick Feed or Reel.',
      'Tap **Share**.',
    ];
    final note = StringBuffer(hasCaption
        ? 'Instagram ignores captions sent through the share sheet, so NEFORUM put your caption on the clipboard; paste it in Instagram.'
        : 'Instagram takes the photo or video from the share sheet; nothing else can be prefilled.');
    if (variant.media.length > 1) {
      note.write(' Sharing several files at once does not work on every phone; if only one arrives, add the rest '
          'from your gallery inside Instagram.');
    }
    return HandoffPlan(
      platformId: descriptor.id,
      instructions: [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n'),
      clipboardText: hasCaption ? caption : null,
      shareText: hasCaption ? caption : null,
      shareFiles: variant.media,
      androidPackage: 'com.instagram.android',
      iosScheme: 'instagram://',
      desktopUrl: 'https://www.instagram.com/',
      preferred: HandoffMethod.shareSheet,
      mediaNote: note.toString(),
    );
  }
}

const String _handoffIntro = '''
**Hand-off works with every Instagram account, personal ones included.**

When you post, NEFORUM copies your caption to the clipboard and hands the photo or video to the Instagram app (or opens instagram.com on a computer). You paste the caption and tap **Share** yourself. Nothing to set up.''';

const String _apiIntro = '''
**Automatic posting needs a professional Instagram account (Business or Creator), your own free Meta app and a media host.** Personal accounts cannot use the API: use Hand-off, or switch for free in Instagram (**Settings > Account type and tools > Switch to professional account**). No Facebook Page and no App Review needed.

1. Open <https://developers.facebook.com/apps/creation/> and create an app with the use case **Manage messaging & content on Instagram** (if asked for an app type, pick **Business**). No business portfolio? Pick **I don't want to connect a business portfolio yet**.
2. **Use cases > Customize > Permissions and features**: click **+ Add** next to both `instagram_business_basic` and `instagram_business_content_publish` (neither is on by default). The list cuts the names off; each row's description shows the full name.
3. **App roles > Roles > Add People > Instagram Tester**, enter your Instagram username, then accept the invite in Instagram: **Settings > Apps and websites > Tester invites**. Tokens can't be made without this.
4. Open **API setup with Instagram login** (left menu). Your account now shows under **Generate access tokens**: click **Generate token**, log in in the pop-up, copy the token and paste it into the first field below. It lasts 60 days and NEFORUM renews it automatically.
5. Pick a **media host** in NEFORUM **Settings > Media hosting**, even for text-only posts (they go out as a text card image). **Litterbox** needs no setup and is fine to start; for regular posting a bucket you own (Backblaze B2, Cloudflare R2, Amazon S3) is more reliable. The **Guide** button there explains each host.

**Browser sign-in instead of a token:** copy the **Instagram app ID** and **Instagram app secret** from the top of the same page (the `-IG` app Meta made for you, not the Meta App ID), add `https://localhost:52771/callback` under **Set up Instagram business login > Business login settings > OAuth redirect URIs**, press **Sign in**, then paste the whole address of the page that fails to load.''';
