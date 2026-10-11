import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../model/publish_result.dart';
import '../util/logger.dart';
import 'transient_stub.dart' if (dart.library.io) 'transient_io.dart';

const String neforumVersion = '0.1.0';
const String defaultUserAgent = 'NEFORUM/$neforumVersion (+https://github.com/neforum-app/neforum)';

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
    Logger? log,
  })  : _client = client ?? http.Client(),
        _log = log ?? Logger('http');

  final http.Client _client;
  final String userAgent;
  final int maxRetries;
  final Duration timeout;
  final Logger _log;

  void close() => _client.close();

  Future<NeforumResponse> get(Uri url, {Map<String, String>? headers, bool throwOnError = true}) =>
      send('GET', url, headers: headers, throwOnError: throwOnError);

  Future<NeforumResponse> delete(Uri url, {Map<String, String>? headers, bool throwOnError = true}) =>
      send('DELETE', url, headers: headers, throwOnError: throwOnError);

  Future<NeforumResponse> postJson(Uri url, Object? json,
          {Map<String, String>? headers, bool throwOnError = true, String method = 'POST'}) =>
      send(method, url, headers: headers, jsonBody: json, throwOnError: throwOnError);

  Future<NeforumResponse> postForm(Uri url, Map<String, String> form,
          {Map<String, String>? headers, bool throwOnError = true, String method = 'POST'}) =>
      send(method, url, headers: headers, form: form, throwOnError: throwOnError);

  Future<NeforumResponse> multipart(
    Uri url, {
    Map<String, String> fields = const {},
    List<HttpFilePart> files = const [],
    Map<String, String>? headers,
    bool throwOnError = true,
    String method = 'POST',
  }) =>
      send(method, url, headers: headers, fields: fields, files: files, throwOnError: throwOnError);

  /// Sends raw bytes (used for S3 presigned PUTs, chunked uploads, ...).
  Future<NeforumResponse> putBytes(Uri url, Uint8List bytes,
          {Map<String, String>? headers, bool throwOnError = true, String method = 'PUT'}) =>
      send(method, url, headers: headers, bytes: bytes, throwOnError: throwOnError);

  Future<Uint8List> download(Uri url, {Map<String, String>? headers}) async {
    final r = await send('GET', url, headers: headers);
    return r.bodyBytes;
  }

  Future<NeforumResponse> send(
    String method,
    Uri url, {
    Map<String, String>? headers,
    Object? jsonBody,
    Map<String, String>? form,
    Map<String, String>? fields,
    List<HttpFilePart>? files,
    Uint8List? bytes,
    bool throwOnError = true,
    Duration? timeout,
  }) async {
    // Uploads: give the body time to travel (assume a slow 150 KB/s uplink)
    // and never re-send a big body automatically after a timeout or a
    // dropped connection; the caller decides whether to retry.
    final bodySize = (bytes?.length ?? 0) + (files ?? const <HttpFilePart>[]).fold<int>(0, (s, f) => s + f.bytes.length);
    final base = timeout ?? this.timeout;
    final effectiveTimeout = bodySize > 512 * 1024 ? _uploadTimeout(bodySize, base) : base;
    final retries = bodySize > 8 * 1024 * 1024 ? 0 : maxRetries;
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        final req = _build(method, url, headers, jsonBody, form, fields, files, bytes);
        _log.debug('$method $url (attempt $attempt)');
        final streamed = await _client.send(req).timeout(effectiveTimeout);
        final res = await http.Response.fromStream(streamed).timeout(effectiveTimeout);
        final out = NeforumResponse(res.statusCode, _lowercase(res.headers), res.bodyBytes, url);
        if (!out.ok && _retryable(out.statusCode) && attempt <= retries) {
          final wait = out.retryAfter ?? _backoff(attempt);
          if (wait <= const Duration(seconds: 30)) {
            _log.warn('HTTP ${out.statusCode} from ${url.host}; retrying in ${wait.inSeconds}s');
            await Future<void>.delayed(wait);
            continue;
          }
        }
        if (!out.ok && throwOnError) throw HttpFailure(out);
        return out;
      } on HttpFailure {
        rethrow;
      } on Object catch (e) {
        final transient = e is TimeoutException || e is http.ClientException || isTransientIoError(e);
        if (transient && attempt <= retries) {
          final wait = _backoff(attempt);
          _log.warn('Network error calling ${url.host} ($e); retrying in ${wait.inSeconds}s');
          await Future<void>.delayed(wait);
          continue;
        }
        rethrow;
      }
    }
  }

  http.BaseRequest _build(
    String method,
    Uri url,
    Map<String, String>? headers,
    Object? jsonBody,
    Map<String, String>? form,
    Map<String, String>? fields,
    List<HttpFilePart>? files,
    Uint8List? bytes,
  ) {
    final h = <String, String>{'User-Agent': userAgent, ...?headers};
    if (files != null || fields != null) {
      final req = http.MultipartRequest(method, url)..headers.addAll(h);
      if (fields != null) req.fields.addAll(fields);
      for (final f in files ?? const <HttpFilePart>[]) {
        req.files.add(http.MultipartFile.fromBytes(f.field, f.bytes,
            filename: f.fileName, contentType: _mediaType(f.contentType)));
      }
      return req;
    }
    final req = http.Request(method, url)..headers.addAll(h);
    if (jsonBody != null) {
      req.headers.putIfAbsent('Content-Type', () => 'application/json; charset=utf-8');
      req.body = jsonEncode(jsonBody);
    } else if (form != null) {
      req.headers.putIfAbsent('Content-Type', () => 'application/x-www-form-urlencoded; charset=utf-8');
      req.bodyFields = form;
    } else if (bytes != null) {
      req.headers.putIfAbsent('Content-Type', () => 'application/octet-stream');
      req.bodyBytes = bytes;
    }
    return req;
  }

  /// Time budget for sending [bytes]: the base timeout plus the time a
  /// 150 KB/s uplink needs, capped at 45 minutes.
  static Duration _uploadTimeout(int bytes, Duration base) {
    final transfer = Duration(seconds: (bytes / (150 * 1024)).ceil());
    final total = base + transfer;
    const cap = Duration(minutes: 45);
    return total > cap ? cap : total;
  }

  /// True for errors that mean "the network failed", not "the server said no".
  static bool isTransportError(Object e) => e is TimeoutException || e is http.ClientException || isTransientIoError(e);

  static bool _retryable(int status) => status == 429 || status == 502 || status == 503 || status == 504;

  static Duration _backoff(int attempt) => Duration(milliseconds: 500 * (1 << (attempt - 1)));

  static Map<String, String> _lowercase(Map<String, String> h) =>
      {for (final e in h.entries) e.key.toLowerCase(): e.value};
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
