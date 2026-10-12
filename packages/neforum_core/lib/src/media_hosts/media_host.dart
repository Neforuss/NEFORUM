import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../model/media.dart';
import '../model/publish_result.dart';

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

  /// Cheap connectivity/credential check used by the settings screen. Show
  /// [verifySuccessMessage] when it returns, so the screen says what was
  /// actually tested.
  Future<void> verify();
}

/// Implemented by hosts whose [MediaHost.verify] tests something specific
/// (a real upload, or only that the service answers).
abstract interface class DescribesVerify {
  /// One sentence for the settings screen after [MediaHost.verify] returned.
  String get verifiedMessage;
}

/// What the settings screen shows when [MediaHost.verify] succeeded.
String verifySuccessMessage(MediaHost host) {
  final Object h = host;
  return h is DescribesVerify ? h.verifiedMessage : 'Connection works';
}

/// Waits before a retry. Injectable so tests do not sleep.
typedef MediaHostDelay = Future<void> Function(Duration duration);

/// The real [MediaHostDelay].
Future<void> mediaHostDefaultDelay(Duration d) => Future<void>.delayed(d);

class MediaHostException implements Exception {
  const MediaHostException(this.message, {this.hostId, this.temporary = false});
  final String message;
  final String? hostId;

  /// The host had an outage-type problem (HTTP 5xx, timeout, network error)
  /// that NEFORUM already retried once; trying again later may work. `false`
  /// for problems with the settings or the file.
  final bool temporary;

  /// This failure for a post's status: an outage can be retried later; any
  /// other problem needs the settings or the file fixed. [message] is
  /// already a full sentence that names the host.
  PublishError toPublishError() => temporary ? PublishError.network(message) : PublishError.configuration(message);

  @override
  String toString() => 'MediaHostException(${hostId ?? ''}: $message)';
}
