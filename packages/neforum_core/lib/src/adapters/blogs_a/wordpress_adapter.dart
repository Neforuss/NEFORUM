import '../../auth/auth_broker.dart';
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
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'blog_common.dart';
import 'wordpress_api.dart';

/// Stable UUID NEFORUM passes as `app_id` to `authorize-application.php`, so
/// WordPress can show which application passwords belong to NEFORUM.
const String wordPressAppId = '6f1e2c1a-9b7d-4c55-8f7e-3e2b8a5d0c41';

/// Statuses the WordPress posts endpoint accepts from NEFORUM.
const Set<String> wordPressStatuses = {'publish', 'draft', 'pending', 'private', 'future'};

/// Longest prefilled body NEFORUM puts into a hand-off URL; longer posts go
/// through the clipboard only (many servers refuse URLs over ~8 KB).
const int _maxIntentChars = 6000;

/// Adapter for self-hosted WordPress (5.6+) through the core REST API with
/// an Application Password.
///
/// Connect: site URL + username + application password (or, when the
/// password is left empty, WordPress's own "Authorize application" page in
/// the browser). Publish: one `POST /wp/v2/media` per file, tag/category
/// resolution, then `POST /wp/v2/posts`. The first image becomes the
/// featured image; the other files are embedded in the content.
class WordPressAdapter extends PlatformAdapter {
  static const Set<String> _imageTypes = {'image/jpeg', 'image/png', 'image/gif', 'image/webp'};
  static const Set<String> _videoTypes = {'video/mp4', 'video/quicktime', 'video/webm'};

  /// Sound types in WordPress's default upload list (wp_get_mime_types): no
  /// AIFF.
  static const Set<String> _audioTypes = {
    AudioMimeTypes.mp3,
    AudioMimeTypes.m4a,
    AudioMimeTypes.wav,
    AudioMimeTypes.ogg,
    AudioMimeTypes.flac,
  };

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'wordpress',
    name: 'WordPress',
    iconKey: 'wordpress',
    homepage: 'https://wordpress.org',
    family: 'wordpress',
    tiers: {PlatformTier.openApi, PlatformTier.handoff},
    defaultTier: PlatformTier.openApi,
    text: TextRules(
      maxLength: null,
      counting: CountingRule.utf16,
      titleSupported: true,
      titleRequired: true,
      supportsThreads: false,
      supportsContentWarning: false,
      supportsHtml: true,
      supportsHashtags: true,
      hashtagsAsField: true,
      linkInText: true,
      notes: 'No length limit. Text is converted to HTML paragraphs (blank line = new paragraph, URLs become links); '
          'set the "html" option to send your own HTML. Tags go into the WordPress tags field and are created when missing.',
    ),
    media: MediaRules(
      maxImages: 20,
      maxVideos: 5,
      allowsMixedImageVideo: true,
      imageMimeTypes: _imageTypes,
      videoMimeTypes: _videoTypes,
      supportsAltText: true,
      notes: 'WordPress itself has no per-post limit (the counts here are NEFORUM\'s). The maximum file size is your '
          'host\'s PHP upload_max_filesize. The first image becomes the featured image; other files are placed in the post. '
          'Sound files go to the media library unchanged and play in an audio block.',
      maxAudios: 5,
      audioMimeTypes: _audioTypes,
      keepsAudioBytes: true,
      audioWithOtherMedia: true,
    ),
    defaultQuotas: [],
    personalAccountOk: true,
    accountRequirements: 'A self-hosted WordPress 5.6 or newer site served over https, and a user with at least the Author '
        'role (Contributors can only submit drafts for review). No developer account or app review is needed.',
    apiCostSummary: 'Free. WordPress has no API quota of its own; your web host may limit uploads or requests.',
    setupGuide: 'docs/platforms/wordpress.md',
    serverSideScheduling: true,
    supportsLinkField: false,
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  static const ConnectField _siteField = ConnectField(
    key: 'site',
    label: 'Site address',
    kind: FieldKind.url,
    placeholder: 'https://example.com',
    help: 'The address of your WordPress site (include the folder if WordPress lives in one, e.g. `https://example.com/blog`).',
  );

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.openApi,
          usesBrowser: true,
          loopbackRedirectOk: false,
          customSchemeRedirectOk: true,
          intro: '**WordPress needs no developer account.** NEFORUM signs in with an *application password*, '
              'a separate password that only works for apps and that you can revoke at any time.\n\n'
              '1. In your WordPress dashboard open **Users > Profile** (or **Users > Your Profile**).\n'
              '2. Scroll to **Application Passwords**, type `NEFORUM` as the name and press **Add New Application Password**.\n'
              '3. Copy the password WordPress shows (spaces do not matter) and paste it below with your WordPress username.\n\n'
              'Or leave the password empty: NEFORUM then opens WordPress\'s **Authorize application** page in your browser '
              'and you press **Yes, I approve of this connection**.\n\n'
              'Your site must use **https://**. If the Application Passwords section is missing, a security plugin or your '
              'host has turned it off.',
          redirectNote: 'Nothing to register. The browser approval returns to neforum://callback; on desktops where that '
              'cannot be caught, NEFORUM asks you to copy the password from the WordPress page instead.',
          fields: [
            _siteField,
            ConnectField(
              key: 'username',
              label: 'WordPress username',
              required: false,
              help: 'The name you log in with (not the display name). Needed when you paste a password.',
            ),
            ConnectField(
              key: 'password',
              label: 'Application password',
              kind: FieldKind.password,
              required: false,
              secret: true,
              help: 'From Users > Profile > Application Passwords. Not your normal login password. '
                  'Leave empty to approve NEFORUM in the browser.',
            ),
            ConnectField(
              key: 'defaultStatus',
              label: 'Publish as',
              kind: FieldKind.select,
              required: false,
              options: ['publish', 'draft', 'pending'],
              defaultValue: 'publish',
              help: '`publish` posts immediately, `draft` keeps it private for you to finish, `pending` submits it for review.',
            ),
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.handoff,
          intro: 'NEFORUM opens the WordPress editor with the title and text filled in; you add images and press '
              '**Publish**. Leave the address empty for WordPress.com (uses its Press This page). '
              'On phones the post can also be shared to the WordPress or Jetpack app.',
          fields: [
            ConnectField(
              key: 'site',
              label: 'Site address (optional)',
              kind: FieldKind.url,
              required: false,
              placeholder: 'https://example.com',
              help: 'Your self-hosted site. Leave empty for WordPress.com.',
            ),
          ],
        ),
      ];

  // ---------------------------------------------------------------- connect

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier == PlatformTier.handoff) return _connectHandoff(input, ctx);
    final typed = parseBlogSiteUrl(input['site'] ?? '');
    ctx.progress('Contacting ${typed.host}');
    final (root, index, site) = await discoverWordPress(typed, ctx);
    final authorizeUrl = applicationPasswordsEndpoint(index);

    var username = (input['username'] ?? '').trim();
    var password = (input['password'] ?? '').trim();
    if (password.isEmpty) {
      if (authorizeUrl == null) {
        final wpCom = site.host.endsWith('.wordpress.com') ? ' WordPress.com sites cannot be connected this way; use Hand-off.' : '';
        throw ConnectException('${site.host} does not offer Application Passwords (the site must use https and the '
            'feature must not be disabled by a plugin). Paste a password if you created one another way.$wpCom',
            field: 'password');
      }
      final creds = await _authorizeInBrowser(authorizeUrl, username, ctx);
      username = creds.$1;
      password = creds.$2;
    }
    if (username.isEmpty) {
      throw const ConnectException('Enter your WordPress username together with the application password.', field: 'username');
    }

    final me = await _verify(root, site, username, password, authorizeUrl != null, ctx);
    final caps = blogMap(me['capabilities']) ?? const <String, dynamic>{};
    if (caps.isNotEmpty && caps['edit_posts'] != true) {
      throw const ConnectException('This WordPress user cannot write posts. Use an account with the Author, Editor '
          'or Administrator role.');
    }
    final userId = blogInt(me['id']);
    final name = blogStr(me['name']) ?? username;
    final siteName = blogStr(index['name']) ?? site.host;
    final home = blogStr(index['home']) ?? blogStr(index['url']) ?? site.toString();
    final avatars = blogMap(me['avatar_urls']);
    final status = (input['defaultStatus'] ?? '').trim();
    return ConnectResult(
      account: ConnectedAccount(
        id: 'wordpress:${userId ?? username}@${site.host}${site.path}',
        platformId: id,
        tier: PlatformTier.openApi,
        displayName: '$name ($siteName)',
        handle: username,
        avatarUrl: avatars == null ? null : blogStr(avatars['96']) ?? blogStr(avatars['48']),
        profileUrl: home,
        createdAt: ctx.now(),
        config: {
          'site': site.toString(),
          'home': home,
          'restBase': root.base,
          'username': username,
          'siteName': siteName,
          'userId': ?userId,
          if (caps.isNotEmpty) 'canPublish': caps['publish_posts'] == true,
          if (caps.isNotEmpty) 'canUpload': caps['upload_files'] == true,
          if (caps.isNotEmpty) 'canManageTerms': caps['manage_categories'] == true,
          if (wordPressStatuses.contains(status)) 'defaultStatus': status,
        },
      ),
      secrets: {'app_password': password.replaceAll(' ', '')},
    );
  }

  ConnectResult _connectHandoff(Map<String, String> input, AdapterContext ctx) {
    final raw = (input['site'] ?? '').trim();
    final site = raw.isEmpty ? null : parseBlogSiteUrl(raw);
    return ConnectResult(
      account: ConnectedAccount(
        id: 'wordpress-handoff:${site == null ? 'wordpress.com' : '${site.host}${site.path}'}',
        platformId: id,
        tier: PlatformTier.handoff,
        displayName: '${site?.host ?? 'WordPress.com'} (hand-off)',
        profileUrl: site?.toString() ?? 'https://wordpress.com',
        createdAt: ctx.now(),
        config: {if (site != null) 'site': site.toString()},
      ),
    );
  }

  /// Sends the user to `authorize-application.php`. Returns (user, password).
  Future<(String, String)> _authorizeInBrowser(Uri authorizeUrl, String username, AdapterContext ctx) async {
    final broker = ctx.broker;
    final manualUrl = authorizeUrl.replace(queryParameters: {
      ...authorizeUrl.queryParameters,
      'app_name': 'NEFORUM',
      'app_id': wordPressAppId,
    });
    if (broker == null) {
      throw ConnectException('Open $manualUrl, approve NEFORUM, then paste the password WordPress shows together '
          'with your username.', field: 'password');
    }
    final redirect = broker.chooseRedirectUri(loopbackOk: false, customSchemeOk: true);
    // WordPress refuses http:// success URLs; a urn: redirect means a
    // paste-code broker, so let WordPress display the password instead.
    final canRedirect = redirect.scheme != 'urn' && redirect.scheme != 'http';
    final url = canRedirect
        ? manualUrl.replace(queryParameters: {
            ...manualUrl.queryParameters,
            'success_url': redirect.toString(),
            'reject_url': redirect.replace(queryParameters: {'success': 'false'}).toString(),
          })
        : manualUrl;
    final Uri back;
    try {
      back = await broker.authorize(url, redirect);
    } on AuthCancelled {
      rethrow;
    } on Object catch (e) {
      ctx.log.warn('WordPress browser approval unavailable: $e');
      throw ConnectException('Browser approval does not work on this device. Open $manualUrl, approve NEFORUM, '
          'then paste the password WordPress shows together with your username.', field: 'password');
    }
    final q = back.queryParameters;
    if (q['success'] == 'false') throw const AuthCancelled('You did not approve NEFORUM on your WordPress site.');
    final password = (q['password'] ?? q['code'] ?? '').trim();
    final user = (q['user_login'] ?? username).trim();
    if (password.isEmpty) throw const AuthCancelled('WordPress did not return an application password.');
    if (user.isEmpty) {
      throw const ConnectException('Enter your WordPress username together with the password.', field: 'username');
    }
    return (user, password);
  }

  Future<Map<String, dynamic>> _verify(
      WordPressRoot root, Uri site, String username, String password, bool appPasswordsOn, AdapterContext ctx) async {
    ctx.progress('Checking your WordPress login');
    final api = WordPressApi(root, ctx, username: username, appPassword: password);
    try {
      final r = await api.get('wp/v2/users/me', {'context': 'edit'});
      return r.jsonMap;
    } on HttpFailure catch (f) {
      final code = blogStr(f.response.jsonMap['code']) ?? '';
      if (f.statusCode == 401 || f.statusCode == 403) {
        final hint = appPasswordsOn
            ? 'Check the username (the login name, not the display name) and create a new application password.'
            : 'Application Passwords seem to be disabled on this site, or a plugin blocks the Authorization header.';
        throw ConnectException('WordPress rejected the login${code.isEmpty ? '' : ' ($code)'}. $hint', field: 'password');
      }
      throw ConnectException('${site.host} answered HTTP ${f.statusCode} while checking the login.');
    } on Exception catch (e) {
      throw ConnectException('Could not reach ${site.host}: $e');
    }
  }

  // --------------------------------------------------------------- validate

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = RulesValidator.validate(variant, descriptor, tier: account.tier);
    if (account.tier == PlatformTier.handoff) {
      if (variant.hasMedia) {
        issues.add(const ValidationIssue.warning('wordpress.handoff_media',
            'The WordPress editor cannot receive files from a link; add the images yourself', field: 'media'));
      }
      return issues;
    }
    final status = _requestedStatus(variant, account);
    if (account.config['canPublish'] == false && (status == 'publish' || status == 'future' || status == 'private')) {
      issues.add(const ValidationIssue.warning('wordpress.cannot_publish',
          'Your WordPress role cannot publish; the post will be submitted for review (pending)', field: 'account'));
    }
    if (variant.hasMedia && account.config['canUpload'] == false) {
      issues.add(const ValidationIssue.error('wordpress.cannot_upload',
          'Your WordPress role cannot upload files; remove the media or use an Author account', field: 'media'));
    }
    final explicit = blogStr(variant.extra['status']);
    if (explicit != null && !wordPressStatuses.contains(explicit)) {
      issues.add(ValidationIssue.error('wordpress.bad_status',
          'Unknown WordPress status "$explicit" (use publish, draft, pending or private)', field: 'extra'));
    }
    if (variant.visibility == Visibility.unlisted || variant.visibility == Visibility.followers) {
      issues.add(const ValidationIssue.warning('wordpress.visibility',
          'WordPress posts are either public or private; this one will be public', field: 'visibility'));
    }
    if (variant.scheduledAt != null) {
      // Only `future` posts are published by WordPress at their date; a
      // draft, pending or private post with a date stays as it is.
      final effective = _status(variant, account);
      if (effective != 'future') {
        issues.add(ValidationIssue.error('wordpress.cannot_schedule',
            'WordPress can only hold posts that it will publish; a "$effective" post cannot be scheduled on the site',
            field: 'scheduledAt'));
      }
    }
    return issues;
  }

  /// The WordPress status for this post: an explicit `extra['status']`, a
  /// delegated schedule (`future`), private visibility, or the account
  /// default.
  String _status(PostVariant v, ConnectedAccount account) {
    final status = _requestedStatus(v, account);
    if (account.config['canPublish'] == false && const {'publish', 'future', 'private'}.contains(status)) {
      return 'pending';
    }
    return status;
  }

  /// The status the user asked for, before role restrictions apply.
  String _requestedStatus(PostVariant v, ConnectedAccount account) {
    final explicit = blogStr(v.extra['status']);
    String status;
    if (explicit != null && wordPressStatuses.contains(explicit)) {
      status = explicit;
    } else if (v.visibility == Visibility.private) {
      status = 'private';
    } else {
      final def = account.configString('defaultStatus', 'publish');
      status = wordPressStatuses.contains(def) ? def : 'publish';
    }
    if (status == 'publish' && v.scheduledAt != null) status = 'future';
    return status;
  }

  // ---------------------------------------------------------------- publish

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    try {
      return await _publish(variant, account, secrets, ctx);
    } on AdapterException catch (e) {
      ctx.log.warn('WordPress publish failed: ${e.error.message}');
      return PublishResult.failure(e.error);
    } on Exception catch (e) {
      ctx.log.warn('WordPress publish failed unexpectedly: $e');
      return PublishResult.failure(unexpectedBlogError('WordPress', e));
    }
  }

  /// API client for an API-tier account; throws [AdapterException] when the
  /// account or its password is missing.
  WordPressApi _api(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) {
    if (account.tier == PlatformTier.handoff) {
      throw const AdapterException(PublishError.unsupported('Hand-off accounts publish through the WordPress editor'));
    }
    final restBase = account.configString('restBase');
    final username = account.configString('username');
    if (restBase.isEmpty || username.isEmpty) {
      throw const AdapterException(PublishError.configuration('This WordPress account is incomplete; reconnect it'));
    }
    final password = secrets['app_password'] ?? '';
    if (password.isEmpty) {
      throw const AdapterException(PublishError.auth('No WordPress application password stored; reconnect the account'));
    }
    return WordPressApi(WordPressRoot(restBase), ctx, username: username, appPassword: password);
  }

  Future<PublishResult> _publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final api = _api(account, secrets, ctx);
    final title = (variant.title ?? '').trim();
    if (title.isEmpty) throw const AdapterException(PublishError.validation('WordPress posts need a title'));

    final uploads = <(MediaAttachment, int, String)>[];
    for (var i = 0; i < variant.media.length; i++) {
      uploads.add(await _upload(api, variant.media[i], i, variant.media.length, ctx));
    }
    final featuredIndex = variant.extra['featuredImage'] == false ? -1 : uploads.indexWhere((u) => u.$1.isImage);
    final featured = featuredIndex < 0 ? null : uploads[featuredIndex];
    final embedded = [
      for (var i = 0; i < uploads.length; i++)
        if (i != featuredIndex) uploads[i],
    ];

    final tagIds = await _resolveTerms(api, 'tags', List<Object>.from(variant.tags), ctx);
    final categoryIds = await _resolveTerms(api, 'categories', _categoryInputs(variant, account), ctx);

    final html = [
      bodyHtml(variant),
      for (final u in embedded) u.$1.isAudio ? wordPressAudioBlock(u.$2, u.$3) : mediaFigureHtml(u.$1, u.$3),
    ].where((s) => s.isNotEmpty).join('\n\n');
    final status = _status(variant, account);
    final excerpt = blogStr(variant.extra['excerpt']);
    final slug = blogStr(variant.extra['slug']);
    final at = variant.scheduledAt;
    final body = <String, Object?>{
      'title': title,
      'content': html,
      'status': status,
      'excerpt': ?excerpt,
      'slug': ?slug,
      if (tagIds.isNotEmpty) 'tags': tagIds,
      if (categoryIds.isNotEmpty) 'categories': categoryIds,
      if (featured != null) 'featured_media': featured.$2,
      if (at != null) 'date_gmt': isoSecondsUtc(at),
    };
    ctx.progress(status == 'future' ? 'Scheduling the post' : 'Publishing the post');
    final r = await guardWordPress('WordPress post', () => api.postJson('wp/v2/posts', body));
    final post = r.jsonMap;
    final postId = blogInt(post['id']);
    if (postId == null) {
      throw AdapterException(PublishError.platform('WordPress did not return the created post', raw: bodySnippet(r)));
    }
    final remoteStatus = blogStr(post['status']) ?? status;
    final link = blogStr(post['link']);
    ctx.log.info('WordPress post $postId created with status $remoteStatus');
    if (remoteStatus == 'future') {
      // WordPress holds the post and publishes it through WP-Cron.
      final when = at ?? _parseGmt(post['date_gmt']);
      if (when != null) return PublishResult.scheduled(remoteId: '$postId', scheduledFor: when, remoteUrl: link);
    }
    // `publish` although a date was sent: the date is in the past by the
    // server's clock, so WordPress published straight away.
    return PublishResult.ok(remoteId: '$postId', remoteUrl: link, publishedAt: ctx.now());
  }

  /// WordPress `date_gmt` values carry no zone suffix.
  static DateTime? _parseGmt(Object? v) {
    final s = blogStr(v);
    if (s == null) return null;
    return DateTime.tryParse(s.endsWith('Z') ? s : '${s}Z');
  }

  // ------------------------------------------------------------ scheduling

  /// Deletes the `future` post WordPress is holding (`DELETE
  /// /wp/v2/posts/{id}?force=true`, skipping the trash so it cannot be
  /// restored and published by mistake). A 404 means it is already gone.
  @override
  Future<void> cancelScheduled(
      PublishResult held, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final postId = int.tryParse(held.remoteId ?? '');
    if (postId == null) {
      throw const AdapterException(PublishError.configuration(
          'NEFORUM does not know which WordPress post holds this schedule; delete it in WordPress under Posts > Scheduled'));
    }
    final api = _api(account, secrets, ctx);
    ctx.progress('Removing the scheduled WordPress post');
    const what = 'Removing the scheduled WordPress post';
    try {
      await api.delete('wp/v2/posts/$postId', {'force': 'true'});
      ctx.log.info('WordPress post $postId deleted');
    } on HttpFailure catch (f) {
      // `rest_post_invalid_id`: deleted already. A missing route or an HTML
      // error page means the API was not reached, so the post may still be
      // held and must not be reported as gone.
      if (f.statusCode == 404 && !isHtmlResponse(f.response) && blogStr(f.response.jsonMap['code']) != 'rest_no_route') {
        ctx.log.info('WordPress post $postId no longer exists');
        return;
      }
      throw AdapterException(mapWordPressFailure(f, what));
    } on Exception catch (e) {
      throw AdapterException(PublishError.network('$what failed: $e', raw: '$e'));
    }
  }

  /// Uploads one file; returns (attachment, media id, source URL).
  Future<(MediaAttachment, int, String)> _upload(
      WordPressApi api, MediaAttachment m, int index, int total, AdapterContext ctx) async {
    final label = m.noun;
    ctx.progress('Uploading $label ${index + 1} of $total');
    final bytes = await readBlogMedia(ctx, m);
    final what = 'WordPress upload ${index + 1}/$total';
    final r = await guardWordPress(what,
        () => api.uploadMedia(bytes, fileName: safeFileName(m), contentType: m.mimeType));
    final json = r.jsonMap;
    final mediaId = blogInt(json['id']);
    final src = blogStr(json['source_url']);
    if (mediaId == null || src == null) {
      throw AdapterException(PublishError.platform('$what: WordPress did not return a media id', raw: bodySnippet(r)));
    }
    final alt = m.isAudio ? '' : (m.altText ?? '').trim();
    if (alt.isNotEmpty) {
      ctx.progress('Adding alt text to $label ${index + 1}');
      await guardWordPress('WordPress alt text ${index + 1}/$total',
          () => api.postJson('wp/v2/media/$mediaId', {'alt_text': alt}));
    }
    return (m, mediaId, src);
  }

  List<Object> _categoryInputs(PostVariant v, ConnectedAccount account) {
    final fromExtra = v.extra['categories'];
    if (fromExtra is List) return fromExtra.whereType<Object>().toList();
    if (fromExtra is String) return _splitCsv(fromExtra);
    return _splitCsv(account.configString('categories'));
  }

  static List<Object> _splitCsv(String s) =>
      s.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).toList();

  /// Turns tag/category names (or ids) into term ids: exact-name search,
  /// then create. Terms the user's role may not create are skipped.
  Future<List<int>> _resolveTerms(WordPressApi api, String taxonomy, List<Object> inputs, AdapterContext ctx) async {
    final ids = <int>[];
    for (final input in inputs) {
      final asId = input is int ? input : (input is String && RegExp(r'^\d+$').hasMatch(input) ? int.parse(input) : null);
      if (asId != null) {
        if (!ids.contains(asId)) ids.add(asId);
        continue;
      }
      final name = '$input'.trim().replaceFirst(RegExp(r'^#'), '');
      if (name.isEmpty) continue;
      final found = await _findTerm(api, taxonomy, name);
      final termId = found ?? await _createTerm(api, taxonomy, name, ctx);
      if (termId != null && !ids.contains(termId)) ids.add(termId);
    }
    return ids;
  }

  Future<int?> _findTerm(WordPressApi api, String taxonomy, String name) async {
    final r = await guardWordPress('WordPress $taxonomy lookup',
        () => api.get('wp/v2/$taxonomy', {'search': name, 'per_page': '100', '_fields': 'id,name,slug'}));
    final lower = name.toLowerCase();
    for (final t in blogList(r.json)) {
      final m = blogMap(t);
      if (m == null) continue;
      final termName = decodeBasicEntities(blogStr(m['name']) ?? '').toLowerCase();
      if (termName == lower || (blogStr(m['slug']) ?? '') == _slugify(name)) return blogInt(m['id']);
    }
    return null;
  }

  Future<int?> _createTerm(WordPressApi api, String taxonomy, String name, AdapterContext ctx) async {
    ctx.progress('Creating ${taxonomy == 'tags' ? 'tag' : 'category'} "$name"');
    try {
      final r = await api.postJson('wp/v2/$taxonomy', {'name': name});
      return blogInt(r.jsonMap['id']);
    } on HttpFailure catch (f) {
      final body = f.response.jsonMap;
      if (blogStr(body['code']) == 'term_exists') {
        // {"code":"term_exists","data":{"status":400,"term_id":5}}
        return blogInt(blogMap(body['data'])?['term_id']);
      }
      if (f.statusCode == 401 || f.statusCode == 403) {
        ctx.log.warn('WordPress: not allowed to create $taxonomy "$name"; skipping it');
        return null;
      }
      throw AdapterException(mapWordPressFailure(f, 'WordPress $taxonomy "$name"'));
    } on Exception catch (e) {
      throw AdapterException(PublishError.network('WordPress $taxonomy "$name" failed: $e', raw: '$e'));
    }
  }

  static String _slugify(String s) =>
      s.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

  // ---------------------------------------------------------------- hand-off

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final siteRaw = account?.configString('site') ?? '';
    final title = (variant.title ?? '').trim();
    final text = fullText(variant);
    final body = text.length > _maxIntentChars ? '' : text;
    final Uri intent;
    if (siteRaw.isEmpty) {
      // WordPress.com "Press This": https://wordpress.com/post/?url=&title=&text=&v=5
      intent = Uri.https('wordpress.com', '/post/', {
        if (variant.link != null && variant.link!.isNotEmpty) 'url': variant.link!,
        if (title.isNotEmpty) 'title': title,
        if (body.isNotEmpty) 'text': body,
        'v': '5',
      });
    } else {
      // Core post-new.php reads post_title / content / excerpt from the query.
      final site = Uri.parse(siteRaw);
      intent = joinPath(site, '/wp-admin/post-new.php', {
        if (title.isNotEmpty) 'post_title': title,
        if (body.isNotEmpty) 'content': body,
        if (blogStr(variant.extra['excerpt']) != null) 'excerpt': blogStr(variant.extra['excerpt'])!,
      });
    }
    final where = siteRaw.isEmpty ? 'WordPress.com' : Uri.parse(siteRaw).host;
    final steps = <String>[
      'NEFORUM opens the editor on $where with the title${body.isEmpty ? '' : ' and text'} filled in (sign in if asked).',
      if (body.isEmpty) 'Paste the text from the clipboard into the editor.',
      if (variant.hasMedia) 'Add your images with the + (Add block) button or the Featured image panel.',
      if (variant.tags.isNotEmpty) 'Add the tags ${variant.tags.join(', ')} in the post settings.',
      'Check the post and press **Publish**.',
    ];
    return HandoffPlan(
      platformId: id,
      webIntent: intent,
      clipboardText: title.isEmpty ? text : '$title\n\n$text',
      shareText: title.isEmpty ? text : '$title\n\n$text',
      shareFiles: variant.media,
      androidPackage: 'org.wordpress.android',
      desktopUrl: intent.toString(),
      preferred: variant.hasMedia ? HandoffMethod.shareSheet : HandoffMethod.webIntent,
      instructions: [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n'),
      mediaNote: variant.hasMedia
          ? 'A link cannot carry files into the WordPress editor. On a phone, share to the WordPress or Jetpack app '
              'to attach them; on a computer, upload them in the editor. Your text is on the clipboard.'
          : null,
    );
  }
}

/// The block editor's audio block for an uploaded sound file (media id
/// [mediaId] at [url]), so the post opens in the editor as an audio block.
String wordPressAudioBlock(int mediaId, String url) => '<!-- wp:audio {"id":$mediaId} -->\n'
    '<figure class="wp-block-audio"><audio controls src="${escapeHtml(url)}"></audio></figure>\n'
    '<!-- /wp:audio -->';
