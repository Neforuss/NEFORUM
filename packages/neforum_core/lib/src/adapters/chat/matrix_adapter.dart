import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../auth/oauth2_pkce.dart';
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
import 'chat_common.dart';
import 'matrix_api.dart';

/// Synapse's default `max_upload_size` (50M); the real value comes from
/// `GET /_matrix/client/v1/media/config` when connecting.
const int matrixDefaultUploadBytes = 50 * 1024 * 1024;

/// Events must stay under 65536 bytes in total; keep room for the envelope.
const int matrixMaxContentBytes = 60000;

/// NEFORUM's own cap: each file is a separate event, and Synapse's default
/// message rate limit allows a burst of 10.
const int matrixMaxFiles = 10;

/// Posts to one Matrix room through the Client-Server API (unencrypted
/// rooms only).
///
/// Connect: homeserver (discovered via `.well-known`), then either an access
/// token (checked with `whoami`) or user id + password (`m.login.password`,
/// the password is never stored); the room alias is resolved, joined if
/// needed and checked for encryption. Publish: every file is uploaded to
/// `/_matrix/media/v3/upload`, then one `m.text` event (with
/// `formatted_body` for Markdown) and one `m.image`/`m.video` event per file.
class MatrixAdapter extends PlatformAdapter {
  /// [newTxnId] makes transaction ids (unique per request); injectable for
  /// tests.
  MatrixAdapter({String Function()? newTxnId}) : _newTxnId = newTxnId ?? (() => 'neforum-${const Uuid().v4()}');

  final String Function() _newTxnId;

  static const Set<String> _imageTypes = {'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/avif'};
  static const Set<String> _videoTypes = {'video/mp4', 'video/quicktime', 'video/webm'};

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'matrix',
    name: 'Matrix',
    iconKey: 'matrix',
    homepage: 'https://matrix.org',
    tiers: {PlatformTier.openApi},
    defaultTier: PlatformTier.openApi,
    text: TextRules(
      maxLength: null,
      counting: CountingRule.utf8Bytes,
      supportsThreads: false,
      supportsMarkdown: true,
      supportsHashtags: true,
      linkInText: true,
      notes: 'No character limit; a message must stay under about 60 KB. Basic Markdown is sent as formatted text '
          'with a plain-text fallback.',
    ),
    media: MediaRules(
      maxImages: matrixMaxFiles,
      maxVideos: matrixMaxFiles,
      allowsMixedImageVideo: true,
      imageMaxBytes: matrixDefaultUploadBytes,
      videoMaxBytes: matrixDefaultUploadBytes,
      imageMimeTypes: _imageTypes,
      videoMimeTypes: _videoTypes,
      supportsAltText: false,
      notes: 'Each file becomes its own message after the text. The size limit is set by your homeserver '
          '(Synapse default 50 MB; NEFORUM reads the real value when you connect). Encrypted rooms are not supported.',
    ),
    defaultQuotas: [
      QuotaRule(
        id: 'matrix.messages_per_minute',
        limit: 12,
        window: Duration(minutes: 1),
        note: 'Synapse default message rate (0.2 per second, bursts of 10); your homeserver may differ',
        appliesToTier: PlatformTier.openApi,
      ),
    ],
    personalAccountOk: true,
    accountRequirements: 'Any account on any Matrix homeserver (matrix.org or your own) that may post in the room. '
        'The room must not be end-to-end encrypted.',
    apiCostSummary: 'Free and open. Your homeserver decides how fast you may post and how large files may be.',
    setupGuide: 'docs/platforms/matrix.md',
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
          intro: '**Matrix needs no developer account.** You sign in with a normal Matrix account; a separate '
              'account just for posting (a "bot" user) is a good idea.\n\n'
              '1. Enter your homeserver (e.g. `matrix.org`) and your user id (`@you:matrix.org`).\n'
              '2. Either paste an **access token** or enter the **password**. With a password NEFORUM signs in '
              'once as a new device called *NEFORUM* and does not store the password.\n'
              '   To get a token in Element: **Settings > Help & About > Advanced > Access Token** '
              '(do not sign that session out afterwards, or the token dies with it).\n'
              '3. Enter the room as `#alias:server` or `!roomid:server` (Room settings > Advanced). '
              'The account must be allowed to post there; NEFORUM joins public rooms automatically.\n\n'
              'End-to-end encrypted rooms cannot be used (NEFORUM does not do Matrix encryption).',
          redirectNote: 'Nothing to register: password and token sign-in need no redirect URI.',
          fields: [
            ConnectField(
              key: 'homeserver',
              label: 'Homeserver',
              kind: FieldKind.url,
              required: false,
              placeholder: 'matrix.org',
              help: 'Your server name or URL. Leave empty to use the server part of your user id.',
            ),
            ConnectField(
              key: 'user_id',
              label: 'User id',
              required: false,
              placeholder: '@you:matrix.org',
              help: 'Needed with a password; optional with an access token.',
            ),
            ConnectField(
              key: 'access_token',
              label: 'Access token',
              kind: FieldKind.password,
              required: false,
              secret: true,
              help: 'Preferred. Element: Settings > Help & About > Advanced > Access Token.',
            ),
            ConnectField(
              key: 'password',
              label: 'Password (instead of a token)',
              kind: FieldKind.password,
              required: false,
              secret: true,
              help: 'Used once to sign in; never stored. Servers that only offer browser (OAuth) sign-in, such as '
                  'some matrix.org setups, need a token instead.',
            ),
            ConnectField(
              key: 'room',
              label: 'Room',
              placeholder: '#myroom:matrix.org',
              help: 'Room alias (`#name:server`) or room id (`!abc123:server`).',
            ),
            ConnectField(
              key: 'formatting',
              label: 'Formatting',
              kind: FieldKind.select,
              required: false,
              options: ['markdown', 'plain'],
              defaultValue: 'markdown',
              help: '`markdown` sends **bold**, *italic*, `code` and [links](https://…) as formatted text.',
            ),
          ],
        ),
      ];

  // ---------------------------------------------------------------- connect

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    final userInput = (input['user_id'] ?? '').trim();
    if (userInput.isNotEmpty && !_mxid.hasMatch(userInput)) {
      throw const ConnectException('A Matrix user id looks like @name:server.org', field: 'user_id');
    }
    var server = (input['homeserver'] ?? '').trim();
    if (server.isEmpty && userInput.isNotEmpty) server = userInput.substring(userInput.indexOf(':') + 1);
    if (server.isEmpty) throw const ConnectException('Enter your homeserver, e.g. matrix.org', field: 'homeserver');
    final room = (input['room'] ?? '').trim();
    if (!_roomRef.hasMatch(room)) {
      throw const ConnectException('Enter the room as #alias:server or !roomid:server', field: 'room');
    }
    final token = (input['access_token'] ?? '').trim();
    final password = input['password'] ?? '';
    if (token.isEmpty && password.isEmpty) {
      throw const ConnectException('Paste an access token or enter your password.', field: 'access_token');
    }
    if (token.isEmpty && userInput.isEmpty) {
      throw const ConnectException('Signing in with a password needs your user id (@you:server).', field: 'user_id');
    }

    final base = await discoverMatrixBase(server, ctx);
    return _guard(() async {
      final _Login login =
          token.isNotEmpty ? await _whoami(base, token, userInput, ctx) : await _login(base, userInput, password, ctx);
      final api = MatrixApi(base, ctx, token: login.tokens.accessToken);
      try {
        return await _finishConnect(api, base, login, room, input['formatting'], ctx);
      } on Object {
        if (login.method == 'password') await _logout(api, ctx);
        rethrow;
      }
    });
  }

  Future<ConnectResult> _finishConnect(
      MatrixApi api, Uri base, _Login login, String room, String? formatting, AdapterContext ctx) async {
    var roomId = room;
    if (room.startsWith('#')) {
      ctx.progress('Looking up $room');
      final res = await api.get(matrixClient('v3', ['directory', 'room', room]));
      roomId = chatStr(res['room_id']) ?? (throw ConnectException('The server did not resolve $room.', field: 'room'));
    }
    final joined = await api.get(matrixClient('v3', ['joined_rooms']));
    final rooms = (joined['joined_rooms'] as List? ?? const []).whereType<String>().toSet();
    if (!rooms.contains(roomId)) {
      ctx.progress('Joining the room');
      try {
        await api.post(matrixClient('v3', ['join', room]), const {});
      } on MatrixApiError catch (e) {
        throw ConnectException('Could not join the room (${e.message}). Join it (or ask for an invite) in your '
            'Matrix app first.', field: 'room');
      }
    }
    final enc = await api.getOptional(matrixClient('v3', ['rooms', roomId, 'state', 'm.room.encryption']));
    if (enc != null && enc.isNotEmpty) {
      throw const ConnectException('This room is end-to-end encrypted. NEFORUM can only post to unencrypted rooms.',
          field: 'room');
    }
    String? roomName;
    try {
      roomName = chatStr((await api.getOptional(matrixClient('v3', ['rooms', roomId, 'state', 'm.room.name'])))?['name']);
    } on MatrixApiError {
      roomName = null;
    }
    final maxUpload = await _mediaConfig(api);
    final alias = room.startsWith('#') ? room : null;
    final title = roomName ?? alias ?? roomId;
    return ConnectResult(
      account: ConnectedAccount(
        id: 'matrix:${login.userId}:$roomId',
        platformId: id,
        tier: PlatformTier.openApi,
        displayName: '$title (${login.userId})',
        handle: login.userId,
        profileUrl: 'https://matrix.to/#/${Uri.encodeComponent(alias ?? roomId)}',
        createdAt: ctx.now(),
        config: {
          'homeserver': base.toString(),
          'userId': login.userId,
          if (login.deviceId != null) 'deviceId': login.deviceId,
          'roomId': roomId,
          if (alias != null) 'roomAlias': alias,
          if (roomName != null) 'roomName': roomName,
          'authMethod': login.method,
          if (maxUpload != null) 'maxUploadBytes': maxUpload,
          'formatting': (formatting ?? '').trim() == 'plain' ? 'plain' : 'markdown',
        },
      ),
      secrets: login.tokens.toSecrets(),
    );
  }

  Future<_Login> _whoami(Uri base, String token, String expectedUser, AdapterContext ctx) async {
    ctx.progress('Checking the access token');
    try {
      final me = await MatrixApi(base, ctx, token: token).get(matrixClient('v3', ['account', 'whoami']));
      final userId = chatStr(me['user_id']);
      if (userId == null) throw const ConnectException('The homeserver did not say who this token belongs to.');
      if (expectedUser.isNotEmpty && expectedUser != userId) {
        throw ConnectException('This token belongs to $userId, not $expectedUser.', field: 'access_token');
      }
      return _Login(userId, chatStr(me['device_id']), OAuthTokens(accessToken: token), 'token');
    } on MatrixApiError catch (e) {
      if (e.statusCode == 401 || e.errcode == 'M_UNKNOWN_TOKEN') {
        throw const ConnectException('The homeserver rejected this access token. Copy it again.', field: 'access_token');
      }
      rethrow;
    }
  }

  Future<_Login> _login(Uri base, String user, String password, AdapterContext ctx) async {
    ctx.progress('Signing in');
    final api = MatrixApi(base, ctx);
    final flows = await api.get(matrixClient('v3', ['login']));
    final types = (flows['flows'] as List? ?? const []).whereType<Map<Object?, Object?>>().map((f) => f['type']).toSet();
    if (!types.contains('m.login.password')) {
      throw const ConnectException('This homeserver does not allow password sign-in from apps (it uses browser '
          'sign-in). Paste an access token from Element instead.', field: 'password');
    }
    try {
      final res = await api.post(matrixClient('v3', ['login']), {
        'type': 'm.login.password',
        'identifier': {'type': 'm.id.user', 'user': user},
        'password': password,
        'initial_device_display_name': 'NEFORUM',
      }, auth: false);
      final at = chatStr(res['access_token']);
      final userId = chatStr(res['user_id']) ?? user;
      if (at == null) throw const ConnectException('The homeserver did not return an access token.');
      final ms = chatInt(res['expires_in_ms']);
      final tokens = OAuthTokens(
        accessToken: at,
        refreshToken: chatStr(res['refresh_token']),
        expiresAt: ms == null ? null : ctx.now().add(Duration(milliseconds: ms)),
      );
      return _Login(userId, chatStr(res['device_id']), tokens, 'password');
    } on MatrixApiError catch (e) {
      if (e.errcode == 'M_FORBIDDEN' || e.statusCode == 403) {
        throw const ConnectException('Wrong user id or password.', field: 'password');
      }
      if (e.errcode == 'M_USER_DEACTIVATED') throw const ConnectException('This Matrix account is deactivated.');
      rethrow;
    }
  }

  Future<int?> _mediaConfig(MatrixApi api) async {
    for (final path in [
      ['client', 'v1', 'media', 'config'],
      ['media', 'v3', 'config'],
    ]) {
      try {
        final cfg = await api.getOptional(path);
        final size = cfg == null ? null : chatInt(cfg['m.upload.size']);
        if (size != null) return size;
      } on MatrixApiError {
        continue;
      }
    }
    return null;
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on ConnectException {
      rethrow;
    } on MatrixApiError catch (e) {
      if (e.errcode == 'M_LIMIT_EXCEEDED' || e.statusCode == 429) {
        throw ConnectException('The homeserver asks to slow down. Try again in ${e.retryAfter?.inSeconds ?? 30} seconds.');
      }
      if (e.errcode == 'M_NOT_FOUND') throw ConnectException('Not found on the homeserver: ${e.message}', field: 'room');
      throw ConnectException('The homeserver refused: ${e.message}');
    } on Exception catch (e) {
      throw ConnectException('Could not reach the homeserver: $e');
    }
  }

  // --------------------------------------------------------------- validate

  /// The descriptor with this account's homeserver upload limit applied.
  PlatformDescriptor descriptorFor(ConnectedAccount account) {
    final max = chatInt(account.config['maxUploadBytes']);
    if (max == null || max <= 0) return _descriptor;
    final d = _descriptor;
    final m = d.media;
    return PlatformDescriptor(
      id: d.id,
      name: d.name,
      iconKey: d.iconKey,
      homepage: d.homepage,
      tiers: d.tiers,
      defaultTier: d.defaultTier,
      text: d.text,
      media: MediaRules(
        maxImages: m.maxImages,
        maxVideos: m.maxVideos,
        allowsMixedImageVideo: m.allowsMixedImageVideo,
        imageMaxBytes: max,
        videoMaxBytes: max,
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

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = RulesValidator.validate(variant, descriptorFor(account), tier: account.tier);
    final text = _fullText(variant);
    final html = account.configString('formatting', 'markdown') == 'plain' ? null : chatMarkdownToHtml(text, brLineBreaks: true);
    final bytes = utf8.encode(text).length + (html == null ? 0 : utf8.encode(html).length);
    if (bytes > matrixMaxContentBytes) {
      issues.add(ValidationIssue.error('text.event_too_large',
          'The message is ${(bytes / 1000).toStringAsFixed(0)} KB; Matrix messages must stay under about 60 KB',
          field: 'text'));
    }
    if (variant.media.length > matrixMaxFiles) {
      issues.add(ValidationIssue.error('media.too_many',
          '${variant.media.length} files; NEFORUM sends at most $matrixMaxFiles to Matrix at once', field: 'media'));
    }
    if (variant.hasMedia) {
      issues.add(ValidationIssue.info('media.separate_events',
          'Each file is posted as its own message after the text (${variant.media.length + (text.trim().isEmpty ? 0 : 1)} messages)',
          field: 'media'));
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
      ctx.log.warn('Matrix publish failed: ${e.error.message}');
      return PublishResult.failure(e.error);
    } on MatrixApiError catch (e) {
      ctx.log.warn('Matrix publish failed: $e');
      return PublishResult.failure(e.toPublishError('Matrix'));
    } on Exception catch (e) {
      ctx.log.warn('Matrix publish: network error ($e)');
      return PublishResult.failure(PublishError.network('Could not reach the homeserver', raw: '$e'));
    }
  }

  Future<PublishResult> _publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final hs = account.configString('homeserver');
    final roomId = account.configString('roomId');
    if (hs.isEmpty || roomId.isEmpty) {
      throw const AdapterException(PublishError.configuration('This Matrix account has no homeserver/room; reconnect'));
    }
    final token = OAuthTokens.fromSecrets(secrets)?.accessToken;
    if (token == null) throw const AdapterException(PublishError.auth('No Matrix access token stored; reconnect'));
    if (variant.media.length > matrixMaxFiles) {
      throw const AdapterException(PublishError.validation('Matrix: at most 10 files per post'));
    }
    final api = MatrixApi(Uri.parse(hs), ctx, token: token);

    // Upload everything first so a failed upload does not leave half a post.
    final uploaded = <(MediaAttachment, String)>[];
    for (var i = 0; i < variant.media.length; i++) {
      final m = variant.media[i];
      ctx.progress('Uploading ${m.isVideo ? 'video' : 'image'} ${i + 1} of ${variant.media.length}');
      final bytes = await ctx.readMedia(m);
      uploaded.add((m, await api.upload(bytes, contentType: m.mimeType, fileName: chatFileName(m))));
    }

    final ids = <String>[];
    final text = _fullText(variant);
    if (text.trim().isNotEmpty) {
      ctx.progress('Sending message');
      ids.add(await _send(api, roomId, _textContent(text, account.configString('formatting', 'markdown') != 'plain')));
    }
    for (var i = 0; i < uploaded.length; i++) {
      final (m, mxc) = uploaded[i];
      ctx.progress('Sending ${m.isVideo ? 'video' : 'image'} ${i + 1} of ${uploaded.length}');
      ids.add(await _send(api, roomId, matrixMediaContent(m, mxc)));
    }
    if (ids.isEmpty) throw const AdapterException(PublishError.validation('Nothing to post'));
    return PublishResult.ok(
      remoteId: ids.first,
      remoteUrl: matrixToUrl(roomId, ids.first),
      threadRemoteIds: ids.length > 1 ? ids : const [],
      publishedAt: ctx.now(),
    );
  }

  Future<String> _send(MatrixApi api, String roomId, Map<String, Object?> content) async {
    final res = await api.put(matrixClient('v3', ['rooms', roomId, 'send', 'm.room.message', _newTxnId()]), content);
    final eventId = chatStr(res['event_id']);
    if (eventId == null) throw const AdapterException(PublishError.platform('The homeserver returned no event id'));
    return eventId;
  }

  Map<String, Object?> _textContent(String text, bool markdown) {
    final html = markdown ? chatMarkdownToHtml(text, brLineBreaks: true) : null;
    return {
      'msgtype': 'm.text',
      'body': text,
      if (html != null) 'format': 'org.matrix.custom.html',
      if (html != null) 'formatted_body': html,
      // Intentional mentions: an empty object means "ping nobody".
      'm.mentions': <String, Object?>{},
    };
  }

  String _fullText(PostVariant v) => v.isThread ? v.threadParts.join('\n\n') : v.text;

  // ---------------------------------------------------------- refresh/logout

  @override
  Future<Map<String, String>?> refreshSecrets(
      ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final tokens = OAuthTokens.fromSecrets(secrets);
    final refresh = tokens?.refreshToken;
    if (tokens == null || refresh == null || !tokens.isExpired(now: ctx.now())) return null;
    final api = MatrixApi(Uri.parse(account.configString('homeserver')), ctx);
    try {
      final res = await api.post(matrixClient('v3', ['refresh']), {'refresh_token': refresh}, auth: false);
      final at = chatStr(res['access_token']);
      if (at == null) throw const AdapterException(PublishError.auth('Matrix refresh returned no token; reconnect'));
      final ms = chatInt(res['expires_in_ms']);
      // Remove the old expiry first: a response without expires_in_ms means
      // the new token does not expire.
      final base = {...secrets}..remove(OAuthTokens.keyExpiresAt);
      return OAuthTokens(
        accessToken: at,
        refreshToken: chatStr(res['refresh_token']) ?? refresh,
        expiresAt: ms == null ? null : ctx.now().add(Duration(milliseconds: ms)),
      ).toSecrets(base);
    } on MatrixApiError catch (e) {
      if (e.statusCode == 401 || e.errcode == 'M_UNKNOWN_TOKEN' || e.errcode == 'M_FORBIDDEN') {
        throw const AdapterException(PublishError.auth('The Matrix session has ended; reconnect the account'));
      }
      throw AdapterException(e.toPublishError('Matrix refresh'));
    } on AdapterException {
      rethrow;
    } on Exception catch (e) {
      throw AdapterException(PublishError.network('Could not reach the homeserver', raw: '$e'));
    }
  }

  /// Signs out the device NEFORUM created with the password. A pasted token
  /// belongs to another app's session and is left alone.
  @override
  Future<void> disconnect(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.configString('authMethod') != 'password') return;
    final token = OAuthTokens.fromSecrets(secrets)?.accessToken;
    if (token == null) return;
    await _logout(MatrixApi(Uri.parse(account.configString('homeserver')), ctx, token: token), ctx);
  }

  Future<void> _logout(MatrixApi api, AdapterContext ctx) async {
    try {
      await api.post(matrixClient('v3', ['logout']), const {});
    } on Exception catch (e) {
      ctx.log.warn('Matrix logout failed: $e');
    }
  }
}

class _Login {
  const _Login(this.userId, this.deviceId, this.tokens, this.method);
  final String userId;
  final String? deviceId;
  final OAuthTokens tokens;
  final String method;
}

final RegExp _mxid = RegExp(r'^@[^:\s]+:[A-Za-z0-9.\-\[\]]+(?::\d+)?$');
final RegExp _roomRef = RegExp(r'^[#!][^:\s]+:[A-Za-z0-9.\-\[\]]+(?::\d+)?$');

/// The `m.image` / `m.video` event content for an uploaded file.
Map<String, Object?> matrixMediaContent(MediaAttachment m, String mxc) {
  final name = chatFileName(m);
  return {
    'msgtype': m.isVideo ? 'm.video' : 'm.image',
    'body': name,
    'filename': name,
    'url': mxc,
    'info': {
      'mimetype': m.mimeType,
      'size': m.sizeBytes,
      if (m.width != null) 'w': m.width,
      if (m.height != null) 'h': m.height,
      if (m.isVideo && m.durationMs != null) 'duration': m.durationMs,
    },
    'm.mentions': <String, Object?>{},
  };
}

/// `https://matrix.to/#/<room>/<event>?via=<server>`.
String matrixToUrl(String roomId, String eventId) {
  final server = roomId.contains(':') ? roomId.substring(roomId.indexOf(':') + 1) : null;
  return 'https://matrix.to/#/${Uri.encodeComponent(roomId)}/${Uri.encodeComponent(eventId)}'
      '${server == null ? '' : '?via=${Uri.encodeComponent(server)}'}';
}

/// Finds the client base URL for [input] (a server name or URL): reads
/// `/.well-known/matrix/client`, falls back to the input itself, and checks
/// `/_matrix/client/versions`.
Future<Uri> discoverMatrixBase(String input, AdapterContext ctx) async {
  var s = input.trim();
  if (!s.contains('://')) s = 'https://$s';
  final parsed = Uri.tryParse(s);
  if (parsed == null || parsed.host.isEmpty) {
    throw const ConnectException('That is not a homeserver address.', field: 'homeserver');
  }
  final local = parsed.host == 'localhost' || parsed.host == '127.0.0.1';
  if (parsed.scheme != 'https' && !(parsed.scheme == 'http' && local)) {
    throw const ConnectException('The homeserver must use https://', field: 'homeserver');
  }
  final origin = Uri(scheme: parsed.scheme, host: parsed.host, port: parsed.hasPort ? parsed.port : null);
  var base = Uri(
      scheme: parsed.scheme,
      host: parsed.host,
      port: parsed.hasPort ? parsed.port : null,
      path: parsed.path.replaceFirst(RegExp(r'/+$'), ''));
  ctx.progress('Finding the homeserver for ${parsed.host}');
  try {
    final wk = await ctx.http.get(origin.replace(path: '/.well-known/matrix/client'), throwOnError: false);
    final hs = wk.ok ? wk.jsonMap['m.homeserver'] : null;
    final url = hs is Map ? chatStr(hs['base_url']) : null;
    if (url != null) {
      final u = Uri.tryParse(url.replaceFirst(RegExp(r'/+$'), ''));
      if (u != null && u.host.isNotEmpty && (u.scheme == 'https' || u.scheme == 'http')) base = u;
    }
  } on Exception {
    // No .well-known: use the address as given.
  }
  try {
    final res = await ctx.http.get(MatrixApi(base, ctx).uri(['client', 'versions']), throwOnError: false);
    if (!res.ok || res.jsonMap['versions'] is! List) {
      throw ConnectException('${base.host} does not answer like a Matrix homeserver.', field: 'homeserver');
    }
  } on ConnectException {
    rethrow;
  } on Exception catch (e) {
    throw ConnectException('Could not reach ${base.host}: $e', field: 'homeserver');
  }
  return base;
}
