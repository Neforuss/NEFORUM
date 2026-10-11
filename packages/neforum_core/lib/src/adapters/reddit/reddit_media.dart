import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../model/media.dart';

/// Reads the first text message from Reddit's media-processing WebSocket
/// (`json.data.websocket_url`). Abstracted so tests can replace the socket.
typedef RedditSocketReader = Future<String?> Function(Uri url, Duration timeout);

/// Default [RedditSocketReader] built on `package:web_socket_channel`
/// (works on IO and web).
Future<String?> webSocketFirstMessage(Uri url, Duration timeout) async {
  final channel = WebSocketChannel.connect(url);
  try {
    await channel.ready.timeout(timeout);
    final Object? message = await channel.stream.firstWhere((m) => m is String).timeout(timeout);
    return message is String ? message : null;
  } finally {
    try {
      await channel.sink.close().timeout(const Duration(seconds: 2));
    } on Object {
      // Best effort.
    }
  }
}

/// Outcome of Reddit's media-processing message:
/// `{"type": "success"|"failed", "payload": {"redirect": "https://www.reddit.com/r/x/comments/<id>/..."}}`.
class RedditMediaStatus {
  const RedditMediaStatus({required this.failed, this.redirect, this.message});

  /// Parses the WebSocket message; `null` when it is not JSON.
  static RedditMediaStatus? parse(String raw) {
    Object? j;
    try {
      j = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (j is! Map) return null;
    final type = j['type'];
    final payload = j['payload'];
    final redirect = payload is Map ? payload['redirect'] : null;
    final message = payload is Map ? payload['message'] : null;
    return RedditMediaStatus(
      failed: type == 'failed',
      redirect: redirect is String && redirect.isNotEmpty ? redirect : null,
      message: message is String ? message : null,
    );
  }

  final bool failed;
  final String? redirect;
  final String? message;

  /// The base-36 post id from [redirect].
  String? get postId => redirect == null ? null : postIdFromUrl(redirect!);
}

/// Extracts `abc123` from `https://www.reddit.com/r/x/comments/abc123/title/`.
String? postIdFromUrl(String url) => RegExp(r'/comments/([a-z0-9]+)', caseSensitive: false).firstMatch(url)?.group(1);

/// The mime type Reddit's media lease expects (it knows image/png,
/// image/jpeg, image/gif, video/mp4 and video/quicktime).
String redditMimeType(MediaAttachment m) {
  final t = m.mimeType.toLowerCase();
  if (t == 'image/jpg' || t == 'image/pjpeg') return 'image/jpeg';
  return t;
}

/// A file name with an extension that matches [mime], as the lease's
/// `filepath` (Reddit derives the stored extension from it).
String redditFileName(MediaAttachment m, String mime) {
  var name = m.fileName;
  if (name == null || name.isEmpty) {
    final p = m.path.replaceAll('\\', '/');
    name = p.substring(p.lastIndexOf('/') + 1);
  }
  if (name.isEmpty) name = m.id;
  final ext = _extensionFor(mime);
  final lower = name.toLowerCase();
  final hasExt = switch (mime) {
    'image/jpeg' => lower.endsWith('.jpg') || lower.endsWith('.jpeg'),
    'video/quicktime' => lower.endsWith('.mov'),
    _ => lower.endsWith('.$ext'),
  };
  if (hasExt) return name;
  // Replace a wrong media extension (photo.jpg that is really a PNG).
  final stem = name.replaceFirst(_mediaExtension, '');
  return '${stem.isEmpty ? m.id : stem}.$ext';
}

final RegExp _mediaExtension =
    RegExp(r'\.(jpe?g|png|gif|webp|heic|heif|mp4|mov|m4v|webm)$', caseSensitive: false);

String _extensionFor(String mime) => switch (mime) {
      'image/png' => 'png',
      'image/gif' => 'gif',
      'video/mp4' => 'mp4',
      'video/quicktime' => 'mov',
      _ => 'jpg',
    };

/// Mime type for a poster image path given in `extra['videoPoster']`.
String posterMimeFor(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  return 'image/jpeg';
}

/// A plain dark 16:9 PNG, used as the required `video_poster_url` when the
/// user supplied no thumbnail (PRAW does the same with its logo). Built by
/// hand with uncompressed ("stored") deflate blocks so the core needs neither
/// dart:io nor an image package.
Uint8List placeholderPosterPng({int width = 320, int height = 180, int red = 0x33, int green = 0x33, int blue = 0x33}) {
  final rowLength = 1 + width * 3;
  final raw = Uint8List(rowLength * height);
  for (var y = 0; y < height; y++) {
    final row = y * rowLength; // raw[row] stays 0: filter type "None"
    for (var x = 0; x < width; x++) {
      final i = row + 1 + x * 3;
      raw[i] = red;
      raw[i + 1] = green;
      raw[i + 2] = blue;
    }
  }
  final ihdr = Uint8List(13);
  final hd = ByteData.sublistView(ihdr)
    ..setUint32(0, width)
    ..setUint32(4, height);
  hd
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 2) // colour type: truecolour RGB
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  final out = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  _chunk(out, 'IHDR', ihdr);
  _chunk(out, 'IDAT', _zlibStored(raw));
  _chunk(out, 'IEND', Uint8List(0));
  return Uint8List.fromList(out);
}

void _chunk(List<int> out, String type, Uint8List data) {
  final typeBytes = ascii.encode(type);
  out.addAll(_u32(data.length));
  final crcInput = Uint8List(typeBytes.length + data.length)
    ..setAll(0, typeBytes)
    ..setAll(typeBytes.length, data);
  out
    ..addAll(crcInput)
    ..addAll(_u32(_crc32(crcInput)));
}

Uint8List _zlibStored(Uint8List data) {
  const maxBlock = 65535;
  final out = <int>[0x78, 0x01];
  var offset = 0;
  do {
    final len = (data.length - offset) > maxBlock ? maxBlock : data.length - offset;
    final last = offset + len >= data.length;
    out
      ..add(last ? 1 : 0)
      ..add(len & 0xFF)
      ..add((len >> 8) & 0xFF)
      ..add(~len & 0xFF)
      ..add((~len >> 8) & 0xFF)
      ..addAll(Uint8List.sublistView(data, offset, offset + len));
    offset += len;
  } while (offset < data.length);
  out.addAll(_u32(_adler32(data)));
  return Uint8List.fromList(out);
}

List<int> _u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

int _adler32(Uint8List data) {
  var a = 1, b = 0;
  for (final byte in data) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return (b << 16) | a;
}

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
  }
  return c;
});

int _crc32(Uint8List data) {
  var c = 0xFFFFFFFF;
  for (final byte in data) {
    c = _crcTable[(c ^ byte) & 0xFF] ^ (c >>> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
