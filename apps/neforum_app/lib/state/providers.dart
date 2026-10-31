import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'services.dart';
import 'settings.dart';

/// The services container. Overridden at the root of the app.
final servicesProvider = Provider<AppServices>((ref) => throw StateError('servicesProvider must be overridden'));

final registryProvider = Provider<AdapterRegistry>((ref) => ref.watch(servicesProvider).registry);

final isDemoProvider = Provider<bool>((ref) => ref.watch(servicesProvider).demo);

/// All connected accounts, live.
final accountsProvider = StreamProvider<List<ConnectedAccount>>((ref) {
  final repo = ref.watch(servicesProvider).accounts;
  return liveList(repo.all, repo.changes);
});

/// All posts (drafts, scheduled, history), newest first, live.
final postsProvider = StreamProvider<List<Post>>((ref) {
  final repo = ref.watch(servicesProvider).posts;
  return liveList(repo.all, repo.changes);
});

/// [load] now and after every change. A failed load (the file busy for longer
/// than the store's own retries) is retried until it works instead of ending
/// the stream, which used to leave the app looking empty until restarted.
@visibleForTesting
Stream<List<T>> liveList<T>(Future<List<T>> Function() load, Stream<void> changes, {Duration retry = const Duration(seconds: 2)}) async* {
  Future<List<T>> loadUntilItWorks() async {
    while (true) {
      try {
        return await load();
      } on Object {
        await Future<void>.delayed(retry);
      }
    }
  }

  yield await loadUntilItWorks();
  await for (final _ in changes) {
    yield await loadUntilItWorks();
  }
}

/// Accounts as a synchronous list (empty while loading).
final accountListProvider = Provider<List<ConnectedAccount>>((ref) => ref.watch(accountsProvider).value ?? const []);

/// False until the accounts have been read once: "no accounts yet" screens
/// wait for this so a slow read never looks like an empty workspace.
final accountsLoadedProvider = Provider<bool>((ref) => ref.watch(accountsProvider).hasValue);

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

/// Posts waiting for the user (hand-offs not yet done, failures and
/// cancelled runs to retry).
final needsAttentionProvider = Provider<List<Post>>((ref) => ref
    .watch(postListProvider)
    .where((p) => p.status == PostStatus.partial || p.status == PostStatus.failed || p.status == PostStatus.cancelled)
    .toList());

/// A network that did not get the post and waits for the user to retry:
/// it failed, or the user cancelled the run. Not one with copies already
/// live ([PostTarget.isPartlyLive]: the feed post of a Post + Story whose
/// story failed, the first parts of a thread), which a retry would post
/// twice and whose error says what to post by hand; unless what is live is
/// recorded well enough that the retry posts only the rest
/// ([PostTarget.canResume]: the rest of a thread, of a series).
bool needsRetry(PostTarget t) =>
    (t.status == TargetStatus.failed || t.status == TargetStatus.cancelled) && (!t.isPartlyLive || t.canResume);

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

/// History posts with a network that failed or was cancelled (Activity >
/// Failed).
final failedPostsProvider = Provider<List<Post>>((ref) => ref.watch(historyPostsProvider).where((p) => p.targets.any(needsRetry)).toList());

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
  const PublishRun({
    required this.postId,
    required this.progress,
    required this.cancellation,
    this.done = false,
    this.result,
    this.error,
  });

  /// Null while the composer's post is still being saved.
  final String? postId;
  final Map<String, TargetProgress> progress;

  /// Cancels this run (the progress sheet's Cancel button).
  final CancellationSignal cancellation;
  final bool done;
  final Post? result;

  /// Why the run could not start or stopped early (the post could not be
  /// saved, a platform still holds a copy, ...). The run is done then.
  final String? error;

  bool get preparing => postId == null && !done;
  bool get cancelling => cancellation.isCancelled && !done;

  PublishRun copyWith({String? postId, Map<String, TargetProgress>? progress, bool? done, Post? result, String? error}) => PublishRun(
        postId: postId ?? this.postId,
        progress: progress ?? this.progress,
        cancellation: cancellation,
        done: done ?? this.done,
        result: result ?? this.result,
        error: error ?? this.error,
      );
}

class PublishRunNotifier extends Notifier<PublishRun?> {
  @override
  PublishRun? build() => null;

  /// The composer's post is being saved for publishing; the sheet shows
  /// that it is getting ready.
  void prepare() => state = PublishRun(postId: null, progress: const {}, cancellation: CancellationSignal());

  /// Starts showing the run for [postId] and returns its signal. A Cancel
  /// pressed while the post was being prepared carries over.
  CancellationSignal start(String postId, Iterable<String> accountIds) {
    final s = state;
    final signal = s != null && s.preparing ? s.cancellation : CancellationSignal();
    state = PublishRun(
      postId: postId,
      cancellation: signal,
      progress: {for (final id in accountIds) id: const TargetProgress(status: TargetStatus.pending)},
    );
    return signal;
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

  /// The run for [postId] (or the one being prepared, when null) ended with
  /// [error] instead of a result.
  void fail(String? postId, Object error) {
    final s = state;
    if (s == null || s.done || (s.postId != null && s.postId != postId)) return;
    state = s.copyWith(done: true, error: '$error');
  }

  /// Asks the run in flight to stop; it ends as soon as the request in
  /// flight is aborted.
  void cancel() {
    final s = state;
    if (s == null || s.done) return;
    s.cancellation.cancel();
    state = s.copyWith();
  }

  void clear() => state = null;
}

final publishRunProvider = NotifierProvider<PublishRunNotifier, PublishRun?>(PublishRunNotifier.new);

/// Posts this process is publishing right now (a run from the composer, a
/// list or the scheduler), each with the signal that cancels its run.
/// Activity shows Cancel for them.
class ActivePublishingNotifier extends Notifier<Map<String, CancellationSignal>> {
  @override
  Map<String, CancellationSignal> build() => const {};

  void begin(String postId, CancellationSignal signal) => state = {...state, postId: signal};

  void end(String postId, CancellationSignal signal) {
    if (identical(state[postId], signal)) state = {...state}..remove(postId);
  }

  void cancel(String postId) {
    final signal = state[postId];
    if (signal == null) return;
    signal.cancel();
    // A new map so Cancel buttons turn into "Cancelling…".
    state = {...state};
  }
}

final activePublishingProvider = NotifierProvider<ActivePublishingNotifier, Map<String, CancellationSignal>>(ActivePublishingNotifier.new);

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
