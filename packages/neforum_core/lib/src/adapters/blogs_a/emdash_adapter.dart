import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:unorm_dart/unorm_dart.dart' show nfkc;

import '../../auth/oauth2_pkce.dart';
import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../model/account.dart';
import '../../model/media.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post.dart' show Visibility;
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../../text/portable_text.dart';
import '../../text/rules_validator.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../network_options.dart';
import '../platform_adapter.dart';
import 'blog_common.dart';
import 'emdash_api.dart';

/// Statuses an EmDash post can be left in by NEFORUM.
const Set<String> emdashStatuses = {'published', 'draft'};

/// The most photos NEFORUM puts in one EmDash post (EmDash sets no limit).
const int emdashMaxImages = 20;

/// The most videos NEFORUM puts in one EmDash post (EmDash sets no limit).
const int emdashMaxVideos = 4;

/// Adapter for EmDash (emdashcms.com, Cloudflare's MIT-licensed CMS) through
/// its REST API with a personal access token.
///
/// Publish: `POST /_emdash/api/media` per photo or video, the tags made sure
/// of in the `tag` taxonomy, `POST content/posts` (a draft, its text as
/// Portable Text), then `POST content/posts/{id}/publish`. The first photo is
/// the featured image. The post is at `/posts/{slug}`.
///
/// A try that is sent again never makes a second post: the post's slug is
/// fixed before it is sent and every Portable Text key carries a mark made
/// from the post, so when the slug is taken NEFORUM reads that post and, when
/// it carries the mark, finishes it instead of making another.
class EmDashAdapter extends PlatformAdapter {
  static const Set<String> _imageTypes = {'image/jpeg', 'image/png', 'image/gif', 'image/webp'};
  static const Set<String> _videoTypes = {'video/mp4', 'video/webm', 'video/quicktime'};

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'emdash',
    name: 'EmDash',
    iconKey: 'emdash',
    homepage: 'https://emdashcms.com',
    tiers: {PlatformTier.openApi, PlatformTier.handoff},
    defaultTier: PlatformTier.openApi,
    text: TextRules(
      maxLength: null,
      counting: CountingRule.utf16,
      titleSupported: true,
      titleRequired: true,
      supportsThreads: false,
      supportsContentWarning: false,
      supportsMarkdown: true,
      supportsHtml: false,
      supportsHashtags: true,
      hashtagsAsField: true,
      linkInText: true,
      notes: 'No length limit. Markdown becomes EmDash\'s own rich text (Portable Text): headings, bold, italic, links, '
          'lists, quotes and code. HTML is shown as text, never run. Tags go into the Tags taxonomy; new ones are made.',
    ),
    media: MediaRules(
      maxImages: emdashMaxImages,
      maxVideos: emdashMaxVideos,
      allowsMixedImageVideo: true,
      imageMaxBytes: emdashDefaultMaxUpload,
      videoMaxBytes: emdashDefaultMaxUpload,
      imageMimeTypes: _imageTypes,
      videoMimeTypes: _videoTypes,
      supportsAltText: true,
      notes: 'Photos (JPEG, PNG, GIF, WEBP) and videos (MP4, WebM, MOV) go to the EmDash media library, 50 MB each by '
          'default. The first photo is the featured image and the others are placed in the post; EmDash sets no '
          'per-post limit, 20 photos and 4 videos are NEFORUM\'s. No sound files.',
    ),
    defaultQuotas: [],
    personalAccountOk: true,
    accountRequirements: 'An EmDash site (1.5 or newer) and an Administrator account on it, which is what can make '
        'API tokens. Other roles can use Hand-off.',
    apiCostSummary: 'Free: EmDash is open source and the API is part of your own site. EmDash does not publish an API '
        'quota.',
    setupGuide: 'docs/platforms/emdash.md',
    serverSideScheduling: false,
    supportsLinkField: false,
    options: emdashOptions,
  );

  @override
  SignInPolicy signInPolicyFor(ConnectedAccount account) => SignInPolicies.emDash(account);

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.openApi,
          intro: '**EmDash needs no developer account**, only an API token from your own site:\n\n'
              '1. Open your EmDash admin (`https://your-site/_emdash/admin`) and go to **Settings > API Tokens**.\n'
              '2. Press **Create token**, name it `NEFORUM` and tick **Content Read**, **Content Write** and '
              '**Media Write**.\n'
              '3. Choose **No expiry** (or an end date you will remember), create it and copy the token: it starts '
              'with `ec_pat_` and is shown only once.\n\n'
              'Only an Administrator can make tokens. Nothing is posted while you connect.',
          fields: [
            ConnectField(
              key: 'site',
              label: 'Site address',
              kind: FieldKind.url,
              placeholder: 'https://blog.example.com',
              help: 'The address of your EmDash site, without /_emdash/admin.',
            ),
            ConnectField(
              key: 'token',
              label: 'API token',
              kind: FieldKind.password,
              secret: true,
              help: 'Starts with `ec_pat_`. Keep it private: it can change the content of your site.',
            ),
            ConnectField(
              key: 'defaultStatus',
              label: 'Publish as',
              kind: FieldKind.select,
              required: false,
              options: ['published', 'draft'],
              defaultValue: 'published',
              help: '`published` makes the post live at once; `draft` leaves it in EmDash for you to finish.',
            ),
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.handoff,
          intro: 'For any EmDash role, with no token: NEFORUM copies the post and opens a new post in your EmDash '
              'admin, where you paste it and press **Publish**.',
          fields: [
            ConnectField(
              key: 'site',
              label: 'Site address',
              kind: FieldKind.url,
              placeholder: 'https://blog.example.com',
              help: 'The address of your EmDash site, without /_emdash/admin.',
            ),
          ],
        ),
      ];

  // ---------------------------------------------------------------- connect

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    final site = parseEmDashSite(input['site'] ?? '');
    if (tier == PlatformTier.handoff) {
      return ConnectResult(
        account: ConnectedAccount(
          id: 'emdash-handoff:${site.host}${site.path}',
          platformId: id,
          tier: PlatformTier.handoff,
          displayName: '${site.host} (hand-off)',
          profileUrl: site.toString(),
          createdAt: ctx.now(),
          config: {'site': site.toString()},
        ),
      );
    }
    final token = parseEmDashToken(input['token'] ?? '');
    final version = await _checkSite(site, ctx);
    await _checkToken(site, token, ctx);
    final title = await _siteTitle(site, ctx) ?? site.host;
    final status = (input['defaultStatus'] ?? '').trim();
    return ConnectResult(
      account: ConnectedAccount(
        id: 'emdash:${site.host}${site.path}',
        platformId: id,
        tier: PlatformTier.openApi,
        displayName: title,
        handle: site.host,
        profileUrl: site.toString(),
        createdAt: ctx.now(),
        config: {
          'site': site.toString(),
          'siteTitle': title,
          'version': ?version,
          if (emdashStatuses.contains(status)) 'defaultStatus': status,
        },
      ),
      secrets: OAuthTokens(accessToken: token, tokenType: 'personal-access-token').toSecrets(),
    );
  }

  /// `GET /_emdash/api/health`, open to anyone: `{product: "emdash", version}`.
  Future<String?> _checkSite(Uri site, AdapterContext ctx) async {
    ctx.progress('Contacting ${site.host}');
    try {
      final r = await EmDashApi(site, ctx).get('health');
      final data = emdashData(r);
      if (data['product'] != 'emdash') throw const FormatException('not emdash');
      return blogStr(data['version']);
    } on HttpFailure catch (f) {
      throw ConnectException(f.statusCode == 404
          ? '${site.host} does not run EmDash (no /_emdash/api). Check the address.'
          : '${site.host} answered HTTP ${f.statusCode}. Check the address and try again.', field: 'site');
    } on FormatException {
      throw ConnectException('${site.host} does not look like an EmDash site.', field: 'site');
    } on Exception catch (e) {
      throw ConnectException('Could not reach ${site.host}: ${NeforumHttp.transportMessage(e)}', field: 'site');
    }
  }

  /// One read of the posts proves the token and its Content Read permission.
  Future<void> _checkToken(Uri site, String token, AdapterContext ctx) async {
    ctx.progress('Checking the API token');
    try {
      await EmDashApi(site, ctx, token: token).get('content/$emdashPostsCollection', {'limit': '1'});
    } on HttpFailure catch (f) {
      final (code, message) = emdashErrorOf(f.response);
      if (f.statusCode == 401 || code == 'INVALID_TOKEN') {
        throw const ConnectException('EmDash did not accept this token. Copy it again, or make a new one if it was '
            'revoked or has run out.', field: 'token');
      }
      if (code == 'INSUFFICIENT_SCOPE') {
        throw const ConnectException('This token cannot read posts. Make a token with Content Read, Content Write '
            'and Media Write.', field: 'token');
      }
      if (code == 'COLLECTION_NOT_FOUND' || f.statusCode == 404) {
        throw ConnectException('${site.host} has no Posts collection. NEFORUM posts to the Posts of EmDash\'s '
            'blog template.', field: 'site');
      }
      throw ConnectException('${site.host} answered HTTP ${f.statusCode} while checking the token'
          '${message == null ? '' : ' ($message)'}.');
    } on Exception catch (e) {
      throw ConnectException('Could not reach ${site.host}: ${NeforumHttp.transportMessage(e)}');
    }
  }

  /// The site's name from its home page (`og:site_name`, else `<title>`).
  /// Best effort: null when it cannot be read.
  Future<String?> _siteTitle(Uri site, AdapterContext ctx) async {
    try {
      final r = await ctx.http.get(site.replace(path: site.path.isEmpty ? '/' : site.path), headers: const {'Accept': 'text/html'});
      final html = r.body;
      final og = RegExp(r'''<meta[^>]+property=["']og:site_name["'][^>]*content=["']([^"']+)["']''', caseSensitive: false).firstMatch(html);
      final title = og?.group(1) ?? RegExp(r'<title[^>]*>([^<]+)</title>', caseSensitive: false).firstMatch(html)?.group(1);
      final cleaned = title == null ? '' : decodeBasicEntities(title).trim();
      return cleaned.isEmpty ? null : cleaned;
    } on Exception {
      return null;
    }
  }

  // --------------------------------------------------------------- validate

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = RulesValidator.validate(variant, descriptor, tier: account.tier);
    if (account.tier == PlatformTier.handoff) {
      if (variant.hasMedia) {
        issues.add(const ValidationIssue.warning('emdash.handoff_media',
            'EmDash\'s editor cannot receive files from NEFORUM; add the photos yourself', field: 'media'));
      }
      return issues;
    }
    final explicit = blogStr(variant.extra['status']);
    if (explicit != null && !emdashStatuses.contains(explicit)) {
      issues.add(ValidationIssue.error('emdash.bad_status', 'Unknown EmDash status "$explicit" (use published or draft)', field: 'extra'));
    }
    if (variant.visibility != Visibility.public) {
      issues.add(const ValidationIssue.warning('emdash.public_only', 'EmDash posts are public once published', field: 'visibility'));
    }
    return issues;
  }

  /// "Publish as": this post's choice, else the choice kept for the account
  /// in the Customize sheet (both reach [PostVariant.extra], the post's over
  /// the account's: VariantResolver), else the account's `defaultStatus`
  /// (Publish as, chosen when connecting), else published.
  String _status(PostVariant v, ConnectedAccount account) {
    final explicit = blogStr(v.extra['status']);
    if (explicit != null && emdashStatuses.contains(explicit)) return explicit;
    return account.configString('defaultStatus', 'published') == 'draft' ? 'draft' : 'published';
  }

  // ---------------------------------------------------------------- publish

  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    try {
      return await _publish(variant, account, secrets, ctx);
    } on AdapterException catch (e) {
      ctx.log.warn('EmDash publish failed: ${e.error.message}');
      return PublishResult.failure(e.error);
    } on Exception catch (e) {
      ctx.log.warn('EmDash publish failed unexpectedly: $e');
      return PublishResult.failure(unexpectedBlogError('EmDash', e));
    }
  }

  EmDashApi _api(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) {
    if (account.tier == PlatformTier.handoff) {
      throw const AdapterException(PublishError.unsupported('Hand-off accounts publish through the EmDash editor'));
    }
    final site = Uri.tryParse(account.configString('site'));
    if (site == null || site.host.isEmpty) {
      throw const AdapterException(PublishError.configuration('This EmDash account has no site address; reconnect it'));
    }
    final token = OAuthTokens.fromSecrets(secrets)?.accessToken ?? '';
    if (token.isEmpty) {
      throw const AdapterException(PublishError.auth('No EmDash API token stored; reconnect the account'));
    }
    return EmDashApi(site, ctx, token: token);
  }

  Future<PublishResult> _publish(PostVariant v, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final api = _api(account, secrets, ctx);
    final title = (v.title ?? '').trim();
    if (title.isEmpty) throw const AdapterException(PublishError.validation('EmDash posts need a title'));
    final status = _status(v, account);
    final key = emdashPostKey(account, v);
    final prefix = emdashKeyPrefix(key);

    // Files first: nothing shows on the site until the post is published. A
    // sound file is left out, as the composer warned (no audio block in
    // EmDash's Portable Text).
    final images = <EmDashMedia>[];
    final videos = <EmDashMedia>[];
    final media = v.media.where((m) => !m.isAudio).toList();
    if (media.length < v.media.length) ctx.log.info('EmDash takes no sound files; ${v.media.length - media.length} left out');
    for (var i = 0; i < media.length; i++) {
      final uploaded = await _upload(api, media[i], i, media.length, ctx);
      (media[i].isVideo ? videos : images).add(uploaded);
    }
    final useFeatured = v.extra['featuredImage'] != false && images.isNotEmpty;
    final featured = useFeatured ? images.first : null;
    final inline = useFeatured ? images.skip(1).toList() : images;

    final content = [
      ...markdownToPortableText(v.text, keyPrefix: prefix),
      for (var i = 0; i < inline.length; i++) inline[i].imageBlock('${prefix}i$i'),
      for (var i = 0; i < videos.length; i++) videos[i].videoBlock('${prefix}v$i'),
    ];
    final tags = await _tagSlugs(api, v.tags, ctx);
    final excerpt = blogStr(v.extra['excerpt']);
    final data = <String, Object?>{
      'title': title,
      'content': content,
      'excerpt': ?excerpt,
      if (featured != null) 'featured_image': featured.mediaValue(),
    };
    final slug = emdashSlug(blogStr(v.extra['slug']) ?? title);
    final (post, resumed) = await _createOnce(api, data, slug, key, tags.slugs, status, ctx);
    final postId = blogStr(post['id']);
    if (postId == null) throw const AdapterException(PublishError.platform('EmDash did not return the created post'));
    final finalSlug = blogStr(post['slug']) ?? slug;

    if (status == 'draft') {
      ctx.log.info('EmDash draft $postId saved');
      return PublishResult.ok(
        remoteId: postId,
        remoteUrl: joinPath(api.site, '$emdashAdminBase/content/$emdashPostsCollection/$postId').toString(),
        publishedAt: ctx.now(),
        notice: _notice(resumed, tags.skipped),
      );
    }
    if (post['status'] != 'published') {
      await guardEmDash(
          'Publishing the EmDash post',
          () => ctx.creating('Publishing the post',
              () => api.postJson('content/$emdashPostsCollection/${Uri.encodeComponent(postId)}/publish', const <String, Object?>{})));
    }
    final url = joinPath(api.site, '/posts/${Uri.encodeComponent(finalSlug)}').toString();
    ctx.log.info('EmDash post $postId published at $url');
    return PublishResult.ok(remoteId: postId, remoteUrl: url, publishedAt: ctx.now(), notice: _notice(resumed, tags.skipped));
  }

  static String? _notice(bool resumed, bool tagsSkipped) {
    final parts = [
      if (resumed) 'NEFORUM found this post from an earlier try and finished it instead of posting it twice.',
      if (tagsSkipped) 'The tags were left out: this EmDash site has no Tags taxonomy.',
    ];
    return parts.isEmpty ? null : parts.join(' ');
  }

  /// Creates the post as a draft under [slug], or finds the one an earlier
  /// try made. Returns the post and whether it was found rather than made.
  ///
  /// The slug is taken (`409 SLUG_CONFLICT`): the post under it is read, and
  /// when its Portable Text keys carry this post's mark it is this post. A
  /// different post holds the slug: the slug with the start of the post's key
  /// is tried once, the same way, so a retry walks the same two slugs.
  Future<(Map<String, dynamic>, bool)> _createOnce(EmDashApi api, Map<String, Object?> data, String slug, String key,
      List<String> tags, String status, AdapterContext ctx) async {
    final prefix = emdashKeyPrefix(key);
    for (final candidate in [slug, emdashFallbackSlug(slug, key)]) {
      final body = <String, Object?>{
        'data': data,
        'slug': candidate,
        if (tags.isNotEmpty) 'taxonomies': {emdashTagTaxonomy: tags},
      };
      Future<NeforumResponse> send() => api.postJson('content/$emdashPostsCollection', body);
      try {
        // A draft is the post itself when the account publishes as draft; else
        // it is not live yet, and the publish call is the one that posts.
        final r = await (status == 'draft' ? ctx.creating('Saving the draft', send) : send());
        final item = blogMap(emdashData(r)['item']);
        if (item == null) throw AdapterException(PublishError.platform('EmDash did not return the created post', raw: bodySnippet(r)));
        return (item, false);
      } on HttpFailure catch (f) {
        if (f.statusCode != 409 || emdashErrorOf(f.response).$1 != 'SLUG_CONFLICT') {
          throw AdapterException(mapEmDashFailure(f, 'EmDash post'));
        }
      } on AdapterException {
        rethrow;
      } on Exception catch (e) {
        throw AdapterException(PublishError.network('EmDash post failed: ${NeforumHttp.transportMessage(e)}', raw: NeforumHttp.transportDetails(e)));
      }
      final existing = await _postBySlug(api, candidate);
      if (existing != null && emdashCarriesMark(existing, prefix, data['title'] as String, fallbackSlug: candidate != slug)) {
        ctx.log.info('EmDash post ${existing['id']} under "$candidate" is this post from an earlier try; finishing it');
        return (existing, true);
      }
      ctx.log.info('The slug "$candidate" belongs to another EmDash post');
    }
    throw AdapterException(PublishError.validation(
        'EmDash already has posts at /posts/$slug and /posts/${emdashFallbackSlug(slug, key)}. Set another slug for this post.'));
  }

  Future<Map<String, dynamic>?> _postBySlug(EmDashApi api, String slug) async {
    try {
      final r = await api.get('content/$emdashPostsCollection/${Uri.encodeComponent(slug)}');
      return blogMap(emdashData(r)['item']);
    } on HttpFailure catch (f) {
      if (f.statusCode == 404) return null;
      throw AdapterException(mapEmDashFailure(f, 'Reading the EmDash post at /posts/$slug'));
    } on Exception catch (e) {
      throw AdapterException(PublishError.network('Reading the EmDash post at /posts/$slug failed: ${NeforumHttp.transportMessage(e)}',
          raw: NeforumHttp.transportDetails(e)));
    }
  }

  /// The tag slugs for [tags]: an existing tag matched by slug or name, a
  /// new one made. `skipped` when the site has no tag taxonomy.
  Future<({List<String> slugs, bool skipped})> _tagSlugs(EmDashApi api, List<String> tags, AdapterContext ctx) async {
    final wanted = <String>[];
    for (final t in tags) {
      final name = t.trim().replaceFirst(RegExp('^#+'), '').trim();
      if (name.isNotEmpty && !wanted.any((w) => w.toLowerCase() == name.toLowerCase())) wanted.add(name);
    }
    if (wanted.isEmpty) return (slugs: const <String>[], skipped: false);
    ctx.progress('Checking the tags');
    final List<Map<String, dynamic>> terms;
    try {
      final r = await api.get('taxonomies/$emdashTagTaxonomy/terms', const {'includeCounts': 'false'});
      terms = _flattenTerms(blogList(emdashData(r)['terms']));
    } on HttpFailure catch (f) {
      final code = emdashErrorOf(f.response).$1;
      if (f.statusCode == 404 && code != '') {
        ctx.log.warn('EmDash has no "$emdashTagTaxonomy" taxonomy ($code); posting without tags');
        return (slugs: const <String>[], skipped: true);
      }
      throw AdapterException(mapEmDashFailure(f, 'Reading the EmDash tags'));
    } on Exception catch (e) {
      throw AdapterException(PublishError.network('Reading the EmDash tags failed: ${NeforumHttp.transportMessage(e)}', raw: NeforumHttp.transportDetails(e)));
    }
    // Two names of one tag ("webdev" and "Web Development") are one tag.
    final slugs = <String>{};
    for (final name in wanted) {
      final slug = emdashSlug(name);
      final match = terms.where((t) => t['slug'] == slug || '${t['label']}'.toLowerCase() == name.toLowerCase()).firstOrNull;
      if (match != null) {
        slugs.add('${match['slug']}');
        continue;
      }
      try {
        final r = await api.postJson('taxonomies/$emdashTagTaxonomy/terms', {'slug': slug, 'label': name});
        slugs.add(blogStr(blogMap(emdashData(r)['term'])?['slug']) ?? slug);
        terms.add({'slug': slug, 'label': name});
        ctx.log.info('EmDash tag "$name" made');
      } on HttpFailure catch (f) {
        // Made in the meantime (by an earlier try or someone else): it is there.
        if (f.statusCode != 409) throw AdapterException(mapEmDashFailure(f, 'Making the EmDash tag "$name"'));
        slugs.add(slug);
      } on Exception catch (e) {
        throw AdapterException(PublishError.network('Making the EmDash tag "$name" failed: ${NeforumHttp.transportMessage(e)}',
            raw: NeforumHttp.transportDetails(e)));
      }
    }
    return (slugs: slugs.toList(), skipped: false);
  }

  static List<Map<String, dynamic>> _flattenTerms(List<Object?> terms) => [
        for (final t in terms)
          if (blogMap(t) case final m?) ...[m, ..._flattenTerms(blogList(m['children']))],
      ];

  Future<EmDashMedia> _upload(EmDashApi api, MediaAttachment m, int index, int total, AdapterContext ctx) async {
    final kind = m.isVideo ? 'video' : 'photo';
    ctx.uploading(m, 'Uploading $kind ${index + 1} of $total');
    final bytes = await ctx.readMedia(m);
    final what = 'EmDash $kind upload ${index + 1}/$total';
    final alt = (m.altText ?? '').trim();
    final r = await guardEmDash(what,
        () => api.uploadMedia(bytes, fileName: safeFileName(m), contentType: m.mimeType, alt: alt, width: m.width, height: m.height));
    final item = blogMap(emdashData(r)['item']);
    final id = blogStr(item?['id']);
    final url = blogStr(item?['url']);
    if (item == null || id == null || url == null) {
      throw AdapterException(PublishError.platform('$what: EmDash did not return the file', raw: bodySnippet(r)));
    }
    return EmDashMedia(
      id: id,
      url: url,
      alt: alt,
      filename: blogStr(item['filename']) ?? safeFileName(m),
      mimeType: blogStr(item['mimeType']) ?? m.mimeType,
      width: blogInt(item['width']) ?? m.width,
      height: blogInt(item['height']) ?? m.height,
      blurhash: blogStr(item['blurhash']),
      dominantColor: blogStr(item['dominantColor']),
    );
  }

  // ---------------------------------------------------------------- hand-off

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final siteRaw = account?.configString('site') ?? '';
    final site = siteRaw.isEmpty ? null : Uri.tryParse(siteRaw);
    final editor = site == null || site.host.isEmpty
        ? null
        : joinPath(site, '$emdashAdminBase/content/$emdashPostsCollection/new').toString();
    final title = (variant.title ?? '').trim();
    final text = fullText(variant);
    final steps = <String>[
      editor == null ? 'Open your EmDash admin and start a new post.' : 'NEFORUM opens a new post in your EmDash admin (sign in if asked).',
      if (title.isNotEmpty) 'Type the title: "$title".',
      'Paste the text from the clipboard into the content.',
      if (variant.hasMedia) 'Add your photos (the first one as the featured image).',
      if (variant.tags.isNotEmpty) 'Add the tags ${variant.tags.join(', ')}, then press **Publish**.' else 'Press **Publish**.',
    ];
    return HandoffPlan(
      platformId: id,
      clipboardText: text,
      shareText: title.isEmpty ? text : '$title\n\n$text',
      shareFiles: variant.media,
      desktopUrl: editor,
      preferred: HandoffMethod.manual,
      instructions: [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n'),
      mediaNote: variant.hasMedia ? 'EmDash\'s editor cannot be filled in from a link; add the photos in the editor yourself.' : null,
    );
  }
}

/// A file in the EmDash media library, as the post refers to it.
class EmDashMedia {
  const EmDashMedia({
    required this.id,
    required this.url,
    required this.filename,
    required this.mimeType,
    this.alt = '',
    this.width,
    this.height,
    this.blurhash,
    this.dominantColor,
  });

  /// The media library id (`_ref` in Portable Text, `id` in a field).
  final String id;

  /// The file's address on the site, as EmDash gives it
  /// (`/_emdash/api/media/file/{storage key}`).
  final String url;
  final String filename;
  final String mimeType;
  final String alt;
  final int? width;
  final int? height;
  final String? blurhash;
  final String? dominantColor;

  /// The value of an image field such as `featured_image` (EmDash's
  /// `MediaValue`, as its admin stores a library pick).
  Map<String, Object?> mediaValue() => {
        'provider': 'local',
        'id': id,
        'src': url,
        'filename': filename,
        'mimeType': mimeType,
        'width': ?width,
        'height': ?height,
        if (alt.isNotEmpty) 'alt': alt,
        'blurhash': ?blurhash,
        'dominantColor': ?dominantColor,
      };

  /// A Portable Text `image` block.
  Map<String, Object?> imageBlock(String key) => {
        '_type': 'image',
        '_key': key,
        'asset': {'_ref': id, 'url': url},
        if (alt.isNotEmpty) 'alt': alt,
        'width': ?width,
        'height': ?height,
        'blurhash': ?blurhash,
        'dominantColor': ?dominantColor,
      };

  /// A Portable Text `video` block.
  Map<String, Object?> videoBlock(String key) => {
        '_type': 'video',
        '_key': key,
        'asset': {'_ref': id, 'url': url},
        'width': ?width,
        'height': ?height,
      };
}

/// The key that tells this post apart from every other: made from the
/// account, the NEFORUM post and what is posted, so a retry of the same post
/// gets the same key and an edited post a new one. Random when the variant
/// has no source post, which only a direct call does.
String emdashPostKey(ConnectedAccount account, PostVariant v) {
  final src = v.sourcePostId;
  if (src == null) {
    final r = Random.secure();
    return [for (var i = 0; i < 32; i++) r.nextInt(16).toRadixString(16)].join();
  }
  final media = v.media.map((m) => m.id).join(',');
  final digest = sha256.convert(utf8.encode('neforum|emdash|${account.id}|$src|${v.title ?? ''}|${v.text}|${v.tags.join(',')}|$media'));
  return digest.toString();
}

/// The start of every Portable Text key in the post: the mark that lets a
/// retry know the post again.
String emdashKeyPrefix(String postKey) => 'nf${postKey.substring(0, 10)}';

/// The slug tried when [slug] belongs to another post: the slug and the
/// start of the post's key.
String emdashFallbackSlug(String slug, String postKey) {
  final runes = slug.runes.toList();
  final head = runes.length > 72 ? String.fromCharCodes(runes.take(72)).replaceAll(RegExp(r'-+$'), '') : slug;
  return '$head-${postKey.substring(0, 6)}';
}

/// Whether [item] is the post made under [keyPrefix]: one of its content
/// keys carries the mark. A post with no content can only be told by its
/// title, which is enough under the [fallbackSlug], which holds the key.
bool emdashCarriesMark(Map<String, dynamic> item, String keyPrefix, String title, {required bool fallbackSlug}) {
  final data = blogMap(item['data']) ?? const {};
  final content = blogList(data['content']);
  if (content.any((b) => '${blogMap(b)?['_key'] ?? ''}'.startsWith(keyPrefix))) return true;
  return fallbackSlug && content.isEmpty && data['title'] == title;
}

/// A URL slug the way EmDash makes one (`@emdash-cms/admin/slugify`):
/// NFKC, lower case, spaces and underscores to hyphens, only letters,
/// numbers, marks and hyphens, at most 80 characters. Text with no letter or
/// number gets `post-` and a hash.
String emdashSlug(String text) {
  final slug = nfkc(text)
      .toLowerCase()
      .replaceAll(RegExp(r'[\s_]+', unicode: true), '-')
      .replaceAll(RegExp(r'[^\p{L}\p{N}\p{M}-]+', unicode: true), '')
      .replaceAll(RegExp('-+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (!RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(slug)) {
    return 'post-${sha256.convert(utf8.encode(text)).toString().substring(0, 8)}';
  }
  final runes = slug.runes.toList();
  if (runes.length <= 80) return slug;
  return String.fromCharCodes(runes.take(80)).replaceAll(RegExp(r'-+$'), '');
}
