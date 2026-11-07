// D10: how a post's result reaches the user. A summary plus one notification
// per network, nothing while the sheet shows it, nothing left behind when the
// post is deleted, and no post text on a lock screen.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/notifications.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/notification_state.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/publish_result_notices.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _MemoryStorage implements AppStorage {
  final Map<String, Object> json = {};

  /// Posts, accounts and the journal are files: a folder of this test's own.
  final String _dir = Directory.systemTemp.createTempSync('neforum-u2n-').path;
  @override
  String? get dataDir => _dir;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async => 'mem://$id.$extension';
  @override
  Future<Uint8List> readMedia(String path) async => Uint8List(0);
  @override
  Future<void> deleteMedia(String path) async {}
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => SizedBox(width: width, height: height);
}

const _secretText = 'The words of the post itself';

final _now = DateTime(2026, 11, 7, 12);

PostTarget _t(String id, TargetStatus status, {PublishResult? result, String? note}) =>
    PostTarget(accountId: id, status: status, result: result, handoffNote: note);

Post _post(List<PostTarget> targets, {String text = _secretText, List<String> extraParts = const []}) => Post(
      id: 'p1',
      text: text,
      additionalParts: extraParts,
      createdAt: _now,
      updatedAt: _now,
      status: PostStatus.partial,
      targets: targets,
    );

const _names = <String, ResultNetworkName>{
  'a': (name: 'Bluesky', accountLabel: null),
  'b': (name: 'YouTube', accountLabel: null),
  'c': (name: 'TikTok', accountLabel: null),
  'd': (name: 'Threads', accountLabel: null),
  'e': (name: 'Mastodon', accountLabel: '@me@one.example'),
  'f': (name: 'Mastodon', accountLabel: '@me@two.example'),
};

List<ResultNotice> _notices(Post p, {bool discarded = false, bool notify = true, Set<String>? only, bool quote = true}) => publishResultNotices(
      p,
      discarded: discarded,
      notifyOnPublish: notify,
      networks: _names,
      heldTime: (_) => '18:00',
      onlyAccountIds: only,
      quotePostText: quote,
    );

PublishResult _ok([String? url]) => PublishResult.ok(remoteId: 'r', remoteUrl: url);

PublishResult _failed(String message) => PublishResult.failure(PublishError.platform(message));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('one row per target state', () {
    ResultNotice child(List<ResultNotice> all, String key) => all.firstWhere((n) => n.key == key);

    test('the table from android.md 6.7', () {
      final held = PublishResult.scheduled(remoteId: 'h', scheduledFor: _now.add(const Duration(hours: 6)));
      final all = _notices(_post([
        _t('a', TargetStatus.published, result: _ok('https://bsky.app/profile/me/post/1')),
        _t('b', TargetStatus.failed, result: _failed('Quota is used up\nand more detail')),
        _t('c', TargetStatus.awaitingHandoff, note: 'Check the page'),
        _t('d', TargetStatus.heldByPlatform, result: held),
        _t('e', TargetStatus.skipped),
      ]));

      final published = child(all, 'result:p1:a');
      expect(published.title, 'Posted to Bluesky');
      expect(published.action, ResultNoticeAction.openLink);
      expect(NotificationIntent.parse(published.payload), isA<OpenPostIntent>());
      final link = NotificationIntent.parse(published.payload, actionId: kOpenLinkAction) as OpenLinkIntent;
      expect(link.link.toString(), 'https://bsky.app/profile/me/post/1');

      final failed = child(all, 'result:p1:b');
      expect(failed.title, 'YouTube failed');
      expect(failed.body, 'Quota is used up', reason: 'first line only');
      expect(failed.action, ResultNoticeAction.retry);
      expect(failed.payload, 'retry:p1:b');

      final handoff = child(all, 'handoff:p1:c');
      expect(handoff.title, 'Time to post to TikTok');
      expect(handoff.body, 'Check the page');
      expect(handoff.payload, 'handoff:p1:c');

      expect(child(all, 'result:p1:d').title, 'YouTube has it for 18:00'.replaceFirst('YouTube', 'Threads'));

      expect(all.where((n) => n.key.endsWith(':e')), isEmpty, reason: 'skipped: counted in the summary only');
      final summary = all.last;
      expect(summary.key, 'result:p1');
      expect(summary.isSummary, isTrue);
      expect(summary.title, 'Posted to 1 of 5');
      expect(summary.payload, 'post:p1');
      expect(summary.lines, ['Posted to Bluesky', 'YouTube failed', 'Time to post to TikTok', 'Threads has it for 18:00']);
    });

    test('a hand-off with no note says where to finish', () {
      expect(_notices(_post([_t('c', TargetStatus.awaitingHandoff)])).single.body, 'Tap to finish in the app.');
    });

    test('partly live: counts the parts, says what Retry does, offers none itself', () {
      final resumable = PublishResult.partialFailure(const PublishError.platform('Part 4 failed'), remoteId: 'r1', threadRemoteIds: const ['r2', 'r3'], resumable: true);
      final stuck = PublishResult.partialFailure(const PublishError.platform('Part 4 failed'), remoteId: 'r1', threadRemoteIds: const ['r2', 'r3']);
      final parts = ['two', 'three', 'four', 'five'];
      final can = _notices(_post([_t('d', TargetStatus.failed, result: resumable)], extraParts: parts)).single;
      expect(can.title, 'Threads: 3 of 5 parts posted');
      expect(can.body, 'Retry posts the rest.');
      expect(can.action, ResultNoticeAction.none);
      final cannot = _notices(_post([_t('d', TargetStatus.failed, result: stuck)], extraParts: parts)).single;
      expect(cannot.body, 'Check it before posting again.');
    });

    test('a lost answer: no Retry on the notification, since the post may be live', () {
      final unknown = PublishResult.failure(const PublishError(kind: PublishErrorKind.network, message: 'NEFORUM could not confirm this. Check YouTube before retrying.', outcomeUnknown: true));
      final n = _notices(_post([_t('b', TargetStatus.failed, result: unknown)])).single;
      expect(n.action, ResultNoticeAction.none);
      expect(n.title, 'YouTube: check before retrying');
      expect(n.payload, 'post:p1');
      expect(NotificationIntent.parse(n.payload, actionId: kRetryAction), isA<OpenPostIntent>());
    });

    test('cancelled: nothing, unless a hand-off still waits', () {
      expect(_notices(_post([_t('a', TargetStatus.published, result: _ok()), _t('b', TargetStatus.cancelled)])), isEmpty);
      final waits = _notices(_post([_t('b', TargetStatus.cancelled), _t('c', TargetStatus.awaitingHandoff)]));
      expect(waits.map((n) => n.key), ['handoff:p1:c']);
    });

    test('every account switched off', () {
      final n = _notices(_post([_t('a', TargetStatus.skipped), _t('b', TargetStatus.skipped)])).single;
      expect(n.title, 'Not posted');
      expect(n.body, contains('switched off'));
    });

    test('networks still waiting for their own time are not part of the result', () {
      final all = _notices(_post([_t('a', TargetStatus.published, result: _ok()), _t('b', TargetStatus.published, result: _ok()), _t('c', TargetStatus.pending)]));
      expect(all.last.title, 'Posted to 2 networks');
      expect(all.where((n) => n.key.endsWith(':c')), isEmpty);
    });

    test('two accounts on one network say which', () {
      final all = _notices(_post([_t('e', TargetStatus.published, result: _ok()), _t('f', TargetStatus.published, result: _ok())]));
      expect(child(all, 'result:p1:e').body, '@me@one.example');
      expect(child(all, 'result:p1:f').body, '@me@two.example');
      expect(all.last.title, 'Posted to 2 networks');
    });

    test('a run that ended with nothing out', () {
      final all = _notices(_post([_t('a', TargetStatus.failed, result: _failed('x')), _t('b', TargetStatus.failed, result: _failed('y'))]));
      expect(all.last.title, 'Not posted');
    });

    test('interrupted, at the next start', () {
      final n = publishInterruptedNotice(_post([_t('a', TargetStatus.failed, result: _failed('NEFORUM closed before this was posted. Retry it.'))]), fallbackMessage: 'fallback');
      expect((n.key, n.title, n.body, n.payload), ('result:p1', 'Posting stopped', 'NEFORUM closed before this was posted. Retry it.', 'post:p1'));
      expect(publishInterruptedNotice(_post([_t('a', TargetStatus.skipped)]), fallbackMessage: 'fallback').body, 'fallback');
    });
  });

  group('the group', () {
    final two = _post([_t('a', TargetStatus.published, result: _ok()), _t('b', TargetStatus.failed, result: _failed('No'))]);

    test('children first and silent, the summary last and the one that sounds', () {
      final all = _notices(two);
      expect(all.map((n) => n.key), ['result:p1:a', 'result:p1:b', 'result:p1']);
      expect(all.map((n) => n.groupKey).toSet(), {'neforum.result.p1'});
      expect(all.map((n) => n.threadId).toSet(), {'p1'});
      expect(all.map((n) => n.alerts), [false, false, true]);
      expect(all.map((n) => n.isSummary), [false, false, true]);
    });

    test('a post on one network is one notification, no group', () {
      final n = _notices(_post([_t('a', TargetStatus.published, result: _ok())])).single;
      expect(n.groupKey, isNull);
      expect(n.isSummary, isFalse);
      expect(n.alerts, isTrue);
      expect(n.title, 'Posted to Bluesky');
      expect(n.body, _secretText, reason: 'alone, it has to say which post');
    });

    test('Android details: group, one sound, a summary with its lines, concealed on the lock screen', () {
      final all = _notices(two);
      final child = NotificationService.resultDetails(all.first).android!;
      expect(child.groupKey, 'neforum.result.p1');
      expect(child.setAsGroupSummary, isFalse);
      expect(child.groupAlertBehavior, GroupAlertBehavior.summary);
      expect(child.visibility, NotificationVisibility.private);
      final summary = NotificationService.resultDetails(all.last).android!;
      expect(summary.setAsGroupSummary, isTrue);
      expect(summary.visibility, NotificationVisibility.private);
      expect((summary.styleInformation! as InboxStyleInformation).lines, ['Posted to Bluesky', 'YouTube failed']);
      expect(NotificationService.resultDetails(all[1]).android!.actions!.single.id, kRetryAction);
    });

    test('iOS and macOS details: one thread, sound on the summary only, each button in a category', () {
      final all = _notices(_post([_t('a', TargetStatus.published, result: _ok('https://x.example/1')), _t('b', TargetStatus.failed, result: _failed('No'))]));
      for (final darwin in [NotificationService.resultDetails(all[0]).iOS!, NotificationService.resultDetails(all[0]).macOS!]) {
        expect(darwin.threadIdentifier, 'p1');
        expect(darwin.presentSound, isFalse);
        expect(darwin.categoryIdentifier, 'neforum.result.posted');
      }
      expect(NotificationService.resultDetails(all[1]).iOS!.categoryIdentifier, 'neforum.result.failed');
      expect(NotificationService.resultDetails(all[2]).iOS!.presentSound, isNull);
    });

    test('Windows and Linux: the summary alone, each network a line of it', () {
      final one = collapseResultNotices(_notices(two)).single;
      expect(one.title, 'Posted to 1 of 2');
      expect(one.body, 'Posted to Bluesky\nYouTube failed');
      expect(one.groupKey, isNull);
      final single = _notices(_post([_t('a', TargetStatus.published, result: _ok())]));
      expect(collapseResultNotices(single), single);
    });
  });

  group('the post text', () {
    final mixed = _post([
      _t('a', TargetStatus.published, result: _ok('https://x.example/1')),
      _t('b', TargetStatus.failed, result: _failed('No')),
      _t('c', TargetStatus.awaitingHandoff),
    ]);

    test('only ever in the summary, the one notification Android conceals', () {
      final all = _notices(mixed);
      expect(all.last.body, _secretText);
      for (final n in all.take(all.length - 1)) {
        expect('${n.title} ${n.body} ${n.payload}', isNot(contains(_secretText)), reason: n.key);
      }
    });

    test('where the OS has no such flag it stays out altogether', () {
      for (final n in _notices(mixed, quote: false)) {
        expect('${n.title} ${n.body} ${n.lines}', isNot(contains(_secretText)), reason: n.key);
      }
      expect(_notices(mixed, quote: false).last.body, 'Posted to Bluesky · YouTube failed · Time to post to TikTok');
      final alone = _notices(_post([_t('a', TargetStatus.published, result: _ok())]), quote: false).single;
      expect(alone.body, isEmpty);
    });

    test('a deleted post is neither quoted nor opened, but its link still works', () {
      final all = _notices(_post([_t('a', TargetStatus.published, result: _ok('https://x.example/1')), _t('b', TargetStatus.published, result: _ok())]), discarded: true);
      expect(all.last.payload, isNull);
      expect(all[1].payload, isNull);
      expect(all.last.body, isNot(contains(_secretText)));
      expect(NotificationIntent.parse(all[0].payload), isNull, reason: 'a tap has nothing to open');
      expect(NotificationIntent.parse(all[0].payload, actionId: kOpenLinkAction), isA<OpenLinkIntent>());
    });

    test('long text is cut at 90 characters without splitting an emoji', () {
      final body = _notices(_post([_t('a', TargetStatus.published, result: _ok())], text: '😀' * 120)).single.body;
      expect(body.runes.length, 91);
      expect(body, endsWith('😀…'));
    });
  });

  group('Tell me how each post went', () {
    test('off: only hand-offs, which wait for the user', () {
      final p = _post([_t('a', TargetStatus.published, result: _ok()), _t('c', TargetStatus.awaitingHandoff), _t('d', TargetStatus.awaitingHandoff)]);
      final all = _notices(p, notify: false);
      expect(all.map((n) => n.key), ['handoff:p1:c', 'handoff:p1:d', 'result:p1']);
      expect(all.last.title, 'Time to post to TikTok and Threads');
      expect(_notices(_post([_t('a', TargetStatus.published, result: _ok())]), notify: false), isEmpty);
    });
  });

  group('only what this run changed', () {
    test('a retry of one network says nothing about the others', () {
      final p = _post([_t('a', TargetStatus.published, result: _ok()), _t('b', TargetStatus.published, result: _ok())]);
      expect(_notices(p, only: {'b'}).map((n) => n.title), ['Posted to YouTube']);
      expect(_notices(p, only: {}), isEmpty);
    });

    test('targetsChangedByRun', () {
      final before = _post([_t('a', TargetStatus.published), _t('b', TargetStatus.pending), _t('c', TargetStatus.failed)]);
      final after = _post([_t('a', TargetStatus.published), _t('b', TargetStatus.published), _t('c', TargetStatus.failed)]);
      expect(targetsChangedByRun(before, after), {'b'});
    });
  });

  group('who is watching', () {
    test('the delivery table', () {
      const hidden = [AppLifecycleState.hidden, AppLifecycleState.paused, AppLifecycleState.detached];
      const visible = [AppLifecycleState.resumed, AppLifecycleState.inactive, null];
      for (final l in visible) {
        expect(tappedRunDelivery(sheetOpen: true, lifecycle: l), RunEndDelivery.none, reason: 'the sheet is the result ($l)');
        expect(tappedRunDelivery(sheetOpen: false, lifecycle: l), RunEndDelivery.notify, reason: '$l');
        expect(unattendedRunDelivery(lifecycle: l), RunEndDelivery.notify, reason: '$l');
      }
      for (final l in hidden) {
        expect(tappedRunDelivery(sheetOpen: true, lifecycle: l), RunEndDelivery.notify, reason: 'the sheet is still there on return ($l)');
        expect(tappedRunDelivery(sheetOpen: false, lifecycle: l), RunEndDelivery.notifyAndRemember, reason: '$l');
        expect(unattendedRunDelivery(lifecycle: l), RunEndDelivery.notifyAndRemember, reason: '$l');
      }
    });
  });

  group('intents', () {
    test('Retry keeps an account id with colons; a plain tap only opens', () {
      const payload = 'retry:p1:bluesky:did:plc:abc';
      final retry = NotificationIntent.parse(payload, actionId: kRetryAction) as RetryTargetIntent;
      expect((retry.postId, retry.accountId), ('p1', 'bluesky:did:plc:abc'));
      expect((NotificationIntent.parse(payload) as OpenPostIntent).postId, 'p1');
    });

    test('Open goes to web addresses only', () {
      expect(NotificationIntent.parse(postedPayload(postId: 'p', link: 'javascript:alert(1)'), actionId: kOpenLinkAction), isNull);
      expect(NotificationIntent.parse(postedPayload(postId: 'p', link: 'file:///etc/passwd'), actionId: kOpenLinkAction), isNull);
      expect(NotificationIntent.parse('posted:p:!!!', actionId: kOpenLinkAction), isNull);
      final web = NotificationIntent.parse(postedPayload(postId: 'p', link: 'https://a.example/x?y=1'), actionId: kOpenLinkAction) as OpenLinkIntent;
      expect(web.link.host, 'a.example');
    });

    test('a link that is not a web address gets no button', () {
      final n = _notices(_post([_t('a', TargetStatus.published, result: _ok('at://did:plc:x/post/1'))])).single;
      expect(n.action, ResultNoticeAction.none);
      expect(n.payload, 'post:p1');
    });

    test('Retry from an old notification never posts again where the post is, or may be', () {
      Post one(TargetStatus s, [PublishResult? r]) => _post([_t('a', s, result: r)]);
      expect(notificationRetryAllowed(one(TargetStatus.failed, _failed('x')), 'a'), isTrue);
      expect(notificationRetryAllowed(one(TargetStatus.published, _ok()), 'a'), isFalse, reason: 'retried since, and it worked');
      expect(notificationRetryAllowed(one(TargetStatus.publishing), 'a'), isFalse);
      expect(notificationRetryAllowed(one(TargetStatus.failed, PublishResult.failure(const PublishError(kind: PublishErrorKind.network, message: 'm', outcomeUnknown: true))), 'a'), isFalse);
      expect(notificationRetryAllowed(one(TargetStatus.failed, PublishResult.partialFailure(const PublishError.platform('x'), remoteId: 'r')), 'a'), isFalse);
      expect(notificationRetryAllowed(one(TargetStatus.failed, _failed('x')), 'gone'), isFalse);
      expect(notificationRetryAllowed(null, 'a'), isFalse);
    });
  });

  group('delivery', () {
    late List<ResultNotice> shown;
    late List<String> cancelled;

    setUp(() {
      shown = NotificationService.instance.debugShownResults = [];
      cancelled = NotificationService.instance.debugCancelledKeys = [];
    });
    tearDown(() {
      NotificationService.instance.debugShownResults = null;
      NotificationService.instance.debugCancelledKeys = null;
    });

    /// Demo publishing runs on real timers.
    void demoRun(String description, Future<void> Function(WidgetTester tester, AppServices s, ProviderContainer c, List<String> accounts) body) {
      testWidgets(description, (tester) async {
        await tester.runAsync(() async {
          final s = await AppServices.create(demo: true, storage: _MemoryStorage());
          final c = ProviderContainer(overrides: [servicesProvider.overrideWithValue(s)]);
          addTearDown(c.dispose);
          c.listen(postsProvider, (_, _) {});
          c.listen(accountsProvider, (_, _) {});
          await c.read(accountsProvider.future);
          final accounts = c.read(accountListProvider).where((a) => a.platformId == 'mastodon' || a.platformId == 'bluesky').map((a) => a.id).toList();
          c.read(composerProvider.notifier)
            ..setText(_secretText)
            ..selectAccounts(accounts);
          await body(tester, s, c, accounts);
        });
      }, timeout: const Timeout(Duration(minutes: 1)));
    }

    tearDownAll(() => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed));

    demoRun('a tapped run with the sheet open and visible sends nothing', (tester, s, c, _) async {
      c.read(publishSheetOpenProvider.notifier).opened();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await c.read(postActionsProvider).publishNow();
      expect(shown, isEmpty);
      expect(await s.storage.readJson(UnseenResults.fileName), isNull);
    });

    demoRun('with the sheet closed it sends the group, after the post is deleted, so nothing removes it', (tester, s, c, accounts) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await c.read(postActionsProvider).publishNow();
      expect(shown.length, accounts.length + 1);
      expect(shown.last.isSummary, isTrue);
      expect(shown.last.body, isNot(contains(_secretText)), reason: 'kept nothing: nothing to quote');
      final removedAt = cancelled.lastIndexOf('result:${shown.last.key.split(':')[1]}');
      expect(removedAt, greaterThanOrEqualTo(0), reason: 'deleting the post removed what the last run said');
      expect(await s.storage.readJson(UnseenResults.fileName), isNull, reason: 'the app was on screen');
    });

    demoRun('hidden with the sheet open: sent, and the sheet still shows it on return', (tester, s, c, accounts) async {
      c.read(publishSheetOpenProvider.notifier).opened();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await c.read(postActionsProvider).publishNow();
      expect(shown, isNotEmpty);
      expect(await s.storage.readJson(UnseenResults.fileName), isNull);
    });

    demoRun('hidden with no sheet: sent, and remembered with no post text', (tester, s, c, accounts) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await c.read(postActionsProvider).publishNow();
      expect(shown, isNotEmpty);
      final unseen = await UnseenResults(s.storage).read();
      expect(unseen.entries.single.title, 'Posted to ${accounts.length} networks');
      expect(unseen.entries.single.lines.length, accounts.length);
      expect(unseen.lastAt, isNotNull);
      expect('${s.storage.readJson(UnseenResults.fileName)}${await s.storage.readJson(UnseenResults.fileName)}', isNot(contains(_secretText)));
    });

    demoRun('a retry first takes back what the last run said about those networks', (tester, s, c, accounts) async {
      await s.saveSettings(s.settings.copyWith(publishedPostRetention: PublishedPostRetention.retainIndefinitely));
      final draft = await c.read(postActionsProvider).saveDraft();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await c.read(postActionsProvider).publishExisting(draft.id, accountIds: {accounts.first});
      expect(cancelled, containsAll(['result:${draft.id}', 'result:${draft.id}:${accounts.first}']));
      expect(shown.map((n) => n.key), ['result:${draft.id}:${accounts.first}'], reason: 'this run touched one network');
    });

    demoRun('notifyOnPublish off silences the results of a tapped run', (tester, s, c, _) async {
      await c.read(settingsProvider.notifier).update((x) => x.copyWith(notifyOnPublish: false));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await c.read(postActionsProvider).publishNow();
      expect(shown, isEmpty);
    });

    demoRun('deleting a post removes every network\'s notification', (tester, s, c, accounts) async {
      await s.saveSettings(s.settings.copyWith(publishedPostRetention: PublishedPostRetention.retainIndefinitely));
      final draft = await c.read(postActionsProvider).saveDraft();
      cancelled.clear();
      await s.posts.delete(draft.id);
      expect(cancelled, containsAll([
        'due:${draft.id}',
        'result:${draft.id}',
        'handoff:${draft.id}',
        for (final a in accounts) ...['result:${draft.id}:$a', 'handoff:${draft.id}:$a'],
      ]));
    });

    test('anything else on screen about the post is found by its payload', () {
      for (final payload in ['post:p1', 'handoff:p1:a', 'publish:p1', 'retry:p1:a:b', postedPayload(postId: 'p1', link: 'https://x.example')]) {
        expect(NotificationService.payloadNamesPost(payload, 'p1'), isTrue, reason: payload);
      }
      for (final payload in ['post:p2', 'handoff:p2:p1', null, '', 'p1', postedPayload(postId: null, link: 'https://x.example')]) {
        expect(NotificationService.payloadNamesPost(payload, 'p1'), isFalse, reason: '$payload');
      }
    });

    testWidgets('a settled run says Posting stopped, with what stopped it, and is remembered', (tester) async {
      await tester.runAsync(() async {
        final storage = _MemoryStorage();
        final s = await AppServices.create(demo: false, storage: storage);
        addTearDown(s.dispose);
        final post = _post([_t('a', TargetStatus.publishing)]).copyWith(status: PostStatus.publishing);
        await s.publishJournal.record(post.id);
        await s.posts.upsert(post);
        await s.recoverInterruptedPublishing(now: DateTime.now().add(const Duration(hours: 1)), atStartup: true);
        expect(shown.single.title, 'Posting stopped');
        expect(shown.single.key, 'result:p1');
        expect(shown.single.body, AppServices.interruptedMessage);
        expect((await UnseenResults(storage).read()).entries.single.title, 'Posting stopped');
      });
    });
  });

  group('UnseenResults', () {
    test('the list has a limit, a later run replaces an earlier one, and clearing keeps the time', () async {
      final store = UnseenResults(_MemoryStorage());
      for (var i = 0; i < UnseenResults.maxEntries + 5; i++) {
        await store.add(UnseenResult(postId: 'p$i', at: _now.add(Duration(minutes: i)), title: 't$i', lines: const []));
      }
      var read = await store.read();
      expect(read.entries.length, UnseenResults.maxEntries);
      expect(read.entries.first.postId, 'p5');

      await store.add(UnseenResult(postId: 'p5', at: _now.add(const Duration(days: 1)), title: 'newer', lines: const ['x']));
      read = await store.read();
      expect(read.entries.last.title, 'newer');
      expect(read.entries.where((e) => e.postId == 'p5').length, 1);

      await store.clearEntries();
      read = await store.read();
      expect(read.entries, isEmpty);
      expect(read.lastAt, _now.add(const Duration(days: 1)).toUtc());

      await store.deleteAll();
      expect((await store.read()).lastAt, isNull);
    });

    test('a damaged file reads as nothing', () async {
      final storage = _MemoryStorage()..json[UnseenResults.fileName] = <String, dynamic>{'entries': 'nope'};
      expect((await UnseenResults(storage).read()).entries, isEmpty);
    });
  });
}
