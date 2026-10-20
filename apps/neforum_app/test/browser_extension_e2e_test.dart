// The real browser extension background script (extensions/browser/src/
// background.js, run by Node) against the real NEFORUM bridge server over
// real HTTP: pairing with a code, the job, a 1.5 MB file in chunks, the
// result, and unpairing. On a port of its own, so a NEFORUM running on
// this computer is not in the way. Skipped when Node is not installed.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/browser_bridge.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

void main() {
  final hasNode = () {
    try {
      return Process.runSync('node', ['--version']).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }();

  test('the real extension pairs, gets the job and its file, reports back and unpairs', () async {
    final secrets = InMemorySecretStore();
    // A free port of its own: fixed ones can be reserved by Windows (Hyper-V).
    final port = await _freePort();
    final bridge = BrowserBridge.create(secrets: secrets, ports: [port]);
    await bridge.start();
    addTearDown(bridge.dispose);
    expect(bridge.status.value.listening, isTrue, reason: 'port $port must be free');

    final bytes = Uint8List.fromList(List.generate(1500000, (i) => i % 251));
    bytes[0] = 1;
    bytes[bytes.length - 1] = 9;
    const url = 'https://www.tiktok.com/tiktokstudio/upload?tab=photo';
    bridge.createJob(
      platformId: 'tiktok',
      platformName: 'TikTok',
      url: url,
      hosts: browserJobHosts(Uri.parse(url)),
      text: 'My caption #fyp',
      media: [BrowserJobMedia(name: 'card.jpg', mimeType: 'image/jpeg', size: bytes.length, read: () async => bytes)],
    );
    final results = <BrowserFillResult>[];
    final sub = bridge.results.listen(results.add);
    addTearDown(sub.cancel);
    final code = bridge.startPairing().code;

    final run = await Process.run('node', ['../../extensions/browser/test/e2e.mjs', code, 'www.tiktok.com', '$port']);
    final lines = const LineSplitter().convert('${run.stdout}').where((l) => l.trim().startsWith('{'));
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    final out = jsonDecode(lines.last) as Map<String, dynamic>;

    expect(out['status1'], containsPair('app', true));
    expect(out['status1'], containsPair('paired', false));
    expect(out['status2'], containsPair('paired', true));
    expect(out['job'], containsPair('platformId', 'tiktok'));
    expect(out['job'], containsPair('text', 'My caption #fyp'));
    expect((out['job']['media'] as List).single, containsPair('kind', 'image'));
    expect(out['otherHost'], isNull, reason: 'another site gets nothing');
    expect(out['mediaBytes'], bytes.length);
    expect(out['mediaType'], startsWith('image/jpeg'));
    expect((out['mediaFirst'], out['mediaLast']), (1, 9));
    expect(out['unpaired'], isTrue);
    expect(out['status3'], containsPair('paired', false));

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(results.single.status, BrowserFillStatus.filled);
    expect(results.single.media, 1);
    expect(results.single.message, 'e2e');
    expect(bridge.browsers.value, isEmpty, reason: 'unpair removed the browser');
  }, skip: hasNode ? false : 'Node is not installed');
}

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}
