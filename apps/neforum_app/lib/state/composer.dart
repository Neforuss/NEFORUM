import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:uuid/uuid.dart';

import '../media/audio_plan.dart';
import '../media/caption_fonts.dart' show CaptionFont, captionFontReadyProvider;
import '../media/card_design.dart';
import '../media/caption_style.dart';
import '../media/text_card.dart';
import '../media/text_card_background.dart';
import '../platform/notifications.dart';
import 'artwork_targets.dart';
import 'audio_renditions.dart';
import 'card_designs.dart';
import 'captioned_photos.dart';
import 'composer_draft.dart';
import 'fitted_photos.dart';
import 'providers.dart';
import 'scheduler.dart';
import 'settings.dart';
import 'shrunk_videos.dart';
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
    this.audioQuality = AudioQuality.standard,
    this.textCardEveryNetwork,
    this.textCardWithText = const {},
    this.mediaParts = const {},
    this.textCardCustomFont, // 1.3.1: cards
    this.textCardDesign, // 1.3.1: cards
    this.audioCardDesign, // 1.3.1: cards
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

  /// Increments when the main fields are replaced (load, reset, clear post,
  /// restore, prefill) so text fields know to resync their controllers. Adding or
  /// removing a thread part leaves it alone: the part editors follow the
  /// number of parts, and the main editor keeps its cursor and open fields.
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

  /// How the post's sound file goes out ([Post.audioQuality]).
  final AudioQuality audioQuality;
  /// A text-only post gets the same text card on every network that takes
  /// images, not only where one is needed; null = the Settings default.
  final bool? textCardEveryNetwork;

  /// Per network (platform id): whether the post's text goes along with its
  /// text card; missing = it does.
  final Map<String, bool> textCardWithText;

  /// [textCardEveryNetwork], or the Settings default.
  bool cardOnEveryNetwork(AppSettings settings) => textCardEveryNetwork ?? settings.textCardEveryNetwork;

  bool get isArtwork => artwork != null;

  /// The user's sound file, when one is attached.
  MediaAttachment? get audio => media.where((m) => m.isAudio && !m.generated).firstOrNull;

  /// "Different time per network": a selected target has a time of its own
  /// (`PostOverrides.scheduledAt`). Off, every network goes at [scheduledAt].
  bool get schedulesEachTarget => selected.any((id) => overrides[id]?.scheduledAt != null);

  /// The thread part (0 = [text], 1 = the first of [additionalParts]...)
  /// each attachment goes with, by media id; missing = the first part
  /// ([Post.mediaParts]). Indexes count empty parts too; [toPost] closes the
  /// gaps.
  final Map<String, int> mediaParts;

  /// The part [mediaId] goes with.
  int partOfMedia(String mediaId) => mediaParts[mediaId] ?? 0;

  /// 1.3.1: cards. The installed or imported font of the text card's words
  /// (CaptionFont.toJson); an empty map for the built-in [textCardFont],
  /// null = the Settings default.
  final Map<String, dynamic>? textCardCustomFont;

  /// [textCardCustomFont], or the Settings default; null for a built-in font.
  CaptionFont? cardCustomFont(AppSettings settings) =>
      textCardCustomFont == null ? settings.textCardCustomFontChoice : CaptionFont.tryParse(textCardCustomFont);

  /// 1.3.1: cards. The card designer's design of this post's text cards
  /// (CardDesign.toJson); an empty map for the classic card, null = the
  /// Settings default.
  final Map<String, dynamic>? textCardDesign;

  /// 1.3.1: cards. The design of the picture in this post's sound file video,
  /// like [textCardDesign].
  final Map<String, dynamic>? audioCardDesign;

  /// [textCardDesign], or the Settings default; null for the classic card.
  CardDesign? textDesign(AppSettings settings) => effectiveCardDesign(textCardDesign, settings.textCardDesign);

  /// [audioCardDesign], or the Settings default; null for the classic card.
  CardDesign? audioDesign(AppSettings settings) => effectiveCardDesign(audioCardDesign, settings.audioCardDesign);

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
    AudioQuality? audioQuality,
    bool? textCardEveryNetwork,
    Map<String, bool>? textCardWithText,
    Map<String, int>? mediaParts,
    Map<String, dynamic>? textCardCustomFont, // 1.3.1: cards
    Map<String, dynamic>? textCardDesign, // 1.3.1: cards
    Map<String, dynamic>? audioCardDesign, // 1.3.1: cards
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
        audioQuality: audioQuality ?? this.audioQuality,
        textCardEveryNetwork: textCardEveryNetwork ?? this.textCardEveryNetwork,
        textCardWithText: textCardWithText ?? this.textCardWithText,
        mediaParts: mediaParts ?? this.mediaParts,
        textCardCustomFont: textCardCustomFont ?? this.textCardCustomFont, // 1.3.1: cards
        textCardDesign: textCardDesign ?? this.textCardDesign, // 1.3.1: cards
        audioCardDesign: audioCardDesign ?? this.audioCardDesign, // 1.3.1: cards
      );

  /// [mediaParts] for the post [toPost] builds, which leaves out empty parts:
  /// an empty part's media goes with the part before it, and media on the
  /// first part (or no longer attached) is not listed.
  Map<String, int> get postMediaParts {
    if (mediaParts.isEmpty) return const {};
    // Index in the post of each composer part.
    final remap = <int>[0];
    var kept = 0;
    for (final p in additionalParts) {
      if (p.trim().isNotEmpty) kept++;
      remap.add(kept);
    }
    final ids = {for (final m in media) m.id};
    return {
      for (final e in mediaParts.entries)
        if (ids.contains(e.key) && e.value > 0 && remap[e.value.clamp(0, remap.length - 1)] > 0) e.key: remap[e.value.clamp(0, remap.length - 1)],
    };
  }

  /// Builds the master [Post] for this composer state. With a different time
  /// per network every target carries its time (a target added since gets
  /// [scheduledAt]), and the post's own time is the earliest of them.
  Post toPost({required String id, required PostStatus status, required DateTime now, DateTime? createdAt}) {
    final each = schedulesEachTarget;
    final base = scheduledAt;
    PostOverrides overridesOf(String accountId) {
      final o = overrides[accountId] ?? const PostOverrides();
      if (!each) return o.scheduledAt == null ? o : o.copyWith(clearScheduledAt: true);
      return o.scheduledAt == null && base != null ? o.copyWith(scheduledAt: base) : o;
    }

    return Post(
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
      audioQuality: audioQuality,
      mediaParts: postMediaParts,
      scheduledAt: scheduledAt,
      status: status,
      createdAt: createdAt ?? now,
      updatedAt: now,
      targets: [
        for (final id in selected) PostTarget(accountId: id, overrides: overridesOf(id)),
      ],
    ).withScheduleFromTargets();
  }
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
  /// Sets the time every network goes at ("Same time for all"). Null removes
  /// the schedule, the times per network included.
  void setSchedule(DateTime? when) {
    if (when != null) {
      state = state.copyWith(scheduledAt: when);
      return;
    }
    state = state.copyWith(clearSchedule: true, overrides: _withTargetTimes(const {}));
  }

  /// "Different time per network": [times] by account id, or null for the
  /// same time for all. The post's time becomes the earliest of them.
  void setTargetSchedules(Map<String, DateTime>? times) {
    final each = times != null && times.isNotEmpty;
    final earliest = each ? times.values.reduce((a, b) => a.isBefore(b) ? a : b) : null;
    state = state.copyWith(overrides: _withTargetTimes(times ?? const {}), scheduledAt: earliest);
  }

  /// The overrides with [times] as each target's own time; the others lose
  /// theirs.
  Map<String, PostOverrides> _withTargetTimes(Map<String, DateTime> times) {
    final out = <String, PostOverrides>{};
    for (final id in {...state.overrides.keys, ...times.keys}) {
      final current = state.overrides[id] ?? const PostOverrides();
      final at = times[id];
      final next = at == null ? current.copyWith(clearScheduledAt: true) : current.copyWith(scheduledAt: at);
      if (!next.isEmpty) out[id] = next;
    }
    return out;
  }
  void focus(String? accountId) => state = accountId == null ? state.copyWith(clearFocus: true) : state.copyWith(focusedAccountId: accountId);
  void setTextCardTheme(TextCardTheme t) => state = state.copyWith(textCardTheme: t);
  /// A built-in font for the card's words (no installed or imported one).
  void setTextCardFont(TextCardFont f) => state = state.copyWith(textCardFont: f, textCardCustomFont: const {});

  /// 1.3.1: cards. An installed or imported font for the card's words; null
  /// for the built-in [ComposerState.textCardFont].
  void setTextCardCustomFont(CaptionFont? font) => state = state.copyWith(textCardCustomFont: font?.toJson() ?? const {});

  /// 1.3.1: cards. This post's text card design; null for the classic card.
  void setTextCardDesign(CardDesign? design) => state = state.copyWith(textCardDesign: design?.toJson() ?? const {});

  /// 1.3.1: cards. This post's audio card design; null for the classic card.
  void setAudioCardDesign(CardDesign? design) => state = state.copyWith(audioCardDesign: design?.toJson() ?? const {});
  void setTextCardBranded(String platformId, bool branded) =>
      state = state.copyWith(textCardBranded: {...state.textCardBranded, platformId: branded});
  void setCaptionOnPhoto(String platformId, bool on) => state = state.copyWith(captionOnPhoto: {...state.captionOnPhoto, platformId: on});
  void setPoll(PostPoll? poll) => state = poll == null ? state.copyWith(clearPoll: true) : state.copyWith(poll: poll);
  void setDifferentiate(bool on) => state = state.copyWith(differentiate: on);
  void setTextCardAlignment(TextCardAlignment a) => state = state.copyWith(textCardAlignment: a);
  void setTextCardHandle(String platformId, bool show) => state = state.copyWith(textCardHandle: {...state.textCardHandle, platformId: show});
  void setCaptionStyle(Map<String, dynamic> style) => state = state.copyWith(captionStyle: style);
  void setAudioQuality(AudioQuality quality) => state = state.copyWith(audioQuality: quality);
  void setTextCardBackground(Map<String, dynamic>? background) =>
      state = background == null ? state.copyWith(clearTextCardBackground: true) : state.copyWith(textCardBackground: background);
  void setTextCardEveryNetwork(bool on) => state = state.copyWith(textCardEveryNetwork: on);
  void setTextCardWithText(String platformId, bool on) => state = state.copyWith(textCardWithText: {...state.textCardWithText, platformId: on});

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
    // Media of the parts after the new one moves along with them.
    state = state.copyWith(additionalParts: parts, mediaParts: _shiftParts(state.mediaParts, from: at + 1, by: 1));
    return at + 1;
  }

  /// Removes thread part [index] (1 or more; part 0 is cleared with
  /// [clearPost]). Its media goes with the part before it.
  void removePart(int index) {
    if (index < 1 || index - 1 >= state.additionalParts.length) return;
    final parts = [...state.additionalParts]..removeAt(index - 1);
    final mediaParts = {
      for (final e in state.mediaParts.entries)
        if (e.value != index) e.key: e.value
        else if (index - 1 > 0) e.key: index - 1,
    };
    state = state.copyWith(additionalParts: parts, mediaParts: _shiftParts(mediaParts, from: index + 1, by: -1));
  }

  /// [mediaParts] with every part index from [from] on moved by [by].
  static Map<String, int> _shiftParts(Map<String, int> mediaParts, {required int from, required int by}) => {
        for (final e in mediaParts.entries) e.key: e.value >= from ? e.value + by : e.value,
      };

  /// Puts attachment [mediaId] in thread part [part] (0 is the first).
  void setMediaPart(String mediaId, int part) {
    final parts = {...state.mediaParts};
    if (part <= 0) {
      parts.remove(mediaId);
    } else {
      parts[mediaId] = part.clamp(1, state.additionalParts.length);
    }
    state = state.copyWith(mediaParts: parts);
  }

  /// Fills the composer with a thread made elsewhere (a document): [parts]
  /// become the thread's parts, [media] its attachments, each in the part
  /// [mediaParts] names. Targets, schedule (the times per network included),
  /// each network's settings ([PostOverrides.extra]: subreddit, Post +
  /// Story...), artwork mode and the post being edited stay; everything else
  /// of the post is replaced, per-network versions of the words and media
  /// included.
  void fillThread(List<String> parts, List<MediaAttachment> media, Map<String, int> mediaParts) {
    state = ComposerState(
      editingPostId: state.editingPostId,
      visibility: state.visibility,
      selected: state.selected,
      scheduledAt: state.scheduledAt,
      overrides: {
        for (final e in state.overrides.entries)
          if (e.value.scheduledAt != null || e.value.extra.isNotEmpty)
            e.key: PostOverrides(scheduledAt: e.value.scheduledAt, extra: e.value.extra),
      },
      artwork: state.artwork,
      text: parts.isEmpty ? '' : parts.first,
      additionalParts: parts.skip(1).toList(),
      media: media,
      mediaParts: {
        for (final e in mediaParts.entries)
          if (e.value > 0) e.key: e.value,
      },
      revision: state.revision + 1,
    );
  }

  /// Undo of [removePart]: puts [text] back as part [index] and keeps what
  /// was written since. [revision] is the one [removePart] left; once the
  /// post was replaced (published, scheduled, loaded, reset or cleared) the
  /// undo is void and nothing changes. Returns whether the part is back.
  bool undoRemovePart(int index, String text, {required int revision}) {
    if (index < 1 || state.revision != revision) return false;
    final at = (index - 1).clamp(0, state.additionalParts.length);
    final parts = [...state.additionalParts]..insert(at, text);
    state = state.copyWith(additionalParts: parts, mediaParts: _shiftParts(state.mediaParts, from: at + 1, by: 1));
    return true;
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
      // The times per network are part of the schedule.
      overrides: {
        for (final e in state.overrides.entries)
          if (e.value.scheduledAt != null) e.key: PostOverrides(scheduledAt: e.value.scheduledAt),
      },
      artwork: state.artwork,
      revision: state.revision + 1,
    );
  }

  /// Undo of [clearPost]: puts [before] back while the composer still holds
  /// [cleared], the state clearing left. Anything changed since (new words,
  /// a publish, a load or a reset) would be overwritten, so the undo is
  /// then void and nothing changes. Returns whether the post is back.
  bool undoClearPost(ComposerState before, ComposerState cleared) {
    if (!identical(state, cleared)) return false;
    restore(before);
    return true;
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
      mediaParts: {...state.mediaParts}..remove(mediaId),
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
    final p = withoutTextCards(withoutAudioRenditions(post));
    final accounts = ref.read(accountListProvider);
    String? platformOf(String id) => accounts.where((a) => a.id == id).map((a) => a.platformId).firstOrNull;
    // A "Mention @everyone" value that matches Settings was written on save
    // (withMentionDefault); it is not a choice of this post.
    final mentionDefault = ref.read(settingsProvider).discordMentionEveryone;
    // The card choices written on save (withTextCardChoices) are the
    // composer's own fields, not the target's.
    PostOverrides ownOverrides(PostTarget t) {
      final o = withoutTextCardChoices(t.overrides);
      return platformOf(t.accountId) == 'discord' && o.extra[kMentionEveryoneKey] == mentionDefault
          ? o.copyWith(extra: {...o.extra}..remove(kMentionEveryoneKey))
          : o;
    }
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
        audioQuality: p.audioQuality,
        textCardEveryNetwork: textCardEveryNetworkOfPost(post),
        textCardWithText: textCardWithTextOfPost(post, platformOf),
        mediaParts: p.mediaParts,
        textCardCustomFont: textCardCustomFontOfPost(post), // 1.3.1: cards
        textCardDesign: textCardDesignOfPost(post), // 1.3.1: cards
        audioCardDesign: audioCardDesignChoiceOfPost(post), // 1.3.1: cards
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
      // A fresh draft has no schedule, nor times per network.
      overrides: {
        for (final e in state.overrides.entries)
          if (!e.value.copyWith(clearScheduledAt: true).isEmpty) e.key: e.value.copyWith(clearScheduledAt: true),
      },
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
      audioQuality: state.audioQuality,
      textCardEveryNetwork: state.textCardEveryNetwork,
      textCardWithText: state.textCardWithText,
      mediaParts: state.mediaParts,
      textCardCustomFont: state.textCardCustomFont, // 1.3.1: cards
      textCardDesign: state.textCardDesign, // 1.3.1: cards
      audioCardDesign: state.audioCardDesign, // 1.3.1: cards
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
  final sound = c.audio;
  // Read once, before the loop: the AOT compiler once hoisted a null-guarded
  // field load out of a loop and crashed release builds (1.2.1).
  final soundId = sound?.id;
  final standardFormat = sound == null ? null : standardAudioFormat(ref.watch(audioOutputFormatsProvider).value ?? const []);
  final canRenderVideo = sound != null && (ref.watch(videoCaptionsSupportedProvider).value ?? false);
  final everyNetwork = c.cardOnEveryNetwork(settings);
  // 1.3.1: cards. Watching the card's own font starts loading it; read once,
  // before the loop (the 1.2.1 AOT crash).
  final cardFont = c.cardCustomFont(settings);
  final cardDesign = c.textDesign(settings);
  final cardFontMissing = settings.textCards && cardFont != null && ref.watch(captionFontReadyProvider(cardFont)).value == false;
  final cardFontFamily = cardFont?.family ?? '';
  final out = <TargetPreview>[];
  for (final a in accounts) {
    if (!c.selected.contains(a.id)) continue;
    final adapter = registry.byId(a.platformId);
    if (adapter == null) continue;
    final target = post.targetFor(a.id)!;
    final d = adapter.descriptorForAccount(a);
    var variant = resolver.resolve(post, withMentionDefault(target, a.platformId, settings), d, account: a);
    final issues = <ValidationIssue>[...variant.issues];
    // Image-only platforms, and stories, get the words as a NEFORUM text
    // card, rendered when the post is saved; preview and check a stand-in for
    // it. A story's card is full screen (9:16). With the card on every
    // network, so does every network that takes images.
    final placement = adapter.supportsStories(a) ? variant.placement : PostPlacement.feed;
    final storyCard = settings.textCards && placement.includesStory && storyQualifiesForTextCard(d, variant, backgroundMediaId: backgroundPhotoId);
    final feedCard = settings.textCards &&
        placement != PostPlacement.story &&
        qualifiesForTextCard(d, variant, backgroundMediaId: backgroundPhotoId, everyNetwork: everyNetwork);
    if (storyCard || feedCard) {
      final signed = c.textCardBranded[d.id] ?? settings.textCardBranded(d.id);
      MediaAttachment placeholder({bool story = false}) => textCardPlaceholder(
            d.id,
            c.textCardTheme ?? settings.textCardTheme,
            branded: signed,
            font: c.textCardFont ?? settings.textCardFont,
            alignment: c.textCardAlignment ?? settings.textCardAlignment,
            showsHandle: c.textCardHandle[d.id] ?? settings.textCardShowsHandle(d.id),
            background: background,
            story: story,
            customFont: cardFont,
            design: cardDesign,
          ).copyWith(altText: textCardAltText(textCardText(post, target)));
      if (feedCard && c.textCardWithText[d.id] == false) {
        // The card alone: resolved again with it, as publishing will. The
        // feed post of Post + Story too; its story keeps a story card.
        final card = placeholder();
        final alone = post.copyWith(media: [...post.media, card]).withTarget(target.copyWith(
            overrides: target.overrides.copyWith(mediaIds: [card.id], extra: {...target.overrides.extra, kTextCardOnlyKey: true})));
        variant = resolver.resolve(alone, withMentionDefault(alone.targetFor(a.id)!, a.platformId, settings), d, account: a);
        if (storyCard) variant = variant.copyWith(storyMedia: [placeholder(story: true)]);
        issues
          ..removeWhere((i) => i.field == 'text')
          ..addAll(variant.issues.where((i) => i.field == 'text'));
      } else {
        variant = placement == PostPlacement.story
            ? variant.copyWith(media: [placeholder(story: true)])
            : variant.copyWith(
                media: feedCard ? [placeholder()] : null,
                storyMedia: storyCard ? [placeholder(story: true)] : null,
              );
      }
      final what = !feedCard
          ? 'Your ${d.name} story shows your words on'
          : d.media.requiresMedia
              ? '${d.name} needs an image, so your words go out as'
              : '${d.name} gets your words as';
      issues.add(ValidationIssue.info(
          'media.text_card', '$what ${signed ? 'a NEFORUM' : 'a plain'} text card${background == null ? '' : ' over your photo'}',
          field: 'media'));
      if (cardFontMissing) {
        issues.add(ValidationIssue.info(
            'media.text_card_font_missing',
            'The font $cardFontFamily is not on this device, so the card uses ${(c.textCardFont ?? settings.textCardFont).label}. '
            'Install or import $cardFontFamily here to use it.',
            field: 'media'));
      }
    } else if (settings.textCards && everyNetwork && !acceptsTextCardImages(d) && variant.media.isEmpty && variant.text.trim().isNotEmpty) {
      issues.add(ValidationIssue.info('media.text_card_unsupported', '${d.name} takes no images, so it gets your words as plain text', field: 'media'));
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
    // A sound file: what this network gets is made when the post is saved
    // (the Standard copy, or a video for video-only networks); check a
    // stand-in for it.
    if (sound != null && variant.media.any((m) => m.id == soundId)) {
      final audio = previewAudio(variant.media, sound, d, c.audioQuality, standardFormat: standardFormat, canRenderVideo: canRenderVideo);
      // The picture of a still-picture video leaves; every other item keeps
      // its thread part, and the stand-in takes the track's.
      final kept = variant.withoutMedia((m) => m.id != soundId && !audio.media.any((x) => identical(x, m)));
      variant = kept.copyWith(media: audio.media);
      issues.addAll(audio.notes);
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
    if (captionOnPhotoFor(d.id, settings, c.captionOnPhoto) &&
        firstMedia != null &&
        firstMedia.isVideo &&
        captionStyle.placement == CaptionPlacement.blockAbove &&
        (ref.watch(videoCaptionsSupportedProvider).value ?? false)) {
      issues.add(ValidationIssue.info('media.caption_video',
          'Your caption is set in a block above the video for ${d.name}; NEFORUM makes that copy when you save or publish', field: 'media'));
    }
    // 1.3: video. Attached files carry no duration: the compositor reads it,
    // so a video over a network's length limit is caught before posting.
    final hasVideo = variant.media.any((m) => m.isVideo);
    if (hasVideo && variant.media.any((m) => m.isVideo && m.durationMs == null)) {
      variant = variant.copyWith(media: [
        for (final m in variant.media)
          if (m.isVideo && m.durationMs == null) withProbedDuration(m, ref.watch(videoProbeProvider(m.path)).value) else m,
      ]);
    }
    final canShrink = hasVideo && (ref.watch(videoShrinkingSupportedProvider).value ?? false);
    try {
      issues.addAll(withVideoLimitAdvice(adapter.validate(variant, a), variant, d,
          shrink: canShrink && settings.shrinkOversizedVideos, canShrink: canShrink));
    } on Object catch (e) {
      issues.add(ValidationIssue.warning('validate.crash', 'Could not validate: $e'));
    }
    // Media host requirement is a configuration problem, not a text one.
    final services = ref.read(servicesProvider);
    if (!services.demo && d.media.requiresPublicMediaUrl && a.tier != PlatformTier.handoff && variant.hasMedia && services.mediaHost == null) {
      issues.add(ValidationIssue.error('media.host_missing', '${d.name} needs a public media host (Settings → Media hosting)', field: 'media'));
    }
    // Nostr checks its own media server (NIP-96) first.
    if (!services.demo && d.media.audioAsLink && d.id != 'nostr' && a.tier != PlatformTier.handoff && variant.media.any((m) => m.isAudio) && services.mediaHost == null) {
      issues.add(ValidationIssue.error(
          'media.audio_host_missing', '${d.name} takes sound only as a link: set up a media host (Settings → Media hosting)', field: 'media'));
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

/// [post] scheduled for [when]. With a different time per network every
/// network still to go moves by the same amount, so the next one goes at
/// [when] and the gaps between them stay.
Post rescheduledPost(Post post, DateTime when, DateTime now) {
  final from = post.scheduledAt;
  var next = post.copyWith(status: PostStatus.scheduled, scheduledAt: when, updatedAt: now);
  if (!post.schedulesEachTarget || from == null) return next;
  final shift = when.difference(from);
  next = next.copyWith(targets: [
    for (final t in post.targets)
      if (t.overrides.scheduledAt case final at? when !t.isDone) t.copyWith(overrides: t.overrides.copyWith(scheduledAt: at.add(shift))) else t,
  ]);
  return next.withScheduleFromTargets();
}

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

  /// Saves the composer's post with [status], under [id] when given.
  Future<Post> _save(PostStatus status, {String? id}) async {
    final s = ref.read(servicesProvider);
    final c = ref.read(composerProvider);
    final now = DateTime.now();
    final existing = c.editingPostId == null ? null : await s.posts.get(c.editingPostId!);
    if (existing != null) await _releaseHeld(existing.id);
    var post = c.toPost(id: id ?? c.editingPostId ?? _uuid.v7(), status: status, now: now, createdAt: existing?.createdAt);
    // Networks that already have an edited post (the earlier times of a post
    // with a time per network) keep their outcome, so they never get it twice.
    final current = existing == null ? null : await s.posts.get(existing.id);
    if (current != null) {
      post = post.copyWith(targets: [
        for (final t in post.targets)
          if (current.targetFor(t.accountId) case final done? when done.isDone)
            done.copyWith(overrides: t.overrides)
          else
            t,
      ]).withScheduleFromTargets();
    }
    final accounts = ref.read(accountListProvider);
    post = withMentionDefaults(post, accounts, ref.read(settingsProvider));
    post = withTextCardChoices(post,
        everyNetwork: c.cardOnEveryNetwork(ref.read(settingsProvider)),
        withText: c.textCardWithText,
        platformOf: (id) => accounts.where((a) => a.id == id).firstOrNull?.platformId);
    // 1.3.1: cards. After the card choices, which replace the targets' extras.
    post = withCardDesigns(post, text: c.textCardDesign, audio: c.audioCardDesign);
    // Hand the old cards and fitted photos over so unchanged ones are reused,
    // stale ones deleted.
    post = post.copyWith(media: [...post.media, ...?existing?.media.where((m) => m.generated)]);
    post = withoutAudioRenditions(post, keepFiles: true);
    post = await attachTextCards(s, post, ref.read(settingsProvider),
        theme: c.textCardTheme,
        font: c.textCardFont,
        branded: c.textCardBranded,
        alignment: c.textCardAlignment,
        handle: c.textCardHandle,
        background: c.textCardBackground ?? const {},
        customFont: c.textCardCustomFont,
        design: c.textCardDesign);
    post = await attachFittedPhotos(s, post, ref.read(settingsProvider));
    post = await attachCaptionedPhotos(s, post, ref.read(settingsProvider), choices: c.captionOnPhoto, style: c.captionStyle);
    post = await attachAudioRenditions(s, post, ref.read(settingsProvider));
    // 1.3: video. A scheduled post gets its smaller copies of videos now,
    // while this device has a compositor: a background run has none and only
    // reuses them. Publishing now makes them in the run, with progress.
    if (status == PostStatus.scheduled) post = await attachShrunkVideos(s, post, ref.read(settingsProvider));
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
  ///
  /// The run is on record in the publish journal before the post is saved
  /// as publishing, so a NEFORUM that closes before the run starts leaves a
  /// post that recovery can settle.
  Future<Post> publishNow() async {
    final run = ref.read(publishRunProvider.notifier);
    run.prepare();
    final s = ref.read(servicesProvider);
    final c = ref.read(composerProvider);
    final id = c.editingPostId ?? _uuid.v7();
    try {
      await s.publishJournal.record(id);
    } on Object catch (e) {
      // Only recovery after a crash needs the record; posting goes on.
      debugPrint('Could not record the run of $id in the publish journal: $e');
    }
    final Post p;
    try {
      // Every network goes now: the times per network go too, so a network
      // that fails is retried after its backoff, not at its old time.
      p = (await _save(PostStatus.publishing, id: id)).withoutSchedule();
      await s.posts.upsert(p);
    } on Object catch (e) {
      // Nothing is publishing: the post keeps its previous state, if any.
      unawaited(s.publishJournal.release(id).catchError((Object _) {}));
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
  /// it is shown in the sheet, and a post it leaves publishing is settled
  /// at once: the networks it did not reach get Retry.
  ///
  /// With [dueTargetsOnly] (a due-post reminder) networks whose own time has
  /// not come yet are left for their own time, which gets the next reminder.
  Future<Post> publishExisting(String postId, {Set<String>? accountIds, bool retryFailed = true, bool dueTargetsOnly = false}) async {
    final run = ref.read(publishRunProvider.notifier);
    if (!(ref.read(publishRunProvider)?.preparing ?? false)) run.prepare();
    final signal = ref.read(publishRunProvider)!.cancellation;
    final active = ref.read(activePublishingProvider.notifier)..begin(postId, signal);
    try {
      return await _publishExisting(postId, signal, accountIds: accountIds, retryFailed: retryFailed, dueTargetsOnly: dueTargetsOnly);
    } on Object catch (e) {
      await ref.read(servicesProvider).concludeStoppedRun(postId, e);
      run.fail(postId, e);
      rethrow;
    } finally {
      active.end(postId, signal);
    }
  }

  Future<Post> _publishExisting(String postId, CancellationSignal signal,
      {Set<String>? accountIds, required bool retryFailed, bool dueTargetsOnly = false}) async {
    final s = ref.read(servicesProvider);
    // A background isolate may have posted some of it meanwhile: the run
    // starts from what posts.json says is still to do.
    await s.posts.reload();
    await _releaseHeld(postId, onlyAccountIds: accountIds);
    var post = await s.posts.get(postId);
    if (post == null) throw StateError('Post $postId not found');
    // Posts saved before text cards existed, or drafts published from a
    // list, get their cards here; every choice is read back from the post.
    post = withoutAudioRenditions(post, keepFiles: true);
    post = await attachTextCards(s, post, ref.read(settingsProvider));
    final choices = await captionChoicesOfSavedPost(s, post);
    post = await attachFittedPhotos(s, post, ref.read(settingsProvider));
    // A caption block above a video is made when the post is saved, never here.
    post = await attachCaptionedPhotos(s, post, ref.read(settingsProvider), choices: choices, composeVideos: false);
    // The quality is the post's own, so a missing rendition is made here.
    post = await attachAudioRenditions(s, post, ref.read(settingsProvider));
    await s.posts.upsert(post);
    final run = ref.read(publishRunProvider.notifier);
    final due = post;
    final now = DateTime.now();
    final starting = accountIds ?? {for (final t in due.targets) if (!dueTargetsOnly || due.isTargetDue(t, now)) t.accountId};
    run.start(postId, starting);
    // 1.3: video. Videos too big for a network get their smaller copy now,
    // with its progress on that network's row.
    post = await attachShrunkVideos(s, post, ref.read(settingsProvider),
        onProgress: run.progress, cancellation: signal, onlyAccountIds: starting);
    await s.posts.upsert(post);
    final done = await s.publisher().publish(
          postId,
          interactive: true,
          onlyAccountIds: accountIds,
          retryFailed: retryFailed,
          onProgress: run.progress,
          cancellation: signal,
          dueTargetsOnly: dueTargetsOnly,
        );
    final finalPost = await s.applySkips(postId) ?? done;
    run.finish(finalPost);
    try {
      // Networks still waiting for their own time keep their reminder.
      final next = finalPost.scheduledAt;
      if (finalPost.status == PostStatus.scheduled && finalPost.schedulesEachTarget && next != null && next.isAfter(DateTime.now())) {
        await ref.read(schedulerProvider).planReminders(finalPost);
      } else {
        await ref.read(schedulerProvider).cancelReminders(finalPost);
      }
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
  /// their failed and cancelled targets become skipped, which completes
  /// them, and the retention setting then applies to them like to any post
  /// that just completed. Posts this process is publishing are left alone.
  Future<({int deleted, int kept})> clearFailed(Iterable<Post> listed) async {
    final s = ref.read(servicesProvider);
    final active = ref.read(activePublishingProvider);
    final publisher = s.publisher();
    final doomed = <Post>[];
    final kept = <String>[];
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
      kept.add(p.id);
    }
    await s.discardPosts(doomed, inUse: _composerReferences());
    for (final id in kept) {
      await s.discardIfComplete(id, inUse: _composerReferences());
    }
    ref.read(schedulerProvider).updateTrayStatus();
    return (deleted: doomed.length, kept: kept.length);
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
    final next = rescheduledPost(current, when, DateTime.now());
    await s.posts.upsert(next);
    await ref.read(schedulerProvider).planReminders(next);
    _delegate(next);
    return next;
  }

  static String _short(String s) => s.length > 80 ? '${s.substring(0, 80)}…' : s;
}
final postActionsProvider = Provider<PostActions>(PostActions.new);
