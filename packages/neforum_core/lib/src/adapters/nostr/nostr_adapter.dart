import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../../handoff/handoff_plan.dart';
import '../../model/account.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../../text/url_detector.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'nostr_event.dart';
import 'nostr_media.dart';
import 'nostr_relay.dart';

/// Relays used when the user does not enter their own. Widely used public
/// relays that accept writes without payment.
const List<String> nostrDefaultRelays = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
  'wss://relay.nostr.band',
];

/// Default NIP-96 media server (free plan: 20 MB per file, NIP-98 auth).
const String nostrDefaultNip96Server = 'https://nostr.build';

/// Publishes kind-1 notes to Nostr relays, signed locally with the user's
/// key (NIP-01), with media uploaded via a media host or NIP-96.
///
/// Account config keys: `pubkey` (hex), `npub`, `relays` (list of wss URLs),
/// `nip96Server` (base URL; empty string disables NIP-96).
/// Secret keys: `privateKey` (64-hex).
class NostrAdapter extends PlatformAdapter {
  NostrAdapter({
    RelayConnector? connector,
    this.relayTimeout = const Duration(seconds: 8),
    this.connectTimeout = const Duration(seconds: 8),
    this.mediaPollInterval = const Duration(seconds: 2),
    Random? random,
  })  : _connector = connector ?? webSocketRelayConnector,
        _random = random;

  final RelayConnector _connector;
  final Random? _random;

  /// How long to wait for each relay's `OK`.
  final Duration relayTimeout;

  /// How long to wait for each relay's WebSocket to open.
  final Duration connectTimeout;

  /// Delay between polls of a NIP-96 `processing_url`.
  final Duration mediaPollInterval;

  static const String secretPrivateKey = 'privateKey';
  static const String configPubkey = 'pubkey';
  static const String configNpub = 'npub';
  static const String configRelays = 'relays';
  static const String configNip96 = 'nip96Server';

  static const int _largeEventBytes = 64 * 1024;

  @override
  PlatformDescriptor get descriptor => nostrDescriptor;

  @override
  List<ConnectSpec> get connectSpecs => const [_spec, _handoffSpec];

  /// Hand the note to the user's own Nostr app, which holds the key.
  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final full = variant.isThread ? variant.threadParts.join('\n\n') : variant.text;
    return HandoffPlan(
      platformId: descriptor.id,
      preferred: HandoffMethod.shareSheet,
      clipboardText: full,
      shareText: full,
      shareFiles: variant.media,
      // Amethyst accepts shared text and images; other apps appear in the
      // share sheet too.
      androidPackage: 'com.vitorpamplona.amethyst',
      desktopUrl: 'https://primal.net/home',
      instructions: '1. Share to your Nostr app (Amethyst, Damus, Primal, …), or open Primal on the web.\n'
          '2. If the text is not filled in, paste it: NEFORUM copied it for you.\n'
          '3. Attach the media if needed, then post.',
      mediaNote: variant.hasMedia ? 'Most Nostr apps upload the shared photos to their own media server.' : null,
    );
  }

  // --- connect ---------------------------------------------------------------

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier == PlatformTier.handoff) {
      final label = (input['label'] ?? '').trim();
      return ConnectResult(
        account: ConnectedAccount(
          id: 'nostr-handoff-${ctx.now().microsecondsSinceEpoch}',
          platformId: descriptor.id,
          tier: PlatformTier.handoff,
          displayName: label.isEmpty ? 'Nostr (hand-off)' : label,
          createdAt: ctx.now(),
        ),
      );
    }
    final NostrKeys keys;
    try {
      keys = NostrKeys.parse(input[secretPrivateKey] ?? '');
    } on FormatException catch (e) {
      throw ConnectException(e.message, field: secretPrivateKey);
    }
    final relays = parseRelays(input[configRelays]);
    final nip96 = _normaliseServer(input[configNip96]);
    final npub = keys.npub;
    final short = '${npub.substring(0, 12)}…${npub.substring(npub.length - 6)}';
    ctx.log.info('Connected Nostr key $short with ${relays.length} relays');
    return ConnectResult(
      account: ConnectedAccount(
        id: 'nostr-${keys.publicKeyHex}',
        platformId: descriptor.id,
        tier: PlatformTier.openApi,
        displayName: 'Nostr ($short)',
        handle: short,
        profileUrl: 'https://njump.me/$npub',
        createdAt: ctx.now(),
        config: {
          configPubkey: keys.publicKeyHex,
          configNpub: npub,
          configRelays: relays,
          configNip96: nip96,
        },
      ),
      secrets: {secretPrivateKey: keys.privateKeyHex},
    );
  }

  /// Parses the relay text field (one per line, commas/spaces also accepted).
  /// Empty input yields [nostrDefaultRelays]. Throws [ConnectException] on a
  /// URL that is not `wss://` or `ws://`.
  static List<String> parseRelays(String? raw) {
    final items = (raw ?? '').split(RegExp(r'[\s,]+')).map((s) => s.trim()).where((s) => s.isNotEmpty);
    final out = <String>[];
    for (final item in items) {
      final uri = Uri.tryParse(item);
      if (uri == null || (uri.scheme != 'wss' && uri.scheme != 'ws') || uri.host.isEmpty) {
        throw ConnectException('"$item" is not a relay address. Relay addresses start with wss://', field: configRelays);
      }
      var s = uri.toString();
      if (s.endsWith('/') && uri.path == '/') s = s.substring(0, s.length - 1);
      if (!out.contains(s)) out.add(s);
    }
    return out.isEmpty ? List.of(nostrDefaultRelays) : out;
  }

  static String _normaliseServer(String? raw) {
    if (raw == null) return nostrDefaultNip96Server;
    final s = raw.trim();
    if (s.isEmpty) return '';
    final uri = Uri.tryParse(s.contains('://') ? s : 'https://$s');
    if (uri == null || uri.host.isEmpty || (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw ConnectException('"$s" is not a valid media server address.', field: configNip96);
    }
    final out = uri.toString();
    return out.endsWith('/') ? out.substring(0, out.length - 1) : out;
  }

  static List<String> _relaysOf(ConnectedAccount account) {
    final v = account.config[configRelays];
    if (v is List) return [for (final r in v) if (r is String && r.trim().isNotEmpty) r.trim()];
    if (v is String) return v.split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty).toList();
    return const [];
  }

  static String _nip96Of(ConnectedAccount account) {
    final v = account.config[configNip96];
    return v is String ? v.trim() : nostrDefaultNip96Server;
  }

  // --- validate --------------------------------------------------------------

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final nip96 = _nip96Of(account);
    final customHost = nip96 != nostrDefaultNip96Server;
    final issues = <ValidationIssue>[
      for (final i in super.validate(variant, account))
        // The size limits in the descriptor are nostr.build's free plan.
        if (customHost && (i.code == 'media.image_too_large' || i.code == 'media.video_too_large'))
          ValidationIssue.warning(i.code, '${i.message} (nostr.build free plan; your server may allow more)', field: i.field)
        else
          i,
    ];
    if (_relaysOf(account).isEmpty) {
      issues.add(const ValidationIssue.error('nostr.no_relays', 'This Nostr account has no relays configured', field: 'account'));
    }
    if (variant.visibility != Visibility.public) {
      issues.add(const ValidationIssue.warning(
          'nostr.public_only', 'Nostr notes are always public; the visibility setting is ignored',
          field: 'visibility'));
    }
    if (variant.hasMedia && nip96.isEmpty) {
      issues.add(const ValidationIssue.warning(
          'nostr.media_host',
          'No NIP-96 media server is set for this account, so media needs a public media host in NEFORUM settings',
          field: 'media'));
    }
    final parts = variant.isThread ? variant.threadParts : [variant.text];
    if (parts.any((p) => utf8.encode(p).length > _largeEventBytes - 4096)) {
      issues.add(const ValidationIssue.warning(
          'nostr.event_large', 'This note is very long; some relays reject events larger than 64 KB',
          field: 'text'));
    }
    return issues;
  }

  // --- publish ---------------------------------------------------------------

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier == PlatformTier.handoff) {
      return PublishResult.failure(const PublishError.unsupported('This Nostr account uses hand-off: your Nostr app signs the note'));
    }
    final sessions = <RelaySession>[];
    try {
      final keys = _keysFrom(account, secrets);
      final relays = _relaysOf(account);
      if (relays.isEmpty) {
        throw const AdapterException(
            PublishError.configuration('No relays configured for this Nostr account. Add at least one wss:// relay.'));
      }
      int nowSecs() => ctx.now().toUtc().millisecondsSinceEpoch ~/ 1000;

      final uploaded = await NostrMediaUploader(
        ctx: ctx,
        keys: keys,
        nip96Server: _nip96Of(account),
        createdAt: nowSecs,
        pollInterval: mediaPollInterval,
      ).uploadAll(variant.media);

      ctx.progress('Connecting to ${relays.length} relay${relays.length == 1 ? '' : 's'}');
      final opened = await Future.wait(relays.map((r) => RelaySession.open(
            r,
            _connector,
            timeout: connectTimeout,
            log: ctx.log,
            signAuth: (relay, challenge) => keys.sign(
              kind: NostrKind.clientAuth,
              content: '',
              createdAt: nowSecs(),
              random: _random,
              tags: [
                ['relay', relay],
                ['challenge', challenge],
              ],
            ),
          )));
      final openFailures = <RelayAck>[];
      for (final o in opened) {
        if (o.session != null) sessions.add(o.session!);
        if (o.failure != null) {
          openFailures.add(o.failure!);
          ctx.log.warn('Nostr relay ${o.failure}');
        }
      }
      if (sessions.isEmpty) throw AdapterException(classifyRelayFailures(openFailures));

      final parts = variant.isThread ? variant.threadParts : [variant.text];
      final baseTime = nowSecs();
      final ids = <String>[];
      var rootHint = '';
      for (var i = 0; i < parts.length; i++) {
        final media = i == 0 ? uploaded : const <NostrUploadedMedia>[];
        final event = keys.sign(
          kind: NostrKind.textNote,
          // +i keeps the parts in order for clients that sort by created_at.
          createdAt: baseTime + i,
          content: _contentFor(parts[i], media),
          tags: buildTags(
            text: parts[i],
            variant: variant,
            media: media,
            pubkey: keys.publicKeyHex,
            rootId: ids.isEmpty ? null : ids.first,
            parentId: ids.isEmpty ? null : ids.last,
            relayHint: rootHint,
            first: i == 0,
          ),
          random: _random,
        );
        final live = sessions.where((s) => !s.isClosed).toList();
        ctx.progress(parts.length > 1
            ? 'Sending part ${i + 1} of ${parts.length} to ${live.length} relays'
            : 'Sending note to ${live.length} relay${live.length == 1 ? '' : 's'}');
        final acks = await Future.wait(live.map((s) => s.publish(event, relayTimeout)));
        final accepted = acks.where((a) => a.accepted).toList();
        for (final a in acks.where((a) => !a.accepted)) {
          ctx.log.warn('Nostr relay $a');
        }
        if (accepted.isEmpty) {
          final err = classifyRelayFailures([...acks, ...openFailures]);
          if (i == 0) throw AdapterException(err);
          throw AdapterException(PublishError(
            kind: err.kind,
            message: 'Part ${i + 1} of ${parts.length} was not accepted by any relay (${err.message}). '
                'The first $i part${i == 1 ? ' is' : 's are'} already live at https://njump.me/${Nip19.encode('note', ids.first)}',
            statusCode: err.statusCode,
            raw: err.raw,
          ));
        }
        if (i == 0) rootHint = accepted.first.relay;
        ids.add(event.id);
        ctx.log.info('Nostr note ${event.noteId} accepted by ${accepted.length}/${relays.length} relays '
            '(${accepted.map((a) => a.relay).join(', ')})');
      }
      return PublishResult.ok(
        remoteId: ids.first,
        remoteUrl: 'https://njump.me/${Nip19.encode('note', ids.first)}',
        threadRemoteIds: parts.length > 1 ? ids : const [],
        publishedAt: ctx.now(),
      );
    } on AdapterException catch (e) {
      return PublishResult.failure(e.error);
    } finally {
      await Future.wait(sessions.map(_closeQuietly));
    }
  }

  static Future<void> _closeQuietly(RelaySession s) async {
    try {
      await s.close();
    } on Object {
      // Best effort.
    }
  }

  NostrKeys _keysFrom(ConnectedAccount account, Map<String, String> secrets) {
    final raw = secrets[secretPrivateKey];
    if (raw == null || raw.isEmpty) {
      throw const AdapterException(PublishError.auth('The Nostr private key is missing. Reconnect this account.'));
    }
    final NostrKeys keys;
    try {
      keys = NostrKeys.parse(raw);
    } on FormatException catch (e) {
      throw AdapterException(PublishError.auth('The stored Nostr key is unusable (${e.message}). Reconnect this account.'));
    }
    final expected = account.config[configPubkey];
    if (expected is String && expected.isNotEmpty && expected != keys.publicKeyHex) {
      throw const AdapterException(
          PublishError.auth('The stored Nostr key does not match this account\'s public key. Reconnect this account.'));
    }
    return keys;
  }

  static String _contentFor(String text, List<NostrUploadedMedia> media) {
    if (media.isEmpty) return text;
    final urls = media.map((m) => m.url).join('\n');
    return text.trim().isEmpty ? urls : '$text\n\n$urls';
  }

  static final RegExp _hashtag = RegExp(r'(?<![\p{L}\p{N}_&/#])#([\p{L}\p{N}_]+)', unicode: true);

  /// Tags for one note: NIP-10 thread markers, `p`, `t` hashtags, `r` links,
  /// NIP-92 `imeta`, NIP-36 `content-warning`.
  static List<List<String>> buildTags({
    required String text,
    required PostVariant variant,
    required String pubkey,
    List<NostrUploadedMedia> media = const [],
    String? rootId,
    String? parentId,
    String relayHint = '',
    bool first = true,
  }) {
    final tags = <List<String>>[];
    if (rootId != null) {
      tags.add(['e', rootId, relayHint, 'root', pubkey]);
      if (parentId != null && parentId != rootId) tags.add(['e', parentId, relayHint, 'reply', pubkey]);
      tags.add(['p', pubkey]);
    }
    final hashtags = <String>{
      for (final m in _hashtag.allMatches(text))
        if (!RegExp(r'^\d+$').hasMatch(m[1]!)) m[1]!.toLowerCase(),
      if (first)
        for (final t in variant.tags)
          if (t.trim().isNotEmpty) t.trim().replaceFirst(RegExp('^#'), '').toLowerCase(),
    };
    for (final h in hashtags) {
      tags.add(['t', h]);
    }
    final links = <String>{
      for (final u in UrlDetector.find(text))
        if (u.hasScheme) u.text,
      if (first && (variant.link ?? '').trim().isNotEmpty) variant.link!.trim(),
    };
    for (final l in links) {
      tags.add(['r', l]);
    }
    for (final m in media) {
      tags.add(m.imeta);
    }
    final cw = (variant.contentWarning ?? '').trim();
    if (cw.isNotEmpty) {
      tags.add(['content-warning', cw]);
    } else if (variant.sensitive) {
      tags.add(['content-warning']);
    }
    return tags;
  }
}

/// Turns the per-relay verdicts into one [PublishError] when no relay
/// accepted the note.
PublishError classifyRelayFailures(List<RelayAck> acks) {
  final summary = acks.map((a) => a.toString()).join('; ');
  bool any(String prefix) => acks.any((a) => a.prefix == prefix);
  if (acks.isNotEmpty && acks.every((a) => a.status != RelayAckStatus.rejected)) {
    return PublishError.network('Could not reach any Nostr relay.', raw: summary);
  }
  if (any('rate-limited')) {
    return PublishError.quota('Relays are rate limiting your key; try again in a few minutes.', raw: summary);
  }
  if (any('invalid')) {
    return PublishError.validation('Relays rejected the note as invalid.', raw: summary);
  }
  if (any('blocked') || any('restricted') || any('auth-required') || any('mute')) {
    return PublishError.configuration(
        'Your relays do not accept notes from this key (they may be paid, invite-only or need sign-in). '
        'Add free public relays to the account.');
  }
  if (any('pow')) {
    return PublishError.platform('Your relays require proof-of-work, which NEFORUM does not do yet.', raw: summary);
  }
  return PublishError.platform('No relay accepted the note.', raw: summary);
}

const _handoffSpec = ConnectSpec(
  tier: PlatformTier.handoff,
  intro: '''
**Keep your private key in your own Nostr app.** NEFORUM prepares the note, copies the text and hands it to
your Nostr app (Amethyst, Damus, Primal, ...) through the share sheet, or opens a web client on desktop.
Your app signs and publishes it. Nothing to paste here except an optional name for this account.''',
  fields: [
    ConnectField(key: 'label', label: 'Name (optional)', required: false, placeholder: 'My Nostr'),
  ],
);

const _spec = ConnectSpec(
  tier: PlatformTier.openApi,
  usesBrowser: false,
  loopbackRedirectOk: false,
  customSchemeRedirectOk: false,
  intro: '''
**Nostr needs no sign-up, no developer app and no API key.** Your identity is a key pair.

1. Open your Nostr app (Damus, Amethyst, Primal, ...) and find the setting that shows your **private key**. It starts with `nsec1`. If you do not have one yet, any Nostr app can create it for you.
2. Paste it below. NEFORUM keeps it in your device's secure storage and only uses it to sign your notes. Anyone with this key can post as you, so never share it.
3. Optionally list the relays you write to (one per line). Leave the defaults if unsure.

Media is uploaded to a media server (free nostr.build by default, 20 MB per file), or to your own media host if you set one up in NEFORUM settings.''',
  fields: [
    ConnectField(
      key: NostrAdapter.secretPrivateKey,
      label: 'Private key (nsec)',
      kind: FieldKind.password,
      secret: true,
      placeholder: 'nsec1...',
      help: 'Starts with nsec1 (or 64 hex characters). Your public key (npub) will not work: it cannot sign.',
    ),
    ConnectField(
      key: NostrAdapter.configRelays,
      label: 'Relays',
      kind: FieldKind.multiline,
      required: false,
      defaultValue: 'wss://relay.damus.io\nwss://nos.lol\nwss://relay.primal.net\nwss://relay.nostr.band',
      help: 'One wss:// address per line. A note counts as published when at least one relay accepts it.',
    ),
    ConnectField(
      key: NostrAdapter.configNip96,
      label: 'Media server (NIP-96)',
      kind: FieldKind.url,
      required: false,
      defaultValue: nostrDefaultNip96Server,
      help: 'Where images and videos are uploaded. Leave empty to use only the media host from NEFORUM settings.',
    ),
  ],
);

/// Static description of Nostr.
const PlatformDescriptor nostrDescriptor = PlatformDescriptor(
  id: 'nostr',
  name: 'Nostr',
  iconKey: 'nostr',
  homepage: 'https://nostr.com',
  tiers: {PlatformTier.openApi, PlatformTier.handoff},
  defaultTier: PlatformTier.openApi,
  text: TextRules(
    maxLength: null,
    counting: CountingRule.utf8Bytes,
    supportsThreads: true,
    supportsContentWarning: true,
    supportsMarkdown: false,
    supportsHashtags: true,
    hashtagsAsField: false,
    linkInText: true,
    notes: 'No protocol limit. Relays cap the whole event, typically at 64 KB (strfry) or 128 KB '
        '(nostr-rs-relay). Plain text only; hashtags are also added as "t" tags.',
  ),
  media: MediaRules(
    maxImages: 20,
    maxVideos: 20,
    allowsMixedImageVideo: true,
    imageMaxBytes: 20971520,
    videoMaxBytes: 20971520,
    imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/avif'},
    videoMimeTypes: {'video/mp4', 'video/quicktime', 'video/webm'},
    supportsAltText: true,
    requiresPublicMediaUrl: false,
    notes: 'Media is uploaded to a server and linked by URL (with NIP-92 imeta). The protocol has no count '
        'limit; NEFORUM caps at 20. Size limit is the free nostr.build plan (20 MB per file).',
  ),
  defaultQuotas: [],
  personalAccountOk: true,
  accountRequirements: 'Just a Nostr key pair (your nsec private key). No email, phone number, sign-up or '
      'app review is needed, and any Nostr app can create a key for you.',
  apiCostSummary: 'Free with no quota. Individual relays may rate-limit or charge; free media uploads to '
      'nostr.build are limited to 20 MB per file.',
  setupGuide: 'docs/platforms/nostr.md',
  serverSideScheduling: false,
  supportsLinkField: false,
);
