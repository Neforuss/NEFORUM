// What happens to a post around publishing: the composer is emptied at
// once, finished posts are deleted as Settings says, interrupted runs and
// unused files are cleaned up at startup, runs can be cancelled, failed
// posts can be cleared together, and times follow the clock setting.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/notifications.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/platform/storage_maintenance.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/composer_draft.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/scheduler.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/activity/time_format.dart';
import 'package:neforum_app/ui/compose/publish_progress_sheet.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _MemoryStorage implements AppStorage {
  final Map<String, Object> _json = {};
  final Map<String, Uint8List> _media = {};
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => _json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => _json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async {
    final path = 'mem://$id.$extension';
    _media[path] = bytes;
    return path;
  }

  @override
  Future<Uint8List> readMedia(String path) async => _media[path]!;
  @override
  Future<void> deleteMedia(String path) async => _media.remove(path);
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => SizedBox(width: width, height: height);
}

final _now = DateTime(2026, 10, 25, 18);

Post _post(String id, {PostStatus status = PostStatus.published, List<TargetStatus> targets = const [TargetStatus.published], DateTime? updatedAt, List<MediaAttachment> media = const []}) => Post(
      id: id,
      text: 'Post $id',
      createdAt: _now.subtract(const Duration(days: 40)),
      updatedAt: updatedAt ?? _now,
      status: status,
      media: media,
      targets: [for (var i = 0; i < targets.length; i++) PostTarget(accountId: 'acct-$i', status: targets[i])],
    );

MediaAttachment _media(String path) => MediaAttachment(id: path, path: path, mimeType: 'image/png', sizeBytes: 3);

Future<AppServices> _demo() async => AppServices.create(demo: true, storage: _MemoryStorage());

Future<(AppServices, ProviderContainer)> _demoContainer() async {
  final services = await _demo();
  final container = ProviderContainer(overrides: [servicesProvider.overrideWithValue(services)]);
  // Listened, as the app's screens do: an unlistened provider is paused.
  container.listen(postsProvider, (_, _) {});
  container.listen(accountsProvider, (_, _) {});
  await container.read(accountsProvider.future);
  return (services, container);
}

/// Demo publishing runs on real timers, so these tests run outside the test
/// clock.
void _demoTest(String description, Future<void> Function(AppServices services, ProviderContainer c) body) {
  testWidgets(description, (tester) async {
    await tester.runAsync(() async {
      final (services, c) = await _demoContainer();
      try {
        await body(services, c);
      } finally {
        c.dispose();
      }
    });
  }, timeout: const Timeout(Duration(minutes: 1)));
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// The app's own fonts: the test font is too wide for the sidebar.
Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
    }
    await loader.load();
  }

  await family('Inter', ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-Medium.ttf', 'assets/fonts/Inter-SemiBold.ttf', 'assets/fonts/Inter-Bold.ttf']);
  await family('Bricolage', ['assets/fonts/BricolageGrotesque-SemiBold.ttf', 'assets/fonts/BricolageGrotesque-Bold.ttf', 'assets/fonts/BricolageGrotesque-ExtraBold.ttf']);
  await family('JetBrainsMono', ['assets/fonts/JetBrainsMono-Regular.ttf']);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadFonts);

  group('retention', () {
    test('complete means every network has it; drafts, runs, failures and waiting hand-offs never are', () {
      expect(isPostComplete(_post('a', targets: [TargetStatus.published, TargetStatus.handedOff, TargetStatus.skipped]), _now), isTrue);
      expect(isPostComplete(_post('b', status: PostStatus.partial, targets: [TargetStatus.published, TargetStatus.awaitingHandoff]), _now), isFalse);
      expect(isPostComplete(_post('c', status: PostStatus.partial, targets: [TargetStatus.published, TargetStatus.failed]), _now), isFalse);
      expect(isPostComplete(_post('d', status: PostStatus.cancelled, targets: [TargetStatus.cancelled]), _now), isFalse);
      expect(isPostComplete(_post('e', status: PostStatus.publishing), _now), isFalse);
      expect(isPostComplete(_post('f', status: PostStatus.draft, targets: [TargetStatus.pending]), _now), isFalse);
      expect(isPostComplete(_post('g', targets: const []), _now), isFalse);

      PostTarget held(DateTime at) => PostTarget(accountId: 'h', status: TargetStatus.heldByPlatform, result: PublishResult.scheduled(remoteId: 'r', scheduledFor: at));
      final past = _post('h', status: PostStatus.scheduled).copyWith(targets: [held(_now.subtract(const Duration(minutes: 1)))]);
      final future = _post('i', status: PostStatus.scheduled).copyWith(targets: [held(_now.add(const Duration(hours: 1)))]);
      expect(isPostComplete(past, _now), isTrue, reason: 'held by its platform and published there');
      expect(isPostComplete(future, _now), isFalse);
    });

    test('a post that reached no network is never complete, so it is never deleted', () {
      final nowhere = _post('j', targets: [TargetStatus.skipped, TargetStatus.skipped]);
      expect(isPostComplete(nowhere, _now), isFalse, reason: 'every account switched off: it stays in Activity');
      for (final r in PublishedPostRetention.values) {
        expect(expiredPosts([nowhere.copyWith(updatedAt: _now.subtract(const Duration(days: 90)))], r, _now), isEmpty, reason: r.name);
      }
      expect(isPostComplete(_post('k', targets: [TargetStatus.handedOff, TargetStatus.skipped]), _now), isTrue);
    });

    test('Delete it right away sweeps only posts every network really got', () {
      PostTarget held(DateTime at) => PostTarget(accountId: 'h', status: TargetStatus.heldByPlatform, result: PublishResult.scheduled(remoteId: 'r', scheduledFor: at));
      final posts = [
        _post('everywhere', targets: [TargetStatus.published, TargetStatus.handedOff]),
        _post('released', status: PostStatus.scheduled).copyWith(targets: [held(_now.subtract(const Duration(minutes: 1)))]),
        _post('one skipped', targets: [TargetStatus.published, TargetStatus.skipped]),
        _post('nowhere', targets: [TargetStatus.skipped]),
        _post('failed', status: PostStatus.failed, targets: [TargetStatus.failed]),
        _post('held', status: PostStatus.scheduled).copyWith(targets: [held(_now.add(const Duration(hours: 1)))]),
      ];
      expect(expiredPosts(posts, PublishedPostRetention.discardOnCompletion, _now).map((p) => p.id), ['everywhere', 'released']);
      expect(reachedEveryNetwork(posts[2], _now), isFalse);
      expect(isPostComplete(posts[2], _now), isTrue, reason: 'deleted the moment it completes, but not by a sweep');
    });

    test('notifications count only networks that got the post and never call a post nobody got live', () {
      final skipped = _post('n', targets: [TargetStatus.skipped, TargetStatus.skipped]);
      final notice = publishResultNotice(skipped, discarded: false, notifyOnPublish: true)!;
      expect(notice.title, 'Not posted');
      expect(notice.body, contains('switched off'));
      expect(notice.body, isNot(contains('live')));
      expect(notice.payload, 'post:n', reason: 'the post is still there to open');

      final mixed = publishResultNotice(_post('m', targets: [TargetStatus.published, TargetStatus.handedOff, TargetStatus.skipped]), discarded: true, notifyOnPublish: true)!;
      expect(mixed.title, 'Posted to 2 networks');
      expect(mixed.payload, isNull, reason: 'deleted: nothing to open');
      expect(publishResultNotice(skipped, discarded: false, notifyOnPublish: false), isNull);
    });

    test('deleted right away, after 7 or 30 days, or never', () {
      final posts = [
        _post('new', updatedAt: _now.subtract(const Duration(hours: 1))),
        _post('week', updatedAt: _now.subtract(const Duration(days: 8))),
        _post('month', updatedAt: _now.subtract(const Duration(days: 31))),
        _post('failed', status: PostStatus.failed, targets: [TargetStatus.failed], updatedAt: _now.subtract(const Duration(days: 90))),
      ];
      List<String> ids(PublishedPostRetention r) => expiredPosts(posts, r, _now).map((p) => p.id).toList();
      expect(ids(PublishedPostRetention.discardOnCompletion), ['new', 'week', 'month']);
      expect(ids(PublishedPostRetention.retainSevenDays), ['week', 'month']);
      expect(ids(PublishedPostRetention.retainThirtyDays), ['month']);
      expect(ids(PublishedPostRetention.retainIndefinitely), isEmpty);
    });
  });

  group('unused files', () {
    test('a file counts as used when any post or draft names it anywhere; fresh files are spared', () {
      final referenced = referencedFileNames([
        _post('p', media: [_media(r'C:\Users\me\AppData\neforum\media\AAA.png')]).toJson(),
        {'textCardBackground': {'path': '/data/media/bbb.jpg'}},
        null,
      ]);
      expect(referenced, containsAll(['aaa.png', 'bbb.jpg']));
      final files = <StoredFile>[
        (path: r'C:\data\media\aaa.png', modified: _now.subtract(const Duration(days: 3))),
        (path: '/data/media/bbb.jpg', modified: _now.subtract(const Duration(days: 3))),
        (path: '/data/media/ccc.png', modified: _now.subtract(const Duration(hours: 2))),
        (path: '/data/media/ddd.png', modified: _now.subtract(const Duration(minutes: 2))),
      ];
      expect(unreferencedMediaFiles(files, referenced, now: _now), ['/data/media/ccc.png']);
      expect(unreferencedMediaFiles(files, referenced, now: _now, grace: Duration.zero), ['/data/media/ccc.png', '/data/media/ddd.png']);
    });

    test('share-sheet copies older than a day are deleted with their folders', () async {
      final tmp = await Directory.systemTemp.createTemp('neforum-share-test-');
      addTearDown(() => tmp.delete(recursive: true));
      final old = File('${tmp.path}/neforum-share/2026-10-20 instagram/photo.jpg')..createSync(recursive: true);
      old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
      final fresh = File('${tmp.path}/neforum-share/today tiktok/photo.jpg')..createSync(recursive: true);
      expect(await deleteExpiredShareExports(temporaryDir: tmp.path), 1);
      expect(old.existsSync(), isFalse);
      expect(old.parent.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
    });

    test('every notification about a post is cancelled with it', () {
      expect(NotificationService.postKeys('p1'), ['due:p1', 'result:p1', 'handoff:p1']);
    });
  });

  group('startup housekeeping', () {
    late Directory dir;
    late AppStorage storage;
    late AppServices services;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('neforum-housekeeping-');
      storage = await openAppStorage(overrideDir: dir.path);
      services = await AppServices.create(demo: false, storage: storage);
    });
    tearDown(() async {
      services.dispose();
      await dir.delete(recursive: true);
    });

    Future<String> file(String id, {bool fresh = false}) async {
      final path = await storage.saveMedia(id, 'png', Uint8List.fromList([1, 2, 3]));
      if (!fresh) File(path).setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
      return path;
    }

    /// Puts a run of [postId] on record the way another process does,
    /// last alive [ago].
    Future<void> runOnRecord(String postId, {required Duration ago, String owner = 'closed-process'}) =>
        JsonFileStore.openPublishJournal(storage.dataDir!, owner: owner, clock: () => DateTime.now().subtract(ago)).record(postId);

    test('interrupted runs become failures with Retry; finished posts and unused files go', () async {
      final failedPhoto = await file('failed-photo');
      final draftPhoto = await file('draft-photo');
      final strayPhoto = await file('stray-photo');
      final justAdded = await file('just-added', fresh: true);
      final postedPhoto = await file('posted-photo');
      final lastProgress = DateTime(2026, 10, 25, 17, 59);
      await services.posts.upsert(_post('interrupted',
          status: PostStatus.publishing, targets: [TargetStatus.published, TargetStatus.pending, TargetStatus.publishing], updatedAt: lastProgress));
      await runOnRecord('interrupted', ago: const Duration(hours: 1));
      await services.posts.upsert(_post('done', media: [_media(postedPhoto)]));
      await services.posts.upsert(_post('failed', status: PostStatus.failed, targets: [TargetStatus.failed], media: [_media(failedPhoto)]));
      await storage.writeJson(kComposerDraftFile, {'v': 1, 'post': _post('composer', status: PostStatus.draft, media: [_media(draftPhoto)]).toJson()});

      await services.performStartupMaintenance();

      final interrupted = (await services.posts.get('interrupted'))!;
      expect(interrupted.targets.map((t) => t.status), [TargetStatus.published, TargetStatus.failed, TargetStatus.failed]);
      expect(interrupted.targets[1].result!.error!.message, AppServices.interruptedMessage);
      expect(interrupted.status, PostStatus.partial);
      expect(interrupted.updatedAt, lastProgress, reason: 'a newer real result from anywhere still wins a sync merge');
      expect(await services.publishJournal.entries(), isEmpty, reason: 'the run is settled');
      expect(await services.posts.get('done'), isNull, reason: 'deleted on completion by default');
      expect(await services.posts.get('failed'), isNotNull);
      expect(File(postedPhoto).existsSync(), isFalse);
      expect(File(strayPhoto).existsSync(), isFalse);
      expect(File(failedPhoto).existsSync(), isTrue);
      expect(File(draftPhoto).existsSync(), isTrue, reason: 'the post being written still shows it');
      expect(File(justAdded).existsSync(), isTrue, reason: 'may belong to a post being written right now');
      // The deletion is on disk, not only in the cache.
      expect((await JsonFileStore(storage.dataDir!).posts.all()).map((p) => p.id), unorderedEquals(['interrupted', 'failed']));
    });

    test('a run another isolate is still executing, and a post that arrived mid-run from another device, are left alone', () async {
      await services.posts.upsert(_post('background', status: PostStatus.publishing, targets: [TargetStatus.pending]));
      await runOnRecord('background', ago: const Duration(seconds: 20), owner: 'workmanager-isolate');
      await services.posts.upsert(_post('synced', status: PostStatus.publishing, targets: [TargetStatus.published, TargetStatus.pending], updatedAt: DateTime.now()));

      await services.performStartupMaintenance();

      final background = (await services.posts.get('background'))!;
      expect(background.status, PostStatus.publishing);
      expect(background.targets.single.status, TargetStatus.pending, reason: 'Android WorkManager may be posting it right now');
      expect((await services.posts.get('synced'))!.targets.last.status, TargetStatus.pending, reason: 'its own device\'s result follows through sync');
      expect((await services.publishJournal.entries()).keys, ['background']);

      // Once the background run has been silent for long enough, it is settled.
      expect(await services.recoverInterruptedPublishing(now: DateTime.now().add(const Duration(minutes: 11))), 1);
      expect((await services.posts.get('background'))!.targets.single.status, TargetStatus.failed);
      expect((await services.posts.get('synced'))!.status, PostStatus.publishing);
    });

    test('a background run that fell silent is settled from what it saved: the networks it reached keep the post', () async {
      await services.posts.upsert(_post('background', status: PostStatus.publishing, targets: [TargetStatus.pending, TargetStatus.pending, TargetStatus.pending]));
      expect((await services.posts.get('background'))!.targets.first.status, TargetStatus.pending, reason: 'the UI has the post in its cache');

      // The WorkManager isolate opens the same folder, posts to two networks
      // and saves that progress, then is stopped during the third upload.
      final background = JsonFileStore(storage.dataDir!);
      var progress = (await background.posts.get('background'))!;
      for (final i in [0, 1]) {
        progress = progress.withTarget(PostTarget(
          accountId: 'acct-$i',
          status: TargetStatus.published,
          result: PublishResult.ok(remoteId: 'remote-$i', remoteUrl: 'https://example.social/remote-$i'),
        ));
        await background.posts.upsert(progress);
      }
      await runOnRecord('background', ago: const Duration(minutes: 15), owner: 'workmanager-isolate');

      expect(await services.recoverInterruptedPublishing(), 1);
      final settled = (await services.posts.get('background'))!;
      expect(settled.targets.map((t) => t.status), [TargetStatus.published, TargetStatus.published, TargetStatus.failed]);
      expect(settled.targets.first.result!.remoteUrl, 'https://example.social/remote-0');
      expect(settled.status, PostStatus.partial);
      final onDisk = (await JsonFileStore(storage.dataDir!).posts.get('background'))!;
      expect(onDisk.targets.map((t) => t.status), [TargetStatus.published, TargetStatus.published, TargetStatus.failed]);
      expect(onDisk.targets[1].result!.remoteId, 'remote-1', reason: 'a retry posts only to the third network');
    });

    test('what a background run saved is never written over by the copy the UI read before', () async {
      await services.posts.upsert(_post('kept', status: PostStatus.publishing, targets: [TargetStatus.pending]));
      await services.posts.upsert(_post('discarded', status: PostStatus.publishing, targets: [TargetStatus.pending]));
      expect(await services.posts.all(), hasLength(2));

      // The background run posts both, then deletes one of them.
      final background = JsonFileStore(storage.dataDir!);
      final kept = (await background.posts.get('kept'))!;
      await background.posts.upsert(kept.copyWith(
        status: PostStatus.published,
        targets: [PostTarget(accountId: 'acct-0', status: TargetStatus.published, result: PublishResult.ok(remoteId: 'remote-0'))],
      ));
      await background.posts.delete('discarded');

      // The UI saves another post.
      await services.posts.upsert(_post('next', status: PostStatus.draft, targets: [TargetStatus.pending]));

      final onDisk = await JsonFileStore(storage.dataDir!).posts.all();
      expect(onDisk.map((p) => p.id), unorderedEquals(['kept', 'next']), reason: 'a deleted post does not come back');
      expect(onDisk.firstWhere((p) => p.id == 'kept').targets.single.result!.remoteId, 'remote-0');
      expect((await services.posts.get('kept'))!.status, PostStatus.published, reason: 'Activity shows it posted, not publishing');
    });

    test('a post NEFORUM 1.1.5 left publishing gets Retry at startup once it has not changed for two hours', () async {
      final longAgo = DateTime.now().subtract(const Duration(hours: 3));
      await services.posts.upsert(_post('left by 1.1.5', status: PostStatus.publishing, targets: [TargetStatus.published, TargetStatus.pending], updatedAt: longAgo));
      await services.posts.upsert(_post('recent', status: PostStatus.publishing, targets: [TargetStatus.pending], updatedAt: DateTime.now().subtract(const Duration(minutes: 30))));
      // A run saves its progress without changing the post's own time.
      final progressing = _post('progressing', status: PostStatus.publishing, targets: [TargetStatus.pending, TargetStatus.pending], updatedAt: longAgo);
      await services.posts.upsert(progressing.withTarget(
        progressing.targets.first.copyWith(status: TargetStatus.published, lastAttemptAt: DateTime.now().subtract(const Duration(minutes: 5))),
      ));
      expect(await services.publishJournal.entries(), isEmpty, reason: 'no run on record');

      // The recovery pass every few minutes leaves them alone.
      expect(await services.recoverInterruptedPublishing(), 0);
      expect((await services.posts.get('left by 1.1.5'))!.status, PostStatus.publishing);

      await services.performStartupMaintenance();

      final left = (await services.posts.get('left by 1.1.5'))!;
      expect(left.targets.map((t) => t.status), [TargetStatus.published, TargetStatus.failed]);
      expect(left.targets.last.result!.error!.message, AppServices.interruptedMessage);
      expect(needsRetry(left.targets.last), isTrue);
      expect(left.status, PostStatus.partial);
      expect(left.updatedAt.isAtSameMomentAs(longAgo), isTrue, reason: 'a newer real result from anywhere still wins a sync merge');
      expect((await services.posts.get('recent'))!.status, PostStatus.publishing, reason: 'changed recently: a run may still be posting it');
      expect((await services.posts.get('progressing'))!.targets.last.status, TargetStatus.pending);
    });

    test('the first start after the update deletes only the posts every network really got', () async {
      // A settings file from before 1.2.0: no retention choice, so the
      // default (delete right away) applies to the history it kept.
      await storage.writeJson('settings.json', {'onboarded': true, 'notifyOnPublish': true});
      services.dispose();
      services = await AppServices.create(demo: false, storage: storage);
      expect(services.settings.publishedPostRetention, PublishedPostRetention.discardOnCompletion);
      final months = DateTime.now().subtract(const Duration(days: 120));
      final keptPhoto = await file('kept-photo');
      for (final p in [
        _post('everywhere', targets: [TargetStatus.published, TargetStatus.handedOff], updatedAt: months),
        _post('one skipped', targets: [TargetStatus.published, TargetStatus.skipped], updatedAt: months, media: [_media(keptPhoto)]),
        _post('nowhere', targets: [TargetStatus.skipped, TargetStatus.skipped], updatedAt: months),
        _post('failed', status: PostStatus.failed, targets: [TargetStatus.failed], updatedAt: months),
      ]) {
        await services.posts.upsert(p);
      }

      await services.performStartupMaintenance();

      expect((await services.posts.all()).map((p) => p.id), unorderedEquals(['one skipped', 'nowhere', 'failed']));
      expect(File(keptPhoto).existsSync(), isTrue);
    });

    test('a run that stopped in this process is settled at once: what went out stays, the rest gets Retry', () async {
      await services.posts.upsert(_post('stopped', status: PostStatus.publishing, targets: [TargetStatus.published, TargetStatus.pending]));
      await services.publishJournal.record('stopped');
      await services.concludeStoppedRun('stopped', StateError('card renderer failed'));
      final stopped = (await services.posts.get('stopped'))!;
      expect(stopped.targets.map((t) => t.status), [TargetStatus.published, TargetStatus.failed]);
      expect(stopped.targets.last.result!.error!.message, contains('card renderer failed'));
      expect(needsRetry(stopped.targets.last), isTrue);
      expect(stopped.status, PostStatus.partial);
      expect(await services.publishJournal.entries(), isEmpty);

      // An outcome the run could not save is saved instead: it knows which
      // networks have the post, so a retry never posts it twice.
      await services.posts.upsert(_post('unsaved', status: PostStatus.publishing, targets: [TargetStatus.pending, TargetStatus.pending]));
      final outcome = _post('unsaved', targets: [TargetStatus.published, TargetStatus.published]);
      await services.concludeStoppedRun('unsaved', PublishOutcomeNotSaved(outcome, StateError('posts.json is locked')));
      expect((await services.posts.get('unsaved'))!.targets.map((t) => t.status), [TargetStatus.published, TargetStatus.published]);

      // A post another isolate is publishing is not touched.
      await services.posts.upsert(_post('elsewhere', status: PostStatus.publishing, targets: [TargetStatus.pending]));
      await runOnRecord('elsewhere', ago: const Duration(seconds: 5), owner: 'workmanager-isolate');
      await services.concludeStoppedRun('elsewhere', StateError('boom'));
      expect((await services.posts.get('elsewhere'))!.targets.single.status, TargetStatus.pending);
    });

    test('kept posts expire after their days', () async {
      // Settings as a later start reads them (saving them here would reach
      // for the keychain).
      await storage.writeJson('settings.json', const AppSettings(publishedPostRetention: PublishedPostRetention.retainSevenDays).toJson());
      services.dispose();
      services = await AppServices.create(demo: false, storage: storage);
      await services.posts.upsert(_post('old', updatedAt: DateTime.now().subtract(const Duration(days: 8))));
      await services.posts.upsert(_post('recent', updatedAt: DateTime.now().subtract(const Duration(days: 6))));
      expect(await services.applyRetention(), 1);
      expect((await services.posts.all()).map((p) => p.id), ['recent']);
    });

    test('publishing empties the draft file at once; other changes wait a moment', () async {
      final container = ProviderContainer(overrides: [servicesProvider.overrideWithValue(services)]);
      addTearDown(container.dispose);
      container.listen(composerDraftKeeperProvider, (_, _) {});
      final keeper = container.read(composerDraftKeeperProvider)!;
      while (!keeper.restored) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final composer = container.read(composerProvider.notifier);
      composer.setText('Going out now');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await storage.readJson(kComposerDraftFile), isNull, reason: 'typing is written after a pause');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect((await storage.readJson(kComposerDraftFile))!['post'], isNotNull);

      await container.read(postActionsProvider).publishNow();
      expect(container.read(composerProvider).text, isEmpty);
      expect(await storage.readJson(kComposerDraftFile), isEmpty, reason: 'written before publishNow returned, no pause');
      expect(await services.publishJournal.entries(), isEmpty, reason: 'a finished run leaves nothing on record');
    });
  });

  group('publishing actions', () {
    _demoTest('publishNow empties the composer as soon as the post is saved; a finished post is deleted', (services, c) async {
      final accounts = c.read(accountListProvider).where((a) => a.platformId == 'mastodon' || a.platformId == 'bluesky').map((a) => a.id).toList();
      c.read(composerProvider.notifier)
        ..setText('Fresh news')
        ..selectAccounts(accounts);
      bool? emptyWhenRunStarted;
      c.listen<PublishRun?>(publishRunProvider, (prev, next) {
        if (next?.postId != null && prev?.postId == null) emptyWhenRunStarted = c.read(composerProvider).isEmpty;
      });

      final done = await c.read(postActionsProvider).publishNow();
      expect(emptyWhenRunStarted, isTrue);
      expect(done.status, PostStatus.published);
      expect(await services.posts.get(done.id), isNull, reason: 'NEFORUM keeps no copy once every network has it');
      final run = c.read(publishRunProvider)!;
      expect(run.done, isTrue);
      expect(run.result!.targets.every((t) => t.status == TargetStatus.published), isTrue, reason: 'the sheet still shows the outcome');
      expect(c.read(activePublishingProvider), isEmpty);
    });

    _demoTest('a kept post stays in Activity', (services, c) async {
      await services.saveSettings(services.settings.copyWith(publishedPostRetention: PublishedPostRetention.retainIndefinitely));
      final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon').id;
      c.read(composerProvider.notifier)
        ..setText('Keep this one')
        ..selectAccounts([masto]);
      final done = await c.read(postActionsProvider).publishNow();
      expect((await services.posts.get(done.id))!.status, PostStatus.published);
    });

    _demoTest('a run cancelled before it starts cancels every target; nothing is left publishing', (services, c) async {
      final ids = c.read(accountListProvider).where((a) => a.platformId == 'mastodon' || a.platformId == 'bluesky').map((a) => a.id).toList();
      c.read(composerProvider.notifier)
        ..setText('Wait, not yet')
        ..selectAccounts(ids);
      final draft = await c.read(postActionsProvider).saveDraft();

      final actions = c.read(postActionsProvider);
      final running = actions.publishExisting(draft.id);
      expect(c.read(activePublishingProvider).containsKey(draft.id), isTrue, reason: 'Activity shows Cancel');
      actions.cancelPublishing(draft.id);
      final p = await running;

      expect(p.status, PostStatus.cancelled);
      expect(p.targets.map((t) => t.status).toSet(), {TargetStatus.cancelled});
      expect((await services.posts.get(draft.id))!.status, PostStatus.cancelled);
      expect(c.read(activePublishingProvider), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.read(needsAttentionProvider).map((x) => x.id), contains(draft.id));

      // Cancelled networks are retried like failed ones.
      final again = await actions.publishExisting(draft.id);
      expect(again.status, PostStatus.published);
    });

    _demoTest('Clear failed deletes posts that reached nobody and skips the failed networks of the rest', (services, c) async {
      await services.saveSettings(services.settings.copyWith(publishedPostRetention: PublishedPostRetention.retainIndefinitely));
      final nobody = _post('nobody', status: PostStatus.failed, targets: [TargetStatus.failed, TargetStatus.cancelled]);
      final some = _post('some', status: PostStatus.partial, targets: [TargetStatus.published, TargetStatus.failed]);
      final waiting = _post('waiting', status: PostStatus.partial, targets: [TargetStatus.awaitingHandoff, TargetStatus.failed]);
      for (final p in [nobody, some, waiting]) {
        await services.posts.upsert(p);
      }
      final result = await c.read(postActionsProvider).clearFailed([nobody, some, waiting]);
      expect(result.deleted, 1);
      expect(result.kept, 2);
      expect(await services.posts.get('nobody'), isNull);
      final kept = (await services.posts.get('some'))!;
      expect(kept.targets.map((t) => t.status), [TargetStatus.published, TargetStatus.skipped]);
      expect(kept.status, PostStatus.published);
      final stillWaiting = (await services.posts.get('waiting'))!;
      expect(stillWaiting.targets.map((t) => t.status), [TargetStatus.awaitingHandoff, TargetStatus.skipped]);
      expect(stillWaiting.status, PostStatus.partial);
    });

    _demoTest('with the default setting a post Clear failed completes is deleted too', (services, c) async {
      final some = _post('some', status: PostStatus.partial, targets: [TargetStatus.published, TargetStatus.failed]);
      await services.posts.upsert(some);
      await c.read(postActionsProvider).clearFailed([some]);
      expect(await services.posts.get('some'), isNull);
    });

    _demoTest('a post whose every account is switched off reached nobody, so it is kept', (services, c) async {
      final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon');
      c.read(composerProvider.notifier)
        ..setText('Nobody will see this')
        ..selectAccounts([masto.id]);
      final draft = await c.read(postActionsProvider).saveDraft();
      await services.accounts.upsert(masto.copyWith(enabled: false));
      final done = await c.read(postActionsProvider).publishExisting(draft.id);
      expect(done.targets.single.status, TargetStatus.skipped);
      expect(done.targets.single.result!.error!.message, contains('switched off'));
      expect(await services.posts.get(draft.id), isNotNull, reason: 'deleting it would lose the text and photos');
    });

    _demoTest('a run that stops with an error leaves nothing looking busy: the networks it did not reach get Retry', (services, c) async {
      final accounts = c.read(accountListProvider);
      final masto = accounts.firstWhere((a) => a.platformId == 'mastodon').id;
      final bsky = accounts.firstWhere((a) => a.platformId == 'bluesky').id;
      // Mastodon holds a copy it is about to publish, so it cannot be taken
      // back and the run stops before it starts.
      await services.posts.upsert(Post(
        id: 'left',
        text: 'Going out',
        createdAt: _now,
        updatedAt: _now,
        status: PostStatus.publishing,
        targets: [
          PostTarget(accountId: masto, status: TargetStatus.heldByPlatform, result: PublishResult.scheduled(remoteId: 'held', scheduledFor: DateTime.now().add(const Duration(minutes: 1)))),
          PostTarget(accountId: bsky),
        ],
      ));
      await expectLater(c.read(postActionsProvider).publishExisting('left'), throwsA(isA<HeldCopiesException>()));
      final left = (await services.posts.get('left'))!;
      expect(left.status, isNot(PostStatus.publishing));
      expect(left.targetFor(bsky)!.status, TargetStatus.failed);
      expect(needsRetry(left.targetFor(bsky)!), isTrue);
      expect(left.targetFor(masto)!.status, TargetStatus.heldByPlatform, reason: 'Mastodon still publishes its copy');
      expect(c.read(publishRunProvider)!.error, isNotNull);
      expect(c.read(activePublishingProvider), isEmpty);
    });

    _demoTest('a run that cannot start says why, and the sheet can be closed', (_, c) async {
      await expectLater(c.read(postActionsProvider).publishExisting('missing'), throwsStateError);
      final run = c.read(publishRunProvider)!;
      expect(run.done, isTrue);
      expect(run.error, contains('not found'));
      expect(c.read(activePublishingProvider), isEmpty);
    });
  });

  group('progress sheet', () {
    Future<ProviderContainer> open(WidgetTester tester, {Size size = const Size(1200, 900)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final services = (await tester.runAsync(_demo))!;
      await tester.pumpWidget(ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AccentChoice.neforum),
          home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () => showPublishProgress(context), child: const Text('open')))),
        ),
      ));
      return ProviderScope.containerOf(tester.element(find.text('open')));
    }

    for (final size in const {'desktop': Size(1200, 900), 'phone': Size(380, 800)}.entries) {
      testWidgets('getting ready and cancelling, then an error with Close (${size.key})', (tester) async {
        final c = await open(tester, size: size.value);
        c.read(publishRunProvider.notifier).prepare();
        await tester.tap(find.text('open'));
        await settle(tester);
        expect(find.text('Getting your post ready…'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pump();
        expect(find.text('Cancelling…'), findsWidgets);
        expect(c.read(publishRunProvider)!.cancellation.isCancelled, isTrue);

        c.read(publishRunProvider.notifier).fail(null, const HeldCopiesException(platforms: ['Mastodon'], reason: 'offline'));
        await tester.pump();
        expect(find.text('Could not post'), findsOneWidget);
        expect(find.textContaining('Mastodon still holds'), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('Could not post'), findsNothing);
        expect(c.read(publishRunProvider), isNull);
      });
    }

    testWidgets('a cancelled run says so and offers Retry', (tester) async {
      final c = await open(tester);
      final run = c.read(publishRunProvider.notifier);
      run.start('p1', ['a', 'b']);
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.text('Cancel'), findsOneWidget);
      run.finish(_post('p1', status: PostStatus.cancelled, targets: [TargetStatus.cancelled, TargetStatus.cancelled]).copyWith(
        targets: const [PostTarget(accountId: 'a', status: TargetStatus.cancelled), PostTarget(accountId: 'b', status: TargetStatus.cancelled)],
      ));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Posting cancelled'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });
  });

  group('Activity', () {
    testWidgets('Clear failed asks with the count, then clears them', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final services = (await tester.runAsync(_demo))!;
      await tester.runAsync(() => services.posts.upsert(_post('nobody', status: PostStatus.failed, targets: [TargetStatus.failed])));
      await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
      await tester.pump(const Duration(milliseconds: 300));
      final c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
      c.read(routerProvider).go('/activity');
      await settle(tester);
      final failed = c.read(failedPostsProvider).length;
      expect(failed, greaterThanOrEqualTo(1));

      await tester.tap(find.textContaining(RegExp(r'^Failed')).first);
      await settle(tester);
      await tester.tap(find.text('Clear failed').first);
      await settle(tester);
      expect(find.text('Clear $failed failed ${failed == 1 ? 'post' : 'posts'}?'), findsOneWidget);
      await tester.tap(find.text('Clear failed').last);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await settle(tester);
      expect(await tester.runAsync(() => services.posts.get('nobody')), isNull);
      expect(c.read(failedPostsProvider), isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('times', () {
    test('exact: weekday, date and time on a 12- or 24-hour clock, in local time', () {
      final t = DateTime(2026, 10, 24, 14, 5);
      expect(const TimeFormatting(exact: true, use24Hour: true).moment(t), 'Saturday, 24 October 2026, 14:05');
      expect(const TimeFormatting(exact: true).moment(t), 'Saturday, 24 October 2026, 2:05 PM');
      expect(const TimeFormatting(exact: true, use24Hour: true).moment(t.toUtc()), 'Saturday, 24 October 2026, 14:05');
      expect(const TimeFormatting(exact: true).day(t), 'Saturday, 24 October 2026');
    });

    test('relative times follow the clock setting and local time', () {
      final yesterday = DateTime(2026, 10, 24, 9, 30);
      expect(relativeTime(yesterday, now: _now, use24Hour: true), 'Yesterday, 09:30');
      expect(relativeTime(yesterday, now: _now), 'Yesterday, 9:30 AM');
      expect(relativeTime(yesterday.toUtc(), now: _now.toUtc(), use24Hour: true), 'Yesterday, 09:30');
      expect(dayLabel(DateTime(2026, 10, 26, 7), now: _now, withTime: true, use24Hour: true), 'Tomorrow, 07:00');
      expect(const TimeFormatting(use24Hour: true).scheduled(DateTime(2026, 10, 26, 7), now: _now), 'Tomorrow, 07:00');
      final local = DateTime.utc(2026, 10, 25, 12).toLocal();
      expect(dayOf(DateTime.utc(2026, 10, 25, 12)), DateTime(local.year, local.month, local.day));
    });

    testWidgets('the System clock follows the device', (tester) async {
      final services = (await tester.runAsync(_demo))!;
      late TimeFormatting format;
      Widget app(bool use24) => ProviderScope(
            overrides: [servicesProvider.overrideWithValue(services)],
            child: MediaQuery(
              data: MediaQueryData(alwaysUse24HourFormat: use24),
              child: Consumer(builder: (context, ref, _) {
                format = TimeFormatting.of(context, ref);
                return const SizedBox();
              }),
            ),
          );
      await tester.pumpWidget(app(true));
      expect(format.use24Hour, isTrue);
      await tester.pumpWidget(app(false));
      expect(format.use24Hour, isFalse);
    });
  });
}
