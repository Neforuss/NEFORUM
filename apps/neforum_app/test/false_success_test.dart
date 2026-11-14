// A post published from the composer is recorded as itself (1.4.3, item 7).
//
// The report: a new post shows going out, Activity marks it posted, yet no
// network has it, and its links open an earlier post. The cause was the
// composer's `editingPostId`: once the post it named had gone out (published by
// a run outside the composer while NEFORUM was in the background, or restored
// from composer.json after it went out), the next post written in the composer
// was saved under that post's id, kept every network's earlier outcome
// ("networks that already have an edited post keep their outcome") and so went
// to no network. The run then credited the old results as posted.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/composer_draft.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
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

/// A demo workspace that keeps finished posts, so their records and links can be
/// read after the run. [storage] carries composer.json between "launches".
Future<(AppServices, ProviderContainer)> _workspace({_MemoryStorage? storage}) async {
  final services = await AppServices.create(demo: true, storage: storage ?? _MemoryStorage());
  await services.saveSettings(services.settings.copyWith(publishedPostRetention: PublishedPostRetention.retainIndefinitely));
  final container = ProviderContainer(overrides: [servicesProvider.overrideWithValue(services)]);
  // Listened, as the app's screens do: an unlistened provider is paused.
  container.listen(postsProvider, (_, _) {});
  container.listen(accountsProvider, (_, _) {});
  container.listen(composerProvider, (_, _) {});
  await container.read(accountsProvider.future);
  await container.read(postsProvider.future);
  return (services, container);
}

/// Two automatic demo accounts.
List<String> _accounts(ProviderContainer c) =>
    c.read(accountListProvider).where((a) => a.platformId == 'mastodon' || a.platformId == 'bluesky').map((a) => a.id).toList();

/// NEFORUM leaves the screen (iOS background, a minimised window) or comes back.
void _goAway(WidgetTester tester) {
  tester.binding
    ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
    ..handleAppLifecycleStateChanged(AppLifecycleState.hidden);
}

void _comeBack(WidgetTester tester) {
  tester.binding
    ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
    ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

/// Lets stream events (the posts list) reach their listeners.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 50));

/// Every network of [second] has a result of its own: none of [first]'s ids or
/// times, which is what "posted" must mean.
void _expectOwnResults(Post second, Post first) {
  final earlier = {for (final t in first.targets) ...?t.result?.allRemoteIds};
  expect(earlier, isNotEmpty, reason: 'the first post went out');
  for (final t in second.targets) {
    expect(t.status, TargetStatus.published, reason: t.accountId);
    final r = t.result!;
    expect(r.remoteId, isNotNull, reason: 'the network answered with an id for this post');
    expect(earlier, isNot(contains(r.remoteId)), reason: '${t.accountId} must not be credited with the earlier post');
    final firstAt = first.targetFor(t.accountId)!.result!.publishedAt!;
    expect(r.publishedAt!.isAfter(firstAt), isTrue, reason: '${t.accountId}: published by this run, not an earlier one');
  }
}

void _demoTest(String description, Future<void> Function(WidgetTester tester) body) {
  testWidgets(description, (tester) async {
    await tester.runAsync(() => body(tester));
    _comeBack(tester);
  }, timeout: const Timeout(Duration(minutes: 1)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  _demoTest('the post being edited went out while NEFORUM was away: the next post is published as itself', (tester) async {
    final (services, c) = await _workspace();
    addTearDown(c.dispose);
    final composer = c.read(composerProvider.notifier);
    final actions = c.read(postActionsProvider);
    final accounts = _accounts(c);

    // A draft, opened again with Edit.
    composer
      ..setText('First post')
      ..selectAccounts(accounts);
    final draft = await actions.saveDraft();
    composer.load((await services.posts.get(draft.id))!);
    expect(c.read(composerProvider).editingPostId, draft.id);

    // The person switches away; the post goes out meanwhile (its reminder's Publish
    // now, the queue's menu, another isolate).
    _goAway(tester);
    final first = await actions.publishExisting(draft.id);
    _comeBack(tester);
    await _settle();
    expect(first.status, PostStatus.published);

    // Back in the composer: the old words go and a new post is written.
    composer
      ..clearPost()
      ..setText('Second post');
    final second = await actions.publishNow();

    expect(second.text, 'Second post');
    expect(second.status, PostStatus.published);
    _expectOwnResults(second, first);
    expect(second.id, isNot(draft.id), reason: 'a post that went out is never the record of a new one');
    final kept = (await services.posts.get(draft.id))!;
    expect(kept.text, 'First post', reason: 'the earlier record keeps its own words');
    expect(kept.targets.map((t) => t.result!.remoteId), first.targets.map((t) => t.result!.remoteId));
  });

  _demoTest('the edited post is going out in another run when Publish is pressed: the new words go out as a new post', (tester) async {
    final (services, c) = await _workspace();
    addTearDown(c.dispose);
    final composer = c.read(composerProvider.notifier);
    final actions = c.read(postActionsProvider);
    final accounts = _accounts(c);
    composer
      ..setText('First post')
      ..selectAccounts(accounts);
    final draft = await actions.saveDraft();
    composer.load((await services.posts.get(draft.id))!);

    // Its time came while NEFORUM was away: a background run has posted it to the
    // first network and is still at the second. The composer keeps editing it
    // (that run may yet fail), so only publishing can tell.
    _goAway(tester);
    final firstAt = DateTime.now();
    final midRun = (await services.posts.get(draft.id))!.copyWith(status: PostStatus.publishing, targets: [
      PostTarget(accountId: accounts[0], status: TargetStatus.published, result: PublishResult.ok(remoteId: 'earlier-1', remoteUrl: 'https://example.social/earlier-1', publishedAt: firstAt)),
      PostTarget(accountId: accounts[1], status: TargetStatus.publishing),
    ]);
    await services.posts.upsert(midRun);
    await _settle();
    _comeBack(tester);
    expect(c.read(composerProvider).editingPostId, draft.id);

    composer
      ..clearPost()
      ..setText('Second post');
    final second = await actions.publishNow();

    expect(second.text, 'Second post');
    for (final t in second.targets) {
      expect(t.status, TargetStatus.published, reason: t.accountId);
      expect(t.result!.remoteId, isNot('earlier-1'), reason: 'never credited with the other run\'s post');
      expect(t.result!.publishedAt!.isAfter(firstAt), isTrue);
    }
    expect(second.id, isNot(draft.id));
    final other = (await services.posts.get(draft.id))!;
    expect(other.text, 'First post', reason: 'the run in progress keeps its own record');
    expect(other.targetFor(accounts[0])!.result!.remoteId, 'earlier-1');
  });

  _demoTest('a composer put back after a restart forgets a post that went out since', (tester) async {
    final storage = _MemoryStorage();
    final (services, c) = await _workspace(storage: storage);
    addTearDown(c.dispose);
    final actions = c.read(postActionsProvider);
    final composer = c.read(composerProvider.notifier);
    composer
      ..setText('First post')
      ..selectAccounts(_accounts(c));
    final draft = await actions.saveDraft();
    final first = await actions.publishExisting(draft.id);
    expect(first.status, PostStatus.published);

    // composer.json from before: the post was open for editing when NEFORUM was
    // closed (iOS ended it in the background), and went out meanwhile.
    await storage.writeJson(kComposerDraftFile, composerDraftToJson(ComposerState(editingPostId: draft.id, text: 'First post', selected: _accounts(c).toSet())));

    // The next launch puts the composer back the way composerDraftKeeperProvider
    // does, before the post list has loaded.
    final launch = ProviderContainer(overrides: [servicesProvider.overrideWithValue(services)]);
    addTearDown(launch.dispose);
    launch.listen(composerProvider, (_, _) {});
    launch.read(composerProvider.notifier).restore(composerDraftFromJson((await storage.readJson(kComposerDraftFile))!)!);
    launch.listen(postsProvider, (_, _) {});
    launch.listen(accountsProvider, (_, _) {});
    await launch.read(accountsProvider.future);
    await launch.read(postsProvider.future);
    await _settle();
    expect(launch.read(composerProvider).text, 'First post', reason: 'the words come back');
    expect(launch.read(composerProvider).editingPostId, isNull, reason: 'as a new post: that one is already out');

    launch.read(composerProvider.notifier)
      ..clearPost()
      ..setText('Second post');
    final second = await launch.read(postActionsProvider).publishNow();
    expect(second.id, isNot(draft.id));
    _expectOwnResults(second, first);
  });

  _demoTest('the composer stops editing a post once it goes out elsewhere, and keeps the words', (tester) async {
    final (services, c) = await _workspace();
    addTearDown(c.dispose);
    final composer = c.read(composerProvider.notifier);
    final actions = c.read(postActionsProvider);
    composer
      ..setText('Scheduled words')
      ..selectAccounts(_accounts(c));
    final draft = await actions.saveDraft();
    composer.load((await services.posts.get(draft.id))!);
    composer.setText('Scheduled words, edited');

    // Still a draft: still edited.
    await services.posts.upsert((await services.posts.get(draft.id))!.copyWith(updatedAt: DateTime.now()));
    await _settle();
    expect(c.read(composerProvider).editingPostId, draft.id);

    await services.publisher().publish(draft.id);
    await _settle();
    final state = c.read(composerProvider);
    expect(state.editingPostId, isNull);
    expect(state.text, 'Scheduled words, edited', reason: 'nothing the person wrote is lost');

    // Saving it now makes a new draft; the posted record is not touched.
    final saved = await actions.saveDraft();
    expect(saved.id, isNot(draft.id));
    expect(saved.targets.every((t) => t.status == TargetStatus.pending && t.result == null), isTrue);
    expect((await services.posts.get(draft.id))!.status, PostStatus.published);
  });

  _demoTest('scheduling over a post that went out makes a new scheduled post', (tester) async {
    final (services, c) = await _workspace();
    addTearDown(c.dispose);
    final composer = c.read(composerProvider.notifier);
    final actions = c.read(postActionsProvider);
    composer
      ..setText('First post')
      ..selectAccounts(_accounts(c));
    final draft = await actions.saveDraft();
    composer.load((await services.posts.get(draft.id))!);
    await services.publisher().publish(draft.id);
    composer
      ..setText('Later post')
      ..setSchedule(DateTime.now().add(const Duration(days: 1)));
    final scheduled = await actions.schedule();
    expect(scheduled.id, isNot(draft.id));
    expect(scheduled.status, PostStatus.scheduled);
    expect(scheduled.targets.every((t) => t.status == TargetStatus.pending && t.result == null), isTrue, reason: 'every network still gets it');
    expect((await services.posts.get(draft.id))!.text, 'First post');
  });

  _demoTest('a draft still being edited keeps its id when published', (tester) async {
    final (services, c) = await _workspace();
    addTearDown(c.dispose);
    final composer = c.read(composerProvider.notifier);
    final actions = c.read(postActionsProvider);
    composer
      ..setText('Draft words')
      ..selectAccounts(_accounts(c));
    final draft = await actions.saveDraft();
    composer.load((await services.posts.get(draft.id))!);
    composer.setText('Draft words, final');
    _goAway(tester);
    final done = await actions.publishNow();
    _comeBack(tester);
    expect(done.id, draft.id, reason: 'publishing a draft publishes that draft, never a copy beside it');
    expect(done.text, 'Draft words, final');
    expect(done.status, PostStatus.published);
    expect((await services.posts.all()).where((p) => p.text.startsWith('Draft words')), hasLength(1));
  });

  _demoTest('two new posts in a row, the second while NEFORUM is away: each record is its own', (tester) async {
    final (services, c) = await _workspace();
    addTearDown(c.dispose);
    final composer = c.read(composerProvider.notifier);
    final actions = c.read(postActionsProvider);
    composer
      ..setText('First post')
      ..selectAccounts(_accounts(c));
    final first = await actions.publishNow();
    composer.setText('Second post');
    final running = actions.publishNow();
    _goAway(tester);
    final second = await running;
    _comeBack(tester);
    expect(second.id, isNot(first.id));
    expect(second.text, 'Second post');
    _expectOwnResults(second, first);
    expect((await services.posts.get(first.id))!.text, 'First post');
  });
}
