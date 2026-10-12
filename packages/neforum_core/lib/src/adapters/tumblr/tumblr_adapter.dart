import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../auth/auth_broker.dart';
import '../../auth/oauth2_pkce.dart';
import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../media_hosts/media_host.dart';
import '../../model/account.dart';
import '../../model/media.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../../text/rules_validator.dart';
import '../../text/url_detector.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'tumblr_api.dart';

/// Tumblr: posts Neue Post Format (NPF) posts to one of the user's blogs
/// through their own registered Tumblr app (OAuth 2, consumer key + secret),
/// or hands the post to Tumblr's share tool / app.
class TumblrAdapter extends PlatformAdapter {
  TumblrAdapter();

  // Config keys (non-secret).
  static const cfgConsumerKey = 'consumerKey';
  static const cfgBlogName = 'blogName';
  static const cfgBlogUuid = 'blogUuid';
  static const cfgBlogUrl = 'blogUrl';
  static const cfgUserName = 'userName';
  static const cfgBlogNames = 'blogNames';
  static const cfgRedirectUri = 'redirectUri';

  // Secret keys (besides OAuthTokens' own).
  static const secretConsumerSecret = 'consumer_secret';

  /// Animated GIFs: 10 MB (Help Center "Image and GIF troubleshooting").
  static const int gifMaxBytes = 10 * 1024 * 1024;

  static const PlatformDescriptor tumblrDescriptor = PlatformDescriptor(
    id: 'tumblr',
    name: 'Tumblr',
    iconKey: 'tumblr',
    homepage: 'https://www.tumblr.com',
    tiers: {PlatformTier.byokApi, PlatformTier.handoff},
    defaultTier: PlatformTier.byokApi,
    text: TextRules(
      maxLength: 524288,
      counting: CountingRule.utf16,
      titleSupported: true,
      titleRequired: false,
      titleMax: TumblrApi.maxTextBlockCodePoints,
      supportsThreads: false,
      supportsContentWarning: false,
      supportsMarkdown: false,
      supportsHtml: false,
      supportsHashtags: true,
      hashtagsAsField: true,
      maxHashtags: 30,
      linkInText: false,
      notes: 'A post can hold up to 524,288 characters; NEFORUM turns every line into its own Tumblr text block '
          '(max 4,096 characters each, longer lines are split). Tumblr counts Unicode code points; NEFORUM counts '
          'UTF-16 units, which is never less. The title becomes a big heading. Tags go into Tumblr\'s tag field '
          '(commas are not allowed inside a tag); the link becomes a link card and the post\'s source. No threads '
          'and no content warnings (Tumblr community labels must be set on tumblr.com).',
    ),
    media: MediaRules(
      maxImages: 30,
      maxVideos: 1,
      allowsMixedImageVideo: true,
      imageMaxBytes: 20 * 1024 * 1024,
      videoMaxBytes: 500 * 1000 * 1000,
      videoMaxSeconds: 10 * 60,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/webp', 'image/gif'},
      videoMimeTypes: {'video/mp4', 'video/quicktime'},
      supportsAltText: true,
      requiresPublicMediaUrl: false,
      notes: 'Up to 30 images (JPEG, PNG, WEBP up to 20 MB, RGB only; GIF up to 10 MB) and one uploaded MP4/MOV '
          'video (up to 500 MB and 10 minutes) per post. Per user per day: 250 images, 20 videos, 60 minutes of '
          'video. Only one video can be processing at a time.',
    ),
    defaultQuotas: [
      QuotaRule(
        id: 'tumblr.posts_per_day',
        limit: 250,
        window: Duration(days: 1),
        note: 'New published posts (including reblogs) per Tumblr user per calendar day, across all apps',
      ),
    ],
    personalAccountOk: true,
    accountRequirements: 'Any normal Tumblr account works. For automatic posting you register your own free Tumblr '
        'app at tumblr.com/oauth/apps, which takes a minute and needs no review.',
    apiCostSummary: 'Free. Tumblr allows 250 posts a day per user, and your own app gets 1,000 API calls an hour '
        'and 5,000 a day, far more than NEFORUM needs.',
    setupGuide: 'docs/platforms/tumblr.md',
    serverSideScheduling: true,
    supportsLinkField: true,
  );

  @override
  PlatformDescriptor get descriptor => tumblrDescriptor;

  // ------------------------------------------------------------- connect

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.byokApi,
          usesBrowser: true,
          loopbackRedirectOk: true,
          customSchemeRedirectOk: true,
          redirectNote: 'Under "OAuth2 redirect URLs" register `http://127.0.0.1:52771/callback` (computer) and '
              '`neforum://callback/` (phone, with the trailing slash), separated by a space.',
          intro: _byokIntro,
          fields: [
            ConnectField(
              key: 'consumerKey',
              label: 'OAuth Consumer Key',
              help: 'tumblr.com/oauth/apps > your app > "OAuth Consumer Key".',
              placeholder: 'abc123...',
            ),
            ConnectField(
              key: 'consumerSecret',
              label: 'Secret Key',
              kind: FieldKind.password,
              secret: true,
              help: 'Same page, click "Show secret key" and copy it. It stays on this device.',
            ),
            ConnectField(
              key: 'blog',
              label: 'Blog name',
              required: false,
              placeholder: 'myblog',
              help: 'Which of your blogs to post to (the part before .tumblr.com). Leave empty for your main blog.',
            ),
            ConnectField(
              key: 'redirectUri',
              label: 'Redirect URI (advanced)',
              kind: FieldKind.url,
              required: false,
              placeholder: 'http://localhost:52771/callback',
              help: 'Only if Tumblr refused the standard redirect URL when you registered the app: enter the one '
                  'you registered instead (on a computer it must use port 52771 and the path /callback).',
            ),
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.handoff,
          intro: 'No setup needed. NEFORUM opens Tumblr\'s post composer with your text, title and tags filled in '
              '(sign in if asked) and you click **Post** yourself. Photos and videos go through the share sheet '
              'on phones. On a computer you drag them into a new Tumblr post, or, with a media host set up in '
              'Settings, NEFORUM fills in the photos too.',
          fields: [
            ConnectField(key: 'displayName', label: 'Name to show in NEFORUM', required: false, placeholder: 'My Tumblr'),
          ],
        ),
      ];

  static const String _byokIntro = '''
**Post to your Tumblr blog automatically.** You need your own (free, instant) Tumblr app:

1. Sign in to Tumblr in your browser, open <https://www.tumblr.com/oauth/apps> and click **Register application**.
2. Fill in an application name (e.g. "NEFORUM for <your name>"), a website (for example `https://github.com/neforum-app/neforum`), a short description and your e-mail address.
3. As **Default callback URL** enter `http://127.0.0.1:52771/callback`.
4. As **OAuth2 redirect URLs** enter `http://127.0.0.1:52771/callback neforum://callback/` (two addresses separated by a space; keep the slash at the end of the second one). Save.
5. Copy the **OAuth Consumer Key** and, after clicking **Show secret key**, the **Secret Key** into the fields below. Click Connect and allow access in the browser.

If Tumblr says "The url's domain is not valid" for the 127.0.0.1 address, register `http://localhost:52771/callback` instead and type that into "Redirect URI" below.''';

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier == PlatformTier.handoff) {
      final name = (input['displayName'] ?? '').trim();
      return ConnectResult(
        account: ConnectedAccount(
          id: 'tumblr:handoff:${const Uuid().v4()}',
          platformId: id,
          tier: PlatformTier.handoff,
          displayName: name.isEmpty ? 'Tumblr (hand-off)' : name,
          createdAt: ctx.now(),
        ),
      );
    }
    if (tier != PlatformTier.byokApi) throw ConnectException('Tumblr does not support the ${tier.label} tier');

    final key = (input['consumerKey'] ?? '').trim();
    final secret = (input['consumerSecret'] ?? '').trim();
    if (key.isEmpty) throw const ConnectException('Enter the OAuth Consumer Key of your Tumblr app', field: 'consumerKey');
    if (secret.isEmpty) throw const ConnectException('Enter the Secret Key of your Tumblr app', field: 'consumerSecret');

    final AuthBroker broker;
    try {
      broker = ctx.requireBroker();
    } on StateError {
      throw const ConnectException('Connecting Tumblr needs a browser sign-in, which is not available here');
    }
    final redirect = _redirectUri(broker, (input['redirectUri'] ?? '').trim());
    final client = _oauthClient(key, secret);

    final OAuthTokens tokens;
    try {
      final request = client.buildAuthorizationUrl(redirectUri: redirect);
      final back = await broker.authorize(request.url, redirect);
      final code = client.extractCode(back, request);
      tokens = await client.exchangeCode(ctx.http, code: code, redirectUri: redirect, now: ctx.now());
    } on OAuthException catch (e) {
      throw ConnectException(_oauthMessage(e, redirect));
    }

    final Map<String, dynamic> user;
    try {
      final res = await ctx.http.get(TumblrApi.userInfoEndpoint, headers: _bearer(tokens.accessToken));
      final response = res.jsonMap['response'];
      final u = response is Map ? response['user'] : null;
      user = u is Map ? Map<String, dynamic>.from(u) : const {};
    } on HttpFailure catch (e) {
      throw ConnectException('Signed in, but Tumblr refused to list your blogs (HTTP ${e.statusCode}). Try again.');
    }
    final blogs = _blogs(user);
    if (blogs.isEmpty) throw const ConnectException('Your Tumblr account has no blogs to post to');
    final blog = _pickBlog(blogs, input['blog'] ?? '');

    final userName = user['name'] as String? ?? '';
    final title = blog.title.trim();
    return ConnectResult(
      account: ConnectedAccount(
        id: 'tumblr:${blog.uuid.isNotEmpty ? blog.uuid : blog.name}',
        platformId: id,
        tier: PlatformTier.byokApi,
        displayName: title.isEmpty || title == blog.name ? blog.name : '$title (${blog.name})',
        handle: blog.name,
        avatarUrl: TumblrApi.avatarUrl(blog.name),
        profileUrl: blog.url.isNotEmpty ? blog.url : 'https://${blog.name}.tumblr.com/',
        createdAt: ctx.now(),
        config: {
          cfgConsumerKey: key,
          cfgBlogName: blog.name,
          if (blog.uuid.isNotEmpty) cfgBlogUuid: blog.uuid,
          if (blog.url.isNotEmpty) cfgBlogUrl: blog.url,
          if (userName.isNotEmpty) cfgUserName: userName,
          cfgBlogNames: [for (final b in blogs) b.name],
          cfgRedirectUri: redirect.toString(),
        },
      ),
      secrets: tokens.toSecrets({secretConsumerSecret: secret}),
    );
  }

  /// The broker's redirect, a user override, and the trailing slash Tumblr
  /// insists on for custom-scheme redirects (tumblr/docs #122).
  Uri _redirectUri(AuthBroker broker, String override) {
    if (override.isNotEmpty) {
      final u = Uri.tryParse(override);
      if (u == null || !u.hasScheme) {
        throw const ConnectException('The redirect URI must be a full address such as http://localhost:52771/callback',
            field: 'redirectUri');
      }
      return u;
    }
    final spec = specFor(PlatformTier.byokApi);
    final chosen = broker.chooseRedirectUri(
      loopbackOk: spec.loopbackRedirectOk,
      customSchemeOk: spec.customSchemeRedirectOk,
      fixed: spec.fixedRedirectUri,
    );
    if (chosen.scheme != 'http' && chosen.scheme != 'https' && chosen.path.isEmpty) return chosen.replace(path: '/');
    return chosen;
  }

  static OAuth2Client _oauthClient(String key, String secret) => OAuth2Client(
        authorizationEndpoint: TumblrApi.authorizationEndpoint,
        tokenEndpoint: TumblrApi.tokenEndpoint,
        clientId: key,
        clientSecret: secret,
        scopes: TumblrApi.scopes,
        // Tumblr has no PKCE; client_id + client_secret go in the form body
        // of both token calls.
        usePkce: false,
        clientAuth: ClientAuth.body,
      );

  static String _oauthMessage(OAuthException e, Uri redirect) {
    final d = '${e.error ?? ''} ${e.description ?? ''}'.toLowerCase();
    if (d.contains('redirect')) {
      return 'Tumblr rejected the redirect URL. Add exactly $redirect to "OAuth2 redirect URLs" in your app at '
          'tumblr.com/oauth/apps and try again.';
    }
    if (d.contains('access_denied')) return 'You did not allow NEFORUM to access Tumblr.';
    if (d.contains('client') || d.contains('secret')) {
      return 'Tumblr did not accept the Consumer Key / Secret Key. Copy both again from tumblr.com/oauth/apps.';
    }
    final detail = [e.error, e.description].whereType<String>().where((s) => s.isNotEmpty).join(': ');
    return 'Tumblr sign-in failed${detail.isEmpty ? '' : ' ($detail)'}';
  }

  static List<_Blog> _blogs(Map<String, dynamic> user) {
    final raw = user['blogs'];
    if (raw is! List) return const [];
    final out = <_Blog>[];
    for (final b in raw) {
      if (b is! Map) continue;
      final name = b['name'];
      if (name is! String || name.isEmpty) continue;
      out.add(_Blog(
        name: name,
        uuid: b['uuid'] as String? ?? '',
        url: b['url'] as String? ?? '',
        title: b['title'] as String? ?? '',
        primary: b['primary'] == true,
      ));
    }
    return out;
  }

  static _Blog _pickBlog(List<_Blog> blogs, String wanted) {
    final w = normalizeBlogName(wanted);
    if (w.isEmpty) return blogs.firstWhere((b) => b.primary, orElse: () => blogs.first);
    for (final b in blogs) {
      if (b.name.toLowerCase() == w || b.uuid.toLowerCase() == w) return b;
    }
    throw ConnectException(
      'You have no blog called "$wanted". Your blogs: ${blogs.map((b) => b.name).join(', ')}',
      field: 'blog',
    );
  }

  /// `@Name`, `name.tumblr.com`, `https://www.tumblr.com/name` -> `name`.
  static String normalizeBlogName(String input) {
    var s = input.trim().toLowerCase();
    s = s.replaceFirst(RegExp(r'^https?://'), '').replaceFirst(RegExp(r'^www\.tumblr\.com/'), '');
    s = s.replaceFirst(RegExp(r'^@'), '').replaceFirst(RegExp(r'/.*$'), '').replaceFirst(RegExp(r'\.tumblr\.com$'), '');
    return s;
  }

  static Map<String, String> _bearer(String token) => {'Authorization': 'Bearer $token'};

  // ------------------------------------------------------------- refresh

  @override
  Future<Map<String, String>?> refreshSecrets(
      ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.byokApi) return null;
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) throw const AdapterException(PublishError.auth(_reconnectMessage));
    if (!tokens.isExpired(now: ctx.now())) return null;

    final refresh = tokens.refreshToken;
    final secret = secrets[secretConsumerSecret];
    final key = account.configString(cfgConsumerKey);
    if (refresh == null || refresh.isEmpty || secret == null || secret.isEmpty || key.isEmpty) {
      throw const AdapterException(PublishError.auth(_expiredMessage));
    }
    try {
      // Every refresh returns a NEW refresh token; toSecrets stores both.
      final fresh = await _oauthClient(key, secret).refresh(ctx.http, refreshToken: refresh, now: ctx.now());
      return fresh.toSecrets(secrets);
    } on OAuthException catch (e) {
      // 401 = refresh token expired (api.md), 429 = rate limited, 5xx = outage.
      throw AdapterException(e.toRefreshError('Tumblr'));
    } on Object catch (e) {
      if (NeforumHttp.isTransportError(e)) {
        throw AdapterException(PublishError.network('Could not reach Tumblr to renew the sign-in: $e'));
      }
      rethrow;
    }
  }

  static const String _expiredMessage =
      'Your Tumblr sign-in has expired (unused for 42 days or revoked). Reconnect Tumblr in Accounts.';
  static const String _reconnectMessage = 'Tumblr is not signed in. Reconnect Tumblr in Accounts.';

  // ------------------------------------------------------------ validate

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = RulesValidator.validate(variant, descriptor, tier: account.tier);

    if (account.tier == PlatformTier.byokApi && account.configString(cfgBlogName).isEmpty) {
      issues.add(const ValidationIssue.error(
          'account.no_blog', 'This Tumblr account has no blog selected; reconnect it', field: 'account'));
    }

    for (final m in variant.media) {
      if (m.kind == MediaKind.gif && m.sizeBytes > gifMaxBytes) {
        issues.add(ValidationIssue.error(
            'media.gif_too_large', '${m.fileName ?? m.id} is larger than Tumblr\'s 10 MB limit for GIFs', field: 'media'));
      }
      if ((m.altText ?? '').runes.length > TumblrApi.maxAltText) {
        issues.add(const ValidationIssue.error(
            'media.alt_too_long', 'Alt text is longer than Tumblr\'s 4,096 characters', field: 'media'));
      }
    }

    final text = bodyText(variant);
    final blocks = TumblrApi.countTextBlocks(text) + ((variant.title ?? '').trim().isEmpty ? 0 : 1);
    if (blocks + variant.media.length + 1 > TumblrApi.maxBlocks) {
      issues.add(const ValidationIssue.error(
          'text.too_many_blocks', 'Tumblr posts can have at most 1,000 paragraphs and media items', field: 'text'));
    }
    if (TumblrApi.countLinks(text) > TumblrApi.maxInlineLinks) {
      issues.add(const ValidationIssue.warning(
          'text.too_many_links', 'Tumblr links at most 100 URLs per post; the rest stay plain text', field: 'text'));
    }
    if (variant.tags.any((t) => t.contains(','))) {
      issues.add(const ValidationIssue.warning(
          'tags.comma', 'Tumblr tags cannot contain commas; they will be replaced by spaces', field: 'tags'));
    }

    final rawType = variant.extra['tumblrPostType'];
    if (rawType != null && '$rawType'.trim().isNotEmpty && postType(variant) == null) {
      issues.add(ValidationIssue.error('tumblr.post_type',
          'Unknown Tumblr post type "$rawType"; choose quote, chat or audio (or leave it automatic)', field: 'extra'));
    }
    switch (postType(variant)) {
      case 'quote' when bodyText(variant).trim().isEmpty:
        issues.add(const ValidationIssue.error('tumblr.quote_empty', 'A Tumblr quote post needs the quote as its text', field: 'text'));
      case 'chat' when bodyText(variant).trim().isEmpty:
        issues.add(const ValidationIssue.error('tumblr.chat_empty',
            'A Tumblr chat post needs its lines as the text ("Alex: hi", one per line)', field: 'text'));
      case 'audio' when audioUrl(variant) == null:
        issues.add(const ValidationIssue.error('tumblr.audio_url',
            'A Tumblr audio post needs a link to the track (SoundCloud, Spotify, Bandcamp...) in the Link field or the text',
            field: 'link'));
    }

    final rawState = variant.extra['state'];
    if (rawState != null && _stateValue(rawState) == null) {
      issues.add(ValidationIssue.error('tumblr.state',
          'Unknown Tumblr post state "$rawState"; use published, queue, draft or private', field: 'extra'));
    }
    if (account.tier == PlatformTier.byokApi) _checkSchedule(variant, DateTime.now(), issues);

    if (variant.visibility == Visibility.unlisted || variant.visibility == Visibility.followers) {
      issues.add(const ValidationIssue.warning('visibility.public',
          'Tumblr has no unlisted or followers-only posts; this will be public (choose private to hide it)',
          field: 'visibility'));
    }
    if (variant.sensitive) {
      issues.add(const ValidationIssue.info('tumblr.community_label',
          'Tumblr content labels cannot be set through the API; add them on tumblr.com after posting',
          field: 'sensitive'));
    }
    if (account.tier == PlatformTier.handoff && variant.hasMedia) {
      issues.add(const ValidationIssue.info('handoff.media',
          'Tumblr\'s website cannot receive files from NEFORUM: phones use the share sheet, on a computer you drag '
              'the files into the post (with a media host set up in Settings, photos are filled in for you)',
          field: 'media'));
    }
    return issues;
  }

  /// Errors on `scheduledAt` make the publish service keep the schedule on
  /// this device instead of handing it to Tumblr. Only a schedule that is
  /// still ahead is checked: once it is due the post is published normally.
  static void _checkSchedule(PostVariant v, DateTime now, List<ValidationIssue> issues) {
    final at = v.scheduledAt;
    if (at == null || !at.isAfter(now)) return;
    final state = _effectiveState(v);
    if (state == 'draft' || state == 'private') {
      // publish_on "will be ignored unless the state parameter is queue".
      issues.add(ValidationIssue.error('schedule.state',
          'Tumblr can only hold queued posts, not ${state == 'draft' ? 'drafts' : 'private posts'}; '
              'NEFORUM keeps this schedule itself',
          field: 'scheduledAt'));
      return;
    }
    final bytes = v.media.fold<int>(0, (s, m) => s + m.sizeBytes);
    final lead = TumblrApi.scheduleLead(bytes);
    if (at.isBefore(now.add(lead))) {
      issues.add(ValidationIssue.error('schedule.too_soon',
          'Tumblr needs the post at least ${lead.inMinutes} minutes before its publishing time; '
              'NEFORUM keeps this schedule itself',
          field: 'scheduledAt'));
    }
  }

  /// The state the post is created with, before scheduling turns it into
  /// `queue`.
  static String _effectiveState(PostVariant v) =>
      _stateValue(v.extra['state']) ?? (v.visibility == Visibility.private ? 'private' : 'published');

  static String? _stateValue(Object? raw) {
    if (raw is! String) return null;
    final s = raw.trim().toLowerCase();
    if (s == 'queued') return 'queue';
    if (s == 'publish') return 'published';
    return TumblrApi.states.contains(s) ? s : null;
  }

  /// The body text; thread parts (never produced for Tumblr, which has no
  /// length problem) are joined back together.
  static String bodyText(PostVariant v) => v.isThread ? v.threadParts.join('\n\n') : v.text;

  // ------------------------------------------------------------- publish

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    try {
      return await _publish(variant, account, secrets, ctx);
    } on AdapterException catch (e) {
      return PublishResult.failure(e.error);
    } on HttpFailure catch (e) {
      return PublishResult.failure(TumblrApi.mapFailure(e, 'Posting to Tumblr'));
    } on Object catch (e) {
      if (NeforumHttp.isTransportError(e)) return PublishResult.failure(PublishError.network('Could not reach Tumblr: $e'));
      if (e is FormatException) {
        return PublishResult.failure(PublishError.platform('Tumblr sent a response NEFORUM did not understand: $e'));
      }
      rethrow;
    }
  }

  Future<PublishResult> _publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier == PlatformTier.handoff) {
      return PublishResult.failure(
          const PublishError.unsupported('Hand-off Tumblr accounts are posted through the composer or share sheet'));
    }
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) return PublishResult.failure(const PublishError.auth(_reconnectMessage));
    if (tokens.isExpired(now: ctx.now(), leeway: Duration.zero)) {
      return PublishResult.failure(const PublishError.auth(_expiredMessage));
    }
    final blogName = account.configString(cfgBlogName);
    final blogId = account.configString(cfgBlogUuid, blogName);
    if (blogId.isEmpty) {
      return PublishResult.failure(const PublishError.configuration('No Tumblr blog selected; reconnect Tumblr'));
    }
    final rawState = variant.extra['state'];
    if (rawState != null && _stateValue(rawState) == null) {
      return PublishResult.failure(
          PublishError.validation('Unknown Tumblr post state "$rawState"; use published, queue, draft or private'));
    }

    final uploads = <TumblrUpload>[];
    final mediaBlocks = <Map<String, Object?>>[];
    for (var i = 0; i < variant.media.length; i++) {
      final m = variant.media[i];
      ctx.progress('Preparing ${m.isVideo ? 'video' : 'image'} ${i + 1} of ${variant.media.length}');
      final identifier = 'media$i';
      final Uint8List bytes;
      try {
        bytes = await ctx.readMedia(m);
      } on Exception catch (e) {
        return PublishResult.failure(PublishError.configuration(
            'Could not read ${m.fileName ?? m.path}; re-attach it and try again ($e)'));
      }
      uploads.add(TumblrUpload(
        identifier: identifier,
        bytes: bytes,
        fileName: m.fileName ?? '$identifier${_extension(m.mimeType)}',
        contentType: m.mimeType,
      ));
      mediaBlocks.add(m.isVideo ? TumblrApi.videoBlock(m, identifier) : TumblrApi.imageBlock(m, identifier));
    }

    final schedule = _schedule(variant, ctx.now());
    final body = <String, Object?>{
      'content': buildContent(variant, mediaBlocks),
      'state': schedule.state,
      if (schedule.publishOn != null) 'publish_on': schedule.publishOn!.toUtc().toIso8601String(),
      if (TumblrApi.tagsField(variant.tags) case final tags?) 'tags': tags,
      if (_sourceUrl(variant) case final source?) 'source_url': source,
    };

    final url = TumblrApi.postsEndpoint(blogId);
    final headers = {..._bearer(tokens.accessToken), 'Accept': 'application/json'};
    final NeforumResponse res;
    if (uploads.isEmpty) {
      ctx.progress('Publishing to Tumblr');
      res = await ctx.http.postJson(url, body, headers: headers);
    } else {
      ctx.progress('Uploading ${uploads.length} file${uploads.length == 1 ? '' : 's'} to Tumblr');
      final mp = TumblrApi.multipart(body, uploads);
      res = await ctx.http.putBytes(url, mp.body,
          method: 'POST', headers: {...headers, 'Content-Type': mp.contentType});
    }

    final postId = TumblrApi.createdId(res);
    if (postId == null) {
      return PublishResult.failure(PublishError.platform(
          'Tumblr accepted the post but did not return its id (HTTP ${res.statusCode})',
          raw: res.body, statusCode: res.statusCode));
    }
    final name = blogName.isNotEmpty ? blogName : account.handle ?? '';
    final publishOn = schedule.publishOn;
    if (publishOn != null) {
      // Tumblr holds the post. Its id changes when it is published (the old
      // one becomes the "genesis" id, which cannot look the post up), so link
      // the blog rather than a permalink that will stop working. The blog
      // identifier needed to delete it again is in the account config.
      return PublishResult.scheduled(
        remoteId: postId,
        scheduledFor: publishOn,
        remoteUrl: name.isNotEmpty ? TumblrApi.blogUrl(name) : account.profileUrl,
      );
    }
    final visible = schedule.state == 'published' || schedule.state == 'private';
    return PublishResult.ok(
      remoteId: postId,
      remoteUrl: visible && name.isNotEmpty ? TumblrApi.postUrl(name, postId) : null,
      publishedAt: visible ? ctx.now() : null,
    );
  }

  /// Post types chosen per post (`extra['tumblrPostType']`) beyond the ones
  /// NEFORUM picks by itself (text, photo, video, link).
  static const List<String> extraPostTypes = ['quote', 'chat', 'audio'];

  /// `quote`, `chat` or `audio` when the user chose one, else null.
  static String? postType(PostVariant v) {
    final t = v.extraAs<String>('tumblrPostType')?.trim().toLowerCase();
    return extraPostTypes.contains(t) ? t : null;
  }

  /// Who said it, for a quote post: `extra['tumblrQuoteSource']`, else the
  /// title.
  static String? quoteSource(PostVariant v) {
    final s = (v.extraAs<String>('tumblrQuoteSource') ?? v.title)?.trim();
    return s == null || s.isEmpty ? null : s;
  }

  /// The track of an audio post: the post's link, else the first URL in the
  /// text.
  static String? audioUrl(PostVariant v) {
    final link = _link(v);
    if (link != null) return link;
    final found = UrlDetector.find(bodyText(v));
    return found.isEmpty ? null : found.first.normalized;
  }

  /// [text] without [url] (an audio post's track is its player, not text).
  static String _withoutUrl(String text, String url) {
    var out = text.replaceAll(url, '');
    for (final u in UrlDetector.find(text).where((u) => u.normalized == url)) {
      out = out.replaceAll(u.text, '');
    }
    return out.replaceAll(RegExp(r'[ \t]+\n'), '\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// NPF content: title heading, media, text paragraphs, link card. Quote
  /// posts: the words as a quote, then "— source". Chat posts: a title, then
  /// one chat line per line ("Alex: hi"). Audio posts: the track's player,
  /// then the rest of the text.
  static List<Map<String, Object?>> buildContent(PostVariant v, List<Map<String, Object?>> mediaBlocks) {
    final budget = LinkBudget();
    final text = bodyText(v);
    final title = v.title?.trim();
    final link = _link(v);
    switch (postType(v)) {
      case 'quote':
        final source = quoteSource(v);
        return [
          ...mediaBlocks,
          ...TumblrApi.textBlocks(text, linkBudget: budget, subtype: 'quote'),
          if (source != null) TumblrApi.textBlock('— $source', linkBudget: budget),
          if (link != null && !_textHasLink(text, link)) TumblrApi.linkBlock(link),
        ];
      case 'chat':
        return [
          if (title != null && title.isNotEmpty) TumblrApi.textBlock(title, subtype: 'heading1'),
          for (final line in const LineSplitter().convert(text))
            if (line.trim().isNotEmpty) TumblrApi.chatBlock(line),
          ...mediaBlocks,
          if (link != null && !_textHasLink(text, link)) TumblrApi.linkBlock(link),
        ];
      case 'audio':
        final track = audioUrl(v);
        return [
          if (title != null && title.isNotEmpty) TumblrApi.textBlock(title, subtype: 'heading1'),
          if (track != null) TumblrApi.audioBlock(track),
          ...mediaBlocks,
          ...TumblrApi.textBlocks(track == null ? text : _withoutUrl(text, track), linkBudget: budget),
        ];
    }
    return [
      if (title != null && title.isNotEmpty) TumblrApi.textBlock(title, subtype: 'heading1'),
      ...mediaBlocks,
      ...TumblrApi.textBlocks(text, linkBudget: budget),
      if (link != null && !_textHasLink(text, link))
        TumblrApi.linkBlock(link,
            title: v.extraAs<String>('linkTitle')?.trim(), description: v.extraAs<String>('linkDescription')?.trim()),
    ];
  }

  static String? _link(PostVariant v) {
    final l = v.link?.trim();
    return l == null || l.isEmpty ? null : l;
  }

  static String? _sourceUrl(PostVariant v) {
    final explicit = v.extraAs<String>('tumblrSourceUrl')?.trim();
    if (explicit != null) return explicit.isEmpty ? null : explicit;
    return _link(v);
  }

  static bool _textHasLink(String text, String link) {
    if (text.contains(link)) return true;
    final normalized = Uri.tryParse(link)?.toString();
    return UrlDetector.find(text).any((u) => u.text == link || u.normalized == normalized);
  }

  static ({String state, DateTime? publishOn}) _schedule(PostVariant v, DateTime now) {
    final state = _effectiveState(v);
    final at = v.scheduledAt;
    if (at != null && at.isAfter(now) && (state == 'published' || state == 'queue')) {
      // publish_on is only honoured for state=queue.
      return (state: 'queue', publishOn: at);
    }
    return (state: state, publishOn: null);
  }

  static String _extension(String mime) => switch (mime) {
        'image/jpeg' => '.jpg',
        'image/png' => '.png',
        'image/gif' => '.gif',
        'image/webp' => '.webp',
        'video/mp4' => '.mp4',
        'video/quicktime' => '.mov',
        _ => '',
      };

  // ------------------------------------------------- cancel scheduled post

  /// A 404 this close to the publishing time may mean Tumblr has already
  /// published the post (which gives it a new id), not that it is gone.
  static const Duration _publishRace = Duration(minutes: 5);

  /// Deletes a post Tumblr holds in the blog's queue:
  /// `POST /v2/blog/{blog-identifier}/post/delete` with `id`.
  @override
  Future<void> cancelScheduled(
      PublishResult held, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.byokApi) {
      throw const AdapterException(PublishError.unsupported('Hand-off Tumblr accounts have no scheduled posts to remove'));
    }
    final postId = (held.remoteId ?? '').trim();
    if (postId.isEmpty) {
      throw const AdapterException(PublishError.configuration(
          'NEFORUM does not know which Tumblr post holds this schedule; delete it from your blog\'s queue on tumblr.com'));
    }
    final blogId = account.configString(cfgBlogUuid, account.configString(cfgBlogName));
    if (blogId.isEmpty) {
      throw const AdapterException(PublishError.configuration('No Tumblr blog selected; reconnect Tumblr'));
    }
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) throw const AdapterException(PublishError.auth(_reconnectMessage));
    if (tokens.isExpired(now: ctx.now(), leeway: Duration.zero)) {
      throw const AdapterException(PublishError.auth(_expiredMessage));
    }
    try {
      await ctx.http.postForm(
        TumblrApi.deleteEndpoint(blogId),
        {'id': postId},
        headers: {..._bearer(tokens.accessToken), 'Accept': 'application/json'},
      );
    } on HttpFailure catch (e) {
      if (e.statusCode != 404) throw AdapterException(TumblrApi.mapFailure(e, 'Removing the scheduled Tumblr post'));
      final due = held.scheduledFor;
      if (due != null && ctx.now().isAfter(due.subtract(_publishRace))) {
        throw AdapterException(PublishError.platform(
            'Tumblr no longer has the scheduled post under its original id. It was due at ${due.toUtc().toIso8601String()}, '
            'so it may already be live; check your blog before posting it again.',
            raw: e.body,
            statusCode: 404));
      }
      ctx.log.info('Tumblr post $postId was already gone from the queue');
    } on Object catch (e) {
      if (NeforumHttp.isTransportError(e)) {
        throw AdapterException(PublishError.network('Could not reach Tumblr to remove the scheduled post: $e'));
      }
      rethrow;
    }
  }

  // ------------------------------------------------------------- hand-off

  /// Tumblr's official share tool (help.tumblr.com "Share button
  /// documentation"): `posttype` text|photo|link|quote|chat|video, `content`
  /// (for photo posts one photo URL or a comma-separated list for a photoset),
  /// `title` (text, link, chat), `caption` (photo, link, video, quote),
  /// `tags` (comma-separated) and `canonicalUrl`.
  static const String shareToolPath = '/widgets/share/tool';

  /// Tumblr's full web composer for a new post of each kind. No URL can
  /// prefill it, but the NEFORUM browser extension fills it in, files
  /// included, which the share tool cannot take.
  static const String newTextUrl = 'https://www.tumblr.com/new/text';
  static const String newPhotoUrl = 'https://www.tumblr.com/new/photo';
  static const String newVideoUrl = 'https://www.tumblr.com/new/video';
  static const String newLinkUrl = 'https://www.tumblr.com/new/link';
  static const String newQuoteUrl = 'https://www.tumblr.com/new/quote';
  static const String newChatUrl = 'https://www.tumblr.com/new/chat';
  static const String newAudioUrl = 'https://www.tumblr.com/new/audio';

  /// The full composer for [v]: the post type the user chose (quote, chat,
  /// audio), else a photo post when it has photos, a video post for a video,
  /// a link post for a link without media, else a text post.
  static Uri composerFor(PostVariant v) {
    switch (postType(v)) {
      case 'quote':
        return Uri.parse(newQuoteUrl);
      case 'chat':
        return Uri.parse(newChatUrl);
      case 'audio':
        return Uri.parse(newAudioUrl);
    }
    if (v.media.any((m) => m.isImage)) return Uri.parse(newPhotoUrl);
    if (v.media.isNotEmpty) return Uri.parse(newVideoUrl);
    if (_link(v) != null) return Uri.parse(newLinkUrl);
    return Uri.parse(newTextUrl);
  }

  /// The steps when the browser extension fills in the full composer.
  static String _composerSteps(PostVariant v) {
    final photos = v.media.where((m) => m.isImage).length;
    final composer = composerFor(v).path.split('/').last;
    final hasText = _fullText(v).isNotEmpty;
    final what = [
      if (photos > 0) photos == 1 ? 'your photo' : 'your $photos photos',
      if (photos == 0 && v.media.isNotEmpty) v.media.length == 1 ? 'your video' : 'your videos',
      if (composer == 'link') 'the link',
      if (composer == 'audio') 'the track\'s link',
      if (hasText)
        switch (composer) {
          'text' => 'your text',
          'quote' => 'the quote',
          'chat' => 'the chat lines',
          _ => 'the text',
        },
    ];
    final filled = what.length < 2 ? what.join() : '${what.sublist(0, what.length - 1).join(', ')} and ${what.last}';
    final tags = TumblrApi.tagsField(v.tags) != null;
    return _numbered([
      'Tumblr opens a new $composer post (sign in if asked), and the NEFORUM browser extension adds $filled.',
      if (composer == 'quote' && quoteSource(v) != null)
        'Add the source: click Tumblr\'s source field, then **Insert** next to Quote source in the NEFORUM panel.',
      if (tags) 'Add the tags: click Tumblr\'s tags field, then **Insert** next to Tags in the NEFORUM panel (they are also listed below).',
      if (_hasAltText(v)) 'Add the alt text listed below to ${photos == 1 ? 'the photo' : 'each photo'}.',
      'Check the post, then click **Post now**.',
    ]);
  }

  /// How long hand-off photos stay on the user's media host when the host can
  /// expire files: long enough to finish the post, without leaving copies
  /// around for good.
  static const Duration handoffMediaTtl = Duration(hours: 24);

  static const String _tumblrPackage = 'com.tumblr';

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    if (postType(variant) != null) return _typedHandoff(variant);
    return variant.hasMedia ? _mediaHandoff(variant) : _textHandoff(variant);
  }

  /// With photos and a media host configured, the photos are put on the host
  /// first, because the share tool takes photos only as links. It then opens
  /// a photo post with them, the caption and the tags. Videos are never
  /// uploaded: the share tool's video `content` is a URL or embed code of a
  /// video service (Tumblr's API refuses URLs of unsupported services), not a
  /// file. Without a host nothing is uploaded; on any failure the plain plan
  /// is returned.
  @override
  Future<HandoffPlan?> prepareHandoff(PostVariant variant, ConnectedAccount account, AdapterContext ctx) async {
    final host = ctx.mediaHost;
    final photos = [for (final m in variant.media) if (m.isImage) m];
    // The browser extension puts the files straight into Tumblr's full
    // composer: nothing to put on the host.
    if (host == null || photos.isEmpty || ctx.browserFills || postType(variant) != null) return buildHandoff(variant, account: account);

    final limit = host.maxBytes;
    final tooBig = limit == null ? null : photos.where((m) => m.sizeBytes > limit).firstOrNull;
    if (tooBig != null) {
      final problem = 'The photo ${_mediaLabel(tooBig)} is larger than ${host.name} accepts';
      ctx.log.warn('Tumblr hand-off: $problem; the photos are not filled in');
      return _mediaHandoff(variant, hostProblem: problem);
    }

    final hosted = <HostedMedia>[];
    try {
      for (var i = 0; i < photos.length; i++) {
        ctx.progress('Uploading photo ${i + 1} of ${photos.length} to ${host.name}');
        final bytes = await ctx.readMedia(photos[i]);
        hosted.add(await host.upload(photos[i], bytes, ttl: handoffMediaTtl));
      }
    } on Object catch (e) {
      ctx.log.warn('Tumblr hand-off: could not put the photos on ${host.name}; using the plain hand-off', e);
      await _discardHosted(host, hosted, ctx);
      return _mediaHandoff(variant,
          hostProblem: e is MediaHostException ? e.message : 'The upload to ${host.name} failed');
    }
    return _photoToolHandoff(variant, photos, [for (final h in hosted) h.url], host.name);
  }

  static Future<void> _discardHosted(MediaHost host, List<HostedMedia> hosted, AdapterContext ctx) async {
    for (final h in hosted) {
      try {
        await host.delete(h);
      } on Object catch (e) {
        ctx.log.warn('Could not delete ${h.url} from ${host.name}', e);
      }
    }
  }

  static Uri _shareTool(Map<String, String> params) => Uri.https('www.tumblr.com', shareToolPath, params);

  /// Title, text and (unless the text has it) the link: what goes on the
  /// clipboard and, for photo posts, into the caption (the share tool has no
  /// title for photos).
  static String _fullText(PostVariant v) {
    final text = bodyText(v).trimRight();
    final title = v.title?.trim() ?? '';
    final link = _link(v);
    return [
      if (title.isNotEmpty) title,
      if (text.isNotEmpty) text,
      if (link != null && !_textHasLink(text, link)) link,
    ].join('\n\n');
  }

  /// Values to copy one by one: the tags (comma-separated, as Tumblr's tag
  /// field takes them) and each photo's alt text (no hand-off route carries
  /// alt text).
  static List<HandoffSnippet> _snippets(PostVariant v) {
    final tags = TumblrApi.tagsField(v.tags);
    final photos = [for (final m in v.media) if (m.isImage) m];
    return [
      if (tags != null) HandoffSnippet('Tags', tags),
      for (var i = 0; i < photos.length; i++)
        if ((photos[i].altText ?? '').trim().isNotEmpty)
          HandoffSnippet(photos.length == 1 ? 'Alt text' : 'Alt text, photo ${i + 1}', photos[i].altText!.trim()),
    ];
  }

  static bool _hasAltText(PostVariant v) => v.media.any((m) => m.isImage && (m.altText ?? '').trim().isNotEmpty);

  static String _mediaLabel(MediaAttachment m) => m.fileName ?? m.id;

  static String _numbered(List<String> steps) => [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n');

  HandoffPlan _textHandoff(PostVariant variant) {
    final text = bodyText(variant).trimRight();
    final title = variant.title?.trim() ?? '';
    final link = _link(variant);
    final tags = TumblrApi.tagsField(variant.tags);
    final params = <String, String>{
      if (link != null) ...{
        'posttype': 'link',
        'content': link,
        if (text.isNotEmpty) 'caption': text,
        'canonicalUrl': link,
      } else ...{
        'posttype': 'text',
        'content': text,
      },
      if (title.isNotEmpty) 'title': title,
      if (tags != null) 'tags': tags,
    };
    final clipboard = _fullText(variant);
    return HandoffPlan(
      platformId: id,
      instructions: _numbered([
        'Tumblr opens a new post with your text${tags == null ? '' : ' and tags'} filled in (sign in if asked; '
            'the draft survives the sign-in).',
        'If anything is missing, paste it: the text is on the clipboard${tags == null ? '' : ', the tags are listed below'}.',
        'Click **Post now**.',
      ]),
      webIntent: _shareTool(params),
      clipboardText: clipboard,
      shareText: clipboard,
      androidPackage: _tumblrPackage,
      desktopUrl: newTextUrl,
      preferred: HandoffMethod.webIntent,
      snippets: _snippets(variant),
      composerUrl: composerFor(variant),
      composerInstructions: _composerSteps(variant),
    );
  }

  /// A quote, chat or audio post. Quote and chat posts open the share tool
  /// filled in (a quote with its source as the caption; chat lines with the
  /// title). The share tool has no audio posts: Tumblr's new audio post
  /// opens, and the track's link goes into it.
  HandoffPlan _typedHandoff(PostVariant variant) {
    final type = postType(variant)!;
    final text = bodyText(variant).trimRight();
    final title = variant.title?.trim() ?? '';
    final tags = TumblrApi.tagsField(variant.tags);
    final source = quoteSource(variant);
    final track = audioUrl(variant);
    final intent = switch (type) {
      'quote' => _shareTool({'posttype': 'quote', 'content': text, if (source != null) 'caption': source, if (tags != null) 'tags': tags}),
      'chat' => _shareTool({'posttype': 'chat', 'content': text, if (title.isNotEmpty) 'title': title, if (tags != null) 'tags': tags}),
      _ => null,
    };
    final clipboard = type == 'audio' && track != null ? _withoutUrl(text, track) : text;
    final snippets = [
      if (type == 'quote' && source != null) HandoffSnippet('Quote source', source),
      if (type == 'audio' && track != null) HandoffSnippet('Track link', track),
      ..._snippets(variant),
    ];
    final filled = switch (type) {
      'quote' => 'your quote${source == null ? '' : ' and its source'}',
      _ => 'your chat lines${title.isEmpty ? '' : ' and title'}',
    };
    final steps = intent != null
        ? [
            'Tumblr opens a new $type post with $filled${tags == null ? '' : ' and tags'} filled in (sign in if asked).',
            'If anything is missing, paste it: the text is on the clipboard${snippets.isEmpty ? '' : ', the rest is listed below'}.',
            'Click **Post now**.',
          ]
        : [
            'Tumblr opens a new audio post (sign in if asked).',
            if (track != null) 'Paste the track\'s link (listed below) into it; Tumblr shows the player.',
            if (clipboard.isNotEmpty) 'Then paste your text below it: it is on the clipboard.',
            if (tags != null) 'Add the tags listed below.',
            'Click **Post now**.',
          ];
    return HandoffPlan(
      platformId: id,
      instructions: _numbered(steps),
      webIntent: intent,
      clipboardText: clipboard.isEmpty ? null : clipboard,
      shareText: clipboard.isEmpty ? null : clipboard,
      shareFiles: variant.media,
      androidPackage: _tumblrPackage,
      desktopUrl: composerFor(variant).toString(),
      preferred: intent != null ? HandoffMethod.webIntent : HandoffMethod.manual,
      snippets: snippets,
      composerUrl: composerFor(variant),
      composerInstructions: _composerSteps(variant),
    );
  }

  /// Photos or a video, nothing uploaded: the share sheet hands the files to
  /// the Tumblr app on phones; on a computer Tumblr's new photo (or video)
  /// post opens and the user drags in the files the app's "Save media to
  /// Downloads" button saved. [hostProblem] says why the media host could not
  /// be used.
  HandoffPlan _mediaHandoff(PostVariant variant, {String? hostProblem}) {
    final media = variant.media;
    final photoCount = media.where((m) => m.isImage).length;
    final videoOnly = photoCount == 0;
    final kind = videoOnly ? 'video' : 'photo';
    final files = media.length == 1 ? 'the $kind' : 'the files';
    final clipboard = _fullText(variant);
    final hasText = clipboard.isNotEmpty;
    final hasTags = TumblrApi.tagsField(variant.tags) != null;

    final steps = [
      if (hasText) 'Your text is on the clipboard.',
      'On a phone, share $files to the **Tumblr** app${hasText ? ' and paste the text if the app leaves it out' : ''}.',
      'On a computer, click **Save media to Downloads** (it saves $files with friendly names and opens the folder), '
          'open Tumblr\'s new $kind post and drag $files into it${hasText ? ', then paste the text' : ''}.',
      if (hasTags) 'Add the tags listed below.',
      if (_hasAltText(variant)) 'Add the alt text listed below to ${photoCount == 1 ? 'the photo' : 'each photo'}.',
      'Click **Post now**.',
    ];

    final note = StringBuffer('Tumblr\'s website cannot take files from another app, so NEFORUM cannot attach '
        '$files there. On a phone the share sheet hands them to the Tumblr app. On a computer NEFORUM opens a new '
        'Tumblr $kind post; use "Save media to Downloads" and drag the files in.');
    if (hostProblem != null) {
      // Host messages are full sentences (sometimes several), so they go last.
      final problem = hostProblem.trimRight();
      note.write(' NEFORUM could not put the photos on your media host, so they are not filled in this time. '
          '$problem${RegExp(r'[.!?]$').hasMatch(problem) ? '' : '.'}');
    } else if (!videoOnly) {
      note.write(' With a media host set up in Settings, NEFORUM fills in photo posts on computers too (photos, '
          'text and tags).');
    }

    return HandoffPlan(
      platformId: id,
      instructions: _numbered(steps),
      clipboardText: clipboard,
      shareText: clipboard,
      shareFiles: media,
      androidPackage: _tumblrPackage,
      desktopUrl: videoOnly ? newVideoUrl : newPhotoUrl,
      preferred: HandoffMethod.shareSheet,
      mediaNote: note.toString(),
      snippets: _snippets(variant),
      composerUrl: composerFor(variant),
      composerInstructions: _composerSteps(variant),
    );
  }

  /// The photos are at [urls] on the user's media host: the share tool opens
  /// a photo post (a photoset for several) with them, the caption and tags.
  HandoffPlan _photoToolHandoff(PostVariant variant, List<MediaAttachment> photos, List<Uri> urls, String hostName) {
    final tags = TumblrApi.tagsField(variant.tags);
    final caption = _fullText(variant);
    final source = _sourceUrl(variant);
    final params = <String, String>{
      'posttype': 'photo',
      // One URL, or a comma-separated list for a photoset. A comma inside a
      // URL is escaped so it cannot split it.
      'content': urls.map((u) => u.toString().replaceAll(',', '%2C')).join(','),
      if (caption.isNotEmpty) 'caption': caption,
      if (tags != null) 'tags': tags,
      if (source != null) 'canonicalUrl': source,
    };

    final n = photos.length;
    final hasVideo = variant.media.any((m) => m.isVideo);
    final hasText = caption.isNotEmpty;
    final filledParts = [n == 1 ? 'your photo' : 'your $n photos', if (hasText) 'text', if (tags != null) 'tags'];
    final filled = filledParts.length == 1
        ? filledParts.single
        : '${filledParts.sublist(0, filledParts.length - 1).join(', ')} and ${filledParts.last}';

    final steps = [
      'Open the Tumblr composer: Tumblr\'s share tool shows a photo post with $filled filled in (sign in if asked).',
      if (hasVideo)
        'The share tool cannot take your video: add it yourself in Tumblr\'s editor (click **Save media to '
            'Downloads** to get the file) or post it separately.',
      if (_hasAltText(variant)) 'Add the alt text listed below to ${n == 1 ? 'the photo' : 'each photo'}.',
      'Click **Post now**.',
      'On a phone you can share the files to the **Tumblr** app instead'
          '${hasText ? ', paste the text from the clipboard' : ''}${tags != null ? ' and add the tags listed below' : ''}.',
    ];

    final them = n == 1 ? 'it' : 'them';
    final note = StringBuffer('NEFORUM put ${n == 1 ? 'the photo' : 'the $n photos'} on $hostName, your media host, '
        'so Tumblr\'s share tool can fetch $them. Post within a day: hosts that expire files delete $them after '
        'about 24 hours. Alt text cannot be passed to the share tool.');
    if (hasVideo) note.write(' The share tool takes photos only as links, so the video has to be added by hand.');

    return HandoffPlan(
      platformId: id,
      instructions: _numbered(steps),
      webIntent: _shareTool(params),
      clipboardText: caption,
      shareText: caption,
      shareFiles: variant.media,
      androidPackage: _tumblrPackage,
      desktopUrl: newPhotoUrl,
      // Phones still hand the files to the Tumblr app; computers (no share
      // sheet) open the prefilled share tool.
      preferred: HandoffMethod.shareSheet,
      mediaNote: note.toString(),
      snippets: _snippets(variant),
      composerUrl: composerFor(variant),
      composerInstructions: _composerSteps(variant),
    );
  }
}

class _Blog {
  const _Blog({required this.name, required this.uuid, required this.url, required this.title, required this.primary});
  final String name;
  final String uuid;
  final String url;
  final String title;
  final bool primary;
}
