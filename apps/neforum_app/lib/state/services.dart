import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../platform/app_auth_broker.dart';
import '../platform/browser_bridge.dart';
import '../platform/env.dart';
import '../platform/media_library.dart';
import '../platform/notifications.dart';
import '../platform/secure_secret_store.dart';
import '../platform/storage.dart';
import '../platform/storage_maintenance.dart';
import '../platform/ui_bridge.dart';
import 'cloud_sync.dart';
import 'composer_draft.dart' show kComposerDraftFile;
import 'demo.dart';
import 'media_host_config.dart';
import 'settings.dart';

/// Every long-lived object the app needs, created once at startup (and again
/// when the user toggles demo mode).
class AppServices {
  AppServices._({
    required this.storage,
    required this.accounts,
    required this.posts,
    required this.quotaRepo,
    required this.secrets,
    required this.registry,
    required this.http,
    required this.media,
    required this.broker,
    required this.handoff,
    required this.browserBridge,
    required this.publishJournal,
    required this.demo,
    required this._settings,
  }) : quota = QuotaTracker(quotaRepo);

  final AppStorage storage;
  final AccountRepository accounts;
  final PostRepository posts;

  /// The publish runs of this process and of the background isolates that
  /// share its data folder (see [recoverInterruptedPublishing]).
  final PublishJournal publishJournal;
  final QuotaRepository quotaRepo;
  final SecretStore secrets;
  final AdapterRegistry registry;
  final NeforumHttp http;
  final MediaLibrary media;
  final AppAuthBroker broker;
  final AppHandoffLauncher handoff;
  final QuotaTracker quota;

  /// The local server the NEFORUM browser extension fills hand-offs from.
  /// Runs on desktop while Settings > Browser extension is on, once
  /// [startBrowserBridge] was called.
  final BrowserBridge browserBridge;
  bool _bridgeWanted = false;
  bool _disposed = false;

  /// Demo workspace: simulated adapters, in-memory data.
  final bool demo;

  /// The shared sync file (Settings > Sync); stays off in the demo.
  late final CloudSync cloudSync;

  AppSettings _settings;
  AppSettings get settings => _settings;

  MediaHost? _mediaHost;

  /// Targets the user skipped in a hand-off sheet during the current run.
  final Set<String> _skipped = {};

  /// [browserBridge] replaces the real one in tests.
  static Future<AppServices> create({required bool demo, AppStorage? storage, BrowserBridge? browserBridge}) async {
    final st = storage ?? await openAppStorage();
    final settings = AppSettings.fromJson(await st.readJson('settings.json') ?? const {});
    final real = builtinRegistry();

    late final AccountRepository accounts;
    late final PostRepository posts;
    late final QuotaRepository quota;
    late final SecretStore secrets;
    late final PublishJournal journal;
    final AdapterRegistry registry;

    if (demo) {
      accounts = InMemoryAccountRepository();
      posts = _NotificationCancellingPostRepository(InMemoryPostRepository());
      quota = InMemoryQuotaRepository();
      secrets = InMemorySecretStore();
      journal = PublishJournal.inMemory();
      registry = demoRegistry(real);
      await seedDemo(registry: registry, accounts: accounts, posts: posts, quota: quota, media: MediaLibrary(st));
    } else {
      final store = JsonFileStore(st.dataDir ?? '');
      accounts = store.accounts;
      posts = _NotificationCancellingPostRepository(store.posts);
      quota = store.quota;
      secrets = SecureSecretStore();
      journal = store.publishJournal;
      registry = real;
    }

    late final AppServices services;
    final handoff = AppHandoffLauncher(onSkip: (postId, accountId) => services._skipped.add('$postId|$accountId'));
    services = AppServices._(
      storage: st,
      accounts: accounts,
      posts: posts,
      quotaRepo: quota,
      secrets: secrets,
      registry: registry,
      http: NeforumHttp(),
      media: MediaLibrary(st),
      broker: AppAuthBroker(
        openUrl: (u) async {
          await launchUrl(u, mode: LaunchMode.externalApplication);
        },
        askPaste: (url, redirect) => UiBridge.instance.askPaste(url, redirect),
      ),
      handoff: handoff,
      // Paired browsers belong to this computer, not to a workspace: the demo
      // keeps them in the real keychain too, so trying the demo does not
      // unpair the extension.
      browserBridge: browserBridge ?? BrowserBridge.create(secrets: demo && Env.isDesktop ? SecureSecretStore() : secrets),
      publishJournal: journal,
      demo: demo,
      settings: settings,
    );
    services.cloudSync = CloudSync(
      storage: st,
      accounts: accounts,
      posts: posts,
      secrets: secrets,
      http: services.http,
      settings: () => services._settings,
      saveSettings: services.saveSettings,
    );
    await services._rebuildMediaHost();
    return services;
  }

  Future<void> saveSettings(AppSettings s) async {
    final hostChanged = s.mediaHostId != _settings.mediaHostId ||
        !mapEquals(s.mediaHostConfig, _settings.mediaHostConfig) ||
        s.fallbackMediaHostId != _settings.fallbackMediaHostId ||
        !mapEquals(s.fallbackMediaHostConfig, _settings.fallbackMediaHostConfig);
    final bridgeChanged = s.browserExtension != _settings.browserExtension;
    _settings = s;
    await storage.writeJson('settings.json', s.toJson());
    if (hostChanged) await _rebuildMediaHost();
    if (bridgeChanged) await _syncBrowserBridge();
    if (!demo) await cloudSync.settingsChanged();
  }

  /// Starts cloud sync when it is set up ([background]: one sync, no timers).
  Future<void> startCloudSync({bool background = false}) async {
    if (!demo) await cloudSync.start(background: background);
  }

  /// Starts the browser-extension bridge when this is a computer and the
  /// setting is on. Call when the UI starts (background runs leave it off).
  Future<void> startBrowserBridge() async {
    _bridgeWanted = true;
    await _syncBrowserBridge();
  }

  Future<void> _syncBrowserBridge() async {
    if (_bridgeWanted && !_disposed && Env.isDesktop && _settings.browserExtension) {
      await browserBridge.start();
    } else {
      await browserBridge.stop();
    }
  }

  Future<void> _rebuildMediaHost() async {
    _mediaHost = await buildMediaHost(_settings, secrets, http,
        onFallback: (m) => lastMediaHostFallback.value = (at: DateTime.now(), message: m));
  }

  /// The last time the fallback media host stepped in during this session,
  /// and why (shown under Settings > Media hosting).
  final ValueNotifier<({DateTime at, String message})?> lastMediaHostFallback = ValueNotifier(null);

  MediaHost? get mediaHost => _mediaHost;

  /// Call after the user edits media-host secrets.
  Future<void> refreshMediaHost() => _rebuildMediaHost();

  /// Hand-offs go to the NEFORUM browser extension: a computer with a paired
  /// browser, outside the demo workspace. The demo's sample posts never
  /// reach the extension, so nothing is filled in or posted on the user's
  /// real accounts.
  bool get extensionFillsHandoffs => !demo && Env.isDesktop && browserBridge.canFill;

  /// A publisher configured with the current settings.
  PublishService publisher() => PublishService(
        registry: registry,
        accounts: accounts,
        posts: posts,
        secrets: secrets,
        quota: quota,
        http: http,
        broker: broker,
        handoffLauncher: handoff,
        mediaHostProvider: () => _mediaHost,
        browserFills: () => extensionFillsHandoffs,
        resolver: VariantResolver(_settings.resolverOptions),
        options: _settings.publishOptions,
        secretsCoordinator: cloudSync.active ? cloudSync : null,
        journal: publishJournal,
        readMedia: media.read,
      );

  /// Context for connect flows (sign-in) outside a publish run.
  AdapterContext connectContext({void Function(String)? onProgress}) => AdapterContext(
        http: http,
        broker: broker,
        mediaHost: _mediaHost,
        onProgress: onProgress,
        readMedia: media.read,
      );

  /// Applies "Skip" choices made in hand-off sheets during a publish run.
  Future<Post?> applySkips(String postId) async {
    final mine = _skipped.where((k) => k.startsWith('$postId|')).toList();
    if (mine.isEmpty) return posts.get(postId);
    var post = await posts.get(postId);
    if (post == null) return null;
    for (final k in mine) {
      final accountId = k.split('|')[1];
      final t = post!.targetFor(accountId);
      if (t != null) post = post.withTarget(t.copyWith(status: TargetStatus.skipped));
      _skipped.remove(k);
    }
    final allDone = post!.targets.every((t) => t.isDone);
    post = post.copyWith(status: allDone ? PostStatus.published : post.status, updatedAt: DateTime.now());
    await posts.upsert(post);
    return post;
  }

  // -------------------------------------------------------------------------
  // Deleting posts, retention and housekeeping
  // -------------------------------------------------------------------------

  /// Deletes [doomed] for good: from posts.json (cloud sync records each
  /// deletion), with their notifications ([posts] cancels them), and with
  /// every media file that no other post, the composer draft on disk or
  /// [inUse] (documents still being edited, such as the composer itself)
  /// mentions.
  Future<void> discardPosts(Iterable<Post> doomed, {Iterable<Object?> inUse = const []}) async {
    final list = doomed.toList();
    if (list.isEmpty) return;
    for (final post in list) {
      await posts.delete(post.id);
    }
    final Set<String> referenced;
    try {
      referenced = await _referencedFileNames(inUse);
    } on Object catch (e) {
      // Unsure what is still in use: keep the files for the startup sweep.
      debugPrint('Kept the media files of deleted posts: $e');
      return;
    }
    final seen = <String>{};
    for (final post in list) {
      for (final m in post.media) {
        if (!seen.add(m.path) || referenced.contains(mediaFileName(m.path))) continue;
        try {
          await media.discard(m);
        } on Object catch (e) {
          debugPrint('Could not delete ${m.path}: $e');
        }
      }
      // Track covers: the file's own and the one the user picked.
      for (final path in audioCoverPaths(post)) {
        if (!seen.add(path) || referenced.contains(mediaFileName(path))) continue;
        try {
          await storage.deleteMedia(path);
        } on Object catch (e) {
          debugPrint('Could not delete $path: $e');
        }
      }
    }
  }

  /// Applies Settings > Activity and history: deletes the complete posts
  /// the setting no longer keeps (see [expiredPosts] for what the first
  /// start after an update deletes). Returns how many were deleted.
  Future<int> applyRetention({DateTime? now, Iterable<Object?> inUse = const []}) async {
    final expired = expiredPosts(await posts.all(), _settings.publishedPostRetention, now ?? DateTime.now());
    await discardPosts(expired, inUse: inUse);
    return expired.length;
  }

  /// Deletes post [postId] right away when it is complete ([isPostComplete]:
  /// finished, and some network has it) and the setting keeps nothing after
  /// posting. True when it was deleted.
  Future<bool> discardIfComplete(String postId, {Iterable<Object?> inUse = const []}) async {
    if (_settings.publishedPostRetention != PublishedPostRetention.discardOnCompletion) return false;
    final post = await posts.get(postId);
    if (post == null || !isPostComplete(post, DateTime.now())) return false;
    await discardPosts([post], inUse: inUse);
    return true;
  }

  /// Shown on targets a closed or crashed NEFORUM left unposted.
  static const interruptedMessage = 'NEFORUM closed before this was posted. Retry it.';

  /// Shown on targets a run of this process did not reach because it
  /// stopped with [error].
  static String stoppedMessage(Object error) => 'Posting stopped before this was posted ($error). Retry it.';

  /// Outcomes of this process's runs that could not be saved yet, because
  /// posts.json stayed locked. They know which networks have each post, so
  /// the next recovery pass saves them before anything else.
  final Map<String, Post> _unsavedOutcomes = {};

  /// How long a post may stay publishing with no run on record and no
  /// change before startup settles it (see [recoverInterruptedPublishing]):
  /// longer than any upload takes.
  static const unrecordedRunTimeout = Duration(hours: 2);

  /// Posts whose run on this device ended without saving its outcome
  /// (NEFORUM closed, crashed or was killed, a background task was stopped):
  /// their targets still waiting or posting become failed, so they show
  /// under Activity > Failed with Retry instead of looking busy for ever.
  /// Returns how many posts were settled.
  ///
  /// Runs [publishJournal] proves abandoned are settled. A run whose
  /// heartbeat is recent may belong to a background isolate still
  /// publishing it (Android WorkManager, iOS), and runs in [exclude] are
  /// this process's own. The posts are read from posts.json first, since
  /// such an isolate saves its progress there: what it posted stays posted.
  ///
  /// A post with no run on record came from another device through sync,
  /// and that device's own result follows. At startup ([atStartup]) such a
  /// post is settled too once it has not changed for [unrecordedRunTimeout]:
  /// no run is still posting it by then. NEFORUM 1.1.5 and earlier kept no
  /// journal, so the posts they left publishing are settled this way.
  ///
  /// A settled post keeps its last change time, so a newer real result
  /// still wins a sync merge.
  Future<int> recoverInterruptedPublishing({DateTime? now, Set<String> exclude = const {}, bool atStartup = false}) async {
    await posts.reload();
    var recovered = 0;
    for (final outcome in _unsavedOutcomes.values.toList()) {
      if (await _saveOutcome(outcome)) recovered++;
    }
    final runs = await publishJournal.entries();
    final at = now ?? DateTime.now();
    final roller = publisher();
    Future<void> settle(Post post) async {
      await posts.upsert(roller.rollUpStatus(failUnfinishedTargets(post, interruptedMessage)));
      recovered++;
    }

    final settled = <String>[];
    for (final run in runs.values) {
      if (exclude.contains(run.postId) || _unsavedOutcomes.containsKey(run.postId) || !publishJournal.isAbandoned(run, now: at)) continue;
      final post = await posts.get(run.postId);
      settled.add(run.postId);
      if (post == null || post.status != PostStatus.publishing) continue;
      await settle(post);
    }
    await publishJournal.remove(settled);
    if (atStartup) {
      for (final post in await posts.all()) {
        if (post.status != PostStatus.publishing || runs.containsKey(post.id) || exclude.contains(post.id) || _unsavedOutcomes.containsKey(post.id)) continue;
        if (at.difference(lastChangeOf(post)) < unrecordedRunTimeout) continue;
        await settle(post);
      }
    }
    return recovered;
  }

  /// Settles post [postId] after its run in this process stopped with
  /// [error] instead of an outcome, so that it never looks busy without a
  /// run: the targets the run did not reach become failed with the error,
  /// and show Retry. When [error] carries the run's outcome
  /// ([PublishOutcomeNotSaved]), that outcome is saved instead, since it
  /// knows which networks already have the post. A post another isolate is
  /// publishing is left alone, and one whose run another isolate abandoned
  /// is settled from what that isolate saved. When posts.json still cannot
  /// be written, the next recovery pass saves it.
  Future<void> concludeStoppedRun(String postId, Object error) async {
    try {
      final run = (await publishJournal.entries())[postId];
      if (run != null && run.owner != publishJournal.owner) {
        if (!publishJournal.isAbandoned(run)) return;
        await posts.reload();
      }
      final Post outcome;
      if (error is PublishOutcomeNotSaved) {
        outcome = error.post;
      } else {
        final stored = await posts.get(postId);
        if (stored == null || stored.status != PostStatus.publishing) {
          await publishJournal.release(postId);
          return;
        }
        outcome = publisher().rollUpStatus(failUnfinishedTargets(stored, stoppedMessage(error))).copyWith(updatedAt: DateTime.now());
      }
      _unsavedOutcomes[postId] = outcome;
      await _saveOutcome(outcome);
    } on Object catch (e) {
      debugPrint('Could not settle the stopped run of $postId: $e');
    }
  }

  /// Saves [outcome] unless the post was deleted or changed since its run
  /// stopped. True when it was saved.
  Future<bool> _saveOutcome(Post outcome) async {
    final bool saved;
    try {
      final stored = await posts.get(outcome.id);
      saved = stored != null && stored.status == PostStatus.publishing;
      if (saved) await posts.upsert(outcome);
    } on Object catch (e) {
      debugPrint('Could not save the outcome of ${outcome.id} yet: $e');
      return false;
    }
    _unsavedOutcomes.remove(outcome.id);
    try {
      await publishJournal.release(outcome.id);
    } on Object catch (e) {
      // The post is settled; recovery takes the stale run off the record.
      debugPrint('Could not take the run of ${outcome.id} off the publish journal: $e');
    }
    return saved;
  }

  /// Deletes media files that no post and no draft mentions: photos taken
  /// out of the composer, and files a crash left between saving a file and
  /// saving its post. Files changed within [grace] are kept, since they may
  /// belong to a post being written right now. Returns how many went.
  Future<int> deleteUnreferencedMedia({Iterable<Object?> inUse = const [], Duration grace = const Duration(minutes: 10), DateTime? now}) async {
    final files = await listMediaFiles(storage.dataDir);
    if (files.isEmpty) return 0;
    final orphans = unreferencedMediaFiles(files, await _referencedFileNames(inUse), now: now ?? DateTime.now(), grace: grace);
    for (final path in orphans) {
      await storage.deleteMedia(path);
    }
    return orphans.length;
  }

  /// Housekeeping when the app starts, before anything is published:
  /// abandoned runs become failures, retention applies, and unused media
  /// files and day-old share-sheet copies are deleted. Not in the demo,
  /// whose sample history stays as it is.
  Future<void> performStartupMaintenance() async {
    if (demo) return;
    Future<void> step(String what, Future<Object?> Function() run) async {
      try {
        await run();
      } on Object catch (e) {
        debugPrint('Startup housekeeping ($what) failed: $e');
      }
    }

    await step('interrupted posts', () => recoverInterruptedPublishing(atStartup: true));
    await step('retention', applyRetention);
    await step('unused media', deleteUnreferencedMedia);
    await step('share-sheet copies', deleteExpiredShareExports);
  }

  /// Names of the files every post, the composer draft on disk and
  /// [inUse] mention. Throws when the draft cannot be read: nothing may be
  /// deleted then.
  Future<Set<String>> _referencedFileNames(Iterable<Object?> inUse) async => referencedFileNames([
        for (final post in await posts.all()) post.toJson(),
        await storage.readJson(kComposerDraftFile),
        ...inUse,
      ]);

  void dispose() {
    _disposed = true;
    cloudSync.dispose();
    unawaited(browserBridge.dispose());
    http.close();
  }
}

/// Posts, with their notifications cancelled whenever one is deleted,
/// whatever deletes it: the user, retention, Clear failed, or a deletion that
/// arrives through cloud sync. The notifications quote the post's text.
class _NotificationCancellingPostRepository implements PostRepository {
  _NotificationCancellingPostRepository(this._posts);

  final PostRepository _posts;

  @override
  Stream<void> get changes => _posts.changes;

  @override
  Future<List<Post>> all() => _posts.all();

  @override
  Future<Post?> get(String id) => _posts.get(id);

  @override
  Future<void> upsert(Post post) => _posts.upsert(post);

  @override
  Future<void> delete(String id) async {
    await _posts.delete(id);
    await NotificationService.instance.cancelPostNotifications(id);
  }

  @override
  Future<List<Post>> due(DateTime now) => _posts.due(now);

  @override
  Future<void> reload() => _posts.reload();
}

/// Whether [t] really reached its network: published, handed off, or held
/// by its platform past its scheduled time (the platform has published it).
/// A skipped network never got the post.
bool reachedNetwork(PostTarget t, DateTime now) =>
    t.status == TargetStatus.published || t.status == TargetStatus.handedOff || _releasedByPlatform(t, now);

bool _releasedByPlatform(PostTarget t, DateTime now) =>
    t.isHeldByPlatform && t.result != null && !(t.result!.scheduledFor?.isAfter(now) ?? false);

/// Drafts, posts in a run and posts without targets are never finished.
bool _settled(Post post) => post.status != PostStatus.draft && post.status != PostStatus.publishing && post.targets.isNotEmpty;

/// Whether [post] is finished and some network has it: each target
/// published, handed off or skipped, or held by its platform past its
/// scheduled time, and at least one of them [reachedNetwork]. Nothing
/// failed, cancelled, waiting or posting. A post that reached no network
/// (every account switched off, every hand-off skipped) never is: it stays
/// in Activity, where it can be duplicated or deleted.
bool isPostComplete(Post post, DateTime now) =>
    _settled(post) &&
    post.targets.every((t) => t.isDone || _releasedByPlatform(t, now)) &&
    post.targets.any((t) => reachedNetwork(t, now));

/// Whether every target of [post] [reachedNetwork], none skipped.
bool reachedEveryNetwork(Post post, DateTime now) => _settled(post) && post.targets.every((t) => reachedNetwork(t, now));

/// How long [retention] keeps a complete post after its last change; null
/// keeps it until the user deletes it.
Duration? retentionPeriod(PublishedPostRetention retention) => switch (retention) {
      PublishedPostRetention.discardOnCompletion => Duration.zero,
      PublishedPostRetention.retainSevenDays => const Duration(days: 7),
      PublishedPostRetention.retainThirtyDays => const Duration(days: 30),
      PublishedPostRetention.retainIndefinitely => null,
    };

/// The complete posts in [all] that [retention] no longer keeps at [now].
/// A post's completion time is its last change ([Post.updatedAt]).
///
/// [PublishedPostRetention.discardOnCompletion] deletes a post the moment
/// it completes ([AppServices.discardIfComplete]). Its sweeps, at startup
/// and by the hour, delete only the posts that [reachedEveryNetwork],
/// because they also see what earlier versions kept: settings saved before
/// 1.2.0 have no retention choice and read as this default, so the first
/// start after the update finds the whole history here. Posts every network
/// really got are deleted then, as the setting says. A post with a skipped
/// network, which may still be wanted there, and a post that reached no
/// network at all stay in Activity.
List<Post> expiredPosts(Iterable<Post> all, PublishedPostRetention retention, DateTime now) {
  final keep = retentionPeriod(retention);
  if (keep == null) return const [];
  if (keep == Duration.zero) return [for (final post in all) if (reachedEveryNetwork(post, now)) post];
  return [
    for (final post in all)
      if (isPostComplete(post, now) && now.difference(post.updatedAt) >= keep) post,
  ];
}

/// The last time [post] changed: its own change time, or a later attempt at
/// one of its targets (a run saves its progress target by target without
/// changing the post's time).
DateTime lastChangeOf(Post post) => post.targets.map((t) => t.lastAttemptAt).nonNulls.fold(post.updatedAt, (last, t) => t.isAfter(last) ? t : last);

/// [post] with every target still waiting or being posted marked failed
/// with [message], so that it can be retried.
Post failUnfinishedTargets(Post post, String message) {
  var fixed = post;
  for (final t in post.targets) {
    if (t.status != TargetStatus.pending && t.status != TargetStatus.publishing) continue;
    fixed = fixed.withTarget(t.copyWith(
      status: TargetStatus.failed,
      result: PublishResult.failure(PublishError(kind: PublishErrorKind.network, message: message)),
    ));
  }
  return fixed;
}

/// How media files are matched: the last segment of a path, in lower case
/// (Windows paths are case-insensitive; `mem://` paths work too).
String mediaFileName(String path) => p.posix.basename(path.replaceAll(r'\', '/')).toLowerCase();

/// The [mediaFileName] of every string in [documents] (JSON values,
/// searched all the way down) that could name a file. Media references
/// live in more places than `Post.media` (text-card backgrounds, render
/// parameters), so the whole document counts.
Set<String> referencedFileNames(Iterable<Object?> documents) {
  final out = <String>{};
  void visit(Object? v) {
    if (v is String) {
      if (v.contains('.')) out.add(mediaFileName(v));
    } else if (v is Map) {
      v.values.forEach(visit);
    } else if (v is Iterable) {
      v.forEach(visit);
    }
  }

  documents.forEach(visit);
  return out;
}

/// The cover pictures of [post]'s sound files: those the files carry
/// ([MediaAttachment.audioTags]) and the one the user chose
/// ([Post.audioDetails]). They are media files of their own, not in
/// [Post.media].
List<String> audioCoverPaths(Post post) => [
      for (final m in post.media)
        if (m.audioTags?.coverPath case final path? when path.isNotEmpty) path,
      if (post.audioDetails?.coverPath case final path? when path.isNotEmpty) path,
    ];

/// Paths of the files in [files] that no name in [referenced] matches and
/// that did not change within [grace] before [now].
List<String> unreferencedMediaFiles(List<StoredFile> files, Set<String> referenced, {required DateTime now, Duration grace = const Duration(minutes: 10)}) => [
      for (final f in files)
        if (!referenced.contains(mediaFileName(f.path)) && now.difference(f.modified) > grace) f.path,
    ];
