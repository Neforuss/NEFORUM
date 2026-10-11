/// Shared helpers for adapter tests.
///
/// Usage:
/// ```dart
/// final calls = <http.Request>[];
/// final ctx = testContext(
///   handler: (req) async {
///     calls.add(req);
///     return http.Response(jsonEncode({'id': '1'}), 200, headers: jsonHeaders);
///   },
/// );
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';

const jsonHeaders = {'content-type': 'application/json'};

/// A fixed "now" so tests are deterministic.
final DateTime testNow = DateTime.utc(2026, 10, 7, 12, 0, 0);

/// Builds an [AdapterContext] whose HTTP goes to [handler] and whose media
/// bytes come from [mediaBytes] (defaults to a tiny fake JPEG payload).
AdapterContext testContext({
  required Future<http.Response> Function(http.Request request) handler,
  AuthBroker? broker,
  MediaHost? mediaHost,
  Uint8List? mediaBytes,
  DateTime? now,
  int maxRetries = 0,
}) {
  final logged = <String>[];
  return AdapterContext(
    http: NeforumHttp(client: MockClient(handler), maxRetries: maxRetries),
    broker: broker,
    mediaHost: mediaHost,
    clock: () => now ?? testNow,
    log: Logger('test', sink: (level, area, msg, [err]) => logged.add('[${level.name}] $area: $msg')),
    readMedia: (m) async => mediaBytes ?? fakeJpegBytes,
  );
}

/// Smallest payload that looks like a JPEG (SOI marker + padding).
final Uint8List fakeJpegBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(60, 0), 0xFF, 0xD9]);

MediaAttachment fakeImage({
  String id = 'img1',
  String mimeType = 'image/jpeg',
  int sizeBytes = 64,
  int? width = 1200,
  int? height = 800,
  String? altText = 'A test image',
}) =>
    MediaAttachment(
      id: id,
      path: '/tmp/$id.jpg',
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      width: width,
      height: height,
      altText: altText,
      fileName: '$id.jpg',
    );

MediaAttachment fakeVideo({
  String id = 'vid1',
  String mimeType = 'video/mp4',
  int sizeBytes = 5 * 1024 * 1024,
  int? durationMs = 15000,
}) =>
    MediaAttachment(
      id: id,
      path: '/tmp/$id.mp4',
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      width: 1080,
      height: 1920,
      durationMs: durationMs,
      fileName: '$id.mp4',
    );

ConnectedAccount fakeAccount(
  String platformId, {
  PlatformTier tier = PlatformTier.openApi,
  Map<String, dynamic> config = const {},
  String id = 'acct-1',
  String displayName = 'Test account',
}) =>
    ConnectedAccount(
      id: id,
      platformId: platformId,
      tier: tier,
      displayName: displayName,
      createdAt: testNow,
      config: config,
    );

/// An [AuthBroker] that immediately "returns from the browser" with the
/// given query parameters appended to the redirect URI. It records the
/// authorization URL it was given so tests can assert on it.
class FakeAuthBroker implements AuthBroker {
  FakeAuthBroker({this.code = 'test-code', this.extraParams = const {}, Uri? redirect})
      : redirectUri = redirect ?? Uri.parse('http://127.0.0.1:52771/callback');

  final String code;
  final Map<String, String> extraParams;
  final Uri redirectUri;
  Uri? lastAuthorizationUrl;

  @override
  Uri chooseRedirectUri({bool loopbackOk = true, bool customSchemeOk = true, Uri? fixed}) => fixed ?? redirectUri;

  @override
  Future<Uri> authorize(Uri authorizationUrl, Uri redirectUri, {Duration timeout = const Duration(minutes: 5)}) async {
    lastAuthorizationUrl = authorizationUrl;
    final state = authorizationUrl.queryParameters['state'];
    return redirectUri.replace(queryParameters: {
      ...redirectUri.queryParameters,
      'code': code,
      if (state != null) 'state': state,
      ...extraParams,
    });
  }
}

/// A [MediaHost] that pretends every upload lands at a public URL.
class FakeMediaHost implements MediaHost {
  final List<MediaAttachment> uploaded = [];
  final List<HostedMedia> deleted = [];

  @override
  String get id => 'fake';
  @override
  String get name => 'Fake host';
  @override
  String get description => 'test double';
  @override
  List<MediaHostField> get fields => const [];
  @override
  int? get maxBytes => null;

  @override
  Future<HostedMedia> upload(MediaAttachment media, Uint8List bytes, {Duration? ttl}) async {
    uploaded.add(media);
    return HostedMedia(hostId: id, url: Uri.parse('https://cdn.example.test/${media.id}'), deleteHandle: media.id);
  }

  @override
  Future<void> delete(HostedMedia hosted) async => deleted.add(hosted);

  @override
  Future<void> verify() async {}
}

/// Decodes a form-encoded or JSON request body into a map for assertions.
Map<String, dynamic> bodyOf(http.Request r) {
  final ct = r.headers['content-type'] ?? '';
  if (ct.contains('json')) return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
  if (ct.contains('x-www-form-urlencoded')) return Map<String, dynamic>.from(Uri.splitQueryString(r.body));
  return {'raw': r.body};
}

/// Extracts the plain fields of a multipart body (files are reported as
/// `<filename>` placeholders). Good enough for asserting field names.
Map<String, String> multipartFieldsOf(http.Request r) {
  final ct = r.headers['content-type'] ?? '';
  final boundary = RegExp(r'boundary=(.+)$').firstMatch(ct)?.group(1);
  if (boundary == null) return {};
  final out = <String, String>{};
  for (final part in utf8.decode(r.bodyBytes, allowMalformed: true).split('--$boundary')) {
    final name = RegExp(r'name="([^"]+)"').firstMatch(part)?.group(1);
    if (name == null) continue;
    final fileName = RegExp(r'filename="([^"]+)"').firstMatch(part)?.group(1);
    if (fileName != null) {
      out[name] = '<$fileName>';
      continue;
    }
    final idx = part.indexOf('\r\n\r\n');
    out[name] = idx < 0 ? '' : part.substring(idx + 4).replaceFirst(RegExp(r'\r\n$'), '');
  }
  return out;
}
