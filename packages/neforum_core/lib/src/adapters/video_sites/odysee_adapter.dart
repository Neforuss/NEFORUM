import 'package:uuid/uuid.dart';

import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../model/account.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'video_site_common.dart';

/// Odysee (the LBRY network).
///
/// * **Automatic** ([PlatformTier.openApi]): through the LBRY SDK's JSON-RPC
///   API (`lbrynet`, http://localhost:5279), which the LBRY desktop app runs.
///   `publish` reads the video straight from its file, so its size does not
///   matter, and creates the claim in the channel of the wallet the app is
///   signed in to. Publishing needs a small LBC deposit ([defaultBid]),
///   returned if the video is removed later. Desktop only: the SDK runs on the
///   same computer.
/// * **Hand-off**: odysee.com's upload page with the title, description and
///   tags ready to paste (web uploads up to 4 GB).
class OdyseeAdapter extends PlatformAdapter {
  static const String defaultDaemon = 'http://localhost:5279';
  static const String defaultBid = '0.001';
  static const String uploadUrl = 'https://odysee.com/\$/upload';
  static const int titleMax = 200;

  static const cfgDaemon = 'daemon';
  static const cfgChannelId = 'channelId';
  static const cfgChannelName = 'channelName';
  static const cfgBid = 'bid';

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'odysee',
    name: 'Odysee',
    iconKey: 'odysee',
    homepage: 'https://odysee.com/',
    tiers: {PlatformTier.openApi, PlatformTier.handoff},
    defaultTier: PlatformTier.openApi,
    text: TextRules(
      maxLength: 5000,
      titleSupported: true,
      titleRequired: true,
      titleMax: titleMax,
      hashtagsAsField: true,
      maxHashtags: 5,
      notes: 'The text is the description; the title goes in its own field (NEFORUM uses the first line when the '
          'post has no title). Odysee shows up to five tags.',
    ),
    media: MediaRules(
      maxImages: 1,
      maxVideos: 1,
      requiresMedia: true,
      videoMimeTypes: {'video/mp4', 'video/quicktime', 'video/webm', 'video/x-matroska'},
      notes: 'One video (or picture) per upload. Automatic uploads read the file directly, so large videos are fine; '
          'the LBRY app finishes sending it in the background, so keep it open until Odysee shows the video.',
    ),
    accountRequirements: 'Automatic: the LBRY desktop app on this computer, signed in with your Odysee account, and a '
        'little LBC for the deposit. Hand-off: any Odysee account.',
    apiCostSummary: 'Free apart from a tiny LBC deposit per upload (0.001 LBC by default), which you get back if you '
        'remove the video. No developer keys.',
    setupGuide: 'docs/platforms/odysee.md',
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.openApi,
          loopbackRedirectOk: false,
          customSchemeRedirectOk: false,
          intro: '''
**Upload to Odysee automatically through the LBRY app on this computer.**

1. Install and open the **LBRY desktop app** (lbry.com/get) and sign in with your **Odysee account**, so it holds your
   channel. Keep it running: it is what publishes (NEFORUM talks to it at `http://localhost:5279`).
2. Make sure the wallet has a little LBC: each upload locks a deposit of 0.001 LBC, returned if you remove the video.
3. Enter your channel below (for example `@mychannel`) and click Connect.

Videos are read straight from their file, so their size does not matter. After NEFORUM publishes, the LBRY app keeps
sending the video to Odysee in the background: leave it open until the video plays on odysee.com.''',
          fields: [
            ConnectField(
              key: 'channel',
              label: 'Channel',
              required: false,
              placeholder: '@mychannel',
              help: 'The Odysee channel to publish in (it must be in the LBRY app\'s wallet). Leave empty to publish '
                  'without a channel.',
            ),
            ConnectField(
              key: cfgBid,
              label: 'Deposit per upload (LBC)',
              required: false,
              defaultValue: defaultBid,
              help: 'Locked while the video is up, returned when it is removed. Higher deposits rank a name higher '
                  'in LBRY search.',
            ),
            ConnectField(
              key: cfgDaemon,
              label: 'LBRY SDK address (advanced)',
              kind: FieldKind.url,
              required: false,
              defaultValue: defaultDaemon,
              help: 'Where the LBRY app\'s SDK (lbrynet) listens. Only change it if you run lbrynet yourself.',
            ),
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.handoff,
          loopbackRedirectOk: false,
          customSchemeRedirectOk: false,
          intro: 'No setup needed. NEFORUM opens odysee.com\'s upload page with your title, description and tags ready to '
              'paste, and saves the video to Downloads so you can pick it (Odysee\'s website takes files up to 4 GB).',
          fields: [
            ConnectField(key: 'label', label: 'Name to show in NEFORUM', required: false, placeholder: 'My Odysee'),
          ],
        ),
      ];

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier == PlatformTier.handoff) {
      final label = (input['label'] ?? '').trim();
      return ConnectResult(
        account: ConnectedAccount(
          id: 'odysee:handoff:${const Uuid().v4()}',
          platformId: id,
          tier: PlatformTier.handoff,
          displayName: label.isEmpty ? 'Odysee (hand-off)' : label,
          createdAt: ctx.now(),
        ),
      );
    }
    if (tier != PlatformTier.openApi) throw ConnectException('Odysee does not support the ${tier.label} tier');

    final daemon = _daemonUri((input[cfgDaemon] ?? '').trim());
    if (daemon == null) throw const ConnectException('Enter the address as http://localhost:5279', field: cfgDaemon);
    final bid = (input[cfgBid] ?? '').trim().isEmpty ? defaultBid : input[cfgBid]!.trim();
    final bidValue = double.tryParse(bid);
    if (bidValue == null || bidValue <= 0) throw const ConnectException('Enter a deposit above 0, such as 0.001', field: cfgBid);

    try {
      await _call(ctx, daemon, 'status', const {});
    } on _SdkUnreachable {
      throw ConnectException('NEFORUM cannot reach the LBRY app at $daemon. Open the LBRY desktop app, sign in with your '
          'Odysee account and try again.');
    }

    final wanted = _normalizeChannel(input['channel'] ?? '');
    String? channelId, channelName;
    if (wanted.isNotEmpty) {
      final res = await _call(ctx, daemon, 'channel_list', const {'page_size': 50});
      final items = res is Map && res['items'] is List ? res['items'] as List : const <Object?>[];
      final names = <String>[];
      for (final c in items) {
        if (c is! Map) continue;
        final name = '${c['name'] ?? ''}';
        names.add(name);
        if (name.toLowerCase() == wanted.toLowerCase()) {
          channelId = '${c['claim_id'] ?? ''}';
          channelName = name;
        }
      }
      if (channelId == null || channelId.isEmpty) {
        throw ConnectException(
          names.isEmpty
              ? 'The LBRY app\'s wallet has no channels. Sign in to the LBRY app with your Odysee account first.'
              : 'The LBRY app\'s wallet has no channel called $wanted. Its channels: ${names.join(', ')}',
          field: 'channel',
        );
      }
    }

    return ConnectResult(
      account: ConnectedAccount(
        id: 'odysee:${channelId ?? 'anonymous'}',
        platformId: id,
        tier: PlatformTier.openApi,
        displayName: channelName ?? 'Odysee (no channel)',
        handle: channelName,
        profileUrl: channelName == null ? 'https://odysee.com/' : 'https://odysee.com/$channelName:${channelId!.substring(0, 1)}',
        createdAt: ctx.now(),
        config: {
          cfgDaemon: daemon.toString(),
          cfgBid: bid,
          if (channelId != null) cfgChannelId: channelId,
          if (channelName != null) cfgChannelName: channelName,
        },
      ),
    );
  }

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = [...super.validate(variant, account)];
    if (account.tier == PlatformTier.openApi && variant.media.isNotEmpty && variant.media.first.path.startsWith('http')) {
      issues.add(const ValidationIssue.error('odysee.local_file', 'Odysee uploads need the file on this computer', field: 'media'));
    }
    return issues;
  }

  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.openApi) {
      return PublishResult.failure(const PublishError.unsupported('Odysee hand-off accounts are posted by you on odysee.com'));
    }
    final daemon = _daemonUri(account.configString(cfgDaemon)) ?? Uri.parse(defaultDaemon);
    if (variant.media.isEmpty) return PublishResult.failure(const PublishError.validation('Odysee needs a video or a picture'));
    final media = variant.media.first;
    final title = videoTitle(variant, max: titleMax);
    final name = '${slugFor(title)}-${const Uuid().v4().substring(0, 6)}';
    final channelId = account.configString(cfgChannelId);
    ctx.onProgress?.call('Publishing on Odysee (the LBRY app prepares the file)');
    try {
      final res = await _call(ctx, daemon, 'publish', {
        'name': name,
        'bid': account.configString(cfgBid).isEmpty ? defaultBid : account.configString(cfgBid),
        'file_path': media.path,
        'title': title,
        'description': videoDescription(variant),
        if (variant.tags.isNotEmpty) 'tags': [for (final t in variant.tags.take(5)) t.replaceFirst('#', '').toLowerCase()],
        if (channelId.isNotEmpty) 'channel_id': channelId,
        'blocking': true,
      }, timeout: const Duration(minutes: 30));
      final outputs = res is Map && res['outputs'] is List ? res['outputs'] as List : const <Object?>[];
      final out = outputs.whereType<Map<Object?, Object?>>().firstOrNull;
      final claimId = '${out?['claim_id'] ?? ''}';
      final claimName = '${out?['name'] ?? name}';
      return PublishResult.ok(
        remoteId: claimId.isEmpty ? null : claimId,
        remoteUrl: claimId.isEmpty ? null : 'https://odysee.com/$claimName:$claimId',
        publishedAt: ctx.now(),
      );
    } on _SdkUnreachable {
      return PublishResult.failure(const PublishError.network('The LBRY app is not running: open it and NEFORUM will retry'));
    } on _SdkError catch (e) {
      final m = e.message.toLowerCase();
      if (m.contains('not enough funds') || m.contains('insufficient')) {
        return PublishResult.failure(PublishError.configuration(
            'The LBRY wallet has too little LBC for the deposit (${account.configString(cfgBid)} LBC plus a small fee). '
            'Add LBC in the LBRY app and try again.'));
      }
      return PublishResult.failure(PublishError.platform('Odysee (LBRY SDK) refused the upload: ${e.message}', raw: e.message));
    }
  }

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) => videoSiteHandoff(
        variant,
        platformId: id,
        name: 'Odysee',
        uploadUrl: uploadUrl,
        titleMax: titleMax,
        maxTags: 5,
        androidPackage: 'com.odysee.app',
        extraStep: 'Pick the channel to publish in, then a thumbnail if Odysee asks for one.',
      );

  /// "My first video!" -> "my-first-video": a claim name (letters, digits and
  /// dashes; LBRY URLs cannot contain spaces or #:@/ characters).
  static String slugFor(String title) {
    final s = title.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final short = s.length > 60 ? s.substring(0, 60).replaceAll(RegExp(r'-+$'), '') : s;
    return short.isEmpty ? 'video' : short;
  }

  static String _normalizeChannel(String raw) {
    final c = raw.trim().replaceFirst(RegExp(r'^https?://odysee\.com/'), '').split(':').first.split('/').first;
    if (c.isEmpty) return '';
    return c.startsWith('@') ? c : '@$c';
  }

  static Uri? _daemonUri(String raw) {
    final u = Uri.tryParse(raw.isEmpty ? defaultDaemon : raw);
    return u == null || !u.hasScheme || u.host.isEmpty ? null : u;
  }

  /// One JSON-RPC call to lbrynet: `{"method": ..., "params": ...}`; returns
  /// `result`.
  static Future<Object?> _call(AdapterContext ctx, Uri daemon, String method, Map<String, Object?> params,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final NeforumResponse res;
    try {
      res = await ctx.http.send('POST', daemon, jsonBody: {'method': method, 'params': params}, throwOnError: false, timeout: timeout);
    } on Object catch (e) {
      if (NeforumHttp.isTransportError(e)) throw const _SdkUnreachable();
      rethrow;
    }
    if (!res.ok) throw _SdkError('HTTP ${res.statusCode}');
    final j = res.jsonMap;
    final err = j['error'];
    if (err != null) throw _SdkError(err is Map ? '${err['message'] ?? err}' : '$err');
    final result = j['result'];
    if (result is Map && result['error'] != null) throw _SdkError('${result['error']}');
    return result;
  }
}

class _SdkUnreachable implements Exception {
  const _SdkUnreachable();
}

class _SdkError implements Exception {
  const _SdkError(this.message);
  final String message;
}
