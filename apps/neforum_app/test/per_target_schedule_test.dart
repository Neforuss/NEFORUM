// Scheduling per platform: a different time per network in the composer,
// what the queue says about a partly published post, rescheduling, and
// editing a post whose first networks already have it.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/composer_draft.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/activity/schedule_summary.dart';
import 'package:neforum_app/ui/activity/time_format.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/widgets/badges.dart';
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
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) =>
      SizedBox(width: width, height: height, child: const ColoredBox(color: Color(0xFF777777)));
}

void main() {
  final ten = DateTime(2030, 3, 4, 10);
  final six = DateTime(2030, 3, 4, 18);

  Post post({TargetStatus mastodon = TargetStatus.pending}) => Post(
        id: 'p',
        text: 'Hello',
        createdAt: ten,
        updatedAt: ten,
        scheduledAt: ten,
        status: PostStatus.scheduled,
        targets: [
          PostTarget(accountId: 'masto', overrides: PostOverrides(scheduledAt: ten), status: mastodon),
          PostTarget(accountId: 'gram', overrides: PostOverrides(scheduledAt: six)),
          PostTarget(accountId: 'sky', overrides: PostOverrides(scheduledAt: six.add(const Duration(days: 1)))),
        ],
      );
  String? networkOf(String id) => const {'masto': 'Mastodon', 'gram': 'Instagram', 'sky': 'Bluesky'}[id];
  const format = TimeFormatting(use24Hour: true);

  group('queue and status', () {
    test('a partly published post says how many have it and which network is next, and when', () {
      final partly = post(mastodon: TargetStatus.published).withScheduleFromTargets();
      expect(scheduleSummary(partly, networkOf: networkOf, format: format, now: ten), '1 published · Instagram at 18:00 · 1 more later');
      expect(isPartlyPublished(partly), isTrue);
      expect(postStatusStyleOf(partly).$1, 'Partly published');
    });

    test('a post with a time per network lists the first one; a time on another day gets its day', () {
      expect(scheduleSummary(post(), networkOf: networkOf, format: format, now: ten), 'Mastodon at 10:00 · 2 more later');
      expect(scheduleSummary(post(), networkOf: networkOf, format: format, now: ten.subtract(const Duration(days: 1))),
          'Mastodon at Tomorrow, 10:00 · 2 more later');
      expect(postStatusStyleOf(post()).$1, 'Scheduled');
    });

    test('one time for all and nothing published: the time alone says it, no summary', () {
      final plain = post().copyWith(targets: const [PostTarget(accountId: 'masto'), PostTarget(accountId: 'gram')]);
      expect(scheduleSummary(plain, networkOf: networkOf, format: format, now: ten), isNull);
      expect(scheduleSummary(plain.copyWith(status: PostStatus.published), networkOf: networkOf, format: format), isNull);
    });
  });

  test('rescheduling moves every network still to go by the same amount', () {
    final partly = post(mastodon: TargetStatus.published).withScheduleFromTargets();
    expect(partly.scheduledAt, six);
    final moved = rescheduledPost(partly, six.add(const Duration(hours: 2)), ten);
    expect(moved.scheduledAt, six.add(const Duration(hours: 2)));
    expect(moved.targetFor('masto')!.overrides.scheduledAt, ten, reason: 'already published');
    expect(moved.targetFor('gram')!.overrides.scheduledAt, six.add(const Duration(hours: 2)));
    expect(moved.targetFor('sky')!.overrides.scheduledAt, six.add(const Duration(days: 1, hours: 2)));
    // One time for all: only the post's time changes.
    final plain = post().copyWith(targets: const [PostTarget(accountId: 'masto')]);
    expect(rescheduledPost(plain, six, ten).scheduledAt, six);
  });

  group('composer', () {
    Future<(AppServices, ProviderContainer)> boot(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
      await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
      await tester.pump(const Duration(milliseconds: 300));
      return (services, ProviderScope.containerOf(tester.element(find.byType(MaterialApp))));
    }

    Future<void> done(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('same time for all by default; a time per network goes on each target, the post takes the earliest', (tester) async {
      final (_, c) = await boot(tester);
      final accounts = c.read(accountListProvider).where((a) => a.tier.isAutomatic).take(2).toList();
      final [a, b] = accounts;
      final notifier = c.read(composerProvider.notifier)
        ..selectAccounts([a.id, b.id])
        ..setText('Hello')
        ..setSchedule(six);
      var p = c.read(composerProvider).toPost(id: 'x', status: PostStatus.scheduled, now: ten);
      expect(c.read(composerProvider).schedulesEachTarget, isFalse);
      expect(p.schedulesEachTarget, isFalse);
      expect(p.scheduledAt, six);

      notifier.setTargetSchedules({a.id: six, b.id: ten});
      expect(c.read(composerProvider).schedulesEachTarget, isTrue);
      p = c.read(composerProvider).toPost(id: 'x', status: PostStatus.scheduled, now: ten);
      expect(p.dueAtFor(p.targetFor(a.id)!), six);
      expect(p.dueAtFor(p.targetFor(b.id)!), ten);
      expect(p.scheduledAt, ten);

      // The times survive the composer file and "Clear post".
      final restored = composerDraftFromJson(composerDraftToJson(c.read(composerProvider)))!;
      expect(restored.overrides[a.id]!.scheduledAt, six);
      notifier.clearPost();
      expect(c.read(composerProvider).overrides[b.id]!.scheduledAt, ten);

      // Back to the same time for all, then no schedule at all.
      notifier.setTargetSchedules(null);
      expect(c.read(composerProvider).schedulesEachTarget, isFalse);
      notifier
        ..setTargetSchedules({a.id: six, b.id: ten})
        ..setSchedule(null);
      expect(c.read(composerProvider).scheduledAt, isNull);
      expect(c.read(composerProvider).schedulesEachTarget, isFalse);
      await done(tester);
    });

    testWidgets('editing a partly published post keeps the networks that have it', (tester) async {
      final (services, c) = await boot(tester);
      final [a, b] = c.read(accountListProvider).where((x) => x.tier.isAutomatic && x.platformId != 'mastodon').take(2).toList();
      final saved = Post(
        id: 'partly',
        text: 'Hello',
        createdAt: ten,
        updatedAt: ten,
        scheduledAt: DateTime.now().add(const Duration(hours: 3)),
        status: PostStatus.scheduled,
        targets: [
          PostTarget(
              accountId: a.id,
              overrides: PostOverrides(scheduledAt: DateTime.now().subtract(const Duration(hours: 1))),
              status: TargetStatus.published,
              result: PublishResult.ok(remoteId: 'live-1')),
          PostTarget(accountId: b.id, overrides: PostOverrides(scheduledAt: DateTime.now().add(const Duration(hours: 3)))),
        ],
      );
      await tester.runAsync(() => services.posts.upsert(saved));
      c.read(composerProvider.notifier)
        ..load(saved)
        ..setText('Hello, edited');
      final p = (await tester.runAsync(() => c.read(postActionsProvider).schedule()))!;
      expect(p.targetFor(a.id)!.status, TargetStatus.published);
      expect(p.targetFor(a.id)!.result!.remoteId, 'live-1');
      expect(p.targetFor(b.id)!.status, TargetStatus.pending);
      expect(p.text, 'Hello, edited');
      expect(p.scheduledAt, saved.targets[1].overrides.scheduledAt, reason: 'the next network still to go');
      await tester.runAsync(() => c.read(postActionsProvider).settle());
      await done(tester);
    });

    testWidgets('a duplicate starts without the times', (tester) async {
      final (_, c) = await boot(tester);
      final a = c.read(accountListProvider).firstWhere((x) => x.tier.isAutomatic);
      final source = post().copyWith(targets: [PostTarget(accountId: a.id, overrides: PostOverrides(scheduledAt: six, title: 'T'))]);
      c.read(composerProvider.notifier).duplicate(source);
      final state = c.read(composerProvider);
      expect(state.scheduledAt, isNull);
      expect(state.schedulesEachTarget, isFalse);
      expect(state.overrides[a.id]!.title, 'T');
      await done(tester);
    });
  });
}
