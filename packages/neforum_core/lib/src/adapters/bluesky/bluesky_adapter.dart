import 'dart:convert';

import '../../auth/oauth2_pkce.dart';
import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
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
import 'bluesky_api.dart';
import 'bluesky_richtext.dart';

/// Bluesky / AT Protocol adapter.
///
/// Tier [PlatformTier.openApi] signs in with a handle + app password
/// (`com.atproto.server.createSession`), keeps the access/refresh JWT pair in
/// the secrets map and talks to the account's own PDS (taken from the DID
/// document in the session). Tier [PlatformTier.handoff] opens the
/// `bsky.app/intent/compose` composer.
class BlueskyAdapter extends PlatformAdapter {
  BlueskyAdapter({
    this.videoPollInterval = const Duration(seconds: 2),
    this.videoMaxWait = const Duration(minutes: 10),
  });

  /// How often to poll video.bsky.app while a video is processed.
  final Duration videoPollInterval;

  /// Give up waiting for video processing after this long.
  final Duration videoMaxWait;

  static const String platformId = 'bluesky';

  /// Secret key holding the app password, so an expired refresh token can be
  /// replaced without asking the user again.
  static const String secretAppPassword = 'app_password';

  /// Config keys.
  static const String cfgDid = 'did';
  static const String cfgPds = 'pds';
  static const String cfgService = 'service';
  static const String cfgHandle = 'handle';

  /// `PostVariant.extra` knobs.
  static const String extraLinkCard = 'bluesky.linkCard';
  static const String extraSelfLabel = 'bluesky.selfLabel';

  static const Set<String> selfLabels = {'sexual', 'nudity', 'porn', 'graphic-media'};

  static final RegExp _appPasswordPattern = RegExp(r'^[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}$', caseSensitive: false);
  static final RegExp _langPattern = RegExp(r'^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{1,8})*$');

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: platformId,
    name: 'Bluesky',
    iconKey: 'bluesky',
    homepage: 'https://bsky.app',
    family: 'atproto',
    tiers: {PlatformTier.openApi, PlatformTier.handoff},
    defaultTier: PlatformTier.openApi,
    text: TextRules(
      maxLength: 300,
      counting: CountingRule.graphemes,
      supportsThreads: true,
      supportsContentWarning: false,
      supportsHashtags: true,
      linkInText: true,
      notes: '300 graphemes and at most 3,000 UTF-8 bytes per post. URLs count in full. '
          'Links, @mentions and #hashtags become clickable facets.',
    ),
    media: MediaRules(
      // Sound goes as a video of one still picture, made by the app.
      audioAsVideo: true,
      maxImages: 4,
      maxVideos: 1,
      imageMaxBytes: blueskyImageMaxBytes,
      videoMaxBytes: blueskyVideoMaxBytes,
      videoMaxSeconds: 600,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/webp', 'image/gif'},
      videoMimeTypes: {'video/mp4'},
      supportsAltText: true,
      mediaPerThreadPart: true,
      notes: 'Up to 4 images (2,000,000 bytes each) or one MP4 video (300 MB, 10 minutes), never both. '
          'GIFs are shown as still images. Video needs a verified email and has a daily upload limit.',
    ),
    defaultQuotas: [
      QuotaRule(
        id: 'bluesky.posts_per_hour',
        limit: 1666,
        window: Duration(hours: 1),
        note: 'posts per hour (5,000 write points, 3 per post)',
        appliesToTier: PlatformTier.openApi,
      ),
      QuotaRule(
        id: 'bluesky.posts_per_day',
        limit: 11666,
        window: Duration(days: 1),
        note: 'posts per day (35,000 write points, 3 per post)',
        appliesToTier: PlatformTier.openApi,
      ),
    ],
    personalAccountOk: true,
    accountRequirements: 'Any free Bluesky account, including ones on a self-hosted AT Protocol server. '
        'You only need to create an app password in Bluesky settings; no developer account or app review.',
    apiCostSummary: 'Free with no paid tiers. Bluesky only caps how fast you post (about 1,600 posts an hour) '
        'and how many videos you upload per day.',
    setupGuide: 'docs/platforms/bluesky.md',
    serverSideScheduling: false,
    supportsLinkField: false,
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.openApi,
          loopbackRedirectOk: false,
          customSchemeRedirectOk: false,
          intro: '**Connect Bluesky with an app password** (free, takes a minute):\n\n'
              '1. Open https://bsky.app/settings/app-passwords (Settings > Privacy and security > App passwords).\n'
              '2. Tap **Add App Password**, name it `NEFORUM`, leave **"Allow access to your direct messages"** off, and create it.\n'
              '3. Copy the password (it looks like `abcd-efgh-ijkl-mnop`) and paste it below together with your handle.\n\n'
              'Never use your main Bluesky password here. You can revoke the app password at any time on the same page.',
          fields: [
            ConnectField(
              key: 'identifier',
              label: 'Handle',
              placeholder: 'alice.bsky.social',
              help: 'Your Bluesky handle without the @ (or the email address you sign in with).',
            ),
            ConnectField(
              key: 'app_password',
              label: 'App password',
              kind: FieldKind.password,
              secret: true,
              placeholder: 'xxxx-xxxx-xxxx-xxxx',
              help: 'Created at bsky.app > Settings > Privacy and security > App passwords.',
            ),
            ConnectField(
              key: 'service',
              label: 'Hosting provider',
              kind: FieldKind.url,
              required: false,
              defaultValue: 'https://bsky.social',
              help: 'Leave as https://bsky.social unless your account lives on your own AT Protocol server (PDS).',
            ),
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.handoff,
          loopbackRedirectOk: false,
          customSchemeRedirectOk: false,
          intro: 'No sign-in needed: NEFORUM opens the Bluesky composer with your text filled in '
              'and you tap **Post** yourself. Media goes through the share sheet on phones.',
          fields: [
            ConnectField(
              key: 'handle',
              label: 'Handle (optional)',
              required: false,
              placeholder: 'alice.bsky.social',
              help: 'Only used as a label in NEFORUM.',
            ),
          ],
        ),
      ];

  // ---------------------------------------------------------------------
  // connect / refresh / disconnect
  // ---------------------------------------------------------------------

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier == PlatformTier.handoff) {
      final handle = _cleanHandle(input['handle'] ?? '');
      return ConnectResult(
        account: ConnectedAccount(
          id: 'bluesky:handoff:${handle.isEmpty ? 'default' : handle}',
          platformId: platformId,
          tier: PlatformTier.handoff,
          displayName: handle.isEmpty ? 'Bluesky (hand-off)' : '@$handle (hand-off)',
          handle: handle.isEmpty ? null : '@$handle',
          profileUrl: handle.isEmpty ? null : 'https://bsky.app/profile/$handle',
          createdAt: ctx.now(),
        ),
      );
    }
    if (tier != PlatformTier.openApi) {
      throw ConnectException('Bluesky does not support the ${tier.label} tier');
    }

    final identifier = _cleanHandle(input['identifier'] ?? '');
    if (identifier.isEmpty) throw const ConnectException('Enter your Bluesky handle', field: 'identifier');
    final password = (input['app_password'] ?? '').trim();
    if (password.isEmpty) throw const ConnectException('Enter an app password', field: 'app_password');
    if (!_appPasswordPattern.hasMatch(password)) {
      throw const ConnectException(
          'That does not look like an app password (xxxx-xxxx-xxxx-xxxx). Create one at bsky.app > Settings > '
          'Privacy and security > App passwords; never enter your main password.',
          field: 'app_password');
    }
    final service = _parseService(input['service']);

    ctx.progress('Signing in to Bluesky');
    final BlueskySession session;
    try {
      session = await BlueskyApi.createSession(ctx, service, identifier: identifier, password: password);
    } on HttpFailure catch (e) {
      throw _connectError(e, ctx);
    } on FormatException catch (e) {
      throw ConnectException('Unexpected answer from $service: ${e.message}');
    }
    if (session.active == false) {
      throw ConnectException('This Bluesky account is ${session.status ?? 'not active'} and cannot post.');
    }

    final pds = session.pds ?? service;
    final api = BlueskyApi(ctx, pds: pds, accessJwt: session.accessJwt);
    final profile = await api.getProfile(session.did);
    final name = profile['displayName'];
    final avatar = profile['avatar'];
    return ConnectResult(
      account: ConnectedAccount(
        id: 'bluesky:${session.did}',
        platformId: platformId,
        tier: PlatformTier.openApi,
        displayName: name is String && name.trim().isNotEmpty ? '${name.trim()} (@${session.handle})' : '@${session.handle}',
        handle: '@${session.handle}',
        avatarUrl: avatar is String ? avatar : null,
        profileUrl: 'https://bsky.app/profile/${session.handle}',
        createdAt: ctx.now(),
        config: {
          cfgDid: session.did,
          cfgHandle: session.handle,
          cfgPds: pds.toString(),
          cfgService: service.toString(),
        },
      ),
      secrets: _sessionSecrets(session, password),
    );
  }

  @override
  Future<Map<String, String>?> refreshSecrets(
      ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.openApi) return null;
    final tokens = OAuthTokens.fromSecrets(secrets);
    final now = ctx.now();
    if (tokens != null) {
      final exp = tokens.expiresAt ?? jwtExpiry(tokens.accessToken);
      if (exp == null || !now.toUtc().add(const Duration(minutes: 5)).isAfter(exp)) return null;
    }
    final service = _serviceOf(account);
    final refreshJwt = tokens?.refreshToken;
    if (refreshJwt != null && refreshJwt.isNotEmpty) {
      try {
        ctx.log.debug('Refreshing Bluesky session for ${account.displayName}');
        final s = await BlueskyApi.refreshSession(ctx, service, refreshJwt);
        return _sessionSecrets(s, secrets[secretAppPassword], secrets);
      } on HttpFailure catch (e) {
        final err = mapBlueskyFailure(e, now: now);
        if (err.kind != PublishErrorKind.auth && err.kind != PublishErrorKind.validation) throw AdapterException(err);
        ctx.log.info('Bluesky refresh token rejected (${xrpcErrorCode(e.response) ?? e.statusCode}); signing in again');
      } on FormatException catch (e) {
        throw AdapterException(PublishError.platform('Unexpected refreshSession answer: ${e.message}'));
      }
    }
    return _relogin(account, secrets, service, ctx);
  }

  Future<Map<String, String>> _relogin(
      ConnectedAccount account, Map<String, String> secrets, Uri service, AdapterContext ctx) async {
    final password = secrets[secretAppPassword];
    final identifier = account.configString(cfgDid, account.configString(cfgHandle));
    if (password == null || password.isEmpty || identifier.isEmpty) {
      throw const AdapterException(PublishError.auth('Your Bluesky session expired. Reconnect the account.'));
    }
    try {
      final s = await BlueskyApi.createSession(ctx, service, identifier: identifier, password: password);
      return _sessionSecrets(s, password, secrets);
    } on HttpFailure catch (e) {
      final err = mapBlueskyFailure(e, now: ctx.now());
      if (e.statusCode == 401 || err.kind == PublishErrorKind.auth) {
        throw AdapterException(PublishError.auth(
            'Bluesky no longer accepts the app password (revoked?). Create a new one and reconnect the account.',
            raw: e.body,
            statusCode: e.statusCode));
      }
      throw AdapterException(err);
    } on FormatException catch (e) {
      throw AdapterException(PublishError.platform('Unexpected createSession answer: ${e.message}'));
    }
  }

  @override
  Future<void> disconnect(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final refresh = secrets[OAuthTokens.keyRefreshToken];
    if (account.tier != PlatformTier.openApi || refresh == null) return;
    try {
      await BlueskyApi(ctx, pds: _serviceOf(account)).deleteSession(_serviceOf(account), refresh);
    } on Exception catch (e) {
      ctx.log.warn('Bluesky deleteSession failed', e);
    }
  }

  // ---------------------------------------------------------------------
  // validation
  // ---------------------------------------------------------------------

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = RulesValidator.validate(variant, descriptor, tier: account.tier);
    final parts = variant.isThread ? variant.threadParts : [variant.text];
    for (var i = 0; i < parts.length; i++) {
      final bytes = utf8.encode(parts[i]).length;
      if (bytes > blueskyTextMaxBytes) {
        issues.add(ValidationIssue.error('bluesky.text_bytes',
            '${parts.length > 1 ? 'Part ${i + 1}' : 'Text'} is $bytes bytes; Bluesky allows $blueskyTextMaxBytes UTF-8 bytes per post',
            field: 'text'));
      }
      for (final tag in BlueskyRichText.overlongTags(parts[i])) {
        issues.add(ValidationIssue.warning('bluesky.tag_too_long',
            '#${tag.length > 20 ? '${tag.substring(0, 20)}…' : tag} is longer than 64 characters and will not be clickable',
            field: 'text'));
      }
    }
    if (variant.visibility != Visibility.public) {
      issues.add(const ValidationIssue.warning(
          'bluesky.always_public', 'Bluesky has no private or followers-only posts; this will be public', field: 'text'));
    }
    if ((variant.contentWarning ?? '').trim().isNotEmpty) {
      issues.add(const ValidationIssue.warning('bluesky.no_cw',
          'Bluesky has no content-warning text; only media can carry an adult/graphic label', field: 'text'));
    }
    if (variant.sensitive && !variant.hasMedia) {
      issues.add(const ValidationIssue.info(
          'bluesky.label_media_only', 'Bluesky content labels only apply to images and video', field: 'media'));
    }
    final label = variant.extraAs<String>(extraSelfLabel);
    if (label != null && !selfLabels.contains(label)) {
      issues.add(ValidationIssue.error('bluesky.bad_label', 'Unknown Bluesky label "$label"; use one of ${selfLabels.join(', ')}',
          field: 'media'));
    }
    if (variant.hasMedia && _cardLink(variant) != null) {
      issues.add(const ValidationIssue.info('bluesky.no_link_card',
          'A Bluesky post holds one attachment, so the link stays a plain link without a preview card',
          field: 'link'));
    }
    if (account.tier == PlatformTier.handoff && variant.hasMedia) {
      issues.add(const ValidationIssue.info('bluesky.handoff_media',
          'The Bluesky compose link cannot carry media; attach it in the composer or use the share sheet',
          field: 'media'));
    }
    return issues;
  }

  // ---------------------------------------------------------------------
  // publish
  // ---------------------------------------------------------------------

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.openApi) {
      return PublishResult.failure(const PublishError.unsupported('This Bluesky account is set up for hand-off only'));
    }
    try {
      return await _publish(variant, account, secrets, ctx);
    } on AdapterException catch (e) {
      return PublishResult.failure(e.error);
    } on HttpFailure catch (e) {
      return PublishResult.failure(mapBlueskyFailure(e, now: ctx.now()));
    } on Exception catch (e) {
      return PublishResult.failure(PublishError.network('Could not reach Bluesky: $e'));
    }
  }

  Future<PublishResult> _publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final did = account.configString(cfgDid);
    final pds = Uri.tryParse(account.configString(cfgPds));
    if (did.isEmpty || pds == null || pds.host.isEmpty) {
      return PublishResult.failure(
          const PublishError.configuration('This Bluesky account is missing its server details; reconnect it'));
    }
    final access = secrets[OAuthTokens.keyAccessToken];
    if (access == null || access.isEmpty) {
      return PublishResult.failure(const PublishError.auth('Not signed in to Bluesky; reconnect the account'));
    }
    final errors = validate(variant, account).where((i) => i.isError).toList();
    if (errors.isNotEmpty) {
      return PublishResult.failure(PublishError.validation(errors.map((e) => e.message).join('; ')));
    }

    final api = BlueskyApi(ctx, pds: pds, accessJwt: access);
    final parts = variant.isThread ? variant.threadParts : [variant.text];
    // A thread that broke off earlier goes on after its live posts, replying
    // to the last of them.
    final posted = variant.postedThreadIds;
    final start = posted.length;

    // Embeds, made before anything is posted: each post's media, and a link
    // card on the first post when it has no media.
    final embeds = <Map<String, dynamic>?>[];
    for (var i = 0; i < parts.length; i++) {
      final media = variant.mediaOfPart(i);
      embeds.add(i < start
          ? null
          : media.isNotEmpty
              ? await _mediaEmbed(media, api, did, ctx)
              : (i == 0 ? await _linkCardEmbed(variant, api, ctx) : null));
    }

    // Resolve every @handle once.
    final handles = {for (final p in parts) ...BlueskyRichText.mentionedHandles(p)};
    final dids = <String, String>{};
    for (final h in handles) {
      final d = await api.resolveHandle(h);
      if (d != null) {
        dids[h] = d;
      } else {
        ctx.log.info('Bluesky: @$h does not resolve; leaving it as plain text');
      }
    }

    final langs = _langs(variant.language);
    final labels = _selfLabel(variant);
    final uris = [...posted];
    StrongRef? root = start > 0 ? await api.getPostRef(posted.first) : null;
    StrongRef? parent = start > 1 ? await api.getPostRef(posted.last) : root;
    for (var i = start; i < parts.length; i++) {
      if (parts.length > 1) ctx.progress('Posting part ${i + 1} of ${parts.length} to Bluesky');
      final facets = BlueskyRichText.facets(parts[i], didsByHandle: dids);
      final record = <String, dynamic>{
        r'$type': 'app.bsky.feed.post',
        'text': parts[i],
        'createdAt': ctx.now().toUtc().toIso8601String(),
        if (langs.isNotEmpty) 'langs': langs,
        if (facets.isNotEmpty) 'facets': facets,
        if (embeds[i] case final embed?) 'embed': embed,
        if (labels != null && (i == 0 || variant.mediaOfPart(i).isNotEmpty)) 'labels': labels,
        if (i > 0 && root != null && parent != null) 'reply': {'root': root.toJson(), 'parent': parent.toJson()},
      };
      try {
        final ref = await api.createPost(did, record);
        root ??= ref;
        parent = ref;
        uris.add(ref.uri);
      } on HttpFailure catch (e) {
        if (uris.isEmpty) rethrow;
        // Earlier posts are live: they are recorded, and the next attempt
        // posts only the rest.
        return PublishResult.partialFailure(
          mapBlueskyFailure(e, now: ctx.now()).asResumableThread(postedIds: uris, total: parts.length),
          remoteId: uris.first,
          remoteUrl: _webUrlOf(account, uris.first),
          threadRemoteIds: uris,
        );
      }
    }
    return PublishResult.ok(
      remoteId: uris.first,
      remoteUrl: _webUrlOf(account, uris.first),
      threadRemoteIds: parts.length > 1 ? uris : const [],
      publishedAt: ctx.now(),
    );
  }

  @override
  bool get resumesThreads => true;

  Future<Map<String, dynamic>> _mediaEmbed(
      List<MediaAttachment> media, BlueskyApi api, String did, AdapterContext ctx) async {
    final videos = media.where((m) => m.isVideo).toList();
    if (videos.isNotEmpty) {
      final v = videos.first;
      ctx.progress('Uploading video to Bluesky');
      final bytes = await ctx.readMedia(v);
      if (bytes.length > blueskyVideoMaxBytes) {
        throw AdapterException(PublishError.validation(
            '${v.fileName ?? v.id} is ${bytes.length} bytes; Bluesky videos are limited to $blueskyVideoMaxBytes bytes'));
      }
      final blob = await api.uploadVideo(
        did: did,
        name: _videoName(v),
        bytes: bytes,
        pollInterval: videoPollInterval,
        maxWait: videoMaxWait,
      );
      return {
        r'$type': 'app.bsky.embed.video',
        'video': blob,
        if ((v.altText ?? '').isNotEmpty) 'alt': v.altText,
        if (_aspect(v) case final a?) 'aspectRatio': a,
      };
    }
    final images = <Map<String, dynamic>>[];
    for (var i = 0; i < media.length; i++) {
      final m = media[i];
      ctx.progress('Uploading image ${i + 1} of ${media.length} to Bluesky');
      final bytes = await ctx.readMedia(m);
      if (bytes.length > blueskyImageMaxBytes) {
        throw AdapterException(PublishError.validation(
            '${m.fileName ?? m.id} is ${bytes.length} bytes; Bluesky accepts images up to $blueskyImageMaxBytes bytes '
            '(2 MB). Resize or compress it and try again.'));
      }
      final blob = await api.uploadBlob(bytes, m.mimeType);
      images.add({
        'alt': m.altText ?? '',
        'image': blob,
        if (_aspect(m) case final a?) 'aspectRatio': a,
      });
    }
    return {r'$type': 'app.bsky.embed.images', 'images': images};
  }

  Future<Map<String, dynamic>?> _linkCardEmbed(PostVariant variant, BlueskyApi api, AdapterContext ctx) async {
    if (variant.extra[extraLinkCard] == false) return null;
    final link = _cardLink(variant);
    final url = link == null ? null : Uri.tryParse(link);
    if (url == null || (url.scheme != 'https' && url.scheme != 'http')) return null;
    ctx.progress('Building link preview');
    final preview = await api.fetchLinkPreview(url);
    if (preview == null) {
      ctx.log.info('Bluesky: no preview data for $url; posting without a link card');
      return null;
    }
    Map<String, dynamic>? thumb;
    if (preview.image != null) {
      try {
        thumb = await api.uploadThumb(preview.image!);
      } on HttpFailure catch (e) {
        ctx.log.warn('Bluesky: link-card image upload failed (${e.statusCode}); posting the card without it');
      }
    }
    return {
      r'$type': 'app.bsky.embed.external',
      'external': {
        'uri': preview.uri,
        'title': preview.title,
        'description': preview.description,
        'thumb': ?thumb,
      },
    };
  }

  // ---------------------------------------------------------------------
  // hand-off
  // ---------------------------------------------------------------------

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final full = variant.isThread ? variant.threadParts.join('\n\n') : variant.text;
    final first = variant.text;
    final intent = Uri.parse('https://bsky.app/intent/compose?text=${Uri.encodeComponent(first)}');
    final hasMedia = variant.hasMedia;
    final steps = hasMedia
        ? '1. Share the media to **Bluesky** from the share sheet (or open the composer on desktop).\n'
            '2. If the text is missing, paste it (it is on your clipboard).\n'
            '3. Check the images or video, add alt text, and tap **Post**.'
        : '1. The Bluesky composer opens with your text filled in (sign in if asked).\n'
            '2. Check the text and tap **Post**.'
            '${variant.isThread ? '\n3. Only the first part is prefilled; reply to your post with the rest (copied to your clipboard).' : ''}';
    final added = [
      if (hasMedia) 'your images or video',
      if (variant.isThread) 'the other ${variant.threadParts.length - 1} posts of the thread',
    ];
    final composerSteps = added.isEmpty
        ? '1. The Bluesky composer opens with your text filled in (sign in if asked).\n'
            '2. Check the text and select **Post**.'
        : '1. The Bluesky composer opens with your text filled in (sign in if asked), and the NEFORUM browser extension '
            'adds ${added.join(' and ')}.\n'
            '2. Check the post${hasMedia ? ', add alt text' : ''} and select **${variant.isThread ? 'Post all' : 'Post'}**.';
    return HandoffPlan(
      platformId: platformId,
      instructions: steps,
      webIntent: intent,
      clipboardText: full,
      shareText: first,
      shareFiles: variant.media,
      androidPackage: 'xyz.blueskyweb.app',
      iosScheme: 'bluesky://',
      desktopUrl: 'https://bsky.app',
      preferred: hasMedia ? HandoffMethod.shareSheet : HandoffMethod.webIntent,
      mediaNote: hasMedia
          ? 'The Bluesky compose link cannot carry images or video. On a phone, pick Bluesky in the share sheet; '
              'on desktop, attach the files in the composer yourself.'
          : null,
      // With the browser extension the compose page also gets the files and
      // every post of a thread.
      composerUrl: intent,
      composerInstructions: composerSteps,
    );
  }

  // ---------------------------------------------------------------------
  // helpers
  // ---------------------------------------------------------------------

  /// The link a card would be built for: the post's link, else the first
  /// URL in the text.
  static String? _cardLink(PostVariant v) {
    final explicit = v.link?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return explicit.contains('://') ? explicit : 'https://$explicit';
    }
    final parts = v.isThread ? v.threadParts : [v.text];
    for (final p in parts) {
      final found = UrlDetector.find(p);
      if (found.isNotEmpty) return found.first.normalized;
    }
    return null;
  }

  static Map<String, String> _sessionSecrets(BlueskySession s, String? appPassword,
      [Map<String, String> existing = const {}]) {
    final tokens = OAuthTokens(
      accessToken: s.accessJwt,
      refreshToken: s.refreshJwt,
      expiresAt: jwtExpiry(s.accessJwt),
    );
    return tokens.toSecrets({
      ...existing,
      if (appPassword != null && appPassword.isNotEmpty) secretAppPassword: appPassword,
    });
  }

  static String _cleanHandle(String s) {
    var h = s.trim();
    if (h.startsWith('@')) h = h.substring(1);
    if (h.startsWith('at://')) h = h.substring(5);
    return h.contains('@') ? h : h.toLowerCase();
  }

  static Uri _parseService(String? raw) {
    final s = (raw ?? '').trim();
    if (s.isEmpty) return blueskyDefaultService;
    final u = Uri.tryParse(s.contains('://') ? s : 'https://$s');
    if (u == null || u.host.isEmpty || (u.scheme != 'https' && u.scheme != 'http')) {
      throw const ConnectException('Hosting provider must be a web address like https://bsky.social', field: 'service');
    }
    return Uri(scheme: u.scheme, host: u.host, port: u.hasPort ? u.port : null);
  }

  static Uri _serviceOf(ConnectedAccount a) {
    final s = Uri.tryParse(a.configString(cfgService));
    if (s != null && s.host.isNotEmpty) return s;
    final p = Uri.tryParse(a.configString(cfgPds));
    return (p != null && p.host.isNotEmpty) ? p : blueskyDefaultService;
  }

  /// The bsky.app address of the post at [uri] (`at://did/collection/rkey`).
  static String _webUrlOf(ConnectedAccount a, String uri) {
    final who = a.configString(cfgHandle, a.configString(cfgDid));
    return 'https://bsky.app/profile/$who/post/${uri.split('/').last}';
  }

  static List<String> _langs(String? language) {
    final l = language?.trim().replaceAll('_', '-');
    if (l == null || l.isEmpty || !_langPattern.hasMatch(l)) return const [];
    return [l];
  }

  static Map<String, dynamic>? _selfLabel(PostVariant v) {
    if (!v.hasMedia) return null;
    final explicit = v.extraAs<String>(extraSelfLabel);
    final val = explicit ?? (v.sensitive ? 'graphic-media' : null);
    if (val == null) return null;
    return {
      r'$type': 'com.atproto.label.defs#selfLabels',
      'values': [
        {'val': val},
      ],
    };
  }

  static Map<String, int>? _aspect(MediaAttachment m) {
    final w = m.width;
    final h = m.height;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return {'width': w, 'height': h};
  }

  static String _videoName(MediaAttachment v) {
    final n = v.fileName ?? '${v.id}.mp4';
    return n.toLowerCase().endsWith('.mp4') ? n : '$n.mp4';
  }

  ConnectException _connectError(HttpFailure e, AdapterContext ctx) {
    final code = xrpcErrorCode(e.response);
    switch (code) {
      case 'AuthFactorTokenRequired':
        return const ConnectException(
            'Bluesky asked for an email sign-in code, which means this is your main password. Use an app password instead.',
            field: 'app_password');
      case 'AccountTakedown':
        return const ConnectException('Bluesky has suspended this account; it cannot be used for posting.');
      case 'RateLimitExceeded':
        return const ConnectException('Too many sign-in attempts. Wait a few minutes and try again.');
    }
    if (e.statusCode == 429) return const ConnectException('Too many sign-in attempts. Wait a few minutes and try again.');
    if (e.statusCode == 401 || code == 'AuthenticationRequired') {
      return const ConnectException('Bluesky did not accept that handle and app password. Check both and try again.',
          field: 'app_password');
    }
    if (e.statusCode == 400 && code == 'InvalidRequest') {
      return const ConnectException('Bluesky could not find that account. Check the handle (e.g. alice.bsky.social).',
          field: 'identifier');
    }
    final err = mapBlueskyFailure(e, now: ctx.now());
    return ConnectException('Could not sign in to Bluesky: ${err.message}');
  }
}
