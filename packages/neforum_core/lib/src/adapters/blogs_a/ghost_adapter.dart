import '../../audio/audio_publishing.dart';
import '../../audio/audio_text_template.dart';
import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../model/account.dart';
import '../../model/audio.dart';
import '../../model/media.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post.dart' show Visibility;
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../../text/rules_validator.dart';
import '../adapter_context.dart';
import '../audio_links.dart' show audioCoverUploadPart, mayRetryWithoutThumbnail;
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'blog_common.dart';
import 'ghost_api.dart';

/// Post statuses the Ghost Admin API accepts.
const Set<String> ghostStatuses = {'published', 'draft', 'scheduled'};

/// Values of the Ghost post `visibility` field.
const Set<String> ghostVisibilities = {'public', 'members', 'paid', 'tiers'};

/// Ghost post titles are limited to 255 characters.
const int ghostTitleMax = 255;

/// Adapter for Ghost (self-hosted or Ghost(Pro)) through the Admin API with
/// a custom-integration Admin API key.
///
/// Every request carries a freshly minted 5-minute JWT, so nothing ever
/// needs refreshing. Publish: `POST images/upload/` per image and
/// `POST media/upload/` per sound file, then `POST posts/?source=html`.
/// The first image becomes the feature image.
class GhostAdapter extends PlatformAdapter {
  static const Set<String> _imageTypes = {'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/svg+xml'};

  /// Sound types Ghost's media upload takes (MP3, WAV, Ogg, M4A): no FLAC or
  /// AIFF.
  static const Set<String> _audioTypes = {AudioMimeTypes.mp3, AudioMimeTypes.wav, AudioMimeTypes.ogg, AudioMimeTypes.m4a};

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'ghost',
    name: 'Ghost',
    iconKey: 'ghost',
    homepage: 'https://ghost.org',
    tiers: {PlatformTier.openApi, PlatformTier.handoff},
    defaultTier: PlatformTier.openApi,
    text: TextRules(
      maxLength: null,
      counting: CountingRule.utf16,
      titleSupported: true,
      titleRequired: true,
      titleMax: ghostTitleMax,
      supportsThreads: false,
      supportsContentWarning: false,
      supportsHtml: true,
      supportsHashtags: true,
      hashtagsAsField: true,
      linkInText: true,
      notes: 'No length limit. Text is converted to HTML (blank line = new paragraph, URLs become links) and Ghost turns '
          'it into editor cards. Tags go into the Ghost tags field; unknown tags are created automatically.',
    ),
    media: MediaRules(
      maxImages: 20,
      maxVideos: 0,
      imageMimeTypes: _imageTypes,
      supportsAltText: true,
      notes: 'Images (JPEG, PNG, GIF, WEBP, SVG) and sound files (MP3, WAV, Ogg, M4A); no video. Ghost sets no per-post '
          'limit; 20 is NEFORUM\'s. The first image becomes the feature image, the others are placed in the post, and '
          'sound files play in an HTML card. File size limits depend on your Ghost setup.',
      maxAudios: 5,
      audioMimeTypes: _audioTypes,
      keepsAudioBytes: true,
      audioWithOtherMedia: true,
    ),
    defaultQuotas: [],
    personalAccountOk: true,
    accountRequirements: 'A Ghost site where you are Owner or Administrator (to create a custom integration). Self-hosted '
        'Ghost works on any setup; on Ghost(Pro) custom integrations are included in the Publisher, Business and Custom '
        'plans, not in Starter.',
    apiCostSummary: 'Free on self-hosted Ghost. On Ghost(Pro) the Admin API needs the Publisher plan or higher (not '
        'Starter). Ghost does not publish an API quota.',
    setupGuide: 'docs/platforms/ghost.md',
    serverSideScheduling: true,
    supportsLinkField: false,
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.openApi,
          intro: '**Ghost needs no developer account**, only a *custom integration* on your own site:\n\n'
              '1. Open your Ghost admin (`https://your-site/ghost/`) and go to **Settings > Advanced > Integrations** '
              '(older versions: **Settings > Integrations**).\n'
              '2. Press **Add custom integration**, name it `NEFORUM` and press **Create**.\n'
              '3. Copy the **API URL** and the **Admin API key** (not the Content API key) into the fields below.\n\n'
              'Ghost(Pro): custom integrations are available on the Publisher plan and above, not on Starter. '
              'Self-hosted Ghost has no such restriction. Nothing is sent to your newsletter subscribers.',
          fields: [
            ConnectField(
              key: 'apiUrl',
              label: 'API URL',
              kind: FieldKind.url,
              placeholder: 'https://your-site.ghost.io',
              help: 'Shown on the integration page. It can differ from your public address (e.g. `*.ghost.io`).',
            ),
            ConnectField(
              key: 'adminKey',
              label: 'Admin API key',
              kind: FieldKind.password,
              secret: true,
              help: 'The long key with a colon in the middle, from the same integration page. Keep it private: it can '
                  'edit everything on your site.',
            ),
            ConnectField(
              key: 'defaultStatus',
              label: 'Publish as',
              kind: FieldKind.select,
              required: false,
              options: ['published', 'draft'],
              defaultValue: 'published',
              help: '`published` makes the post live immediately; `draft` leaves it in Ghost for you to finish.',
            ),
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.handoff,
          intro: 'For Ghost(Pro) Starter, which has no integrations: NEFORUM copies the post to the clipboard and opens the Ghost '
              'editor, where you paste it and press **Publish**.',
          fields: [
            ConnectField(
              key: 'site',
              label: 'Site address',
              kind: FieldKind.url,
              placeholder: 'https://your-site.ghost.io',
              help: 'The address you use to open Ghost admin (without /ghost/).',
            ),
          ],
        ),
      ];

  // ---------------------------------------------------------------- connect

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier == PlatformTier.handoff) {
      final site = parseBlogSiteUrl(input['site'] ?? '');
      return ConnectResult(
        account: ConnectedAccount(
          id: 'ghost-handoff:${site.host}${site.path}',
          platformId: id,
          tier: PlatformTier.handoff,
          displayName: '${site.host} (hand-off)',
          profileUrl: site.toString(),
          createdAt: ctx.now(),
          config: {'site': site.toString()},
        ),
      );
    }
    final apiUrl = parseBlogSiteUrl(input['apiUrl'] ?? '', field: 'apiUrl', what: 'Ghost API URL');
    final key = parseGhostKeyForConnect(input['adminKey'] ?? '');
    final site = await _siteInfo(apiUrl, ctx);
    await _checkKey(apiUrl, key, ctx);
    final title = blogStr(site['title']) ?? apiUrl.host;
    final publicUrl = blogStr(site['url']) ?? apiUrl.toString();
    final status = (input['defaultStatus'] ?? '').trim();
    return ConnectResult(
      account: ConnectedAccount(
        id: 'ghost:${apiUrl.host}${apiUrl.path}:${key.id}',
        platformId: id,
        tier: PlatformTier.openApi,
        displayName: title,
        handle: Uri.tryParse(publicUrl)?.host ?? apiUrl.host,
        avatarUrl: blogStr(site['icon']) ?? blogStr(site['logo']),
        profileUrl: publicUrl,
        createdAt: ctx.now(),
        config: {
          'apiUrl': apiUrl.toString(),
          'site': publicUrl,
          'siteTitle': title,
          'keyId': key.id,
          if (blogStr(site['version']) != null) 'version': blogStr(site['version']),
          if (status == 'published' || status == 'draft') 'defaultStatus': status,
        },
      ),
      secrets: {'admin_api_key': '${key.id}:${key.secretHex}'},
    );
  }

  Future<Map<String, dynamic>> _siteInfo(Uri apiUrl, AdapterContext ctx) async {
    ctx.progress('Contacting ${apiUrl.host}');
    try {
      final r = await GhostApi(apiUrl, ctx).get('site/');
      final site = blogMap(r.jsonMap['site']);
      if (site == null) throw const FormatException('no site object');
      return site;
    } on HttpFailure catch (f) {
      throw ConnectException(f.statusCode == 404
          ? '${apiUrl.host} has no Ghost Admin API. Copy the API URL exactly as shown on the integration page.'
          : '${apiUrl.host} answered HTTP ${f.statusCode}. Check the API URL and try again.', field: 'apiUrl');
    } on FormatException {
      throw ConnectException('${apiUrl.host} does not look like a Ghost site.', field: 'apiUrl');
    } on Exception catch (e) {
      throw ConnectException('Could not reach ${apiUrl.host}: $e', field: 'apiUrl');
    }
  }

  Future<void> _checkKey(Uri apiUrl, GhostAdminKey key, AdapterContext ctx) async {
    ctx.progress('Checking the Admin API key');
    try {
      await GhostApi(apiUrl, ctx, key: key).get('posts/', {'limit': '1'});
    } on HttpFailure catch (f) {
      final (_, message, _) = ghostErrorOf(f.response);
      if (f.statusCode == 401 || f.statusCode == 403) {
        throw ConnectException('Ghost rejected the Admin API key${message == null ? '' : ' ($message)'}. Copy the Admin '
            'API key again (not the Content API key) and check that this device\'s clock is correct.', field: 'adminKey');
      }
      throw ConnectException('${apiUrl.host} answered HTTP ${f.statusCode} while checking the key.');
    } on Exception catch (e) {
      throw ConnectException('Could not reach ${apiUrl.host}: $e');
    }
  }

  // --------------------------------------------------------------- validate

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = RulesValidator.validate(variant, descriptor, tier: account.tier);
    if (account.tier == PlatformTier.handoff) {
      if (variant.hasMedia) {
        issues.add(const ValidationIssue.warning('ghost.handoff_media',
            'Ghost\'s editor cannot receive files from NEFORUM; add the images yourself', field: 'media'));
      }
      return issues;
    }
    final explicit = blogStr(variant.extra['status']);
    if (explicit != null && !ghostStatuses.contains(explicit)) {
      issues.add(ValidationIssue.error('ghost.bad_status',
          'Unknown Ghost status "$explicit" (use published, draft or scheduled)', field: 'extra'));
    }
    if (explicit == 'scheduled' && variant.scheduledAt == null) {
      issues.add(const ValidationIssue.error('ghost.schedule_without_date',
          'A scheduled Ghost post needs a date; set one or choose published/draft', field: 'scheduledAt'));
    }
    if (variant.scheduledAt != null && _status(variant, account) != 'scheduled') {
      // Ghost only publishes `scheduled` posts by itself; a draft keeps its date and stays a draft.
      issues.add(const ValidationIssue.error('ghost.cannot_schedule',
          'Ghost can only hold posts that it will publish; a draft cannot be scheduled on the site', field: 'scheduledAt'));
    }
    final vis = blogStr(variant.extra['ghostVisibility']);
    if (vis != null && !ghostVisibilities.contains(vis)) {
      issues.add(ValidationIssue.error('ghost.bad_visibility',
          'Unknown Ghost visibility "$vis" (use public, members, paid or tiers)', field: 'extra'));
    }
    if (variant.visibility == Visibility.unlisted) {
      issues.add(const ValidationIssue.warning('ghost.unlisted',
          'Ghost has no unlisted posts; this one will be public', field: 'visibility'));
    } else if (variant.visibility == Visibility.followers || variant.visibility == Visibility.private) {
      issues.add(const ValidationIssue.info('ghost.members_only',
          'The post will be visible to signed-in members only', field: 'visibility'));
    }
    return issues;
  }

  String _status(PostVariant v, ConnectedAccount account) {
    final explicit = blogStr(v.extra['status']);
    var status = explicit != null && ghostStatuses.contains(explicit)
        ? explicit
        : (account.configString('defaultStatus', 'published') == 'draft' ? 'draft' : 'published');
    if (status == 'published' && v.scheduledAt != null) status = 'scheduled';
    return status;
  }

  String _visibility(PostVariant v) {
    final explicit = blogStr(v.extra['ghostVisibility']);
    if (explicit != null && ghostVisibilities.contains(explicit)) return explicit;
    return switch (v.visibility) {
      Visibility.public || Visibility.unlisted => 'public',
      Visibility.followers || Visibility.private => 'members',
    };
  }

  // ---------------------------------------------------------------- publish

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    try {
      return await _publish(variant, account, secrets, ctx);
    } on AdapterException catch (e) {
      ctx.log.warn('Ghost publish failed: ${e.error.message}');
      return PublishResult.failure(e.error);
    } on Exception catch (e) {
      ctx.log.warn('Ghost publish failed unexpectedly: $e');
      return PublishResult.failure(unexpectedBlogError('Ghost', e));
    }
  }

  /// Admin API client for an API-tier account; throws [AdapterException]
  /// when the account or its key is missing.
  GhostApi _api(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) {
    if (account.tier == PlatformTier.handoff) {
      throw const AdapterException(PublishError.unsupported('Hand-off accounts publish through the Ghost editor'));
    }
    final apiUrl = Uri.tryParse(account.configString('apiUrl'));
    if (apiUrl == null || apiUrl.host.isEmpty) {
      throw const AdapterException(PublishError.configuration('This Ghost account has no API URL; reconnect it'));
    }
    final GhostAdminKey key;
    try {
      key = GhostAdminKey.parse(secrets['admin_api_key'] ?? '');
    } on FormatException {
      throw const AdapterException(PublishError.auth('No valid Ghost Admin API key stored; reconnect the account'));
    }
    return GhostApi(apiUrl, ctx, key: key);
  }

  Future<PublishResult> _publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final api = _api(account, secrets, ctx);
    final title = (variant.title ?? '').trim();
    if (title.isEmpty) throw const AdapterException(PublishError.validation('Ghost posts need a title'));
    if (variant.media.any((m) => m.isVideo)) {
      throw const AdapterException(
          PublishError.unsupported('NEFORUM can only upload images to Ghost; remove the video or add it in Ghost'));
    }

    final images = <(MediaAttachment, String)>[];
    final sounds = <(MediaAttachment, String, String?)>[];
    final media = variant.media;
    for (var i = 0; i < media.length; i++) {
      final m = media[i];
      if (m.isAudio) {
        final (url, thumbnail) = await _uploadAudio(api, m, i, media.length, ctx);
        sounds.add((m, url, thumbnail));
      } else {
        images.add((m, await _upload(api, m, i, media.length, ctx)));
      }
    }
    final wholeHtmlCard = variant.extra['ghostHtmlCard'] == true;
    final useFeature = variant.extra['featuredImage'] != false && images.isNotEmpty;
    final feature = useFeature ? images.first : null;
    final inline = useFeature ? images.skip(1) : images;

    var html = [
      bodyHtml(variant),
      for (final (m, url) in inline) mediaFigureHtml(m, url, imageClass: 'kg-card kg-image-card'),
      for (final (m, url, thumbnail) in sounds)
        ghostAudioHtml(url,
            htmlCard: !wholeHtmlCard,
            caption: m.audioTags == null ? null : renderAudioText(kDefaultAudioTextTemplate, m.audioTags!),
            thumbnailUrl: thumbnail),
    ].where((s) => s.isNotEmpty).join('\n\n');
    if (wholeHtmlCard && html.isNotEmpty) {
      html = '<!--kg-card-begin: html-->\n$html\n<!--kg-card-end: html-->';
    }
    final status = _status(variant, account);
    final at = variant.scheduledAt;
    final excerpt = blogStr(variant.extra['excerpt']);
    final canonical = blogStr(variant.extra['canonicalUrl']);
    final slug = blogStr(variant.extra['slug']);
    final featureAlt = (feature?.$1.altText ?? '').trim();
    final post = <String, Object?>{
      'title': title,
      'html': html,
      'status': status,
      'visibility': _visibility(variant),
      if (at != null && status != 'draft') 'published_at': at.toUtc().toIso8601String(),
      if (variant.tags.isNotEmpty) 'tags': [for (final t in variant.tags) {'name': t}],
      if (feature != null) 'feature_image': feature.$2,
      if (feature != null && featureAlt.isNotEmpty) 'feature_image_alt': featureAlt,
      'custom_excerpt': ?excerpt,
      'canonical_url': ?canonical,
      'slug': ?slug,
    };
    ctx.progress(status == 'scheduled' ? 'Scheduling the post' : 'Publishing the post');
    final r = await guardGhost('Ghost post', () => api.postJson('posts/', {
          'posts': [post],
        }, {'source': 'html'}));
    final created = blogMap(blogList(r.jsonMap['posts']).firstOrNull);
    final postId = blogStr(created?['id']);
    if (created == null || postId == null) {
      throw AdapterException(PublishError.platform('Ghost did not return the created post', raw: bodySnippet(r)));
    }
    final remoteStatus = blogStr(created['status']) ?? status;
    final url = blogStr(created['url']);
    ctx.log.info('Ghost post $postId created with status $remoteStatus');
    if (remoteStatus == 'scheduled') {
      final when = at ?? DateTime.tryParse(blogStr(created['published_at']) ?? '');
      if (when != null) return PublishResult.scheduled(remoteId: postId, scheduledFor: when, remoteUrl: url);
    }
    return PublishResult.ok(remoteId: postId, remoteUrl: url, publishedAt: ctx.now());
  }

  // ------------------------------------------------------------ scheduling

  /// Deletes the `scheduled` post Ghost is holding
  /// (`DELETE /ghost/api/admin/posts/{id}/`, answered with 204). A 404 means
  /// it is already gone.
  @override
  Future<void> cancelScheduled(
      PublishResult held, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final postId = held.remoteId ?? '';
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(postId)) {
      throw const AdapterException(PublishError.configuration(
          'NEFORUM does not know which Ghost post holds this schedule; delete it in Ghost under Posts > Scheduled'));
    }
    final api = _api(account, secrets, ctx);
    ctx.progress('Removing the scheduled Ghost post');
    const what = 'Removing the scheduled Ghost post';
    try {
      await api.delete('posts/$postId/');
      ctx.log.info('Ghost post $postId deleted');
    } on HttpFailure catch (f) {
      // A Ghost NotFoundError means the post is gone; an HTML 404 page means
      // the Admin API was not reached, so the post may still be held.
      if (f.statusCode == 404 && !isHtmlResponse(f.response)) {
        ctx.log.info('Ghost post $postId no longer exists');
        return;
      }
      throw AdapterException(mapGhostFailure(f, what));
    } on Exception catch (e) {
      throw AdapterException(PublishError.network('$what failed: $e', raw: '$e'));
    }
  }

  Future<String> _upload(GhostApi api, MediaAttachment m, int index, int total, AdapterContext ctx) async {
    ctx.progress('Uploading image ${index + 1} of $total');
    final bytes = await readBlogMedia(ctx, m);
    final what = 'Ghost image upload ${index + 1}/$total';
    final r = await guardGhost(what, () => api.uploadImage(bytes, fileName: safeFileName(m), contentType: m.mimeType));
    final url = blogStr(blogMap(blogList(r.jsonMap['images']).firstOrNull)?['url']);
    if (url == null) {
      throw AdapterException(PublishError.platform('$what: Ghost did not return an image URL', raw: bodySnippet(r)));
    }
    return url;
  }

  /// Uploads a sound file, with its cover as the thumbnail; returns its URL
  /// and the thumbnail's (null when there is none or Ghost kept none).
  Future<(String, String?)> _uploadAudio(GhostApi api, MediaAttachment m, int index, int total, AdapterContext ctx) async {
    ctx.progress('Uploading sound file ${index + 1} of $total');
    final bytes = await readBlogMedia(ctx, m);
    final thumbnail = await audioCoverUploadPart(m, ctx);
    final what = 'Ghost sound file upload ${index + 1}/$total';
    final fileName = m.audioTaggedFileName ?? safeFileName(m);
    final r = await guardGhost(what, () async {
      try {
        return await api.uploadMedia(bytes, fileName: fileName, contentType: m.mimeType, thumbnail: thumbnail);
      } on HttpFailure catch (f) {
        // A site that refuses the cover still gets the sound file.
        if (thumbnail == null || !mayRetryWithoutThumbnail(f.statusCode)) rethrow;
        ctx.log.warn('Ghost refused the upload of ${m.fileName ?? m.id} with its cover (HTTP ${f.statusCode}); trying without the cover');
        return api.uploadMedia(bytes, fileName: fileName, contentType: m.mimeType);
      }
    });
    final uploaded = blogMap(blogList(r.jsonMap['media']).firstOrNull);
    final url = blogStr(uploaded?['url']);
    if (url == null) {
      throw AdapterException(PublishError.platform('$what: Ghost did not return a file URL', raw: bodySnippet(r)));
    }
    return (url, blogStr(uploaded?['thumbnail_url']));
  }

  // ---------------------------------------------------------------- hand-off

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final siteRaw = account == null
        ? ''
        : (account.configString('apiUrl').isNotEmpty ? account.configString('apiUrl') : account.configString('site'));
    final title = (variant.title ?? '').trim();
    final text = fullText(variant);
    final editor = siteRaw.isEmpty ? null : '${Uri.parse(siteRaw)}/ghost/#/editor/post';
    final steps = <String>[
      editor == null
          ? 'Open your Ghost admin and start a new post.'
          : 'NEFORUM opens a new post in your Ghost editor (sign in if asked).',
      if (title.isNotEmpty) 'Type the title: "$title".',
      'Paste the text from the clipboard into the body.',
      if (variant.hasMedia) 'Add your images (+ button, or the feature image above the title).',
      if (variant.tags.isNotEmpty) 'Add the tags ${variant.tags.join(', ')} in the post settings, then press **Publish**.'
      else 'Press **Publish**.',
    ];
    return HandoffPlan(
      platformId: id,
      clipboardText: text,
      shareText: title.isEmpty ? text : '$title\n\n$text',
      shareFiles: variant.media,
      desktopUrl: editor,
      preferred: HandoffMethod.manual,
      instructions: [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n'),
      mediaNote: variant.hasMedia
          ? 'Ghost\'s editor cannot be prefilled from a link and has no mobile app share target; upload the images in '
              'the editor yourself.'
          : null,
    );
  }
}

/// A player for an uploaded sound file at [url]. Ghost's HTML import drops
/// an `<audio>` element it does not recognise, so it goes in an HTML card
/// ([htmlCard]) unless the whole post already is one. The track's cover
/// ([thumbnailUrl]) goes above the player and its details ([caption])
/// below it.
String ghostAudioHtml(String url, {bool htmlCard = true, String? caption, String? thumbnailUrl}) {
  final cover = thumbnailUrl == null
      ? ''
      : '<img class="kg-audio-thumbnail" src="${escapeHtml(thumbnailUrl)}" alt="${escapeHtml(caption ?? '')}" loading="lazy">';
  final details = caption == null || caption.isEmpty ? '' : '<figcaption>${escapeHtml(caption)}</figcaption>';
  final player = '<figure class="kg-card kg-audio-card">$cover<audio controls preload="metadata" src="${escapeHtml(url)}"></audio>$details</figure>';
  return htmlCard ? '<!--kg-card-begin: html-->\n$player\n<!--kg-card-end: html-->' : player;
}
