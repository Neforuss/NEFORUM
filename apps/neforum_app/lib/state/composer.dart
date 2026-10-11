import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:uuid/uuid.dart';

import '../platform/notifications.dart';
import 'providers.dart';
import 'scheduler.dart';

const _uuid = Uuid();

/// Everything the composer screen is editing.
@immutable
class ComposerState {
  const ComposerState({
    this.editingPostId,
    this.text = '',
    this.title,
    this.link,
    this.media = const [],
    this.contentWarning,
    this.sensitive = false,
    this.visibility = PostVisibility.public,
    this.tags = const [],
    this.selected = const {},
    this.overrides = const {},
    this.scheduledAt,
    this.focusedAccountId,
    this.revision = 0,
  });

  /// Set when editing an existing draft or scheduled post.
  final String? editingPostId;
  final String text;
  final String? title;
  final String? link;
  final List<MediaAttachment> media;
  final String? contentWarning;
  final bool sensitive;
  final PostVisibility visibility;
  final List<String> tags;

  /// Account ids the post goes to.
  final Set<String> selected;

  /// Per-account customisations.
  final Map<String, PostOverrides> overrides;
  final DateTime? scheduledAt;

  /// The preview tab the user is looking at (narrow layouts).
  final String? focusedAccountId;

  /// Increments when the whole state is replaced (load/reset) so text fields
  /// know to resync their controllers.
  final int revision;

  bool get isEmpty => text.trim().isEmpty && media.isEmpty && (title ?? '').trim().isEmpty && (link ?? '').trim().isEmpty;

  ComposerState copyWith({
    String? editingPostId,
    String? text,
    String? title,
    String? link,
    List<MediaAttachment>? media,
    String? contentWarning,
    bool? sensitive,
    PostVisibility? visibility,
    List<String>? tags,
    Set<String>? selected,
    Map<String, PostOverrides>? overrides,
    DateTime? scheduledAt,
    String? focusedAccountId,
    int? revision,
    bool clearSchedule = false,
    bool clearTitle = false,
    bool clearLink = false,
    bool clearCw = false,
    bool clearFocus = false,
  }) =>
      ComposerState(
        editingPostId: editingPostId ?? this.editingPostId,
        text: text ?? this.text,
        title: clearTitle ? null : (title ?? this.title),
        link: clearLink ? null : (link ?? this.link),
        media: media ?? this.media,
        contentWarning: clearCw ? null : (contentWarning ?? this.contentWarning),
        sensitive: sensitive ?? this.sensitive,
        visibility: visibility ?? this.visibility,
        tags: tags ?? this.tags,
        selected: selected ?? this.selected,
        overrides: overrides ?? this.overrides,
        scheduledAt: clearSchedule ? null : (scheduledAt ?? this.scheduledAt),
        focusedAccountId: clearFocus ? null : (focusedAccountId ?? this.focusedAccountId),
        revision: revision ?? this.revision,
      );

  /// Builds the master [Post] for this composer state.
  Post toPost({required String id, required PostStatus status, required DateTime now, DateTime? createdAt}) => Post(
        id: id,
        text: text,
        title: (title ?? '').trim().isEmpty ? null : title!.trim(),
        link: (link ?? '').trim().isEmpty ? null : link!.trim(),
        media: media,
        contentWarning: (contentWarning ?? '').trim().isEmpty ? null : contentWarning,
        sensitive: sensitive,
        visibility: visibility,
        tags: tags,
        scheduledAt: scheduledAt,
        status: status,
        createdAt: createdAt ?? now,
        updatedAt: now,
        targets: [
          for (final id in selected) PostTarget(accountId: id, overrides: overrides[id] ?? const PostOverrides()),
        ],
      );
}

class ComposerNotifier extends Notifier<ComposerState> {
  @override
  ComposerState build() {
    // Accounts load asynchronously; pick the default targets once they
    // arrive, unless the user already started choosing.
    ref.listen(accountListProvider, (prev, next) {
      if ((prev == null || prev.isEmpty) && next.isNotEmpty && state.selected.isEmpty && state.isEmpty) {
        state = state.copyWith(selected: _defaultTargets(next));
      }
    });
    final settings = ref.read(settingsProvider);
    return ComposerState(
      visibility: settings.defaultVisibility,
      selected: _defaultTargets(ref.read(accountListProvider)),
    );
  }

  Set<String> _defaultTargets(List<ConnectedAccount> accounts) {
    final ids = accounts.map((a) => a.id).toSet();
    final defaults = ref.read(settingsProvider).defaultTargetIds.where(ids.contains).toSet();
    return defaults.isNotEmpty ? defaults : accounts.where((a) => a.enabled).map((a) => a.id).toSet();
  }

  void setText(String v) => state = state.copyWith(text: v);

  /// Replaces the text programmatically (editor fields resync).
  void prefill(String text) => state = state.copyWith(text: text, revision: state.revision + 1);
  void setTitle(String v) => state = v.isEmpty ? state.copyWith(clearTitle: true) : state.copyWith(title: v);
  void setLink(String v) => state = v.isEmpty ? state.copyWith(clearLink: true) : state.copyWith(link: v);
  void setContentWarning(String? v) =>
      state = (v == null || v.isEmpty) ? state.copyWith(clearCw: true) : state.copyWith(contentWarning: v);
  void setSensitive(bool v) => state = state.copyWith(sensitive: v);
  void setVisibility(PostVisibility v) => state = state.copyWith(visibility: v);
  void setTags(List<String> v) => state = state.copyWith(tags: v);
  void setSchedule(DateTime? when) => state = when == null ? state.copyWith(clearSchedule: true) : state.copyWith(scheduledAt: when);
  void focus(String? accountId) => state = accountId == null ? state.copyWith(clearFocus: true) : state.copyWith(focusedAccountId: accountId);

  void addMedia(Iterable<MediaAttachment> items) => state = state.copyWith(media: [...state.media, ...items]);

  void removeMedia(String mediaId) {
    state = state.copyWith(
      media: state.media.where((m) => m.id != mediaId).toList(),
      overrides: {
        for (final e in state.overrides.entries)
          e.key: e.value.mediaIds == null ? e.value : e.value.copyWith(mediaIds: e.value.mediaIds!.where((x) => x != mediaId).toList()),
      },
    );
  }

  /// Moves an attachment; [to] is the final index (already adjusted for the
  /// removed item, as ReorderableListView.onReorderItem reports it).
  void moveMedia(int from, int to) {
    final list = [...state.media];
    final item = list.removeAt(from);
    list.insert(to.clamp(0, list.length), item);
    state = state.copyWith(media: list);
  }

  void setAltText(String mediaId, String alt) => state = state.copyWith(
        media: [for (final m in state.media) m.id == mediaId ? m.copyWith(altText: alt, clearAltText: alt.isEmpty) : m],
      );

  void toggleAccount(String accountId) {
    final s = {...state.selected};
    if (!s.remove(accountId)) s.add(accountId);
    state = state.copyWith(selected: s);
  }

  void selectAccounts(Iterable<String> ids) => state = state.copyWith(selected: ids.toSet());

  void setOverride(String accountId, PostOverrides o) =>
      state = state.copyWith(overrides: {...state.overrides, accountId: o});

  void clearOverride(String accountId) => state = state.copyWith(overrides: {...state.overrides}..remove(accountId));

  /// Loads an existing post into the composer (edit draft / reschedule).
  void load(Post p) => state = ComposerState(
        editingPostId: p.id,
        text: p.text,
        title: p.title,
        link: p.link,
        media: p.media,
        contentWarning: p.contentWarning,
        sensitive: p.sensitive,
        visibility: p.visibility,
        tags: p.tags,
        selected: p.targets.map((t) => t.accountId).toSet(),
        overrides: {for (final t in p.targets) if (!t.overrides.isEmpty) t.accountId: t.overrides},
        scheduledAt: p.scheduledAt,
        revision: state.revision + 1,
      );

  /// Starts over with the same targets.
  void reset({bool keepTargets = true}) {
    final fresh = build();
    state = fresh.copyWith(selected: keepTargets ? state.selected : fresh.selected, revision: state.revision + 1);
  }

  /// Duplicates [p] as a fresh draft.
  void duplicate(Post p) {
    load(p);
    state = ComposerState(
      text: state.text,
      title: state.title,
      link: state.link,
      media: state.media,
      contentWarning: state.contentWarning,
      sensitive: state.sensitive,
      visibility: state.visibility,
      tags: state.tags,
      selected: state.selected,
      overrides: state.overrides,
      revision: state.revision + 1,
    );
  }
}

final composerProvider = NotifierProvider<ComposerNotifier, ComposerState>(ComposerNotifier.new);

/// Live per-target previews of what each platform will receive.
final composerPreviewsProvider = Provider<List<TargetPreview>>((ref) {
  final c = ref.watch(composerProvider);
  final accounts = ref.watch(accountListProvider);
  final registry = ref.watch(registryProvider);
  final settings = ref.watch(settingsProvider);
  final resolver = VariantResolver(settings.resolverOptions);
  final now = DateTime.now();
  final post = c.toPost(id: 'preview', status: PostStatus.draft, now: now);
  final out = <TargetPreview>[];
  for (final a in accounts) {
    if (!c.selected.contains(a.id)) continue;
    final adapter = registry.byId(a.platformId);
    if (adapter == null) continue;
    final target = post.targetFor(a.id)!;
    final variant = resolver.resolve(post, target, adapter.descriptor, account: a);
    final issues = <ValidationIssue>[...variant.issues];
    try {
      issues.addAll(adapter.validate(variant, a));
    } on Object catch (e) {
      issues.add(ValidationIssue.warning('validate.crash', 'Could not validate: $e'));
    }
    // Media host requirement is a configuration problem, not a text one.
    final services = ref.read(servicesProvider);
    if (!services.demo && adapter.descriptor.media.requiresPublicMediaUrl && a.tier != PlatformTier.handoff && variant.hasMedia && services.mediaHost == null) {
      issues.add(ValidationIssue.error('media.host_missing', '${adapter.descriptor.name} needs a public media host (Settings → Media hosting)', field: 'media'));
    }
    // An empty composer is not a problem worth shouting about on every card.
    if (c.isEmpty) issues.removeWhere((i) => i.code == 'post.empty' || i.code.endsWith('.empty') || i.code.contains('required') && i.field != 'account');
    out.add(TargetPreview(target: target, account: a, descriptor: adapter.descriptor, variant: variant, issues: _dedupe(issues)));
  }
  return out;
});

List<ValidationIssue> _dedupe(List<ValidationIssue> issues) {
  final seen = <String>{};
  return [for (final i in issues) if (seen.add('${i.code}|${i.message}')) i];
}

/// Summary used by the composer's action bar.
@immutable
class ComposerReadiness {
  const ComposerReadiness({required this.ready, required this.blocked, required this.handoff, required this.warnings});
  final int ready;
  final int blocked;
  final int handoff;
  final int warnings;
  bool get canPublish => ready + handoff > 0 && blocked == 0;
}

final composerReadinessProvider = Provider<ComposerReadiness>((ref) {
  final previews = ref.watch(composerPreviewsProvider);
  var ready = 0, blocked = 0, handoff = 0, warnings = 0;
  for (final p in previews) {
    if (!p.canPublish) {
      blocked++;
    } else if (p.account.tier == PlatformTier.handoff) {
      handoff++;
    } else {
      ready++;
    }
    if (p.issues.warnings.isNotEmpty) warnings++;
  }
  return ComposerReadiness(ready: ready, blocked: blocked, handoff: handoff, warnings: warnings);
});

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

/// Publishing, scheduling and draft actions shared by composer and lists.
class PostActions {
  PostActions(this.ref);
  final Ref ref;

  Future<Post> _save(PostStatus status) async {
    final s = ref.read(servicesProvider);
    final c = ref.read(composerProvider);
    final now = DateTime.now();
    final existing = c.editingPostId == null ? null : await s.posts.get(c.editingPostId!);
    final post = c.toPost(id: c.editingPostId ?? _uuid.v7(), status: status, now: now, createdAt: existing?.createdAt);
    await s.posts.upsert(post);
    return post;
  }

  Future<Post> saveDraft() async {
    final p = await _save(PostStatus.draft);
    await ref.read(schedulerProvider).cancelReminders(p);
    return p;
  }

  /// Schedules the composer's post at its [ComposerState.scheduledAt].
  Future<Post> schedule() async {
    final p = await _save(PostStatus.scheduled);
    await ref.read(schedulerProvider).planReminders(p);
    return p;
  }

  /// Publishes the composer's post right now. Returns the final post.
  Future<Post> publishNow() async {
    final c = ref.read(composerProvider);
    final p = (await _save(PostStatus.publishing)).copyWith(clearScheduledAt: true);
    await ref.read(servicesProvider).posts.upsert(p);
    return publishExisting(p.id, accountIds: c.selected);
  }

  /// Runs (or re-runs) publishing for an existing post.
  Future<Post> publishExisting(String postId, {Set<String>? accountIds, bool retryFailed = true}) async {
    final s = ref.read(servicesProvider);
    final run = ref.read(publishRunProvider.notifier);
    final post = await s.posts.get(postId);
    if (post == null) throw StateError('Post $postId not found');
    run.start(postId, accountIds ?? post.targets.map((t) => t.accountId));
    final done = await s.publisher().publish(
          postId,
          interactive: true,
          onlyAccountIds: accountIds,
          retryFailed: retryFailed,
          onProgress: run.progress,
        );
    final finalPost = await s.applySkips(postId) ?? done;
    run.finish(finalPost);
    await ref.read(schedulerProvider).cancelReminders(finalPost);
    await _notifyResult(finalPost);
    return finalPost;
  }

  Future<void> _notifyResult(Post p) async {
    final settings = ref.read(settingsProvider);
    if (!settings.notifyOnPublish) return;
    final ok = p.targets.where((t) => t.status == TargetStatus.published || t.status == TargetStatus.handedOff).length;
    final failed = p.targets.where((t) => t.status == TargetStatus.failed).length;
    final waiting = p.targets.where((t) => t.status == TargetStatus.awaitingHandoff).length;
    if (failed == 0 && waiting == 0) return; // the in-app result sheet is enough
    await NotificationService.instance.show(
      key: 'result:${p.id}',
      title: failed > 0 ? 'Posted to $ok, $failed failed' : 'Posted to $ok · $waiting waiting for you',
      body: _short(p.text),
      payload: 'post:${p.id}',
    );
  }

  /// Hand-off for one target, triggered from a list or a notification.
  Future<Post> runHandoff(String postId, String accountId) async {
    final s = ref.read(servicesProvider);
    final p = await s.publisher().runHandoff(postId, accountId);
    return await s.applySkips(postId) ?? p;
  }

  Future<Post> markHandedOff(String postId, String accountId, {bool done = true}) =>
      ref.read(servicesProvider).publisher().confirmHandoff(postId, accountId, completed: done);

  Future<void> delete(Post p) async {
    final s = ref.read(servicesProvider);
    await ref.read(schedulerProvider).cancelReminders(p);
    await s.posts.delete(p.id);
    // Drop media files no other post uses.
    final others = await s.posts.all();
    final inUse = {for (final o in others) ...o.media.map((m) => m.path)};
    for (final m in p.media) {
      if (!inUse.contains(m.path)) await s.media.discard(m);
    }
  }

  Future<Post> unschedule(Post p) async {
    final s = ref.read(servicesProvider);
    final draft = p.copyWith(status: PostStatus.draft, clearScheduledAt: true, updatedAt: DateTime.now());
    await s.posts.upsert(draft);
    await ref.read(schedulerProvider).cancelReminders(p);
    return draft;
  }

  Future<Post> reschedule(Post p, DateTime when) async {
    final s = ref.read(servicesProvider);
    final next = p.copyWith(status: PostStatus.scheduled, scheduledAt: when, updatedAt: DateTime.now());
    await s.posts.upsert(next);
    await ref.read(schedulerProvider).planReminders(next);
    return next;
  }

  static String _short(String s) => s.length > 80 ? '${s.substring(0, 80)}…' : s;
}

final postActionsProvider = Provider<PostActions>(PostActions.new);
