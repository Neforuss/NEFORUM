import '../../auth/oauth2_pkce.dart';
import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../model/account.dart';
import '../../model/media.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../../text/rules_validator.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'lemmy_api.dart';

/// `MAX_TITLE_LENGTH` in Lemmy's validation.rs (UTF-16 code units).
const int lemmyTitleMax = 200;

/// Titles need at least 3 visible characters.
const int lemmyTitleMin = 3;

/// `POST_BODY_MAX_LENGTH` (UTF-16 code units).
const int lemmyBodyMax = 50000;

/// `MAX_URL_LENGTH` for the post link.
const int lemmyUrlMax = 2000;

/// `ALT_TEXT_MAX_LENGTH` for image posts.
const int lemmyAltMax = 1500;

/// Stock Lemmy deployments put nginx with `client_max_body_size 20M` in
/// front of pict-rs (whose own default is 40 MB); many instances go lower.
const int lemmyDefaultMaxUploadBytes = 20 * 1024 * 1024;

/// Hand-off URLs longer than this drop the body (it is on the clipboard).
const int _maxIntentLength = 6000;

/// Adapter for Lemmy instances (HTTP API v3: Lemmy 0.19.x, and Lemmy 1.0
/// through its v3 compatibility layer).
///
/// Connect: instance + username/email + password (+ 2FA code) -> a JWT kept
/// as the only secret. Publish: optional `POST /pictrs/image`, then one
/// `POST /api/v3/post` into the chosen community. Mbin and PieFed speak
/// different APIs and are not handled here.
class LemmyAdapter extends PlatformAdapter {
  static const Set<String> _imageTypes = {'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/avif'};
  static const Set<String> _videoTypes = {'video/mp4', 'video/webm'};

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'lemmy',
    name: 'Lemmy',
    iconKey: 'lemmy',
    homepage: 'https://join-lemmy.org',
    family: 'lemmy-api',
    tiers: {PlatformTier.openApi, PlatformTier.handoff},
    defaultTier: PlatformTier.openApi,
    text: TextRules(
      maxLength: lemmyBodyMax,
      counting: CountingRule.utf16,
      titleMax: lemmyTitleMax,
      titleRequired: true,
      titleSupported: true,
      supportsThreads: false,
      supportsContentWarning: false,
      supportsMarkdown: true,
      supportsHashtags: false,
      linkInText: false,
      notes: 'Every post needs a title (3-200 characters, one line) and a community. The body is Markdown, '
          'up to 50000 characters. The link goes into the post\'s own URL field. No hashtags; NSFW is a flag.',
    ),
    media: MediaRules(
      maxImages: 1,
      maxVideos: 1,
      allowsMixedImageVideo: false,
      imageMaxBytes: lemmyDefaultMaxUploadBytes,
      videoMaxBytes: lemmyDefaultMaxUploadBytes,
      imageMimeTypes: _imageTypes,
      videoMimeTypes: _videoTypes,
      supportsAltText: true,
      requiresPublicMediaUrl: false,
      notes: 'One image per post, uploaded to your instance (pict-rs). The size limit is set by the instance '
          '(20 MB on a stock install, much lower on some). Video only works where the admin allows it.',
    ),
    defaultQuotas: [
      QuotaRule(
        id: 'lemmy.posts_per_10min',
        limit: 6,
        window: Duration(minutes: 10),
        note: 'posts per 10 minutes per IP (Lemmy default; your instance can change it). '
            'Image uploads: 6 per hour by default.',
        appliesToTier: PlatformTier.openApi,
      ),
    ],
    personalAccountOk: true,
    accountRequirements: 'Any ordinary account on a Lemmy instance (lemmy.world, lemmy.ml, ...). '
        'No developer account, app or review is needed; you sign in with your username and password.',
    apiCostSummary: 'Free. By default an instance allows about 6 posts every 10 minutes and 6 image uploads an hour; '
        'each instance sets its own limits and image size.',
    setupGuide: 'docs/platforms/lemmy.md',
    serverSideScheduling: false,
    supportsLinkField: true,
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  static const ConnectField _instanceField = ConnectField(
    key: 'instance',
    label: 'Instance',
    kind: FieldKind.url,
    placeholder: 'lemmy.world',
    help: 'The server your account lives on, e.g. `lemmy.world` or `lemmy.ml`. '
        'You can also paste your handle (`@you@lemmy.world`).',
  );

  static const ConnectField _communityField = ConnectField(
    key: 'community',
    label: 'Default community',
    required: false,
    placeholder: '!technology@lemmy.world',
    help: 'Where posts go unless you pick another community for a post. Write it as `!name@instance` '
        '(or paste the community\'s web address). Communities on your own instance can be just `name`.',
  );

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.openApi,
          usesBrowser: false,
          loopbackRedirectOk: false,
          customSchemeRedirectOk: false,
          intro: '**Lemmy needs no developer account and no app registration.** NEFORUM signs in with your '
              'normal Lemmy username (or email) and password, exactly like the website does.\n\n'
              '1. Enter your instance, e.g. `lemmy.world`.\n'
              '2. Enter your username or email and your password. The password is used once to get a login '
              'token and is **not stored**.\n'
              '3. If you turned on two-factor authentication, also enter the current 6-digit code.\n'
              '4. Optionally enter a default community such as `!technology@lemmy.world`.\n\n'
              'Tip: Lemmy instances let you tick **Bot account** in Settings if you only cross-post; '
              'many communities welcome that.',
          redirectNote: 'Nothing to register: Lemmy has no OAuth for apps and no redirect URI.',
          fields: [
            _instanceField,
            ConnectField(
              key: 'username',
              label: 'Username or email',
              placeholder: 'alice',
              help: 'Your Lemmy username (without @instance) or the email address you log in with.',
            ),
            ConnectField(
              key: 'password',
              label: 'Password',
              kind: FieldKind.password,
              secret: true,
              help: 'Only sent to your instance to log in; NEFORUM keeps the login token, not the password.',
            ),
            ConnectField(
              key: 'totp',
              label: 'Two-factor code (if enabled)',
              required: false,
              secret: true,
              placeholder: '123456',
              help: 'Only needed when your account has two-factor authentication turned on.',
            ),
            _communityField,
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.handoff,
          intro: 'NEFORUM opens your instance\'s **Create post** page with the title, link, text and community '
              'filled in; you check it and press **Create**. You must be logged in to your instance in the '
              'browser. Images cannot be attached automatically.',
          loopbackRedirectOk: false,
          customSchemeRedirectOk: false,
          fields: [_instanceField, _communityField],
        ),
      ];

  // ---------------------------------------------------------------- connect

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    final instance = parseLemmyInstance(input['instance'] ?? '');
    final communityRaw = (input['community'] ?? '').trim();
    if (tier == PlatformTier.handoff) {
      final community = communityRaw.isEmpty ? null : await _connectCommunity(LemmyApi(instance, ctx), communityRaw);
      return ConnectResult(
        account: ConnectedAccount(
          id: 'lemmy-handoff:${instance.authority}',
          platformId: id,
          tier: PlatformTier.handoff,
          displayName: '${instance.host} (hand-off)',
          createdAt: ctx.now(),
          profileUrl: instance.toString(),
          config: {'instance': instance.toString(), 'host': instance.host, ...?community},
        ),
      );
    }

    final user = (input['username'] ?? '').trim();
    final password = input['password'] ?? '';
    final totp = (input['totp'] ?? '').replaceAll(RegExp(r'\s'), '');
    if (user.isEmpty) throw const ConnectException('Enter your Lemmy username or email', field: 'username');
    if (password.isEmpty) throw const ConnectException('Enter your Lemmy password', field: 'password');

    final jwt = await _login(instance, user, password, totp, ctx);
    final api = LemmyApi(instance, ctx, jwt: jwt);
    final site = await _site(api, ctx);
    final community = communityRaw.isEmpty ? null : await _connectCommunity(api, communityRaw);

    final person = _person(site);
    final name = _str(person?['name']) ?? (user.contains('@') ? null : user);
    if (name == null) {
      throw const ConnectException('Logged in, but the instance did not say who you are. Use your username instead of your email.',
          field: 'username');
    }
    final siteView = site['site_view'];
    final siteInfo = siteView is Map ? siteView['site'] : null;
    final siteName = siteInfo is Map ? _str(siteInfo['name']) : null;
    final languages = _languages(site);
    return ConnectResult(
      account: ConnectedAccount(
        id: 'lemmy:$name@${instance.authority}',
        platformId: id,
        tier: PlatformTier.openApi,
        displayName: '${_str(person?['display_name']) ?? name} (${instance.host})',
        handle: '@$name@${instance.host}',
        avatarUrl: _str(person?['avatar']),
        profileUrl: '$instance/u/$name',
        createdAt: ctx.now(),
        config: {
          'instance': instance.toString(),
          'host': instance.host,
          'username': name,
          'authMethod': 'password',
          if (person?['id'] is num) 'personId': (person!['id'] as num).toInt(),
          if (siteName != null) 'siteName': siteName,
          if (_str(site['version']) != null) 'version': _str(site['version']),
          if (languages.isNotEmpty) 'languages': languages,
          ...?community,
        },
      ),
      secrets: OAuthTokens(accessToken: jwt, tokenType: 'Bearer').toSecrets(),
    );
  }

  Future<String> _login(Uri instance, String user, String password, String totp, AdapterContext ctx) async {
    ctx.progress('Logging in to ${instance.host}');
    final Map<String, dynamic> res;
    try {
      res = await LemmyApi(instance, ctx).login(user, password, totp: totp);
    } on HttpFailure catch (f) {
      throw await _loginError(instance, f, totp.isNotEmpty, ctx);
    } on Exception catch (e) {
      throw ConnectException('Could not reach ${instance.host}: $e');
    }
    final jwt = _str(res['jwt']);
    if (jwt == null) {
      throw ConnectException(res['verify_email_sent'] == true
          ? 'Lemmy sent you a verification email. Confirm your address, then connect again.'
          : 'Your account on ${instance.host} is waiting for approval. Connect again once it is approved.');
    }
    return jwt;
  }

  Future<ConnectException> _loginError(Uri instance, HttpFailure f, bool sentTotp, AdapterContext ctx) async {
    final code = lemmyErrorCode(f.response);
    switch (code) {
      case 'incorrect_login':
        return const ConnectException('Wrong username/email or password.', field: 'password');
      case 'missing_totp_token':
        return const ConnectException('This account uses two-factor authentication. Enter the current 6-digit code.',
            field: 'totp');
      case 'incorrect_totp_token':
        return const ConnectException('The two-factor code was wrong or expired. Enter the current code.', field: 'totp');
      case 'email_not_verified':
        return const ConnectException('Verify your email address first (check your inbox), then connect again.');
      case 'registration_application_is_pending':
        return ConnectException('Your account on ${instance.host} is still waiting for approval.');
      case 'registration_denied':
        return ConnectException('${instance.host} denied your registration.');
      case 'rate_limit_error':
        return const ConnectException('Too many attempts. Wait a few minutes and try again.');
    }
    if (f.statusCode == 404 && code == null) {
      return ConnectException(await _isPiefed(instance, ctx)
          ? '${instance.host} runs PieFed, which NEFORUM does not support yet. Use the hand-off option or a Lemmy account.'
          : '${instance.host} does not offer the Lemmy API. Mbin, Kbin and PieFed servers are not supported yet.');
    }
    if (f.statusCode == 401) return const ConnectException('Wrong username/email or password.', field: 'password');
    return ConnectException('${instance.host} refused the login (HTTP ${f.statusCode}${code == null ? '' : ', $code'}).');
  }

  Future<bool> _isPiefed(Uri instance, AdapterContext ctx) async {
    try {
      final r = await ctx.http.get(instance.replace(path: '/api/alpha/site'), throwOnError: false);
      return r.ok && r.jsonMap.containsKey('site');
    } on Exception {
      return false;
    }
  }

  /// `GET /api/v3/site`: account info, version and languages. Best effort.
  Future<Map<String, dynamic>> _site(LemmyApi api, AdapterContext ctx) async {
    ctx.progress('Reading your account');
    try {
      return await api.get('site');
    } on Exception catch (e) {
      ctx.log.warn('Lemmy /site failed on ${api.instance.host}: $e');
      return const {};
    }
  }

  Future<Map<String, dynamic>> _connectCommunity(LemmyApi api, String raw) async {
    final name = normalizeLemmyCommunity(raw, homeHost: api.instance.host);
    if (name == null) {
      throw ConnectException('"$raw" is not a community. Write it as !name@instance.', field: 'community');
    }
    try {
      return _communityConfig(await _resolveCommunity(api, name), name);
    } on AdapterException catch (e) {
      throw ConnectException(e.error.message, field: 'community');
    }
  }

  Map<String, dynamic> _communityConfig(Map<String, dynamic> c, String name) => {
        'community': name,
        'communityId': (c['id'] as num).toInt(),
        if (_str(c['title']) != null) 'communityTitle': _str(c['title']),
      };

  /// Looks the community up on the home instance; when the instance has
  /// never seen a remote community, asks it to fetch it (needs a login).
  Future<Map<String, dynamic>> _resolveCommunity(LemmyApi api, String name) async {
    api.ctx.progress('Looking up community $name');
    try {
      return await api.getCommunity(name);
    } on HttpFailure catch (f) {
      final notFound = f.statusCode == 404 || lemmyErrorCode(f.response) == 'couldnt_find_community';
      if (!notFound) throw AdapterException(lemmyPublishError(f, context: 'Community lookup'));
    } on FormatException {
      // Fall through to resolve_object.
    } on Exception catch (e) {
      throw AdapterException(PublishError.network('Community lookup: could not reach ${api.instance.host}', raw: '$e'));
    }
    final remote = name.contains('@');
    if (remote && api.jwt != null) {
      try {
        return await guardLemmy('Community lookup', () => api.resolveCommunity(name));
      } on AdapterException catch (e) {
        if (e.error.kind != PublishErrorKind.validation && e.error.statusCode != 404) rethrow;
      }
    }
    final shown = remote ? '!$name' : '!$name@${api.instance.host}';
    throw AdapterException(PublishError.validation('${api.instance.host} cannot find the community $shown. '
        'Check the spelling${remote ? ', or open it once on the website so your instance learns about it' : ''}.'));
  }

  // --------------------------------------------------------------- validate

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = RulesValidator.validate(variant, descriptor, tier: account.tier);
    final title = variant.title ?? '';
    final clean = _cleanTitle(title);
    if (clean.isNotEmpty && clean.runes.length < lemmyTitleMin) {
      issues.add(const ValidationIssue.error('title.too_short', 'Lemmy titles need at least $lemmyTitleMin characters',
          field: 'title'));
    }
    if (title.contains('\n')) {
      issues.add(const ValidationIssue.warning('title.newline', 'Lemmy titles are one line; line breaks become spaces',
          field: 'title'));
    }
    if (_communityTarget(variant, account) == null) {
      if (account.tier == PlatformTier.handoff) {
        // The Create post page lets the user pick the community there.
        issues.add(const ValidationIssue.info('lemmy.community_on_page', 'You will choose the Lemmy community on the Create post page',
            field: 'account'));
      } else {
        issues.add(const ValidationIssue.error('lemmy.community_required',
            'Choose a community for Lemmy (set a default community on the account or one for this post)', field: 'account'));
      }
    }
    final link = variant.link?.trim() ?? '';
    if (link.isNotEmpty) {
      final uri = Uri.tryParse(link);
      if (uri == null || !const {'http', 'https', 'magnet'}.contains(uri.scheme)) {
        issues.add(const ValidationIssue.error('link.invalid', 'Lemmy links must start with http://, https:// or magnet:',
            field: 'link'));
      }
      if (link.length > lemmyUrlMax) {
        issues.add(const ValidationIssue.error('link.too_long', 'The link is longer than $lemmyUrlMax characters',
            field: 'link'));
      }
    }
    if (variant.media.any((m) => (m.altText ?? '').length > lemmyAltMax)) {
      issues.add(const ValidationIssue.warning('media.alt_too_long',
          'Alt text longer than $lemmyAltMax characters will be shortened', field: 'media'));
    }
    if (account.tier == PlatformTier.openApi) {
      if (variant.media.any((m) => m.isVideo)) {
        issues.add(const ValidationIssue.warning('media.video_instance',
            'Video uploads only work if your Lemmy instance allows them', field: 'media'));
      }
      if (variant.hasMedia && link.isNotEmpty) {
        issues.add(const ValidationIssue.info('media.embedded',
            'The post links to your URL; the image is shown at the top of the text', field: 'media'));
      }
    }
    if (account.tier == PlatformTier.handoff && variant.hasMedia) {
      issues.add(const ValidationIssue.warning('media.handoff',
          'The Lemmy web composer cannot be given files; upload the image yourself on the page', field: 'media'));
    }
    return issues;
  }

  /// The community this post goes to: a per-post override (`extra.community`
  /// or `extra.communityId`) or the account default.
  Object? _communityTarget(PostVariant v, ConnectedAccount account) {
    final id = v.extra['communityId'];
    if (id is num) return id.toInt();
    final name = _str(v.extra['community']);
    if (name != null) return name;
    final cid = account.config['communityId'];
    if (cid is num) return cid.toInt();
    return _str(account.config['community']);
  }

  // ---------------------------------------------------------------- publish

  @override
  Future<Map<String, String>?> refreshSecrets(
      ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    // Lemmy JWTs do not expire; they only stop working after logout or a
    // password change, which the API reports as not_logged_in.
    if (account.tier == PlatformTier.openApi && _jwt(secrets) == null) {
      throw const AdapterException(PublishError.auth('No Lemmy login stored; reconnect the account'));
    }
    return null;
  }

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    try {
      return await _publish(variant, account, secrets, ctx);
    } on AdapterException catch (e) {
      ctx.log.warn('Lemmy publish failed: ${e.error.message}');
      return PublishResult.failure(e.error);
    }
  }

  Future<PublishResult> _publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier == PlatformTier.handoff) {
      throw const AdapterException(PublishError.unsupported('Hand-off accounts publish through the web composer'));
    }
    final instanceRaw = account.configString('instance');
    if (instanceRaw.isEmpty) {
      throw const AdapterException(PublishError.configuration('This Lemmy account has no instance; reconnect it'));
    }
    final instance = Uri.parse(instanceRaw);
    final jwt = _jwt(secrets);
    if (jwt == null) throw const AdapterException(PublishError.auth('No Lemmy login stored; reconnect the account'));
    final api = LemmyApi(instance, ctx, jwt: jwt);

    final title = _cleanTitle(variant.title ?? '');
    if (title.runes.length < lemmyTitleMin) {
      throw const AdapterException(PublishError.validation('Lemmy posts need a title of at least 3 characters'));
    }
    final communityId = await _communityId(variant, account, api);

    String? imageUrl;
    String? alt;
    if (variant.hasMedia) {
      final m = variant.media.first;
      imageUrl = (await _upload(api, m, ctx)).toString();
      alt = _clip(m.altText?.trim(), lemmyAltMax);
    }

    final link = _str(variant.link?.trim());
    var body = (variant.isThread ? variant.threadParts.join('\n\n') : variant.text).trim();
    final url = link ?? imageUrl;
    if (link != null && imageUrl != null) {
      // The URL field holds the link, so show the image inline instead.
      body = '![${_mdAlt(alt ?? '')}]($imageUrl)${body.isEmpty ? '' : '\n\n$body'}';
    }
    if (url != null && url.length > lemmyUrlMax) {
      throw const AdapterException(PublishError.validation('The link is longer than 2000 characters'));
    }
    final languageId = _languageId(variant, account);
    final nsfw = variant.sensitive || variant.extra['nsfw'] == true;

    Map<String, Object?> request(int? lang) => {
          'name': title,
          'community_id': communityId,
          if (url != null) 'url': url,
          if (body.isNotEmpty) 'body': body,
          if (alt != null && url == imageUrl) 'alt_text': alt,
          'nsfw': nsfw,
          if (lang != null) 'language_id': lang,
        };

    ctx.progress('Creating the post');
    final res = await guardLemmy('Lemmy post', () async {
      try {
        return await api.post('post', request(languageId));
      } on HttpFailure catch (f) {
        if (languageId == null || lemmyErrorCode(f.response) != 'language_not_allowed') rethrow;
        ctx.log.info('Community does not allow language $languageId; posting without a language');
        return api.post('post', request(null));
      }
    });
    final pv = res['post_view'];
    final post = pv is Map ? pv['post'] : null;
    final postId = post is Map && post['id'] is num ? (post['id'] as num).toInt() : null;
    if (postId == null) {
      final s = res.toString();
      throw AdapterException(PublishError.platform('Lemmy did not return the created post',
          raw: s.length > 600 ? s.substring(0, 600) : s));
    }
    ctx.log.info('Posted to community $communityId on ${instance.host} as post $postId');
    return PublishResult.ok(remoteId: '$postId', remoteUrl: '$instance/post/$postId', publishedAt: ctx.now());
  }

  Future<int> _communityId(PostVariant variant, ConnectedAccount account, LemmyApi api) async {
    final target = _communityTarget(variant, account);
    if (target is int) return target;
    if (target is! String) {
      throw const AdapterException(PublishError.configuration(
          'No Lemmy community chosen. Set a default community on the account or pick one for this post.'));
    }
    final name = normalizeLemmyCommunity(target, homeHost: api.instance.host);
    if (name == null) {
      throw AdapterException(PublishError.validation('"$target" is not a Lemmy community (write it as !name@instance)'));
    }
    final cached = account.config['communityId'];
    if (cached is num && name == account.config['community']) return cached.toInt();
    final c = await _resolveCommunity(api, name);
    return (c['id'] as num).toInt();
  }

  Future<Uri> _upload(LemmyApi api, MediaAttachment m, AdapterContext ctx) async {
    ctx.progress('Uploading ${m.isVideo ? 'video' : 'image'} 1 of 1');
    final bytes = await ctx.readMedia(m);
    return guardLemmy('Lemmy image upload', () => api.uploadImage(
          bytes: bytes,
          fileName: m.fileName ?? '${m.id}.${_ext(m.mimeType)}',
          contentType: m.mimeType,
        ));
  }

  int? _languageId(PostVariant v, ConnectedAccount account) {
    final explicit = v.extra['languageId'];
    if (explicit is num) return explicit.toInt();
    final lang = v.language?.trim().toLowerCase().replaceAll('_', '-');
    final map = account.config['languages'];
    if (lang == null || lang.isEmpty || map is! Map) return null;
    final hit = map[lang] ?? map[lang.split('-').first];
    return hit is num ? hit.toInt() : null;
  }

  @override
  Future<void> disconnect(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final jwt = _jwt(secrets);
    final instance = account.configString('instance');
    if (jwt == null || instance.isEmpty) return;
    try {
      await LemmyApi(Uri.parse(instance), ctx, jwt: jwt).logout();
    } on Object catch (e) {
      ctx.log.warn('Lemmy logout failed: $e');
    }
  }

  // ---------------------------------------------------------------- hand-off

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final instanceRaw = account?.configString('instance') ?? '';
    final title = _cleanTitle(variant.title ?? '');
    final body = (variant.isThread ? variant.threadParts.join('\n\n') : variant.text).trim();
    final link = _str(variant.link?.trim());
    final full = [title, if (link != null) link, if (body.isNotEmpty) body].where((s) => s.isNotEmpty).join('\n\n');
    final nsfw = variant.sensitive || variant.extra['nsfw'] == true;

    if (instanceRaw.isEmpty) {
      return HandoffPlan(
        platformId: id,
        clipboardText: body.isEmpty ? title : body,
        shareText: full,
        shareFiles: variant.media,
        androidPackage: 'com.jerboa',
        desktopUrl: 'https://join-lemmy.org/instances',
        preferred: HandoffMethod.manual,
        instructions: '1. Open your Lemmy instance and choose **Create post**.\n'
            '2. Type the title, pick the community and paste the text (it is on the clipboard).\n'
            '3. Press **Create**.',
      );
    }

    final instance = Uri.parse(instanceRaw);
    final communityId = _handoffCommunityId(variant, account!);
    final languageId = _languageId(variant, account);
    Uri intent(bool withBody) => instance.replace(path: '/create_post', queryParameters: {
          if (title.isNotEmpty) 'title': title,
          if (link != null) 'url': link,
          if (withBody && body.isNotEmpty) 'body': body,
          if (communityId != null) 'communityId': '$communityId',
          if (languageId != null) 'languageId': '$languageId',
          if (nsfw) 'nsfw': 'true',
        });
    var webIntent = intent(true);
    final bodyInUrl = webIntent.toString().length <= _maxIntentLength;
    if (!bodyInUrl) webIntent = intent(false);

    final steps = <String>[
      'NEFORUM opens **Create post** on ${instance.host} with the title${link != null ? ', link' : ''}'
          '${bodyInUrl && body.isNotEmpty ? ' and text' : ''} filled in (log in there if asked).',
      if (communityId == null) 'Choose the community${_str(variant.extra['community']) != null ? ' ${variant.extra['community']}' : ''}.',
      if (!bodyInUrl && body.isNotEmpty) 'Paste the text into the body (it is on the clipboard).',
      if (variant.hasMedia) 'Upload your image with the image button next to the URL field.',
      'Check everything and press **Create**.',
    ];
    return HandoffPlan(
      platformId: id,
      webIntent: webIntent,
      clipboardText: body.isEmpty ? title : body,
      shareText: full,
      shareFiles: variant.media,
      androidPackage: 'com.jerboa',
      desktopUrl: webIntent.toString(),
      preferred: variant.hasMedia ? HandoffMethod.shareSheet : HandoffMethod.webIntent,
      instructions: [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n'),
      mediaNote: variant.hasMedia
          ? 'Lemmy\'s Create post page cannot receive files. Upload the image on the page, or share it to a Lemmy app '
              'such as Jerboa; your text is on the clipboard.'
          : null,
    );
  }

  int? _handoffCommunityId(PostVariant v, ConnectedAccount account) {
    final explicit = v.extra['communityId'];
    if (explicit is num) return explicit.toInt();
    final override = _str(v.extra['community']);
    final cid = account.config['communityId'];
    if (cid is! num) return null;
    if (override == null) return cid.toInt();
    final host = account.configString('host');
    final same = normalizeLemmyCommunity(override, homeHost: host) == account.config['community'];
    return same ? cid.toInt() : null;
  }
}

String? _jwt(Map<String, String> secrets) {
  final t = OAuthTokens.fromSecrets(secrets)?.accessToken ?? secrets['jwt'];
  return t == null || t.isEmpty ? null : t;
}

Map<String, dynamic>? _person(Map<String, dynamic> site) {
  final my = site['my_user'];
  final luv = my is Map ? my['local_user_view'] : null;
  final p = luv is Map ? luv['person'] : null;
  return p is Map ? Map<String, dynamic>.from(p) : null;
}

/// Language code -> Lemmy language id, limited to the instance's discussion
/// languages when it lists any. Id 0 ("undetermined") is skipped.
Map<String, int> _languages(Map<String, dynamic> site) {
  final all = site['all_languages'];
  if (all is! List) return const {};
  final allowedRaw = site['discussion_languages'];
  final allowed = allowedRaw is List ? allowedRaw.whereType<num>().map((n) => n.toInt()).toSet() : <int>{};
  final out = <String, int>{};
  for (final l in all) {
    if (l is! Map) continue;
    final id = l['id'];
    final code = l['code'];
    if (id is! num || code is! String || id.toInt() == 0 || code == 'und') continue;
    if (allowed.isNotEmpty && !allowed.contains(id.toInt())) continue;
    out[code.toLowerCase()] = id.toInt();
  }
  return out;
}

String _cleanTitle(String t) => t.replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ').trim();

String _mdAlt(String s) => s.replaceAll(RegExp(r'[\[\]\r\n]'), ' ').trim();

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

String? _clip(String? s, int max) {
  if (s == null || s.isEmpty) return null;
  if (s.length <= max) return s;
  // Do not cut a surrogate pair in half.
  final end = (s.codeUnitAt(max - 1) & 0xFC00) == 0xD800 ? max - 1 : max;
  return s.substring(0, end);
}

String _ext(String mime) {
  final sub = mime.split('/').last;
  return switch (sub) {
    'jpeg' => 'jpg',
    _ => sub,
  };
}
