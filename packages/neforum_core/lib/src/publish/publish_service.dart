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
import '../model/post_variant.dart';
import '../model/publish_result.dart';
import '../model/validation.dart';
import '../quota/quota_tracker.dart';
import '../storage/repositories.dart';
import '../storage/secret_store.dart';
import '../text/variant_resolver.dart';
import '../util/logger.dart';

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

/// Executes hand-off plans. The Flutter app implements this with share_plus,
/// url_launcher and the clipboard; the CLI prints the plan.
abstract class HandoffLauncher {
  Future<HandoffOutcome> launch(
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
    this.broker,
    this.handoffLauncher,
    this.resolver = const VariantResolver(),
    this.options = const PublishOptions(),
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
  final AuthBroker? broker;
  final HandoffLauncher? handoffLauncher;
  final VariantResolver resolver;
  final PublishOptions options;
  final Clock _now;
  final Logger _log;
  final Future<Uint8List> Function(MediaAttachment media)? _readMedia;

  AdapterContext context({void Function(String message)? onProgress, Logger? log}) => AdapterContext(
        http: http,
        broker: broker,
        mediaHost: mediaHostProvider?.call(),
        log: log ?? _log,
        clock: _now,
        onProgress: onProgress,
        readMedia: _readMedia,
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
      final variant = resolver.resolve(post, target, adapter.descriptor, account: account);
      final issues = [...variant.issues, ...adapter.validate(variant, account)];
      out.add(TargetPreview(target: target, account: account, descriptor: adapter.descriptor, variant: variant, issues: issues));
    }
    return out;
  }

  Future<HandoffPlan?> planHandoff(Post post, String accountId) async {
    final target = post.targetFor(accountId);
    final account = await accounts.get(accountId);
    if (target == null || account == null) return null;
    final adapter = registry.byId(account.platformId);
    if (adapter == null) return null;
    final variant = resolver.resolve(post, target, adapter.descriptor, account: account);
    return adapter.buildHandoff(variant, account: account);
  }

  // ---------------------------------------------------------------------
  // Publishing
  // ---------------------------------------------------------------------

  /// Publishes every pending target of [postId]. With [interactive] false
  /// (background run) hand-off targets are only marked as waiting.
  Future<Post> publish(
    String postId, {
    bool interactive = true,
    Set<String>? onlyAccountIds,
    bool retryFailed = true,
    void Function(String accountId, String message)? onProgress,
  }) async {
    var post = await _require(postId);
    post = post.copyWith(status: PostStatus.publishing, updatedAt: _now());
    await posts.upsert(post);
    _log.info('Publishing "${_short(post.text)}" to ${post.targets.length} target(s)');

    for (final target in post.targets) {
      if (onlyAccountIds != null && !onlyAccountIds.contains(target.accountId)) continue;
      if (target.isDone) continue;
      if (target.status == TargetStatus.failed && !retryFailed) continue;
      if (target.status == TargetStatus.awaitingHandoff && !interactive) continue;
      if (_inBackoff(target)) continue;
      final updated = await _publishTarget(
        post,
        target,
        interactive: interactive,
        onProgress: onProgress == null ? null : (m) => onProgress(target.accountId, m),
      );
      post = post.withTarget(updated);
      await posts.upsert(post); // persist progress target by target
    }
    post = _rollup(post).copyWith(updatedAt: _now());
    await posts.upsert(post);
    return post;
  }

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
    );
    post = _rollup(post.withTarget(updated)).copyWith(updatedAt: _now());
    await posts.upsert(post);
    return post;
  }

  Future<PostTarget> _publishTarget(
    Post post,
    PostTarget target, {
    required bool interactive,
    required void Function(String message)? onProgress,
    bool forceHandoff = false,
  }) async {
    final account = await accounts.get(target.accountId);
    if (account == null) {
      return _fail(target, const PublishError.configuration('This account was removed'));
    }
    if (!account.enabled) return target.copyWith(status: TargetStatus.skipped);
    final adapter = registry.byId(account.platformId);
    if (adapter == null) {
      return _fail(target, PublishError.unsupported('No adapter for platform "${account.platformId}"'));
    }
    final log = _log.child(account.platformId);
    final ctx = context(onProgress: onProgress, log: log);

    final variant = resolver.resolve(post, target, adapter.descriptor, account: account);
    final issues = [...variant.issues, ...adapter.validate(variant, account)];
    if (issues.hasErrors) {
      return _fail(target, PublishError.validation(issues.errors.map((i) => i.message).join('; ')));
    }

    final attempt = target.copyWith(
      attempts: target.attempts + 1,
      lastAttemptAt: _now(),
      status: TargetStatus.publishing,
    );

    if (account.tier == PlatformTier.handoff || forceHandoff) {
      return _handoff(post, attempt, variant, account, adapter, interactive: interactive);
    }

    // ---- API tiers ----------------------------------------------------
    var secretMap = await secrets.read(account.id) ?? const <String, String>{};
    try {
      final refreshed = await adapter.refreshSecrets(account, secretMap, ctx);
      if (refreshed != null) {
        await secrets.write(account.id, refreshed);
        secretMap = refreshed;
      }
    } on AdapterException catch (e) {
      return _fail(attempt, e.error, account: account);
    } on AuthCancelled {
      return _fail(attempt, const PublishError(kind: PublishErrorKind.cancelled, message: 'Sign-in cancelled'));
    } on HttpFailure catch (e) {
      // A 5xx/429 from the token endpoint is the platform having a bad
      // moment, not a revoked login.
      final err = e.statusCode >= 500 || e.statusCode == 429
          ? e.toPublishError(context: '${adapter.descriptor.name} sign-in renewal')
          : PublishError.auth('Could not renew the ${adapter.descriptor.name} sign-in (HTTP ${e.statusCode}); reconnect the account', raw: e.body, statusCode: e.statusCode);
      return _fail(attempt, err, account: account);
    } on Object catch (e) {
      if (NeforumHttp.isTransportError(e)) {
        return _fail(attempt, PublishError.network('Could not reach ${adapter.descriptor.name} to renew the sign-in: $e'));
      }
      return _fail(attempt, PublishError.auth('Could not refresh credentials: $e'), account: account);
    }

    final needed = variant.isThread ? variant.threadParts.length : 1;
    final exceeded = await quota.firstExceeded(account, adapter.descriptor, needed: needed);
    if (exceeded != null) {
      final err = PublishError.quota(
        '${adapter.descriptor.name} quota reached (${exceeded.used}/${exceeded.limit} ${exceeded.rule.note})',
        retryAfter: exceeded.resetsAt?.difference(_now()),
      );
      if (options.fallbackToHandoffOnQuota && adapter.buildHandoff(variant, account: account) != null) {
        log.warn('${account.displayName}: ${err.message}; falling back to hand-off');
        return _handoff(post, attempt, variant, account, adapter, interactive: interactive, reason: err.message);
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
    } on Object catch (e, st) {
      result = PublishResult.failure(_classifyUnexpected(e, adapter.descriptor.name));
      if (result.error!.kind == PublishErrorKind.platform) {
        log.error('Unexpected error publishing to ${account.displayName}', e);
        log.debug('$st');
      }
    }

    if (result.success) {
      await quota.record(account, adapter.descriptor, count: math.max(1, result.threadRemoteIds.length));
      if (account.lastError != null) await accounts.upsert(account.copyWith(clearLastError: true));
      log.info('Published to ${account.displayName}: ${result.remoteUrl ?? result.remoteId ?? 'ok'}');
      return attempt.copyWith(status: TargetStatus.published, result: result);
    }

    final err = result.error!;
    if (err.kind == PublishErrorKind.quota && options.fallbackToHandoffOnQuota && adapter.buildHandoff(variant, account: account) != null) {
      log.warn('${account.displayName}: ${err.message}; falling back to hand-off');
      return _handoff(post, attempt, variant, account, adapter, interactive: interactive, reason: err.message);
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
  }) async {
    var plan = adapter.buildHandoff(variant, account: account);
    if (plan == null) {
      return _fail(attempt, PublishError.unsupported('${adapter.descriptor.name} has no hand-off route'));
    }
    if (reason != null) plan = plan.copyWith(instructions: '$reason\n\n${plan.instructions}');
    final launcher = handoffLauncher;
    if (!interactive || launcher == null) {
      return attempt.copyWith(status: TargetStatus.awaitingHandoff);
    }
    final outcome = await launcher.launch(plan, post: post, target: attempt, variant: variant, account: account);
    return switch (outcome) {
      HandoffOutcome.launched => attempt.copyWith(
          status: TargetStatus.handedOff,
          result: PublishResult.handedOff(remoteUrl: plan.webIntent?.toString()),
        ),
      HandoffOutcome.deferred => attempt.copyWith(status: TargetStatus.awaitingHandoff),
      HandoffOutcome.unavailable => _fail(attempt, const PublishError.configuration('Hand-off is not available in this environment')),
    };
  }

  PostTarget _fail(PostTarget t, PublishError error, {ConnectedAccount? account}) {
    if (account != null && error.kind == PublishErrorKind.auth) {
      // Fire and forget; the account list shows the warning.
      unawaited(accounts.upsert(account.copyWith(lastError: error.message)));
    }
    final retry = error.retryable && t.attempts < options.maxAttempts && t.attempts > 0;
    _log.warn('${account?.displayName ?? t.accountId}: ${error.message}${retry ? ' (will retry)' : ''}');
    return t.copyWith(status: retry ? TargetStatus.pending : TargetStatus.failed, result: PublishResult.failure(error));
  }

  bool _inBackoff(PostTarget t) {
    if (t.status != TargetStatus.pending || t.attempts == 0 || t.lastAttemptAt == null) return false;
    final wait = options.retryBackoffBase * math.pow(2, t.attempts - 1).toInt();
    return _now().isBefore(t.lastAttemptAt!.add(wait));
  }

  Post _rollup(Post p) {
    if (p.targets.isEmpty) return p.copyWith(status: PostStatus.draft);
    final ts = p.targets;
    final anyRetrying = ts.any((t) => t.status == TargetStatus.pending || t.status == TargetStatus.publishing);
    final anyWaiting = ts.any((t) => t.status == TargetStatus.awaitingHandoff);
    final anyFailed = ts.any((t) => t.status == TargetStatus.failed);
    final allDone = ts.every((t) => t.isDone);
    if (allDone) return p.copyWith(status: PostStatus.published);
    if (anyRetrying) {
      // Keep it in the queue so the scheduler retries; immediate publishes
      // get "now" as their schedule so they are picked up too.
      return p.copyWith(status: PostStatus.scheduled, scheduledAt: p.scheduledAt ?? _now());
    }
    if (anyWaiting || (anyFailed && ts.any((t) => t.isDone))) return p.copyWith(status: PostStatus.partial);
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
