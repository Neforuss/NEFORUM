import 'dart:convert';

import '../../http/neforum_http.dart';
import '../../model/account.dart';
import '../../model/media.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../../text/rules_validator.dart';
import '../../text/text_splitter.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'chat_common.dart';

/// Execute Webhook `content`: up to 2000 characters.
const int discordMaxContent = 2000;

/// Reference > Uploading Files: "default limit is 20 MiB for all users"
/// per file (higher with Nitro / server boosts).
const int discordFileMaxBytes = 20 * 1024 * 1024;

/// Message resource: "The maximum request size when sending a message is
/// 25 MiB."
const int discordRequestMaxBytes = 25 * 1024 * 1024;

/// Attachments per message.
const int discordMaxFiles = 10;

/// Attachment `description` (alt text): max 1024 characters.
const int discordMaxAltText = 1024;

/// Forum post (thread) names: max 100 characters.
const int discordMaxThreadName = 100;

/// Posts with `extra['mentionEveryone'] == true` start with this line
/// (unless the text already mentions @everyone or @here).
const String discordEveryoneMention = '@everyone';

/// @everyone or @here in the text. Discord's `everyone` mention type covers
/// both.
final RegExp _everyoneOrHere = RegExp(r'@(?:everyone|here)(?!\w)');

const String _apiBase = 'https://discord.com/api/v10';

/// A parsed incoming-webhook URL.
class DiscordWebhook {
  const DiscordWebhook(this.id, this.token, {this.threadId});

  final String id;
  final String token;

  /// `?thread_id=` from the pasted URL, if any.
  final String? threadId;

  /// Canonical, versioned execute URL.
  Uri get url => Uri.parse('$_apiBase/webhooks/$id/$token');

  /// Parses `https://discord.com/api/webhooks/{id}/{token}` (also
  /// `discordapp.com`, `ptb.` / `canary.` hosts and `/api/vN/`).
  static DiscordWebhook parse(String raw) {
    final m = RegExp(
      r'^https://(?:(?:ptb|canary)\.)?discord(?:app)?\.com/api(?:/v\d+)?/webhooks/(\d{5,25})/([A-Za-z0-9_-]{20,200})/?(\?.*)?$',
    ).firstMatch(raw.trim());
    if (m == null) {
      throw const ConnectException('That is not a Discord webhook URL. It looks like '
          'https://discord.com/api/webhooks/1234…/AbCd… (Copy Webhook URL in the channel\'s Integrations).',
          field: 'webhook_url');
    }
    final query = m.group(3);
    final thread = query == null ? null : Uri.splitQueryString(query.substring(1))['thread_id'];
    return DiscordWebhook(m.group(1)!, m.group(2)!, threadId: chatStr(thread));
  }
}

/// Posts to a Discord channel through an incoming webhook.
///
/// Connect: the webhook URL (a secret; it needs no other credentials),
/// verified with `GET /webhooks/{id}/{token}`. Publish: `POST
/// /webhooks/{id}/{token}?wait=true`, as JSON or as multipart with
/// `payload_json` + `files[n]`. Long posts go out as consecutive messages.
class DiscordAdapter extends PlatformAdapter {
  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'discord',
    name: 'Discord',
    iconKey: 'discord',
    homepage: 'https://discord.com',
    tiers: {PlatformTier.openApi},
    defaultTier: PlatformTier.openApi,
    text: TextRules(
      maxLength: discordMaxContent,
      // Discord says "characters"; UTF-16 never under-counts them.
      counting: CountingRule.utf16,
      supportsThreads: true,
      supportsMarkdown: true,
      supportsHashtags: false,
      linkInText: true,
      notes: 'Messages up to 2000 characters; longer posts are sent as several messages in a row. '
          'Discord Markdown (**bold**, *italic*, `code`, > quote) is shown as-is. With "Mention @everyone" on '
          '(the default; Settings > Posting, or per post in Customize) the first message starts with @everyone '
          'and notifies the channel once. Otherwise @everyone/@here and role mentions are not pinged.',
    ),
    media: MediaRules(
      maxImages: discordMaxFiles,
      maxVideos: discordMaxFiles,
      allowsMixedImageVideo: true,
      imageMaxBytes: discordFileMaxBytes,
      videoMaxBytes: discordFileMaxBytes,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/avif'},
      videoMimeTypes: {'video/mp4', 'video/quicktime', 'video/webm'},
      supportsAltText: true,
      notes: 'Up to 10 files per message, 20 MiB each by default (more on boosted servers) and 25 MiB per message '
          'in total. Alt text up to 1024 characters. Sensitive media is sent as a spoiler.',
    ),
    defaultQuotas: [
      QuotaRule(
        id: 'discord.webhook_messages_per_minute',
        limit: 30,
        window: Duration(minutes: 1),
        note: 'approximate per-webhook limit (community-documented, not in the official docs); '
            'Discord answers 429 with the exact wait',
        appliesToTier: PlatformTier.openApi,
      ),
    ],
    personalAccountOk: true,
    accountRequirements: 'You need the "Manage Webhooks" permission in the Discord server. One webhook posts '
        'into one channel; no bot or developer account is needed.',
    apiCostSummary: 'Free. Discord limits how fast a webhook may post (it tells NEFORUM how long to wait) and how '
        'big files may be (20 MiB each unless the server is boosted).',
    setupGuide: 'docs/platforms/discord.md',
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
          intro: '**Discord posts through a channel webhook. No bot or developer account is needed.**\n\n'
              '1. In Discord, hover the channel and click the gear (**Edit Channel**) > **Integrations** > '
              '**Webhooks** > **New Webhook**. (You need the *Manage Webhooks* permission.)\n'
              '2. Give it a name and avatar; this is how your posts will appear.\n'
              '3. Click **Copy Webhook URL** and paste it below.\n\n'
              'Treat the URL like a password: anyone who has it can post in the channel. One webhook = one '
              'channel; add another account for each channel.',
          redirectNote: 'Nothing to register: webhooks do not use redirect URIs.',
          fields: [
            ConnectField(
              key: 'webhook_url',
              label: 'Webhook URL',
              kind: FieldKind.password,
              secret: true,
              placeholder: 'https://discord.com/api/webhooks/123456789012345678/AbCdEf…',
              help: 'Edit Channel > Integrations > Webhooks > Copy Webhook URL.',
            ),
            ConnectField(
              key: 'username',
              label: 'Post as (optional)',
              required: false,
              help: 'Overrides the webhook\'s name for NEFORUM posts (up to 80 characters, without "discord" or '
                  '"clyde"). Leave empty to use the webhook\'s own name.',
            ),
            ConnectField(
              key: 'forum',
              label: 'Forum or media channel',
              kind: FieldKind.boolean,
              required: false,
              defaultValue: 'false',
              help: 'Turn on when the webhook belongs to a forum/media channel: every post then starts a new '
                  'forum post, named after the title (or the first line).',
            ),
          ],
        ),
      ];

  // ---------------------------------------------------------------- connect

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    final hook = DiscordWebhook.parse(input['webhook_url'] ?? '');
    final username = (input['username'] ?? '').trim();
    // Webhook names: 1-80 characters and never "clyde" or "discord" (any
    // case); Discord refuses every post that overrides the name with one.
    if (username.length > 80 || RegExp('clyde|discord', caseSensitive: false).hasMatch(username)) {
      throw const ConnectException('"Post as" must be at most 80 characters and may not contain "discord" or "clyde".',
          field: 'username');
    }
    ctx.progress('Checking the webhook');
    final NeforumResponse res;
    try {
      res = await ctx.http.get(hook.url, throwOnError: false);
    } on Exception {
      throw const ConnectException('Could not reach discord.com. Check your internet connection.');
    }
    if (res.statusCode == 401 || res.statusCode == 404) {
      throw const ConnectException('Discord does not know this webhook (deleted, or the URL is incomplete). '
          'Copy the URL again.', field: 'webhook_url');
    }
    if (res.statusCode == 429) {
      throw const ConnectException('Discord is rate limiting this network. Wait a minute and try again.');
    }
    if (!res.ok) throw ConnectException('Discord answered HTTP ${res.statusCode} while checking the webhook.');
    final w = res.jsonMap;
    final channelId = chatId(w['channel_id']);
    if (chatId(w['id']) != hook.id || channelId == null) {
      throw const ConnectException('Discord answered, but not with this webhook.', field: 'webhook_url');
    }
    if (chatInt(w['type']) != null && chatInt(w['type']) != 1) {
      throw const ConnectException('This is not an incoming webhook. Create one under Integrations > Webhooks.',
          field: 'webhook_url');
    }
    final name = chatStr(w['name']) ?? 'Webhook';
    final guildId = chatId(w['guild_id']);
    final avatar = chatStr(w['avatar']);
    final forum = (input['forum'] ?? '').trim().toLowerCase() == 'true';
    return ConnectResult(
      account: ConnectedAccount(
        id: 'discord:${hook.id}',
        platformId: id,
        tier: PlatformTier.openApi,
        displayName: '$name (Discord webhook)',
        handle: username.isNotEmpty ? username : name,
        avatarUrl: avatar == null ? null : 'https://cdn.discordapp.com/avatars/${hook.id}/$avatar.png',
        profileUrl: guildId == null ? null : 'https://discord.com/channels/$guildId/$channelId',
        createdAt: ctx.now(),
        config: {
          'webhookId': hook.id,
          'webhookName': name,
          'channelId': channelId,
          if (guildId != null) 'guildId': guildId,
          if (hook.threadId != null) 'threadId': hook.threadId,
          if (username.isNotEmpty) 'username': username,
          'forum': forum,
        },
      ),
      secrets: {'webhook_url': hook.url.toString()},
    );
  }

  // --------------------------------------------------------------- validate

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = RulesValidator.validate(variant, descriptor, tier: account.tier);
    if (variant.media.length > discordMaxFiles) {
      issues.add(ValidationIssue.error('media.too_many',
          '${variant.media.length} files; Discord allows $discordMaxFiles per message', field: 'media'));
    }
    final total = variant.media.fold<int>(0, (s, m) => s + m.sizeBytes);
    if (total > discordRequestMaxBytes) {
      issues.add(ValidationIssue.error('media.total_too_large',
          'Files add up to ${(total / (1024 * 1024)).toStringAsFixed(1)} MB; Discord takes 25 MB per message',
          field: 'media'));
    }
    if (variant.media.any((m) => (m.altText ?? '').length > discordMaxAltText)) {
      issues.add(const ValidationIssue.warning('media.alt_too_long',
          'Alt text longer than 1024 characters will be shortened', field: 'media'));
    }
    if (account.config['forum'] == true && (variant.title ?? '').trim().isEmpty) {
      issues.add(const ValidationIssue.info('title.forum',
          'Forum post title: the first line of the text will be used', field: 'title'));
    }
    if (variant.extra['mentionEveryone'] == true) {
      final parts = variant.isThread ? variant.threadParts : [variant.text];
      issues.add(parts.any(_everyoneOrHere.hasMatch)
          ? const ValidationIssue.info('mention.everyone', 'Your @everyone or @here notifies the channel', field: 'text')
          : const ValidationIssue.info('mention.everyone', 'Starts with @everyone, which notifies everyone in the channel',
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
      ctx.log.warn('Discord publish failed: ${e.message}');
      return PublishResult.failure(e);
    }

    try {
      return await _publish(variant, account, secrets, ctx, sent);
    } on AdapterException catch (e) {
      return failed(e.error);
    } on Exception catch (e) {
      // The webhook token is part of the URL; keep it out of the message.
      final hook = secrets['webhook_url'];
      final token = hook == null ? null : RegExp(r'/webhooks/\d+/([^/?#]+)').firstMatch(hook)?.group(1);
      return failed(chatUnexpected(e, 'discord.com', secret: token));
    }
  }

  Future<PublishResult> _publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets,
      AdapterContext ctx, ChatMessages sent) async {
    final raw = secrets['webhook_url'];
    if (raw == null || raw.isEmpty) {
      throw const AdapterException(PublishError.auth('No Discord webhook URL stored; reconnect the account'));
    }
    final DiscordWebhook hook;
    try {
      hook = DiscordWebhook.parse(raw);
    } on ConnectException {
      throw const AdapterException(PublishError.auth('The stored Discord webhook URL is invalid; reconnect'));
    }
    if (variant.media.length > discordMaxFiles) {
      throw const AdapterException(PublishError.validation('Discord takes at most 10 files per message'));
    }
    var parts = (variant.isThread ? variant.threadParts : [variant.text]).where((p) => p.trim().isNotEmpty).toList();
    if (parts.isEmpty) parts.add('');
    // "Mention @everyone": exactly one message may notify the channel, the
    // first that names @everyone or @here. Without one, the post gets an
    // @everyone line at the top.
    var mentionAt = -1;
    if (variant.extra['mentionEveryone'] == true) {
      mentionAt = parts.indexWhere(_everyoneOrHere.hasMatch);
      if (mentionAt < 0) {
        parts = [...discordWithEveryone(parts.first), ...parts.skip(1)];
        mentionAt = 0;
      }
    }
    final forum = account.config['forum'] == true;
    var threadId = chatStr(account.config['threadId']);
    final ids = sent.ids;
    sent.total = parts.length;
    String? channelId;

    for (var i = 0; i < parts.length; i++) {
      ctx.progress(parts.length > 1 ? 'Sending part ${i + 1} of ${parts.length}' : 'Sending message');
      final payload = <String, Object?>{
        if (parts[i].isNotEmpty) 'content': parts[i],
        if (chatStr(account.config['username']) != null) 'username': account.config['username'],
        'allowed_mentions': {'parse': i == mentionAt ? const ['everyone'] : <String>[]},
        if (variant.extra['disableLinkPreview'] == true) 'flags': 4,
        if (forum && i == 0 && threadId == null) 'thread_name': discordThreadName(variant),
      };
      final query = {'wait': 'true', if (threadId != null) 'thread_id': threadId};
      final url = hook.url.replace(queryParameters: query);
      final media = i == 0 ? variant.media : const <MediaAttachment>[];
      final part = i;
      // Later messages sit out a short rate-limit wait instead of leaving
      // the post half finished.
      final msg = ids.isEmpty
          ? await _execute(url, payload, media, variant.sensitive, ctx, part, parts.length)
          : await chatSendWithFloodWait(
              () => _execute(url, payload, media, variant.sensitive, ctx, part, parts.length), _discordFloodWait);
      final msgId = chatId(msg['id']);
      if (msgId == null) throw const AdapterException(PublishError.platform('Discord did not return a message id'));
      sent.add(msgId);
      channelId ??= chatId(msg['channel_id']);
      // A forum post creates a thread whose id is the message's channel id;
      // later parts go into it.
      if (forum && threadId == null) threadId = chatId(msg['channel_id']);
    }

    final guild = chatStr(account.config['guildId']);
    final channel = channelId ?? chatStr(account.config['channelId']);
    return PublishResult.ok(
      remoteId: ids.first,
      remoteUrl: guild == null || channel == null ? null : 'https://discord.com/channels/$guild/$channel/${ids.first}',
      threadRemoteIds: ids.length > 1 ? List.unmodifiable(ids) : const [],
      publishedAt: ctx.now(),
    );
  }

  Future<Map<String, dynamic>> _execute(Uri url, Map<String, Object?> payload, List<MediaAttachment> media,
      bool spoiler, AdapterContext ctx, int part, int parts) async {
    final NeforumResponse res;
    if (media.isEmpty) {
      res = await ctx.http.postJson(url, payload, throwOnError: false);
    } else {
      final files = <HttpFilePart>[];
      final attachments = <Map<String, Object?>>[];
      for (var i = 0; i < media.length; i++) {
        final m = media[i];
        ctx.progress('Reading ${m.isVideo ? 'video' : 'image'} ${i + 1} of ${media.length}');
        final name = spoiler ? 'SPOILER_${chatFileName(m)}' : chatFileName(m);
        files.add(HttpFilePart(field: 'files[$i]', bytes: await ctx.readMedia(m), fileName: name, contentType: m.mimeType));
        final alt = m.altText?.trim() ?? '';
        attachments.add({
          'id': i,
          'filename': name,
          if (alt.isNotEmpty) 'description': alt.length > discordMaxAltText ? alt.substring(0, discordMaxAltText) : alt,
        });
      }
      ctx.progress('Uploading ${media.length} file${media.length == 1 ? '' : 's'}');
      res = await ctx.http.multipart(url,
          fields: {'payload_json': jsonEncode({...payload, 'attachments': attachments})}, files: files, throwOnError: false);
    }
    if (!res.ok) throw AdapterException(discordError(res, parts > 1 ? 'Discord part ${part + 1}/$parts' : 'Discord'));
    final msg = res.jsonMap;
    if (msg.isEmpty) throw const AdapterException(PublishError.platform('Discord returned no message'));
    return msg;
  }
}

/// How long Discord asked to wait when [e] is a 429 answer.
Duration? _discordFloodWait(Object e) =>
    e is AdapterException && e.error.statusCode == 429 ? (e.error.retryAfter ?? const Duration(seconds: 1)) : null;

/// [part] with [discordEveryoneMention] on a line of its own above it. A part
/// the extra line makes longer than a message may be is split again.
List<String> discordWithEveryone(String part) {
  const lead = '$discordEveryoneMention\n';
  if (part.trim().isEmpty) return const [discordEveryoneMention];
  if (part.length + lead.length <= discordMaxContent) return ['$lead$part'];
  final pieces = TextSplitter.split(
      part, const TextRules(maxLength: discordMaxContent - lead.length, counting: CountingRule.utf16),
      numbering: false);
  return ['$lead${pieces.first}', ...pieces.skip(1)];
}

/// Forum post name: the variant title, else the first line, max 100 chars.
String discordThreadName(PostVariant v) {
  final title = v.title?.trim() ?? '';
  var name = title.isNotEmpty ? title : v.text.trim().split('\n').first.trim();
  if (name.isEmpty) name = 'New post';
  return name.length > discordMaxThreadName ? '${name.substring(0, discordMaxThreadName - 1)}…' : name;
}

/// Maps a failed webhook response onto a [PublishError].
PublishError discordError(NeforumResponse res, String where) {
  final body = res.jsonMap;
  final code = chatInt(body['code']);
  final message = chatStr(body['message']) ?? 'HTTP ${res.statusCode}';
  final raw = chatSnippet(res.body);
  final status = res.statusCode;
  if (status == 429) {
    final secs = body['retry_after'];
    final retry = secs is num ? Duration(milliseconds: (secs * 1000).ceil()) : res.retryAfter;
    return PublishError.quota('$where: rate limited${body['global'] == true ? ' (global)' : ''}',
        raw: raw, statusCode: status, retryAfter: retry);
  }
  if (status == 401 || status == 403 || status == 404 || code == 10015 || code == 50027) {
    return PublishError.auth('$where: the webhook no longer works ($message). Create a new one and reconnect.',
        raw: raw, statusCode: status);
  }
  if (status == 413 || code == 40005) {
    return PublishError.validation('$where: files too large for this server ($message)', raw: raw, statusCode: status);
  }
  if (status >= 500) return PublishError.network('$where: Discord server error $status', raw: raw, statusCode: status);
  if (status == 400) return PublishError.validation('$where: $message', raw: raw, statusCode: status);
  return PublishError.platform('$where: $message', raw: raw, statusCode: status);
}
