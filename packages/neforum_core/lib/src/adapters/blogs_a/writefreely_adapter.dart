import 'dart:typed_data';

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
import '../../text/rules_validator.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'blog_common.dart';

/// Default instance: the hosted Write.as service.
const String writeAsInstance = 'https://write.as';

/// Snap.as, Write.as's photo host (Write.as accounts only).
const String snapAsBase = 'https://snap.as';

/// ISO 639-1 codes of right-to-left scripts, used to set `rtl`.
const Set<String> _rtlLanguages = {'ar', 'he', 'fa', 'ur', 'yi', 'ps', 'dv', 'ug', 'sd', 'ckb'};

/// Adapter for Write.as and self-hosted WriteFreely instances.
///
/// Connect: username + password are exchanged once for an access token via
/// `POST /api/auth/login`; the password itself is never stored. Leaving the
/// username empty creates an anonymous account that publishes with
/// `POST /api/posts`. Publish: Markdown body to
/// `POST /api/collections/{alias}/posts`. Images are uploaded to Snap.as
/// (Write.as only, when enabled) or to NEFORUM's public media host and
/// embedded as Markdown.
class WriteFreelyAdapter extends PlatformAdapter {
  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'writefreely',
    name: 'Write.as / WriteFreely',
    iconKey: 'writefreely',
    homepage: 'https://writefreely.org',
    family: 'writefreely',
    tiers: {PlatformTier.openApi, PlatformTier.handoff},
    defaultTier: PlatformTier.openApi,
    text: TextRules(
      maxLength: null,
      counting: CountingRule.utf16,
      titleSupported: true,
      titleRequired: false,
      supportsThreads: false,
      supportsContentWarning: false,
      supportsMarkdown: true,
      supportsHashtags: true,
      hashtagsAsField: false,
      linkInText: true,
      notes: 'No length limit. The body is Markdown; #hashtags in the text become the post\'s tags. The title is optional.',
    ),
    media: MediaRules(
      maxImages: 20,
      maxVideos: 0,
      supportsAltText: true,
      requiresPublicMediaUrl: true,
      notes: 'WriteFreely has no upload API, so images are placed at a public URL first (Snap.as for Write.as accounts '
          'that enable it, otherwise NEFORUM\'s media host) and embedded as Markdown. 20 per post is NEFORUM\'s limit.',
    ),
    defaultQuotas: [],
    personalAccountOk: true,
    accountRequirements: 'A Write.as account or an account on any WriteFreely server; Write.as also allows anonymous posts. '
        'No developer account or app review is needed.',
    apiCostSummary: 'Free. Free Write.as accounts have a daily limit on new posts that grows with account age, and fast '
        'bursts are refused for a while; paid Write.as plans are exempt. Self-hosted WriteFreely sets its own rules.',
    setupGuide: 'docs/platforms/writefreely.md',
    serverSideScheduling: false,
    supportsLinkField: false,
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  static const ConnectField _instanceField = ConnectField(
    key: 'instance',
    label: 'Server',
    kind: FieldKind.url,
    defaultValue: writeAsInstance,
    placeholder: writeAsInstance,
    help: '`https://write.as` or the address of your WriteFreely server.',
  );

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.openApi,
          intro: '**No developer account needed.** Enter the username and password you use on Write.as or your '
              'WriteFreely server. NEFORUM swaps them for an access token once and does not keep the password.\n\n'
              'Leave the username empty to publish **anonymously** (Write.as only; anonymous posts cannot be edited '
              'from NEFORUM later).\n\n'
              'Images: Write.as Pro users can turn on **Snap.as**; everyone else needs a public media host in NEFORUM '
              'settings, because WriteFreely has no image upload.',
          fields: [
            _instanceField,
            ConnectField(
              key: 'username',
              label: 'Username',
              required: false,
              help: 'Leave empty for anonymous posts.',
            ),
            ConnectField(
              key: 'password',
              label: 'Password',
              kind: FieldKind.password,
              required: false,
              secret: true,
              help: 'Used once to get an access token; NEFORUM does not store it.',
            ),
            ConnectField(
              key: 'blog',
              label: 'Blog alias (optional)',
              required: false,
              placeholder: 'myblog',
              help: 'The blog to post to, as in `write.as/myblog`. Empty = your first blog.',
            ),
            ConnectField(
              key: 'snapAs',
              label: 'Upload images to Snap.as',
              kind: FieldKind.boolean,
              required: false,
              defaultValue: 'false',
              help: 'Write.as accounts with Snap.as access only.',
            ),
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.handoff,
          intro: 'NEFORUM copies the post (title as a `# heading`) to the clipboard and opens the editor on your server; '
              'paste it and press **Publish**.',
          fields: [_instanceField],
        ),
      ];

  // ---------------------------------------------------------------- connect

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    final instance = _instance(input['instance']);
    if (tier == PlatformTier.handoff) {
      return ConnectResult(
        account: ConnectedAccount(
          id: 'writefreely-handoff:${instance.host}${instance.path}',
          platformId: id,
          tier: PlatformTier.handoff,
          displayName: '${instance.host} (hand-off)',
          profileUrl: instance.toString(),
          createdAt: ctx.now(),
          config: {'instance': instance.toString()},
        ),
      );
    }
    final username = (input['username'] ?? '').trim();
    final password = input['password'] ?? '';
    if (username.isEmpty) {
      return ConnectResult(
        account: ConnectedAccount(
          id: 'writefreely-anon:${instance.host}${instance.path}',
          platformId: id,
          tier: PlatformTier.openApi,
          displayName: 'Anonymous (${instance.host})',
          profileUrl: instance.toString(),
          createdAt: ctx.now(),
          config: {'instance': instance.toString(), 'anonymous': true},
        ),
      );
    }
    if (password.isEmpty) throw const ConnectException('Enter your password.', field: 'password');

    final (token, user) = await _login(instance, username, password, ctx);
    final collections = await _collections(instance, token, ctx);
    final wanted = (input['blog'] ?? '').trim().toLowerCase();
    final chosen = wanted.isEmpty
        ? collections.firstOrNull
        : collections.where((c) => (blogStr(c['alias']) ?? '').toLowerCase() == wanted).firstOrNull;
    if (chosen == null) {
      final known = collections.map((c) => blogStr(c['alias'])).nonNulls.join(', ');
      throw ConnectException(wanted.isEmpty
          ? 'This account has no blog yet. Create one on ${instance.host} first.'
          : 'No blog called "$wanted" on this account${known.isEmpty ? '' : ' (you have: $known)'}.', field: 'blog');
    }
    final alias = blogStr(chosen['alias'])!;
    final collectionUrl = blogStr(chosen['url']) ?? '$instance/$alias/';
    final title = blogStr(chosen['title']) ?? alias;
    final snap = (input['snapAs'] ?? '').toLowerCase() == 'true';
    return ConnectResult(
      account: ConnectedAccount(
        id: 'writefreely:$user@${instance.host}${instance.path}/$alias',
        platformId: id,
        tier: PlatformTier.openApi,
        displayName: '$title (${instance.host})',
        handle: user,
        profileUrl: collectionUrl,
        createdAt: ctx.now(),
        config: {
          'instance': instance.toString(),
          'anonymous': false,
          'username': user,
          'alias': alias,
          'collectionUrl': collectionUrl,
          'collectionTitle': title,
          if (snap && instance.host == 'write.as') 'snapAs': true,
        },
      ),
      secrets: OAuthTokens(accessToken: token, tokenType: 'Token').toSecrets(),
    );
  }

  Uri _instance(String? raw) {
    final s = (raw ?? '').trim();
    return parseBlogSiteUrl(s.isEmpty ? writeAsInstance : s, field: 'instance', what: 'server address');
  }

  Future<(String, String)> _login(Uri instance, String username, String password, AdapterContext ctx) async {
    ctx.progress('Signing in to ${instance.host}');
    try {
      final r = await ctx.http.postJson(joinPath(instance, '/api/auth/login'), {'alias': username, 'pass': password},
          headers: {'Accept': 'application/json'});
      final data = blogMap(r.jsonMap['data']);
      final token = blogStr(data?['access_token']);
      if (token == null) throw const FormatException('no access_token');
      return (token, blogStr(blogMap(data?['user'])?['username']) ?? username);
    } on HttpFailure catch (f) {
      final msg = _errorMsg(f.response);
      // The API answers 404 "User doesn't exist." for an unknown username; a
      // 404 without the API's JSON error means there is no API at all.
      final noApi = f.statusCode == 404 && msg == null;
      throw ConnectException(switch (f.statusCode) {
        400 || 401 || 403 => 'Wrong username or password${msg == null ? '' : ' ($msg)'}.',
        404 when noApi => '${instance.host} does not offer the WriteFreely API. Check the server address.',
        404 => 'There is no account called "$username" on ${instance.host} ($msg).',
        429 => 'Too many sign-in attempts. Wait a few minutes and try again.',
        _ => '${instance.host} answered HTTP ${f.statusCode} while signing in${msg == null ? '' : ': $msg'}.',
      }, field: noApi ? 'instance' : (f.statusCode == 404 ? 'username' : 'password'));
    } on FormatException {
      throw ConnectException('${instance.host} did not return an access token. Is this a WriteFreely server?');
    } on Exception catch (e) {
      throw ConnectException('Could not reach ${instance.host}: $e');
    }
  }

  Future<List<Map<String, dynamic>>> _collections(Uri instance, String token, AdapterContext ctx) async {
    ctx.progress('Loading your blogs');
    try {
      final r = await ctx.http.get(joinPath(instance, '/api/me/collections'), headers: _authHeaders(token));
      return blogList(r.jsonMap['data']).map(blogMap).nonNulls.toList();
    } on HttpFailure catch (f) {
      throw ConnectException('${instance.host} answered HTTP ${f.statusCode} while listing your blogs.');
    } on Exception catch (e) {
      throw ConnectException('Could not reach ${instance.host}: $e');
    }
  }

  static Map<String, String> _authHeaders(String? token) =>
      {'Accept': 'application/json', if (token != null) 'Authorization': 'Token $token'};

  // --------------------------------------------------------------- validate

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = RulesValidator.validate(variant, descriptor, tier: account.tier);
    if (variant.hasMedia) {
      if (account.tier == PlatformTier.handoff) {
        issues.add(const ValidationIssue.warning('writefreely.handoff_media',
            'The editor cannot receive files; add image links yourself', field: 'media'));
      } else if (account.config['snapAs'] != true) {
        issues.add(const ValidationIssue.warning('writefreely.media_host',
            'WriteFreely has no image upload; images need a public media host in NEFORUM settings', field: 'media'));
      }
    }
    if (variant.visibility != Visibility.public && account.tier != PlatformTier.handoff) {
      issues.add(const ValidationIssue.warning('writefreely.visibility',
          'Who can read the post is set by the blog\'s own visibility on the server, not per post', field: 'visibility'));
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
      ctx.log.warn('WriteFreely publish failed: ${e.error.message}');
      return PublishResult.failure(e.error);
    } on Exception catch (e) {
      ctx.log.warn('WriteFreely publish failed unexpectedly: $e');
      return PublishResult.failure(unexpectedBlogError('WriteFreely', e));
    }
  }

  Future<PublishResult> _publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier == PlatformTier.handoff) {
      throw const AdapterException(PublishError.unsupported('Hand-off accounts publish through the editor'));
    }
    final instanceRaw = account.configString('instance');
    if (instanceRaw.isEmpty) {
      throw const AdapterException(PublishError.configuration('This account has no server address; reconnect it'));
    }
    final instance = Uri.parse(instanceRaw);
    final anonymous = account.config['anonymous'] == true;
    final alias = account.configString('alias');
    final token = OAuthTokens.fromSecrets(secrets)?.accessToken;
    if (!anonymous && (token == null || alias.isEmpty)) {
      throw const AdapterException(PublishError.auth('No access token stored for this blog; reconnect the account'));
    }
    if (variant.media.any((m) => m.isVideo)) {
      throw const AdapterException(PublishError.unsupported('WriteFreely posts cannot contain uploaded videos'));
    }

    final images = <String>[];
    for (var i = 0; i < variant.media.length; i++) {
      final m = variant.media[i];
      final url = await _hostImage(m, i, variant.media.length, account, anonymous ? null : token, ctx);
      images.add('![${_altForMarkdown(m.altText)}]($url)');
    }
    final body = [variant.text.trim(), ...images].where((s) => s.isNotEmpty).join('\n\n');
    final title = (variant.title ?? '').trim();
    final lang = _lang(variant.language);
    final rtl = variant.extra['rtl'] is bool ? variant.extra['rtl'] as bool : _rtlLanguages.contains(lang);
    final font = blogStr(variant.extra['font']);
    final slug = blogStr(variant.extra['slug']);
    final payload = <String, Object?>{
      'body': body,
      if (title.isNotEmpty) 'title': title,
      'lang': ?lang,
      'rtl': rtl,
      'font': ?font,
      if (!anonymous) 'slug': ?slug,
    };
    final url = anonymous ? joinPath(instance, '/api/posts') : joinPath(instance, '/api/collections/$alias/posts');
    ctx.progress('Publishing the post');
    final NeforumResponse r;
    try {
      r = await ctx.http.postJson(url, payload, headers: _authHeaders(anonymous ? null : token));
    } on HttpFailure catch (f) {
      throw AdapterException(mapWriteFreelyFailure(f, 'WriteFreely post'));
    } on Exception catch (e) {
      throw AdapterException(PublishError.network('WriteFreely post failed: $e', raw: '$e'));
    }
    final data = blogMap(r.jsonMap['data']);
    final postId = blogStr(data?['id']);
    if (data == null || postId == null) {
      throw AdapterException(PublishError.platform('The server did not return the created post', raw: bodySnippet(r)));
    }
    return PublishResult.ok(remoteId: postId, remoteUrl: _postUrl(instance, data, account, anonymous), publishedAt: ctx.now());
  }

  String _postUrl(Uri instance, Map<String, dynamic> data, ConnectedAccount account, bool anonymous) {
    final id = blogStr(data['id'])!;
    if (anonymous) return '$instance/$id';
    final slug = blogStr(data['slug']);
    final base = blogStr(blogMap(data['collection'])?['url']) ?? blogStr(account.config['collectionUrl']);
    if (slug == null || base == null) return '$instance/$id';
    return base.endsWith('/') ? '$base$slug' : '$base/$slug';
  }

  Future<String> _hostImage(
      MediaAttachment m, int index, int total, ConnectedAccount account, String? token, AdapterContext ctx) async {
    final useSnap = account.config['snapAs'] == true && token != null;
    final host = ctx.mediaHost;
    if (!useSnap && host == null) {
      throw const AdapterException(PublishError.configuration(
          'WriteFreely cannot store images. Configure a public media host in NEFORUM settings '
          '(or turn on Snap.as for a Write.as account), or remove the images.'));
    }
    ctx.progress('Uploading image ${index + 1} of $total to ${useSnap ? 'Snap.as' : host!.name}');
    final bytes = await readBlogMedia(ctx, m);
    if (useSnap) return _snapAs(m, bytes, token, index, total, ctx);
    try {
      return (await host!.upload(m, bytes)).url.toString();
    } on Object catch (e) {
      throw AdapterException(PublishError.network('Upload to ${host!.name} failed: $e', raw: '$e'));
    }
  }

  Future<String> _snapAs(
      MediaAttachment m, Uint8List bytes, String token, int index, int total, AdapterContext ctx) async {
    final what = 'Snap.as upload ${index + 1}/$total';
    try {
      // Snap.as documents the raw token (no "Token" prefix).
      final r = await ctx.http.multipart(Uri.parse('$snapAsBase/api/photos/upload'),
          headers: {'Authorization': token, 'Accept': 'application/json'},
          files: [HttpFilePart(field: 'file', bytes: bytes, fileName: safeFileName(m), contentType: m.mimeType)]);
      final url = blogStr(blogMap(r.jsonMap['data'])?['url']);
      if (url == null) throw AdapterException(PublishError.platform('$what: no URL returned', raw: bodySnippet(r)));
      return url;
    } on HttpFailure catch (f) {
      throw AdapterException(mapWriteFreelyFailure(f, what));
    } on AdapterException {
      rethrow;
    } on Exception catch (e) {
      throw AdapterException(PublishError.network('$what failed: $e', raw: '$e'));
    }
  }

  static String _altForMarkdown(String? alt) =>
      (alt ?? '').replaceAll(RegExp(r'[\[\]\r\n]+'), ' ').replaceAll(RegExp(r'\s{2,}'), ' ').trim();

  static String? _lang(String? bcp47) {
    final primary = (bcp47 ?? '').split(RegExp('[-_]')).first.toLowerCase();
    return RegExp(r'^[a-z]{2,3}$').hasMatch(primary) ? primary : null;
  }

  // -------------------------------------------------------------- disconnect

  @override
  Future<void> disconnect(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final token = OAuthTokens.fromSecrets(secrets)?.accessToken;
    final instance = account.configString('instance');
    if (token == null || instance.isEmpty) return;
    try {
      await ctx.http.delete(joinPath(Uri.parse(instance), '/api/auth/me'), headers: _authHeaders(token));
    } on Object catch (e) {
      ctx.log.warn('Could not revoke the WriteFreely token: $e');
    }
  }

  // ---------------------------------------------------------------- hand-off

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final instanceRaw = account?.configString('instance') ?? '';
    final instance = instanceRaw.isEmpty ? writeAsInstance : instanceRaw;
    final title = (variant.title ?? '').trim();
    final text = fullText(variant);
    final clip = title.isEmpty ? text : '# $title\n\n$text';
    return HandoffPlan(
      platformId: id,
      clipboardText: clip,
      shareText: clip,
      shareFiles: variant.media,
      desktopUrl: instance,
      preferred: HandoffMethod.manual,
      instructions: [
        '1. NEFORUM opens ${Uri.parse(instance).host}; sign in and start a new post.',
        '2. Paste the text from the clipboard (the first `# ` line becomes the title).',
        if (variant.hasMedia) '3. Add your images as Markdown links (`![description](https://...)`).',
        '${variant.hasMedia ? 4 : 3}. Press **Publish**.',
      ].join('\n'),
      mediaNote: variant.hasMedia
          ? 'WriteFreely editors cannot receive files; images must be uploaded elsewhere and linked.'
          : null,
    );
  }
}

/// Maps a Write.as / WriteFreely failure (`{code, error_msg}`) onto a
/// [PublishError].
PublishError mapWriteFreelyFailure(HttpFailure f, String what) {
  final msg = _errorMsg(f.response);
  final suffix = msg == null ? '' : ': $msg';
  final raw = bodySnippet(f.response);
  return switch (f.statusCode) {
    401 => PublishError.auth('$what: the access token is no longer valid$suffix. Reconnect the account.',
        raw: raw, statusCode: 401),
    // "You don't have permission to add to this collection." / "Account is silenced."
    403 => PublishError.auth('$what: this account is not allowed to do that$suffix', raw: raw, statusCode: 403),
    429 => PublishError.quota(
        '$what: posting limit reached$suffix. Free Write.as accounts can only publish a few posts per day.',
        raw: raw,
        statusCode: 429,
        retryAfter: f.response.retryAfter),
    404 => PublishError.configuration('$what: blog not found on ${f.url.host}$suffix. Reconnect the account.'),
    410 => PublishError.platform('$what: gone$suffix', raw: raw, statusCode: 410),
    _ => f.toPublishError(context: '$what$suffix'),
  };
}

String? _errorMsg(NeforumResponse r) => blogStr(r.jsonMap['error_msg']);
