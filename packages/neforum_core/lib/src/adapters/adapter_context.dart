import 'dart:typed_data';

import '../auth/auth_broker.dart';
import '../http/neforum_http.dart';
import '../io/media_reader_stub.dart' if (dart.library.io) '../io/media_reader_io.dart';
import '../media_hosts/media_host.dart';
import '../model/media.dart';
import '../model/publish_result.dart';
import '../publish/cancellation_signal.dart';
import '../util/logger.dart';
import 'platform_adapter.dart' show AdapterException;

/// Everything an adapter may need from its environment. Built once per
/// operation by the publishing/connect services so adapters stay pure.
class AdapterContext {
  AdapterContext({
    required NeforumHttp http,
    this.broker,
    this.mediaHost,
    Logger? log,
    Clock? clock,
    this.onProgress,
    this.browserFills = false,
    Future<Uint8List> Function(MediaAttachment media)? readMedia,
    this.cancellation,
    this.livePostCount = 0,
  })  : http = http.withCancellation(cancellation),
        log = log ?? Logger('adapter'),
        now = clock ?? systemClock,
        _readMedia = readMedia;

  /// Bound to [cancellation] when there is one: cancelling aborts the
  /// adapter's request in flight.
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

  /// Fires when the user cancels the publish run. [http] already honours it;
  /// adapters that wait between steps (polling for processed media) can
  /// check [isCancelled] or call [throwIfCancelled].
  final CancellationSignal? cancellation;

  /// Posts of this target that are already live when this call starts: the
  /// earlier posts of a series. A failure then must not say nothing was posted.
  final int livePostCount;

  bool get isCancelled => cancellation?.isCancelled ?? false;

  /// Throws [OperationCancelledException] once the run was cancelled.
  void throwIfCancelled() => cancellation?.throwIfCancelled();

  void progress(String message) {
    log.debug(message);
    onProgress?.call(message);
  }

  /// The bytes of [media]. A file that cannot be read fails as an
  /// [AdapterException] in plain words, for every adapter; the system's text,
  /// with its errno, goes to the details box.
  Future<Uint8List> readMedia(MediaAttachment media) async {
    try {
      return await (_readMedia != null ? _readMedia(media) : readMediaFromPath(media.path));
    } on OperationCancelledException {
      rethrow;
    } on Object catch (e) {
      throw AdapterException(PublishError.configuration('Could not read ${media.fileName ?? media.path}. Attach it again and retry.', raw: '$e'));
    }
  }

  AuthBroker requireBroker() {
    final b = broker;
    if (b == null) throw StateError('This operation needs a browser (AuthBroker) but none was provided');
    return b;
  }

  AdapterContext copyWith({AuthBroker? broker, MediaHost? mediaHost, Logger? log, void Function(String)? onProgress, int? livePostCount}) =>
      AdapterContext(
        http: http,
        broker: broker ?? this.broker,
        mediaHost: mediaHost ?? this.mediaHost,
        log: log ?? this.log,
        clock: now,
        onProgress: onProgress ?? this.onProgress,
        browserFills: browserFills,
        readMedia: _readMedia,
        cancellation: cancellation,
        livePostCount: livePostCount ?? this.livePostCount,
      );
}
