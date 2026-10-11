import 'dart:convert';
import 'dart:math';

import 'package:bech32/bech32.dart';
import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

/// Order of the secp256k1 group. A private key must be in `1 .. n-1`.
final BigInt _secp256k1N = BigInt.parse(
  'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141',
  radix: 16,
);

final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

/// Event kinds used by the adapter.
abstract final class NostrKind {
  /// NIP-01 short text note.
  static const int textNote = 1;

  /// NIP-42 client authentication.
  static const int clientAuth = 22242;

  /// NIP-98 HTTP auth.
  static const int httpAuth = 27235;
}

/// A signed Nostr event (NIP-01).
@immutable
class NostrEvent {
  const NostrEvent({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    required this.sig,
  });

  /// 64-hex sha256 of the NIP-01 serialisation.
  final String id;

  /// 64-hex x-only public key.
  final String pubkey;

  /// Unix seconds.
  final int createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;

  /// 128-hex BIP-340 Schnorr signature over [id].
  final String sig;

  /// Wire representation. Valid JSON (control characters escaped), which is
  /// fine: relays recompute the id from the parsed values.
  Map<String, Object> toJson() => {
        'id': id,
        'pubkey': pubkey,
        'created_at': createdAt,
        'kind': kind,
        'tags': tags,
        'content': content,
        'sig': sig,
      };

  /// NIP-19 `note1...` encoding of [id].
  String get noteId => Nip19.encode('note', id);
}

/// Builds the canonical NIP-01 serialisation
/// `[0,<pubkey>,<created_at>,<kind>,<tags>,<content>]`: no whitespace, and in
/// strings only `\n \" \\ \r \t \b \f` are escaped; every other character is
/// written verbatim (no `\uXXXX`, no escaped `/`).
String nip01Serialize({
  required String pubkey,
  required int createdAt,
  required int kind,
  required List<List<String>> tags,
  required String content,
}) {
  final b = StringBuffer('[0,')
    ..write(_nip01String(pubkey))
    ..write(',')
    ..write(createdAt)
    ..write(',')
    ..write(kind)
    ..write(',[');
  for (var i = 0; i < tags.length; i++) {
    if (i > 0) b.write(',');
    b
      ..write('[')
      ..write(tags[i].map(_nip01String).join(','))
      ..write(']');
  }
  b
    ..write('],')
    ..write(_nip01String(content))
    ..write(']');
  return b.toString();
}

String _nip01String(String s) {
  final b = StringBuffer('"');
  for (final unit in s.codeUnits) {
    switch (unit) {
      case 0x0A:
        b.write(r'\n');
      case 0x22:
        b.write(r'\"');
      case 0x5C:
        b.write(r'\\');
      case 0x0D:
        b.write(r'\r');
      case 0x09:
        b.write(r'\t');
      case 0x08:
        b.write(r'\b');
      case 0x0C:
        b.write(r'\f');
      default:
        b.writeCharCode(unit);
    }
  }
  b.write('"');
  return b.toString();
}

/// sha256 of the NIP-01 serialisation, lowercase hex.
String nostrEventId({
  required String pubkey,
  required int createdAt,
  required int kind,
  required List<List<String>> tags,
  required String content,
}) {
  final serialized = nip01Serialize(pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content);
  return sha256.convert(utf8.encode(serialized)).toString();
}

/// A local private key plus its derived public key.
@immutable
class NostrKeys {
  const NostrKeys._(this.privateKeyHex, this.publicKeyHex);

  /// Parses `nsec1...` or 64-hex. Throws [FormatException] with a
  /// user-readable message.
  factory NostrKeys.parse(String input) {
    final s = input.trim();
    if (s.isEmpty) throw const FormatException('Paste your private key (nsec1... or 64 hex characters).');
    final lower = s.toLowerCase();
    if (lower.startsWith('npub1')) {
      throw const FormatException(
          'That is your public key (npub). NEFORUM needs the private key, which starts with "nsec1".');
    }
    if (lower.startsWith('bunker://') || lower.startsWith('nostrconnect://')) {
      throw const FormatException(
          'Remote signers (NIP-46 bunker links) are not supported yet. Paste an nsec private key instead.');
    }
    String hex;
    if (lower.startsWith('nsec1')) {
      final decoded = Nip19.decode(s);
      if (decoded.hrp != 'nsec') throw const FormatException('Not an nsec key.');
      hex = decoded.hex;
    } else if (_hex64.hasMatch(s)) {
      hex = lower;
    } else {
      throw const FormatException('The private key must start with "nsec1" or be exactly 64 hex characters.');
    }
    final d = BigInt.parse(hex, radix: 16);
    if (d < BigInt.one || d >= _secp256k1N) {
      throw const FormatException('This is not a valid secp256k1 private key.');
    }
    return NostrKeys._(hex, bip340.getPublicKey(hex).toLowerCase());
  }

  final String privateKeyHex;
  final String publicKeyHex;

  String get npub => Nip19.encode('npub', publicKeyHex);
  String get nsec => Nip19.encode('nsec', privateKeyHex);

  /// Builds, hashes and signs an event. [random] supplies the 32 bytes of
  /// BIP-340 auxiliary randomness.
  NostrEvent sign({
    required int kind,
    required String content,
    required int createdAt,
    List<List<String>> tags = const [],
    Random? random,
  }) {
    final id = nostrEventId(
        pubkey: publicKeyHex, createdAt: createdAt, kind: kind, tags: tags, content: content);
    final rng = random ?? Random.secure();
    final aux = List<int>.generate(32, (_) => rng.nextInt(256));
    final sig = bip340.sign(privateKeyHex, id, hexEncode(aux));
    return NostrEvent(
      id: id,
      pubkey: publicKeyHex,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
      sig: sig,
    );
  }
}

/// Result of [Nip19.decode].
typedef Nip19Decoded = ({String hrp, String hex});

/// NIP-19 bare bech32 entities (`npub`, `nsec`, `note`): exactly 32 bytes.
abstract final class Nip19 {
  static String encode(String hrp, String hex) {
    final bytes = hexDecode(hex);
    if (bytes.length != 32) throw FormatException('NIP-19 $hrp must encode 32 bytes');
    return bech32.encode(Bech32(hrp, convertBits(bytes, 8, 5, pad: true)));
  }

  static Nip19Decoded decode(String value) {
    final Bech32 b;
    try {
      b = bech32.decode(value.trim());
    } on Exception catch (e) {
      throw FormatException('Not a valid bech32 key ($e).');
    }
    final bytes = convertBits(b.data, 5, 8, pad: false);
    if (bytes.length != 32) throw const FormatException('A bech32 key must encode exactly 32 bytes.');
    return (hrp: b.hrp, hex: hexEncode(bytes));
  }
}

/// General power-of-two base conversion (BIP-173 `convertbits`).
List<int> convertBits(List<int> data, int from, int to, {required bool pad}) {
  var acc = 0;
  var bits = 0;
  final out = <int>[];
  final maxv = (1 << to) - 1;
  final maxAcc = (1 << (from + to - 1)) - 1;
  for (final value in data) {
    if (value < 0 || (value >> from) != 0) throw const FormatException('Invalid data for bit conversion');
    acc = ((acc << from) | value) & maxAcc;
    bits += from;
    while (bits >= to) {
      bits -= to;
      out.add((acc >> bits) & maxv);
    }
  }
  if (pad) {
    if (bits > 0) out.add((acc << (to - bits)) & maxv);
  } else if (bits >= from || ((acc << (to - bits)) & maxv) != 0) {
    throw const FormatException('Invalid padding in bech32 data');
  }
  return out;
}

String hexEncode(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

List<int> hexDecode(String hex) {
  if (hex.length.isOdd) throw const FormatException('Odd-length hex');
  return List<int>.generate(hex.length ~/ 2, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16));
}
