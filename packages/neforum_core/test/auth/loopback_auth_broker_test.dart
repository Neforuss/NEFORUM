import 'dart:convert';
import 'dart:io';

import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

// A real loopback server on a spare port, with a fake "browser" that follows
// the redirect itself.
void main() {
  // A free port: fixed ones can be reserved by Windows (Hyper-V).
  late int port;
  setUp(() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = s.port;
    await s.close();
  });

  Future<(int, String)> get(InternetAddress address, String pathAndQuery) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('http://${address.type == InternetAddressType.IPv6 ? '[::1]' : '127.0.0.1'}:$port$pathAndQuery'));
      final res = await req.close();
      return (res.statusCode, await res.transform(utf8.decoder).join());
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> hasIpv6() async {
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv6, 0);
      await s.close();
      return true;
    } on SocketException {
      return false;
    }
  }

  for (final family in [InternetAddress.loopbackIPv4, InternetAddress.loopbackIPv6]) {
    test('a localhost redirect is caught over ${family.type.name}', () async {
      if (family.type == InternetAddressType.IPv6 && !await hasIpv6()) {
        markTestSkipped('no IPv6 loopback on this machine');
        return;
      }
      late Future<(int, String)> page;
      final broker = LoopbackAuthBroker(
        port: port,
        host: 'localhost',
        openBrowser: (url) async => page = get(family, '/callback?code=abc&state=xyz'),
      );
      final back = await broker.authorize(Uri.parse('https://example.com/authorize'),
          Uri.parse('http://localhost:$port/callback'), timeout: const Duration(seconds: 10));
      expect(back.queryParameters['code'], 'abc');
      expect(back.host, 'localhost');
      final (status, body) = await page;
      expect(status, 200);
      expect(body, contains('Signed in'));
    });
  }

  test('an error redirect shows what the platform said, escaped', () async {
    late Future<(int, String)> page;
    final broker = LoopbackAuthBroker(
      port: port,
      openBrowser: (url) async => page = get(InternetAddress.loopbackIPv4,
          '/callback?error=invalid_request&error_description=${Uri.encodeQueryComponent('redirect_uri <b>mismatch</b>')}'),
    );
    final back = await broker.authorize(Uri.parse('https://example.com/authorize'),
        Uri.parse('http://127.0.0.1:$port/callback'), timeout: const Duration(seconds: 10));
    expect(back.queryParameters['error'], 'invalid_request');
    final (_, body) = await page;
    expect(body, contains('Sign-in failed'));
    expect(body, contains('invalid_request: redirect_uri &lt;b&gt;mismatch&lt;/b&gt;'));
    expect(body, isNot(contains('<b>')));
  });
}
