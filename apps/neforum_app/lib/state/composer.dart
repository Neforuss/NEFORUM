import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:uuid/uuid.dart';

import '../media/caption_style.dart';
import '../media/text_card.dart';
import '../media/text_card_background.dart';
import '../platform/notifications.dart';
import 'artwork_targets.dart';
import 'captioned_photos.dart';
import 'composer_draft.dart';
import 'fitted_photos.dart';
import 'providers.dart';
import 'scheduler.dart';
import 'settings.dart';
import 'text_cards.dart';

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
    this.textCardTheme,
    this.textCardFont,
    this.textCardBranded = const {},
    this.captionOnPhoto = const {},
    this.poll,
    this.differentiate = false,
    this.additionalParts = const [],
    this.artwork,
    this.textCardAlignment,
    this.textCardHandle = const {},
    this.captionStyle,
    this.textCardBackground,
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

  /// Style of the text card for image-only platforms; null = the default
  /// from Settings.
  final TextCardTheme? textCardTheme;

  /// Typeface of the card's words; null = the default from Settings.
  final TextCardFont? textCardFont;

  /// Per network (platform id): whether its text card carries the NEFORUM
  /// signature; missing = the Settings default.
  final Map<String, bool> textCardBranded;

  /// Per network (instagram, tiktok): whether the caption is written on the
  /// first photo; missing = the Settings default.
  final Map<String, bool> captionOnPhoto;

  /// Poll or quiz for networks that have them (YouTube Posts).
  final PostPoll? poll;

  /// DIFFERENTIATION: the composer shows one editable version per network.
  final bool differentiate;

  /// Thread parts after the first one ([text]), see [Post.additionalParts].
  final List<String> additionalParts;

  /// Set while the post is artwork for art portfolio sites.
  final ArtworkDetails? artwork;

  /// Alignment of the text card's words; null = the Settings default.
  final TextCardAlignment? textCardAlignment;

  /// Per network (platform id): whether its text card shows the account's
  /// @handle; missing = the Settings default.
  final Map<String, bool> textCardHandle;

  /// Style of the caption written on photos (CaptionStyle.toJson); null =
  /// the Settings default.
  final Map<String, dynamic>? captionStyle;

  /// A photo behind the text card's words, with its blur and dimming
  /// (TextCardBackground.toJson); null = a plain colour background.
  final Map<String, dynamic>? textCardBackground;

  bool get isArtwork => artwork != null;

  /// Every part with words in it ([text], then [additionalParts]) joined with
  /// blank lines: what networks without threads receive.
  String get joinedParts => [
        for (final p in [text, ...additionalParts])
          if (p.trim().isNotEmpty) p.trimRight(),
      ].join('\n\n');

  bool get isEmpty =>
      text.trim().isEmpty &&
      additionalParts.every((p) => p.trim().isEmpty) &&
      media.isEmpty &&
      (title ?? '').trim().isEmpty &&
      (link ?? '').trim().isEmpty;

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
    TextCardTheme? textCardTheme,
    TextCardFont? textCardFont,
    Map<String, bool>? textCardBranded,
    Map<String, bool>? captionOnPhoto,
    PostPoll? poll,
    bool? differentiate,
    List<String>? additionalParts,
    ArtworkDetails? artwork,
    TextCardAlignment? textCardAlignment,
    Map<String, bool>? textCardHandle,
    Map<String, dynamic>? captionStyle,
    Map<String, dynamic>? textCardBackground,
    bool clearPoll = false,
    bool clearSchedule = false,
    bool clearTitle = false,
    bool clearLink = false,
    bool clearCw = false,
    bool clearFocus = false,
    bool clearArtwork = false,
    bool clearTextCardBackground = false,
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
        textCardTheme: textCardTheme ?? this.textCardTheme,
        textCardFont: textCardFont ?? this.textCardFont,
        textCardBranded: textCardBranded ?? this.textCardBranded,
        captionOnPhoto: captionOnPhoto ?? this.captionOnPhoto,
        poll: clearPoll ? null : (poll ?? this.poll),
        differentiate: differentiate ?? this.differentiate,
        additionalParts: additionalParts ?? this.additionalParts,
        artwork: clearArtwork ? null : (artwork ?? this.artwork),
        textCardAlignment: textCardAlignment ?? this.textCardAlignment,
        textCardHandle: textCardHandle ?? this.textCardHandle,
        captionStyle: captionStyle ?? this.captionStyle,
        textCardBackground: clearTextCardBackground ? null : (textCardBackground ?? this.textCardBackground),
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
        poll: poll,
        additionalParts: [
          for (final p in additionalParts)
            if (p.trim().isNotEmpty) p,
        ],
        artwork: artwork,
        scheduledAt: scheduledAt,
        status: status,
        createdAt: createdAt ?? now,
        updatedAt: now,
        targets: [
          for (final id in selected) PostTarget(accountId: id, overrides: overrides[id] ?? const PostOverrides()),
        ],
      );
}

/// `PostOverrides.extra` key of a Discord target's "Mention @everyone"
/// choice (bool), read by the Discord adapter.
const String kMentionEveryoneKey = 'mentionEveryone';

/// [target] with the Settings value of "Mention @everyone" written into its
/// overrides when it is a Discord target without a choice of its own, so
/// scheduled and background runs post it the way it was saved.
PostTarget withMentionDefault(PostTarget target, String? platformId, AppSettings settings) {
  if (platformId != 'discord' || target.overrides.extra.containsKey(kMentionEveryoneKey)) return target;
  return target.copyWith(
    overrides: target.overrides.copyWith(extra: {...target.overrides.extra, kMentionEveryoneKey: settings.discordMentionEveryone}),
  );
}

/// [withMentionDefault] for every target of [post].
Post withMentionDefaults(Post post, List<ConnectedAccount> accounts, AppSettings settings) => post.copyWith(targets: [
      for (final t in post.targets) withMentionDefault(t, accounts.where((a) => a.id == t.accountId).firstOrNull?.platformId, settings),
    ]);

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

  /// Art sites are left out: they only receive artwork (artwork_targets.dart).
  Set<String> _defaultTargets(List<ConnectedAccount> accounts) =>
      defaultPostTargets(accounts, ref.read(registryProvider), ref.read(settingsProvider));

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
  void setTextCardTheme(TextCardTheme t) => state = state.copyWith(textCardTheme: t);
  void setTextCardFont(TextCardFont f) => state = state.copyWith(textCardFont: f);
  void setTextCardBranded(String platformId, bool branded) =>
      state = state.copyWith(textCardBranded: {...state.textCardBranded, platformId: branded});
  void setCaptionOnPhoto(String platformId, bool on) => state = state.copyWith(captionOnPhoto: {...state.captionOnPhoto, platformId: on});
  void setPoll(PostPoll? poll) => state = poll == null ? state.copyWith(clearPoll: true) : state.copyWith(poll: poll);
  void setDifferentiate(bool on) => state = state.copyWith(differentiate: on);
  void setTextCardAlignment(TextCardAlignment a) => state = state.copyWith(textCardAlignment: a);
  void setTextCardHandle(String platformId, bool show) => state = state.copyWith(textCardHandle: {...state.textCardHandle, platformId: show});
  void setCaptionStyle(Map<String, dynamic> style) => state = state.copyWith(captionStyle: style);
  void setTextCardBackground(Map<String, dynamic>? background) =>
      state = background == null ? state.copyWith(clearTextCardBackground: true) : state.copyWith(textCardBackground: background);

  /// Artwork mode on or off. On, the post goes to art sites only.
  void setArtwork(ArtworkDetails? artwork) =>
      state = artwork == null ? state.copyWith(clearArtwork: true) : state.copyWith(artwork: artwork);

  /// Text of thread part [index]: 0 is the first part ([ComposerState.text]).
  void setPart(int index, String text) {
    if (index == 0) {
      setText(text);
      return;
    }
    final parts = [...state.additionalParts];
    if (index - 1 >= parts.length) return;
    parts[index - 1] = text;
    state = state.copyWith(additionalParts: parts);
  }

  /// Adds an empty thread part after part [after] (default: at the end).
  /// Returns the new part's index.
  int addPart({int? after}) {
    final parts = [...state.additionalParts];
    final at = after == null ? parts.length : after.clamp(0, parts.length);
    parts.insert(at, '');
    state = state.copyWith(additionalParts: parts, revision: state.revision + 1);
    return at + 1;
  }

  /// Removes thread part [index] (1 or more; part 0 is cleared with
  /// [clearPost]).
  void removePart(int index) {
    if (index < 1 || index - 1 >= state.additionalParts.length) return;
    final parts = [...state.additionalParts]..removeAt(index - 1);
    state = state.copyWith(additionalParts: parts, revision: state.revision + 1);
  }

  /// Empties the post: every part, media, title, link, poll, content
  /// warning, tags and per-network versions. Keeps the targets, the schedule,
  /// artwork mode and which saved post is being edited.
  void clearPost() {
    state = ComposerState(
      editingPostId: state.editingPostId,
      visibility: ref.read(settingsProvider).defaultVisibility,
      selected: state.selected,
      scheduledAt: state.scheduledAt,
      artwork: state.artwork,
      revision: state.revision + 1,
    );
  }

  /// DIFFERENTIATION: [text] becomes this account's own version; null goes
  /// back to the main post.
  void setVersionText(String accountId, String? text) {
    final current = state.overrides[accountId] ?? const PostOverrides();
    final next = text == null ? current.copyWith(clearText: true) : current.copyWith(text: text);
    state = state.copyWith(overrides: next.isEmpty ? ({...state.overrides}..remove(accountId)) : {...state.overrides, accountId: next});
  }

  /// Sets several versions at once (null: back to the main post).
  void setVersionTexts(Map<String, String?> texts) {
    final overrides = {...state.overrides};
    for (final e in texts.entries) {
      final current = overrides[e.key] ?? const PostOverrides();
      final next = e.value == null ? current.copyWith(clearText: true) : current.copyWith(text: e.value);
      if (next.isEmpty) {
        overrides.remove(e.key);
      } else {
        overrides[e.key] = next;
      }
    }
    state = state.copyWith(overrides: overrides);
  }

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
  /// Generated text cards stay out of the editor; they are rebuilt on save.
  void load(Post post) {
    final p = withoutTextCards(post);
    final accounts = ref.read(accountListProvider);
    String? platformOf(String id) => accounts.where((a) => a.id == id).map((a) => a.platformId).firstOrNull;
    // A "Mention @everyone" value that matches Settings was written on save
    // (withMentionDefault); it is not a choice of this post.
    final mentionDefault = ref.read(settingsProvider).discordMentionEveryone;
    PostOverrides ownOverrides(PostTarget t) => platformOf(t.accountId) == 'discord' && t.overrides.extra[kMentionEveryoneKey] == mentionDefault
        ? t.overrides.copyWith(extra: {...t.overrides.extra}..remove(kMentionEveryoneKey))
        : t.overrides;
    state = ComposerState(
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
        overrides: {
          for (final t in p.targets)
            if (!ownOverrides(t).isEmpty) t.accountId: ownOverrides(t),
        },
        scheduledAt: p.scheduledAt,
        revision: state.revision + 1,
        textCardTheme: textCardThemeOfPost(post),
        textCardFont: textCardFontOfPost(post),
        textCardBranded: textCardBrandingOfPost(post, platformOf),
        captionOnPhoto: captionChoicesOfPost(post, platformOf),
        poll: p.poll,
        differentiate: p.targets.any((t) => t.overrides.text != null),
        additionalParts: p.additionalParts,
        artwork: p.artwork,
        textCardAlignment: textCardAlignmentOfPost(post),
        textCardHandle: textCardHandleOfPost(post, platformOf),
        captionStyle: captionStyleOfPost(post),
        textCardBackground: textCardBackgroundOfPost(post),
      );
  }

  /// Puts back a post that was being written when NEFORUM closed
  /// (composer_draft.dart).
  void restore(ComposerState kept) => state = kept.copyWith(revision: state.revision + 1);

  /// Starts over with the same targets. Kept art sites keep artwork mode on,
  /// with the artwork details back at their defaults.
  void reset({bool keepTargets = true}) {
    final fresh = build();
    state = fresh.copyWith(
      selected: keepTargets ? state.selected : fresh.selected,
      artwork: keepTargets && state.isArtwork ? newArtworkDetails(ref.read(settingsProvider)) : null,
      revision: state.revision + 1,
    );
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
      textCardTheme: state.textCardTheme,
      textCardFont: state.textCardFont,
      textCardBranded: state.textCardBranded,
      captionOnPhoto: state.captionOnPhoto,
      poll: state.poll,
      differentiate: state.differentiate,
      additionalParts: state.additionalParts,
      artwork: state.artwork,
      textCardAlignment: state.textCardAlignment,
      textCardHandle: state.textCardHandle,
      captionStyle: state.captionStyle,
      textCardBackground: state.textCardBackground,
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
  final background = TextCardBackground.tryParse(c.textCardBackground);
  // One of the post's photos as the cards' background: the card takes its
  // place on image-only networks.
  final backgroundPhotoId = background != null && c.media.any((m) => m.id == background.photo.id) ? background.photo.id : null;
  final captionStyle = captionStyleFor(c.captionStyle, settings);
  final out = <TargetPreview>[];
  for (final a in accounts) {
    if (!c.selected.contains(a.id)) continue;
    final adapter = registry.byId(a.platformId);
    if (adapter == null) continue;
    final target = post.targetFor(a.id)!;
    final d = adapter.descriptorForAccount(a);
    var variant = resolver.resolve(post, withMentionDefault(target, a.platformId, settings), d, account: a);
    final issues = <ValidationIssue>[...variant.issues];
    // Image-only platforms get the words as a NEFORUM text card, rendered
    // when the post is saved; preview and check a stand-in for it.
    if (settings.textCards && qualifiesForTextCard(d, variant, backgroundMediaId: backgroundPhotoId)) {
      final signed = c.textCardBranded[d.id] ?? settings.textCardBranded(d.id);
      variant = variant.copyWith(media: [
        textCardPlaceholder(
          d.id,
          c.textCardTheme ?? settings.textCardTheme,
          branded: signed,
          font: c.textCardFont ?? settings.textCardFont,
          alignment: c.textCardAlignment ?? settings.textCardAlignment,
          showsHandle: c.textCardHandle[d.id] ?? settings.textCardShowsHandle(d.id),
          background: background,
        ),
      ]);
      issues.add(ValidationIssue.info(
          'media.text_card',
          '${d.name} needs an image, so your words go out as ${signed ? 'a NEFORUM' : 'a plain'} text card${background == null ? '' : ' over your photo'}',
          field: 'media'));
    }
    // Photos this network does not take as they are get a fitted copy on
    // save; check what that copy will be.
    final fit = settings.photoFit == PhotoFitMode.off ? null : effectivePhotoFit(adapter, a, variant, settings);
    if (fit != null) {
      final fitted = [
        for (final m in variant.media)
          if (!m.generated && fit.problemsOf(m).isNotEmpty) m,
      ];
      if (fitted.isNotEmpty) {
        variant = variant.copyWith(media: [for (final m in variant.media) fitted.contains(m) ? fit.standIn(m, settings.photoFit) : m]);
        for (final m in fitted) {
          issues.add(ValidationIssue.info('media.photo_fit', '${m.fileName ?? 'A photo'} will be ${fit.describe(m, settings.photoFit)} for ${d.name}', field: 'media'));
        }
      }
    }
    final firstMedia = variant.media.firstOrNull;
    if (captionOnPhotoFor(d.id, settings, c.captionOnPhoto) && firstMedia != null && firstMedia.kind == MediaKind.image && !firstMedia.isTextCard) {
      issues.add(ValidationIssue.info(
          'media.caption_photo',
          captionStyle.placement == CaptionPlacement.blockAbove
              ? 'Your caption is set in a block above the first photo for ${d.name}'
              : 'Your caption is written on the first photo for ${d.name}',
          field: 'media'));
    }
    try {
      issues.addAll(adapter.validate(variant, a));
    } on Object catch (e) {
      issues.add(ValidationIssue.warning('validate.crash', 'Could not validate: $e'));
    }
    // Media host requirement is a configuration problem, not a text one.
    final services = ref.read(servicesProvider);
    if (!services.demo && d.media.requiresPublicMediaUrl && a.tier != PlatformTier.handoff && variant.hasMedia && services.mediaHost == null) {
      issues.add(ValidationIssue.error('media.host_missing', '${d.name} needs a public media host (Settings → Media hosting)', field: 'media'));
    }
    // An empty composer is not a problem worth shouting about on every card.
    if (c.isEmpty) issues.removeWhere((i) => i.code == 'post.empty' || i.code.endsWith('.empty') || i.code.contains('required') && i.field != 'account');
    out.add(TargetPreview(target: target, account: a, descriptor: d, variant: variant, issues: _dedupe(issues)));
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

/// A platform still holds a copy of a scheduled post that NEFORUM could not
/// take back (offline, expired sign-in). The copy will still go out there.
class HeldCopiesException implements Exception {
  const HeldCopiesException({required this.platforms, required this.reason});

  /// Display names of the platforms that still hold a copy.
  final List<String> platforms;
  final String reason;

  String get message =>
      '${platforms.join(', ')} still ${platforms.length == 1 ? 'holds' : 'hold'} a scheduled copy that NEFORUM could not remove ($reason). '
      'Try again when you are online, or delete it on ${platforms.length == 1 ? 'that site' : 'those sites'}.';

  @override
  String toString() => message;
}

/// Publishing, scheduling and draft actions shared by composer and lists.
class PostActions {
  PostActions(this.ref);
  final Ref ref;

  /// Server-side scheduling runs in the background after a post is
  /// scheduled; anything that changes the post waits for it first so the
  /// two never overwrite each other.
  final Map<String, Future<void>> _delegations = {};

  Future<Post> _save(PostStatus status) async {
    final s = ref.read(servicesProvider);
    final c = ref.read(composerProvider);
    final now = DateTime.now();
    final existing = c.editingPostId == null ? null : await s.posts.get(c.editingPostId!);
    if (existing != null) await _releaseHeld(existing.id);
    var post = c.toPost(id: c.editingPostId ?? _uuid.v7(), status: status, now: now, createdAt: existing?.createdAt);
    post = withMentionDefaults(post, ref.read(accountListProvider), ref.read(settingsProvider));
    // Hand the old cards and fitted photos over so unchanged ones are reused,
    // stale ones deleted.
    post = post.copyWith(media: [...post.media, ...?existing?.media.where((m) => m.generated)]);
    post = await attachTextCards(s, post, ref.read(settingsProvider),
        theme: c.textCardTheme,
        font: c.textCardFont,
        branded: c.textCardBranded,
        alignment: c.textCardAlignment,
        handle: c.textCardHandle,
        background: c.textCardBackground ?? const {});
    post = await attachFittedPhotos(s, post, ref.read(settingsProvider));
    post = await attachCaptionedPhotos(s, post, ref.read(settingsProvider), choices: c.captionOnPhoto, style: c.captionStyle);
    await s.posts.upsert(post);
    return post;
  }

  /// Takes back every copy a platform holds for [postId]. Throws
  /// [HeldCopiesException] when one could not be removed.
  Future<void> _releaseHeld(String postId, {Set<String>? onlyAccountIds}) async {
    await _delegations[postId];
    final s = ref.read(servicesProvider);
    final p = await s.posts.get(postId);
    if (p == null || !p.hasHeldTargets) return;
    final outcome = await s.publisher().releaseSchedules(postId, onlyAccountIds: onlyAccountIds);
    if (outcome.ok) return;
    final names = <String>[];
    for (final id in outcome.failed.keys) {
      final a = await s.accounts.get(id);
      names.add(a == null ? 'A removed account' : (s.registry.descriptor(a.platformId)?.name ?? a.displayName));
    }
    throw HeldCopiesException(platforms: names, reason: outcome.failed.values.first.message);
  }

  /// Lets the platforms that can hold [p] do so, in the background.
  void _delegate(Post p) {
    final settings = ref.read(settingsProvider);
    if (!settings.delegateSchedules || p.status != PostStatus.scheduled) return;
    final s = ref.read(servicesProvider);
    final job = () async {
      try {
        final updated = await s.publisher().delegateSchedules(p.id);
        await ref.read(schedulerProvider).planReminders(updated);
      } on Object catch (e) {
        debugPrint('Server-side scheduling failed: $e');
      }
    }();
    _delegations[p.id] = job;
    unawaited(job.whenComplete(() {
      if (identical(_delegations[p.id], job)) _delegations.remove(p.id);
    }));
  }

  /// Waits for background scheduling hand-offs (tests, shutdown).
  Future<void> settle() => Future.wait(_delegations.values.toList());

  Future<Post> saveDraft() async {
    final p = await _save(PostStatus.draft);
    await ref.read(schedulerProvider).cancelReminders(p);
    return p;
  }

  /// Schedules the composer's post at its [ComposerState.scheduledAt].
  Future<Post> schedule() async {
    final p = await _save(PostStatus.scheduled);
    await ref.read(schedulerProvider).planReminders(p);
    _delegate(p);
    return p;
  }

  /// Publishes the composer's post right now. As soon as the post is saved
  /// for publishing, the composer starts over and its draft file is written
  /// empty: the progress sheet follows the run, and Activity has the post
  /// (for a retry) until the retention setting deletes it. A failure before
  /// that leaves the composer as it was. Returns the final post.
  Future<Post> publishNow() async {
    final run = ref.read(publishRunProvider.notifier);
    run.prepare();
    final c = ref.read(composerProvider);
    final Post p;
    try {
      p = (await _save(PostStatus.publishing)).copyWith(clearScheduledAt: true);
      await ref.read(servicesProvider).posts.upsert(p);
    } on Object catch (e) {
      run.fail(null, e);
      rethrow;
    }
    ref.read(composerProvider.notifier).reset();
    await ref.read(composerDraftKeeperProvider)?.keep(ref.read(composerProvider));
    return publishExisting(p.id, accountIds: c.selected);
  }

  /// Runs (or re-runs) publishing for an existing post. Copies held by
  /// platforms are taken back first, so nothing goes out twice. The run can
  /// be cancelled from its progress sheet or from Activity; whatever stops
  /// it is shown in the sheet.
  Future<Post> publishExisting(String postId, {Set<String>? accountIds, bool retryFailed = true}) async {
    final run = ref.read(publishRunProvider.notifier);
    if (!(ref.read(publishRunProvider)?.preparing ?? false)) run.prepare();
    final signal = ref.read(publishRunProvider)!.cancellation;
    final active = ref.read(activePublishingProvider.notifier)..begin(postId, signal);
    try {
      return await _publishExisting(postId, signal, accountIds: accountIds, retryFailed: retryFailed);
    } on Object catch (e) {
      run.fail(postId, e);
      rethrow;
    } finally {
      active.end(postId, signal);
    }
  }

  Future<Post> _publishExisting(String postId, CancellationSignal signal, {Set<String>? accountIds, required bool retryFailed}) async {
    final s = ref.read(servicesProvider);
    await _releaseHeld(postId, onlyAccountIds: accountIds);
    var post = await s.posts.get(postId);
    if (post == null) throw StateError('Post $postId not found');
    // Posts saved before text cards existed, or drafts published from a
    // list, get their cards here; every choice is read back from the post.
    post = await attachTextCards(s, post, ref.read(settingsProvider));
    final choices = await captionChoicesOfSavedPost(s, post);
    post = await attachFittedPhotos(s, post, ref.read(settingsProvider));
    post = await attachCaptionedPhotos(s, post, ref.read(settingsProvider), choices: choices);
    await s.posts.upsert(post);
    final run = ref.read(publishRunProvider.notifier);
    run.start(postId, accountIds ?? post.targets.map((t) => t.accountId));
    final done = await s.publisher().publish(
          postId,
          interactive: true,
          onlyAccountIds: accountIds,
          retryFailed: retryFailed,
          onProgress: run.progress,
          cancellation: signal,
        );
    final finalPost = await s.applySkips(postId) ?? done;
    run.finish(finalPost);
    try {
      await ref.read(schedulerProvider).cancelReminders(finalPost);
      await _notifyResult(finalPost);
      await _discardIfComplete(postId);
    } on Object catch (e) {
      // The post went out; tidying up afterwards must not look like a failure.
      debugPrint('After publishing $postId: $e');
    }
    return finalPost;
  }

  /// Asks the run publishing [postId] in this process to stop.
  void cancelPublishing(String postId) {
    ref.read(activePublishingProvider.notifier).cancel(postId);
    if (ref.read(publishRunProvider)?.postId == postId) ref.read(publishRunProvider.notifier).cancel();
  }

  /// What the composer mentions, so deleting a post never takes a file the
  /// composer still shows (a duplicated post shares its photos).
  List<Object?> _composerReferences() {
    final c = ref.read(composerProvider);
    return [c.toPost(id: 'composer', status: PostStatus.draft, now: DateTime.now()).toJson(), c.captionStyle, c.textCardBackground];
  }

  /// Deletes [postId] once every network has it, when the setting keeps
  /// nothing after posting.
  Future<void> _discardIfComplete(String postId) async {
    if (await ref.read(servicesProvider).discardIfComplete(postId, inUse: _composerReferences())) {
      ref.read(schedulerProvider).updateTrayStatus();
    }
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
  /// The last hand-off of a post can complete it (see [_discardIfComplete]).
  Future<Post> runHandoff(String postId, String accountId) async {
    final s = ref.read(servicesProvider);
    final p = await s.publisher().runHandoff(postId, accountId);
    final done = await s.applySkips(postId) ?? p;
    await _discardIfComplete(postId);
    return done;
  }

  Future<Post> markHandedOff(String postId, String accountId, {bool done = true}) async {
    final p = await ref.read(servicesProvider).publisher().confirmHandoff(postId, accountId, completed: done);
    if (done) await _discardIfComplete(postId);
    return p;
  }

  /// Deletes [p] from NEFORUM, with its notifications and the media files
  /// nothing else uses. Copies held by platforms are removed first; when
  /// that fails a [HeldCopiesException] is thrown unless [force].
  Future<void> delete(Post p, {bool force = false}) async {
    final s = ref.read(servicesProvider);
    try {
      await _releaseHeld(p.id);
    } on HeldCopiesException {
      if (!force) rethrow;
    }
    await ref.read(schedulerProvider).cancelReminders(p);
    // The stored post: it may have more generated media than the list's copy.
    final current = await s.posts.get(p.id) ?? p;
    await s.discardPosts([current], inUse: _composerReferences());
  }

  /// Activity > Clear failed. Posts that reached no network (every target
  /// failed or cancelled) are deleted. Posts that reached some keep those;
  /// their failed and cancelled targets become skipped, and the retention
  /// setting then applies to them like to any finished post. Posts this
  /// process is publishing are left alone.
  Future<({int deleted, int kept})> clearFailed(Iterable<Post> listed) async {
    final s = ref.read(servicesProvider);
    final active = ref.read(activePublishingProvider);
    final publisher = s.publisher();
    final doomed = <Post>[];
    var kept = 0;
    for (final l in listed) {
      if (active.containsKey(l.id)) continue;
      final p = await s.posts.get(l.id);
      if (p == null || !p.targets.any(needsRetry)) continue;
      if (p.targets.every(needsRetry)) {
        doomed.add(p);
        continue;
      }
      var next = p;
      for (final t in p.targets.where(needsRetry)) {
        next = next.withTarget(t.copyWith(status: TargetStatus.skipped));
      }
      await s.posts.upsert(publisher.rollUpStatus(next).copyWith(updatedAt: DateTime.now()));
      kept++;
    }
    await s.discardPosts(doomed, inUse: _composerReferences());
    if (kept > 0) await s.applyRetention(inUse: _composerReferences());
    ref.read(schedulerProvider).updateTrayStatus();
    return (deleted: doomed.length, kept: kept);
  }

  Future<Post> unschedule(Post p) async {
    final s = ref.read(servicesProvider);
    await _releaseHeld(p.id);
    final current = await s.posts.get(p.id) ?? p;
    final draft = current.copyWith(status: PostStatus.draft, clearScheduledAt: true, updatedAt: DateTime.now());
    await s.posts.upsert(draft);
    await ref.read(schedulerProvider).cancelReminders(p);
    return draft;
  }

  Future<Post> reschedule(Post p, DateTime when) async {
    final s = ref.read(servicesProvider);
    await _releaseHeld(p.id);
    final current = await s.posts.get(p.id) ?? p;
    final next = current.copyWith(status: PostStatus.scheduled, scheduledAt: when, updatedAt: DateTime.now());
    await s.posts.upsert(next);
    await ref.read(schedulerProvider).planReminders(next);
    _delegate(next);
    return next;
  }

  static String _short(String s) => s.length > 80 ? '${s.substring(0, 80)}…' : s;
}
final postActionsProvider = Provider<PostActions>(PostActions.new);
