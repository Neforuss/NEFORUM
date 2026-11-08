// What happens around a run that died: the background task settles and reports it,
// a killed process's run is settled at once on the next start, and the probe's fake
// server really takes what the real Mastodon adapter sends.

import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/main.dart' show openWorkspace;
import 'package:neforum_app/platform/process_identity.dart';
import 'package:neforum_app/platform/publish_host.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/scheduler.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../integration_test/android_background_probe.dart';
import '../tool/android_background_probe/fake_mastodon.dart';

Post _publishing(String id, {List<TargetStatus> targets = const [TargetStatus.pending]}) {
  final at = DateTime.now().subtract(const Duration(minutes: 1));
  return Post(
    id: id,
    text: 'The private words of $id',
    createdAt: at,
    updatedAt: at,
    status: PostStatus.publishing,
    targets: [for (var i = 0; i < targets.length; i++) PostTarget(accountId: 'acct-$i', status: targets[i])],
  );
}

void main() {
  late Directory dir;
  late AppStorage storage;
  final opened = <AppServices>[];

  Future<AppServices> open(String? process) async {
    final s = await AppServices.create(demo: false, storage: storage, journalProcess: process);
    opened.add(s);
    return s;
  }

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('neforum-background-');
    storage = await openAppStorage(overrideDir: dir.path);
  });
  tearDown(() async {
    for (final s in opened) {
      s.dispose();
    }
    opened.clear();
    // Windows holds a file a moment after its last write.
    for (var i = 0; dir.existsSync() && i < 20; i++) {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  group('after a kill', () {
    test('the next process settles the run at once, not after the heartbeat runs out', () async {
      final killed = await open('pid1:100');
      await killed.posts.upsert(_publishing('p'));
      await killed.publishJournal.record('p');

      final next = await open('pid2:200');
      expect(await next.recoverInterruptedPublishing(atStartup: true), 1);
      final p = (await next.posts.get('p'))!;
      expect(p.targets.single.status, TargetStatus.failed);
      expect(p.targets.single.result!.error!.message, AppServices.interruptedMessage);
      expect(await next.publishJournal.entries(), isEmpty);
    });

    test('this process\'s other isolate is left alone while it beats', () async {
      final background = await open('same');
      await background.posts.upsert(_publishing('p'));
      await background.publishJournal.record('p');

      final ui = await open('same');
      expect(await ui.recoverInterruptedPublishing(atStartup: true), 0);
      expect((await ui.posts.get('p'))!.status, PostStatus.publishing);
    });

    test('a request that was making the post says it may be live, even at once', () async {
      final killed = await open('pid1:100');
      await killed.posts.upsert(_publishing('p'));
      await killed.publishJournal.record('p');
      await killed.publishJournal.beginCreate('p', 'acct-0');

      final next = await open('pid2:200');
      await next.recoverInterruptedPublishing();
      final error = (await next.posts.get('p'))!.targets.single.result!.error!;
      expect(error.outcomeUnknown, isTrue);
      expect(error.retryable, isFalse);
    });

    test('when Android says the person stopped the app, the words say so', () async {
      final killed = await open('pid1:100');
      await killed.posts.upsert(_publishing('p'));
      await killed.publishJournal.record('p');

      final next = await open('pid2:200');
      next.interruptionMessage = AppServices.stoppedByUserMessage;
      await next.recoverInterruptedPublishing();
      expect((await next.posts.get('p'))!.targets.single.result!.error!.message, 'You stopped NEFORUM while it was posting. Retry it.');
    });

    test('the numbers of ApplicationExitInfo that mean the person', () {
      expect(kExitReasonsByUser, {10, 11});
    });
  });

  group('callbackDispatcher', () {
    test('settles a dead run first and reports it, without the post\'s words', () async {
      final killed = await open('pid1:100');
      await killed.posts.upsert(_publishing('dead'));
      await killed.publishJournal.record('dead');

      final worker = await open('pid2:200');
      final shown = <String>[];
      await runBackgroundPublish(worker, show: ({required key, required title, required body, payload}) async => shown.add('$key|$title|$body|$payload'));

      expect(shown, ['result:dead|Posting stopped|${AppServices.interruptedMessage}|post:dead']);
      expect((await worker.posts.get('dead'))!.status, isNot(PostStatus.publishing));
      expect(shown.single, isNot(contains('private words')));
    });

    test('a post that may be live says check first, not retry', () async {
      final killed = await open('pid1:100');
      await killed.posts.upsert(_publishing('dead'));
      await killed.publishJournal.record('dead');
      await killed.publishJournal.beginCreate('dead', 'acct-0');

      final worker = await open('pid2:200');
      final shown = <String>[];
      await runBackgroundPublish(worker, show: ({required key, required title, required body, payload}) async => shown.add(body));
      expect(shown.single, 'A network may have it. Check before you retry.');
    });

    test('a run still beating in this process is not touched and nothing is said', () async {
      final ui = await open('same');
      await ui.posts.upsert(_publishing('alive'));
      await ui.publishJournal.record('alive');

      final worker = await open('same');
      final shown = <String>[];
      await runBackgroundPublish(worker, show: ({required key, required title, required body, payload}) async => shown.add(key));
      expect(shown, isEmpty);
      expect((await worker.posts.get('alive'))!.status, PostStatus.publishing);
    });

    test('notifyOnPublish off: settled, not announced', () async {
      final killed = await open('pid1:100');
      await killed.posts.upsert(_publishing('dead'));
      await killed.publishJournal.record('dead');

      final worker = await open('pid2:200');
      await worker.saveSettings(worker.settings.copyWith(notifyOnPublish: false));
      final shown = <String>[];
      await runBackgroundPublish(worker, show: ({required key, required title, required body, payload}) async => shown.add(key));
      expect(shown, isEmpty);
      expect((await worker.posts.get('dead'))!.status, isNot(PostStatus.publishing));
    });

    test('a failure of recovery does not stop what is due', () async {
      final worker = await open('pid2:200');
      await File('${dir.path}/publish-journal.json').writeAsString('{"p1": ');
      expect(await runBackgroundPublish(worker, show: ({required key, required title, required body, payload}) async {}), 0);
    });
  });

  group('process identity', () {
    test('pid and start time, past a name with spaces and brackets', () {
      const stat = '4242 (org.neforum (x) y) S 1 4242 4242 0 -1 4194624 100 0 0 0 5 5 0 0 20 0 30 0 987654 1000 200';
      expect(processIdentityFrom(4242, stat), '4242:987654');
    });

    test('nothing readable leaves the pid', () {
      expect(processIdentityFrom(7, null), '7');
      expect(processIdentityFrom(7, 'garbage'), '7');
      expect(processIdentityFrom(7, '7 (short) S 1'), '7');
    });

    test('tests run as a computer, which names no process', () {
      expect(publishProcessIdentity(), isNull);
    });
  });

  group('the probe', () {
    test('the account the prepare hook stores is the one the app publishes with, after startup as runNeforum runs it', () async {
      // runNeforum leaves the sign-in dates running (unawaited) while prepare stores
      // the account. On CI's emulator the dates' late first read of accounts.json
      // replaced the cache, and the tapped post failed with "This account was
      // removed". Many fresh starts, since the order of two file reads decides it.
      for (var i = 0; i < 25; i++) {
        final st = await openAppStorage(overrideDir: (await Directory('${dir.path}/start-$i').create()).path);
        final s = await openWorkspace(st, prepare: (s) => seedBackgroundProbe(s, 'http://127.0.0.1:9'));
        opened.add(s);
        expect(s.demo, isFalse);
        // What startup left running reads the file meanwhile.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect((await s.accounts.get(kProbeAccountId))?.id, kProbeAccountId, reason: 'start $i: the account the UI publishes with');
        expect((await s.posts.get(kProbePostId))!.targets.single.accountId, kProbeAccountId);
      }
    });

    test('the fake server takes the real adapter through its steps, and one status comes of it', () async {
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = overrides);
      final log = <String>[];
      final server = FakeMastodon(hold: const Duration(seconds: 3), log: log.add);
      await server.start();
      addTearDown(server.stop);

      final s = await open('me');
      await seedBackgroundProbe(s, 'http://127.0.0.1:${server.port}');
      final done = await s.publisher().publish(kProbePostId, interactive: false);

      expect(done.status, PostStatus.published, reason: '${done.targets.single.result?.error?.message}');
      final steps = log.where((l) => l != 'media-poll').toList();
      expect(steps.first, startsWith('media-created'));
      expect(steps, containsAllInOrder(['media-ready', 'status-created n=1']));
      expect(steps.where((l) => l.startsWith('unexpected')), isEmpty, reason: '$log');
      expect(log.where((l) => l.startsWith('status-created')), hasLength(1));
      expect(log, contains('media-poll'), reason: 'the wait the swipe happens during');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
