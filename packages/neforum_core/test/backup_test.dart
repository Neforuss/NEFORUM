import 'dart:convert';
import 'dart:typed_data';

import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

const _fast = BackupKdfParams.testing;
const _device = BackupDevice(platform: 'windows', appVersion: '1.0.7', label: 'PC');
final _now = DateTime.utc(2026, 10, 19, 18);

ConnectedAccount _account(String id, String platform, {PlatformTier tier = PlatformTier.byokApi, String? name}) =>
    ConnectedAccount(id: id, platformId: platform, tier: tier, displayName: name ?? id, createdAt: _now);

Post _post(String id, PostStatus status, {List<PostTarget> targets = const [], DateTime? scheduledAt}) => Post(
      id: id,
      text: 'Post $id',
      status: status,
      createdAt: _now,
      updatedAt: _now,
      scheduledAt: scheduledAt,
      targets: targets,
      media: [MediaAttachment(id: 'm-$id', path: '/old/device/m-$id.jpg', mimeType: 'image/jpeg', sizeBytes: 10)],
    );

void main() {
  group('file format', () {
    final payload = <String, dynamic>{'app': 'NEFORUM', 'payloadVersion': 1, 'secret': 'sk-live-ABC123'};

    test('round trip', () async {
      final bytes = await encryptBackup(payload, 'correct horse battery', params: _fast);
      expect(looksLikeBackup(bytes), isTrue);
      expect(await decryptBackup(bytes, 'correct horse battery', minimum: _fast), payload);
    });

    test('the secret never appears in the file', () async {
      final bytes = await encryptBackup(payload, 'pass phrase here', params: _fast);
      expect(latin1.decode(bytes, allowInvalid: true), isNot(contains('sk-live-ABC123')));
    });

    test('wrong passphrase', () async {
      final bytes = await encryptBackup(payload, 'right one', params: _fast);
      await expectLater(decryptBackup(bytes, 'wrong one', minimum: _fast),
          throwsA(isA<BackupException>().having((e) => e.message, 'message', 'Wrong passphrase or damaged file.')));
    });

    test('every changed header byte, a cut-off end or an extra byte is rejected', () async {
      final bytes = await encryptBackup(payload, 'p', params: _fast);
      for (var i = 8; i < BackupFormat.headerLength; i++) {
        final bad = Uint8List.fromList(bytes)..[i] ^= 0x01;
        await expectLater(decryptBackup(bad, 'p', minimum: _fast), throwsA(isA<BackupException>()), reason: 'byte $i');
      }
      await expectLater(decryptBackup(Uint8List.sublistView(bytes, 0, bytes.length - 1), 'p', minimum: _fast), throwsA(isA<BackupException>()));
      await expectLater(decryptBackup(Uint8List.fromList([...bytes, 0]), 'p', minimum: _fast), throwsA(isA<BackupException>()));
    });

    test('a header claiming cheaper key stretching than allowed is refused', () async {
      final bytes = await encryptBackup(payload, 'p', params: _fast);
      await expectLater(decryptBackup(bytes, 'p'), throwsA(isA<BackupException>().having((e) => e.kind, 'kind', BackupErrorKind.wrongPassphraseOrDamaged)));
    });

    test('not a backup, and newer versions', () async {
      await expectLater(decryptBackup(Uint8List.fromList(utf8.encode('{"hello": 1}')), 'p'),
          throwsA(isA<BackupException>().having((e) => e.kind, 'kind', BackupErrorKind.notABackup)));
      final bytes = await encryptBackup(payload, 'p', params: _fast);
      final newer = Uint8List.fromList(bytes)..[8] = 2;
      await expectLater(decryptBackup(newer, 'p', minimum: _fast), throwsA(isA<BackupException>().having((e) => e.kind, 'kind', BackupErrorKind.tooNew)));
      expect(() => BackupPayload.parse({'app': 'NEFORUM', 'payloadVersion': 2}),
          throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('newer NEFORUM'))));
    });

    test('the same passphrase typed with combining accents opens the file', () async {
      final bytes = await encryptBackup(payload, 'café au lait 2026', params: _fast);
      expect(await decryptBackup(bytes, 'café au lait 2026', minimum: _fast), payload);
    });

    test('generated passphrases: 24 unambiguous characters in groups of four', () {
      final p = generatePassphrase();
      expect(p, matches(RegExp(r'^([A-HJ-NP-Z2-9]{4}-){5}[A-HJ-NP-Z2-9]{4}$')));
      expect(generatePassphrase(), isNot(p));
      expect(passphraseStrength('short'), PassphraseStrength.tooShort);
      expect(passphraseStrength('twelve chars'), PassphraseStrength.weak);
      expect(passphraseStrength(p), PassphraseStrength.ok);
    });
  });

  group('collect and apply', () {
    late InMemoryAccountRepository fromAccounts, toAccounts;
    late InMemoryPostRepository fromPosts, toPosts;
    late InMemorySecretStore fromSecrets, toSecrets;

    setUp(() async {
      fromAccounts = InMemoryAccountRepository();
      toAccounts = InMemoryAccountRepository();
      fromPosts = InMemoryPostRepository();
      toPosts = InMemoryPostRepository();
      fromSecrets = InMemorySecretStore();
      toSecrets = InMemorySecretStore();
      await fromAccounts.upsert(_account('facebook-123', 'facebook'));
      await fromAccounts.upsert(_account('x:9', 'x'));
      await fromAccounts.upsert(_account('tumblr:handoff:aaa', 'tumblr', tier: PlatformTier.handoff, name: 'My Tumblr'));
      await fromSecrets.write('facebook-123', {'access_token': 'EAAB-page-token'});
      await fromSecrets.write('x:9', {'access_token': 'x-at', 'refresh_token': 'x-rt'});
    });

    Future<BackupPayload> roundTrip({BackupMode mode = BackupMode.copy, bool history = false}) async {
      final payload = await collectBackup(
          accounts: fromAccounts,
          posts: fromPosts,
          secrets: fromSecrets,
          mode: mode,
          device: _device,
          now: _now,
          includeHistory: history,
          settings: const {'themeMode': 'dark'},
          mediaHosts: const {'main': {'id': 's3', 'config': {'bucket': 'b'}, 'secrets': {'secret': 'k'}}, 'fallback': null});
      final bytes = await encryptBackup(payload, 'a long passphrase', params: _fast);
      return BackupPayload.parse(await decryptBackup(bytes, 'a long passphrase', minimum: _fast));
    }

    test('into an empty device: identical accounts, keys, settings and media hosts', () async {
      final p = await roundTrip();
      expect(p.device!.label, 'PC');
      expect(p.settings, {'themeMode': 'dark'});
      expect((p.mediaHosts!['main'] as Map)['secrets'], {'secret': 'k'});
      final candidates = previewImport(p, await toAccounts.all(), registry: builtinRegistry());
      expect(candidates.map((c) => c.defaultChoice), everyElement(ImportChoice.add));
      final report = await applyBackup(p, candidates: candidates, accounts: toAccounts, posts: toPosts, secrets: toSecrets);
      expect(report.added, 3);
      expect((await toAccounts.all()).map((a) => a.id).toSet(), {'facebook-123', 'x:9', 'tumblr:handoff:aaa'});
      expect(await toSecrets.read('facebook-123'), {'access_token': 'EAAB-page-token'});
      expect(await toSecrets.read('x:9'), {'access_token': 'x-at', 'refresh_token': 'x-rt'});
      expect(report.attention.single, contains('X stays connected on only one device'));
    });

    test('Replace or Keep for an account already here; hand-off accounts match by name', () async {
      await toAccounts.upsert(_account('facebook-123', 'facebook', name: 'Old name'));
      await toSecrets.write('facebook-123', {'access_token': 'old'});
      await toAccounts.upsert(_account('tumblr:handoff:zzz', 'tumblr', tier: PlatformTier.handoff, name: 'My Tumblr'));
      final p = await roundTrip();
      final candidates = previewImport(p, await toAccounts.all(), registry: builtinRegistry());
      final fb = candidates.firstWhere((c) => c.item.account.id == 'facebook-123');
      final tumblr = candidates.firstWhere((c) => c.item.account.platformId == 'tumblr');
      expect(fb.defaultChoice, ImportChoice.replace);
      expect(tumblr.existing!.id, 'tumblr:handoff:zzz');
      expect(tumblr.defaultChoice, ImportChoice.keep, reason: 'already here under another id: not duplicated');

      await applyBackup(p, candidates: candidates, accounts: toAccounts, posts: toPosts, secrets: toSecrets,
          choices: const {'facebook-123': ImportChoice.keep});
      expect(await toSecrets.read('facebook-123'), {'access_token': 'old'}, reason: 'kept');
      expect((await toAccounts.all()).where((a) => a.platformId == 'tumblr'), hasLength(1));

      await applyBackup(p, candidates: candidates, accounts: toAccounts, posts: toPosts, secrets: toSecrets);
      expect(await toSecrets.read('facebook-123'), {'access_token': 'EAAB-page-token'}, reason: 'replaced');
    });

    test('unticked accounts are left out', () async {
      final p = await roundTrip();
      final candidates = previewImport(p, const []);
      await applyBackup(p, candidates: candidates, accounts: toAccounts, posts: toPosts, secrets: toSecrets, selected: {'x:9'});
      expect((await toAccounts.all()).map((a) => a.id), ['x:9']);
    });

    test('scheduled posts arrive as drafts; copies a platform holds are never sent again; photos are dropped', () async {
      final when = DateTime.utc(2026, 11, 1, 9);
      await fromPosts.upsert(_post('draft', PostStatus.draft));
      await fromPosts.upsert(_post('sched', PostStatus.scheduled, scheduledAt: when, targets: const [
        PostTarget(accountId: 'x:9'),
        PostTarget(accountId: 'facebook-123', status: TargetStatus.heldByPlatform),
      ]));
      await fromPosts.upsert(_post('done', PostStatus.published));
      final p = await roundTrip();
      expect(p.posts.map((x) => x.id).toSet(), {'draft', 'sched'}, reason: 'history is off by default');
      await applyBackup(p, candidates: previewImport(p, const []), accounts: toAccounts, posts: toPosts, secrets: toSecrets);
      final sched = (await toPosts.get('sched'))!;
      expect(sched.status, PostStatus.draft);
      expect(sched.scheduledAt, when);
      expect(sched.targets.map((t) => t.accountId), ['x:9']);
      expect(sched.media, isEmpty);
      expect((await toPosts.get('draft'))!.status, PostStatus.draft);
    });

    test('history comes along when asked', () async {
      await fromPosts.upsert(_post('done', PostStatus.published));
      final p = await roundTrip(history: true);
      expect(p.posts.single.status, PostStatus.published);
    });

    test('broken entries are skipped and counted', () {
      final p = BackupPayload.parse({
        'app': 'NEFORUM',
        'payloadVersion': 1,
        'accounts': [
          {'account': 'nope', 'secrets': <String, String>{}},
          {'account': _account('ok', 'mastodon').toJson(), 'secrets': {'token': 't', 'bad': 3}},
        ],
        'posts': [42],
      });
      expect(p.accounts.single.secrets, {'token': 't'});
      expect(p.skipped, 2);
    });
  });
}
