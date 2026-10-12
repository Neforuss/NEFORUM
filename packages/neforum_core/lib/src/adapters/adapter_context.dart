import 'dart:typed_data';

import '../auth/auth_broker.dart';
import '../http/neforum_http.dart';
import '../io/media_reader_stub.dart' if (dart.library.io) '../io/media_reader_io.dart';
import '../media_hosts/media_host.dart';
import '../model/media.dart';
import '../util/logger.dart';

/// Everything an adapter may need from its environment. Built once per
/// operation by the publishing/connect services so adapters stay pure.
class AdapterContext {
  AdapterContext({
    required this.http,
    this.broker,
    this.mediaHost,
    Logger? log,
    Clock? clock,
    this.onProgress,
    this.browserFills = false,
    Future<Uint8List> Function(MediaAttachment media)? readMedia,
  })  : log = log ?? Logger('adapter'),
        now = clock ?? systemClock,
        _readMedia = readMedia;

  final NeforumHttp http;

  /// Present during `connect` (and refresh) when a browser flow is possible.
  final AuthBroker? broker;

  /// Present when the user configured a public media host.
  final MediaHost? mediaHost;
  final Logger log;
  final Clock now;

  /// Optional progress callback ("Uploading image 2 of 3…").
  final void Function(String message)? onProgress;

  /// The NEFORUM browser extension will fill in hand-offs on the platform's
  /// web composer ([HandoffPlan.composerUrl]), files included: work only the
  /// plain hand-off needs (putting photos on the media host for an intent
  /// URL) can be skipped.
  final bool browserFills;
  final Future<Uint8List> Function(MediaAttachment media)? _readMedia;

  void progress(String message) {
    log.debug(message);
    onProgress?.call(message);
  }

  Future<Uint8List> readMedia(MediaAttachment media) =>
      _readMedia != null ? _readMedia(media) : readMediaFromPath(media.path);

  AuthBroker requireBroker() {
    final b = broker;
    if (b == null) throw StateError('This operation needs a browser (AuthBroker) but none was provided');
    return b;
  }

  AdapterContext copyWith({AuthBroker? broker, MediaHost? mediaHost, Logger? log, void Function(String)? onProgress}) =>
      AdapterContext(
        http: http,
        broker: broker ?? this.broker,
        mediaHost: mediaHost ?? this.mediaHost,
        log: log ?? this.log,
        clock: now,
        onProgress: onProgress ?? this.onProgress,
        browserFills: browserFills,
        readMedia: _readMedia,
      );
}
