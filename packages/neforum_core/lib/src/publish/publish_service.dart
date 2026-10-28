import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../adapters/adapter_context.dart';
import '../adapters/adapter_registry.dart';
import '../adapters/platform_adapter.dart';
import '../auth/auth_broker.dart';
import '../handoff/handoff_plan.dart';
import '../http/neforum_http.dart';
import '../media_hosts/media_host.dart';
import '../model/account.dart';
import '../model/media.dart';
import '../model/platform_descriptor.dart';
import '../model/post.dart';
import '../model/post_placement.dart';
import '../model/post_variant.dart';
import '../model/publish_result.dart';
import '../model/validation.dart';
import '../quota/quota_tracker.dart';
import '../storage/repositories.dart';
import '../storage/secret_store.dart';
import '../sync/secrets_coordinator.dart';
import '../text/variant_resolver.dart';
import '../util/logger.dart';
import 'cancellation_signal.dart';
import 'publish_journal.dart';

/// What happened when the environment tried to execute a [HandoffPlan].
enum HandoffOutcome {
  /// Share sheet / browser was opened; the user is now in the other app.
  launched,

  /// Cannot open UI right now (background run); a notification was queued and
  /// the user will trigger it later via [PublishService.runHandoff].
  deferred,

  /// This environment cannot execute the plan at all.
  unavailable,
}

/// What [HandoffLauncher.launch] did with a [HandoffPlan].
@immutable
class HandoffResult {
  const HandoffResult(this.outcome, {this.note});

  static const launched = HandoffResult(HandoffOutcome.launched);
  static const deferred = HandoffResult(HandoffOutcome.deferred);
  static const unavailable = HandoffResult(HandoffOutcome.unavailable);

  final HandoffOutcome outcome;

  /// With [HandoffOutcome.deferred]: what an automatic attempt to post the
  /// hand-off left for the user to check before posting it by hand (Post
  /// may already have been pressed). The target keeps it as its
  /// [PostTarget.handoffNote], and is then never posted automatically
  /// again. Null when there was no such attempt.
  final String? note;
}

/// Executes hand-off plans. The Flutter app implements this with share_plus,
/// url_launcher and the clipboard; the CLI prints the plan.
abstract class HandoffLauncher {
  Future<HandoffResult> launch(
    HandoffPlan plan, {
    required Post post,
    required PostTarget target,
    required PostVariant variant,
    required ConnectedAccount account,
  });
}

@immutable
class PublishOptions {
  const PublishOptions({
    this.fallbackToHandoffOnQuota = true,
    this.maxAttempts = 3,
    this.retryBackoffBase = const Duration(minutes: 2),
  });

  /// When an API tier hits its quota, hand the post to the user instead of
  /// failing (if the platform has a hand-off route).
  final bool fallbackToHandoffOnQuota;
  final int maxAttempts;
  final Duration retryBackoffBase;
}

/// One target resolved and validated, for the composer's live preview.
@immutable
class TargetPreview {
  const TargetPreview({
    required this.target,
    required this.account,
    required this.descriptor,
    required this.variant,
    required this.issues,
  });

  final PostTarget target;
  final ConnectedAccount account;
  final PlatformDescriptor descriptor;
  final PostVariant variant;
  final List<ValidationIssue> issues;

  bool get canPublish => !issues.hasErrors;
}

/// Result of [PublishService.releaseSchedules].
@immutable
class ReleaseOutcome {
  const ReleaseOutcome({required this.post, this.failed = const {}, this.alreadyLive = const {}});

  final Post post;

  /// Account id -> why the held copy could not be removed. Those copies may
  /// still go out at their scheduled time.
  final Map<String, PublishError> failed;

  /// Accounts whose held copy had already been published by the platform.
  final Set<String> alreadyLive;

  bool get ok => failed.isEmpty;
}

/// Thrown by [PublishService.publish] when the run ended but its outcome
/// could not be saved (posts.json stayed locked). [post] is the outcome as
/// the run left it, with every network that already has the post: save it
/// as soon as the file can be written, so nothing is posted twice.
class PublishOutcomeNotSaved implements Exception {
  const PublishOutcomeNotSaved(this.post, this.cause);

  final Post post;
  final Object cause;

  @override
  String toString() => 'The result could not be saved: $cause';
}

/// Fans a [Post] out to its targets: resolves the per-platform variant,
/// validates, refreshes tokens, checks quota, publishes or hands off, and
/// records the outcome on the post.
class PublishService {
  PublishService({
    required this.registry,
    required this.accounts,
    required this.posts,
    required this.secrets,
    required this.quota,
    required this.http,
    this.mediaHostProvider,
    this.browserFills,
    this.broker,
    this.handoffLauncher,
    this.resolver = const VariantResolver(),
    this.options = const PublishOptions(),
    this.secretsCoordinator,
    this.journal,
    Clock? clock,
    Logger? log,
    Future<Uint8List> Function(MediaAttachment media)? readMedia,
  })  : _now = clock ?? systemClock,
        _log = log ?? Logger('publish'),
        _readMedia = readMedia;

  final AdapterRegistry registry;
  final AccountRepository accounts;
  final PostRepository posts;
  final SecretStore secrets;
  final QuotaTracker quota;
  final NeforumHttp http;

  /// Returns the currently configured public media host (or `null`).
  final MediaHost? Function()? mediaHostProvider;

  /// Whether the NEFORUM browser extension will fill in hand-offs now (see
  /// [AdapterContext.browserFills]).
  final bool Function()? browserFills;
  final AuthBroker? broker;
  final HandoffLauncher? handoffLauncher;
  final VariantResolver resolver;
  final PublishOptions options;

  /// Renews sign-ins that several devices share through the sync file, for
  /// accounts whose network rotates refresh tokens (the sync engine).
  final SecretsCoordinator? secretsCoordinator;

  /// Where [publish] keeps its run on record while it goes, so that a run
  /// this process abandons can be recovered and one it still executes is
  /// left alone (see [PublishJournal]).
  final PublishJournal? journal;
  final Clock _now;
  final Logger _log;
  final Future<Uint8List> Function(MediaAttachment media)? _readMedia;

  AdapterContext context({void Function(String message)? onProgress, Logger? log, CancellationSignal? cancellation}) => AdapterContext(
        http: http,
        broker: broker,
        mediaHost: mediaHostProvider?.call(),
        log: log ?? _log,
        clock: _now,
        onProgress: onProgress,
        browserFills: browserFills?.call() ?? false,
        readMedia: _readMedia,
        cancellation: cancellation,
      );

  // ---------------------------------------------------------------------
  // Preview / validation
  // ---------------------------------------------------------------------

  /// Resolves and validates every target without side effects.
  Future<List<TargetPreview>> preview(Post post) async {
    final out = <TargetPreview>[];
    for (final target in post.targets) {
      final account = await accounts.get(target.accountId);
      if (account == null) continue;
      final adapter = registry.byId(account.platformId);
      if (adapter == null) continue;
      final d = adapter.descriptorForAccount(account);
      final variant = resolver.resolve(post, target, d, account: account);
      final issues = [...variant.issues, ...adapter.validate(variant, account)];
      out.add(TargetPreview(target: target, account: account, descriptor: d, variant: variant, issues: issues));
    }
    return out;
  }

  Future<HandoffPlan?> planHandoff(Post post, String accountId) async {
    final target = post.targetFor(accountId);
    final account = await accounts.get(accountId);
    if (target == null || account == null) return null;
    final adapter = registry.byId(account.platformId);
    if (adapter == null) return null;
    final variant = resolver.resolve(post, target, adapter.descriptorForAccount(account), account: account);
    try {
      return await adapter.prepareHandoff(variant, account, context(log: _log.child(account.platformId)));
    } on Object catch (e) {
      _log.warn('Preparing the ${adapter.descriptor.name} hand-off failed ($e); using the plain plan');
      return adapter.buildHandoff(variant, account: account);
    }
  }

  // ---------------------------------------------------------------------
  // Publishing
  // ---------------------------------------------------------------------

  /// Publishes every pending target of [postId]. With [interactive] false
  /// (background run) hand-off targets are only marked as waiting. With
  /// [retryFailed] failed and cancelled targets are tried again.
  ///
  /// When [cancellation] fires, the request in flight is aborted and the
  /// target being posted plus every target still to come become
  /// [TargetStatus.cancelled]; targets already posted stay posted.
  ///
  /// With [dueTargetsOnly] (the scheduler) a pending target whose own time
  /// ([Post.dueAtFor]) has not come yet is left for a later run; the post
  /// then stays scheduled for the next of those times.
  ///
  /// Whatever goes wrong with one target fails that target; the run goes on.
  /// When the outcome cannot be saved at the end, [PublishOutcomeNotSaved]
  /// carries it. The run stays on record in [journal] until its outcome is
  /// saved.
  Future<Post> publish(
    String postId, {
    bool interactive = true,
    Set<String>? onlyAccountIds,
    bool retryFailed = true,
    void Function(String accountId, String message)? onProgress,
    CancellationSignal? cancellation,
    bool dueTargetsOnly = false,
  }) async {
    var post = await _require(postId);
    await _recordRun(postId);
    final journal = this.journal;
    final heartbeat = journal == null ? null : Timer.periodic(journal.heartbeatInterval, (_) => unawaited(_recordRun(postId)));
    try {
      post = post.copyWith(status: PostStatus.publishing, updatedAt: _now());
      await posts.upsert(post);
      _log.info('Publishing "${_short(post.text)}" to ${post.targets.length} target(s)');

      for (final target in post.targets) {
        if (onlyAccountIds != null && !onlyAccountIds.contains(target.accountId)) continue;
        if (target.isHeldByPlatform) {
          // The platform publishes this one itself; record it once its time
          // has come. Never publish it a second time from here.
          final held = target.result;
          if (held != null && _isReleased(held)) {
            post = post.withTarget(target.copyWith(status: TargetStatus.published, result: held.asReleased()));
            await _saveProgress(post);
          }
          continue;
        }
        if (target.isDone) continue;
        if (dueTargetsOnly && target.status == TargetStatus.pending && !post.isTargetDue(target, _now())) continue;
        if (_isFailedOrCancelled(target) && !retryFailed) continue;
        if (target.status == TargetStatus.awaitingHandoff && !interactive) continue;
        if (cancellation != null && cancellation.isCancelled) {
          // Waiting retries included: the scheduler must not pick them up later.
          post = post.withTarget(_cancel(target));
          continue;
        }
        if (_inBackoff(target)) continue;
        PostTarget updated;
        try {
          updated = await _publishTarget(
            post,
            target,
            interactive: interactive,
            onProgress: onProgress == null ? null : (m) => onProgress(target.accountId, m),
            cancellation: cancellation,
          );
        } on Object catch (e, st) {
          // Something around the network call broke (a file that cannot be
          // read, a hand-off sheet that failed to open). The post must never
          // be left looking busy: this target fails and can be retried.
          _log.error('Unexpected error with ${target.accountId}', e);
          _log.debug('$st');
          updated = cancellation != null && cancellation.isCancelled
              ? _cancel(target)
              : _fail(target, PublishError.platform('Something went wrong before this was posted: $e'));
        }
        post = post.withTarget(updated);
        await _saveProgress(post); // persist progress target by target
      }
      if (cancellation != null && cancellation.isCancelled) _log.info('Publishing "${_short(post.text)}" was cancelled');
      post = _rollup(post).copyWith(updatedAt: _now());
      try {
        await posts.upsert(post);
      } on Object catch (e) {
        throw PublishOutcomeNotSaved(post, e);
      }
    } finally {
      heartbeat?.cancel();
    }
    // Only a saved outcome takes the run off the record. Otherwise its
    // heartbeat has stopped, and recovery finds it abandoned.
    await _releaseRun(postId);
    return post;
  }

  /// Saves the run's progress after a target. A write that fails does not
  /// stop the run: [post] keeps every result in memory, and the next write
  /// (after the next target, or at the end) saves them all.
  Future<void> _saveProgress(Post post) async {
    try {
      await posts.upsert(post);
    } on Object catch (e) {
      _log.warn('Could not save the progress of "${_short(post.text)}" yet ($e); the next write includes it');
    }
  }

  Future<void> _recordRun(String postId) async {
    try {
      await journal?.record(postId);
    } on Object catch (e) {
      _log.warn('Could not record the run of $postId in the publish journal: $e');
    }
  }

  Future<void> _releaseRun(String postId) async {
    try {
      await journal?.release(postId);
    } on Object catch (e) {
      _log.warn('Could not take the run of $postId off the publish journal: $e');
    }
  }

  /// [post] with its status worked out from its targets, as a publish run
  /// leaves it: published when every target is done, scheduled while a
  /// target waits for a retry or its platform, otherwise partial, cancelled
  /// or failed.
  Post rollUpStatus(Post post) => _rollup(post);

  /// The user triggered a hand-off (tapped the notification / "Post now").
  Future<Post> runHandoff(String postId, String accountId) async {
    var post = await _require(postId);
    final target = post.targetFor(accountId);
    if (target == null) return post;
    final updated = await _publishTarget(post, target, interactive: true, onProgress: null, forceHandoff: true);
    post = _rollup(post.withTarget(updated)).copyWith(updatedAt: _now());
    await posts.upsert(post);
    return post;
  }

  /// The user tells us whether they completed a hand-off in the other app.
  Future<Post> confirmHandoff(String postId, String accountId, {bool completed = true}) async {
    var post = await _require(postId);
    final target = post.targetFor(accountId);
    if (target == null) return post;
    final updated = target.copyWith(
      status: completed ? TargetStatus.handedOff : TargetStatus.awaitingHandoff,
      result: completed ? PublishResult.handedOff() : null,
      clearHandoffNote: completed,
    );
    post = _rollup(post.withTarget(updated)).copyWith(updatedAt: _now());
    await posts.upsert(post);
    return post;
  }

  /// An automatic hand-off of [accountId]'s target ended without a confirmed
  /// post: the target keeps waiting, with [note] saying what to check before
  /// posting it by hand (see [PostTarget.handoffNote]).
  Future<Post> noteHandoff(String postId, String accountId, String note) async {
    var post = await _require(postId);
    final target = post.targetFor(accountId);
    if (target == null || target.status != TargetStatus.awaitingHandoff) return post;
    post = post.withTarget(target.copyWith(handoffNote: note)).copyWith(updatedAt: _now());
    await posts.upsert(post);
    return post;
  }

  /// The user stopped a run after [publish] returned, while the hand-offs
  /// of [accountIds] were still to be posted automatically: those targets
  /// that are not done become [TargetStatus.cancelled], to retry like failed
  /// ones.
  Future<Post> cancelTargets(String postId, Iterable<String> accountIds) async {
    var post = await _require(postId);
    final ids = accountIds.toSet();
    for (final target in post.targets) {
      if (!ids.contains(target.accountId) || target.isDone) continue;
      post = post.withTarget(_cancel(target));
    }
    post = _rollup(post).copyWith(updatedAt: _now());
    await posts.upsert(post);
    return post;
  }

  // ---------------------------------------------------------------------
  // Server-side scheduling
  // ---------------------------------------------------------------------

  /// Hands the schedule of [postId] to every platform that can hold a post
  /// itself (Mastodon, Facebook Pages, YouTube, Tumblr, WordPress, Ghost).
  /// Those targets become [TargetStatus.heldByPlatform] and go out even when
  /// this device is off. Everything else stays pending for the local
  /// scheduler, which is also the fallback whenever delegation does not work
  /// (thread, schedule too soon or too far out, platform error): this method
  /// never fails a target.
  Future<Post> delegateSchedules(
    String postId, {
    Set<String>? onlyAccountIds,
    void Function(String accountId, String message)? onProgress,
  }) async {
    var post = await _require(postId);
    if (post.status != PostStatus.scheduled) return post;
    for (final target in post.targets) {
      if (onlyAccountIds != null && !onlyAccountIds.contains(target.accountId)) continue;
      if (target.status != TargetStatus.pending || target.attempts > 0) continue;
      // Each target's own time when the post has a different time per network.
      final at = post.dueAtFor(target);
      if (at == null || !at.isAfter(_now())) continue;
      final updated = await _delegateTarget(post, target,
          onProgress: onProgress == null ? null : (m) => onProgress(target.accountId, m));
      if (updated == null) continue;
      // A held target no longer waits for this device: the post's time moves
      // to the next target that does.
      post = post.withTarget(updated).withScheduleFromTargets();
      await posts.upsert(post);
    }
    return post;
  }

  /// Whether [delegateSchedules] would try this target. Cheap; for the UI.
  bool canDelegate(ConnectedAccount account) {
    if (!account.enabled || !account.tier.isAutomatic) return false;
    final adapter = registry.byId(account.platformId);
    return adapter != null && adapter.descriptorForAccount(account).serverSideScheduling;
  }

  Future<PostTarget?> _delegateTarget(Post post, PostTarget target, {void Function(String message)? onProgress}) async {
    final account = await accounts.get(target.accountId);
    if (account == null || !canDelegate(account)) return null;
    final adapter = registry.byId(account.platformId)!;
    final name = adapter.descriptor.name;
    final log = _log.child(account.platformId);
    final variant = resolver.resolve(post, target, adapter.descriptorForAccount(account), account: account, delegateSchedule: true);
    // A thread cannot be held: its replies need the first part's id.
    if (variant.scheduledAt == null || variant.isThread) return null;
    final issues = [...variant.issues, ...adapter.validate(variant, account)];
    if (issues.hasErrors) {
      log.info('${account.displayName}: keeping the schedule on this device (${issues.errors.first.message})');
      return null;
    }
    final ctx = context(onProgress: onProgress, log: log);
    final (secretMap, secretError) = await _freshSecrets(account, adapter, ctx);
    if (secretMap == null) {
      log.warn('${account.displayName}: could not hand the schedule to $name (${secretError?.message}); it stays on this device');
      return null;
    }
    if (await quota.firstExceeded(account, adapter.descriptor) != null) return null;

    PublishResult result;
    try {
      result = await adapter.publish(variant, account, secretMap, ctx);
    } on AdapterException catch (e) {
      result = PublishResult.failure(e.error);
    } on HttpFailure catch (e) {
      result = PublishResult.failure(e.toPublishError(context: name));
    } on Object catch (e) {
      result = PublishResult.failure(_classifyUnexpected(e, name));
    }
    if (result.isHeldByPlatform) {
      await quota.record(account, adapter.descriptor);
      log.info('$name holds the post for ${account.displayName} until ${result.scheduledFor!.toLocal()}');
      return target.copyWith(status: TargetStatus.heldByPlatform, result: result, lastAttemptAt: _now());
    }
    if (result.success) {
      // The server ignored the schedule and published straight away.
      await quota.record(account, adapter.descriptor);
      log.warn('$name published ${account.displayName}\'s post immediately instead of holding it');
      return target.copyWith(status: TargetStatus.published, result: result, attempts: 1, lastAttemptAt: _now());
    }
    log.warn('${account.displayName}: $name did not take the schedule (${result.error?.message}); it stays on this device');
    return null;
  }

  /// Takes back the copies platforms hold for [postId], so the post can be
  /// edited, rescheduled, published now or deleted without a stale copy
  /// going out later. Released targets return to pending. Copies whose time
  /// has already passed are recorded as published instead.
  ///
  /// Check [ReleaseOutcome.ok]: when a platform could not be reached its copy
  /// is still held and will still be published, so the caller must not
  /// pretend the edit or deletion took effect there.
  Future<ReleaseOutcome> releaseSchedules(String postId, {Set<String>? onlyAccountIds}) async {
    var post = await _require(postId);
    final failed = <String, PublishError>{};
    final live = <String>{};
    for (final target in post.targets) {
      if (!target.isHeldByPlatform) continue;
      if (onlyAccountIds != null && !onlyAccountIds.contains(target.accountId)) continue;
      final held = target.result;
      if (held == null || !held.isHeldByPlatform) {
        post = post.withTarget(target.copyWith(status: TargetStatus.pending, clearResult: true));
        continue;
      }
      if (_isReleased(held)) {
        post = post.withTarget(target.copyWith(status: TargetStatus.published, result: held.asReleased()));
        live.add(target.accountId);
        continue;
      }
      final account = await accounts.get(target.accountId);
      final adapter = account == null ? null : registry.byId(account.platformId);
      if (account == null || adapter == null) {
        failed[target.accountId] = const PublishError.configuration(
            'The account was removed from NEFORUM, so its scheduled copy has to be deleted on the platform itself');
        continue;
      }
      final name = adapter.descriptor.name;
      // Due within two minutes: the platform may be publishing it right now,
      // and a cancel would race it (a 404 would then look like "gone").
      if (held.scheduledFor!.difference(_now()) < const Duration(minutes: 2)) {
        failed[target.accountId] = PublishError.platform('$name is publishing it right now, so it can no longer be taken back');
        continue;
      }
      final ctx = context(log: _log.child(account.platformId));
      final (secretMap, secretError) = await _freshSecrets(account, adapter, ctx);
      if (secretMap == null) {
        failed[target.accountId] = secretError!;
        continue;
      }
      try {
        await adapter.cancelScheduled(held, account, secretMap, ctx);
        _log.info('Removed the copy $name was holding for ${account.displayName}');
        post = post.withTarget(target.copyWith(status: TargetStatus.pending, clearResult: true, attempts: 0));
      } on AdapterException catch (e) {
        failed[target.accountId] = e.error;
      } on HttpFailure catch (e) {
        failed[target.accountId] = e.toPublishError(context: name);
      } on Object catch (e) {
        failed[target.accountId] = _classifyUnexpected(e, name);
      }
    }
    post = post.withScheduleFromTargets().copyWith(updatedAt: _now());
    await posts.upsert(post);
    for (final e in failed.entries) {
      _log.warn('${e.key}: could not remove the held copy: ${e.value.message}');
    }
    return ReleaseOutcome(post: post, failed: failed, alreadyLive: live);
  }

  bool _isReleased(PublishResult held) {
    final at = held.scheduledFor;
    return at == null || !at.isAfter(_now());
  }

  /// Current secrets for [account], refreshed when needed. Returns the error
  /// instead when the sign-in cannot be renewed.
  Future<(Map<String, String>?, PublishError?)> _freshSecrets(
      ConnectedAccount account, PlatformAdapter adapter, AdapterContext ctx) async {
    final secretMap = await secrets.read(account.id) ?? const <String, String>{};
    try {
      final coordinator = secretsCoordinator;
      final refreshed = coordinator != null && adapter.rotatesRefreshTokensFor(account)
          ? await coordinator.renew(account, secretMap, (s) => adapter.refreshSecrets(account, s, ctx))
          : await adapter.refreshSecrets(account, secretMap, ctx);
      if (refreshed == null) return (secretMap, null);
      await secrets.write(account.id, refreshed);
      return (refreshed, null);
    } on AdapterException catch (e) {
      return (null, e.error);
    } on AuthCancelled {
      return (null, const PublishError(kind: PublishErrorKind.cancelled, message: 'Sign-in cancelled'));
    } on OperationCancelledException {
      return (null, _cancelledError);
    } on HttpFailure catch (e) {
      // A 5xx/429 from the token endpoint is the platform having a bad
      // moment, not a revoked login.
      final err = e.statusCode >= 500 || e.statusCode == 429
          ? e.toPublishError(context: '${adapter.descriptor.name} sign-in renewal')
          : PublishError.auth('Could not renew the ${adapter.descriptor.name} sign-in (HTTP ${e.statusCode}); reconnect the account', raw: e.body, statusCode: e.statusCode);
      return (null, err);
    } on Object catch (e) {
      if (NeforumHttp.isTransportError(e)) {
        return (null, PublishError.network('Could not reach ${adapter.descriptor.name} to renew the sign-in: $e'));
      }
      return (null, PublishError.auth('Could not refresh credentials: $e'));
    }
  }

  Future<PostTarget> _publishTarget(
    Post post,
    PostTarget target, {
    required bool interactive,
    required void Function(String message)? onProgress,
    bool forceHandoff = false,
    CancellationSignal? cancellation,
  }) async {
    bool cancelled() => cancellation != null && cancellation.isCancelled;
    final account = await accounts.get(target.accountId);
    if (account == null) {
      return _fail(target, const PublishError.configuration('This account was removed'));
    }
    // Skipped, never posted: the result says why, and a post whose every
    // target was skipped is not one any network has.
    if (!account.enabled) return target.copyWith(status: TargetStatus.skipped, result: PublishResult.failure(_switchedOffError));
    final adapter = registry.byId(account.platformId);
    if (adapter == null) {
      return _fail(target, PublishError.unsupported('No adapter for platform "${account.platformId}"'));
    }
    final log = _log.child(account.platformId);
    final ctx = context(onProgress: onProgress, log: log, cancellation: cancellation);

    final PostVariant variant;
    final List<ValidationIssue> issues;
    try {
      variant = resolver.resolve(post, target, adapter.descriptorForAccount(account), account: account);
      issues = [...variant.issues, ...adapter.validate(variant, account)];
    } on Object catch (e) {
      return _fail(target, PublishError.validation('Could not check the post for ${adapter.descriptor.name}: $e'));
    }
    if (issues.hasErrors) {
      return _fail(target, PublishError.validation(issues.errors.map((i) => i.message).join('; ')));
    }
    if (cancelled()) return _cancel(target);

    final attempt = target.copyWith(
      attempts: target.attempts + 1,
      lastAttemptAt: _now(),
      status: TargetStatus.publishing,
    );

    if (account.tier == PlatformTier.handoff || forceHandoff) {
      return _handoff(post, attempt, variant, account, adapter, interactive: interactive, cancellation: cancellation);
    }

    // ---- API tiers ----------------------------------------------------
    // The renewal is not bound to the run's cancellation. X, Tumblr and
    // DeviantArt retire the old refresh token as soon as they answer, so a
    // renewal cut short would leave only a dead token on this device. A
    // renewal that has started finishes and its keys are saved; Cancel
    // takes effect right after.
    final (freshSecrets, secretError) = await _freshSecrets(account, adapter, context(onProgress: onProgress, log: log));
    // A renewal cut short by the user is not a broken sign-in.
    if (cancelled()) return _cancel(attempt);
    if (freshSecrets == null) return _fail(attempt, secretError!, account: account);
    final secretMap = freshSecrets;

    final needed = _postsNeeded(variant, adapter.supportsStories(account));
    final QuotaStatus? exceeded;
    try {
      exceeded = await quota.firstExceeded(account, adapter.descriptor, needed: needed);
    } on Object catch (e) {
      return _fail(attempt, PublishError.configuration('Could not read how much of the ${adapter.descriptor.name} quota is used: $e'));
    }
    if (exceeded != null) {
      final err = PublishError.quota(
        '${adapter.descriptor.name} quota reached (${exceeded.used}/${exceeded.limit} ${exceeded.rule.note})',
        retryAfter: exceeded.resetsAt?.difference(_now()),
      );
      if (options.fallbackToHandoffOnQuota && adapter.buildHandoff(variant, account: account) != null) {
        log.warn('${account.displayName}: ${err.message}; falling back to hand-off');
        return _handoff(post, attempt, variant, account, adapter, interactive: interactive, reason: err.message, cancellation: cancellation);
      }
      return _fail(attempt, err);
    }

    PublishResult result;
    try {
      result = await adapter.publish(variant, account, secretMap, ctx);
    } on AdapterException catch (e) {
      result = PublishResult.failure(e.error);
    } on HttpFailure catch (e) {
      result = PublishResult.failure(e.toPublishError(context: adapter.descriptor.name));
    } on AuthCancelled {
      result = PublishResult.failure(const PublishError(kind: PublishErrorKind.cancelled, message: 'Cancelled'));
    } on OperationCancelledException {
      result = PublishResult.failure(_cancelledError);
    } on Object catch (e, st) {
      result = PublishResult.failure(_classifyUnexpected(e, adapter.descriptor.name));
      if (result.error!.kind == PublishErrorKind.platform) {
        log.error('Unexpected error publishing to ${account.displayName}', e);
        log.debug('$st');
      }
    }

    // From here on the network has the post: bookkeeping that fails must
    // never turn it back into one that was not posted.
    if (result.isHeldByPlatform) {
      // Not expected from a normal publish, but never record a held post as live.
      await _bestEffort(log, 'count the post against the quota', () => quota.record(account, adapter.descriptor));
      return attempt.copyWith(status: TargetStatus.heldByPlatform, result: result);
    }
    if (result.success) {
      // Posted, even if the user pressed Cancel a moment too late.
      await _bestEffort(log, 'count the post against the quota',
          () => quota.record(account, adapter.descriptor, count: math.max(1, result.threadRemoteIds.length) + result.additionalRemoteIds.length));
      if (account.lastError != null) {
        await _bestEffort(log, 'clear the account warning', () => accounts.upsert(account.copyWith(clearLastError: true)));
      }
      log.info('Published to ${account.displayName}: ${result.remoteUrl ?? result.remoteId ?? 'ok'}');
      return attempt.copyWith(status: TargetStatus.published, result: result);
    }
    final live = result.allRemoteIds;
    if (live.isNotEmpty) {
      // Some copies went live before the rest failed (a feed post before its
      // story): the target keeps their ids, and is never retried by itself.
      await _bestEffort(log, 'count the post against the quota', () => quota.record(account, adapter.descriptor, count: live.length));
      final cause = result.error!;
      final stopped = cancelled();
      log.warn('${account.displayName}: ${cause.message}');
      return attempt.copyWith(
        status: stopped ? TargetStatus.cancelled : TargetStatus.failed,
        result: PublishResult.partialFailure(
          PublishError(
            kind: stopped ? PublishErrorKind.cancelled : cause.kind,
            message: cause.message,
            statusCode: cause.statusCode,
            raw: cause.raw,
          ),
          remoteId: result.remoteId,
          remoteUrl: result.remoteUrl,
          additionalRemoteIds: result.additionalRemoteIds,
          publishedAt: result.publishedAt,
        ),
      );
    }
    if (cancelled()) return _cancel(attempt, cause: result.error);

    final err = result.error!;
    // A quota error after part of a thread went out is not retryable; handing
    // the whole post off then would post those parts a second time.
    if (err.kind == PublishErrorKind.quota && err.retryable && options.fallbackToHandoffOnQuota && adapter.buildHandoff(variant, account: account) != null) {
      log.warn('${account.displayName}: ${err.message}; falling back to hand-off');
      return _handoff(post, attempt, variant, account, adapter, interactive: interactive, reason: err.message, cancellation: cancellation);
    }
    return _fail(attempt, err, account: account);
  }

  Future<PostTarget> _handoff(
    Post post,
    PostTarget attempt,
    PostVariant variant,
    ConnectedAccount account,
    PlatformAdapter adapter, {
    required bool interactive,
    String? reason,
    CancellationSignal? cancellation,
  }) async {
    HandoffPlan? plan;
    try {
      plan = await adapter.prepareHandoff(variant, account, context(log: _log.child(account.platformId), cancellation: cancellation));
    } on Object catch (e) {
      if (cancellation != null && cancellation.isCancelled) return _cancel(attempt);
      _log.warn('Preparing the ${adapter.descriptor.name} hand-off failed ($e); using the plain plan');
      plan = adapter.buildHandoff(variant, account: account);
    }
    // Never open the hand-off sheet for a run the user cancelled.
    if (cancellation != null && cancellation.isCancelled) return _cancel(attempt);
    if (plan == null) {
      return _fail(attempt, PublishError.unsupported('${adapter.descriptor.name} has no hand-off route'));
    }
    if (reason != null) plan = plan.copyWith(instructions: '$reason\n\n${plan.instructions}');
    final launcher = handoffLauncher;
    if (!interactive || launcher == null) {
      return attempt.copyWith(status: TargetStatus.awaitingHandoff);
    }
    final launched = await launcher.launch(plan, post: post, target: attempt, variant: variant, account: account);
    return switch (launched.outcome) {
      HandoffOutcome.launched => attempt.copyWith(
          status: TargetStatus.handedOff,
          result: PublishResult.handedOff(remoteUrl: plan.webIntent?.toString()),
          clearHandoffNote: true,
        ),
      // An automatic attempt that ended without a confirmed post leaves its
      // note with the target; an earlier note stays when there is no new one.
      HandoffOutcome.deferred => attempt.copyWith(status: TargetStatus.awaitingHandoff, handoffNote: launched.note),
      HandoffOutcome.unavailable => _fail(attempt, const PublishError.configuration('Hand-off is not available in this environment')),
    };
  }

  PostTarget _fail(PostTarget t, PublishError error, {ConnectedAccount? account}) {
    if (account != null && error.kind == PublishErrorKind.auth) {
      // Fire and forget; the account list shows the warning.
      unawaited(_bestEffort(_log, 'save the account warning', () => accounts.upsert(account.copyWith(lastError: error.message))));
    }
    final retry = error.retryable && t.attempts < options.maxAttempts && t.attempts > 0;
    _log.warn('${account?.displayName ?? t.accountId}: ${error.message}${retry ? ' (will retry)' : ''}');
    return t.copyWith(status: retry ? TargetStatus.pending : TargetStatus.failed, result: PublishResult.failure(error));
  }

  /// Runs [step] and only logs when it fails.
  static Future<void> _bestEffort(Logger log, String what, Future<void> Function() step) async {
    try {
      await step();
    } on Object catch (e) {
      log.warn('Could not $what: $e');
    }
  }

  static const _cancelledError = PublishError(kind: PublishErrorKind.cancelled, message: 'Cancelled before it was posted');

  static const _switchedOffError = PublishError.configuration('Not posted: this account was switched off in Accounts.');

  /// [t] stopped by the user. [cause] is the error the interrupted attempt
  /// ended with, if any.
  PostTarget _cancel(PostTarget t, {PublishError? cause}) {
    // A thread cut off halfway keeps the adapter's explanation: its first
    // parts are live, and a retry would post them again.
    final error = cause != null && _isPartialThread(cause)
        ? PublishError(kind: PublishErrorKind.cancelled, message: cause.message, statusCode: cause.statusCode, raw: cause.raw)
        : _cancelledError;
    _log.info('${t.accountId}: cancelled');
    return t.copyWith(status: TargetStatus.cancelled, result: PublishResult.failure(error));
  }

  /// The wording of [PublishError.asPartialThread].
  static final _partialThread = RegExp(r'^Part \d+ of \d+ failed: ');

  static bool _isPartialThread(PublishError e) => !e.retryable && _partialThread.hasMatch(e.message);

  /// How many posts [variant] makes on its network, for the quota: one per
  /// part of a thread, else one feed post plus one per story frame where the
  /// account takes stories ([PostPlacement]).
  static int _postsNeeded(PostVariant variant, bool stories) {
    if (variant.isThread) return variant.threadParts.length;
    if (!stories) return 1;
    final frames = math.max(1, variant.storyFrames.length);
    return switch (variant.placement) {
      PostPlacement.feed => 1,
      PostPlacement.story => frames,
      PostPlacement.feedAndStory => 1 + frames,
    };
  }

  /// Failed and cancelled targets are only tried again when the run asks.
  static bool _isFailedOrCancelled(PostTarget t) => t.status == TargetStatus.failed || t.status == TargetStatus.cancelled;

  bool _inBackoff(PostTarget t) {
    if (t.status != TargetStatus.pending || t.attempts == 0 || t.lastAttemptAt == null) return false;
    final wait = options.retryBackoffBase * math.pow(2, t.attempts - 1).toInt();
    return _now().isBefore(t.lastAttemptAt!.add(wait));
  }

  Post _rollup(Post p) {
    if (p.targets.isEmpty) return p.copyWith(status: PostStatus.draft);
    final ts = p.targets;
    final anyRetrying = ts.any((t) => t.status == TargetStatus.pending || t.status == TargetStatus.publishing);
    final anyHeld = ts.any((t) => t.isHeldByPlatform);
    final anyWaiting = ts.any((t) => t.status == TargetStatus.awaitingHandoff);
    final anyFailed = ts.any((t) => t.status == TargetStatus.failed);
    final anyCancelled = ts.any((t) => t.status == TargetStatus.cancelled);
    final allDone = ts.every((t) => t.isDone);
    if (allDone) return p.copyWith(status: PostStatus.published);
    if (anyRetrying || anyHeld) {
      // Keep it in the queue so the scheduler retries; immediate publishes
      // get "now" as their schedule so they are picked up too. With a
      // different time per network the post waits for the next target's time.
      final waiting = p.withScheduleFromTargets();
      return waiting.copyWith(status: PostStatus.scheduled, scheduledAt: waiting.scheduledAt ?? _now());
    }
    if (anyWaiting || ((anyFailed || anyCancelled) && ts.any((t) => t.isDone))) return p.copyWith(status: PostStatus.partial);
    if (anyCancelled) return p.copyWith(status: PostStatus.cancelled);
    return p.copyWith(status: PostStatus.failed);
  }

  /// Maps an exception that escaped an adapter onto a sensible error kind.
  static PublishError _classifyUnexpected(Object e, String platform) {
    if (NeforumHttp.isTransportError(e)) {
      return PublishError.network('Could not reach $platform: $e');
    }
    final text = e.toString();
    // dart:io is off limits here (web builds), so recognise file errors by name.
    if (text.startsWith('FileSystemException') || text.contains('PathNotFoundException') || text.contains('Media not found')) {
      return PublishError.configuration('A media file for this post is missing or unreadable. Re-attach it and try again. ($text)');
    }
    if (e is FormatException || e is TypeError) {
      return PublishError.platform('$platform sent a response NEFORUM did not understand: $text');
    }
    return PublishError.platform('Unexpected error: $text');
  }

  Future<Post> _require(String postId) async {
    final post = await posts.get(postId);
    if (post == null) throw ArgumentError.value(postId, 'postId', 'Unknown post');
    return post;
  }

  static String _short(String s) => s.length > 40 ? '${s.substring(0, 40)}…' : s;
}
