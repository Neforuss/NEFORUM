import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/nostr/nostr_adapter.dart';
import 'package:neforum_core/src/adapters/nostr/nostr_event.dart';
import 'package:neforum_core/src/adapters/nostr/nostr_relay.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

// NIP-19 test vectors (https://github.com/nostr-protocol/nips/blob/master/19.md).
const nip19Nsec = 'nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5';
const nip19NsecHex = '67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa';
const nip19Npub = 'npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg';
const nip19NpubHex = '7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e';

final String testPub = bip340.getPublicKey(nip19NsecHex);
final int nowSecs = testNow.millisecondsSinceEpoch ~/ 1000;

/// How a fake relay reacts to an incoming client message.
typedef RelayScript = void Function(FakeRelay relay, List<dynamic> message);

/// In-memory relay: records every frame and answers via [script].
class FakeRelay implements RelayConnection {
  FakeRelay(this.url, this.script);

  final String url;
  final RelayScript script;
  final StreamController<String> _out = StreamController<String>();
  final List<List<dynamic>> sent = [];
  bool closed = false;

  List<Map<String, dynamic>> get events => [
        for (final m in sent)
          if (m[0] == 'EVENT') Map<String, dynamic>.from(m[1] as Map),
      ];

  @override
  Stream<String> get messages => _out.stream;

  @override
  void send(String message) {
    final m = jsonDecode(message) as List<dynamic>;
    sent.add(m);
    scheduleMicrotask(() => script(this, m));
  }

  void reply(List<Object?> message) {
    if (!_out.isClosed) _out.add(jsonEncode(message));
  }

  @override
  Future<void> close() async {
    closed = true;
    await _out.close();
  }
}

String eventIdOf(List<dynamic> m) => (m[1] as Map)['id'] as String;

void acceptAll(FakeRelay r, List<dynamic> m) {
  if (m[0] == 'EVENT') r.reply(['OK', eventIdOf(m), true, '']);
}

RelayScript rejectWith(String message) => (r, m) {
      if (m[0] == 'EVENT') r.reply(['OK', eventIdOf(m), false, message]);
    };

void silent(FakeRelay r, List<dynamic> m) {}

/// Builds an adapter whose relays are [FakeRelay]s keyed by URL. A missing
/// script means the connection fails.
({NostrAdapter adapter, Map<String, FakeRelay> relays}) harness(Map<String, RelayScript?> scripts) {
  final relays = <String, FakeRelay>{};
  final adapter = NostrAdapter(
    relayTimeout: const Duration(milliseconds: 200),
    connectTimeout: const Duration(milliseconds: 200),
    mediaPollInterval: Duration.zero,
    random: Random(1),
    connector: (uri) async {
      final script = scripts[uri.toString()];
      if (script == null) throw StateError('connection refused');
      return relays[uri.toString()] = FakeRelay(uri.toString(), script);
    },
  );
  return (adapter: adapter, relays: relays);
}

ConnectedAccount nostrAccount({List<String>? relays, String? nip96}) => fakeAccount('nostr', config: {
      'pubkey': testPub,
      'npub': Nip19.encode('npub', testPub),
      'relays': relays ?? ['wss://a.example', 'wss://b.example'],
      if (nip96 != null) 'nip96Server': nip96,
    });

const secrets = {'privateKey': nip19NsecHex};

/// Checks id and signature of a wire event exactly as a relay would.
void expectValidEvent(Map<String, dynamic> e) {
  final tags = [for (final t in e['tags'] as List) (t as List).cast<String>()];
  final id = nostrEventId(
    pubkey: e['pubkey'] as String,
    createdAt: e['created_at'] as int,
    kind: e['kind'] as int,
    tags: tags,
    content: e['content'] as String,
  );
  expect(e['id'], id);
  expect(bip340.verify(e['pubkey'] as String, id, e['sig'] as String), isTrue);
}

List<List<String>> tagsOf(Map<String, dynamic> e) => [for (final t in e['tags'] as List) (t as List).cast<String>()];

Future<http.Response> noHttp(http.Request r) async => fail('unexpected HTTP ${r.method} ${r.url}');

void main() {
  group('NIP-19 and keys', () {
    test('decodes and encodes the spec vectors', () {
      expect(Nip19.decode(nip19Nsec), (hrp: 'nsec', hex: nip19NsecHex));
      expect(Nip19.decode(nip19Npub), (hrp: 'npub', hex: nip19NpubHex));
      expect(Nip19.encode('nsec', nip19NsecHex), nip19Nsec);
      expect(Nip19.encode('npub', nip19NpubHex), nip19Npub);
    });

    test('parses nsec and hex to the same key and derives pubkey', () {
      final a = NostrKeys.parse(nip19Nsec);
      final b = NostrKeys.parse(nip19NsecHex.toUpperCase());
      expect(a.privateKeyHex, nip19NsecHex);
      expect(b.privateKeyHex, nip19NsecHex);
      expect(a.publicKeyHex, testPub);
      expect(a.npub, startsWith('npub1'));
      expect(Nip19.decode(a.npub).hex, testPub);
    });

    test('rejects npub, garbage, zero key', () {
      expect(() => NostrKeys.parse(nip19Npub), throwsA(isA<FormatException>()));
      expect(() => NostrKeys.parse('hello'), throwsA(isA<FormatException>()));
      expect(() => NostrKeys.parse('0' * 64), throwsA(isA<FormatException>()));
      expect(() => NostrKeys.parse('${nip19Nsec.substring(0, nip19Nsec.length - 1)}x'), throwsA(isA<FormatException>()));
    });
  });

  group('NIP-01 serialisation', () {
    test('matches jsonEncode for ordinary text, including / and non-ASCII', () {
      const content = 'Hi "there"\n\ttab\\ back / slash ünïcødé 🎉 \r\f\b';
      final tags = [
        ['t', 'nostr'],
        ['r', 'https://example.com/a?b=c'],
      ];
      expect(
        nip01Serialize(pubkey: testPub, createdAt: 1, kind: 1, tags: tags, content: content),
        jsonEncode([0, testPub, 1, 1, tags, content]),
      );
    });

    test('writes other control characters verbatim (no \\u escapes)', () {
      final s = nip01Serialize(pubkey: 'p', createdAt: 1, kind: 1, tags: const [], content: 'a\u0001b');
      expect(s, '[0,"p",1,1,[],"a\u0001b"]');
    });

    test('signed events verify', () {
      final keys = NostrKeys.parse(nip19Nsec);
      final e = keys.sign(kind: 1, content: 'hello', createdAt: nowSecs, tags: const [
        ['t', 'x'],
      ]);
      expect(e.id, sha256.convert(utf8.encode(jsonEncode([0, testPub, nowSecs, 1, [['t', 'x']], 'hello']))).toString());
      expect(bip340.verify(testPub, e.id, e.sig), isTrue);
      expect(e.noteId, startsWith('note1'));
      expect(Nip19.decode(e.noteId).hex, e.id);
    });
  });

  group('descriptor', () {
    test('matches research', () {
      final d = NostrAdapter().descriptor;
      expect(d.id, 'nostr');
      expect(d.tiers, {PlatformTier.openApi, PlatformTier.handoff});
      expect(d.defaultTier, PlatformTier.openApi);
      expect(d.text.maxLength, isNull);
      expect(d.text.counting, CountingRule.utf8Bytes);
      expect(d.text.supportsThreads, isTrue);
      expect(d.text.supportsContentWarning, isTrue);
      expect(d.text.titleSupported, isFalse);
      expect(d.media.imageMaxBytes, 20971520);
      expect(d.media.supportsAltText, isTrue);
      expect(d.media.requiresPublicMediaUrl, isFalse);
      expect(d.personalAccountOk, isTrue);
      expect(d.serverSideScheduling, isFalse);
      expect(d.setupGuide, 'docs/platforms/nostr.md');
      expect(d.defaultQuotas, isEmpty);
    });

    test('connect spec has a secret key field and no browser', () {
      final spec = NostrAdapter().specFor(PlatformTier.openApi);
      expect(spec.usesBrowser, isFalse);
      final key = spec.fields.firstWhere((f) => f.key == 'privateKey');
      expect(key.secret, isTrue);
      expect(key.kind, FieldKind.password);
      final relays = spec.fields.firstWhere((f) => f.key == 'relays');
      expect(relays.defaultValue, contains('wss://relay.damus.io'));
      expect(relays.secret, isFalse);
    });
  });

  group('connect', () {
    test('nsec + relays -> account and hex secret, no network', () async {
      final r = await NostrAdapter().connect(
          PlatformTier.openApi,
          {'privateKey': '  $nip19Nsec ', 'relays': 'wss://a.example/\nwss://b.example, wss://a.example'},
          testContext(handler: noHttp));
      expect(r.secrets, {'privateKey': nip19NsecHex});
      expect(r.account.platformId, 'nostr');
      expect(r.account.tier, PlatformTier.openApi);
      expect(r.account.config['pubkey'], testPub);
      expect(r.account.config['npub'], Nip19.encode('npub', testPub));
      expect(r.account.config['relays'], ['wss://a.example', 'wss://b.example']);
      expect(r.account.config['nip96Server'], 'https://nostr.build');
      expect(r.account.profileUrl, 'https://njump.me/${Nip19.encode('npub', testPub)}');
      expect(r.account.config.values.join(), isNot(contains(nip19NsecHex)));
    });

    test('empty relays fall back to defaults; empty media server disables NIP-96', () async {
      final r = await NostrAdapter().connect(PlatformTier.openApi,
          {'privateKey': nip19NsecHex, 'relays': '', 'nip96Server': ''}, testContext(handler: noHttp));
      expect(r.account.config['relays'], nostrDefaultRelays);
      expect(r.account.config['nip96Server'], '');
    });

    test('bad input -> ConnectException on the right field', () async {
      final ctx = testContext(handler: noHttp);
      await expectLater(NostrAdapter().connect(PlatformTier.openApi, {'privateKey': nip19Npub}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'privateKey')));
      await expectLater(
          NostrAdapter().connect(PlatformTier.openApi, {'privateKey': nip19Nsec, 'relays': 'https://relay.example'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'relays')));
    });

    test('refreshSecrets is a no-op', () async {
      final a = NostrAdapter();
      expect(await a.refreshSecrets(nostrAccount(), secrets, testContext(handler: noHttp)), isNull);
    });

    test('hand-off shares the full text to a Nostr app', () async {
      final a = NostrAdapter();
      final plan = a.buildHandoff(const PostVariant(text: 'one', threadParts: ['one', 'two']))!;
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.clipboardText, 'one\n\ntwo');
      expect(plan.desktopUrl, startsWith('https://'));
      final r = await a.connect(PlatformTier.handoff, {'label': 'Me on Nostr'}, testContext(handler: noHttp));
      expect(r.account.tier, PlatformTier.handoff);
      expect(r.account.displayName, 'Me on Nostr');
      expect(r.secrets, isEmpty);
    });
  });

  group('validate', () {
    test('plain text is fine', () {
      final issues = NostrAdapter().validate(const PostVariant(text: 'gm'), nostrAccount());
      expect(issues.hasErrors, isFalse);
    });

    test('no relays is an error; non-public visibility warns', () {
      final issues = NostrAdapter().validate(
          const PostVariant(text: 'gm', visibility: Visibility.followers), nostrAccount(relays: const []));
      expect(issues.map((i) => i.code), containsAll(['nostr.no_relays', 'nostr.public_only']));
      expect(issues.hasErrors, isTrue);
    });

    test('oversized file is an error on nostr.build, a warning on a custom server', () {
      final v = PostVariant(text: 'pic', media: [fakeImage(sizeBytes: 25 * 1024 * 1024)]);
      expect(NostrAdapter().validate(v, nostrAccount()).hasErrors, isTrue);
      final custom = NostrAdapter().validate(v, nostrAccount(nip96: 'https://files.example'));
      expect(custom.hasErrors, isFalse);
      expect(custom.map((i) => i.code), contains('media.image_too_large'));
    });

    test('media without NIP-96 server warns; huge text warns', () {
      final issues = NostrAdapter()
          .validate(PostVariant(text: 'x' * 70000, media: [fakeImage()]), nostrAccount(nip96: ''));
      expect(issues.map((i) => i.code), containsAll(['nostr.media_host', 'nostr.event_large']));
    });
  });

  group('publish', () {
    test('signs a kind-1 note with t/r/content-warning tags and sends it to every relay', () async {
      final h = harness({'wss://a.example': acceptAll, 'wss://b.example': acceptAll});
      final progress = <String>[];
      final ctx = testContext(handler: noHttp).copyWith(onProgress: progress.add);
      final res = await h.adapter.publish(
        const PostVariant(
          text: 'Hello #Nostr and #FOSS see https://example.com/x.',
          contentWarning: 'spoilers',
          tags: ['neforum'],
        ),
        nostrAccount(),
        secrets,
        ctx,
      );
      expect(res.success, isTrue, reason: '${res.error}');
      for (final relay in h.relays.values) {
        expect(relay.sent, hasLength(1));
        expect(relay.sent.single[0], 'EVENT');
        expect(relay.closed, isTrue);
      }
      final e = h.relays['wss://a.example']!.events.single;
      expect(h.relays['wss://b.example']!.events.single['id'], e['id']);
      expectValidEvent(e);
      expect(e['kind'], 1);
      expect(e['pubkey'], testPub);
      expect(e['created_at'], nowSecs);
      expect(e['content'], 'Hello #Nostr and #FOSS see https://example.com/x.');
      expect(tagsOf(e), [
        ['t', 'nostr'],
        ['t', 'foss'],
        ['t', 'neforum'],
        ['r', 'https://example.com/x'],
        ['content-warning', 'spoilers'],
      ]);
      expect(res.remoteId, e['id']);
      expect(res.remoteUrl, 'https://njump.me/${Nip19.encode('note', e['id'] as String)}');
      expect(res.threadRemoteIds, isEmpty);
      expect(progress, contains('Sending note to 2 relays'));
    });

    test('succeeds when one relay accepts and others fail or time out', () async {
      final h = harness({
        'wss://a.example': rejectWith('blocked: not on whitelist'),
        'wss://b.example': silent,
        'wss://c.example': acceptAll,
        'wss://down.example': null,
      });
      final res = await h.adapter.publish(const PostVariant(text: 'gm'),
          nostrAccount(relays: ['wss://a.example', 'wss://b.example', 'wss://c.example', 'wss://down.example']),
          secrets, testContext(handler: noHttp));
      expect(res.success, isTrue);
    });

    test('"duplicate:" counts as accepted', () async {
      final h = harness({'wss://a.example': rejectWith('duplicate: already have this event')});
      final res = await h.adapter.publish(
          const PostVariant(text: 'gm'), nostrAccount(relays: ['wss://a.example']), secrets, testContext(handler: noHttp));
      expect(res.success, isTrue);
    });

    test('answers a NIP-42 AUTH challenge and re-sends the note', () async {
      final h = harness({
        'wss://auth.example': (r, m) {
          if (m[0] == 'EVENT') {
            final authed = r.sent.any((x) => x[0] == 'AUTH');
            if (!authed) {
              r.reply(['AUTH', 'challenge-123']);
              r.reply(['OK', eventIdOf(m), false, 'auth-required: sign in first']);
            } else {
              r.reply(['OK', eventIdOf(m), true, '']);
            }
          } else if (m[0] == 'AUTH') {
            r.reply(['OK', eventIdOf(m), true, '']);
          }
        },
      });
      final res = await h.adapter.publish(const PostVariant(text: 'gm'), nostrAccount(relays: ['wss://auth.example']),
          secrets, testContext(handler: noHttp));
      expect(res.success, isTrue, reason: '${res.error}');
      final sent = h.relays['wss://auth.example']!.sent;
      expect(sent.map((m) => m[0]), ['EVENT', 'AUTH', 'EVENT']);
      final auth = Map<String, dynamic>.from(sent[1][1] as Map);
      expectValidEvent(auth);
      expect(auth['kind'], 22242);
      expect(tagsOf(auth), [
        ['relay', 'wss://auth.example'],
        ['challenge', 'challenge-123'],
      ]);
    });

    test('thread: parts are NIP-10 replies in order', () async {
      final h = harness({'wss://a.example': acceptAll});
      final res = await h.adapter.publish(
        const PostVariant(text: 'one', threadParts: ['one', 'two', 'three']),
        nostrAccount(relays: ['wss://a.example']),
        secrets,
        testContext(handler: noHttp),
      );
      expect(res.success, isTrue);
      final events = h.relays['wss://a.example']!.events;
      expect(events.map((e) => e['content']), ['one', 'two', 'three']);
      events.forEach(expectValidEvent);
      final root = events[0]['id'] as String;
      final second = events[1]['id'] as String;
      expect(tagsOf(events[0]), isEmpty);
      expect(tagsOf(events[1]), [
        ['e', root, 'wss://a.example', 'root', testPub],
        ['p', testPub],
      ]);
      expect(tagsOf(events[2]), [
        ['e', root, 'wss://a.example', 'root', testPub],
        ['e', second, 'wss://a.example', 'reply', testPub],
        ['p', testPub],
      ]);
      expect(events.map((e) => e['created_at']), [nowSecs, nowSecs + 1, nowSecs + 2]);
      expect(res.threadRemoteIds, [root, second, events[2]['id']]);
      expect(res.remoteId, root);
    });

    test('NIP-96 upload to nostr.build with NIP-98 auth, then imeta + URL in content', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        if (req.url.path == '/.well-known/nostr/nip96.json') {
          return http.Response(jsonEncode({'api_url': 'https://nostr.build/api/v2/nip96/upload'}), 200,
              headers: jsonHeaders);
        }
        return http.Response(
            jsonEncode({
              'status': 'success',
              'message': 'Upload successful.',
              'nip94_event': {
                'tags': [
                  ['url', 'https://image.nostr.build/abc.jpg'],
                  ['ox', 'aa' * 32],
                  ['x', 'bb' * 32],
                  ['m', 'image/jpeg'],
                  ['dim', '1200x800'],
                ],
                'content': '',
              },
            }),
            201,
            headers: jsonHeaders);
      });
      final h = harness({'wss://a.example': acceptAll});
      final res = await h.adapter.publish(PostVariant(text: 'Look', media: [fakeImage()]),
          nostrAccount(relays: ['wss://a.example']), secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');

      expect(calls, hasLength(2));
      expect(calls[0].method, 'GET');
      expect(calls[0].url.toString(), 'https://nostr.build/.well-known/nostr/nip96.json');
      expect(calls[1].method, 'POST');
      expect(calls[1].url.toString(), 'https://nostr.build/api/v2/nip96/upload');
      expect(multipartFieldsOf(calls[1]), {
        'alt': 'A test image',
        'caption': 'A test image',
        'size': '${fakeJpegBytes.length}',
        'content_type': 'image/jpeg',
        'file': '<img1.jpg>',
      });
      final authHeader = calls[1].headers['Authorization']!;
      expect(authHeader, startsWith('Nostr '));
      final auth = Map<String, dynamic>.from(jsonDecode(utf8.decode(base64.decode(authHeader.substring(6)))) as Map);
      expectValidEvent(auth);
      expect(auth['kind'], 27235);
      expect(auth['content'], '');
      expect(auth['created_at'], nowSecs);
      expect(tagsOf(auth), [
        ['u', 'https://nostr.build/api/v2/nip96/upload'],
        ['method', 'POST'],
      ]);

      final e = h.relays['wss://a.example']!.events.single;
      expectValidEvent(e);
      expect(e['content'], 'Look\n\nhttps://image.nostr.build/abc.jpg');
      expect(tagsOf(e), [
        [
          'imeta',
          'url https://image.nostr.build/abc.jpg',
          'm image/jpeg',
          'x ${'bb' * 32}',
          'ox ${'aa' * 32}',
          'dim 1200x800',
          'alt A test image',
        ],
      ]);
    });

    test('NIP-96 202 processing is polled until done', () async {
      final calls = <http.Request>[];
      var polls = 0;
      final ctx = testContext(handler: (req) async {
        calls.add(req);
        if (req.url.path == '/.well-known/nostr/nip96.json') {
          return http.Response(jsonEncode({'api_url': 'https://files.example/upload'}), 200, headers: jsonHeaders);
        }
        if (req.method == 'POST') {
          return http.Response(
              jsonEncode({'status': 'processing', 'processing_url': 'https://files.example/p/1'}), 202,
              headers: jsonHeaders);
        }
        polls++;
        if (polls == 1) {
          return http.Response(jsonEncode({'status': 'processing', 'percentage': 50}), 200, headers: jsonHeaders);
        }
        return http.Response(
            jsonEncode({
              'status': 'success',
              'nip94_event': {
                'tags': [
                  ['url', 'https://files.example/v.mp4'],
                  ['ox', 'cc' * 32],
                ],
              },
            }),
            201,
            headers: jsonHeaders);
      });
      final h = harness({'wss://a.example': acceptAll});
      final res = await h.adapter.publish(PostVariant(text: '', media: [fakeVideo()]),
          nostrAccount(relays: ['wss://a.example'], nip96: 'https://files.example'), secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(calls.map((c) => '${c.method} ${c.url}'), [
        'GET https://files.example/.well-known/nostr/nip96.json',
        'POST https://files.example/upload',
        'GET https://files.example/p/1',
        'GET https://files.example/p/1',
      ]);
      expect(calls[2].headers['Authorization'], startsWith('Nostr '));
      final e = h.relays['wss://a.example']!.events.single;
      expect(e['content'], 'https://files.example/v.mp4');
      expect(tagsOf(e).single, ['imeta', 'url https://files.example/v.mp4', 'm video/mp4', 'ox ${'cc' * 32}', 'dim 1080x1920']);
    });

    test('configured media host is used when the account has no NIP-96 server', () async {
      final host = FakeMediaHost();
      final ctx = testContext(handler: noHttp, mediaHost: host);
      final h = harness({'wss://a.example': acceptAll});
      final res = await h.adapter.publish(PostVariant(text: 'pic', media: [fakeImage()]),
          nostrAccount(relays: ['wss://a.example'], nip96: ''), secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(host.uploaded.single.id, 'img1');
      final e = h.relays['wss://a.example']!.events.single;
      expect(e['content'], 'pic\n\nhttps://cdn.example.test/img1');
      expect(tagsOf(e).single, [
        'imeta',
        'url https://cdn.example.test/img1',
        'm image/jpeg',
        'x ${sha256.convert(fakeJpegBytes)}',
        'dim 1200x800',
        'alt A test image',
      ]);
    });

    test('media with no host and NIP-96 disabled -> configuration error, nothing sent', () async {
      final h = harness({'wss://a.example': acceptAll});
      final res = await h.adapter.publish(PostVariant(text: 'pic', media: [fakeImage()]),
          nostrAccount(relays: ['wss://a.example'], nip96: ''), secrets, testContext(handler: noHttp));
      expect(res.error?.kind, PublishErrorKind.configuration);
      expect(h.relays, isEmpty);
    });
  });

  group('error mapping', () {
    Future<PublishResult> uploadFailing(int status, {Map<String, String> headers = jsonHeaders, String? body}) {
      final ctx = testContext(handler: (req) async {
        if (req.method == 'GET') {
          return http.Response(jsonEncode({'api_url': 'https://nostr.build/api/v2/nip96/upload'}), 200,
              headers: jsonHeaders);
        }
        return http.Response(body ?? jsonEncode({'status': 'error', 'message': 'nope'}), status, headers: headers);
      });
      final h = harness({'wss://a.example': acceptAll});
      return h.adapter.publish(PostVariant(text: 'x', media: [fakeImage()]), nostrAccount(), secrets, ctx);
    }

    test('NIP-96 401 -> auth', () async {
      final r = await uploadFailing(401);
      expect(r.error?.kind, PublishErrorKind.auth);
      expect(r.error?.message, contains('nope'));
    });

    test('NIP-96 429 -> quota with retryAfter', () async {
      final r = await uploadFailing(429, headers: {...jsonHeaders, 'retry-after': '120'});
      expect(r.error?.kind, PublishErrorKind.quota);
      expect(r.error?.retryAfter, const Duration(seconds: 120));
    });

    test('NIP-96 413 / 400 -> validation; 402 -> quota; 500 -> network', () async {
      expect((await uploadFailing(413)).error?.kind, PublishErrorKind.validation);
      expect((await uploadFailing(400)).error?.kind, PublishErrorKind.validation);
      expect((await uploadFailing(402)).error?.kind, PublishErrorKind.quota);
      expect((await uploadFailing(500)).error?.kind, PublishErrorKind.network);
    });

    test('missing or mismatched key -> auth', () async {
      final h = harness({'wss://a.example': acceptAll});
      final ctx = testContext(handler: noHttp);
      expect((await h.adapter.publish(const PostVariant(text: 'x'), nostrAccount(), const {}, ctx)).error?.kind,
          PublishErrorKind.auth);
      expect(
          (await h.adapter.publish(const PostVariant(text: 'x'), nostrAccount(), {'privateKey': '1' * 64}, ctx))
              .error
              ?.kind,
          PublishErrorKind.auth);
    });

    Future<PublishError?> relaysSay(List<RelayScript?> scripts) async {
      final urls = [for (var i = 0; i < scripts.length; i++) 'wss://r$i.example'];
      final h = harness({for (var i = 0; i < scripts.length; i++) urls[i]: scripts[i]});
      return (await h.adapter.publish(
              const PostVariant(text: 'x'), nostrAccount(relays: urls), secrets, testContext(handler: noHttp)))
          .error;
    }

    test('relay verdicts are classified', () async {
      expect((await relaysSay([rejectWith('rate-limited: slow down'), silent]))?.kind, PublishErrorKind.quota);
      expect((await relaysSay([rejectWith('invalid: bad sig')]))?.kind, PublishErrorKind.validation);
      expect((await relaysSay([rejectWith('restricted: paid relay')]))?.kind, PublishErrorKind.configuration);
      expect((await relaysSay([rejectWith('pow: difficulty 20')]))?.kind, PublishErrorKind.platform);
      final net = await relaysSay([silent, null]);
      expect(net?.kind, PublishErrorKind.network);
      expect(net?.retryable, isTrue);
    });

    test('a later thread part failing reports the live first part', () async {
      var count = 0;
      final h = harness({
        'wss://a.example': (r, m) {
          if (m[0] != 'EVENT') return;
          count++;
          r.reply(['OK', eventIdOf(m), count == 1, count == 1 ? '' : 'invalid: nope']);
        },
      });
      final res = await h.adapter.publish(const PostVariant(text: 'a', threadParts: ['a', 'b']),
          nostrAccount(relays: ['wss://a.example']), secrets, testContext(handler: noHttp));
      expect(res.error?.kind, PublishErrorKind.validation);
      expect(res.error?.message, contains('Part 2 of 2'));
      expect(res.error?.message, contains('https://njump.me/note1'));
    });
  });
}
