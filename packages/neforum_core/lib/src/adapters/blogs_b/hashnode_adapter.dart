import 'dart:convert';

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
import '../audio_links.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'blogs_common.dart';
import 'hashnode_api.dart';

/// Hashnode's tag cap per post.
const int hashnodeMaxTags = 15;

/// Hashnode image uploads: 8 MB, `image/*`, no SVG.
const int hashnodeImageMaxBytes = 8 * 1024 * 1024;

/// Hashnode's GraphQL request body cap (100 KB).
const int hashnodeMaxRequestBytes = 100 * 1024;

/// NEFORUM's own cap on images per post (first = cover, rest inline).
const int hashnodeMaxImages = 10;

/// Adapter for Hashnode blogs (public GraphQL API at gql-beta.hashnode.com).
///
/// Connect: a Personal Access Token plus the blog (host or id), resolved
/// with `publication(host:)`. Publish: images go through
/// `createImageUploadURL` -> PUT -> `confirmImageUpload`, then
/// `publishPost` with the flat `coverImage` field of the current schema.
/// Since 2026-05-13 every API call needs Hashnode Pro on the blog; the
/// FORBIDDEN answer is mapped to a configuration error.
class HashnodeAdapter extends PlatformAdapter {
  HashnodeAdapter();

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'hashnode',
    name: 'Hashnode',
    iconKey: 'hashnode',
    homepage: 'https://hashnode.com',
    tiers: {PlatformTier.byokApi, PlatformTier.handoff},
    defaultTier: PlatformTier.byokApi,
    text: TextRules(
      maxLength: null,
      titleRequired: true,
      titleSupported: true,
      supportsThreads: false,
      supportsContentWarning: false,
      supportsMarkdown: true,
      supportsHashtags: true,
      hashtagsAsField: true,
      maxHashtags: hashnodeMaxTags,
      linkInText: true,
      notes: 'Markdown articles with a required title and up to 15 tags. The whole request (text included) '
          'must stay under 100 KB.',
    ),
    media: MediaRules(
      // Sound goes as a link to the file on the media host.
      audioAsLink: true,
      maxImages: hashnodeMaxImages,
      maxVideos: 0,
      imageMaxBytes: hashnodeImageMaxBytes,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif', 'image/webp'},
      supportsAltText: true,
      notes: 'Images (max 8 MB, no SVG) are uploaded to the Hashnode CDN. The first one becomes the cover, the '
          'others are embedded at the end of the article.',
    ),
    defaultQuotas: [
      QuotaRule(
        id: 'hashnode.mutations_per_minute',
        limit: 500,
        window: Duration(minutes: 1),
        note: 'API write calls per minute (published target, not enforced; one post uses 1 + 2 per image)',
        appliesToTier: PlatformTier.byokApi,
      ),
    ],
    personalAccountOk: true,
    accountRequirements: 'A Hashnode account with a blog. API posting only works when that blog is on the paid '
        'Hashnode Pro plan; the hand-off option works on any plan.',
    apiCostSummary: 'Since May 2026 Hashnode only answers API calls for blogs on Hashnode Pro (paid per seat). '
        'Within Pro the limits are generous (500 write calls a minute).',
    setupGuide: 'docs/platforms/hashnode.md',
    serverSideScheduling: false,
    supportsLinkField: false,
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.byokApi,
          intro: '**Needs Hashnode Pro.** Since May 2026 Hashnode only allows API access for blogs on the Pro plan '
              '(blog dashboard > Billing > Upgrade to Pro).\n\n'
              '1. Sign in at https://hashnode.com and open **Account settings > Developer** '
              '(https://hashnode.com/settings/developer).\n'
              '2. Press **Generate new token**, name it `NEFORUM` and copy it. Treat it like a password: it can publish, '
              'edit and delete posts on your blogs.\n'
              '3. Paste it below together with your blog address (e.g. `alice.hashnode.dev` or your custom domain).',
          fields: [
            ConnectField(
              key: 'token',
              label: 'Personal Access Token',
              kind: FieldKind.password,
              secret: true,
              help: 'From Account settings > Developer. It does not expire until you revoke it.',
            ),
            ConnectField(
              key: 'publication',
              label: 'Blog address or publication id',
              placeholder: 'alice.hashnode.dev',
              required: false,
              help: 'The blog to post to. Leave empty if you have only one blog.',
            ),
            ConnectField(
              key: 'endpoint',
              label: 'API endpoint (advanced)',
              kind: FieldKind.url,
              required: false,
              defaultValue: 'https://gql-beta.hashnode.com',
              help: 'Leave as is. The retired https://gql.hashnode.com is replaced automatically.',
            ),
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.handoff,
          intro: 'Free on any plan. NEFORUM copies your article (Markdown) to the clipboard and opens Hashnode; '
              'you start a new draft on your blog, paste it, add the title and press **Publish**.',
        ),
      ];

  // ---------------------------------------------------------------- connect

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier == PlatformTier.handoff) {
      return ConnectResult(
        account: ConnectedAccount(
          id: 'hashnode-handoff',
          platformId: id,
          tier: PlatformTier.handoff,
          displayName: 'Hashnode (hand-off)',
          createdAt: ctx.now(),
          profileUrl: 'https://hashnode.com',
        ),
      );
    }
    final token = (input['token'] ?? '').trim();
    if (token.isEmpty) throw const ConnectException('Paste your Hashnode Personal Access Token', field: 'token');
    final endpoint = _parseEndpoint(input['endpoint']);
    final api = HashnodeApi(ctx, token: token, endpoint: endpoint);

    ctx.progress('Checking the token with Hashnode');
    final me = blogMap((await _connectCall(() => api.call(HashnodeDocs.me)))['me']);
    final username = blogStr(me['username']);
    if (username == null) throw const ConnectException('Hashnode did not return your account; check the token.', field: 'token');

    final pubInput = (input['publication'] ?? '').trim();
    Map<String, dynamic> pub;
    if (pubInput.isEmpty) {
      final pubs = [
        for (final e in blogList(blogMap(me['publications'])['edges'])) blogMap(blogMap(e)['node']),
      ].where((p) => blogStr(p['id']) != null).toList();
      if (pubs.isEmpty) throw const ConnectException('Your Hashnode account has no blog yet.', field: 'publication');
      if (pubs.length > 1) {
        final hosts = pubs.map((p) => Uri.tryParse(blogStr(p['url']) ?? '')?.host ?? blogStr(p['id'])).join(', ');
        throw ConnectException('You have several blogs ($hosts). Enter the one to post to.', field: 'publication');
      }
      pub = pubs.single;
    } else {
      ctx.progress('Looking up your blog');
      final isId = RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(pubInput);
      final data = await _connectCall(() => isId
          ? api.call(HashnodeDocs.publicationById, {'id': pubInput})
          : api.call(HashnodeDocs.publicationByHost, {'host': _host(pubInput)}));
      pub = blogMap(data['publication']);
      if (blogStr(pub['id']) == null) {
        throw ConnectException('Hashnode has no blog at "$pubInput".', field: 'publication');
      }
    }
    final pubId = blogStr(pub['id'])!;
    final pubUrl = blogStr(pub['url']);
    final pubTitle = blogStr(pub['title']);
    final name = blogStr(me['name']);
    return ConnectResult(
      account: ConnectedAccount(
        id: 'hashnode:$pubId',
        platformId: id,
        tier: PlatformTier.byokApi,
        displayName: pubTitle ?? name ?? username,
        handle: '@$username',
        avatarUrl: blogStr(me['profilePicture']),
        profileUrl: pubUrl,
        createdAt: ctx.now(),
        config: {
          'publicationId': pubId,
          if (pubUrl != null) 'publicationUrl': pubUrl,
          if (pubTitle != null) 'publicationTitle': pubTitle,
          'username': username,
          if (blogStr(me['id']) != null) 'userId': blogStr(me['id']),
          if (endpoint != hashnodeDefaultEndpoint) 'endpoint': endpoint.toString(),
        },
      ),
      secrets: OAuthTokens(accessToken: token, tokenType: 'PAT').toSecrets(),
    );
  }

  Future<Map<String, dynamic>> _connectCall(Future<Map<String, dynamic>> Function() call) async {
    try {
      return await call();
    } on HashnodeError catch (e) {
      if (e.isProRequired) {
        throw const ConnectException('Hashnode only allows API access for blogs on Hashnode Pro. Upgrade the blog '
            '(Dashboard > Billing > Upgrade to Pro) or choose the hand-off option.');
      }
      if (e.code == 'UNAUTHENTICATED' || e.statusCode == 401) {
        throw const ConnectException('Hashnode rejected this token. Copy it again or generate a new one.', field: 'token');
      }
      throw ConnectException('Hashnode answered: ${e.message}');
    } on HttpFailure catch (f) {
      throw ConnectException('Hashnode answered HTTP ${f.statusCode}.');
    } on Exception catch (e) {
      throw ConnectException('Could not reach Hashnode: $e');
    }
  }

  Uri _parseEndpoint(String? raw) {
    final s = (raw ?? '').trim();
    if (s.isEmpty) return hashnodeDefaultEndpoint;
    final u = Uri.tryParse(s);
    if (u == null || u.scheme != 'https' || u.host.isEmpty) {
      throw const ConnectException('The API endpoint must be an https:// URL', field: 'endpoint');
    }
    return hashnodeEndpointOrDefault(u);
  }

  String _host(String raw) {
    final s = raw.contains('://') ? raw : 'https://$raw';
    return (Uri.tryParse(s)?.host ?? raw).toLowerCase();
  }

  // --------------------------------------------------------------- validate

  /// Hashnode tag slugs are lower-case and hyphenated.
  static String tagSlug(String tag) => tag
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = RulesValidator.validate(variant, descriptor, tier: account.tier);
    final estimate = utf8.encode(jsonEncode([variant.text, variant.title ?? ''])).length + 2048;
    if (estimate > hashnodeMaxRequestBytes) {
      issues.add(ValidationIssue.error('hashnode.too_large',
          'The article is about ${(estimate / 1024).round()} KB; Hashnode accepts requests up to 100 KB', field: 'text'));
    }
    if (variant.media.any((m) => m.mimeType == 'image/svg+xml')) {
      issues.add(const ValidationIssue.error('media.svg', 'Hashnode does not accept SVG images', field: 'media'));
    }
    if (account.tier == PlatformTier.handoff && variant.hasMedia) {
      issues.add(const ValidationIssue.warning('media.handoff',
          'Images cannot be handed to the Hashnode editor; upload them there yourself', field: 'media'));
    }
    if (account.tier == PlatformTier.byokApi && account.configString('publicationId').isEmpty) {
      issues.add(const ValidationIssue.error('account.publication_missing',
          'This Hashnode account has no blog selected; reconnect it', field: 'account'));
    }
    return issues;
  }

  // ---------------------------------------------------------------- publish

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    try {
      return await _publish(await withAudioLinks(variant, ctx, platform: 'Hashnode', markdown: true), account, secrets, ctx);
    } on AdapterException catch (e) {
      ctx.log.warn('Hashnode publish failed: ${e.error.message}');
      return PublishResult.failure(e.error);
    }
  }

  Future<T> _guard<T>(String context, Future<T> Function() body) => guardBlog(context, () async {
        try {
          return await body();
        } on HashnodeError catch (e) {
          throw AdapterException(hashnodePublishError(e, context: context));
        }
      }, mapHttp: (f) => f.toPublishError(context: context));

  Future<PublishResult> _publish(
      PostVariant v, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier == PlatformTier.handoff) {
      throw const AdapterException(PublishError.unsupported('Hand-off accounts publish through the Hashnode editor'));
    }
    final token = OAuthTokens.fromSecrets(secrets)?.accessToken;
    if (token == null) throw const AdapterException(PublishError.auth('No Hashnode token stored; reconnect the account'));
    final errors = validate(v, account).errors.toList();
    if (errors.isNotEmpty) throw AdapterException(PublishError.validation(errors.first.message));
    final endpointRaw = account.configString('endpoint');
    final api = HashnodeApi(ctx, token: token, endpoint: endpointRaw.isEmpty ? null : Uri.parse(endpointRaw));

    var markdown = v.text;
    String? cover = blogStr(v.extra['coverImageUrl']);
    if (v.hasMedia) {
      final urls = <String>[];
      for (var i = 0; i < v.media.length; i++) {
        urls.add(await _uploadImage(api, v.media[i], i + 1, v.media.length, ctx));
      }
      final alts = [for (final m in v.media) m.altText];
      if (cover == null && v.extra['coverFromFirstImage'] != false) {
        cover = urls.first;
        markdown = appendMarkdownImages(markdown, urls.sublist(1), alts.sublist(1));
      } else {
        markdown = appendMarkdownImages(markdown, urls, alts);
      }
    }

    final tags = <Map<String, String>>[];
    for (final t in v.tags) {
      final slug = tagSlug(t);
      if (slug.isEmpty || tags.any((x) => x['slug'] == slug) || tags.length >= hashnodeMaxTags) continue;
      tags.add({'slug': slug, 'name': t});
    }
    final input = <String, Object?>{
      'publicationId': account.configString('publicationId'),
      'title': v.title!.trim(),
      'contentMarkdown': markdown,
      if (tags.isNotEmpty) 'tags': tags,
      if (blogStr(v.extra['subtitle']) != null) 'subtitle': blogStr(v.extra['subtitle']),
      if (blogStr(v.extra['slug']) != null) 'slug': blogStr(v.extra['slug']),
      if (blogStr(v.extra['canonicalUrl']) != null) 'originalArticleURL': blogStr(v.extra['canonicalUrl']),
      if (v.extra['disableComments'] == true) 'disableComments': true,
      // PublishPostInput has a flat `coverImage: String`; the old
      // `coverImageOptions` object is rejected with BAD_USER_INPUT.
      if (cover != null) 'coverImage': cover,
    };

    ctx.progress('Publishing on Hashnode');
    final data = await _guard('Hashnode post', () => api.call(HashnodeDocs.publishPost, {'input': input}));
    final post = blogMap(blogMap(data['publishPost'])['post']);
    final postId = blogStr(post['id']);
    if (postId == null) {
      throw AdapterException(PublishError.platform('Hashnode did not return the new post', raw: blogSnippet(jsonEncode(data))));
    }
    ctx.log.info('Published Hashnode post $postId');
    return PublishResult.ok(remoteId: postId, remoteUrl: blogStr(post['url']), publishedAt: ctx.now());
  }

  Future<String> _uploadImage(HashnodeApi api, MediaAttachment m, int n, int total, AdapterContext ctx) async {
    final context = 'Hashnode image $n/$total';
    ctx.progress('Uploading image $n of $total');
    final created = await _guard(context,
        () => api.call(HashnodeDocs.createImageUpload, {
              'input': {'contentType': m.mimeType},
            }));
    final put = blogMap(blogMap(created['createImageUploadURL'])['presignedPut']);
    final url = blogStr(put['url']);
    final key = blogStr(put['key']);
    if (url == null || key == null) {
      throw AdapterException(PublishError.platform('$context: Hashnode returned no upload URL', raw: blogSnippet(jsonEncode(created))));
    }
    final bytes = await ctx.readMedia(m);
    await guardBlog(context,
        () => ctx.http.send('PUT', Uri.parse(url), headers: {'Content-Type': m.mimeType}, bytes: bytes, timeout: blogUploadTimeout),
        mapHttp: (f) => f.statusCode == 403
            ? PublishError.platform('$context: the upload link was refused (expired?)', raw: f.body, statusCode: 403)
            : f.toPublishError(context: context));
    final confirmed = blogMap((await _guard(context,
        () => api.call(HashnodeDocs.confirmImageUpload, {
              'input': {'key': key},
            })))['confirmImageUpload']);
    if (confirmed['ok'] != true) {
      throw AdapterException(PublishError.validation('$context: Hashnode refused the image (larger than 8 MB?)'));
    }
    return blogStr(confirmed['cdnUrl']) ?? blogStr(put['cdnUrl']) ?? url;
  }

  // ---------------------------------------------------------------- hand-off

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final title = variant.title?.trim() ?? '';
    final tags = variant.tags.take(hashnodeMaxTags).toList();
    return HandoffPlan(
      platformId: id,
      clipboardText: variant.text,
      shareText: variant.text,
      shareFiles: variant.media,
      desktopUrl: 'https://hashnode.com/',
      preferred: HandoffMethod.manual,
      instructions: [
        '1. NEFORUM opens Hashnode: go to your blog dashboard and start a new draft. Your article is on the clipboard.',
        '2. Paste it into the editor${title.isNotEmpty ? ' and type the title "$title"' : ''}.',
        '3. ${tags.isNotEmpty ? 'Add the tags ${tags.join(', ')}' : 'Add tags'}${variant.hasMedia ? ', upload your images' : ''}, then press **Publish**.',
      ].join('\n'),
      mediaNote: variant.hasMedia ? 'Hashnode cannot receive files from NEFORUM in hand-off mode; upload the images in the editor.' : null,
    );
  }
}
