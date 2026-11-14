import 'dart:async';

import 'package:bip340/bip340.dart' as bip340;

import '../../util/logger.dart';
import 'nostr_broadcast.dart';
import 'nostr_event.dart';
import 'nostr_relay.dart';

/// Relays that collect everyone's relay lists (NIP-65), asked besides the
/// user's own relays.
const List<String> nostrRelayListIndexers = ['wss://purplepag.es'];

/// The write relays in a NIP-65 relay list event: `r` tags with no marker or
/// the `write` marker, as normalised `wss://` / `ws://` addresses, in order.
List<String> writeRelaysOf(NostrEvent relayList) {
  final out = <String>[];
  for (final t in relayList.tags) {
    if (t.length < 2 || t[0] != 'r') continue;
    if (t.length > 2 && t[2] != 'write') continue;
    final relay = normaliseRelayUrl(t[1]);
    if (relay != null && !out.contains(relay)) out.add(relay);
  }
  return out;
}

/// `wss://host[/path]` without a trailing `/` on an empty path, or null when
/// [raw] is not a relay address.
String? normaliseRelayUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || (uri.scheme != 'wss' && uri.scheme != 'ws') || uri.host.isEmpty) return null;
  var s = uri.toString();
  if (s.endsWith('/') && uri.path == '/') s = s.substring(0, s.length - 1);
  return s;
}

/// Reads the user's relay list (NIP-65, kind 10002) from [from] and returns
/// its write relays. The newest correctly signed list wins. Empty when no
/// relay has one or none answers within [timeout]; never throws.
Future<List<String>> fetchWriteRelays({
  required String pubkey,
  required List<String> from,
  required RelayConnector connector,
  required AuthEventSigner signAuth,
  required Logger log,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final lists = <NostrEvent>[];
  final sessions = <RelaySession>[];
  var over = false;

  Future<void> ask(String relay) async {
    final o = await RelaySession.open(relay, connector, timeout: timeout, signAuth: signAuth, log: log);
    final s = o.session;
    if (s == null) return;
    if (over) {
      await RelayPool.closeQuietly(s);
      return;
    }
    sessions.add(s);
    final r = await s.query({
      'kinds': [NostrKind.relayList],
      'authors': [pubkey],
      'limit': 1,
    }, timeout);
    lists.addAll(r.events);
  }

  final deadline = Completer<void>();
  final timer = Timer(timeout, () {
    if (!deadline.isCompleted) deadline.complete();
  });
  try {
    await Future.any([Future.wait(from.map(ask)), deadline.future]);
  } on Object catch (e) {
    log.debug('Relay list lookup failed: $e');
  } finally {
    over = true;
    timer.cancel();
    await Future.wait(sessions.map(RelayPool.closeQuietly));
  }

  NostrEvent? newest;
  for (final e in lists) {
    if (e.kind != NostrKind.relayList || e.pubkey != pubkey.toLowerCase()) continue;
    if (newest != null && e.createdAt <= newest.createdAt) continue;
    bool valid;
    try {
      valid = bip340.verify(e.pubkey, e.id, e.sig);
    } on Object {
      valid = false;
    }
    if (valid) newest = e;
  }
  return newest == null ? const [] : writeRelaysOf(newest);
}
