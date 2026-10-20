import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import '../backup/backup_format.dart';

/// One synced thing: an account, an account's keys, a post, a setting.
/// Deleted ones stay as tombstones (with [deleted] set) for a while, so a
/// device that was offline learns about the deletion instead of bringing
/// the thing back.
@immutable
class SyncRecord {
  const SyncRecord({required this.value, required this.hash, required this.at, required this.by, this.deleted = false});

  factory SyncRecord.of(Object? value, {required DateTime at, required String by}) =>
      SyncRecord(value: value, hash: syncHash(value), at: at, by: by);

  factory SyncRecord.tombstone({required DateTime at, required String by}) =>
      SyncRecord(value: null, hash: '', at: at, by: by, deleted: true);

  static SyncRecord? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse('${raw['at'] ?? ''}');
    final by = raw['by'];
    if (at == null || by is! String) return null;
    if (raw['deleted'] == true) return SyncRecord.tombstone(at: at, by: by);
    if (!raw.containsKey('v')) return null;
    return SyncRecord.of(raw['v'], at: at, by: by);
  }

  /// The JSON value; `null` for a tombstone.
  final Object? value;

  /// [syncHash] of [value]; empty for a tombstone.
  final String hash;

  /// When this version was written (a post's own `updatedAt` when it has one).
  final DateTime at;

  /// The device that wrote it.
  final String by;
  final bool deleted;

  Map<String, dynamic> toJson() => deleted
      ? {'deleted': true, 'at': at.toUtc().toIso8601String(), 'by': by}
      : {'v': value, 'at': at.toUtc().toIso8601String(), 'by': by};
}

/// A device that uses the sync file.
@immutable
class SyncDeviceInfo {
  const SyncDeviceInfo({required this.label, required this.platform, required this.appVersion, required this.seenAt});

  static SyncDeviceInfo? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final seen = DateTime.tryParse('${raw['seenAt'] ?? ''}');
    if (seen == null) return null;
    return SyncDeviceInfo(label: '${raw['label'] ?? ''}', platform: '${raw['platform'] ?? ''}', appVersion: '${raw['appVersion'] ?? ''}', seenAt: seen);
  }

  final String label;
  final String platform;
  final String appVersion;

  /// The last time this device wrote the file (a heartbeat while it runs).
  final DateTime seenAt;

  SyncDeviceInfo seen(DateTime at) => SyncDeviceInfo(label: label, platform: platform, appVersion: appVersion, seenAt: at);

  Map<String, dynamic> toJson() => {'label': label, 'platform': platform, 'appVersion': appVersion, 'seenAt': seenAt.toUtc().toIso8601String()};
}

/// "Device [by] is renewing this account's sign-in until [until]": the one
/// renewer of an account whose network replaces the refresh token on every
/// renewal (X, Tumblr), so two devices never race and sign each other out.
@immutable
class SyncLease {
  const SyncLease({required this.by, required this.until});

  static SyncLease? tryParse(Object? raw) {
    if (raw is! Map || raw['by'] is! String) return null;
    final until = DateTime.tryParse('${raw['until'] ?? ''}');
    return until == null ? null : SyncLease(by: raw['by'] as String, until: until);
  }

  final String by;
  final DateTime until;

  bool liveAt(DateTime now) => until.isAfter(now);

  Map<String, dynamic> toJson() => {'by': by, 'until': until.toUtc().toIso8601String()};
}

/// "Device [by] publishes this scheduled post": the device it was scheduled
/// on, which has its photos and videos. Another device only takes over when
/// the owner has been silent and the post is well overdue.
@immutable
class SyncClaim {
  const SyncClaim({required this.by, required this.at, this.publishing = false});

  static SyncClaim? tryParse(Object? raw) {
    if (raw is! Map || raw['by'] is! String) return null;
    final at = DateTime.tryParse('${raw['at'] ?? ''}');
    return at == null ? null : SyncClaim(by: raw['by'] as String, at: at, publishing: raw['publishing'] == true);
  }

  final String by;
  final DateTime at;

  /// The owner started publishing it.
  final bool publishing;

  Map<String, dynamic> toJson() => {'by': by, 'at': at.toUtc().toIso8601String(), if (publishing) 'publishing': true};
}

/// The decrypted sync file.
class SyncDocument {
  SyncDocument({
    Map<String, SyncRecord>? records,
    Map<String, SyncDeviceInfo>? devices,
    Map<String, SyncLease>? leases,
    Map<String, SyncClaim>? claims,
  })  : records = records ?? {},
        devices = devices ?? {},
        leases = leases ?? {},
        claims = claims ?? {};

  /// Reads [j], untrusted: entries that do not parse are dropped.
  factory SyncDocument.parse(Map<String, dynamic> j) {
    if (j['app'] != 'NEFORUM' || j['kind'] != 'sync') {
      throw const BackupException(BackupErrorKind.invalidContent, 'This is not a NEFORUM sync file.');
    }
    final v = j['syncVersion'];
    if (v is! int) throw const BackupException(BackupErrorKind.invalidContent, 'The sync file has no version.');
    if (v > syncVersion) {
      throw const BackupException(BackupErrorKind.tooNew, 'The sync file was written by a newer NEFORUM. Update NEFORUM on this device.');
    }
    Map<String, T> read<T>(Object? raw, T? Function(Object?) parse) => {
          if (raw is Map)
            for (final e in raw.entries)
              if (e.key is String && parse(e.value) != null) e.key as String: parse(e.value) as T,
        };
    return SyncDocument(
      records: read(j['records'], SyncRecord.tryParse),
      devices: read(j['devices'], SyncDeviceInfo.tryParse),
      leases: read(j['leases'], SyncLease.tryParse),
      claims: read(j['claims'], SyncClaim.tryParse),
    );
  }

  static const int syncVersion = 1;

  final Map<String, SyncRecord> records;
  final Map<String, SyncDeviceInfo> devices;
  final Map<String, SyncLease> leases;
  final Map<String, SyncClaim> claims;

  SyncDocument copy() => SyncDocument(records: {...records}, devices: {...devices}, leases: {...leases}, claims: {...claims});

  Map<String, dynamic> toJson({required String writtenBy, required DateTime writtenAt}) => {
        'app': 'NEFORUM',
        'kind': 'sync',
        'syncVersion': syncVersion,
        'writtenBy': writtenBy,
        'writtenAt': writtenAt.toUtc().toIso8601String(),
        'devices': {for (final e in devices.entries) e.key: e.value.toJson()},
        'records': {for (final e in records.entries) e.key: e.value.toJson()},
        'leases': {for (final e in leases.entries) e.key: e.value.toJson()},
        'claims': {for (final e in claims.entries) e.key: e.value.toJson()},
      };

  /// Folds [other] (a cloud client's conflicting copy) into this document:
  /// per record the newer version wins, devices keep their latest heartbeat,
  /// live leases and claims are kept.
  void absorb(SyncDocument other) {
    for (final e in other.records.entries) {
      final mine = records[e.key];
      if (mine == null || e.value.at.isAfter(mine.at)) records[e.key] = e.value;
    }
    for (final e in other.devices.entries) {
      final mine = devices[e.key];
      if (mine == null || e.value.seenAt.isAfter(mine.seenAt)) devices[e.key] = e.value;
    }
    for (final e in other.leases.entries) {
      final mine = leases[e.key];
      if (mine == null || e.value.until.isAfter(mine.until)) leases[e.key] = e.value;
    }
    for (final e in other.claims.entries) {
      claims.putIfAbsent(e.key, () => e.value);
    }
  }
}

/// SHA-256 of [value] as canonical JSON (object keys sorted), so equal
/// values hash equally on every device.
String syncHash(Object? value) => sha256.convert(utf8.encode(_canonical(value))).toString();

String _canonical(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => '$k').toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_canonical(v[k])}').join(',')}}';
  }
  if (v is List) return '[${v.map(_canonical).join(',')}]';
  return jsonEncode(v);
}
