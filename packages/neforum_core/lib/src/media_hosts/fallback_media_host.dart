import 'dart:typed_data';

import '../model/media.dart';
import '../util/logger.dart';
import 'media_host.dart';

/// Tries [main] first and, when it can't store a file, [fallback]: for the
/// day a free host such as Litterbox is down. Adapters see one host, so every
/// network that needs public links gets the fallback without changes.
///
/// A file goes straight to [fallback] when it is larger than [main] accepts.
/// [main] has already retried outages once (see `guardedUpload`), so any
/// failure left over moves on to [fallback].
class FallbackMediaHost implements MediaHost, DescribesVerify {
  FallbackMediaHost(this.main, this.fallback, {this.onFallback, Logger? log}) : _log = log ?? Logger('media-host');

  final MediaHost main;
  final MediaHost fallback;

  /// Called with one or two sentences each time [fallback] stored a file
  /// instead of [main], so the app can tell the user their main host has a
  /// problem.
  final void Function(String message)? onFallback;
  final Logger _log;

  /// Appended to [HostedMedia.hostId] of files on [fallback], so [delete]
  /// reaches the right host even when both are the same kind (two buckets).
  static const String fallbackMark = '@fallback';

  @override
  String get id => main.id;
  @override
  String get name => main.name;
  @override
  String get description => main.description;
  @override
  List<MediaHostField> get fields => main.fields;

  @override
  int? get maxBytes {
    final a = main.maxBytes, b = fallback.maxBytes;
    return a == null || b == null ? null : (a > b ? a : b);
  }

  static bool _fits(MediaHost host, int bytes) => host.maxBytes == null || bytes <= host.maxBytes!;

  @override
  Future<HostedMedia> upload(MediaAttachment media, Uint8List bytes, {Duration? ttl}) async {
    if (!_fits(main, bytes.length)) {
      final hosted = await fallback.upload(media, bytes, ttl: ttl);
      _report('${_label(media)} is larger than ${main.name} accepts, so ${fallback.name} stored it.');
      return _marked(hosted);
    }
    final MediaHostException first;
    try {
      return await main.upload(media, bytes, ttl: ttl);
    } on MediaHostException catch (e) {
      first = e;
    } on Exception catch (e) {
      first = MediaHostException('${main.name} couldn\'t store the file: $e', hostId: main.id, temporary: true);
    }
    if (!_fits(fallback, bytes.length)) throw first;
    try {
      final hosted = await fallback.upload(media, bytes, ttl: ttl);
      _report('${main.name} failed, so ${fallback.name} stored ${_label(media)}. ${first.message}');
      return _marked(hosted);
    } on MediaHostException catch (e) {
      throw _both(first, e.message, e.temporary);
    } on Exception catch (e) {
      throw _both(first, '$e', true);
    }
  }

  MediaHostException _both(MediaHostException first, String second, bool secondTemporary) => MediaHostException(
        'Neither media host could store the file. ${first.message} The fallback, ${fallback.name}: $second',
        hostId: main.id,
        // Retrying later can work if either host was only having an outage.
        temporary: first.temporary || secondTemporary,
      );

  void _report(String message) {
    _log.warn(message);
    onFallback?.call(message);
  }

  static String _label(MediaAttachment m) => m.fileName ?? (m.isVideo ? 'the video' : 'the image');

  static HostedMedia _marked(HostedMedia h) =>
      HostedMedia(hostId: '${h.hostId}$fallbackMark', url: h.url, deleteHandle: h.deleteHandle, expiresAt: h.expiresAt);

  @override
  Future<void> delete(HostedMedia hosted) {
    if (!hosted.hostId.endsWith(fallbackMark)) return main.delete(hosted);
    final hostId = hosted.hostId.substring(0, hosted.hostId.length - fallbackMark.length);
    return fallback.delete(HostedMedia(hostId: hostId, url: hosted.url, deleteHandle: hosted.deleteHandle, expiresAt: hosted.expiresAt));
  }

  /// Tests both hosts, the main one first.
  @override
  Future<void> verify() async {
    await main.verify();
    await fallback.verify();
  }

  @override
  String get verifiedMessage => '${verifySuccessMessage(main)} Fallback: ${verifySuccessMessage(fallback)}';
}
