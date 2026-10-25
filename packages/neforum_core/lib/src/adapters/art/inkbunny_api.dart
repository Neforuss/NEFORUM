import 'dart:typed_data';

import '../../http/neforum_http.dart';
import '../../model/media.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import 'art_api_common.dart';

/// A signed-in Inkbunny session (from `api_login.php`).
class InkbunnySession {
  const InkbunnySession({required this.sid, this.userId});
  final String sid;
  final String? userId;
}

/// An error Inkbunny reported in its JSON (`error_code`, `error_message`).
class InkbunnyException implements Exception {
  const InkbunnyException(this.message, {this.code});
  final String message;
  final int? code;

  /// The session id is no longer valid: the user must sign in again.
  bool get invalidSession => code == InkbunnyApi.errorInvalidSession;

  /// Too many submissions in the last hour.
  bool get hourlyLimit => code == InkbunnyApi.errorHourlyLimit;

  @override
  String toString() => 'InkbunnyException($code: $message)';
}

/// Thin client for Inkbunny's API (wiki.inkbunny.net/wiki/API, read
/// 2026-10-25). Every call answers JSON; failures carry `error_code` and
/// `error_message`.
class InkbunnyApi {
  InkbunnyApi(this.ctx);

  static final Uri loginEndpoint = Uri.parse('https://inkbunny.net/api_login.php');
  static final Uri logoutEndpoint = Uri.parse('https://inkbunny.net/api_logout.php');
  static final Uri uploadEndpoint = Uri.parse('https://inkbunny.net/api_upload.php');
  static final Uri editEndpoint = Uri.parse('https://inkbunny.net/api_editsubmission.php');

  /// `error_code` of a session id that is not (or no longer) valid.
  static const int errorInvalidSession = 2;

  /// `error_code` of the hourly submission limit.
  static const int errorHourlyLimit = 6;

  final AdapterContext ctx;

  static String submissionUrl(String id) => 'https://inkbunny.net/s/$id';

  /// Signs in once. The username and password travel in the POST body, never
  /// in the address.
  Future<InkbunnySession> login(String username, String password) async {
    final res = await ctx.http.postForm(loginEndpoint, {'username': username, 'password': password},
        headers: const {'Accept': 'application/json'}, throwOnError: false);
    final j = _checked(res);
    final sid = '${j['sid'] ?? ''}';
    if (sid.isEmpty) throw const InkbunnyException('Inkbunny returned no session');
    return InkbunnySession(sid: sid, userId: j['user_id']?.toString());
  }

  /// `api_upload.php`: one new (not yet public) submission with every file.
  /// Returns its id.
  Future<String> upload(String sid, List<(MediaAttachment, Uint8List)> files) async {
    final body = MultipartBody()..field('sid', sid);
    for (final (media, bytes) in files) {
      body.file('uploadedfile[]', bytes, fileName: media.fileName ?? 'artwork', contentType: media.mimeType);
    }
    final res = await ctx.http.send(
      'POST',
      uploadEndpoint,
      headers: {'Accept': 'application/json', 'Content-Type': body.contentType},
      bytes: body.bytes,
      throwOnError: false,
    );
    final id = '${_checked(res)['submission_id'] ?? ''}';
    if (id.isEmpty) throw const InkbunnyException('Inkbunny accepted the files but returned no submission');
    return id;
  }

  /// `api_editsubmission.php`: the details of submission `submission_id`
  /// in [form], and whether it is public.
  Future<void> edit(Map<String, String> form) async {
    final res = await ctx.http.postForm(editEndpoint, form, headers: const {'Accept': 'application/json'}, throwOnError: false);
    _checked(res);
  }

  /// `api_logout.php` (best effort).
  Future<void> logout(String sid) async {
    await ctx.http.postForm(logoutEndpoint, {'sid': sid}, headers: const {'Accept': 'application/json'}, throwOnError: false);
  }

  /// The JSON body, or [InkbunnyException] when it reports an error. A
  /// non-JSON answer with an error status becomes [HttpFailure].
  static Map<String, dynamic> _checked(NeforumResponse res) {
    final j = res.jsonMap;
    if (j.containsKey('error_code')) {
      final code = j['error_code'] is int ? j['error_code'] as int : int.tryParse('${j['error_code']}');
      throw InkbunnyException('${j['error_message'] ?? 'Inkbunny refused the request'}', code: code);
    }
    if (!res.ok) throw HttpFailure(res);
    return j;
  }

  /// The [PublishError] for an Inkbunny error.
  static PublishError mapError(InkbunnyException e, {String? context}) {
    final prefix = context == null ? '' : '$context: ';
    if (e.invalidSession) {
      return PublishError.auth('${prefix}Inkbunny ended the sign-in (${e.message}). Reconnect Inkbunny in Accounts.',
          raw: e.toString());
    }
    if (e.hourlyLimit) {
      return PublishError.quota('${prefix}Inkbunny allows only so many submissions an hour (${e.message}); NEFORUM tries '
          'again later', raw: e.toString(), retryAfter: const Duration(hours: 1));
    }
    return PublishError.platform('$prefix${e.message}', raw: e.toString());
  }
}
