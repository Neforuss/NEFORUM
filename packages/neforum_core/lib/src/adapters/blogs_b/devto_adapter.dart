import '../../auth/oauth2_pkce.dart';
import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../media_hosts/media_host.dart';
import '../../model/account.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../../text/rules_validator.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'blogs_common.dart';

/// Forem's `MAX_TAG_LIST_SIZE`.
const int devtoMaxTags = 4;

/// Forem `Tag#validate_name`: at most 30 characters, letters and digits only.
/// A longer tag makes the whole article fail with HTTP 422.
const int devtoTagMaxLength = 30;

/// Forem article title maximum for full posts (app/models/article.rb).
const int devtoTitleMax = 128;

/// Forem `body_markdown` byte cap (800 kilobytes).
const int devtoBodyMaxBytes = 800 * 1024;

/// NEFORUM's own cap on images per article (first = cover, rest inline).
const int devtoMaxImages = 10;

/// Accept header that selects Forem API v1.
const String devtoAccept = 'application/vnd.forem.api-v1+json';

/// The default Forem community.
final Uri devtoDefaultBase = Uri.parse('https://dev.to');

/// Adapter for DEV Community and other Forem communities (Forem API v1).
///
/// Connect: a personal API key (Settings > Extensions) checked with
/// `GET /api/users/me`. Publish: `POST /api/articles` with
/// `{article: {title, body_markdown, published, tags, ...}}`. The API has no
/// image upload, so images go through the configured media host. Hand-off
/// opens `/new?prefill=` with front matter.
class DevtoAdapter extends PlatformAdapter {
  DevtoAdapter();

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'devto',
    name: 'DEV Community',
    iconKey: 'devto',
    homepage: 'https://dev.to',
    family: 'forem',
    tiers: {PlatformTier.openApi, PlatformTier.handoff},
    defaultTier: PlatformTier.openApi,
    text: TextRules(
      maxLength: devtoBodyMaxBytes,
      counting: CountingRule.utf8Bytes,
      titleMax: devtoTitleMax,
      titleRequired: true,
      titleSupported: true,
      supportsThreads: false,
      supportsContentWarning: false,
      supportsMarkdown: true,
      supportsHashtags: true,
      hashtagsAsField: true,
      maxHashtags: devtoMaxTags,
      linkInText: true,
      notes: 'Articles are Markdown with a required title (max 128 characters). At most 4 tags, letters and digits '
          'only, 30 characters each. Body up to 800 KB.',
    ),
    media: MediaRules(
      maxImages: devtoMaxImages,
      maxVideos: 0,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif', 'image/webp'},
      supportsAltText: true,
      requiresPublicMediaUrl: true,
      notes: 'The DEV API cannot upload images. NEFORUM puts them on your media host: the first image becomes the '
          'cover, the others are embedded at the end of the article. Use a host that keeps files permanently.',
    ),
    defaultQuotas: [
      QuotaRule(
        id: 'devto.articles_per_30s',
        limit: 10,
        window: Duration(seconds: 30),
        note: 'new articles per 30 seconds (DEV rate limit; HTTP 429 beyond it)',
        appliesToTier: PlatformTier.openApi,
      ),
    ],
    personalAccountOk: true,
    accountRequirements: 'Any DEV (or other Forem) account. You create a personal API key in your settings; '
        'no developer registration or review.',
    apiCostSummary: 'Free. DEV allows about 10 new articles per 30 seconds (brand-new accounts only about one '
        'per 5 minutes) and one write request per second.',
    setupGuide: 'docs/platforms/devto.md',
    serverSideScheduling: false,
    supportsLinkField: false,
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  static const ConnectField _instanceField = ConnectField(
    key: 'instance',
    label: 'Forem community (optional)',
    kind: FieldKind.url,
    required: false,
    defaultValue: 'https://dev.to',
    help: 'Leave as https://dev.to unless you post to another Forem community.',
  );

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.openApi,
          intro: '**DEV needs no developer account.**\n\n'
              '1. Sign in at https://dev.to and open **Settings > Extensions** (https://dev.to/settings/extensions).\n'
              '2. Under **DEV Community API Keys**, type `NEFORUM` as the description and press **Generate API Key**.\n'
              '3. Copy the key and paste it below.\n\n'
              'Images need a media host (Settings > Media host), because the DEV API cannot upload files.',
          fields: [
            ConnectField(
              key: 'apiKey',
              label: 'API key',
              kind: FieldKind.password,
              secret: true,
              help: 'From Settings > Extensions > DEV Community API Keys. It never expires; revoke it there.',
            ),
            _instanceField,
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.handoff,
          intro: 'NEFORUM opens the DEV editor (dev.to/new) with your title, tags and text filled in; you check it '
              'and press **Publish**. You must be signed in to DEV in the browser. Images must be added in the editor.',
          fields: [_instanceField],
        ),
      ];

  // ---------------------------------------------------------------- connect

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    final base = _parseBase(input['instance']);
    if (tier == PlatformTier.handoff) {
      return ConnectResult(
        account: ConnectedAccount(
          id: 'devto-handoff:${base.host}',
          platformId: id,
          tier: PlatformTier.handoff,
          displayName: '${base.host} (hand-off)',
          createdAt: ctx.now(),
          profileUrl: base.toString(),
          config: {'base': base.toString()},
        ),
      );
    }
    final key = (input['apiKey'] ?? '').trim();
    if (key.isEmpty) throw const ConnectException('Paste your DEV API key', field: 'apiKey');
    ctx.progress('Checking the API key with ${base.host}');
    final Map<String, dynamic> me;
    try {
      me = (await ctx.http.get(base.replace(path: '/api/users/me'), headers: _headers(key))).jsonMap;
    } on HttpFailure catch (f) {
      if (f.statusCode == 401 || f.statusCode == 403) {
        throw const ConnectException('DEV rejected this API key. Copy it again or generate a new one.', field: 'apiKey');
      }
      throw ConnectException('${base.host} answered HTTP ${f.statusCode} while checking the key.');
    } on Exception catch (e) {
      throw ConnectException('Could not reach ${base.host}: $e');
    }
    final userId = blogInt(me['id'])?.toString() ?? blogStr(me['id']);
    final username = blogStr(me['username']);
    if (userId == null || username == null) {
      throw ConnectException('${base.host} answered, but not with a user. Is this a Forem community?');
    }
    final name = blogStr(me['name']);
    return ConnectResult(
      account: ConnectedAccount(
        id: 'devto:$userId@${base.host}',
        platformId: id,
        tier: PlatformTier.openApi,
        displayName: name == null ? '$username (${base.host})' : '$name (${base.host})',
        handle: '@$username',
        avatarUrl: blogStr(me['profile_image']),
        profileUrl: '$base/$username',
        createdAt: ctx.now(),
        config: {'base': base.toString(), 'userId': userId, 'username': username},
      ),
      secrets: OAuthTokens(accessToken: key, tokenType: 'api-key').toSecrets(),
    );
  }

  Uri _parseBase(String? raw) {
    var s = (raw ?? '').trim();
    if (s.isEmpty) return devtoDefaultBase;
    if (!s.contains('://')) s = 'https://$s';
    final u = Uri.tryParse(s);
    if (u == null || u.host.isEmpty || !u.host.contains('.') || u.scheme != 'https') {
      throw ConnectException('"$raw" is not a valid https:// community address', field: 'instance');
    }
    return Uri(scheme: 'https', host: u.host.toLowerCase(), port: u.hasPort ? u.port : null);
  }

  static Map<String, String> _headers(String key) => {'api-key': key, 'Accept': devtoAccept};

  // --------------------------------------------------------------- validate

  /// DEV tags: lower-case letters and digits only.
  static String cleanTag(String tag) => tag.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

  /// The tags DEV will accept, in order: cleaned, de-duplicated, at most
  /// [devtoTagMaxLength] characters each and [devtoMaxTags] in total.
  static List<String> sendableTags(Iterable<String> raw) {
    final tags = <String>[];
    for (final t in raw.map(cleanTag)) {
      if (t.isEmpty || t.length > devtoTagMaxLength || tags.contains(t)) continue;
      if (tags.length == devtoMaxTags) break;
      tags.add(t);
    }
    return tags;
  }

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = RulesValidator.validate(variant, descriptor, tier: account.tier);
    if (variant.tags.any((t) => cleanTag(t) != t)) {
      issues.add(const ValidationIssue.info('devto.tag_cleaned',
          'DEV tags may only contain lower-case letters and digits; NEFORUM will clean them up', field: 'tags'));
    }
    if (variant.tags.any((t) => cleanTag(t).length > devtoTagMaxLength)) {
      issues.add(const ValidationIssue.warning('devto.tag_too_long',
          'DEV tags are at most $devtoTagMaxLength characters; longer tags are left out', field: 'tags'));
    }
    if (variant.tags.length > devtoMaxTags) {
      issues.add(const ValidationIssue.info('devto.tags_dropped', 'Only the first 4 tags are sent to DEV', field: 'tags'));
    }
    final canonical = blogStr(variant.extra['canonicalUrl']);
    if (canonical != null) {
      final u = Uri.tryParse(canonical);
      if (u == null || (u.scheme != 'https' && u.scheme != 'http') || u.host.isEmpty || canonical.contains(' ')) {
        issues.add(const ValidationIssue.error('devto.canonical_url', 'The canonical URL must be an http(s) link',
            field: 'extra'));
      }
    }
    if (variant.hasMedia && account.tier == PlatformTier.handoff) {
      issues.add(const ValidationIssue.warning('media.handoff',
          'The DEV editor cannot be prefilled with images; upload them in the editor', field: 'media'));
    } else if (variant.hasMedia) {
      issues.add(const ValidationIssue.info('media.needs_host',
          'DEV images are placed on your media host first (the first image becomes the cover)', field: 'media'));
    }
    return issues;
  }

  // ---------------------------------------------------------------- publish

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    try {
      return await _publish(variant, account, secrets, ctx);
    } on AdapterException catch (e) {
      ctx.log.warn('DEV publish failed: ${e.error.message}');
      return PublishResult.failure(e.error);
    }
  }

  Future<PublishResult> _publish(
      PostVariant v, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier == PlatformTier.handoff) {
      throw const AdapterException(PublishError.unsupported('Hand-off accounts publish through the DEV editor'));
    }
    final key = OAuthTokens.fromSecrets(secrets)?.accessToken;
    if (key == null) throw const AdapterException(PublishError.auth('No DEV API key stored; reconnect the account'));
    final errors = validate(v, account).errors.toList();
    if (errors.isNotEmpty) throw AdapterException(PublishError.validation(errors.first.message));
    final base = Uri.parse(account.configString('base', devtoDefaultBase.toString()));

    var markdown = v.text;
    String? mainImage = blogStr(v.extra['mainImage']);
    if (v.hasMedia) {
      final urls = await _hostImages(v, ctx);
      final alts = [for (final m in v.media) m.altText];
      if (mainImage == null && v.extra['coverFromFirstImage'] != false) {
        mainImage = urls.first;
        markdown = appendMarkdownImages(markdown, urls.sublist(1), alts.sublist(1));
      } else {
        markdown = appendMarkdownImages(markdown, urls, alts);
      }
    }

    final tags = sendableTags(v.tags);
    final article = <String, Object?>{
      'title': v.title!.trim(),
      'body_markdown': markdown,
      'published': v.extra['draft'] != true,
      if (tags.isNotEmpty) 'tags': tags,
      if (mainImage != null) 'main_image': mainImage,
      if (blogStr(v.extra['canonicalUrl']) != null) 'canonical_url': blogStr(v.extra['canonicalUrl']),
      if (blogStr(v.extra['description']) != null) 'description': blogStr(v.extra['description']),
      if (blogStr(v.extra['series']) != null) 'series': blogStr(v.extra['series']),
      if (blogInt(v.extra['organizationId']) != null) 'organization_id': blogInt(v.extra['organizationId']),
    };
    ctx.progress('Publishing the article on ${base.host}');
    final res = await guardBlog('DEV article',
        () => ctx.http.postJson(base.replace(path: '/api/articles'), {'article': article}, headers: _headers(key)),
        mapHttp: (f) => devtoError(f, context: 'DEV article'));
    final json = res.jsonMap;
    final articleId = blogInt(json['id'])?.toString() ?? blogStr(json['id']);
    final path = blogStr(json['path']);
    final url = blogStr(json['url']) ?? res.headers['location'] ?? (path == null ? null : base.resolve(path).toString());
    if (articleId == null) {
      throw AdapterException(PublishError.platform('DEV did not return the new article', raw: blogSnippet(res.body)));
    }
    ctx.log.info('Created DEV article $articleId');
    return PublishResult.ok(remoteId: articleId, remoteUrl: url, publishedAt: ctx.now());
  }

  Future<List<String>> _hostImages(PostVariant v, AdapterContext ctx) async {
    final host = ctx.mediaHost;
    if (host == null) {
      throw const AdapterException(PublishError.configuration(
          'DEV cannot upload images: set up a media host in Settings, or remove the images'));
    }
    final urls = <String>[];
    for (var i = 0; i < v.media.length; i++) {
      final m = v.media[i];
      ctx.progress('Uploading image ${i + 1} of ${v.media.length} to ${host.name}');
      try {
        final hosted = await host.upload(m, await ctx.readMedia(m));
        urls.add(hosted.url.toString());
      } on MediaHostException catch (e) {
        throw AdapterException(e.toPublishError());
      }
    }
    return urls;
  }

  // ---------------------------------------------------------------- hand-off

  /// The Markdown with front matter that `/new?prefill=` expects.
  static String prefillMarkdown(PostVariant v) {
    final tags = sendableTags(v.tags);
    final canonical = blogStr(v.extra['canonicalUrl']);
    final cover = blogStr(v.extra['mainImage']);
    final title = v.title?.trim() ?? '';
    return [
      '---',
      'title: ${yamlQuote(title)}',
      'published: true',
      if (tags.isNotEmpty) 'tags: ${tags.join(', ')}',
      if (canonical != null) 'canonical_url: $canonical',
      if (cover != null) 'cover_image: $cover',
      '---',
      '',
      v.text,
    ].join('\n');
  }

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final base = Uri.parse(account?.configString('base', devtoDefaultBase.toString()) ?? devtoDefaultBase.toString());
    final md = prefillMarkdown(variant);
    final intent = Uri.parse('$base/new?prefill=${Uri.encodeComponent(md)}');
    return HandoffPlan(
      platformId: id,
      webIntent: intent,
      clipboardText: md,
      shareText: md,
      shareFiles: variant.media,
      desktopUrl: intent.toString(),
      preferred: HandoffMethod.webIntent,
      instructions: [
        '1. NEFORUM opens the DEV editor with your title, tags and text filled in (sign in if asked).',
        if (variant.hasMedia) '2. Upload your images with the image button and paste the links where you want them.',
        '${variant.hasMedia ? 3 : 2}. Check the preview and press **Publish**.',
      ].join('\n'),
      mediaNote: variant.hasMedia
          ? 'The DEV editor link cannot carry images. Upload them in the editor; the full article is also on the clipboard.'
          : null,
    );
  }
}

/// Maps a failed Forem API call onto a [PublishError]. Forem answers
/// `{"error": "...", "status": 422}`.
PublishError devtoError(HttpFailure f, {required String context}) {
  final base = f.toPublishError(context: context);
  final message = blogStr(f.response.jsonMap['error']);
  final detail = message == null ? '' : ': $message';
  final status = f.statusCode;
  return switch (status) {
    401 => PublishError.auth('$context: DEV rejected the API key; reconnect the account$detail',
        raw: base.raw, statusCode: status),
    403 => PublishError.auth('$context: this API key may not do that$detail', raw: base.raw, statusCode: status),
    422 => PublishError.validation('$context: DEV refused the article$detail', raw: base.raw, statusCode: status),
    429 => PublishError.quota('$context: DEV rate limit reached$detail',
        raw: base.raw, statusCode: status, retryAfter: f.response.retryAfter ?? const Duration(seconds: 30)),
    _ => message == null || status >= 500
        ? base
        : PublishError(kind: base.kind, message: '${base.message}$detail', raw: base.raw, statusCode: status, retryable: base.retryable),
  };
}
