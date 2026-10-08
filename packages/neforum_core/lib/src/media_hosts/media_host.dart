import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../model/media.dart';

/// A file NEFORUM has placed at a public URL so that URL-only APIs (Instagram,
/// Threads, TikTok PULL_FROM_URL) can fetch it.
@immutable
class HostedMedia {
  const HostedMedia({required this.hostId, required this.url, this.deleteHandle, this.expiresAt});

  final String hostId;
  final Uri url;

  /// Whatever the host needs to delete the file later (object key, delete
  /// token). `null` when the host cannot delete.
  final String? deleteHandle;
  final DateTime? expiresAt;
}

/// Declarative form for configuring a host (same idea as `ConnectSpec`).
@immutable
class MediaHostField {
  const MediaHostField({
    required this.key,
    required this.label,
    this.secret = false,
    this.required = true,
    this.help,
    this.placeholder,
  });

  final String key;
  final String label;
  final bool secret;
  final bool required;
  final String? help;
  final String? placeholder;
}

/// A pluggable "put this file somewhere public for a while" backend.
///
/// Implementations: S3-compatible (AWS/R2/B2/MinIO) via SigV4, WebDAV/
/// Nextcloud public links, catbox/litterbox, a user-run relay, ...
abstract class MediaHost {
  String get id;
  String get name;
  String get description;
  List<MediaHostField> get fields;

  /// Largest file this host accepts, or `null` if unknown/unbounded.
  int? get maxBytes;

  Future<HostedMedia> upload(
    MediaAttachment media,
    Uint8List bytes, {
    Duration? ttl,
  });

  Future<void> delete(HostedMedia hosted);

  /// Cheap connectivity/credential check used by the settings screen.
  Future<void> verify();
}

class MediaHostException implements Exception {
  const MediaHostException(this.message, {this.hostId});
  final String message;
  final String? hostId;
  @override
  String toString() => 'MediaHostException(${hostId ?? ''}: $message)';
}
