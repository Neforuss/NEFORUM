import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

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
      case 403:
        return PublishError.auth('${prefix}HTTP $statusCode from $where', raw: snippet, statusCode: statusCode);
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

/// Thin wrapper over `package:http` with a NEFORUM user agent, JSON/form/
/// multipart helpers, timeouts and bounded retries for transient failures.
class NeforumHttp {
  NeforumHttp({
    http.Client? client,
    this.userAgent = defaultUserAgent,
    this.maxRetries = 2,
    this.timeout = const Duration(seconds: 60),
    this.uploadStallTimeout = const Duration(seconds: 90),
    Logger? log,
  })  : _client = client ?? http.Client(),
        _log = log ?? Logger('http'),
        cancellation = null,
        _ownsClient = true;

  NeforumHttp._bound(NeforumHttp base, CancellationSignal this.cancellation)
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
  /// big file takes as long as it takes, as long as it keeps moving.
  final Duration uploadStallTimeout;
  final Logger _log;

  /// When set, cancelling it aborts the request in flight and every later
  /// one fails with [OperationCancelledException] (see [withCancellation]).
  final CancellationSignal? cancellation;
  final bool _ownsClient;

  /// The same connection pool, with every request bound to [signal]: the
  /// client is shared by publishing, sync and media hosts, so a publish run
  /// is stopped request by request instead of by closing it.
  NeforumHttp withCancellation(CancellationSignal? signal) =>
      signal == null || identical(signal, cancellation) ? this : NeforumHttp._bound(this, signal);

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
  }) =>
      send(method, url,
          headers: headers, signHeaders: signHeaders, fields: fields, files: files, throwOnError: throwOnError);

  /// Sends raw bytes (used for S3 presigned PUTs, chunked uploads, ...).
  Future<NeforumResponse> putBytes(Uri url, Uint8List bytes,
          {Map<String, String>? headers, HeaderSigner? signHeaders, bool throwOnError = true, String method = 'PUT'}) =>
      send(method, url, headers: headers, signHeaders: signHeaders, bytes: bytes, throwOnError: throwOnError);

  Future<Uint8List> download(Uri url, {Map<String, String>? headers}) async {
    final r = await send('GET', url, headers: headers);
    return r.bodyBytes;
  }

  /// [signHeaders] is called before every attempt, retries included, and its
  /// headers go over [headers]: for signatures that must not be sent twice,
  /// such as OAuth 1.0a's (X and Tumblr refuse a nonce they have seen).
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
  }) async {
    // Uploads are watched instead of timed: they fail only when nothing has
    // been sent for [uploadStallTimeout], or no answer comes after the last
    // byte (a fixed budget failed 3 MB files on a busy 1 Mbit/s uplink). A
    // big body is never re-sent automatically after a timeout or a dropped
    // connection; the caller decides whether to retry.
    final bodySize = (bytes?.length ?? 0) + (files ?? const <HttpFilePart>[]).fold<int>(0, (s, f) => s + f.bytes.length);
    final base = timeout ?? this.timeout;
    final upload = bodySize > 512 * 1024;
    final retries = bodySize > 8 * 1024 * 1024 ? 0 : maxRetries;
    // A POST that may already have been processed (gateway error, dropped
    // connection) is never re-sent here: that could publish twice. The
    // publish service retries the whole target later instead.
    final idempotent = _idempotentMethods.contains(method.toUpperCase()) ||
        (headers?.keys.any((k) => k.toLowerCase() == 'idempotency-key') ?? false);
    final signal = cancellation;
    var attempt = 0;
    while (true) {
      attempt++;
      signal?.throwIfCancelled();
      try {
        final attemptHeaders = signHeaders == null ? headers : {...?headers, ...signHeaders()};
        _log.debug('$method $url (attempt $attempt)');
        final http.Response res;
        if (upload) {
          res = await _unlessCancelled(_sendWatched(method, url, attemptHeaders, fields, files, bytes, base, signal), signal);
        } else {
          final req = _build(method, url, attemptHeaders, jsonBody, form, fields, files, bytes, abortTrigger: signal?.whenCancelled);
          final streamed = await _unlessCancelled(_client.send(req).timeout(base), signal);
          res = await _unlessCancelled(http.Response.fromStream(streamed).timeout(base), signal);
        }
        final out = NeforumResponse(res.statusCode, _lowercase(res.headers), res.bodyBytes, url);
        if (!out.ok && attempt <= retries && (idempotent ? _retryable(out.statusCode) : _notProcessed(out))) {
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
        rethrow;
      } on Object catch (e) {
        // An aborted request surfaces as a ClientException; report it as
        // the cancellation it is, never as a network error to retry.
        if (signal != null && signal.isCancelled) throw const OperationCancelledException();
        final transient = e is TimeoutException || e is http.ClientException || isTransientIoError(e);
        if (transient && idempotent && attempt <= retries) {
          final wait = _backoff(attempt);
          _log.warn('Network error calling ${url.host} ($e); retrying in ${wait.inSeconds}s');
          await _pause(wait, signal);
          continue;
        }
        rethrow;
      }
    }
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
    Object? jsonBody,
    Map<String, String>? form,
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
    if (jsonBody != null) {
      req.headers.putIfAbsent('Content-Type', () => 'application/json; charset=utf-8');
      req.body = jsonEncode(jsonBody);
    } else if (form != null) {
      // The plain type, as browsers and curl send it: the body is
      // percent-encoded ASCII, and TikTok's token endpoint answers "The
      // request parameters are malformed" to `; charset=utf-8`. bodyFields
      // (and body) would add that charset, so set the bytes directly.
      req.headers.putIfAbsent('Content-Type', () => 'application/x-www-form-urlencoded');
      req.bodyBytes = utf8.encode(encodeForm(form));
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
  Future<http.Response> _sendWatched(String method, Uri url, Map<String, String>? headers, Map<String, String>? fields,
      List<HttpFilePart>? files, Uint8List? bytes, Duration base, CancellationSignal? signal) async {
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
    final plain = _build(method, url, headers, null, null, fields, files, bytes);
    final body = _watchedBody(
      plain.finalize(),
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

  static const int _uploadChunk = 64 * 1024;

  /// [source] in pieces of at most [_uploadChunk] bytes, calling [onProgress]
  /// each time the consumer takes one and [onSent] after the last. The
  /// generator waits at each `yield` until the connection wants more, so the
  /// calls follow what is really sent.
  static Stream<List<int>> _watchedBody(Stream<List<int>> source,
      {required void Function() onProgress, required void Function() onSent}) async* {
    await for (final chunk in source) {
      for (var start = 0; start < chunk.length; start += _uploadChunk) {
        final end = start + _uploadChunk < chunk.length ? start + _uploadChunk : chunk.length;
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

  static bool _retryable(int status) => status == 429 || status == 502 || status == 503 || status == 504;

  /// The server says it did not act on the request, so re-sending is safe.
  static bool _notProcessed(NeforumResponse r) => r.statusCode == 503 || (r.statusCode == 429 && r.retryAfter != null);

  static const _idempotentMethods = {'GET', 'HEAD', 'PUT', 'DELETE', 'OPTIONS'};

  static Duration _backoff(int attempt) => Duration(milliseconds: 500 * (1 << (attempt - 1)));

  static Map<String, String> _lowercase(Map<String, String> h) =>
      {for (final e in h.entries) e.key.toLowerCase(): e.value};
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
