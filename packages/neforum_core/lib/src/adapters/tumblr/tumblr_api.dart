import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../http/neforum_http.dart';
import '../../model/media.dart';
import '../../model/publish_result.dart';
import '../../text/url_detector.dart';

/// Endpoints, Neue Post Format (NPF) builders, the multipart encoder and
/// error mapping for the Tumblr API v2 (`https://api.tumblr.com/v2`).
///
/// Sources: tumblr/docs `api.md` (OAuth 2, rate limits, NPF create route,
/// error subcodes) and `npf-spec.md` (block shapes and content limits).
class TumblrApi {
  TumblrApi._();

  static final Uri authorizationEndpoint = Uri.parse('https://www.tumblr.com/oauth2/authorize');
  static final Uri tokenEndpoint = Uri.parse('https://api.tumblr.com/v2/oauth2/token');
  static final Uri userInfoEndpoint = Uri.parse('https://api.tumblr.com/v2/user/info');

  /// `offline_access` is what makes Tumblr return a refresh token.
  static const List<String> scopes = ['basic', 'write', 'offline_access'];

  /// POST target for new NPF posts. [blog] is a blog name, hostname or
  /// `t:...` uuid.
  static Uri postsEndpoint(String blog) => Uri.https('api.tumblr.com', '/v2/blog/$blog/posts');

  /// `POST /v2/blog/{blog-identifier}/post/delete` with the form field `id`
  /// (api.md "/post/delete – Delete a Post"; answers 200 OK).
  static Uri deleteEndpoint(String blog) => Uri.https('api.tumblr.com', '/v2/blog/$blog/post/delete');

  /// Public permalink. Tumblr's API only returns the id, so the URL is built
  /// client-side.
  static String postUrl(String blogName, String id) => 'https://$blogName.tumblr.com/post/$id';

  /// The blog's front page.
  static String blogUrl(String blogName) => 'https://$blogName.tumblr.com/';

  /// The shortest lead NEFORUM hands to Tumblr's scheduler. `publish_on`
  /// must be a future time when Tumblr receives the request (api.md: "The
  /// exact _future_ date and time"), so the upload must finish before it.
  static const Duration minScheduleLead = Duration(minutes: 5);

  /// [minScheduleLead] plus the time [uploadBytes] need on a slow
  /// (150 KB/s) uplink, the same assumption NeforumHttp makes for uploads.
  static Duration scheduleLead(int uploadBytes) =>
      minScheduleLead + Duration(seconds: (uploadBytes / (150 * 1024)).ceil());

  /// Square avatar of a blog (public endpoint that redirects to the image).
  static String avatarUrl(String blogName) => 'https://api.tumblr.com/v2/blog/$blogName/avatar/128';

  // NPF content limits (npf-spec.md "Post Content Limits").
  static const int maxTextBlockCodePoints = 4096;
  static const int maxBlocks = 1000;
  static const int maxInlineLinks = 100;
  static const int maxAltText = 4096;

  /// The states the create route accepts for an original post.
  static const Set<String> states = {'published', 'queue', 'draft', 'private'};

  // ------------------------------------------------------------- NPF text

  /// Turns plain text into NPF text blocks: one block per non-empty line,
  /// lines longer than 4,096 code points split at a space. URLs get `link`
  /// formatting (code-point offsets) until [linkBudget] runs out.
  static List<Map<String, Object?>> textBlocks(String text, {LinkBudget? linkBudget}) {
    final budget = linkBudget ?? LinkBudget();
    final out = <Map<String, Object?>>[];
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trimRight();
      if (trimmed.trim().isEmpty) continue;
      for (final chunk in splitCodePoints(trimmed, maxTextBlockCodePoints)) {
        out.add(textBlock(chunk, linkBudget: budget));
      }
    }
    return out;
  }

  static Map<String, Object?> textBlock(String text, {String? subtype, LinkBudget? linkBudget}) {
    final formatting = <Map<String, Object?>>[];
    if (linkBudget != null) {
      for (final url in UrlDetector.find(text)) {
        if (!linkBudget.take()) break;
        formatting.add({
          'start': text.substring(0, url.start).runes.length,
          'end': text.substring(0, url.end).runes.length,
          'type': 'link',
          'url': url.normalized,
        });
      }
    }
    return {
      'type': 'text',
      if (subtype != null) 'subtype': subtype,
      'text': text,
      if (formatting.isNotEmpty) 'formatting': formatting,
    };
  }

  /// Splits [s] into chunks of at most [max] Unicode code points, preferring
  /// the last whitespace inside the window.
  static List<String> splitCodePoints(String s, int max) {
    final runes = s.runes.toList();
    if (runes.length <= max) return [s];
    final out = <String>[];
    var start = 0;
    while (runes.length - start > max) {
      var cut = start + max;
      for (var i = cut; i > start + max ~/ 2; i--) {
        if (_isSpace(runes[i])) {
          cut = i;
          break;
        }
      }
      out.add(String.fromCharCodes(runes.sublist(start, cut)).trimRight());
      start = cut;
      while (start < runes.length && _isSpace(runes[start])) {
        start++;
      }
    }
    if (start < runes.length) out.add(String.fromCharCodes(runes.sublist(start)));
    return out.where((c) => c.isNotEmpty).toList();
  }

  static bool _isSpace(int r) => r == 0x20 || r == 0x09 || r == 0xA0 || r == 0x3000;

  /// How many text blocks [text] will become (for validation).
  static int countTextBlocks(String text) => textBlocks(text).length;

  /// Number of URLs in [text] that would get link formatting.
  static int countLinks(String text) => UrlDetector.find(text).length;

  // ------------------------------------------------------------ NPF media

  /// Image block; `media` is an ARRAY for images.
  static Map<String, Object?> imageBlock(MediaAttachment m, String identifier) {
    final alt = m.altText?.trim();
    return {
      'type': 'image',
      'media': [_mediaObject(m, identifier)],
      if (alt != null && alt.isNotEmpty) 'alt_text': alt,
    };
  }

  /// Video block; `media` is a single OBJECT for video (an array gives a
  /// 400, tumblr/docs #88).
  static Map<String, Object?> videoBlock(MediaAttachment m, String identifier) => {
        'type': 'video',
        'media': _mediaObject(m, identifier),
      };

  static Map<String, Object?> _mediaObject(MediaAttachment m, String identifier) => {
        'type': m.mimeType,
        'identifier': identifier,
        if (m.width != null) 'width': m.width,
        if (m.height != null) 'height': m.height,
      };

  static Map<String, Object?> linkBlock(String url, {String? title, String? description}) => {
        'type': 'link',
        'url': url,
        if (title != null && title.isNotEmpty) 'title': title,
        if (description != null && description.isNotEmpty) 'description': description,
      };

  /// Tags as ONE comma-separated string (an array is rejected with 400.8001).
  /// Commas inside a tag are impossible on Tumblr, so they become spaces.
  static String? tagsField(List<String> tags) {
    final clean = <String>[];
    for (final t in tags) {
      final v = t.replaceAll(',', ' ').replaceFirst(RegExp(r'^#+'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (v.isNotEmpty && !clean.any((c) => c.toLowerCase() == v.toLowerCase())) clean.add(v);
    }
    return clean.isEmpty ? null : clean.join(',');
  }

  // ------------------------------------------------------------ multipart

  /// Builds the multipart body Tumblr expects for NPF uploads: the first part
  /// is `name="json"` with `Content-Type: application/json`, followed by one
  /// file part per media block whose form name equals the block's
  /// `identifier`. Hand-built because `package:http` cannot give a non-file
  /// part its own content type.
  static TumblrMultipart multipart(Map<String, Object?> json, List<TumblrUpload> files, {String? boundary}) {
    final b = boundary ?? _boundary();
    final out = BytesBuilder(copy: false);
    void write(String s) => out.add(utf8.encode(s));
    write('--$b\r\nContent-Disposition: form-data; name="json"\r\nContent-Type: application/json\r\n\r\n');
    write(jsonEncode(json));
    write('\r\n');
    for (final f in files) {
      write('--$b\r\nContent-Disposition: form-data; name="${f.identifier}"; filename="${safeFileName(f.fileName)}"\r\n'
          'Content-Type: ${f.contentType}\r\n\r\n');
      out.add(f.bytes);
      write('\r\n');
    }
    write('--$b--\r\n');
    return TumblrMultipart(out.takeBytes(), 'multipart/form-data; boundary=$b');
  }

  /// ASCII-only file name safe for a Content-Disposition header.
  static String safeFileName(String name) {
    final s = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return s.isEmpty ? 'upload' : s;
  }

  static String _boundary() {
    final r = Random.secure();
    return 'neforum-${List<int>.generate(16, (_) => r.nextInt(256)).map((x) => x.toRadixString(16).padLeft(2, '0')).join()}';
  }

  // ------------------------------------------------------------ responses

  /// Extracts the new post id (a STRING in Tumblr's response).
  static String? createdId(NeforumResponse res) {
    final response = res.jsonMap['response'];
    if (response is! Map) return null;
    final id = response['id_string'] ?? response['id'];
    if (id == null) return null;
    final s = '$id';
    return s.isEmpty ? null : s;
  }

  /// Tumblr error subcodes (`errors[].code`) from a failure body.
  static List<int> errorCodes(Map<String, dynamic> body) {
    final errors = body['errors'];
    if (errors is! List) return const [];
    final out = <int>[];
    for (final e in errors) {
      if (e is! Map) continue;
      final c = e['code'];
      final n = c is int ? c : int.tryParse('$c');
      if (n != null) out.add(n);
    }
    return out;
  }

  static String? errorText(Map<String, dynamic> body) {
    final errors = body['errors'];
    if (errors is List) {
      final parts = <String>[];
      for (final e in errors) {
        if (e is! Map) continue;
        final t = [e['title'], e['detail']].whereType<String>().where((s) => s.isNotEmpty).join(': ');
        if (t.isNotEmpty) parts.add(t);
      }
      if (parts.isNotEmpty) return parts.join('; ');
    }
    final meta = body['meta'];
    if (meta is Map && meta['msg'] is String) return meta['msg'] as String;
    return null;
  }

  /// Maps a failed API call onto a [PublishError], refining the generic
  /// HTTP mapping with Tumblr's documented subcodes.
  static PublishError mapFailure(HttpFailure f, String context) {
    final base = f.toPublishError(context: context);
    final body = f.response.jsonMap;
    final codes = errorCodes(body);
    final detail = errorText(body);
    final suffix = detail == null ? '' : ' ($detail)';
    final raw = base.raw;
    final status = f.statusCode;

    if (codes.contains(8023)) {
      return PublishError.quota('Tumblr\'s daily posting limit for this blog is reached (250 posts a day)$suffix',
          raw: raw, statusCode: status, retryAfter: const Duration(hours: 24));
    }
    if (codes.contains(8022)) {
      return PublishError.quota('This blog\'s queue is full; publish or delete queued posts first$suffix',
          raw: raw, statusCode: status);
    }
    if (codes.contains(8004)) {
      return PublishError.quota('Tumblr\'s daily media upload limit is reached (250 images a day)$suffix',
          raw: raw, statusCode: status, retryAfter: const Duration(hours: 24));
    }
    if (codes.contains(8011)) {
      return PublishError.quota('Tumblr\'s daily video limit is reached (20 videos or 60 minutes a day)$suffix',
          raw: raw, statusCode: status, retryAfter: const Duration(hours: 24));
    }
    if (codes.contains(8010)) {
      return PublishError(
        kind: PublishErrorKind.platform,
        message: 'Tumblr is still processing your previous video; try again in a few minutes$suffix',
        retryable: true,
        retryAfter: const Duration(minutes: 5),
        raw: raw,
        statusCode: status,
      );
    }
    if (codes.contains(8008)) {
      return PublishError.validation('Tumblr does not allow videos in reblogs$suffix', raw: raw, statusCode: status);
    }
    if (codes.contains(8005)) {
      return PublishError.validation('Tumblr cannot accept this media format$suffix', raw: raw, statusCode: status);
    }
    if (codes.contains(8001) || codes.contains(8016)) {
      return PublishError.validation('Tumblr rejected the post content$suffix', raw: raw, statusCode: status);
    }
    if (codes.contains(8006) || codes.contains(8009)) {
      return PublishError.network('Tumblr had an upload error; try again$suffix',
          raw: raw, statusCode: status, retryAfter: f.response.retryAfter);
    }

    switch (status) {
      case 401:
        return PublishError.auth('Tumblr sign-in expired or was revoked; reconnect Tumblr in Accounts$suffix',
            raw: raw, statusCode: status);
      case 403:
        return PublishError.auth('Tumblr refused: you may not post to this blog with this sign-in$suffix',
            raw: raw, statusCode: status);
      case 404:
        return PublishError.configuration(
            'Tumblr could not find this blog (renamed or deleted?); reconnect Tumblr and pick the blog again$suffix');
      case 429:
        return PublishError.quota('Tumblr rate limit reached$suffix',
            raw: raw, statusCode: status, retryAfter: _rateLimitWait(f.response));
      case 400:
        if (codes.contains(0)) {
          // Undocumented "Tumblr went thud. Try again." (tumblr/docs #129).
          return PublishError.network('Tumblr had a temporary problem; try again$suffix', raw: raw, statusCode: status);
        }
        return PublishError.validation('Tumblr rejected the post$suffix', raw: raw, statusCode: status);
      case 503:
        return PublishError.network('Tumblr posting is temporarily unavailable$suffix',
            raw: raw, statusCode: status, retryAfter: f.response.retryAfter);
    }
    return detail == null
        ? base
        : PublishError(
            kind: base.kind,
            message: '${base.message}$suffix',
            retryable: base.retryable,
            retryAfter: base.retryAfter,
            raw: raw,
            statusCode: status,
          );
  }

  /// Retry-After when present; otherwise guess from the per-key headers
  /// (1 hour when the hourly budget is spent, else a minute for the per-IP
  /// per-minute limit).
  static Duration _rateLimitWait(NeforumResponse r) {
    final explicit = r.retryAfter;
    if (explicit != null) return explicit;
    if (r.headers['x-ratelimit-perday-remaining']?.trim() == '0') return const Duration(hours: 24);
    if (r.headers['x-ratelimit-perhour-remaining']?.trim() == '0') return const Duration(hours: 1);
    return const Duration(minutes: 1);
  }
}

/// Counts down the 100 inline links NPF allows per post.
class LinkBudget {
  LinkBudget([this.remaining = TumblrApi.maxInlineLinks]);
  int remaining;

  bool take() {
    if (remaining <= 0) return false;
    remaining--;
    return true;
  }
}

/// One file part of an NPF upload.
class TumblrUpload {
  const TumblrUpload({
    required this.identifier,
    required this.bytes,
    required this.fileName,
    required this.contentType,
  });

  final String identifier;
  final Uint8List bytes;
  final String fileName;
  final String contentType;
}

/// A ready-to-send multipart body plus its Content-Type header value.
class TumblrMultipart {
  const TumblrMultipart(this.body, this.contentType);
  final Uint8List body;
  final String contentType;
}
