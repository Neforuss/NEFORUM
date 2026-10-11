import 'dart:typed_data';

import '../../http/neforum_http.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import 'chat_common.dart';

/// A Matrix error answer (`{errcode, error}`).
class MatrixApiError implements Exception {
  const MatrixApiError({
    required this.statusCode,
    this.errcode,
    this.error,
    this.retryAfter,
    this.softLogout = false,
    this.raw = '',
  });

  final int statusCode;
  final String? errcode;
  final String? error;
  final Duration? retryAfter;
  final bool softLogout;
  final String raw;

  String get message => error ?? errcode ?? 'HTTP $statusCode';

  /// Maps the error onto a [PublishError] kind.
  PublishError toPublishError(String where) {
    final snippet = chatSnippet(raw);
    switch (errcode) {
      case 'M_UNKNOWN_TOKEN':
      case 'M_MISSING_TOKEN':
        return PublishError.auth('$where: the homeserver no longer accepts this login${softLogout ? ' (session expired)' : ''}. '
            'Reconnect the account.', raw: snippet, statusCode: statusCode);
      case 'M_FORBIDDEN':
        return PublishError.auth('$where: not allowed ($message). Check that the account may post in this room.',
            raw: snippet, statusCode: statusCode);
      case 'M_LIMIT_EXCEEDED':
        return PublishError.quota('$where: rate limited by the homeserver',
            raw: snippet, statusCode: statusCode, retryAfter: retryAfter);
      case 'M_TOO_LARGE':
        return PublishError.validation('$where: file too large for this homeserver', raw: snippet, statusCode: statusCode);
      case 'M_NOT_FOUND':
        return PublishError(
            kind: PublishErrorKind.configuration,
            message: '$where: room not found ($message). Reconnect the account.',
            raw: snippet,
            statusCode: statusCode);
    }
    if (statusCode == 429) {
      return PublishError.quota('$where: rate limited', raw: snippet, statusCode: statusCode, retryAfter: retryAfter);
    }
    if (statusCode == 401 || statusCode == 403) {
      return PublishError.auth('$where: $message', raw: snippet, statusCode: statusCode);
    }
    if (statusCode == 413) return PublishError.validation('$where: too large', raw: snippet, statusCode: statusCode);
    if (statusCode >= 500) {
      return PublishError.network('$where: homeserver error $statusCode', raw: snippet, statusCode: statusCode);
    }
    if (statusCode == 400) return PublishError.validation('$where: $message', raw: snippet, statusCode: statusCode);
    return PublishError.platform('$where: $message', raw: snippet, statusCode: statusCode);
  }

  @override
  String toString() => 'MatrixApiError($statusCode ${errcode ?? ''}: ${error ?? ''})';
}

/// Raw Client-Server API calls over [AdapterContext.http]. [base] is the
/// homeserver's client base URL (`m.homeserver.base_url`).
class MatrixApi {
  MatrixApi(this.base, this._ctx, {this.token});

  final Uri base;
  final AdapterContext _ctx;
  final String? token;

  /// `{base}/_matrix/<segments…>` with every segment percent-encoded.
  Uri uri(List<String> segments, [Map<String, String>? query]) => base.replace(
        pathSegments: [...base.pathSegments.where((s) => s.isNotEmpty), '_matrix', ...segments],
        queryParameters: query == null || query.isEmpty ? null : query,
      );

  Map<String, String> get _auth => token == null ? const {} : {'Authorization': 'Bearer $token'};

  Future<Map<String, dynamic>> get(List<String> segments, {Map<String, String>? query}) async =>
      _check(await _ctx.http.get(uri(segments, query), headers: _auth, throwOnError: false));

  /// Like [get] but returns `null` on 404 (state lookups, optional endpoints).
  Future<Map<String, dynamic>?> getOptional(List<String> segments) async {
    final res = await _ctx.http.get(uri(segments), headers: _auth, throwOnError: false);
    if (res.statusCode == 404) return null;
    return _check(res);
  }

  Future<Map<String, dynamic>> post(List<String> segments, Map<String, Object?> body,
          {bool auth = true, Map<String, String>? query}) async =>
      _check(await _ctx.http
          .postJson(uri(segments, query), body, headers: auth ? _auth : const {}, throwOnError: false));

  Future<Map<String, dynamic>> put(List<String> segments, Map<String, Object?> body) async =>
      _check(await _ctx.http.postJson(uri(segments), body, headers: _auth, throwOnError: false, method: 'PUT'));

  /// `POST /_matrix/media/v3/upload?filename=` with the raw bytes; returns
  /// the `mxc://` content URI.
  Future<String> upload(Uint8List bytes, {required String contentType, required String fileName}) async {
    final res = await _ctx.http.putBytes(uri(['media', 'v3', 'upload'], {'filename': fileName}), bytes,
        headers: {..._auth, 'Content-Type': contentType}, throwOnError: false, method: 'POST');
    final json = _check(res);
    final mxc = chatStr(json['content_uri']);
    if (mxc == null || !mxc.startsWith('mxc://')) {
      throw MatrixApiError(statusCode: res.statusCode, error: 'upload returned no content_uri', raw: res.body);
    }
    return mxc;
  }

  Map<String, dynamic> _check(NeforumResponse res) {
    final json = res.jsonMap;
    if (res.ok) return json;
    final ms = chatInt(json['retry_after_ms']);
    throw MatrixApiError(
      statusCode: res.statusCode,
      errcode: chatStr(json['errcode']),
      error: chatStr(json['error']),
      // Retry-After header is the current way; retry_after_ms is deprecated.
      retryAfter: res.retryAfter ?? (ms == null ? null : Duration(milliseconds: ms)),
      softLogout: json['soft_logout'] == true,
      raw: res.body,
    );
  }
}

/// `client`, `v3`, … helpers.
List<String> matrixClient(String version, List<String> rest) => ['client', version, ...rest];
