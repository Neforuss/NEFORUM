import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'services.dart';
import 'settings.dart';

/// The services container. Overridden at the root of the app.
final servicesProvider = Provider<AppServices>((ref) => throw StateError('servicesProvider must be overridden'));

final registryProvider = Provider<AdapterRegistry>((ref) => ref.watch(servicesProvider).registry);

final isDemoProvider = Provider<bool>((ref) => ref.watch(servicesProvider).demo);

/// All connected accounts, live.
final accountsProvider = StreamProvider<List<ConnectedAccount>>((ref) async* {
  final repo = ref.watch(servicesProvider).accounts;
  yield await repo.all();
  await for (final _ in repo.changes) {
    yield await repo.all();
  }
});

/// All posts (drafts, scheduled, history), newest first, live.
final postsProvider = StreamProvider<List<Post>>((ref) async* {
  final repo = ref.watch(servicesProvider).posts;
  yield await repo.all();
  await for (final _ in repo.changes) {
    yield await repo.all();
  }
});

/// Accounts as a synchronous list (empty while loading).
final accountListProvider = Provider<List<ConnectedAccount>>((ref) => ref.watch(accountsProvider).value ?? const []);

final accountByIdProvider = Provider.family<ConnectedAccount?, String>((ref, id) {
  for (final a in ref.watch(accountListProvider)) {
    if (a.id == id) return a;
  }
  return null;
});

final postListProvider = Provider<List<Post>>((ref) => ref.watch(postsProvider).value ?? const []);

final postByIdProvider = Provider.family<Post?, String>((ref, id) {
  for (final p in ref.watch(postListProvider)) {
    if (p.id == id) return p;
  }
  return null;
});

/// Posts waiting for the user (hand-offs not yet done, failures to retry).
final needsAttentionProvider = Provider<List<Post>>((ref) => ref
    .watch(postListProvider)
    .where((p) => p.status == PostStatus.partial || p.status == PostStatus.failed)
    .toList());

final scheduledPostsProvider = Provider<List<Post>>((ref) {
  final list = ref.watch(postListProvider).where((p) => p.status == PostStatus.scheduled && p.scheduledAt != null).toList()
    ..sort((a, b) => a.scheduledAt!.compareTo(b.scheduledAt!));
  return list;
});

final draftPostsProvider = Provider<List<Post>>((ref) => ref.watch(postListProvider).where((p) => p.status == PostStatus.draft).toList());

final historyPostsProvider = Provider<List<Post>>((ref) => ref
    .watch(postListProvider)
    .where((p) => p.status != PostStatus.draft && p.status != PostStatus.scheduled)
    .toList());

/// Quota usage for one account; refreshes whenever posts change.
final quotaStatusProvider = FutureProvider.family<List<QuotaStatus>, String>((ref, accountId) async {
  ref.watch(postsProvider);
  final s = ref.watch(servicesProvider);
  final account = ref.watch(accountByIdProvider(accountId));
  if (account == null) return const [];
  final d = s.registry.descriptor(account.platformId);
  if (d == null) return const [];
  return s.quota.status(account, d);
});

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(servicesProvider).settings;

  Future<void> update(AppSettings Function(AppSettings s) change) async {
    final next = change(state);
    state = next;
    await ref.read(servicesProvider).saveSettings(next);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

// ---------------------------------------------------------------------------
// Live publish progress
// ---------------------------------------------------------------------------

/// Progress of one target during a publish run.
class TargetProgress {
  const TargetProgress({required this.status, this.message});
  final TargetStatus status;
  final String? message;
}

/// State of the publish run currently in flight (or the last one).
class PublishRun {
  const PublishRun({required this.postId, required this.progress, this.done = false, this.result});

  final String postId;
  final Map<String, TargetProgress> progress;
  final bool done;
  final Post? result;

  PublishRun copyWith({Map<String, TargetProgress>? progress, bool? done, Post? result}) =>
      PublishRun(postId: postId, progress: progress ?? this.progress, done: done ?? this.done, result: result ?? this.result);
}

class PublishRunNotifier extends Notifier<PublishRun?> {
  @override
  PublishRun? build() => null;

  void start(String postId, Iterable<String> accountIds) {
    state = PublishRun(postId: postId, progress: {for (final id in accountIds) id: const TargetProgress(status: TargetStatus.pending)});
  }

  void progress(String accountId, String message) {
    final s = state;
    if (s == null) return;
    state = s.copyWith(progress: {...s.progress, accountId: TargetProgress(status: TargetStatus.publishing, message: message)});
  }

  void finish(Post post) {
    final s = state;
    if (s == null || s.postId != post.id) return;
    state = s.copyWith(
      done: true,
      result: post,
      progress: {for (final t in post.targets) t.accountId: TargetProgress(status: t.status, message: t.result?.error?.message)},
    );
  }

  void clear() => state = null;
}

final publishRunProvider = NotifierProvider<PublishRunNotifier, PublishRun?>(PublishRunNotifier.new);

/// Bumps whenever something outside the repositories changed (e.g. a media
/// host was reconfigured) so dependent widgets can refresh.
class RefreshTick extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final refreshTickProvider = NotifierProvider<RefreshTick, int>(RefreshTick.new);

/// Keeps a stream subscription alive for the lifetime of a provider.
extension RefDisposeX on Ref {
  void disposeSub(StreamSubscription<Object?> sub) => onDispose(sub.cancel);
}
