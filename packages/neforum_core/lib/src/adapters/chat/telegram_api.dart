import 'dart:convert';

import '../../http/neforum_http.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import 'chat_common.dart';

/// Telegram Bot API base. The token is part of the path
/// (`https://api.telegram.org/bot<token>/<method>`).
const String telegramApiBase = 'https://api.telegram.org';

/// An `{ok: false}` answer from the Bot API.
class TelegramApiError implements Exception {
  const TelegramApiError({
    required this.method,
    required this.statusCode,
    required this.description,
    this.errorCode,
    this.retryAfter,
    this.migrateToChatId,
    this.raw = '',
  });

  final String method;
  final int statusCode;
  final int? errorCode;
  final String description;
  final Duration? retryAfter;
  final String? migrateToChatId;
  final String raw;

  int get code => errorCode ?? statusCode;

  /// Maps the error onto a [PublishError] kind.
  PublishError toPublishError() {
    final d = description.toLowerCase();
    final snippet = chatSnippet(raw);
    final where = 'Telegram $method';
    if (code == 429 || retryAfter != null) {
      return PublishError.quota('$where: flood limit, wait ${retryAfter?.inSeconds ?? '?'} s ($description)',
          raw: snippet, statusCode: code, retryAfter: retryAfter);
    }
    if (migrateToChatId != null) {
      return PublishError(
          kind: PublishErrorKind.configuration,
          message: 'The group was upgraded to a supergroup ($migrateToChatId). Reconnect it in NEFORUM.',
          raw: snippet,
          statusCode: code);
    }
    if (code == 401 || d.contains('unauthorized')) {
      return PublishError.auth('The bot token was rejected (revoked in @BotFather?). Reconnect with a new token.',
          raw: snippet, statusCode: code);
    }
    if (code == 403 ||
        d.contains('administrator rights') ||
        d.contains('not enough rights') ||
        d.contains('have no rights') ||
        d.contains('bot is not a member')) {
      return PublishError.auth(
          'The bot may not post here ($description). Add it as an administrator with "Post Messages".',
          raw: snippet,
          statusCode: code);
    }
    if (d.contains('chat not found')) {
      return PublishError(
          kind: PublishErrorKind.configuration,
          message: 'Telegram cannot find the chat. Check the chat id and that the bot was added to it.',
          raw: snippet,
          statusCode: code);
    }
    if (code == 413 || d.contains('too big') || d.contains('too large')) {
      return PublishError.validation('$where: file too large ($description)', raw: snippet, statusCode: code);
    }
    if (code >= 500) {
      return PublishError.network('$where: Telegram server error $code', raw: snippet, statusCode: code);
    }
    if (code == 400) return PublishError.validation('$where: $description', raw: snippet, statusCode: code);
    return PublishError.platform('$where: $description', raw: snippet, statusCode: code);
  }

  @override
  String toString() => 'TelegramApiError($method $code: $description)';
}

/// Minimal Bot API client. Never put the URL in an error message: it
/// contains the token.
class TelegramApi {
  TelegramApi(this._token, this._ctx);

  final String _token;
  final AdapterContext _ctx;

  Uri url(String method) => Uri.parse('$telegramApiBase/bot$_token/$method');

  /// GET with query parameters (getMe, getChat, getChatMember).
  Future<Object?> get(String method, [Map<String, String> query = const {}]) async {
    final u = url(method);
    final res = await _ctx.http.get(query.isEmpty ? u : u.replace(queryParameters: query), throwOnError: false);
    return _result(method, res);
  }

  /// POST with a JSON body (sendMessage).
  Future<Object?> postJson(String method, Map<String, Object?> body) async {
    final res = await _ctx.http.postJson(url(method), body, throwOnError: false);
    return _result(method, res);
  }

  /// POST multipart/form-data (sendPhoto, sendVideo, sendAnimation,
  /// sendMediaGroup).
  Future<Object?> multipart(String method, Map<String, String> fields, List<HttpFilePart> files) async {
    final res = await _ctx.http.multipart(url(method), fields: fields, files: files, throwOnError: false);
    return _result(method, res);
  }

  Object? _result(String method, NeforumResponse res) {
    final json = res.json;
    if (json is Map && json['ok'] == true) return json['result'];
    final map = json is Map ? json : const <Object?, Object?>{};
    final params = map['parameters'];
    final retry = params is Map ? chatInt(params['retry_after']) : null;
    final migrate = params is Map ? chatId(params['migrate_to_chat_id']) : null;
    throw TelegramApiError(
      method: method,
      statusCode: res.statusCode,
      errorCode: chatInt(map['error_code']),
      description: chatStr(map['description']) ?? 'HTTP ${res.statusCode}',
      retryAfter: retry != null ? Duration(seconds: retry) : res.retryAfter,
      migrateToChatId: migrate,
      raw: res.body,
    );
  }
}

/// Encodes a value for a multipart field (objects and arrays as JSON).
String telegramField(Object value) => value is String ? value : jsonEncode(value);
