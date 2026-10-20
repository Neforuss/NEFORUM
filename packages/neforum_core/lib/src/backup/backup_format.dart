import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// NEFORUM's encrypted backup file (`.neforumbackup`), version 1: one file
/// that moves accounts, keys and settings between devices by hand, with no
/// cloud and no server.
///
/// All binary, little-endian:
///
/// | Offset | Size | Field |
/// |---|---|---|
/// | 0 | 8 | Magic `NEFORUMB` |
/// | 8 | 1 | Format version (1) |
/// | 9 | 1 | KDF id (1 = Argon2id) |
/// | 10 | 4 | Argon2id memory, KiB |
/// | 14 | 1 | Argon2id iterations |
/// | 15 | 1 | Argon2id parallelism |
/// | 16 | 16 | Salt |
/// | 32 | 1 | AEAD id (1 = AES-256-GCM) |
/// | 33 | 12 | Nonce |
/// | 45 | n | Ciphertext + 16-byte GCM tag |
///
/// The whole 45-byte header is the GCM associated data, so changing any of
/// it (lowering the key-stretching cost, for one) makes decryption fail. The
/// plaintext is gzip-compressed UTF-8 JSON. Nothing is ever written to disk
/// unencrypted: everything happens in memory.
abstract final class BackupFormat {
  static const List<int> magic = [0x4E, 0x45, 0x46, 0x4F, 0x52, 0x55, 0x4D, 0x42]; // NEFORUMB
  static const int version = 1;
  static const int kdfArgon2id = 1;
  static const int aeadAesGcm = 1;
  static const int headerLength = 45;
  static const int tagLength = 16;

  /// Files larger than this are refused before any key stretching.
  static const int maxFileBytes = 200 * 1024 * 1024;

  /// File name extension, without the dot.
  static const String extension = 'neforumbackup';
}

/// Argon2id cost stored in the header.
@immutable
class BackupKdfParams {
  const BackupKdfParams({required this.memoryKiB, required this.iterations, this.parallelism = 1});

  /// OWASP's recommended Argon2id setting (19 MiB, 2 passes, 1 lane): a few
  /// seconds at most on a phone, while making every passphrase guess cost the
  /// same.
  static const BackupKdfParams standard = BackupKdfParams(memoryKiB: 19 * 1024, iterations: 2);

  /// The cheapest a file may claim; anything below is refused as tampered.
  static const BackupKdfParams minimum = BackupKdfParams(memoryKiB: 19 * 1024, iterations: 2);

  /// For tests only: fast, never accepted from a real file by default.
  @visibleForTesting
  static const BackupKdfParams testing = BackupKdfParams(memoryKiB: 64, iterations: 1);

  final int memoryKiB;
  final int iterations;
  final int parallelism;
}

/// Why a backup could not be read.
enum BackupErrorKind { notABackup, tooNew, wrongPassphraseOrDamaged, tooLarge, invalidContent }

class BackupException implements Exception {
  const BackupException(this.kind, this.message);
  final BackupErrorKind kind;
  final String message;
  @override
  String toString() => 'BackupException(${kind.name}): $message';
}

/// The bytes of an encrypted backup holding [payload] (JSON-encodable),
/// locked with [passphrase].
Future<Uint8List> encryptBackup(Map<String, dynamic> payload, String passphrase,
    {BackupKdfParams params = BackupKdfParams.standard, Random? random}) async {
  final rng = random ?? Random.secure();
  final salt = Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256)));
  final nonce = Uint8List.fromList(List.generate(12, (_) => rng.nextInt(256)));
  final header = _header(params, salt, nonce);
  final plain = GZipEncoder().encodeBytes(utf8.encode(jsonEncode(payload)));
  final key = await _deriveKey(passphrase, salt, params);
  final box = await AesGcm.with256bits().encrypt(plain, secretKey: key, nonce: nonce, aad: header);
  return Uint8List.fromList([...header, ...box.cipherText, ...box.mac.bytes]);
}

/// The payload inside an encrypted backup. Throws [BackupException] with a
/// message fit to show: not a NEFORUM backup, made by a newer NEFORUM, wrong
/// passphrase or damaged file (GCM cannot tell which), or too large.
///
/// [minimum] is the cheapest key stretching accepted; tests pass
/// [BackupKdfParams.testing].
Future<Map<String, dynamic>> decryptBackup(Uint8List bytes, String passphrase, {BackupKdfParams minimum = BackupKdfParams.minimum}) async {
  if (bytes.length > BackupFormat.maxFileBytes) {
    throw const BackupException(BackupErrorKind.tooLarge, 'This file is too large to be a NEFORUM backup.');
  }
  if (bytes.length < BackupFormat.magic.length || !_startsWithMagic(bytes)) {
    throw const BackupException(BackupErrorKind.notABackup, 'This is not a NEFORUM backup file.');
  }
  if (bytes.length < BackupFormat.headerLength + BackupFormat.tagLength) {
    throw const BackupException(BackupErrorKind.wrongPassphraseOrDamaged, 'Wrong passphrase or damaged file.');
  }
  final d = ByteData.sublistView(bytes);
  if (bytes[8] > BackupFormat.version) {
    throw const BackupException(BackupErrorKind.tooNew, 'This backup was made by a newer NEFORUM. Update NEFORUM here first.');
  }
  if (bytes[8] != BackupFormat.version || bytes[9] != BackupFormat.kdfArgon2id || bytes[32] != BackupFormat.aeadAesGcm) {
    throw const BackupException(BackupErrorKind.wrongPassphraseOrDamaged, 'Wrong passphrase or damaged file.');
  }
  final params = BackupKdfParams(memoryKiB: d.getUint32(10, Endian.little), iterations: bytes[14], parallelism: bytes[15]);
  // A header claiming less work than any NEFORUM writes has been tampered
  // with; one claiming absurd work would stall the device.
  if (params.memoryKiB < minimum.memoryKiB ||
      params.iterations < minimum.iterations ||
      params.parallelism < 1 ||
      params.memoryKiB > 1024 * 1024 ||
      params.iterations > 20 ||
      params.parallelism > 8) {
    throw const BackupException(BackupErrorKind.wrongPassphraseOrDamaged, 'Wrong passphrase or damaged file.');
  }
  final header = Uint8List.sublistView(bytes, 0, BackupFormat.headerLength);
  final salt = Uint8List.sublistView(bytes, 16, 32);
  final nonce = Uint8List.sublistView(bytes, 33, 45);
  final cipherText = Uint8List.sublistView(bytes, BackupFormat.headerLength, bytes.length - BackupFormat.tagLength);
  final mac = Mac(Uint8List.sublistView(bytes, bytes.length - BackupFormat.tagLength));
  final key = await _deriveKey(passphrase, salt, params);
  final List<int> plain;
  try {
    plain = await AesGcm.with256bits().decrypt(SecretBox(cipherText, nonce: nonce, mac: mac), secretKey: key, aad: header);
  } on SecretBoxAuthenticationError {
    throw const BackupException(BackupErrorKind.wrongPassphraseOrDamaged, 'Wrong passphrase or damaged file.');
  }
  try {
    final json = jsonDecode(utf8.decode(GZipDecoder().decodeBytes(plain)));
    if (json is! Map) throw const FormatException('not an object');
    return Map<String, dynamic>.from(json);
  } on Object {
    throw const BackupException(BackupErrorKind.invalidContent, 'The backup opened but its contents are not readable.');
  }
}

/// True when [bytes] start like a NEFORUM backup (for file pickers whose
/// extension filters are unreliable, Android's for one).
bool looksLikeBackup(Uint8List bytes) => bytes.length >= BackupFormat.magic.length && _startsWithMagic(bytes);

/// A random passphrase: 24 base32 characters (120 bits) in groups of four,
/// e.g. `K7QF-MZ3D-W9TB-XC4N-P2RV-H8LG`. No 0/1/I/O, so it reads back
/// unambiguously.
String generatePassphrase({Random? random}) {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // 32 symbols
  final rng = random ?? Random.secure();
  final chars = List.generate(24, (_) => alphabet[rng.nextInt(alphabet.length)]);
  return [for (var i = 0; i < 24; i += 4) chars.sublist(i, i + 4).join()].join('-');
}

/// How strong a passphrase is, for the export screen.
enum PassphraseStrength { tooShort, weak, ok }

/// At least 14 characters is OK; 10 to 13 is weak; shorter is refused.
PassphraseStrength passphraseStrength(String p) {
  final n = unorm.nfc(p).runes.length;
  if (n < 10) return PassphraseStrength.tooShort;
  if (n < 14) return PassphraseStrength.weak;
  return PassphraseStrength.ok;
}

Uint8List _header(BackupKdfParams p, Uint8List salt, Uint8List nonce) {
  final h = Uint8List(BackupFormat.headerLength);
  h.setAll(0, BackupFormat.magic);
  final d = ByteData.sublistView(h)
    ..setUint8(8, BackupFormat.version)
    ..setUint8(9, BackupFormat.kdfArgon2id)
    ..setUint32(10, p.memoryKiB, Endian.little)
    ..setUint8(14, p.iterations)
    ..setUint8(15, p.parallelism)
    ..setUint8(32, BackupFormat.aeadAesGcm);
  assert(d.lengthInBytes == BackupFormat.headerLength);
  h.setAll(16, salt);
  h.setAll(33, nonce);
  return h;
}

bool _startsWithMagic(Uint8List b) {
  for (var i = 0; i < BackupFormat.magic.length; i++) {
    if (b[i] != BackupFormat.magic[i]) return false;
  }
  return true;
}

/// Argon2id(passphrase as NFC UTF-8, salt, m, t, p) -> 32-byte key. A
/// passphrase typed on different keyboards ("é" as one or two code points)
/// gives the same key.
Future<SecretKey> _deriveKey(String passphrase, List<int> salt, BackupKdfParams p) => Argon2id(
      memory: p.memoryKiB,
      iterations: p.iterations,
      parallelism: p.parallelism,
      hashLength: 32,
    ).deriveKey(secretKey: SecretKey(utf8.encode(unorm.nfc(passphrase))), nonce: salt);
