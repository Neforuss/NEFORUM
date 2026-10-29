import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import '../../http/neforum_http.dart';
import '../../model/audio.dart';
import '../../model/media.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import '../platform_adapter.dart';
import 'nostr_event.dart';

/// A media file that is now reachable at a public URL, with its NIP-92
/// `imeta` tag.
@immutable
class NostrUploadedMedia {
  const NostrUploadedMedia(this.url, this.imeta);

  final String url;

  /// `["imeta", "url ...", "m ...", ...]`.
  final List<String> imeta;
}

/// Uploads attachments either to the configured NEFORUM media host or to a
/// NIP-96 server (default nostr.build) with NIP-98 auth.
class NostrMediaUploader {
  NostrMediaUploader({
    required this.ctx,
    required this.keys,
    required this.nip96Server,
    required this.createdAt,
    this.pollInterval = const Duration(seconds: 2),
    this.maxPolls = 15,
  });

  final AdapterContext ctx;
  final NostrKeys keys;

  /// Base URL of the NIP-96 server, or empty when only the media host may be
  /// used.
  final String nip96Server;
  final int Function() createdAt;
  final Duration pollInterval;
  final int maxPolls;

  Future<List<NostrUploadedMedia>> uploadAll(List<MediaAttachment> media) async {
    if (media.isEmpty) return const [];
    // Notes are permanent: prefer the account's NIP-96 server (permanent
    // links) and only fall back to the app-wide media host when none is set.
    final host = nip96Server.isEmpty ? ctx.mediaHost : null;
    if (host == null && nip96Server.isEmpty) {
      throw const AdapterException(PublishError.configuration(
          'Nostr notes link to media by URL, so the files must be uploaded somewhere first. '
          'Either set a NIP-96 media server for this account (for example https://nostr.build) '
          'or configure a public media host in NEFORUM settings.'));
    }
    final apiUrl = host == null ? await _discoverApiUrl() : null;
    final out = <NostrUploadedMedia>[];
    for (var i = 0; i < media.length; i++) {
      final m = media[i];
      final label = m.noun;
      final where = host?.name ?? Uri.parse(nip96Server).host;
      ctx.progress('Uploading $label ${i + 1} of ${media.length} to $where');
      final bytes = await ctx.readMedia(m);
      out.add(host != null ? await _viaHost(m, bytes) : await _viaNip96(apiUrl!, m, bytes));
    }
    return out;
  }

  // --- configured media host --------------------------------------------

  Future<NostrUploadedMedia> _viaHost(MediaAttachment m, Uint8List bytes) async {
    final host = ctx.mediaHost!;
    if (host.maxBytes != null && bytes.length > host.maxBytes!) {
      throw AdapterException(PublishError.validation(
          '${m.fileName ?? m.id} is larger than ${host.name} accepts (${host.maxBytes} bytes).'));
    }
    try {
      // Nostr notes are permanent, so the link must not expire.
      final hosted = await host.upload(m, bytes);
      if (hosted.expiresAt != null) {
        try {
          await host.delete(hosted);
        } on Object {
          // Best effort.
        }
        throw AdapterException(PublishError.configuration(
            '${host.name} only makes temporary links, but Nostr notes are permanent. '
            'Set a NIP-96 media server (for example https://nostr.build) on this Nostr account.'));
      }
      final url = hosted.url.toString();
      return NostrUploadedMedia(url, buildImeta(url, m, {'x': sha256.convert(bytes).toString()}));
    } on AdapterException {
      rethrow;
    } on Object catch (e) {
      throw AdapterException(PublishError.network('Upload to ${host.name} failed: $e', raw: '$e'));
    }
  }

  // --- NIP-96 --------------------------------------------------------------

  String get _base => nip96Server.endsWith('/') ? nip96Server.substring(0, nip96Server.length - 1) : nip96Server;

  Future<String> _discoverApiUrl() async {
    var base = _base;
    for (var hop = 0; hop < 2; hop++) {
      final info = await _getJson(Uri.parse('$base/.well-known/nostr/nip96.json'), 'NIP-96 discovery');
      final api = (info['api_url'] as String? ?? '').trim();
      if (api.isNotEmpty) return api;
      final delegated = (info['delegated_to_url'] as String? ?? '').trim();
      if (delegated.isEmpty) break;
      base = delegated.endsWith('/') ? delegated.substring(0, delegated.length - 1) : delegated;
    }
    throw AdapterException(PublishError.configuration(
        '$nip96Server does not look like a NIP-96 media server (no api_url in /.well-known/nostr/nip96.json).'));
  }

  Future<Map<String, dynamic>> _getJson(Uri url, String what, {Map<String, String>? headers}) async {
    try {
      final r = await ctx.http.get(url, headers: {'Accept': 'application/json', ...?headers});
      return r.jsonMap;
    } on HttpFailure catch (f) {
      if (f.statusCode == 404) {
        throw AdapterException(PublishError.configuration('$what failed: ${url.host} has no NIP-96 endpoint (404).'));
      }
      throw AdapterException(mapNip96Failure(f, what));
    } on Object catch (e) {
      throw AdapterException(PublishError.network('$what failed: $e', raw: '$e'));
    }
  }

  /// `Authorization: Nostr <base64(kind 27235 event)>` per NIP-98.
  String nip98Header(String url, String method) {
    final event = keys.sign(
      kind: NostrKind.httpAuth,
      content: '',
      createdAt: createdAt(),
      tags: [
        ['u', url],
        ['method', method],
      ],
    );
    return 'Nostr ${base64.encode(utf8.encode(jsonEncode(event.toJson())))}';
  }

  Future<NostrUploadedMedia> _viaNip96(String apiUrl, MediaAttachment m, Uint8List bytes) async {
    final alt = (m.altText ?? '').trim();
    final NeforumResponse r;
    try {
      r = await ctx.http.multipart(
        Uri.parse(apiUrl),
        headers: {'Authorization': nip98Header(apiUrl, 'POST'), 'Accept': 'application/json'},
        fields: {
          if (alt.isNotEmpty) 'alt': alt,
          if (alt.isNotEmpty) 'caption': alt,
          'size': '${bytes.length}',
          'content_type': m.mimeType,
        },
        files: [
          HttpFilePart(field: 'file', bytes: bytes, fileName: m.fileName ?? m.id, contentType: m.mimeType),
        ],
      );
    } on HttpFailure catch (f) {
      throw AdapterException(mapNip96Failure(f, 'Media upload'));
    } on Object catch (e) {
      throw AdapterException(PublishError.network('Media upload to ${Uri.parse(apiUrl).host} failed: $e', raw: '$e'));
    }
    var body = r.jsonMap;
    if (r.statusCode == 202 || (body['processing_url'] is String && body['nip94_event'] == null)) {
      body = await _poll(body['processing_url'] as String? ?? '');
    }
    return _fromNip94(body, m, apiUrl);
  }

  Future<Map<String, dynamic>> _poll(String processingUrl) async {
    if (processingUrl.isEmpty) {
      throw const AdapterException(PublishError.platform('Media server accepted the upload but gave no processing URL.'));
    }
    for (var i = 0; i < maxPolls; i++) {
      await Future<void>.delayed(pollInterval);
      ctx.progress('Waiting for the media server to process the upload');
      final body = await _getJson(Uri.parse(processingUrl), 'Media processing',
          headers: {'Authorization': nip98Header(processingUrl, 'GET')});
      if (body['nip94_event'] is Map) return body;
      if (body['status'] == 'error') {
        throw AdapterException(PublishError.platform('Media server failed to process the upload: ${body['message'] ?? ''}'));
      }
    }
    throw const AdapterException(
        PublishError.network('The media server is still processing the upload; try again in a minute.'));
  }

  NostrUploadedMedia _fromNip94(Map<String, dynamic> body, MediaAttachment m, String apiUrl) {
    final event = body['nip94_event'];
    if (body['status'] == 'error' || event is! Map) {
      throw AdapterException(PublishError.platform(
          'Media upload failed: ${body['message'] ?? 'no nip94_event in the response'}',
          raw: jsonEncode(body)));
    }
    final values = <String, String>{};
    for (final tag in (event['tags'] as List? ?? const <Object?>[])) {
      if (tag is List && tag.length >= 2 && tag[0] is String && tag[1] is String) {
        values.putIfAbsent(tag[0] as String, () => tag[1] as String);
      }
    }
    final url = values['url'];
    if (url == null || url.isEmpty) {
      throw AdapterException(PublishError.platform('Media server ${Uri.parse(apiUrl).host} returned no file URL.',
          raw: jsonEncode(body)));
    }
    return NostrUploadedMedia(url, buildImeta(url, m, values));
  }
}

/// Builds a NIP-92 `imeta` tag. [known] holds values reported by the server
/// (`m`, `x`, `ox`, `dim`, `blurhash`); the attachment fills the gaps.
List<String> buildImeta(String url, MediaAttachment m, Map<String, String> known) {
  final dim = known['dim'] ?? ((m.width != null && m.height != null) ? '${m.width}x${m.height}' : null);
  final alt = (m.altText ?? '').trim();
  return [
    'imeta',
    'url $url',
    'm ${known['m'] ?? m.mimeType}',
    if (known['x'] != null) 'x ${known['x']}',
    if (known['ox'] != null) 'ox ${known['ox']}',
    if (dim != null) 'dim $dim',
    if (known['blurhash'] != null) 'blurhash ${known['blurhash']}',
    if (alt.isNotEmpty) 'alt ${alt.replaceAll(RegExp(r'\s+'), ' ')}',
  ];
}

/// Maps a NIP-96 HTTP failure. Body `message` is surfaced when present.
PublishError mapNip96Failure(HttpFailure f, String what) {
  final message = f.response.jsonMap['message'];
  final detail = message is String && message.isNotEmpty ? ': $message' : '';
  final host = f.url.host;
  final raw = f.body.length > 600 ? f.body.substring(0, 600) : f.body;
  return switch (f.statusCode) {
    401 => PublishError.auth(
        '$what: $host rejected the signed NIP-98 authorisation$detail. Check that the device clock is correct.',
        raw: raw,
        statusCode: 401),
    402 => PublishError.quota('$what: $host requires a paid plan for this upload$detail', raw: raw, statusCode: 402),
    403 => PublishError.platform('$what: $host refused the upload$detail', raw: raw, statusCode: 403),
    413 => PublishError.validation('$what: the file is too large for $host$detail', raw: raw, statusCode: 413),
    429 => PublishError.quota('$what: $host is rate limiting uploads$detail',
        raw: raw, statusCode: 429, retryAfter: f.response.retryAfter),
    _ => f.toPublishError(context: '$what$detail'),
  };
}
