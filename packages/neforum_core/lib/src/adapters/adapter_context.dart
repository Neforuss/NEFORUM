import 'dart:typed_data';

import '../auth/auth_broker.dart';
import '../http/neforum_http.dart';
import '../io/media_reader_stub.dart' if (dart.library.io) '../io/media_reader_io.dart';
import '../media_hosts/media_host.dart';
import '../model/account.dart';
import '../model/media.dart';
import '../model/post_variant.dart';
import '../model/publish_result.dart';
import '../publish/cancellation_signal.dart';
import '../publish/publish_pause_signal.dart';
import '../publish/publish_progress.dart';
import '../util/logger.dart';
import 'platform_adapter.dart' show AdapterException;

/// Where [AdapterContext.creating] stands: told before a request that can make a
/// post starts and when it ends. Awaited, because the mark must be on disk before
/// the request goes out.
abstract interface class CreateRecorder {
  Future<void> begin();

  /// [mayBeLive]: the network has the post, or the answer was lost.
  Future<void> end({required bool mayBeLive});
}

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
    this.onEvent,
    this.networkName,
    this.createRecorder,
    this.pause,
    this.livePostCount = 0,
    this.onAccountConfig,
    this.replan,
  })  : _baseHttp = http,
        log = log ?? Logger('adapter'),
        now = clock ?? systemClock,
        _readMedia = readMedia;

  final NeforumHttp _baseHttp;

  /// Bound to [cancellation] when there is one: cancelling aborts the
  /// adapter's request in flight. Bound to the run's progress when it listens,
  /// so the bytes of the open upload are counted.
  late final NeforumHttp http =
      onEvent == null ? _baseHttp.withCancellation(cancellation) : _baseHttp.bound(cancellation: cancellation, observer: _routeBody);

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
  /// adapters that wait between steps (polling for processed media) use [wait].
  final CancellationSignal? cancellation;

  /// Told what the target is doing, in numbers where numbers exist.
  final void Function(ProgressEvent event)? onEvent;

  /// The network's name, for "Check {network} before retrying."
  final String? networkName;

  /// Keeps the publish journal up to date around [creating].
  final CreateRecorder? createRecorder;

  /// While paused, no new [creating] call starts.
  final PublishPauseSignal? pause;

  ProgressStage? _stage;
  String? _label;
  String? _slot;
  int _waitPolls = 0;
  int _created = 0;
  DateTime? _stageSince;
  int _stageBytes = 0;

  /// Posts of this target that are already live when this call starts: the
  /// earlier posts of a series. A failure then must not say nothing was posted.
  final int livePostCount;

  /// Saves what the adapter learned about the account while it published
  /// (X: whether it takes 20 photos and videos in one post) into the stored
  /// account's [ConnectedAccount.config]: each key of the map replaces that
  /// key, a null value removes it. Absent outside a publish run.
  final Future<void> Function(Map<String, Object?> changes)? onAccountConfig;

  /// The target's post resolved again for [account] (an account whose
  /// limits changed, see [onAccountConfig]), checked as a publish checks it:
  /// null when the new plan has errors or no post is at hand. For an adapter
  /// that finds out mid-publish that the plan does not fit the network, and
  /// posts the new plan instead, once, before anything went live.
  final Future<PostVariant?> Function(ConnectedAccount account)? replan;

  /// [onAccountConfig], whose failure only gets a log line: what was learned
  /// is a hint, and the post must not fail over it.
  Future<void> updateAccountConfig(Map<String, Object?> changes) async {
    final save = onAccountConfig;
    if (save == null) return;
    try {
      await save(changes);
    } on Object catch (e) {
      log.warn('Could not save what was learned about the account: $e');
    }
  }

  bool get isCancelled => cancellation?.isCancelled ?? false;

  /// Throws [OperationCancelledException] once the run was cancelled.
  void throwIfCancelled() => cancellation?.throwIfCancelled();

  /// Says what is happening. Ends any open upload slot: from here on, a body that
  /// goes out is not the planned file.
  void progress(String message) {
    _slot = null;
    _say(message);
    _emit(_stage ?? ProgressStage.reading, message);
  }

  void _say(String message) {
    _label = message;
    log.debug(message);
    onProgress?.call(message);
  }

  void _emit(
    ProgressStage stage,
    String label, {
    String? slot,
    int? position,
    int? slotTotal,
    bool confirmed = false,
    int? stepDone,
    int? stepTotal,
    int? serverPercent,
    int attempt = 1,
    int? waitPolls,
  }) {
    if (onEvent != null) {
      if (stage != _stage) {
        finishStage();
        _stageSince = now();
      }
      if (position != null && position > _stageBytes) _stageBytes = position;
    }
    _stage = stage;
    onEvent?.call(ProgressEvent(
      stage: stage,
      label: label,
      at: now(),
      slot: slot,
      position: position,
      slotTotal: slotTotal,
      confirmed: confirmed,
      stepDone: stepDone,
      stepTotal: stepTotal,
      serverPercent: serverPercent,
      attempt: attempt,
      waitPolls: waitPolls,
    ));
  }

  /// Leaves the trace of the stage that just ended: one local log line with how long
  /// it took and how many bytes it counted. The publish service calls this when a
  /// target ends; the last stage has nothing after it to end it.
  void finishStage() {
    final since = _stageSince;
    final stage = _stage;
    if (since == null || stage == null) return;
    log.debug('Stage ${stage.name}: ${now().difference(since).inMilliseconds} ms, $_stageBytes bytes');
    _stageSince = null;
    _stageBytes = 0;
  }

  /// [m] starts going up. Bodies from here on count toward its slot of the plan,
  /// until the next stage. [placement] tells two uploads of one file apart.
  void uploading(MediaAttachment m, String label, {String? placement}) => _open(ProgressSlot.keyOf(m, placement: placement), label);

  /// One body carries all the target's files.
  void uploadingAll(String label) => _open(ProgressEvent.wholeBody, label);

  void _open(String slot, String label) {
    _slot = slot;
    _say(label);
    _emit(ProgressStage.uploading, label, slot: slot);
  }

  /// An upload the plan does not list is next (a cover, a poster): its bytes must
  /// not count toward the last file.
  void closeUploadSlot() => _slot = null;

  /// The server says it has [position] of [total] bytes of the open upload (a
  /// resume offset). A lower figure than the count holds the bar until it passes.
  void uploadOffset(int position, int total) {
    final slot = _slot;
    if (slot == null) return;
    _emit(ProgressStage.uploading, _label ?? '', slot: slot, position: position, slotTotal: total, confirmed: true);
  }

  /// Waiting on the server. [percent] only when the network itself sent one: this
  /// is the one way a number can move during a wait.
  void serverWait(String label, {int? percent}) {
    _slot = null;
    if (_stage != ProgressStage.serverProcessing) _waitPolls = 0;
    _say(label);
    _emit(ProgressStage.serverProcessing, label, serverPercent: percent, waitPolls: _waitPolls);
  }

  /// [done] of [of] counted steps are finished (parts, relays, frames).
  void posted(int done, int of, String label) {
    _slot = null;
    _emit(ProgressStage.posting, label, stepDone: done, stepTotal: of);
  }

  /// Sleeps for [d], and Cancel ends the sleep at once. [via] is a test's stand-in
  /// for the real sleep. After it, one more request of the wait follows, and that
  /// is what the wait's count ([ProgressEvent.waitPolls]) counts.
  Future<void> wait(Duration d, {Future<void> Function(Duration)? via}) async {
    final sleep = via == null ? Future<void>.delayed(d) : via(d);
    final signal = cancellation;
    if (signal == null) {
      await sleep;
    } else {
      await Future.any([sleep, signal.whenCancelled]);
      signal.throwIfCancelled();
    }
    if (_stage == ProgressStage.serverProcessing) {
      _waitPolls++;
      _emit(ProgressStage.serverProcessing, _label ?? '', waitPolls: _waitPolls);
    }
  }

  /// Wraps the request that makes a post (or one part of a thread or series). The
  /// one place that knows what a lost answer means: the post may be live, so the
  /// target fails with [PublishError.outcomeUnknown] and nothing retries it by
  /// itself. A request with a real dedupe key passes [idempotent]: sending it
  /// again cannot post twice, so its errors go on as they are.
  ///
  /// [uploads]: this request's body is the file (Tumblr, Telegram, Dribbble). The
  /// open upload slot stays open and counts its bytes. [countsAsPosted]: false when
  /// the post is not done on this answer (TikTok still processes it).
  ///
  /// An error that proves the server cannot have acted (no connection, a body that
  /// never went out whole) stays the plain retryable failure it is.
  Future<T> creating<T>(String label, Future<T> Function() call, {bool idempotent = false, bool uploads = false, bool countsAsPosted = true}) async {
    throwIfCancelled();
    final held = pause;
    if (held != null && held.isPaused) {
      final signal = cancellation;
      await (signal == null ? held.whenResumed : Future.any([held.whenResumed, signal.whenCancelled]));
      throwIfCancelled();
    }
    if (!uploads) {
      _slot = null;
      if (label != _label) _say(label);
      _emit(ProgressStage.posting, label);
    }
    await createRecorder?.begin();
    var mayBeLive = false;
    try {
      final result = await call();
      final refused = result is NeforumResponse && !result.ok;
      mayBeLive = !refused;
      if (!refused && countsAsPosted) posted(++_created, _created, label);
      return result;
    } on HttpFailure {
      rethrow;
    } on OperationCancelledException catch (e) {
      // Stopped halfway through its body, this request can have made nothing.
      if (idempotent || e.notSent) rethrow;
      mayBeLive = true;
      throw AdapterException(cancelledUnconfirmedError());
    } on Object catch (e) {
      if (idempotent || !NeforumHttp.isTransportError(e) || NeforumHttp.neverReachedServer(e)) rethrow;
      mayBeLive = true;
      throw AdapterException(outcomeUnknownError(details: NeforumHttp.transportDetails(e), uploadInterrupted: NeforumHttp.uploadTrace(e) != null));
    } finally {
      await createRecorder?.end(mayBeLive: mayBeLive);
    }
  }

  String get _unconfirmedMessage => PublishError.unconfirmedMessage(networkName ?? 'the network');

  /// The failure for a post that may be live although no answer says so.
  PublishError outcomeUnknownError({String? details, bool uploadInterrupted = false}) => PublishError(
        kind: PublishErrorKind.network,
        message: _unconfirmedMessage,
        raw: details,
        uploadInterrupted: uploadInterrupted ? true : null,
        outcomeUnknown: true,
      );

  /// The same, when the person cancelled before anyone could say.
  PublishError cancelledUnconfirmedError() => PublishError(kind: PublishErrorKind.cancelled, message: _unconfirmedMessage, outcomeUnknown: true);

  /// [future], or [OperationCancelledException] as soon as the run is cancelled. For
  /// work [http] does not carry, such as relay sockets.
  Future<T> untilCancelled<T>(Future<T> future) {
    final signal = cancellation;
    if (signal == null) return future;
    return Future.any([future, signal.whenCancelled.then<T>((_) => throw const OperationCancelledException())]);
  }

  void _routeBody(BodyProgress p) {
    final slot = _slot;
    if (slot == null) return;
    _emit(
      _stage == ProgressStage.posting ? ProgressStage.posting : ProgressStage.uploading,
      _label ?? '',
      slot: slot,
      position: p.offset + p.sent,
      slotTotal: p.whole ?? p.total,
      confirmed: p.confirmed,
      attempt: p.attempt,
    );
  }

  /// Reads [media] from disk. All at once today, so the stage has no number.
  Future<Uint8List> readMedia(MediaAttachment media) async {
    final before = _stage;
    final open = _slot;
    if (onEvent != null) _emit(ProgressStage.reading, _label ?? 'Reading ${media.fileName ?? 'the file'}');
    final Uint8List bytes;
    try {
      bytes = await (_readMedia != null ? _readMedia(media) : readMediaFromPath(media.path));
    } on OperationCancelledException {
      rethrow;
    } on Object catch (e) {
      // Plain words for every adapter; the system's text, with its errno, goes to the details box.
      throw AdapterException(PublishError.configuration('Could not read ${media.fileName ?? media.path}. Attach it again and retry.', raw: '$e'));
    }
    if (onEvent != null && open != null && before == ProgressStage.uploading) _emit(ProgressStage.uploading, _label ?? '', slot: open);
    return bytes;
  }

  AuthBroker requireBroker() {
    final b = broker;
    if (b == null) throw StateError('This operation needs a browser (AuthBroker) but none was provided');
    return b;
  }

  AdapterContext copyWith({AuthBroker? broker, MediaHost? mediaHost, Logger? log, void Function(String)? onProgress, int? livePostCount}) =>
      AdapterContext(
        http: _baseHttp,
        broker: broker ?? this.broker,
        mediaHost: mediaHost ?? this.mediaHost,
        log: log ?? this.log,
        clock: now,
        onProgress: onProgress ?? this.onProgress,
        browserFills: browserFills,
        readMedia: _readMedia,
        cancellation: cancellation,
        onEvent: onEvent,
        networkName: networkName,
        createRecorder: createRecorder,
        pause: pause,
        livePostCount: livePostCount ?? this.livePostCount,
        onAccountConfig: onAccountConfig,
        replan: replan,
      );
}
