import 'dart:async';

import 'package:http/http.dart' as http;

import '../../http/neforum_http.dart';
import '../../model/media.dart';
import '../../model/publish_result.dart';
import '../platform_adapter.dart';

/// Upload timeout for media files (the default request timeout is 60 s).
const Duration blogUploadTimeout = Duration(minutes: 5);

/// Non-empty string or `null`.
String? blogStr(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

/// Integer from a number or numeric string.
int? blogInt(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v.trim()) : null);

/// Typed map view of a decoded JSON value (empty when it is not a map).
Map<String, dynamic> blogMap(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

/// Typed list view of a decoded JSON value (empty when it is not a list).
List<Object?> blogList(Object? v) => v is List ? List<Object?>.from(v) : const <Object?>[];

/// Strings from a value that may be a single string or a list of strings.
List<String> blogStrings(Object? v) {
  if (v is String) {
    return v.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }
  return blogList(v).map(blogStr).whereType<String>().toList();
}

/// Truncates [s] for error messages.
String blogSnippet(String s, [int max = 600]) => s.length > max ? '${s.substring(0, max)}…' : s;

/// A file name for [m] when it has none.
String blogFileName(MediaAttachment m) {
  final name = m.fileName;
  if (name != null && name.isNotEmpty) return name;
  final sub = m.mimeType.split('/').last;
  final ext = switch (sub) {
    'jpeg' => 'jpg',
    'quicktime' => 'mov',
    _ => sub,
  };
  return '${m.id}.$ext';
}

/// Appends Markdown image embeds for [urls] (with the matching alt texts) to
/// [markdown].
String appendMarkdownImages(String markdown, List<String> urls, List<String?> alts) {
  if (urls.isEmpty) return markdown;
  final lines = <String>[];
  for (var i = 0; i < urls.length; i++) {
    final alt = (i < alts.length ? alts[i] : null)?.replaceAll(RegExp(r'[\[\]\n\r]'), ' ').trim() ?? '';
    lines.add('![$alt](${urls[i]})');
  }
  final body = markdown.trimRight();
  return body.isEmpty ? lines.join('\n\n') : '$body\n\n${lines.join('\n\n')}';
}

/// Runs [body] and converts expected transport failures into
/// [AdapterException]s. [mapHttp] refines non-2xx responses.
Future<T> guardBlog<T>(
  String context,
  Future<T> Function() body, {
  required PublishError Function(HttpFailure f) mapHttp,
}) async {
  try {
    return await body();
  } on AdapterException {
    rethrow;
  } on HttpFailure catch (f) {
    throw AdapterException(mapHttp(f));
  } on TimeoutException catch (e) {
    throw AdapterException(PublishError.network('$context: timed out', raw: '$e'));
  } on http.ClientException catch (e) {
    throw AdapterException(PublishError.network('$context: network error', raw: e.message));
  } on FormatException catch (e) {
    throw AdapterException(PublishError.platform('$context: unexpected response', raw: e.message));
  }
}

/// Quotes a value for a YAML front-matter line.
String yamlQuote(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', ' ')}"';
