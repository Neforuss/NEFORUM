import 'package:uuid/uuid.dart';

import '../../auth/auth_broker.dart';
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
import 'misskey_api.dart';

/// Upstream Misskey default `MAX_NOTE_TEXT_LENGTH` (packages/backend/src/const.ts).
const int misskeyDefaultMaxNoteLength = 3000;

/// Upstream default role policy `maxFileSizeMb` = 30 (MiB).
const int misskeyDefaultMaxFileBytes = 30 * 1024 * 1024;

/// `notes/create` accepts at most 16 `fileIds`.
const int misskeyMaxFilesPerNote = 16;

/// `cw` maxLength on `notes/create`.
const int misskeyMaxCwLength = 100;

/// `DB_MAX_IMAGE_COMMENT_LENGTH`: alt text (Drive file comment) limit.
const int misskeyMaxAltLength = 512;

/// Permissions NEFORUM needs on the token.
const List<String> misskeyPermissions = ['write:notes', 'write:drive', 'read:account'];

/// Adapter for Misskey and Misskey-API servers (Sharkey, CherryPick, legacy
/// Firefish / Iceshrimp-JS). Iceshrimp.NET speaks the Mastodon API instead.
///
/// Connect: instance + an access token from Settings > API, or (token left
/// empty) the MiAuth browser flow. Publish: one `drive/files/create` per
/// media file, then `notes/create`; long posts become a reply chain.
class MisskeyAdapter extends PlatformAdapter {
  /// [newSessionId] generates MiAuth session ids (UUID v4); injectable for
  /// tests.
  MisskeyAdapter({String Function()? newSessionId}) : _newSessionId = newSessionId ?? (() => const Uuid().v4());

  final String Function() _newSessionId;

  static const Set<String> _imageTypes = {
    'image/jpeg',
    'image/png',
    'image/gif',
    'image/webp',
    'image/avif',
    'image/apng',
    'image/bmp',
    'image/tiff',
  };

  static const Set<String> _videoTypes = {
    'video/mp4',
    'video/quicktime',
    'video/webm',
    'video/ogg',
    'video/mpeg',
    'video/x-m4v',
    'video/3gpp',
  };

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'misskey',
    name: 'Misskey',
    iconKey: 'misskey',
    homepage: 'https://misskey-hub.net',
    family: 'misskey-api',
    tiers: {PlatformTier.openApi, PlatformTier.handoff},
    defaultTier: PlatformTier.openApi,
    text: TextRules(
      maxLength: misskeyDefaultMaxNoteLength,
      // The server counts code points; UTF-16 is never lower, so it is the
      // safe choice (an emoji outside the BMP counts 2 here, 1 on the server).
      counting: CountingRule.utf16,
      supportsThreads: true,
      supportsContentWarning: true,
      supportsMarkdown: true,
      supportsHashtags: true,
      mentionCountsDomain: true,
      linkInText: true,
      notes: 'Limit is per instance (3000 on misskey.io, up to 100000 on some Sharkey servers); '
          'NEFORUM reads it when you connect. Text is MFM (Markdown-like). URLs count at full length. '
          'Content warning max 100 characters.',
    ),
    media: MediaRules(
      maxImages: misskeyMaxFilesPerNote,
      maxVideos: misskeyMaxFilesPerNote,
      allowsMixedImageVideo: true,
      imageMaxBytes: misskeyDefaultMaxFileBytes,
      videoMaxBytes: misskeyDefaultMaxFileBytes,
      imageMimeTypes: _imageTypes,
      videoMimeTypes: _videoTypes,
      supportsAltText: true,
      notes: 'Up to 16 files per note, images and videos mixed. Per-file size and Drive capacity are '
          'set by your instance (default 30 MB per file, 100 MB Drive). Alt text max 512 characters.',
    ),
    defaultQuotas: [
      QuotaRule(
        id: 'misskey.notes_per_hour',
        limit: 300,
        window: Duration(hours: 1),
        note: 'notes per hour (upstream Misskey default; instances can scale it)',
        appliesToTier: PlatformTier.openApi,
      ),
    ],
    personalAccountOk: true,
    accountRequirements: 'Any ordinary account on a Misskey, Sharkey, CherryPick, Firefish or Iceshrimp-JS server. '
        'No developer account or app review is needed.',
    apiCostSummary: 'Free. Your server allows about 300 notes and 120 file uploads per hour, '
        'and sets its own file-size and storage limits.',
    setupGuide: 'docs/platforms/misskey.md',
    serverSideScheduling: false,
    supportsLinkField: false,
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  static const ConnectField _instanceField = ConnectField(
    key: 'instance',
    label: 'Instance',
    kind: FieldKind.url,
    placeholder: 'misskey.io',
    help: 'The server your account lives on, e.g. `misskey.io`, `misskey.design` or a Sharkey server. '
        'You can also paste your handle (`@you@misskey.io`).',
  );

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.openApi,
          usesBrowser: true,
          loopbackRedirectOk: true,
          customSchemeRedirectOk: true,
          intro: '**Misskey needs no developer account.** Choose one way to sign in:\n\n'
              '1. **Browser sign-in (MiAuth, easiest):** enter your instance and leave the token empty. '
              'NEFORUM opens your server in the browser; check that it asks for *Compose or delete notes*, '
              '*Edit or delete your Drive files* and *View your account information*, then tap **Allow**.\n'
              '2. **Paste a token:** on your server open **Settings > API > Generate access token**, '
              'name it `NEFORUM`, tick **write:notes**, **write:drive** and **read:account**, '
              'create it and paste the token below.\n\n'
              'Works with Misskey, Sharkey, CherryPick and older Firefish / Iceshrimp-JS servers. '
              'Iceshrimp.NET servers: use the Mastodon option instead.',
          redirectNote: 'Nothing to register: Misskey has no developer portal. The browser sign-in returns to '
              'http://127.0.0.1:52771/callback on desktop and neforum://callback on mobile automatically.',
          fields: [
            _instanceField,
            ConnectField(
              key: 'token',
              label: 'Access token (optional)',
              kind: FieldKind.password,
              required: false,
              secret: true,
              help: 'Leave empty to sign in through the browser. Otherwise: Settings > API > Generate access token, '
                  'with the permissions write:notes, write:drive and read:account.',
            ),
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.handoff,
          intro: 'NEFORUM opens your server\'s share page with the text filled in; you check it and press **Note**. '
              'You must be signed in to your server in the browser. Media cannot be attached automatically.',
          fields: [_instanceField],
        ),
      ];

  // ---------------------------------------------------------------- connect

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    final instance = parseMisskeyInstance(input['instance'] ?? '');
    final meta = await _fetchMeta(instance, ctx);
    if (tier == PlatformTier.handoff) {
      return ConnectResult(
        account: ConnectedAccount(
          id: 'misskey-handoff:${instance.authority}',
          platformId: id,
          tier: PlatformTier.handoff,
          displayName: '${_str(meta['name']) ?? instance.host} (hand-off)',
          createdAt: ctx.now(),
          profileUrl: instance.toString(),
          config: _configFrom(instance, meta, const {}, 'handoff'),
        ),
      );
    }

    var token = (input['token'] ?? '').trim();
    var method = 'token';
    if (token.isEmpty) {
      if (ctx.broker == null) {
        throw const ConnectException('Paste an access token (Settings > API on your server).', field: 'token');
      }
      final features = meta['features'];
      if (features is Map && features['miauth'] == false) {
        throw const ConnectException('This server does not support browser sign-in. Paste an access token instead.',
            field: 'token');
      }
      token = await _miauth(instance, ctx);
      method = 'miauth';
    }

    final me = await _verifyToken(instance, token, ctx);
    final userId = _str(me['id']);
    final username = _str(me['username']);
    if (userId == null || username == null) {
      throw const ConnectException('The server answered, but not with a user. Is this a Misskey-API server?');
    }
    final name = _str(me['name']);
    return ConnectResult(
      account: ConnectedAccount(
        id: 'misskey:$userId@${instance.authority}',
        platformId: id,
        tier: PlatformTier.openApi,
        displayName: '${name ?? username} (${instance.host})',
        handle: '@$username@${instance.host}',
        avatarUrl: _str(me['avatarUrl']),
        profileUrl: '$instance/@$username',
        createdAt: ctx.now(),
        config: {
          ..._configFrom(instance, meta, me, method),
          'userId': userId,
          'username': username,
        },
      ),
      secrets: OAuthTokens(accessToken: token, tokenType: 'Misskey', scope: misskeyPermissions.join(',')).toSecrets(),
    );
  }

  Future<Map<String, dynamic>> _fetchMeta(Uri instance, AdapterContext ctx) async {
    ctx.progress('Contacting ${instance.host}');
    try {
      final meta = await MisskeyApi(instance, ctx).callMap('meta', {'detail': true});
      if (meta['version'] == null && meta['maxNoteTextLength'] == null) throw const FormatException('no version');
      return meta;
    } on HttpFailure catch (f) {
      throw ConnectException(f.statusCode == 404
          ? '${instance.host} does not offer the Misskey API. Iceshrimp.NET and Mastodon servers need the Mastodon option.'
          : '${instance.host} answered HTTP ${f.statusCode}. Check the address and try again.');
    } on FormatException {
      throw ConnectException('${instance.host} does not look like a Misskey, Sharkey or Firefish server.');
    } on Exception catch (e) {
      throw ConnectException('Could not reach ${instance.host}: $e');
    }
  }

  /// MiAuth: open `/miauth/{uuid}`, wait for the redirect, then exchange the
  /// session once via `/api/miauth/{uuid}/check`.
  Future<String> _miauth(Uri instance, AdapterContext ctx) async {
    final broker = ctx.requireBroker();
    final session = _newSessionId();
    final redirect = broker.chooseRedirectUri(loopbackOk: true, customSchemeOk: true);
    final authUrl = instance.replace(path: '/miauth/$session', queryParameters: {
      'name': 'NEFORUM',
      // A urn: "redirect" means a paste-code broker: let Misskey just show
      // its success page instead of navigating to an unloadable URL.
      if (redirect.scheme != 'urn') 'callback': redirect.toString(),
      'permission': misskeyPermissions.join(','),
    });
    final back = await broker.authorize(authUrl, redirect);
    final returned = back.queryParameters['session'];
    if (returned != null && returned != session) {
      throw const ConnectException('The browser returned a different sign-in session. Please try again.');
    }
    ctx.progress('Fetching the token from ${instance.host}');
    final Map<String, dynamic> res;
    try {
      res = await MisskeyApi(instance, ctx).miauthCheck(session);
    } on HttpFailure catch (f) {
      throw ConnectException('${instance.host} refused the sign-in (HTTP ${f.statusCode}).');
    }
    final token = _str(res['token']);
    if (res['ok'] != true || token == null) {
      throw const AuthCancelled('The sign-in was not approved on the server. Press Allow on the Misskey page and try again.');
    }
    return token;
  }

  Future<Map<String, dynamic>> _verifyToken(Uri instance, String token, AdapterContext ctx) async {
    ctx.progress('Checking the token');
    try {
      return await MisskeyApi(instance, ctx, token: token).callMap('i');
    } on HttpFailure catch (f) {
      final code = MisskeyApiError.fromResponse(f.response)?.code;
      if (code == 'PERMISSION_DENIED') {
        throw const ConnectException('The token is missing the read:account permission. '
            'Generate a new one with write:notes, write:drive and read:account.', field: 'token');
      }
      if (f.statusCode == 401 || f.statusCode == 403 || code == 'AUTHENTICATION_FAILED') {
        throw const ConnectException('The server rejected this access token. Copy it again or generate a new one.',
            field: 'token');
      }
      throw ConnectException('${instance.host} answered HTTP ${f.statusCode} while checking the token.');
    } on ConnectException {
      rethrow;
    } on Exception catch (e) {
      throw ConnectException('Could not reach ${instance.host}: $e');
    }
  }

  Map<String, dynamic> _configFrom(Uri instance, Map<String, dynamic> meta, Map<String, dynamic> me, String method) {
    final metaPolicies = meta['policies'];
    final mePolicies = me['policies'];
    // The user's own policies (from /api/i) beat the instance defaults.
    final policies = <String, dynamic>{
      if (metaPolicies is Map) ...Map<String, dynamic>.from(metaPolicies),
      if (mePolicies is Map) ...Map<String, dynamic>.from(mePolicies),
    };
    final features = meta['features'];
    final types = policies['uploadableFileTypes'];
    return {
      'instance': instance.toString(),
      'host': instance.host,
      'authMethod': method,
      if (_str(meta['name']) != null) 'instanceName': _str(meta['name']),
      if (_str(meta['version']) != null) 'version': _str(meta['version']),
      if (meta['maxNoteTextLength'] is num) 'maxNoteTextLength': (meta['maxNoteTextLength'] as num).toInt(),
      if (meta['maxFileSize'] is num) 'maxFileSize': (meta['maxFileSize'] as num).toInt(),
      if (policies['maxFileSizeMb'] is num) 'maxFileSizeMb': (policies['maxFileSizeMb'] as num).toInt(),
      if (policies['driveCapacityMb'] is num) 'driveCapacityMb': (policies['driveCapacityMb'] as num).toInt(),
      if (policies['canPublicNote'] is bool) 'canPublicNote': policies['canPublicNote'],
      if (types is List) 'uploadableFileTypes': types.whereType<String>().toList(),
      if (features is Map && features['miauth'] is bool) 'miauth': features['miauth'],
    };
  }

  // --------------------------------------------------------------- validate

  /// The descriptor with this account's instance limits (note length, file
  /// size) applied. Use it wherever per-account limits matter.
  @override
  PlatformDescriptor descriptorForAccount(ConnectedAccount account) => descriptorFor(account);

  PlatformDescriptor descriptorFor(ConnectedAccount account) {
    final d = _descriptor;
    final maxLen = _int(account.config['maxNoteTextLength']);
    final maxBytes = _maxFileBytes(account);
    if (maxLen == null && maxBytes == null) return d;
    final t = d.text;
    final m = d.media;
    return PlatformDescriptor(
      id: d.id,
      name: d.name,
      iconKey: d.iconKey,
      homepage: d.homepage,
      family: d.family,
      tiers: d.tiers,
      defaultTier: d.defaultTier,
      text: TextRules(
        maxLength: maxLen ?? t.maxLength,
        counting: t.counting,
        supportsThreads: t.supportsThreads,
        supportsContentWarning: t.supportsContentWarning,
        supportsMarkdown: t.supportsMarkdown,
        supportsHashtags: t.supportsHashtags,
        mentionCountsDomain: t.mentionCountsDomain,
        linkInText: t.linkInText,
        notes: t.notes,
      ),
      media: MediaRules(
        maxImages: m.maxImages,
        maxVideos: m.maxVideos,
        allowsMixedImageVideo: m.allowsMixedImageVideo,
        imageMaxBytes: maxBytes ?? m.imageMaxBytes,
        videoMaxBytes: maxBytes ?? m.videoMaxBytes,
        imageMimeTypes: m.imageMimeTypes,
        videoMimeTypes: m.videoMimeTypes,
        supportsAltText: m.supportsAltText,
        notes: m.notes,
      ),
      defaultQuotas: d.defaultQuotas,
      personalAccountOk: d.personalAccountOk,
      accountRequirements: d.accountRequirements,
      apiCostSummary: d.apiCostSummary,
      setupGuide: d.setupGuide,
      serverSideScheduling: d.serverSideScheduling,
      supportsLinkField: d.supportsLinkField,
    );
  }

  int? _maxFileBytes(ConnectedAccount account) {
    final mb = _int(account.config['maxFileSizeMb']);
    final hard = _int(account.config['maxFileSize']);
    final policy = mb == null ? null : mb * 1024 * 1024;
    if (policy == null) return hard;
    if (hard == null) return policy;
    return policy < hard ? policy : hard;
  }

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = RulesValidator.validate(variant, descriptorFor(account), tier: account.tier);
    if (variant.media.length > misskeyMaxFilesPerNote) {
      issues.add(ValidationIssue.error('media.too_many',
          '${variant.media.length} files; Misskey allows $misskeyMaxFilesPerNote per note', field: 'media'));
    }
    final cw = variant.contentWarning?.trim() ?? '';
    if (cw.runes.length > misskeyMaxCwLength) {
      issues.add(ValidationIssue.error('cw.too_long',
          'Content warning is ${cw.runes.length}/$misskeyMaxCwLength characters', field: 'contentWarning'));
    }
    if (variant.media.any((m) => (m.altText ?? '').runes.length > misskeyMaxAltLength)) {
      issues.add(const ValidationIssue.warning('media.alt_too_long',
          'Alt text longer than $misskeyMaxAltLength characters will be shortened', field: 'media'));
    }
    final types = account.config['uploadableFileTypes'];
    if (types is List && types.isNotEmpty) {
      final patterns = types.whereType<String>().toList();
      for (final m in variant.media) {
        if (!misskeyMimeAllowed(m.mimeType, patterns)) {
          issues.add(ValidationIssue.error('media.type_not_allowed',
              '${m.fileName ?? m.id}: your server does not accept ${m.mimeType} uploads', field: 'media'));
        }
      }
    }
    if (account.tier == PlatformTier.openApi &&
        variant.visibility == Visibility.public &&
        account.config['canPublicNote'] == false) {
      issues.add(const ValidationIssue.warning('visibility.public_not_allowed',
          'Your server does not let this account post publicly; the note will be Home-only', field: 'visibility'));
    }
    if (account.tier == PlatformTier.handoff && variant.hasMedia) {
      issues.add(const ValidationIssue.warning('media.handoff',
          'The Misskey share page cannot take files; attach them yourself in the composer', field: 'media'));
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
      ctx.log.warn('Misskey publish failed: ${e.error.message}');
      return PublishResult.failure(e.error);
    }
  }

  Future<PublishResult> _publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier == PlatformTier.handoff) {
      throw const AdapterException(PublishError.unsupported('Hand-off accounts publish through the share page'));
    }
    final instanceRaw = account.configString('instance');
    if (instanceRaw.isEmpty) {
      throw const AdapterException(PublishError.configuration('This Misskey account has no instance; reconnect it'));
    }
    final instance = Uri.parse(instanceRaw);
    final token = OAuthTokens.fromSecrets(secrets)?.accessToken ?? secrets['token'];
    if (token == null || token.isEmpty) {
      throw const AdapterException(PublishError.auth('No Misskey access token stored; reconnect the account'));
    }
    final api = MisskeyApi(instance, ctx, token: token);

    final fileIds = <String>[];
    for (var i = 0; i < variant.media.length; i++) {
      fileIds.add(await _upload(api, variant.media[i], i, variant.media.length, variant.sensitive, ctx));
    }

    final parts = variant.isThread ? variant.threadParts : [variant.text];
    final ids = <String>[];
    String? replyId = _str(variant.extra['replyId']);
    for (var i = 0; i < parts.length; i++) {
      ctx.progress(parts.length > 1 ? 'Posting part ${i + 1} of ${parts.length}' : 'Posting note');
      final body = _noteBody(variant, account, parts[i], i == 0 ? fileIds : const [], replyId);
      try {
        final res = await guardMisskey(
            parts.length > 1 ? 'Misskey note ${i + 1}/${parts.length}' : 'Misskey note', ctx, () => api.callMap('notes/create', body));
        final created = res['createdNote'];
        final noteId = created is Map ? _str(created['id']) : null;
        if (noteId == null) {
          throw AdapterException(PublishError.platform('Misskey did not return the created note',
              raw: res.toString().length > 600 ? res.toString().substring(0, 600) : res.toString()));
        }
        ids.add(noteId);
        replyId = noteId;
      } on AdapterException catch (e) {
        throw AdapterException(e.error.asPartialThread(postedIds: ids, total: parts.length));
      }
    }
    ctx.log.info('Posted ${ids.length} note(s) to ${instance.host}');
    return PublishResult.ok(
      remoteId: ids.first,
      remoteUrl: '$instance/notes/${ids.first}',
      threadRemoteIds: ids.length > 1 ? ids : const [],
      publishedAt: ctx.now(),
    );
  }

  Future<String> _upload(MisskeyApi api, MediaAttachment m, int index, int total, bool sensitive, AdapterContext ctx) async {
    final kind = m.isVideo ? 'video' : 'image';
    ctx.progress('Uploading $kind ${index + 1} of $total');
    final bytes = await ctx.readMedia(m);
    final alt = _clip(m.altText?.trim(), misskeyMaxAltLength);
    final res = await guardMisskey('Misskey upload ${index + 1}/$total', ctx, () => api.uploadDriveFile(
          bytes: bytes,
          fileName: m.fileName ?? '${m.id}.${_ext(m.mimeType)}',
          contentType: m.mimeType,
          comment: alt,
          isSensitive: sensitive,
        ));
    final fileId = _str(res['id']);
    if (fileId == null) {
      throw const AdapterException(PublishError.platform('Misskey did not return a Drive file id'));
    }
    return fileId;
  }

  Map<String, Object?> _noteBody(
      PostVariant v, ConnectedAccount account, String text, List<String> fileIds, String? replyId) {
    final visibility = _visibility(v, account);
    final cw = v.contentWarning?.trim();
    final visibleUserIds = v.extra['visibleUserIds'];
    final reaction = _str(v.extra['reactionAcceptance']);
    final channelId = _str(v.extra['channelId']);
    return {
      // minLength is 1 on both: send null, never ''.
      'text': text.trim().isEmpty ? null : text,
      'visibility': visibility,
      if (cw != null && cw.isNotEmpty) 'cw': cw,
      if (fileIds.isNotEmpty) 'fileIds': fileIds,
      if (replyId != null) 'replyId': replyId,
      if (v.extra['localOnly'] == true) 'localOnly': true,
      if (visibility == 'specified' && visibleUserIds is List) 'visibleUserIds': visibleUserIds.whereType<String>().toList(),
      if (reaction != null) 'reactionAcceptance': reaction,
      if (channelId != null) 'channelId': channelId,
    };
  }

  String _visibility(PostVariant v, ConnectedAccount? account) {
    final explicit = _str(v.extra['visibility']);
    if (explicit != null && const {'public', 'home', 'followers', 'specified'}.contains(explicit)) return explicit;
    final mapped = switch (v.visibility) {
      Visibility.public => 'public',
      Visibility.unlisted => 'home',
      Visibility.followers => 'followers',
      Visibility.private => 'specified',
    };
    if (mapped == 'public' && account?.config['canPublicNote'] == false) return 'home';
    return mapped;
  }

  // ---------------------------------------------------------------- hand-off

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final instanceRaw = account?.configString('instance') ?? '';
    final ownServer = instanceRaw.isNotEmpty;
    final base = ownServer ? Uri.parse(instanceRaw) : Uri.parse('https://misskey-hub.net');
    final full = variant.isThread ? variant.threadParts.join('\n\n') : variant.text;
    final visibility = _visibility(variant, account);
    final intent = base.replace(path: '/share', queryParameters: {
      'text': variant.text,
      if (visibility != 'public') 'visibility': visibility,
      if (variant.extra['localOnly'] == true) 'localOnly': '1',
    });
    final cw = variant.contentWarning?.trim() ?? '';
    final where = ownServer ? base.host : 'the Misskey Hub page (pick your server there)';
    return HandoffPlan(
      platformId: id,
      webIntent: intent,
      clipboardText: full,
      shareText: full,
      shareFiles: variant.media,
      desktopUrl: intent.toString(),
      preferred: variant.hasMedia ? HandoffMethod.shareSheet : HandoffMethod.webIntent,
      instructions: [
        '1. NEFORUM opens the share page on $where with your text filled in (sign in there if asked).',
        if (variant.hasMedia) '2. Attach your media with the paperclip button in the composer.',
        if (cw.isNotEmpty) '${variant.hasMedia ? 3 : 2}. Turn on the content warning and paste: "$cw".',
        '${2 + (variant.hasMedia ? 1 : 0) + (cw.isNotEmpty ? 1 : 0)}. Check the text and press **Note**.',
      ].join('\n'),
      mediaNote: variant.hasMedia
          ? 'Misskey\'s share page cannot receive files. Your text is on the clipboard; attach the media in the composer, '
              'or share it to a Misskey app such as Milktea.'
          : null,
    );
  }
}

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

int? _int(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);

String? _clip(String? s, int max) {
  if (s == null || s.isEmpty) return null;
  final runes = s.runes.toList();
  return runes.length <= max ? s : String.fromCharCodes(runes.take(max));
}

String _ext(String mime) {
  final sub = mime.split('/').last;
  return switch (sub) {
    'jpeg' => 'jpg',
    'quicktime' => 'mov',
    'x-m4v' => 'm4v',
    _ => sub,
  };
}
