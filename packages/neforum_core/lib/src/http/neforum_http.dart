import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:meta/meta.dart';

import '../model/publish_result.dart';
import '../publish/cancellation_signal.dart';
import '../util/logger.dart';
import 'transient_stub.dart' if (dart.library.io) 'transient_io.dart';

/// Headers computed afresh for each attempt of a request (see
/// [NeforumHttp.send]).
typedef HeaderSigner = Map<String, String> Function();

const String neforumVersion = '0.1.0';
const String defaultUserAgent = 'NEFORUM/$neforumVersion (+https://github.com/Neforuss/NEFORUM)';

/// A file part of a multipart request. Bytes are held in memory so that the
/// request can be retried.
class HttpFilePart {
  const HttpFilePart({
    required this.field,
    required this.bytes,
    required this.fileName,
    required this.contentType,
  });

  final String field;
  final Uint8List bytes;
  final String fileName;
  final String contentType;
}

class NeforumResponse {
  NeforumResponse(this.statusCode, this.headers, this.bodyBytes, this.url);

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List bodyBytes;
  final Uri url;

  bool get ok => statusCode >= 200 && statusCode < 300;

  String get body => utf8.decode(bodyBytes, allowMalformed: true);

  /// Decoded JSON body, or `null` when the body is empty or not JSON.
  dynamic get json {
    if (bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  Map<String, dynamic> get jsonMap {
    final j = json;
    return j is Map ? Map<String, dynamic>.from(j) : <String, dynamic>{};
  }

  Duration? get retryAfter => _parseRetryAfter(headers['retry-after']);
}

/// Thrown by [NeforumHttp] for non-2xx responses when `throwOnError` is set.
class HttpFailure implements Exception {
  HttpFailure(this.response);

  final NeforumResponse response;

  int get statusCode => response.statusCode;
  String get body => response.body;
  Uri get url => response.url;

  /// Best-effort mapping of an HTTP status onto a [PublishError]. Adapters
  /// refine this with platform-specific error bodies.
  PublishError toPublishError({String? context}) {
    final prefix = context == null ? '' : '$context: ';
    final snippet = body.length > 600 ? '${body.substring(0, 600)}…' : body;
    final where = '${url.host}${url.path}';
    switch (statusCode) {
      case 401:
        return PublishError.auth('${prefix}HTTP $statusCode from $where', raw: snippet, statusCode: statusCode);
      // Forbidden: the server knows who is asking and refuses this request. That is
      // not an ended sign-in, and a reconnect is not what fixes it.
      case 403:
        return PublishError.auth('${prefix}HTTP $statusCode from $where', raw: snippet, statusCode: statusCode, notAllowed: true);
      case 429:
        return PublishError.quota('${prefix}rate limited by $where',
            raw: snippet, statusCode: statusCode, retryAfter: response.retryAfter);
      case 400:
      case 413:
      case 415:
      case 422:
        return PublishError.validation('${prefix}HTTP $statusCode from $where', raw: snippet, statusCode: statusCode);
      default:
        if (statusCode >= 500) {
          return PublishError.network('${prefix}HTTP $statusCode from $where',
              raw: snippet, statusCode: statusCode, retryAfter: response.retryAfter);
        }
        return PublishError.platform('${prefix}HTTP $statusCode from $where', raw: snippet, statusCode: statusCode);
    }
  }

  @override
  String toString() => 'HttpFailure($statusCode ${url.host}${url.path}): ${body.length > 200 ? body.substring(0, 200) : body}';
}

/// What is known about a watched upload when it failed. The count is bytes
/// handed to the connection, not bytes the server has: the operating system
/// and the path can hold a good part of a file that never arrives.
@immutable
class UploadTrace {
  const UploadTrace({required this.sentBytes, required this.totalBytes, required this.attempts, required this.elapsed});

  final int sentBytes;
  final int totalBytes;
  final int attempts;
  final Duration elapsed;

  /// Every byte was handed over, so the server may have the whole request.
  /// When this is false it cannot have acted on the request.
  bool get wholeBodySent => sentBytes >= totalBytes;

  String get summary => '$sentBytes of $totalBytes bytes handed to the connection, ${elapsed.inSeconds} s, attempt $attempts';
}

/// A request the connection dropped before an answer came. [message] and
/// [toString] are plain words for people; [details] keeps the system's own
/// text for the details box and for logs, with the address cut down to its
/// origin (some APIs carry a token in the path or the query).
class ConnectionFailed extends http.ClientException {
  ConnectionFailed(Uri url, this.details, {String? message, this.neverSent = false}) : super(message ?? 'The connection to ${url.host} failed.', url);

  final String details;

  /// No connection was ever made (no such host, connection refused), so the
  /// server cannot have seen the request.
  final bool neverSent;

  @override
  String toString() => message;
}

/// A watched upload the connection dropped before an answer came. On Windows
/// this is what "Write failed" (errno 10053 or 10054) becomes. If the server
/// sent an answer first, it is lost: dart:io only returns a response once the
/// whole body went out.
class UploadInterrupted extends ConnectionFailed {
  UploadInterrupted(Uri url, String cause, this.trace, {super.neverSent})
      : super(url, '$cause\n${trace.summary}', message: 'The upload to ${url.host} was cut off${_triedText(trace.attempts)}.');

  final UploadTrace trace;
}

/// A request that got no answer in time. [message] and [toString] are plain
/// words; [trace] is set when it was a watched upload.
class RequestTimedOut extends TimeoutException {
  RequestTimedOut(String super.message, super.duration, this.details, {this.trace});

  final String details;
  final UploadTrace? trace;

  @override
  String toString() => message!;
}

String _triedText(int attempts) => attempts > 1 ? ' (tried $attempts times)' : '';

/// How far a request's body has got. [sent] is bytes handed to the connection,
/// not bytes the server has: buffers in the operating system and on the path can
/// hold most of a small file, so a count never means "received".
@immutable
class BodyProgress {
  const BodyProgress({
    required this.sent,
    required this.total,
    this.offset = 0,
    this.whole,
    this.attempt = 1,
    this.answered = false,
    this.status,
  });

  /// Bytes of this request's body the connection has taken.
  final int sent;

  /// The request's content length.
  final int total;

  /// Where this body starts in the whole file (chunked uploads, resumes).
  final int offset;

  /// The whole file's size when this body is a part of it.
  final int? whole;

  /// 1, 2, ... inside [NeforumHttp]'s own retry loop. [sent] restarts on each.
  final int attempt;

  /// The server answered this request.
  final bool answered;
  final int? status;

  /// The server answered for this body with a success.
  bool get confirmed => answered && status != null && status! >= 200 && status! < 300;
}

/// Told how a request's body goes (see [NeforumHttp.bound]).
typedef BodyObserver = void Function(BodyProgress progress);

/// Thin wrapper over `package:http` with a NEFORUM user agent, JSON/form/
/// multipart helpers, timeouts and bounded retries for transient failures.
class NeforumHttp {
  NeforumHttp({
    http.Client? client,
    this.userAgent = defaultUserAgent,
    this.maxRetries = 2,
    this.timeout = const Duration(seconds: 60),
    this.uploadStallTimeout = const Duration(seconds: 60),
    Logger? log,
  })  : _client = client ?? http.Client(),
        _log = log ?? Logger('http'),
        cancellation = null,
        observer = null,
        _ownsClient = true;

  NeforumHttp._bound(NeforumHttp base, this.cancellation, this.observer)
      : _client = base._client,
        userAgent = base.userAgent,
        maxRetries = base.maxRetries,
        timeout = base.timeout,
        uploadStallTimeout = base.uploadStallTimeout,
        _log = base._log,
        _ownsClient = false;

  final http.Client _client;
  final String userAgent;
  final int maxRetries;
  final Duration timeout;

  /// How long an upload may go without sending anything before it is given
  /// up. Uploads have no deadline of their own: on a slow or shared uplink a
  /// big file takes as long as it takes, as long as it keeps moving. 60 s
  /// matches nginx's `client_body_timeout`: a server that has given up is not
  /// waited on for longer than it waits for us.
  final Duration uploadStallTimeout;
  final Logger _log;

  /// When set, cancelling it aborts the request in flight and every later
  /// one fails with [OperationCancelledException] (see [withCancellation]).
  final CancellationSignal? cancellation;

  /// When set, told how the bodies of uploads go (see [bound]).
  final BodyObserver? observer;
  final bool _ownsClient;

  /// The same connection pool, with every request bound to [signal]: the
  /// client is shared by publishing, sync and media hosts, so a publish run
  /// is stopped request by request instead of by closing it.
  NeforumHttp withCancellation(CancellationSignal? signal) =>
      signal == null || identical(signal, cancellation) ? this : NeforumHttp._bound(this, signal, observer);

  /// The same connection pool with [cancellation] and [observer] over this one's.
  ///
  /// The observer hears about bodies that carry a file (`bytes` or `files`) and
  /// any body big enough to be watched, which is how a JSON body with a base64
  /// image counts. A small JSON or form call says nothing: it is not an upload. A
  /// watched body reports each piece as the connection takes it. A smaller one
  /// goes over in one piece, so it reports once, when the answer arrives.
  NeforumHttp bound({CancellationSignal? cancellation, BodyObserver? observer}) {
    final signal = cancellation ?? this.cancellation;
    final watcher = observer ?? this.observer;
    return identical(signal, this.cancellation) && identical(watcher, this.observer) ? this : NeforumHttp._bound(this, signal, watcher);
  }

  /// Closes the client. A view made by [withCancellation] leaves the shared
  /// client open.
  void close() {
    if (_ownsClient) _client.close();
  }

  Future<NeforumResponse> get(Uri url,
          {Map<String, String>? headers, HeaderSigner? signHeaders, bool throwOnError = true}) =>
      send('GET', url, headers: headers, signHeaders: signHeaders, throwOnError: throwOnError);

  Future<NeforumResponse> delete(Uri url,
          {Map<String, String>? headers, HeaderSigner? signHeaders, bool throwOnError = true}) =>
      send('DELETE', url, headers: headers, signHeaders: signHeaders, throwOnError: throwOnError);

  Future<NeforumResponse> postJson(Uri url, Object? json,
          {Map<String, String>? headers, HeaderSigner? signHeaders, bool throwOnError = true, String method = 'POST'}) =>
      send(method, url, headers: headers, signHeaders: signHeaders, jsonBody: json, throwOnError: throwOnError);

  Future<NeforumResponse> postForm(Uri url, Map<String, String> form,
          {Map<String, String>? headers, HeaderSigner? signHeaders, bool throwOnError = true, String method = 'POST'}) =>
      send(method, url, headers: headers, signHeaders: signHeaders, form: form, throwOnError: throwOnError);

  Future<NeforumResponse> multipart(
    Uri url, {
    Map<String, String> fields = const {},
    List<HttpFilePart> files = const [],
    Map<String, String>? headers,
    HeaderSigner? signHeaders,
    bool throwOnError = true,
    String method = 'POST',
    bool retrySafe = false,
    int? bodyOffset,
    int? bodyWhole,
  }) =>
      send(method, url,
          headers: headers,
          signHeaders: signHeaders,
          fields: fields,
          files: files,
          throwOnError: throwOnError,
          retrySafe: retrySafe,
          bodyOffset: bodyOffset,
          bodyWhole: bodyWhole);

  /// Sends raw bytes (used for S3 presigned PUTs, chunked uploads, ...).
  Future<NeforumResponse> putBytes(Uri url, Uint8List bytes,
          {Map<String, String>? headers,
          HeaderSigner? signHeaders,
          bool throwOnError = true,
          String method = 'PUT',
          bool retrySafe = false,
          int? bodyOffset,
          int? bodyWhole}) =>
      send(method, url,
          headers: headers,
          signHeaders: signHeaders,
          bytes: bytes,
          throwOnError: throwOnError,
          retrySafe: retrySafe,
          bodyOffset: bodyOffset,
          bodyWhole: bodyWhole);

  Future<Uint8List> download(Uri url, {Map<String, String>? headers}) async {
    final r = await send('GET', url, headers: headers);
    return r.bodyBytes;
  }

  /// [signHeaders] is called before every attempt, retries included, and its
  /// headers go over [headers]: for signatures that must not be sent twice,
  /// such as OAuth 1.0a's (X and Tumblr refuse a nonce they have seen).
  ///
  /// [retrySafe]: the caller knows this request cannot create a post (a media
  /// file nothing is attached to yet), so a dropped connection or a timeout
  /// re-sends it up to [maxRetries] times at any size. It stays false for
  /// anything that can publish: a platform where the upload is the post must
  /// never set it.
  ///
  /// [bodyOffset] and [bodyWhole] say where this body sits in a bigger file, for
  /// [observer]: chunked uploads and resumes.
  ///
  /// Transport failures leave as [ConnectionFailed], [UploadInterrupted] or
  /// [RequestTimedOut], whose text is fit to show to a person.
  Future<NeforumResponse> send(
    String method,
    Uri url, {
    Map<String, String>? headers,
    HeaderSigner? signHeaders,
    Object? jsonBody,
    Map<String, String>? form,
    Map<String, String>? fields,
    List<HttpFilePart>? files,
    Uint8List? bytes,
    bool throwOnError = true,
    Duration? timeout,
    bool retrySafe = false,
    int? bodyOffset,
    int? bodyWhole,
  }) async {
    // Encoded up front so that a big JSON body (Pinterest's base64 images)
    // counts as what it is: an upload.
    final jsonBytes = jsonBody == null ? null : utf8.encode(jsonEncode(jsonBody));
    final formBytes = form == null ? null : utf8.encode(encodeForm(form));
    // Uploads are watched instead of timed: they fail only when nothing has
    // been sent for [uploadStallTimeout], or no answer comes after the last
    // byte (a fixed budget failed 3 MB files on a busy 1 Mbit/s uplink). A
    // big body is not re-sent automatically after a timeout or a dropped
    // connection unless the caller says it is safe ([retrySafe]).
    final bodySize = (jsonBytes?.length ?? 0) +
        (formBytes?.length ?? 0) +
        (bytes?.length ?? 0) +
        (fields ?? const <String, String>{}).values.fold<int>(0, (s, v) => s + v.length) +
        (files ?? const <HttpFilePart>[]).fold<int>(0, (s, f) => s + f.bytes.length);
    final base = timeout ?? this.timeout;
    final upload = bodySize > watchedBodyThreshold;
    final retries = bodySize > 8 * 1024 * 1024 && !retrySafe ? 0 : maxRetries;
    // A POST that may already have been processed (gateway error, dropped
    // connection) is never re-sent here: that could publish twice. The
    // publish service retries the whole target later instead.
    final idempotent = _idempotentMethods.contains(method.toUpperCase()) ||
        (headers?.keys.any((k) => k.toLowerCase() == 'idempotency-key') ?? false);
    final signal = cancellation;
    final meter = _UploadMeter();
    final clock = Stopwatch()..start();
    var attempt = 0;
    final watcher = observer;
    final reports = watcher != null && bodySize > 0 && (upload || bytes != null || (files?.isNotEmpty ?? false));
    void report({bool answered = false, int? status}) => watcher!(BodyProgress(
          sent: answered ? meter.total : meter.sent,
          total: meter.total,
          offset: bodyOffset ?? 0,
          whole: bodyWhole,
          attempt: attempt,
          answered: answered,
          status: status,
        ));
    while (true) {
      attempt++;
      meter.sent = 0;
      if (signal != null && signal.isCancelled) throw const OperationCancelledException(notSent: true);
      try {
        final attemptHeaders = signHeaders == null ? headers : {...?headers, ...signHeaders()};
        // The host only: some APIs carry a token in the path or the query.
        _log.debug('$method ${url.host} (attempt $attempt)');
        final http.Response res;
        if (upload) {
          res = await _unlessCancelled(
              _sendWatched(method, url, attemptHeaders, jsonBytes, formBytes, fields, files, bytes, base, signal, meter, reports ? report : null), signal);
          if (reports) report(answered: true, status: res.statusCode);
        } else {
          final req = _build(method, url, attemptHeaders, jsonBytes, formBytes, fields, files, bytes, abortTrigger: signal?.whenCancelled);
          final streamed = await _unlessCancelled(_client.send(req).timeout(base), signal);
          res = await _unlessCancelled(http.Response.fromStream(streamed).timeout(base), signal);
          if (reports) {
            meter.total = req.contentLength ?? bodySize;
            report(answered: true, status: res.statusCode);
          }
        }
        final out = NeforumResponse(res.statusCode, _lowercase(res.headers), res.bodyBytes, url);
        if (!out.ok && attempt <= retries && (idempotent ? _retryable(out.statusCode) : _notProcessed(out) || (retrySafe && _gatewayError(out)))) {
          final wait = out.retryAfter ?? _backoff(attempt);
          if (wait <= const Duration(seconds: 30)) {
            _log.warn('HTTP ${out.statusCode} from ${url.host}; retrying in ${wait.inSeconds}s');
            await _pause(wait, signal);
            continue;
          }
        }
        if (!out.ok && throwOnError) throw HttpFailure(out);
        return out;
      } on HttpFailure {
        rethrow;
      } on OperationCancelledException {
        throw OperationCancelledException(notSent: upload && meter.sent < meter.total);
      } on Object catch (e) {
        // An aborted request surfaces as a ClientException; report it as
        // the cancellation it is, never as a network error to retry.
        if (signal != null && signal.isCancelled) throw OperationCancelledException(notSent: upload && meter.sent < meter.total);
        if (!isTransportError(e)) rethrow;
        final cause = _safeDetails('$e');
        final trace = upload
            ? UploadTrace(sentBytes: meter.sent, totalBytes: meter.total, attempts: attempt, elapsed: clock.elapsed)
            : null;
        final position = trace == null ? 'attempt $attempt' : trace.summary;
        if ((idempotent || retrySafe) && attempt <= retries) {
          final wait = _backoff(attempt);
          _log.warn('Network error calling ${url.host} ($cause; $position); retrying in ${wait.inMilliseconds} ms');
          await _pause(wait, signal);
          continue;
        }
        _log.warn('Network error calling ${url.host} ($cause; $position); giving up');
        throw _plainFailure(e, cause, url, base, trace);
      }
    }
  }

  /// The failure callers see for a transport error [e], in words fit for a
  /// person. [cause] is the system's own text, kept for the details box.
  static Exception _plainFailure(Object e, String cause, Uri url, Duration base, UploadTrace? trace) {
    if (e is TimeoutException) {
      final what = (trace == null ? null : e.message) ?? '${url.host} did not answer within ${base.inSeconds} s';
      final tried = trace == null ? '' : _triedText(trace.attempts);
      return RequestTimedOut('$what$tried.', e.duration, trace == null ? cause : '$cause\n${trace.summary}', trace: trace);
    }
    final neverSent = isConnectFailure(e);
    return trace == null ? ConnectionFailed(url, cause, neverSent: neverSent) : UploadInterrupted(url, cause, trace, neverSent: neverSent);
  }

  /// Whether transport error [e] proves the server cannot have acted on the
  /// request: no connection was made, or the body never went out whole. Anything
  /// else may have reached the server, its answer lost.
  static bool neverReachedServer(Object e) {
    if (e is ConnectionFailed && e.neverSent) return true;
    if (isConnectFailure(e)) return true;
    final trace = uploadTrace(e);
    return trace != null && !trace.wholeBodySent;
  }

  /// [future], or [OperationCancelledException] as soon as [signal] fires,
  /// even with a client that ignores the abort trigger.
  static Future<T> _unlessCancelled<T>(Future<T> future, CancellationSignal? signal) {
    if (signal == null) return future;
    return Future.any([future, signal.whenCancelled.then<T>((_) => throw const OperationCancelledException())]);
  }

  /// Waits [wait] before a retry; a cancellation ends the wait at once.
  static Future<void> _pause(Duration wait, CancellationSignal? signal) async {
    if (signal == null) return Future<void>.delayed(wait);
    await Future.any([Future<void>.delayed(wait), signal.whenCancelled]);
    signal.throwIfCancelled();
  }

  http.BaseRequest _build(
    String method,
    Uri url,
    Map<String, String>? headers,
    Uint8List? jsonBytes,
    Uint8List? formBytes,
    Map<String, String>? fields,
    List<HttpFilePart>? files,
    Uint8List? bytes, {
    Future<void>? abortTrigger,
  }) {
    final h = <String, String>{'User-Agent': userAgent, ...?headers};
    if (files != null || fields != null) {
      final req = http.AbortableMultipartRequest(method, url, abortTrigger: abortTrigger)..headers.addAll(h);
      if (fields != null) req.fields.addAll(fields);
      for (final f in files ?? const <HttpFilePart>[]) {
        req.files.add(http.MultipartFile.fromBytes(f.field, f.bytes,
            filename: f.fileName, contentType: _mediaType(f.contentType)));
      }
      return req;
    }
    final req = http.AbortableRequest(method, url, abortTrigger: abortTrigger)..headers.addAll(h);
    if (jsonBytes != null) {
      req.headers.putIfAbsent('Content-Type', () => 'application/json; charset=utf-8');
      // As `Request.body` would: a type without a charset gets one.
      final type = _mediaType(req.headers['Content-Type']!);
      if (type != null && !type.parameters.containsKey('charset')) {
        req.headers['Content-Type'] = type.change(parameters: {'charset': 'utf-8'}).toString();
      }
      req.bodyBytes = jsonBytes;
    } else if (formBytes != null) {
      // The plain type, as browsers and curl send it: the body is
      // percent-encoded ASCII, and TikTok's token endpoint answers "The
      // request parameters are malformed" to `; charset=utf-8`. bodyFields
      // (and body) would add that charset, so set the bytes directly.
      req.headers.putIfAbsent('Content-Type', () => 'application/x-www-form-urlencoded');
      req.bodyBytes = formBytes;
    } else if (bytes != null) {
      req.headers.putIfAbsent('Content-Type', () => 'application/octet-stream');
      req.bodyBytes = bytes;
    }
    return req;
  }

  /// Sends an upload in [_uploadChunk] pieces that the connection pulls as
  /// fast as it can send them, and gives up only when no piece has gone out
  /// for [uploadStallTimeout], or when the server has not answered [base]
  /// twice over after the last one (it may still be processing a video).
  Future<http.Response> _sendWatched(String method, Uri url, Map<String, String>? headers, Uint8List? jsonBytes, Uint8List? formBytes,
      Map<String, String>? fields, List<HttpFilePart>? files, Uint8List? bytes, Duration base, CancellationSignal? signal, _UploadMeter meter, void Function()? report) async {
    final abort = Completer<void>();
    final stalled = Completer<Never>();
    Timer? watchdog;
    void arm(Duration limit, String what) {
      watchdog?.cancel();
      watchdog = Timer(limit, () {
        if (!stalled.isCompleted) stalled.completeError(TimeoutException(what, limit));
        if (!abort.isCompleted) abort.complete();
      });
    }

    final stallLimit = uploadStallTimeout;
    final answerLimit = base * 2;
    final trigger = signal == null ? abort.future : Future.any([abort.future, signal.whenCancelled]);
    final plain = _build(method, url, headers, jsonBytes, formBytes, fields, files, bytes);
    final source = plain.finalize();
    meter.total = plain.contentLength ?? 0;
    final body = _watchedBody(
      source,
      onPiece: (n) {
        meter.sent += n;
        // A browser collects the whole body first: there, only the answer means anything.
        if (bodyPiecesAreCounted) report?.call();
      },
      onProgress: () => arm(stallLimit, 'Nothing could be sent to ${url.host} for ${stallLimit.inSeconds} s'),
      onSent: () => arm(answerLimit, '${url.host} did not answer within ${answerLimit.inSeconds} s of the upload'),
    );
    final req = _WatchedRequest(method, url, body, abortTrigger: trigger)
      ..headers.addAll(plain.headers)
      ..contentLength = plain.contentLength;
    arm(stallLimit, 'Nothing could be sent to ${url.host} for ${stallLimit.inSeconds} s');
    try {
      final streamed = await Future.any([_client.send(req), stalled.future]);
      // Reading the answer counts as progress too.
      arm(answerLimit, '${url.host} did not finish its answer within ${answerLimit.inSeconds} s');
      return await Future.any([http.Response.fromStream(streamed), stalled.future]);
    } finally {
      watchdog?.cancel();
    }
  }

  /// From this body size on, a request is watched instead of timed: 60 s for
  /// the whole request is too little for more than a few hundred KiB on a
  /// starved uplink, and a timed request is not aborted when it gives up.
  static const int watchedBodyThreshold = 64 * 1024;

  /// Small enough that 8 kbit/s still moves a piece well inside the stall limit.
  static const int _uploadChunk = 16 * 1024;

  /// [source] in pieces of at most [_uploadChunk] bytes. [onPiece] runs as a
  /// piece is handed over, so while the count is short of the total, part of
  /// the body certainly never left. [onProgress] runs each time the consumer
  /// is ready for more and [onSent] after the last piece. The generator waits
  /// at each `yield` until the connection wants more, so the calls follow what
  /// is really sent.
  static Stream<List<int>> _watchedBody(Stream<List<int>> source,
      {required void Function(int) onPiece, required void Function() onProgress, required void Function() onSent}) async* {
    await for (final chunk in source) {
      for (var start = 0; start < chunk.length; start += _uploadChunk) {
        final end = start + _uploadChunk < chunk.length ? start + _uploadChunk : chunk.length;
        onPiece(end - start);
        yield chunk is Uint8List ? Uint8List.sublistView(chunk, start, end) : chunk.sublist(start, end);
        onProgress();
      }
    }
    onSent();
  }

  /// True for errors that mean "the network failed", not "the server said no".
  /// `application/x-www-form-urlencoded` body for [form] (UTF-8, `+` for spaces).
  static String encodeForm(Map<String, String> form) =>
      form.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');

  static bool isTransportError(Object e) => e is TimeoutException || e is http.ClientException || isTransientIoError(e);

  /// The trace of [e] when it is a watched upload that failed.
  static UploadTrace? uploadTrace(Object e) => switch (e) {
        UploadInterrupted(:final trace) => trace,
        RequestTimedOut(:final trace) => trace,
        _ => null,
      };

  /// The text for a person about transport error [e]: never an errno or a
  /// Dart type name. [transportDetails] keeps those for the details box.
  static String transportMessage(Object e) => switch (e) {
        ConnectionFailed(:final message) => message,
        RequestTimedOut(:final message?) => message,
        TimeoutException() => 'The server did not answer in time.',
        _ when isTransportError(e) => 'The connection failed.',
        _ => '$e',
      };

  /// The system's own text for [e], for `PublishError.raw`. Any other
  /// exception gives its `toString`.
  static String transportDetails(Object e) => switch (e) {
        ConnectionFailed(:final details) => details,
        RequestTimedOut(:final details) => details,
        _ => _safeDetails('$e'),
      };

  /// [text] fit to store and log: every address cut down to its origin, because
  /// some APIs carry a token in the path or the query. If what is left looks like
  /// quoted request data rather than the system's own words, none of it is kept,
  /// because a body can hold a token too.
  static String _safeDetails(String text) {
    final cut = text
        .replaceAllMapped(RegExp(r'(https?://[^/\s?#]+)[^\s]*'), (m) => m[1]!)
        .replaceAll(RegExp(r'uri=(?!https?://)\S+'), 'uri=(address removed)');
    final words = cut.replaceAll(RegExp(r'\b(address|port|errno|uri)\s*=\s*\S*'), '');
    return RegExp(r'["{}&]|\S=\S').hasMatch(words) ? 'The system message was left out because it quoted what was sent.' : cut;
  }

  static bool _retryable(int status) => status == 429 || status == 502 || status == 503 || status == 504;

  /// The server says it did not act on the request, so re-sending is safe.
  static bool _notProcessed(NeforumResponse r) => r.statusCode == 503 || (r.statusCode == 429 && r.retryAfter != null);

  static bool _gatewayError(NeforumResponse r) => r.statusCode == 502 || r.statusCode == 504;

  static const _idempotentMethods = {'GET', 'HEAD', 'PUT', 'DELETE', 'OPTIONS'};

  static Duration _backoff(int attempt) => Duration(milliseconds: 500 * (1 << (attempt - 1)));

  static Map<String, String> _lowercase(Map<String, String> h) =>
      {for (final e in h.entries) e.key.toLowerCase(): e.value};
}

/// Bytes of the current attempt handed to the connection.
class _UploadMeter {
  int sent = 0;
  int total = 0;
}

/// A request whose body is a stream read only as the connection sends it
/// (see [NeforumHttp._sendWatched]).
class _WatchedRequest extends http.BaseRequest with http.Abortable {
  _WatchedRequest(super.method, super.url, this._body, {this.abortTrigger});

  final Stream<List<int>> _body;

  @override
  final Future<void>? abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_body);
  }
}

Duration? _parseRetryAfter(String? v) {
  if (v == null) return null;
  final secs = int.tryParse(v.trim());
  if (secs != null) return Duration(seconds: secs);
  try {
    final when = parseHttpDate(v);
    final d = when.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  } on Object {
    return null;
  }
}

MediaType? _mediaType(String contentType) {
  try {
    return MediaType.parse(contentType);
  } on FormatException {
    return null;
  }
}
