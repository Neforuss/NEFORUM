import 'dart:typed_data';

import '../../audio/audio_publishing.dart';
import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../model/account.dart';
import '../../model/audio.dart';
import '../../model/media.dart';
import '../../model/photo_fit.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../../text/rules_validator.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'chat_common.dart';
import 'telegram_api.dart';

/// `sendMessage` text: 1-4096 characters after entities parsing.
const int telegramMaxText = 4096;

/// Captions on photos, videos and albums: 0-1024 characters.
const int telegramMaxCaption = 1024;

/// `sendMediaGroup` takes 2-10 items.
const int telegramMaxAlbum = 10;

/// Multipart upload limits from "Sending files": 10 MB photos, 50 MB other.
const int telegramPhotoMaxBytes = 10 * 1024 * 1024;
const int telegramFileMaxBytes = 50 * 1024 * 1024;

/// Whether Telegram plays [m] in the chat: `sendAudio` takes MP3 and M4A.
/// A lossless file (Apple Lossless in M4A too) goes with `sendDocument`,
/// which keeps it as the file it is.
bool telegramPlaysAudio(MediaAttachment m) =>
    !m.isLosslessAudio && (m.mimeType == AudioMimeTypes.mp3 || m.mimeType == AudioMimeTypes.m4a);

/// The track title `sendAudio` shows: the title from the track's details,
/// else the file name without its extension.
String telegramTrackTitle(MediaAttachment m) {
  final tagged = m.audioTags?.title?.trim() ?? '';
  if (tagged.isNotEmpty) return tagged;
  final name = chatFileName(m);
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// Posts to a Telegram channel or group as a bot (Bot API).
///
/// Connect: a bot token from @BotFather plus the chat (`@channelusername`
/// or a numeric `-100…` id); verified with `getMe`, `getChat` and
/// `getChatMember`. Publish: `sendMessage`, `sendPhoto` / `sendVideo` /
/// `sendAnimation` / `sendAudio` / `sendDocument` or `sendMediaGroup` (multipart upload). Text longer than
/// a caption goes out as a separate message after the media; thread parts
/// are sent as replies to the previous message.
class TelegramAdapter extends PlatformAdapter {
  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'telegram',
    name: 'Telegram',
    iconKey: 'telegram',
    homepage: 'https://telegram.org',
    tiers: {PlatformTier.openApi, PlatformTier.handoff},
    defaultTier: PlatformTier.openApi,
    text: TextRules(
      maxLength: telegramMaxText,
      // Telegram counts "characters after entities parsing" and measures
      // entities in UTF-16 code units; UTF-16 is the safe reading.
      counting: CountingRule.utf16,
      supportsThreads: true,
      supportsMarkdown: true,
      supportsHashtags: true,
      linkInText: true,
      notes: 'Messages up to 4096 characters, captions on media up to 1024. When a post with media is longer '
          'than 1024 characters NEFORUM sends the media first and the text as a separate message. '
          'Basic Markdown (**bold**, *italic*, `code`, [links](https://…)) is converted to Telegram formatting.',
    ),
    media: MediaRules(
      maxImages: telegramMaxAlbum,
      maxVideos: telegramMaxAlbum,
      allowsMixedImageVideo: true,
      imageMaxBytes: telegramPhotoMaxBytes,
      videoMaxBytes: telegramFileMaxBytes,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/webp', 'image/gif'},
      videoMimeTypes: {'video/mp4'},
      notes: 'Up to 10 photos/videos per post (sent as an album). Photos max 10 MB with width + height at most '
          '10000 px and a side ratio of at most 20; videos (MP4) and GIFs max 50 MB. No alt text. One sound file '
          'per post (50 MB): MP3 and M4A play in the chat; lossless and other files go as a document, unchanged.',
      maxAudios: 1,
      audioMaxBytes: telegramFileMaxBytes,
      audioMimeTypes: AudioMimeTypes.all,
      keepsAudioBytes: true,
    ),
    defaultQuotas: [
      QuotaRule(
        id: 'telegram.messages_per_minute_per_chat',
        limit: 20,
        window: Duration(minutes: 1),
        note: 'Bot FAQ: about 20 messages per minute to the same group (and ~1 per second per chat)',
        appliesToTier: PlatformTier.openApi,
      ),
    ],
    personalAccountOk: true,
    accountRequirements: 'Any Telegram account can create a bot with @BotFather in a minute. The bot then has to be '
        'an administrator (with "Post Messages") of your channel, or a member of your group.',
    apiCostSummary: 'Free, with no app review. Telegram only slows down bots that send many messages per minute.',
    setupGuide: 'docs/platforms/telegram.md',
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
          intro: '**Telegram posts through a bot that you own. No developer account or review is needed.**\n\n'
              '1. In Telegram, open a chat with **@BotFather** and send `/newbot`. Pick a name and a username '
              'ending in `bot`. BotFather replies with a **token** like `110201543:AAH…`; copy it.\n'
              '2. Open your channel > **Administrators** > **Add Admin**, search for your bot and add it with the '
              '**Post Messages** right. For a group, just add the bot as a member.\n'
              '3. Paste the token below and enter the channel as `@channelusername`. For a private channel or '
              'group enter its numeric id (channels and supergroups start with `-100`; a small basic group has a '
              'shorter negative id).\n\n'
              'Keep the token secret: anyone who has it controls your bot.',
          redirectNote: 'Nothing to register: Telegram bots do not use redirect URIs.',
          fields: [
            ConnectField(
              key: 'bot_token',
              label: 'Bot token',
              kind: FieldKind.password,
              secret: true,
              placeholder: '110201543:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw',
              help: 'From @BotFather (`/newbot`, or `/token` for an existing bot).',
            ),
            ConnectField(
              key: 'chat',
              label: 'Channel or group',
              placeholder: '@mychannel',
              help: 'A public channel: `@username` or `https://t.me/username`. Private channel or group: the '
                  'numeric id, e.g. `-1001234567890` (forward a post to @userinfobot or a similar bot to see it).',
            ),
            ConnectField(
              key: 'formatting',
              label: 'Formatting',
              kind: FieldKind.select,
              required: false,
              options: ['markdown', 'plain'],
              defaultValue: 'markdown',
              help: '`markdown` turns **bold**, *italic*, `code` and [links](https://…) into Telegram formatting. '
                  '`plain` sends the text exactly as written.',
            ),
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.handoff,
          loopbackRedirectOk: false,
          customSchemeRedirectOk: false,
          intro: 'NEFORUM opens Telegram\'s share page (or the share sheet when you attach media); you pick the chat '
              'and press **Send**. Nothing to set up.',
        ),
      ];

  // ---------------------------------------------------------------- connect

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier == PlatformTier.handoff) {
      return ConnectResult(
        account: ConnectedAccount(
          id: 'telegram-handoff',
          platformId: id,
          tier: PlatformTier.handoff,
          displayName: 'Telegram (share)',
          createdAt: ctx.now(),
        ),
      );
    }
    final token = (input['bot_token'] ?? '').trim();
    if (!RegExp(r'^\d{5,}:[A-Za-z0-9_-]{30,}$').hasMatch(token)) {
      throw const ConnectException('That does not look like a bot token. BotFather tokens look like '
          '123456789:AAH… (digits, a colon, then about 35 letters).', field: 'bot_token');
    }
    final chat = normalizeTelegramChat(input['chat'] ?? '');
    final formatting = (input['formatting'] ?? '').trim() == 'plain' ? 'plain' : 'markdown';
    final api = TelegramApi(token, ctx);

    ctx.progress('Checking the bot token');
    final me = _map(await _connectCall(() => api.get('getMe'), tokenStep: true));
    final botId = chatId(me['id']);
    final botUsername = chatStr(me['username']);
    if (botId == null || me['is_bot'] != true) {
      throw const ConnectException('Telegram did not return a bot for this token.', field: 'bot_token');
    }

    ctx.progress('Looking up $chat');
    final info = _map(await _connectCall(() => api.get('getChat', {'chat_id': chat})));
    final chatNumeric = chatId(info['id']);
    if (chatNumeric == null) throw ConnectException('Telegram did not return the chat $chat.', field: 'chat');
    final type = chatStr(info['type']) ?? 'channel';
    if (type == 'private') {
      throw const ConnectException('That is a private chat with a person. Enter a channel or a group.', field: 'chat');
    }

    final member = _map(await _connectCall(() => api.get('getChatMember', {'chat_id': chatNumeric, 'user_id': botId})));
    _checkRights(type, member, botUsername);

    final title = chatStr(info['title']) ?? chat;
    final username = chatStr(info['username']);
    return ConnectResult(
      account: ConnectedAccount(
        id: 'telegram:$botId:$chatNumeric',
        platformId: id,
        tier: PlatformTier.openApi,
        displayName: botUsername == null ? title : '$title (via @$botUsername)',
        handle: username != null ? '@$username' : title,
        profileUrl: username != null ? 'https://t.me/$username' : null,
        createdAt: ctx.now(),
        config: {
          'chatId': chatNumeric,
          'chatType': type,
          'chatTitle': title,
          if (username != null) 'chatUsername': username,
          'botId': botId,
          if (botUsername != null) 'botUsername': botUsername,
          'formatting': formatting,
        },
      ),
      secrets: {'bot_token': token},
    );
  }

  Future<Object?> _connectCall(Future<Object?> Function() call, {bool tokenStep = false}) async {
    try {
      return await call();
    } on TelegramApiError catch (e) {
      if (e.code == 401 || (e.code == 404 && tokenStep)) {
        throw const ConnectException('Telegram rejected the bot token. Copy it again from @BotFather.',
            field: 'bot_token');
      }
      final d = e.description.toLowerCase();
      if (d.contains('chat not found') || d.contains('member list is inaccessible') || e.code == 403) {
        throw const ConnectException('The bot cannot see this chat. Add the bot to the channel or group first '
            '(as administrator for a channel), then check the @username or -100… id.', field: 'chat');
      }
      if (e.code == 429) {
        throw ConnectException('Telegram asks to wait ${e.retryAfter?.inSeconds ?? 30} seconds. Try again then.');
      }
      throw ConnectException('Telegram refused: ${e.description}');
    } on ConnectException {
      rethrow;
    } on Exception {
      // Do not show the exception: its text may contain the token-bearing URL.
      throw const ConnectException('Could not reach api.telegram.org. Check your internet connection.');
    }
  }

  void _checkRights(String type, Map<String, dynamic> member, String? botUsername) {
    final status = chatStr(member['status']) ?? '';
    final who = botUsername == null ? 'The bot' : '@$botUsername';
    if (type == 'channel') {
      if (status == 'creator') return;
      if (status != 'administrator') {
        throw ConnectException('$who is not an administrator of this channel. Open the channel > Administrators > '
            'Add Admin, add the bot and allow "Post Messages".', field: 'chat');
      }
      if (member['can_post_messages'] == false) {
        throw ConnectException('$who is an administrator but lacks the "Post Messages" right. Edit its admin '
            'rights in the channel settings.', field: 'chat');
      }
      return;
    }
    if (status == 'left' || status == 'kicked') {
      throw ConnectException('$who is not a member of this group. Add it to the group first.', field: 'chat');
    }
    if (status == 'restricted' && member['can_send_messages'] == false) {
      throw ConnectException('$who may not send messages in this group. Lift the restriction first.', field: 'chat');
    }
  }

  // --------------------------------------------------------------- validate

  /// Bot photos: width + height up to 10000 and a ratio up to 20. The share
  /// sheet (hand-off) takes files as they are.
  @override
  PhotoFit? photoFit(ConnectedAccount account, PostVariant variant) => account.tier == PlatformTier.handoff
      ? null
      : super.photoFit(account, variant)?.copyWith(minAspect: 1 / 20, maxAspect: 20, maxSideSum: 10000);

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = RulesValidator.validate(variant, descriptor, tier: account.tier);
    if (account.tier == PlatformTier.handoff) {
      if (variant.hasMedia) {
        issues.add(const ValidationIssue.info('media.handoff',
            'Media goes through the share sheet; the text is also copied to the clipboard', field: 'media'));
      }
      return issues;
    }
    // A GIF on its own goes out with sendAnimation, which takes 50 MB like
    // other files; the generic 10 MB photo limit only applies to album GIFs
    // (sent as photos).
    if (variant.media.length == 1 && variant.media.single.kind == MediaKind.gif) {
      issues.removeWhere((i) => i.code == 'media.image_too_large');
    }
    if (variant.media.length > telegramMaxAlbum) {
      issues.add(ValidationIssue.error('media.too_many',
          '${variant.media.length} files; Telegram allows $telegramMaxAlbum per album', field: 'media'));
    }
    for (final m in variant.media) {
      final w = m.width;
      final h = m.height;
      if (m.kind == MediaKind.image && w != null && h != null && w > 0 && h > 0) {
        final ratio = w > h ? w / h : h / w;
        if (w + h > 10000 || ratio > 20) {
          issues.add(ValidationIssue.error('media.dimensions',
              '${m.fileName ?? m.id} is ${w}x$h; Telegram photos need width + height <= 10000 and a ratio <= 20',
              field: 'media'));
        }
      }
      if (m.kind == MediaKind.gif && variant.media.length > 1) {
        issues.add(ValidationIssue.warning('media.gif_in_album',
            '${m.fileName ?? m.id}: GIFs in an album are shown as still photos; post it alone to keep the animation',
            field: 'media'));
      }
      if (m.kind == MediaKind.gif && m.sizeBytes > telegramFileMaxBytes) {
        issues.add(ValidationIssue.error('media.gif_too_large', '${m.fileName ?? m.id} is larger than 50 MB',
            field: 'media'));
      }
    }
    if (variant.hasMedia && variant.text.length > telegramMaxCaption) {
      issues.add(const ValidationIssue.info('text.caption_split',
          'Longer than a 1024-character caption: the media is sent first and the text follows as its own message',
          field: 'text'));
    }
    return issues;
  }

  // ---------------------------------------------------------------- publish

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final sent = ChatMessages();
    PublishResult failed(PublishError error) {
      final e = sent.fail(error);
      ctx.log.warn('Telegram publish failed: ${e.message}');
      return PublishResult.failure(e);
    }

    try {
      return await _publish(variant, account, secrets, ctx, sent);
    } on AdapterException catch (e) {
      return failed(e.error);
    } on TelegramApiError catch (e) {
      return failed(e.toPublishError());
    } on Exception catch (e) {
      // The exception text may contain the token-bearing URL; chatUnexpected
      // blanks the token out.
      return failed(chatUnexpected(e, 'api.telegram.org', secret: secrets['bot_token']));
    }
  }

  Future<PublishResult> _publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets,
      AdapterContext ctx, ChatMessages sent) async {
    if (account.tier == PlatformTier.handoff) {
      throw const AdapterException(PublishError.unsupported('Hand-off accounts publish through the share page'));
    }
    final token = secrets['bot_token'];
    if (token == null || token.isEmpty) {
      throw const AdapterException(PublishError.auth('No Telegram bot token stored; reconnect the account'));
    }
    final chat = account.configString('chatId');
    if (chat.isEmpty) {
      throw const AdapterException(PublishError.configuration('This Telegram account has no chat; reconnect it'));
    }
    if (variant.media.length > telegramMaxAlbum) {
      throw const AdapterException(PublishError.validation('Telegram albums take at most 10 files'));
    }
    final api = TelegramApi(token, ctx);
    final markdown = account.configString('formatting', 'markdown') != 'plain';
    final parts = (variant.isThread ? variant.threadParts : [variant.text]).where((p) => p.trim().isNotEmpty).toList();
    final ids = sent.ids;
    String? previous;
    var nextPart = 0;
    final first = parts.isEmpty ? '' : parts.first;
    final asCaption = variant.hasMedia && first.isNotEmpty && first.length <= telegramMaxCaption;
    sent.total = (variant.hasMedia ? 1 : 0) + parts.length - (asCaption ? 1 : 0);

    if (variant.hasMedia) {
      final mediaId = variant.media.length == 1
          ? await _sendSingle(api, chat, variant, asCaption ? first : null, markdown, ctx)
          : await _sendAlbum(api, chat, variant, asCaption ? first : null, markdown, ctx);
      sent.add(mediaId);
      if (asCaption) {
        previous = mediaId;
        nextPart = 1;
      }
    }

    for (var i = nextPart; i < parts.length; i++) {
      ctx.progress(parts.length > 1 ? 'Sending part ${i + 1} of ${parts.length}' : 'Sending message');
      final replyTo = previous;
      final text = parts[i];
      // Later messages sit out a short flood wait (about one message per
      // second per chat) instead of leaving the post half finished.
      final id = ids.isEmpty
          ? await _sendText(api, chat, variant, text, markdown, replyTo)
          : await chatSendWithFloodWait(
              () => _sendText(api, chat, variant, text, markdown, replyTo), _telegramFloodWait);
      sent.add(id);
      previous = id;
    }
    if (ids.isEmpty) throw const AdapterException(PublishError.validation('Nothing to post'));
    ctx.log.info('Posted ${ids.length} Telegram message(s) to $chat');
    return PublishResult.ok(
      remoteId: ids.first,
      remoteUrl: telegramMessageUrl(account, ids.first),
      threadRemoteIds: ids.length > 1 ? List.unmodifiable(ids) : const [],
      publishedAt: ctx.now(),
    );
  }

  Future<String> _sendText(
      TelegramApi api, String chat, PostVariant v, String text, bool markdown, String? replyTo) async {
    final html = markdown ? chatMarkdownToHtml(text) : null;
    final res = await api.postJson('sendMessage', {
      'chat_id': chat,
      'text': html ?? text,
      if (html != null) 'parse_mode': 'HTML',
      if (v.extra['disableLinkPreview'] == true) 'link_preview_options': {'is_disabled': true},
      if (v.extra['silent'] == true) 'disable_notification': true,
      if (replyTo != null) 'reply_parameters': {'message_id': int.parse(replyTo), 'allow_sending_without_reply': true},
    });
    return _messageId(res);
  }

  Future<String> _sendSingle(
      TelegramApi api, String chat, PostVariant v, String? caption, bool markdown, AdapterContext ctx) async {
    final m = v.media.single;
    final document = m.isAudio && !telegramPlaysAudio(m);
    final (method, field) = switch (m.kind) {
      MediaKind.image => ('sendPhoto', 'photo'),
      MediaKind.gif => ('sendAnimation', 'animation'),
      MediaKind.video => ('sendVideo', 'video'),
      MediaKind.audio => document ? ('sendDocument', 'document') : ('sendAudio', 'audio'),
    };
    ctx.progress('Uploading ${m.noun} 1 of 1');
    final bytes = await ctx.readMedia(m);
    final thumbnail = m.isAudio ? await _audioThumbnail(m, ctx) : null;
    final performer = m.audioTags?.artist?.trim() ?? '';
    final res = await api.multipart(method, {
      'chat_id': chat,
      ..._captionFields(caption, markdown),
      if (v.sensitive && !m.isAudio) 'has_spoiler': 'true',
      if (v.extra['silent'] == true) 'disable_notification': 'true',
      if (m.isVideo) 'supports_streaming': 'true',
      if (m.kind != MediaKind.image && m.width != null) 'width': '${m.width}',
      if (m.kind != MediaKind.image && m.height != null) 'height': '${m.height}',
      if (m.kind != MediaKind.image && !document && m.durationMs != null) 'duration': '${(m.durationMs! / 1000).round()}',
      if (m.isAudio && !document) 'title': telegramTrackTitle(m),
      if (m.isAudio && !document && performer.isNotEmpty) 'performer': performer,
      // The cover, uploaded alongside under its own name.
      if (thumbnail != null) 'thumbnail': 'attach://cover',
      // A lossless file stays a file: Telegram must not treat it as anything else.
      if (document) 'disable_content_type_detection': 'true',
    }, [
      HttpFilePart(field: field, bytes: bytes, fileName: m.isAudio ? m.audioTaggedFileName ?? chatFileName(m) : chatFileName(m), contentType: m.mimeType),
      if (thumbnail != null) HttpFilePart(field: 'cover', bytes: thumbnail, fileName: 'cover.jpg', contentType: 'image/jpeg'),
    ]);
    return _messageId(res);
  }

  /// The track's cover as Telegram's thumbnail (a JPEG under 200 kB, at most
  /// 320 px on each side); null without a cover or when it cannot be read.
  Future<Uint8List?> _audioThumbnail(MediaAttachment m, AdapterContext ctx) async {
    final cover = m.audioCover;
    if (cover == null) return null;
    try {
      return await audioThumbnailJpeg(await ctx.readMedia(cover));
    } on Exception catch (e) {
      ctx.log.warn('Could not read the cover of ${m.fileName ?? m.id}: $e');
      return null;
    }
  }

  Future<String> _sendAlbum(
      TelegramApi api, String chat, PostVariant v, String? caption, bool markdown, AdapterContext ctx) async {
    final files = <HttpFilePart>[];
    final media = <Map<String, Object?>>[];
    for (var i = 0; i < v.media.length; i++) {
      final m = v.media[i];
      ctx.progress('Reading ${m.noun} ${i + 1} of ${v.media.length}');
      final name = 'file$i';
      files.add(HttpFilePart(field: name, bytes: await ctx.readMedia(m), fileName: chatFileName(m), contentType: m.mimeType));
      media.add({
        'type': m.isVideo ? 'video' : 'photo',
        'media': 'attach://$name',
        if (i == 0) ..._captionFields(caption, markdown),
        if (v.sensitive) 'has_spoiler': true,
        if (m.isVideo) 'supports_streaming': true,
        if (m.isVideo && m.width != null) 'width': m.width,
        if (m.isVideo && m.height != null) 'height': m.height,
        if (m.isVideo && m.durationMs != null) 'duration': (m.durationMs! / 1000).round(),
      });
    }
    ctx.progress('Uploading ${v.media.length} files as an album');
    final res = await api.multipart('sendMediaGroup', {
      'chat_id': chat,
      'media': telegramField(media),
      if (v.extra['silent'] == true) 'disable_notification': 'true',
    }, files);
    if (res is! List || res.isEmpty) {
      throw const AdapterException(PublishError.platform('Telegram did not return the album messages'));
    }
    return _messageId(res.first);
  }

  Map<String, String> _captionFields(String? caption, bool markdown) {
    if (caption == null || caption.isEmpty) return const {};
    final html = markdown ? chatMarkdownToHtml(caption) : null;
    return {'caption': html ?? caption, if (html != null) 'parse_mode': 'HTML'};
  }

  String _messageId(Object? message) {
    final id = message is Map ? chatId(message['message_id']) : null;
    if (id == null) throw const AdapterException(PublishError.platform('Telegram did not return a message id'));
    return id;
  }

  // ---------------------------------------------------------------- hand-off

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final full = variant.isThread ? variant.threadParts.join('\n\n') : variant.text;
    final link = variant.link?.trim() ?? '';
    // `url` is the required parameter and lands on the first line; with no
    // link, the whole text goes there.
    final String url;
    String? text;
    if (link.isNotEmpty) {
      url = link;
      final rest = full.replaceFirst(link, '').trim();
      text = rest.isEmpty ? null : rest;
    } else {
      url = full;
    }
    final intent = Uri.parse('https://t.me/share/url?url=${Uri.encodeComponent(url)}'
        '${text == null ? '' : '&text=${Uri.encodeComponent(text)}'}');
    final media = variant.hasMedia;
    return HandoffPlan(
      platformId: id,
      webIntent: intent,
      clipboardText: full,
      shareText: full,
      shareFiles: variant.media,
      androidPackage: 'org.telegram.messenger',
      iosScheme: 'tg://',
      desktopUrl: intent.toString(),
      preferred: media ? HandoffMethod.shareSheet : HandoffMethod.webIntent,
      instructions: media
          ? '1. Choose Telegram in the share sheet.\n'
              '2. Pick your channel or group.\n'
              '3. If the text is missing, paste it from the clipboard as the caption.\n'
              '4. Press **Send**.'
          : '1. NEFORUM opens Telegram with your text ready.\n'
              '2. Pick your channel or group.\n'
              '3. Check the text and press **Send**.',
      mediaNote: media
          ? 'Telegram\'s share link cannot carry files, so media goes through the share sheet. '
              'Your full text is on the clipboard.'
          : null,
    );
  }
}

/// Normalises what the user typed into a `chat_id`: `@username` for public
/// chats, the numeric id otherwise. Throws [ConnectException] on junk.
String normalizeTelegramChat(String raw) {
  var s = raw.trim();
  if (s.isEmpty) throw const ConnectException('Enter the channel (@username) or its numeric id.', field: 'chat');
  if (RegExp(r'^-?\d+$').hasMatch(s)) return s;
  final link = RegExp(r'^(?:https?://)?(?:www\.)?(?:t\.me|telegram\.me)/(.+)$', caseSensitive: false).firstMatch(s);
  if (link != null) {
    final path = link.group(1)!.split(RegExp(r'[/?#]')).first;
    if (path.startsWith('+') || path == 'joinchat') {
      throw const ConnectException('Invite links cannot be used by bots. Enter the numeric chat id (-100…) instead.',
          field: 'chat');
    }
    s = path;
  }
  if (s.startsWith('@')) s = s.substring(1);
  if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]{3,31}$').hasMatch(s)) {
    throw const ConnectException('That is not a valid Telegram @username or chat id.', field: 'chat');
  }
  return '@$s';
}

/// Public link to a posted message: `t.me/<username>/<id>` for public chats,
/// `t.me/c/<id>/<msg>` (members only) for private supergroups and channels.
String? telegramMessageUrl(ConnectedAccount account, String messageId) {
  final username = account.configString('chatUsername');
  if (username.isNotEmpty) return 'https://t.me/$username/$messageId';
  final chat = account.configString('chatId');
  if (chat.startsWith('-100') && chat.length > 4) return 'https://t.me/c/${chat.substring(4)}/$messageId';
  return null;
}

Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

/// How long Telegram asked to wait when [e] is a flood-control answer.
Duration? _telegramFloodWait(Object e) =>
    e is TelegramApiError && e.code == 429 ? (e.retryAfter ?? const Duration(seconds: 1)) : null;
