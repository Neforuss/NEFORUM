import 'dart:convert';
import 'dart:typed_data';

import '../../auth/auth_broker.dart';
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
import 'blogs_common.dart';
import 'micropub_api.dart';

/// NEFORUM's hosted IndieAuth client id, used when the redirect is not a
/// loopback address (mobile `neforum://callback`). Because that redirect is
/// on another host, servers only accept it once the page at this URL
/// publishes an OAuth Client ID Metadata Document listing it
/// (IndieAuth §4.2.2 / §5.2). As of 2026-10 that page does not exist yet.
const String micropubDefaultClientId = 'https://neforum.app/';

/// Scopes NEFORUM asks for: create posts, upload to the media endpoint, and
/// `profile` so the token response may carry the name and photo
/// (IndieAuth §5.3.4; servers return only `me` without it).
const List<String> micropubScopes = ['create', 'media', 'profile'];

/// The IndieAuth client id for a loopback [redirect] (`http://127.0.0.1:PORT/`),
/// or `null` when [redirect] is not on 127.0.0.1 / [::1]. Servers must not
/// fetch loopback client ids, and a redirect on the same scheme, host and
/// port needs no published redirect list (IndieAuth §4.2 and §5.2).
String? micropubLoopbackClientId(Uri redirect) {
  if (redirect.scheme != 'http' || (redirect.host != '127.0.0.1' && redirect.host != '::1')) return null;
  return Uri(scheme: 'http', host: redirect.host, port: redirect.hasPort ? redirect.port : null, path: '/').toString();
}

/// Micro.blog's Micropub endpoint (help.micro.blog "Posting API").
final Uri microblogMicropubEndpoint = Uri.parse('https://micro.blog/micropub');

/// Micro.blog shortens untitled posts in the timeline beyond this length.
const int microblogShortPostChars = 300;

/// NEFORUM's own cap: the Micropub spec sets no limit on photos per post.
const int micropubMaxImages = 10;

/// Adapter for any site with a Micropub endpoint (Micro.blog, WordPress with
/// the IndieAuth + Micropub plugins, Known, many static-site setups).
///
/// Connect: discover `indieauth-metadata` / `authorization_endpoint` /
/// `token_endpoint` and `micropub` on the user's URL, IndieAuth
/// authorization code + PKCE (S256), then `q=config` for the media endpoint.
/// A pasted app token (Micro.blog > Account > App tokens) skips the browser.
/// Publish: optional uploads to the media endpoint, then one form-encoded
/// `h=entry` create; the `Location` header is the post URL.
class MicropubAdapter extends PlatformAdapter {
  MicropubAdapter();

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'micropub',
    name: 'Micropub (IndieWeb / Micro.blog)',
    iconKey: 'micropub',
    homepage: 'https://micropub.spec.indieweb.org/',
    family: 'indieweb',
    tiers: {PlatformTier.openApi},
    defaultTier: PlatformTier.openApi,
    text: TextRules(
      maxLength: null,
      counting: CountingRule.graphemes,
      titleSupported: true,
      titleRequired: false,
      supportsThreads: false,
      supportsContentWarning: false,
      supportsMarkdown: true,
      supportsHashtags: true,
      hashtagsAsField: true,
      linkInText: true,
      notes: 'No length limit in the Micropub spec. A post with a title becomes a full article; on Micro.blog, '
          'untitled posts longer than 300 characters are shortened in the timeline. Tags are sent as categories. '
          'Most servers (Micro.blog included) render Markdown.',
    ),
    media: MediaRules(
      maxImages: micropubMaxImages,
      maxVideos: 1,
      allowsMixedImageVideo: true,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif', 'image/webp'},
      videoMimeTypes: {'video/mp4', 'video/quicktime'},
      supportsAltText: true,
      notes: 'Files go to your media endpoint first (or ride along with the post when your site has none). '
          'Size limits are set by your site. Alt text is sent as mp-photo-alt, which Micro.blog understands; '
          'other servers may ignore it.',
    ),
    defaultQuotas: [],
    personalAccountOk: true,
    accountRequirements: 'Your own website or Micro.blog blog with Micropub and IndieAuth turned on. '
        'No developer account or app registration is needed.',
    apiCostSummary: 'The protocol is free and has no published rate limits. Micro.blog needs a paid hosted plan for '
        'a hosted blog; your own site costs whatever your hosting costs.',
    setupGuide: 'docs/platforms/micropub.md',
    serverSideScheduling: false,
    supportsLinkField: false,
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.openApi,
          usesBrowser: true,
          loopbackRedirectOk: true,
          customSchemeRedirectOk: true,
          intro: '**Micropub needs no developer account.** Enter the address of your site (for Micro.blog: '
              '`yourname.micro.blog` or your custom domain). NEFORUM finds your sign-in and posting endpoints, '
              'opens your site\'s IndieAuth sign-in page in the browser and asks for permission to **create** posts '
              'and upload **media**. Approve it and you are done.\n\n'
              '**Micro.blog shortcut:** instead of the browser, open **micro.blog > Account > App tokens**, create a '
              'token named `NEFORUM` and paste it below.\n\n'
              'Your site must advertise `rel="micropub"` and IndieAuth (`rel="indieauth-metadata"` or '
              '`rel="authorization_endpoint"` + `rel="token_endpoint"`). WordPress needs the IndieAuth and Micropub '
              'plugins.',
          redirectNote: 'Nothing to register. On a computer NEFORUM identifies itself as http://127.0.0.1:52771/ and '
              'returns to http://127.0.0.1:52771/callback. On a phone it uses https://neforum.app/ and '
              'neforum://callback, which servers that verify redirect addresses may refuse; use an app token there.',
          fields: [
            ConnectField(
              key: 'me',
              label: 'Your site URL (me)',
              kind: FieldKind.url,
              placeholder: 'https://alice.micro.blog/',
              help: 'The home page you sign in with, e.g. `alice.micro.blog` or `https://alice.example/`.',
            ),
            ConnectField(
              key: 'token',
              label: 'App token (optional)',
              kind: FieldKind.password,
              required: false,
              secret: true,
              help: 'Leave empty to sign in through the browser. Micro.blog users can paste a token from '
                  'Account > App tokens instead.',
            ),
            ConnectField(
              key: 'clientId',
              label: 'Client ID (advanced, optional)',
              kind: FieldKind.url,
              required: false,
              placeholder: 'automatic',
              help: 'Leave empty. NEFORUM then uses `http://127.0.0.1:52771/` on a computer (servers never fetch '
                  'loopback client ids) and `https://neforum.app/` on a phone. Enter your own client id URL only if '
                  'you host a client metadata page that lists NEFORUM\'s redirect address.',
            ),
          ],
        ),
      ];

  // ---------------------------------------------------------------- connect

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    final me = canonicalMe(input['me'] ?? '');
    final pasted = (input['token'] ?? '').trim();
    final disc = await discoverMicropub(me, ctx);

    OAuthTokens tokens;
    var profileMe = me;
    var micropub = disc.micropub;
    var method = 'token';
    Map<String, dynamic> profile = const {};
    var clientId = micropubDefaultClientId;
    if (pasted.isNotEmpty) {
      tokens = OAuthTokens(accessToken: pasted);
      micropub ??= _isMicroblogHost(me.host) ? microblogMicropubEndpoint : null;
    } else {
      if (ctx.broker == null) {
        throw const ConnectException('Browser sign-in is not available here; paste an app token instead.', field: 'token');
      }
      final authz = disc.authorizationEndpoint;
      final tokenEp = disc.tokenEndpoint;
      if (authz == null || tokenEp == null) {
        throw ConnectException('${me.host} does not advertise IndieAuth (no authorization or token endpoint). '
            'Install IndieAuth on your site, or paste an app token.', field: 'me');
      }
      final (granted, usedClientId) = await _indieAuth(disc, input['clientId'], ctx);
      tokens = granted;
      clientId = usedClientId;
      method = 'indieauth';
      profile = blogMap(tokens.raw['profile']);
      final returned = blogStr(tokens.raw['me']);
      if (returned != null) {
        final r = canonicalMe(returned);
        if (r != me) {
          final again = await discoverMicropub(r, ctx);
          if (again.authorizationEndpoint != authz) {
            throw ConnectException('The sign-in returned ${r.host}, which does not use the same IndieAuth server as '
                '${me.host}. Connect with ${r.toString()} instead.');
          }
          micropub = again.micropub ?? micropub;
        }
        profileMe = r;
      }
    }
    if (micropub == null) {
      throw ConnectException('${me.host} does not advertise a Micropub endpoint (rel="micropub").', field: 'me');
    }

    final config = await _queryConfig(micropub, tokens.accessToken, ctx);
    final mediaEndpoint = blogStr(config['media-endpoint']);
    final name = blogStr(profile['name']);
    final microblog = _isMicroblogHost(profileMe.host) || micropub.host == 'micro.blog';
    return ConnectResult(
      account: ConnectedAccount(
        id: 'micropub:$profileMe',
        platformId: id,
        tier: PlatformTier.openApi,
        displayName: name == null ? profileMe.host : '$name (${profileMe.host})',
        handle: _handle(profileMe),
        avatarUrl: blogStr(profile['photo']),
        profileUrl: profileMe.toString(),
        createdAt: ctx.now(),
        config: {
          'me': profileMe.toString(),
          'micropubEndpoint': micropub.toString(),
          if (mediaEndpoint != null) 'mediaEndpoint': micropub.resolve(mediaEndpoint).toString(),
          'authMethod': method,
          if (method == 'indieauth') 'clientId': clientId,
          if (disc.authorizationEndpoint != null) 'authorizationEndpoint': disc.authorizationEndpoint.toString(),
          if (disc.tokenEndpoint != null) 'tokenEndpoint': disc.tokenEndpoint.toString(),
          if (disc.revocationEndpoint != null) 'revocationEndpoint': disc.revocationEndpoint.toString(),
          if (disc.issuer != null) 'issuer': disc.issuer,
          'microblog': microblog,
          'syndicateTargets': _targets(config['syndicate-to']),
          'destinations': _targets(config['destination']),
          if (config['post-types'] is List) 'postTypes': _postTypes(config['post-types']),
        },
      ),
      secrets: tokens.toSecrets(),
    );
  }

  /// The client id to send: the user's own one when they entered it,
  /// otherwise the loopback id for a loopback [redirect] and NEFORUM's
  /// hosted id for anything else.
  String _clientId(String? raw, Uri redirect) {
    final s = (raw ?? '').trim();
    if (s.isEmpty || s == micropubDefaultClientId) {
      return micropubLoopbackClientId(redirect) ?? micropubDefaultClientId;
    }
    final u = Uri.tryParse(s);
    if (u == null || (u.scheme != 'https' && u.scheme != 'http') || u.host.isEmpty || u.hasFragment) {
      throw const ConnectException('The client id must be an http(s) URL without a #fragment', field: 'clientId');
    }
    return u.path.isEmpty ? u.replace(path: '/').toString() : u.toString();
  }

  Future<(OAuthTokens, String)> _indieAuth(MicropubDiscovery disc, String? rawClientId, AdapterContext ctx) async {
    final broker = ctx.requireBroker();
    final redirect = broker.chooseRedirectUri(loopbackOk: true, customSchemeOk: true);
    final clientId = _clientId(rawClientId, redirect);
    final client = OAuth2Client(
      authorizationEndpoint: disc.authorizationEndpoint!,
      tokenEndpoint: disc.tokenEndpoint!,
      clientId: clientId,
      scopes: micropubScopes,
      usePkce: true,
      clientAuth: ClientAuth.body,
      extraAuthorizationParams: {'me': disc.me.toString()},
    );
    final req = client.buildAuthorizationUrl(redirectUri: redirect);
    ctx.progress('Waiting for you to approve NEFORUM on ${disc.authorizationEndpoint!.host}');
    final back = await broker.authorize(req.url, redirect);
    final iss = back.queryParameters['iss'];
    if (disc.issuer != null && (iss != null || disc.issParameterSupported) && iss != disc.issuer) {
      throw const ConnectException('The sign-in answer came from a different server than expected (issuer mismatch). '
          'Please try again.');
    }
    final String code;
    try {
      code = client.extractCode(back, req);
    } on OAuthException catch (e) {
      if (e.error == 'access_denied') throw const AuthCancelled('You did not approve NEFORUM on your site');
      throw ConnectException('Sign-in failed: ${e.description ?? e.error ?? e.message}');
    }
    ctx.progress('Fetching the access token');
    try {
      final tokens = await client.exchangeCode(ctx.http, code: code, redirectUri: redirect, pkce: req.pkce, now: ctx.now());
      return (tokens, clientId);
    } on OAuthException catch (e) {
      throw ConnectException('Your token endpoint refused the sign-in: ${e.description ?? e.error ?? e.message}');
    } on HttpFailure catch (f) {
      throw ConnectException('Your token endpoint answered HTTP ${f.statusCode}.');
    }
  }

  Future<Map<String, dynamic>> _queryConfig(Uri micropub, String token, AdapterContext ctx) async {
    ctx.progress('Reading your Micropub configuration');
    final url = micropub.replace(queryParameters: {...micropub.queryParameters, 'q': 'config'});
    try {
      final r = await ctx.http.get(url, headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'});
      return r.jsonMap;
    } on HttpFailure catch (f) {
      if (f.statusCode == 401 || f.statusCode == 403) {
        throw const ConnectException('Your Micropub endpoint rejected the token. Create a new one and try again.',
            field: 'token');
      }
      // q=config is only mandatory for servers with a media endpoint.
      ctx.log.info('q=config failed with HTTP ${f.statusCode}; continuing without it');
      return const {};
    } on Exception catch (e) {
      throw ConnectException('Could not reach your Micropub endpoint ${micropub.host}: $e');
    }
  }

  // ---------------------------------------------------------------- refresh

  @override
  Future<Map<String, String>?> refreshSecrets(
      ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) {
      throw const AdapterException(PublishError.auth('No Micropub token stored; reconnect the account'));
    }
    if (!tokens.isExpired(now: ctx.now())) return null;
    final refresh = tokens.refreshToken;
    final tokenEp = account.configString('tokenEndpoint');
    if (refresh == null || refresh.isEmpty || tokenEp.isEmpty) {
      throw const AdapterException(PublishError.auth('Your site\'s access token expired; reconnect the account'));
    }
    final client = OAuth2Client(
      authorizationEndpoint: Uri.parse(account.configString('authorizationEndpoint', tokenEp)),
      tokenEndpoint: Uri.parse(tokenEp),
      clientId: account.configString('clientId', micropubDefaultClientId),
      clientAuth: ClientAuth.body,
    );
    try {
      final fresh = await client.refresh(ctx.http, refreshToken: refresh, now: ctx.now());
      return fresh.toSecrets(secrets);
    } on OAuthException catch (e) {
      throw AdapterException(e.toRefreshError('Your site'));
    } on Exception catch (e) {
      throw AdapterException(PublishError.network('Could not renew the Micropub token', raw: '$e'));
    }
  }

  // --------------------------------------------------------------- validate

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = RulesValidator.validate(variant, descriptor, tier: account.tier);
    final microblog = account.config['microblog'] == true;
    final untitled = (variant.title ?? '').trim().isEmpty;
    if (microblog && untitled && variant.text.runes.length > microblogShortPostChars) {
      issues.add(const ValidationIssue.info('microblog.long_untitled',
          'Micro.blog shortens untitled posts over 300 characters in the timeline; add a title to post a full article',
          field: 'title'));
    }
    final status = blogStr(variant.extra['postStatus']);
    if (status != null && status != 'draft' && status != 'published') {
      issues.add(const ValidationIssue.error('micropub.post_status', 'postStatus must be "draft" or "published"',
          field: 'extra'));
    }
    if (account.configString('micropubEndpoint').isEmpty) {
      issues.add(const ValidationIssue.error('account.micropub_missing',
          'This account has no Micropub endpoint; reconnect it', field: 'account'));
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
      ctx.log.warn('Micropub publish failed: ${e.error.message}');
      return PublishResult.failure(e.error);
    }
  }

  Future<PublishResult> _publish(
      PostVariant v, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final endpointRaw = account.configString('micropubEndpoint');
    if (endpointRaw.isEmpty) {
      throw const AdapterException(PublishError.configuration('No Micropub endpoint stored; reconnect the account'));
    }
    final endpoint = Uri.parse(endpointRaw);
    final token = OAuthTokens.fromSecrets(secrets)?.accessToken;
    if (token == null) throw const AdapterException(PublishError.auth('No Micropub token stored; reconnect the account'));
    final errors = validate(v, account).errors.toList();
    if (errors.isNotEmpty) throw AdapterException(PublishError.validation(errors.first.message));

    final mediaRaw = account.configString('mediaEndpoint');
    final media = mediaRaw.isEmpty ? null : Uri.parse(mediaRaw);
    final photos = v.media.where((m) => m.isImage).toList();
    final videos = v.media.where((m) => m.isVideo).toList();

    final pairs = <MapEntry<String, String>>[const MapEntry('h', 'entry')];
    if (v.text.trim().isNotEmpty) pairs.add(MapEntry('content', v.text));
    final title = v.title?.trim();
    if (title != null && title.isNotEmpty) pairs.add(MapEntry('name', title));
    for (final t in v.tags) {
      pairs.add(MapEntry('category[]', t));
    }

    final files = <MultipartFile>[];
    if (media != null) {
      final total = v.media.length;
      var n = 0;
      final photoUrls = <String>[];
      final videoUrls = <String>[];
      for (final m in [...photos, ...videos]) {
        n++;
        final url = await _uploadMedia(media, token, m, n, total, ctx);
        (m.isVideo ? videoUrls : photoUrls).add(url);
      }
      _addArray(pairs, 'photo', photoUrls);
      _addArray(pairs, 'video', videoUrls);
    } else {
      for (final m in [...photos, ...videos]) {
        final field = m.isVideo ? (videos.length > 1 ? 'video[]' : 'video') : (photos.length > 1 ? 'photo[]' : 'photo');
        files.add(MultipartFile(field, blogFileName(m), m.mimeType, await ctx.readMedia(m)));
      }
    }
    if (photos.any((m) => (m.altText ?? '').trim().isNotEmpty)) {
      _addArray(pairs, 'mp-photo-alt', [for (final m in photos) m.altText?.trim() ?? '']);
    }
    _addExtras(pairs, v, account);

    ctx.progress(files.isEmpty ? 'Posting to ${endpoint.host}' : 'Uploading the post with ${files.length} file(s)');
    final res = await guardBlog('Micropub post', () => _send(endpoint, token, pairs, files, ctx),
        mapHttp: (f) => micropubError(f, context: 'Micropub post'));
    final json = res.jsonMap;
    final location = res.headers['location'];
    final url = location != null && location.isNotEmpty
        ? endpoint.resolve(location.trim()).toString()
        : blogStr(json['url']) ?? blogStr(json['preview']);
    if (url == null) {
      throw AdapterException(PublishError.platform(
          'Your site accepted the post (HTTP ${res.statusCode}) but did not say where it is',
          raw: blogSnippet(res.body)));
    }
    ctx.log.info('Posted to ${endpoint.host}: $url');
    return PublishResult.ok(remoteId: url, remoteUrl: url, publishedAt: ctx.now());
  }

  Future<NeforumResponse> _send(Uri endpoint, String token, List<MapEntry<String, String>> pairs,
      List<MultipartFile> files, AdapterContext ctx) {
    final headers = {'Authorization': 'Bearer $token', 'Accept': 'application/json'};
    if (files.isEmpty) {
      return ctx.http.send('POST', endpoint,
          headers: {...headers, 'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8'},
          bytes: Uint8List.fromList(utf8.encode(encodeFormPairs(pairs))));
    }
    final mp = encodeMultipart(pairs, files);
    return ctx.http.send('POST', endpoint,
        headers: {...headers, 'Content-Type': mp.contentType}, bytes: mp.body, timeout: blogUploadTimeout);
  }

  Future<String> _uploadMedia(Uri media, String token, MediaAttachment m, int n, int total, AdapterContext ctx) async {
    ctx.progress('Uploading ${m.isVideo ? 'video' : 'image'} $n of $total');
    final context = 'Media upload $n/$total';
    final bytes = await ctx.readMedia(m);
    final res = await guardBlog(context, () => ctx.http.send('POST', media,
            headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
            fields: const {},
            files: [HttpFilePart(field: 'file', bytes: bytes, fileName: blogFileName(m), contentType: m.mimeType)],
            timeout: blogUploadTimeout),
        mapHttp: (f) => micropubError(f, context: context));
    final location = res.headers['location'] ?? blogStr(res.jsonMap['url']);
    if (location == null || location.isEmpty) {
      throw AdapterException(PublishError.platform('$context: your media endpoint returned no file URL',
          raw: blogSnippet(res.body)));
    }
    return media.resolve(location.trim()).toString();
  }

  void _addArray(List<MapEntry<String, String>> pairs, String name, List<String> values) {
    if (values.isEmpty) return;
    final key = values.length > 1 ? '$name[]' : name;
    for (final x in values) {
      pairs.add(MapEntry(key, x));
    }
  }

  void _addExtras(List<MapEntry<String, String>> pairs, PostVariant v, ConnectedAccount account) {
    final status = blogStr(v.extra['postStatus']) ?? (v.extra['draft'] == true ? 'draft' : null);
    if (status != null) pairs.add(MapEntry('post-status', status));
    final slug = blogStr(v.extra['slug']);
    if (slug != null) pairs.add(MapEntry('mp-slug', slug));
    final syndicate = v.extra.containsKey('syndicateTo')
        ? blogStrings(v.extra['syndicateTo'])
        : blogStrings(account.config['syndicateTo']);
    for (final s in syndicate) {
      pairs.add(MapEntry('mp-syndicate-to[]', s));
    }
    final dest = blogStr(v.extra['destination']) ?? blogStr(account.config['destination']);
    if (dest != null) pairs.add(MapEntry('mp-destination', dest));
  }

  // ---------------------------------------------------------------- hand-off

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final me = account?.configString('me') ?? '';
    final microblog = account == null || account.config['microblog'] == true || _isMicroblogHost(Uri.tryParse(me)?.host ?? '');
    final title = variant.title?.trim() ?? '';
    final text = variant.text;
    if (microblog) {
      return HandoffPlan(
        platformId: id,
        clipboardText: text,
        shareText: text,
        shareFiles: variant.media,
        androidPackage: 'blog.micro.android',
        iosScheme: 'microblog://post?text=${Uri.encodeComponent(text)}',
        desktopUrl: 'https://micro.blog/',
        preferred: HandoffMethod.shareSheet,
        instructions: [
          '1. Share to the Micro.blog app (or open micro.blog on the web): your text is also on the clipboard.',
          if (title.isNotEmpty) '2. Turn on the title field and type: "$title".',
          '${title.isNotEmpty ? 3 : 2}. ${variant.hasMedia ? 'Attach your photos, check' : 'Check'} the post and press **Post**.',
        ].join('\n'),
        mediaNote: variant.hasMedia ? 'Micro.blog cannot take files from a link; share them from the share sheet or attach them in the app.' : null,
      );
    }
    return HandoffPlan(
      platformId: id,
      clipboardText: text,
      shareText: text,
      shareFiles: variant.media,
      desktopUrl: me.isEmpty ? null : me,
      preferred: HandoffMethod.manual,
      instructions: [
        '1. Open your site\'s editor (NEFORUM opens your home page) and start a new post.',
        '2. Paste the text from the clipboard${title.isNotEmpty ? ' and use the title "$title"' : ''}.',
        '3. ${variant.hasMedia ? 'Attach your media, then publish' : 'Publish'} the post.',
      ].join('\n'),
      mediaNote: variant.hasMedia ? 'Media must be attached in your site\'s editor.' : null,
    );
  }

  // -------------------------------------------------------------- disconnect

  @override
  Future<void> disconnect(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.configString('authMethod') != 'indieauth') return;
    final token = OAuthTokens.fromSecrets(secrets)?.accessToken;
    if (token == null) return;
    final revocation = account.configString('revocationEndpoint');
    final tokenEp = account.configString('tokenEndpoint');
    try {
      if (revocation.isNotEmpty) {
        await ctx.http.postForm(Uri.parse(revocation), {'token': token}, throwOnError: false);
      } else if (tokenEp.isNotEmpty) {
        // Legacy IndieAuth revocation through the token endpoint.
        await ctx.http.postForm(Uri.parse(tokenEp), {'action': 'revoke', 'token': token}, throwOnError: false);
      }
    } on Exception catch (e) {
      ctx.log.warn('Could not revoke the Micropub token: $e');
    }
  }
}

bool _isMicroblogHost(String host) => host == 'micro.blog' || host.endsWith('.micro.blog');

String _handle(Uri me) {
  final path = me.path == '/' ? '' : me.path;
  return '${me.host}$path';
}

List<Map<String, String>> _targets(Object? v) => [
      for (final t in blogList(v))
        if (blogStr(blogMap(t)['uid']) != null)
          {'uid': blogStr(blogMap(t)['uid'])!, 'name': blogStr(blogMap(t)['name']) ?? blogStr(blogMap(t)['uid'])!},
    ];

List<String> _postTypes(Object? v) => [
      for (final t in blogList(v))
        if (blogStr(blogMap(t)['type']) != null) blogStr(blogMap(t)['type'])!,
    ];

