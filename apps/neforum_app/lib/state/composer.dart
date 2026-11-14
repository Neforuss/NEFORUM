import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:uuid/uuid.dart';

import '../media/audio_plan.dart';
import '../media/caption_fonts.dart' show CaptionFont, captionFontReadyProvider;
import '../media/font_catalog.dart' show FontDownloadMode;
import '../media/card_design.dart';
import '../media/card_design_edits.dart' show designWithHandle;
import '../media/caption_style.dart';
import '../media/text_card.dart';
import '../media/text_card_background.dart';
import '../platform/notifications.dart';
import '../platform/publish_host.dart';
import 'artwork_targets.dart';
import 'audio_renditions.dart';
import 'automatic_targets.dart';
import 'card_designs.dart';
import 'captioned_photos.dart';
import 'composer_draft.dart';
import 'fitted_photos.dart';
import 'notification_state.dart';
import 'providers.dart';
import 'publish_result_notices.dart';
import 'publish_run_keeper.dart';
import 'publish_run_session.dart';
import 'publish_run_surface.dart';
import 'scheduler.dart';
import 'settings.dart';
import 'shrunk_videos.dart';
import 'story_placements.dart';
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
    this.audioDetails = const {},
    this.textCardCustomFont, // 1.3.1: cards
    this.textCardDesign, // 1.3.1: cards
    this.audioCardDesign, // 1.3.1: cards
    this.textCardStyle = TextCardStyle.classic, // 1.3.5: cards
    this.textCardDesignBeforeEdits, // 1.3.5: cards
    this.automaticTargets = false, // 1.4.3: Automatic only
    this.targetChoices = const {}, // 1.4.3: Automatic only
    this.paragraphMedia = const {}, // 1.4.3
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

  /// The user's (first) sound file, when one is attached.
  MediaAttachment? get audio => media.where((m) => m.isAudio && !m.generated).firstOrNull;

  /// "Different time per network": a selected target has a time of its own
  /// (`PostOverrides.scheduledAt`). Off, every network goes at [scheduledAt].
  bool get schedulesEachTarget => selected.any((id) => overrides[id]?.scheduledAt != null);

  /// The thread part (0 = [text], 1 = the first of [additionalParts]...)
  /// each attachment goes with, by media id; missing = the first part
  /// ([Post.mediaParts]). Indexes count empty parts too; [toPost] closes the
  /// gaps.
  final Map<String, int> mediaParts;

  /// What the user set for each sound file's track details, by media id,
  /// over the tags that file carries ([Post.audioDetails]); a file without
  /// an entry keeps its own.
  final Map<String, AudioTags> audioDetails;

  /// The track details the sound file [mediaId] goes out with: its own tags
  /// under its [audioDetails]; null when it is not one of the user's sound
  /// files.
  AudioTags? effectiveAudioTagsOf(String mediaId) {
    final sound = media.where((m) => m.id == mediaId && m.isAudio && !m.generated).firstOrNull;
    return sound == null ? null : (sound.audioTags ?? AudioTags.none).overriddenBy(audioDetails[mediaId]);
  }

  /// 1.4.3: why [account] cannot take this post ([automaticSkipReason]),
  /// with its own version of the words and its own choice of files; null
  /// when it can.
  String? skipReasonFor(ConnectedAccount account, AdapterRegistry registry, AppSettings settings) {
    final adapter = registry.byId(account.platformId);
    if (adapter == null) return null;
    final own = overrides[account.id];
    final ids = own?.mediaIds;
    return automaticSkipReason(
      adapter.descriptorForAccount(account),
      media: ids == null ? media : media.where((m) => ids.contains(m.id)),
      hasWords: (own?.text ?? joinedParts).trim().isNotEmpty,
      textCards: settings.textCards,
    );
  }

  /// The track details the first sound file ([audio]) goes out with; null
  /// without a sound file.
  AudioTags? get effectiveAudioTags {
    final sound = audio;
    return sound == null ? null : effectiveAudioTagsOf(sound.id);
  }

  /// The part [mediaId] goes with.
  int partOfMedia(String mediaId) => mediaParts[mediaId] ?? 0;

  /// 1.4.3: thread media. The attachments of thread part [part] (0 is the
  /// first), in the post's order. A part number past the last part counts as
  /// the last part, as the Part chip shows it.
  List<MediaAttachment> mediaOfPart(int part) => [
        for (final m in media)
          if (partOfMedia(m.id).clamp(0, additionalParts.length) == part) m,
      ];
  /// 1.4.3: which paragraph of [text] refers to which photos and videos
  /// ([Post.paragraphMedia]); empty (the default) for none. Kept while the
  /// user types: the links move with their paragraphs.
  final ParagraphMediaLinks paragraphMedia;

  /// The paragraphs of [text], as the links count them.
  List<String> get paragraphs => ParagraphMedia.split(text);

  /// The files a paragraph can be linked to: the user's photos and videos.
  List<MediaAttachment> get linkableMedia => [for (final m in media) if (!m.generated && (m.isImage || m.isVideo)) m];

  /// Whether linking paragraphs to media makes sense: one long post (no
  /// thread) of two paragraphs or more, with a photo or video.
  bool get canLinkParagraphs => additionalParts.isEmpty && linkableMedia.isNotEmpty && paragraphs.length > 1;

  /// [paragraphMedia] for the post [toPost] builds: only paragraphs that
  /// exist and files still attached.
  ParagraphMediaLinks get postParagraphMedia => paragraphMedia.isEmpty
      ? const {}
      : ParagraphMedia.normalized(paragraphMedia, paragraphs: paragraphs.length, mediaIds: {for (final m in linkableMedia) m.id});

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

  /// 1.3.5: cards. The classic text card's size, colours, line spacing,
  /// margins, word position and @handle (its words, size, corner and
  /// colour), the same on every network's card; [TextCardStyle.classic] for
  /// the card as it always was. Set from the master editor or under any
  /// network's card; its @handle also goes on designed cards.
  final TextCardStyle textCardStyle;

  /// 1.3.5: cards. The post's design as it was before the text card
  /// editor's controls first changed it, as `{'design': <its JSON or null>}`
  /// (null inside: the post followed the Settings default); null when the
  /// editor has changed nothing since a design was picked or the post was
  /// opened or saved. "Reset handle and words" puts it back, however often
  /// the editor is folded or rebuilt, and the composer's draft keeps it.
  final Map<String, dynamic>? textCardDesignBeforeEdits;

  /// 1.4.3: the targets came from "Automatic only" and follow the post: the
  /// automatic accounts whose rules take it are added as it changes (a video
  /// added brings YouTube videos and Odysee), and the ones NEFORUM added go
  /// again when the rules no longer take it. See [targetChoices].
  final bool automaticTargets;

  /// 1.4.3: while [automaticTargets], how each account came to be in or out
  /// of the post: added by NEFORUM, or ticked or unticked by hand. Hand
  /// choices are kept as they are; an account without an entry was left
  /// out by Automatic only and comes in once its rules take the post.
  final Map<String, TargetChoice> targetChoices;

  /// [audioCardDesign], or the Settings default; null for the classic card.
  CardDesign? audioDesign(AppSettings settings) => effectiveCardDesign(audioCardDesign, settings.audioCardDesign);

  /// The design written on the saved post's targets for its sound file's
  /// video ([withCardDesigns]): [audioCardDesign], else the Settings default
  /// the video is drawn with now, so a scheduled or background run still
  /// finds that video after the default changes. Null without a sound file.
  Map<String, dynamic>? audioCardDesignToSave(AppSettings settings) => audioCardDesign ?? (audio == null ? null : settings.audioCardDesign);

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

  /// Something that clearing or replacing the post would lose. Post / Story
  /// alone is not: it stays, and a new post starts with it (1.4.3).
  bool get hasContent =>
      !isEmpty ||
      additionalParts.isNotEmpty ||
      poll != null ||
      contentWarning != null ||
      tags.isNotEmpty ||
      overrides.values.any((o) => !withoutPlacement(o).isEmpty);

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
    Map<String, AudioTags>? audioDetails,
    Map<String, dynamic>? textCardCustomFont, // 1.3.1: cards
    Map<String, dynamic>? textCardDesign, // 1.3.1: cards
    Map<String, dynamic>? audioCardDesign, // 1.3.1: cards
    TextCardStyle? textCardStyle, // 1.3.5: cards
    bool clearPoll = false,
    bool clearSchedule = false,
    bool clearTitle = false,
    bool clearLink = false,
    bool clearCw = false,
    bool clearFocus = false,
    bool clearArtwork = false,
    bool clearTextCardBackground = false,
    Map<String, dynamic>? textCardDesignBeforeEdits, // 1.3.5: cards
    bool clearTextCardDesign = false,
    bool clearTextCardDesignBeforeEdits = false,
    bool clearEditingPostId = false,
    bool? automaticTargets, // 1.4.3: Automatic only
    Map<String, TargetChoice>? targetChoices, // 1.4.3: Automatic only
    ParagraphMediaLinks? paragraphMedia, // 1.4.3
  }) =>
      ComposerState(
        editingPostId: clearEditingPostId ? null : (editingPostId ?? this.editingPostId),
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
        audioDetails: audioDetails ?? this.audioDetails,
        textCardCustomFont: textCardCustomFont ?? this.textCardCustomFont, // 1.3.1: cards
        textCardDesign: clearTextCardDesign ? null : (textCardDesign ?? this.textCardDesign), // 1.3.1: cards
        audioCardDesign: audioCardDesign ?? this.audioCardDesign, // 1.3.1: cards
        textCardStyle: textCardStyle ?? this.textCardStyle, // 1.3.5: cards
        textCardDesignBeforeEdits:
            clearTextCardDesignBeforeEdits ? null : (textCardDesignBeforeEdits ?? this.textCardDesignBeforeEdits), // 1.3.5: cards
        automaticTargets: automaticTargets ?? this.automaticTargets, // 1.4.3: Automatic only
        targetChoices: targetChoices ?? this.targetChoices, // 1.4.3: Automatic only
        paragraphMedia: paragraphMedia ?? this.paragraphMedia, // 1.4.3
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
      paragraphMedia: postParagraphMedia,
      audioDetails: {
        for (final e in audioDetails.entries)
          if (!e.value.isEmpty && media.any((m) => m.id == e.key && m.isAudio && !m.generated)) e.key: e.value,
      },
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

/// Whether the composer may still save over [post] as the post it edits: a draft
/// or a scheduled post. A post that went out, is going out or failed in a run
/// belongs to that run: its targets hold what each network answered, and words
/// written over it are a new post. Saved over it instead, they would keep those
/// answers (see [PostActions]), go to no network and be recorded as posted with
/// the earlier post's links.
bool isEditablePost(Post? post) => post != null && (post.status == PostStatus.draft || post.status == PostStatus.scheduled);

/// The composer's edited post went out between the moment Publish was pressed
/// and the moment its words were saved. Nothing was saved or sent; pressing
/// Publish again posts the words as a new post.
class EditedPostPublishedException implements Exception {
  const EditedPostPublishedException();

  String get message => 'This post went out while you were editing it, so your changes were not saved over it. Press Publish again to post them as a new post.';

  @override
  String toString() => message;
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
        final selected = _defaultTargets(next);
        state = state.copyWith(selected: selected, overrides: _withRememberedPlacements(state.overrides, selected, accounts: next));
      }
    });
    // 1.3.5 round 5: a post with no theme of its own follows Settings > Text
    // cards' theme, so a theme changed there gets the same readability rule
    // as the composer's theme chip ([setTextCardTheme]): a words or @handle
    // colour that would not read on the new plain card (under 3:1) goes, and
    // neither the preview nor a scheduled re-render draws white on white. A
    // photo card keeps its colours: they were picked for the photo.
    ref.listen(settingsProvider.select((s) => s.textCardTheme), (prev, next) {
      if (prev == next || state.textCardTheme != null || state.textCardBackground != null) return;
      final style = _readableOn(state.textCardStyle, next);
      if (style != state.textCardStyle) state = state.copyWith(textCardStyle: style);
    });
    // 1.4.3: cards. An empty new post follows a shape or layout changed in
    // Settings > Text cards; a post being written or edited keeps its own.
    ref.listen(settingsProvider.select((s) => s.newTextCardStyle), (prev, next) {
      if (prev == next || !state.isEmpty || state.editingPostId != null) return;
      final style = state.textCardStyle.copyWith(shape: next.shape, layout: next.layout);
      if (style != state.textCardStyle) state = state.copyWith(textCardStyle: style);
    });
    // 1.4.3: the post being edited went out (a run outside the composer while
    // NEFORUM was in the background, another device) or was deleted: the words
    // stay, as a new post.
    ref.listen<AsyncValue<List<Post>>>(postsProvider, (_, next) {
      final posts = next.value;
      if (posts != null) _forgetPostThatWentOut(posts);
    });
    return _fresh();
  }

  /// An empty post with the default targets.
  ComposerState _fresh() {
    final settings = ref.read(settingsProvider);
    final selected = _defaultTargets(ref.read(accountListProvider));
    return ComposerState(
      visibility: settings.defaultVisibility,
      selected: selected,
      // 1.4.3: a new post starts with each account's remembered Post / Story.
      overrides: _withRememberedPlacements(const {}, selected),
      // 1.4.3: cards. A new post's card starts with the shape and layout
      // Settings > Text cards picked.
      textCardStyle: settings.newTextCardStyle,
    );
  }

  /// Stops editing the saved post once [posts] say it can no longer be edited
  /// ([isEditablePost]) or is gone. Everything written stays; publishing or
  /// saving then makes a new post instead of writing over that post's record.
  /// A post being published is left to [PostActions], which decides when the
  /// words are saved (its run may be this composer's own).
  void _forgetPostThatWentOut(List<Post> posts) {
    final id = state.editingPostId;
    if (id == null) return;
    final post = posts.where((p) => p.id == id).firstOrNull;
    if (post?.status == PostStatus.publishing || isEditablePost(post)) return;
    state = state.copyWith(clearEditingPostId: true);
  }

  /// Every change goes through here: while the targets follow the post
  /// ([ComposerState.automaticTargets]), a change of its words or files
  /// brings the targets along ([_followingPost]).
  @override
  set state(ComposerState value) => super.state = _followingPost(value);

  /// 1.4.3: [s] with its targets brought in line with its post while they
  /// follow it: an automatic account without a choice of its own is added
  /// once its rules take the post, and one NEFORUM added goes when they no
  /// longer do. Accounts ticked or unticked by hand stay as they are. [s]
  /// itself when nothing changes.
  ComposerState _followingPost(ComposerState s) {
    if (!s.automaticTargets) return s;
    final registry = ref.read(registryProvider);
    final settings = ref.read(settingsProvider);
    final selected = {...s.selected};
    final choices = {...s.targetChoices};
    final added = <String>[];
    var changed = false;
    for (final a in automaticTargetCandidates(ref.read(accountListProvider), registry, artwork: s.isArtwork)) {
      final choice = choices[a.id];
      if (choice == TargetChoice.ticked || choice == TargetChoice.unticked) continue;
      final fits = s.skipReasonFor(a, registry, settings) == null;
      if (fits && !selected.contains(a.id)) {
        selected.add(a.id);
        added.add(a.id);
        choices[a.id] = TargetChoice.automatic;
        changed = true;
      } else if (!fits && choice == TargetChoice.automatic) {
        selected.remove(a.id);
        choices.remove(a.id);
        changed = true;
      }
    }
    if (!changed) return s;
    // An account this adds starts with its remembered Post / Story (1.4.3).
    return s.copyWith(
      selected: selected,
      overrides: added.isEmpty ? null : _withRememberedPlacements(s.overrides, added),
      targetChoices: choices,
    );
  }

  /// Art sites are left out: they only receive artwork (artwork_targets.dart).
  Set<String> _defaultTargets(List<ConnectedAccount> accounts) =>
      defaultPostTargets(accounts, ref.read(registryProvider), ref.read(settingsProvider));

  /// 1.4.3: [overrides] with the remembered Post / Story of each of [ids] that
  /// has no placement of its own ([withRememberedPlacements]).
  Map<String, PostOverrides> _withRememberedPlacements(Map<String, PostOverrides> overrides, Iterable<String> ids, {List<ConnectedAccount>? accounts}) =>
      withRememberedPlacements(overrides, ids, accounts ?? ref.read(accountListProvider), ref.read(registryProvider), ref.read(settingsProvider));

  /// 1.4.3: Post, Story or Post + Story for [accountId] on this post, chosen
  /// on its preview. The choice is remembered for the account: the next new
  /// post starts with it ([AppSettings.defaultPlacements]).
  void setPlacement(String accountId, PostPlacement placement) {
    final current = state.overrides[accountId] ?? const PostOverrides();
    final next = current.copyWith(extra: extraWithPlacement(current.extra, placement));
    state = state.copyWith(overrides: next.isEmpty ? ({...state.overrides}..remove(accountId)) : {...state.overrides, accountId: next});
    final remembered = ref.read(settingsProvider).defaultPlacements;
    final updated = withRememberedPlacement(remembered, accountId, placement);
    if (!mapEquals(remembered, updated)) {
      unawaited(ref.read(settingsProvider.notifier).update((s) => s.copyWith(defaultPlacements: withRememberedPlacement(s.defaultPlacements, accountId, placement))));
    }
  }

  /// The main text. Paragraph links move along with their paragraphs.
  void setText(String v) => state = state.copyWith(
        text: v,
        paragraphMedia: state.paragraphMedia.isEmpty ? null : ParagraphMedia.remap(state.text, v, state.paragraphMedia),
      );

  /// 1.4.3: links file [mediaId] to paragraph [paragraph] (from 0) of the
  /// text, or unlinks it when it already is. A file belongs to one paragraph:
  /// linking it here takes it from the paragraph it had. A paragraph's files
  /// keep the order of the attachments.
  void toggleParagraphMedia(int paragraph, String mediaId) {
    final own = state.paragraphMedia[paragraph] ?? const <String>[];
    final ids = own.contains(mediaId) ? own.where((id) => id != mediaId).toSet() : {...own, mediaId};
    final order = [for (final m in state.media) m.id];
    state = state.copyWith(
      paragraphMedia: ParagraphMedia.link(state.paragraphMedia, paragraph, [for (final id in order) if (ids.contains(id)) id]),
    );
  }

  /// 1.4.3: removes every paragraph link.
  void clearParagraphMedia() => state = state.copyWith(paragraphMedia: const {});

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

  /// "White on black" or "Black on white": the theme's colours, so colours
  /// of the card's own ([TextCardStyle]) go.
  void setTextCardTheme(TextCardTheme t) {
    // On a plain card a @handle colour that would vanish on the new theme
    // goes too (1.3.5).
    final style = state.textCardStyle.withoutColours();
    state = state.copyWith(textCardTheme: t, textCardStyle: state.textCardBackground == null ? _readableOn(style, t) : style);
  }

  /// 1.3.5: cards. The text card's style for every network.
  void setTextCardStyle(TextCardStyle style) => state = state.copyWith(textCardStyle: style);

  /// 1.3.5: cards. Where the words sit, top to bottom: one setting for the
  /// master editor and the background photo's "Words" controls
  /// ([textCardWordsPosition]). A place the photo chose before 1.3.5 is
  /// folded into it, so the two never disagree.
  void setTextCardWordsPosition(TextCardTextPosition position) {
    final photo = TextCardBackground.tryParse(state.textCardBackground);
    state = state.copyWith(
      textCardStyle: state.textCardStyle.copyWith(textPosition: position),
      textCardBackground: photo != null && photo.textPosition != TextCardTextPosition.center
          ? photo.copyWith(textPosition: TextCardTextPosition.center).toJson()
          : null,
    );
  }

  /// 1.3.5: cards. The words' own colour (opaque ARGB) for every network,
  /// set in the master editor or with the photo's "Other…": null for the
  /// theme's, or over a photo white or black, whichever reads. A white or
  /// black the photo chose is folded in, so the last change wins
  /// ([textCardWordsColour]).
  void setTextCardWordsColour(int? argb) {
    final photo = TextCardBackground.tryParse(state.textCardBackground);
    final style = state.textCardStyle;
    state = state.copyWith(
      textCardStyle: argb == null ? style.copyWith(clearTextColor: true) : style.copyWith(textColor: argb),
      textCardBackground: photo != null && photo.textColor != TextCardTextColor.automatic ? photo.copyWith(textColor: TextCardTextColor.automatic).toJson() : null,
    );
  }

  /// 1.3.5: cards. The background photo's own words colour (Automatic,
  /// White or Black, as before 1.3.5): it goes with the photo, and clears a
  /// words colour of the style's so the last change wins. Without a photo
  /// it does nothing.
  void setTextCardPhotoWordsColour(TextCardTextColor colour) {
    final photo = TextCardBackground.tryParse(state.textCardBackground);
    if (photo == null) return;
    state = state.copyWith(textCardBackground: photo.copyWith(textColor: colour).toJson(), textCardStyle: state.textCardStyle.copyWith(clearTextColor: true));
  }
  /// A built-in font for the card's words (no installed or imported one).
  void setTextCardFont(TextCardFont f) => state = state.copyWith(textCardFont: f, textCardCustomFont: const {});

  /// 1.3.1: cards. An installed or imported font for the card's words; null
  /// for the built-in [ComposerState.textCardFont].
  void setTextCardCustomFont(CaptionFont? font) => state = state.copyWith(textCardCustomFont: font?.toJson() ?? const {});

  /// 1.3.1: cards. This post's text card design; null for the classic card.
  /// A design picked (in the designer, or a template) starts afresh: the
  /// text card editor's "Reset" has nothing to put back.
  void setTextCardDesign(CardDesign? design) =>
      state = state.copyWith(textCardDesign: design?.toJson() ?? const {}, clearTextCardDesignBeforeEdits: true);

  /// 1.3.5: cards. The design the text card editor's controls made from the
  /// post's design ([textCardDesignBeforeEdits] remembers the design before
  /// the first such change, or that the post followed the Settings
  /// default).
  void setTextCardDesignEdited(CardDesign design) => state = state.copyWith(
        textCardDesign: design.toJson(),
        textCardDesignBeforeEdits: state.textCardDesignBeforeEdits ?? {'design': state.textCardDesign},
      );

  /// 1.3.5: cards. The post was saved: what the editor changed is now the
  /// post's own design, with nothing to put back.
  void forgetTextCardDesignEdits() {
    if (state.textCardDesignBeforeEdits != null) state = state.copyWith(clearTextCardDesignBeforeEdits: true);
  }

  /// 1.3.5: cards. Puts back the design the editor's controls started from;
  /// a post that followed the Settings default follows it again.
  void resetTextCardDesignEdits() {
    final before = state.textCardDesignBeforeEdits;
    if (before == null) return;
    final design = before['design'];
    state = design is Map
        ? state.copyWith(textCardDesign: Map<String, dynamic>.from(design), clearTextCardDesignBeforeEdits: true)
        : state.copyWith(clearTextCardDesign: true, clearTextCardDesignBeforeEdits: true);
  }

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
  /// The card's background photo (TextCardBackground.toJson); null for the
  /// plain colour. Going back to the colour never leaves words the card
  /// cannot show (1.3.5): a words colour of the style's too close to the
  /// card's colour (a contrast under 3:1, such as black words picked for a
  /// light photo, now on a black card) goes back to the theme's.
  void setTextCardBackground(Map<String, dynamic>? background) {
    if (background != null) {
      state = state.copyWith(textCardBackground: background);
      return;
    }
    final theme = state.textCardTheme ?? ref.read(settingsProvider).textCardTheme;
    state = state.copyWith(clearTextCardBackground: true, textCardStyle: _readableOn(state.textCardStyle, theme));
  }

  /// [style] with its words and @handle colours that would not read on the
  /// plain card of [theme] (a contrast under 3:1 with the card's colour) put
  /// back: the words to the theme's, the @handle to the words' (faded).
  /// What is left is always legible, whatever was picked for a photo.
  static TextCardStyle _readableOn(TextCardStyle style, TextCardTheme theme) {
    final card = style.backgroundColorOr(theme.background);
    bool unreadable(int? argb) => argb != null && textCardContrast(Color(argb), card) < 3;
    return style.copyWith(clearTextColor: unreadable(style.textColor), clearHandleColor: unreadable(style.handleColor));
  }
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

  /// 1.4.3: thread media. Moves thread part [from] to position [to] (both
  /// from 0, the first part included), with its words and its media: every
  /// attachment stays with the part it was in. The editors take the new
  /// order from the revision this bumps. Out-of-range moves do nothing.
  void movePart(int from, int to) {
    final texts = [state.text, ...state.additionalParts];
    if (from < 0 || from >= texts.length || to < 0 || to >= texts.length || from == to) return;
    // order[new position] = old position.
    final order = [for (var i = 0; i < texts.length; i++) i]
      ..removeAt(from)
      ..insert(to, from);
    final positionOf = {for (var i = 0; i < order.length; i++) order[i]: i};
    final last = texts.length - 1;
    final mediaParts = <String, int>{};
    for (final id in {for (final m in state.media) m.id, ...state.mediaParts.keys}) {
      final moved = positionOf[state.partOfMedia(id).clamp(0, last)]!;
      if (moved > 0) mediaParts[id] = moved;
    }
    final reordered = [for (final i in order) texts[i]];
    state = state.copyWith(
      text: reordered.first,
      additionalParts: reordered.skip(1).toList(),
      mediaParts: mediaParts,
      revision: state.revision + 1,
    );
  }

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
      // Targets that follow the post follow the new one.
      automaticTargets: state.automaticTargets,
      targetChoices: state.targetChoices,
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
  /// [mediaIds], the attachments the part had, go back into it (1.4.3);
  /// those removed since stay removed.
  bool undoRemovePart(int index, String text, {required int revision, List<String> mediaIds = const []}) {
    if (index < 1 || state.revision != revision) return false;
    final at = (index - 1).clamp(0, state.additionalParts.length);
    final parts = [...state.additionalParts]..insert(at, text);
    final attached = {for (final m in state.media) m.id};
    state = state.copyWith(additionalParts: parts, mediaParts: {
      ..._shiftParts(state.mediaParts, from: at + 1, by: 1),
      for (final id in mediaIds)
        if (attached.contains(id)) id: at + 1,
    });
    return true;
  }

  /// Empties the post: every part, media, title, link, poll, content
  /// warning, tags and per-network versions. Keeps the targets, the schedule,
  /// each network's Post / Story (1.4.3), artwork mode and which saved post
  /// is being edited.
  void clearPost() {
    state = ComposerState(
      editingPostId: state.editingPostId,
      visibility: ref.read(settingsProvider).defaultVisibility,
      selected: state.selected,
      // Targets that follow the post follow the empty one: the accounts
      // NEFORUM added for its video go with it.
      automaticTargets: state.automaticTargets,
      targetChoices: state.targetChoices,
      scheduledAt: state.scheduledAt,
      // The times per network are part of the schedule.
      overrides: {
        for (final e in state.overrides.entries)
          if (e.value.scheduledAt != null || hasOwnPlacement(e.value))
            e.key: placementOnly(e.value).copyWith(scheduledAt: e.value.scheduledAt),
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

  /// Attaches [items] to thread part [part] (0, the first, by default; a
  /// part past the last goes to the last).
  void addMedia(Iterable<MediaAttachment> items, {int part = 0}) {
    final added = items.toList();
    if (added.isEmpty) return;
    final into = part.clamp(0, state.additionalParts.length);
    state = state.copyWith(
      media: [...state.media, ...added],
      mediaParts: into == 0 ? null : {...state.mediaParts, for (final m in added) m.id: into},
    );
  }

  /// 1.4.3: thread media. Moves an attachment within the tray of thread part
  /// [part]: [from] and [to] are positions among that part's own media
  /// ([ComposerState.mediaOfPart]; [to] already adjusted for the removed
  /// item, as ReorderableListView.onReorderItem reports it). The media of
  /// the other parts keeps its place.
  void moveMediaInPart(int part, int from, int to) {
    final own = state.mediaOfPart(part);
    if (from < 0 || from >= own.length) return;
    final reordered = [...own];
    reordered.insert(to.clamp(0, own.length - 1), reordered.removeAt(from));
    final slots = {for (final m in own) m.id};
    var next = 0;
    state = state.copyWith(media: [
      for (final m in state.media) slots.contains(m.id) ? reordered[next++] : m,
    ]);
  }

  /// The user's track details over the own tags of the sound file
  /// [mediaId]; null or empty goes back to the file's tags. Each sound file
  /// has details of its own.
  void setAudioDetails(String mediaId, AudioTags? details) => state = state.copyWith(
        audioDetails: details == null || details.isEmpty ? ({...state.audioDetails}..remove(mediaId)) : {...state.audioDetails, mediaId: details},
      );

  /// Writes the post text from the track details of the sound file
  /// [mediaId] (the first one when null) with [template]
  /// ([renderAudioText]), when the text is still empty. False when there is
  /// nothing to write (text already there, no sound file, no details).
  bool useTrackDetailsAsText(String template, {String? mediaId}) {
    final tags = mediaId == null ? state.effectiveAudioTags : state.effectiveAudioTagsOf(mediaId);
    if (tags == null || state.text.trim().isNotEmpty) return false;
    final text = renderAudioText(template, tags);
    if (text.isEmpty) return false;
    prefill(text);
    return true;
  }

  void removeMedia(String mediaId) {
    state = state.copyWith(
      // The track details go with the sound file they describe.
      audioDetails: state.audioDetails.containsKey(mediaId) ? ({...state.audioDetails}..remove(mediaId)) : null,
      media: state.media.where((m) => m.id != mediaId).toList(),
      mediaParts: {...state.mediaParts}..remove(mediaId),
      paragraphMedia: ParagraphMedia.withoutMedia(state.paragraphMedia, mediaId),
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
    // A paragraph's files follow the attachments' order.
    final order = {for (final (i, m) in list.indexed) m.id: i};
    state = state.copyWith(media: list, paragraphMedia: {
      for (final e in state.paragraphMedia.entries) e.key: [...e.value]..sort((a, b) => (order[a] ?? 0).compareTo(order[b] ?? 0)),
    });
  }

  void setAltText(String mediaId, String alt) => state = state.copyWith(
        media: [for (final m in state.media) m.id == mediaId ? m.copyWith(altText: alt, clearAltText: alt.isEmpty) : m],
      );

  /// Ticks or unticks [accountId] by hand. While the targets follow the post
  /// the choice is kept: NEFORUM never takes away an account ticked by hand,
  /// nor adds back one unticked by hand.
  ///
  /// An account added to the post starts with its remembered Post / Story
  /// (1.4.3), unless this post already chose one for it.
  void toggleAccount(String accountId) {
    final s = {...state.selected};
    final on = !s.remove(accountId);
    if (on) s.add(accountId);
    state = state.copyWith(
      selected: s,
      overrides: on ? _withRememberedPlacements(state.overrides, [accountId]) : null,
      targetChoices: state.automaticTargets ? {...state.targetChoices, accountId: on ? TargetChoice.ticked : TargetChoice.unticked} : null,
    );
  }

  /// Exactly [ids], chosen as a whole: the targets no longer follow the post.
  /// See [toggleAccount] for the accounts this adds.
  void selectAccounts(Iterable<String> ids) {
    final selected = ids.toSet();
    state = state.copyWith(
      selected: selected,
      overrides: _withRememberedPlacements(state.overrides, selected.difference(state.selected)),
      automaticTargets: false,
      targetChoices: const {},
    );
  }

  /// "Automatic only": the automatic accounts whose rules take the post as it
  /// is ([automaticSkipReason]); the others are left out, with the reason on
  /// their cell. From then on the targets follow the post
  /// ([ComposerState.automaticTargets]).
  ///
  /// With [among] (the accounts the picker's filter shows) only those are
  /// chosen again, and the others stay as they are, as if set by hand.
  void selectAutomatic({Iterable<String>? among}) {
    final scope = among?.toSet();
    final registry = ref.read(registryProvider);
    final settings = ref.read(settingsProvider);
    final accounts = ref.read(accountListProvider);
    final selected = <String>{};
    final choices = <String, TargetChoice>{};
    if (scope != null) {
      selected.addAll(state.selected.difference(scope));
      for (final a in accounts) {
        if (!scope.contains(a.id)) choices[a.id] = selected.contains(a.id) ? TargetChoice.ticked : TargetChoice.unticked;
      }
    }
    for (final a in automaticTargetCandidates(accounts, registry, artwork: state.isArtwork)) {
      if (scope != null && !scope.contains(a.id)) continue;
      if (state.skipReasonFor(a, registry, settings) != null) continue;
      selected.add(a.id);
      choices[a.id] = TargetChoice.automatic;
    }
    state = state.copyWith(
      selected: selected,
      // An account this adds starts with its remembered Post / Story (1.4.3).
      overrides: _withRememberedPlacements(state.overrides, selected.difference(state.selected)),
      automaticTargets: true,
      targetChoices: choices,
    );
  }

  void setOverride(String accountId, PostOverrides o) =>
      state = state.copyWith(overrides: {...state.overrides, accountId: o});

  /// Back to the main post for [accountId]. Its Post / Story stays: it is
  /// chosen on the preview, not by customizing (1.4.3).
  void clearOverride(String accountId) {
    final kept = placementOnly(state.overrides[accountId] ?? const PostOverrides());
    state = state.copyWith(overrides: kept.isEmpty ? ({...state.overrides}..remove(accountId)) : {...state.overrides, accountId: kept});
  }

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
        paragraphMedia: p.paragraphMedia, // 1.4.3
        audioDetails: p.audioDetails,
        textCardCustomFont: textCardCustomFontOfPost(post), // 1.3.1: cards
        textCardDesign: textCardDesignOfPost(post), // 1.3.1: cards
        audioCardDesign: audioCardDesignOfPost(post), // 1.3.1: cards
        textCardStyle: textCardStyleOfPost(post) ?? TextCardStyle.classic, // 1.3.5: cards
      );
  }

  /// Puts back a post that was being written when NEFORUM closed
  /// (composer_draft.dart).
  /// The post it edited may have gone out since it was kept: it then comes back
  /// as a new post.
  void restore(ComposerState kept) {
    state = kept.copyWith(revision: state.revision + 1);
    final posts = ref.read(postsProvider).value;
    if (posts != null) _forgetPostThatWentOut(posts);
  }

  /// Starts over with the same targets. Kept art sites keep artwork mode on,
  /// with the artwork details back at their defaults. Kept targets that
  /// follow the post (Automatic only) follow the next one, with the choices
  /// made by hand.
  void reset({bool keepTargets = true}) {
    final fresh = _fresh();
    final selected = keepTargets ? state.selected : fresh.selected;
    state = fresh.copyWith(
      selected: selected,
      // 1.4.3: the new post starts with each account's remembered Post / Story.
      overrides: _withRememberedPlacements(const {}, selected),
      artwork: keepTargets && state.isArtwork ? newArtworkDetails(ref.read(settingsProvider)) : null,
      revision: state.revision + 1,
      automaticTargets: keepTargets && state.automaticTargets,
      targetChoices: keepTargets ? state.targetChoices : const {},
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
      paragraphMedia: state.paragraphMedia, // 1.4.3
      audioDetails: state.audioDetails,
      textCardCustomFont: state.textCardCustomFont, // 1.3.1: cards
      textCardDesign: state.textCardDesign, // 1.3.1: cards
      audioCardDesign: state.audioCardDesign, // 1.3.1: cards
      textCardStyle: state.textCardStyle, // 1.3.5: cards
    );
  }
}

final composerProvider = NotifierProvider<ComposerNotifier, ComposerState>(ComposerNotifier.new);

/// 1.4.3: while the targets follow the post (Automatic only), why each
/// automatic account left out cannot take the post ("Needs a video"), by
/// account id, for its cell in "Post to". Empty otherwise.
final automaticSkipReasonsProvider = Provider<Map<String, String>>((ref) {
  // Only what the reasons depend on: not every letter typed.
  final on = ref.watch(composerProvider.select((c) => c.automaticTargets
      ? (c.selected, c.media, c.overrides, c.joinedParts.trim().isNotEmpty, c.isArtwork)
      : null));
  if (on == null) return const {};
  final c = ref.read(composerProvider);
  final registry = ref.watch(registryProvider);
  final settings = ref.watch(settingsProvider);
  return {
    for (final a in automaticTargetCandidates(ref.watch(accountListProvider), registry, artwork: c.isArtwork))
      if (!c.selected.contains(a.id)) a.id: ?c.skipReasonFor(a, registry, settings),
  };
});

/// Live per-target previews of what each platform will receive.
final composerPreviewsProvider = Provider<List<TargetPreview>>((ref) {
  final c = ref.watch(composerProvider);
  final accounts = ref.watch(accountListProvider);
  final registry = ref.watch(registryProvider);
  final settings = ref.watch(settingsProvider);
  final resolver = VariantResolver(settings.resolverOptions);
  final now = DateTime.now();
  var post = c.toPost(id: 'preview', status: PostStatus.draft, now: now);
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
  // 1.3.5: cards. A written @handle gets a block on a design without one.
  final designOwn = c.textDesign(settings);
  final cardDesign = designOwn == null ? null : designWithHandle(designOwn, c.textCardStyle.handle);
  final cardFontMissing = settings.textCards && cardFont != null && ref.watch(captionFontReadyProvider(cardFont)).value == false;
  final cardFontFamily = cardFont?.family ?? '';
  // 1.4: fonts. A font from the font list can be fetched from the picker.
  final cardFontHelp = cardFont?.source != null && settings.fontDownloads != FontDownloadMode.off
      ? 'Choose More fonts to download $cardFontFamily.'
      : 'Install or import $cardFontFamily here to use it.';
  // 1.4.1: a network where the card is a choice (YouTube Posts) takes the
  // post's card when another selected network gets one.
  var postMakesCard = false;
  if (settings.textCards) {
    for (final a in accounts) {
      if (!c.selected.contains(a.id) || kTextCardChoicePlatforms.contains(a.platformId)) continue;
      final adapter = registry.byId(a.platformId);
      if (adapter == null) continue;
      final d = adapter.descriptorForAccount(a);
      final v = resolver.resolve(post, withMentionDefault(post.targetFor(a.id)!, a.platformId, settings), d, account: a);
      final placement = adapter.supportsStories(a) ? v.placement : PostPlacement.feed;
      if ((placement.includesStory && storyQualifiesForTextCard(d, v, backgroundMediaId: backgroundPhotoId)) ||
          (placement != PostPlacement.story && qualifiesForTextCard(d, v, backgroundMediaId: backgroundPhotoId, everyNetwork: everyNetwork))) {
        postMakesCard = true;
        break;
      }
    }
  }
  // 1.4.3: cards. **Bold** and *italic* drawn on the classic card leave the
  // words of networks without Markdown, as they will when the post is saved
  // (attachTextCards, withCardEmphasis).
  final cardChosen = post.targets.any((t) => c.selected.contains(t.accountId) && textCardChoiceOf(t.overrides.extra) == TextCardChoice.card);
  final emphasisOnCard = settings.textCards &&
      cardDesign == null &&
      (postMakesCard || cardChosen) &&
      post.targets.any((t) => c.selected.contains(t.accountId) && hasEmphasis(textCardText(post, t)));
  post = withCardEmphasis(post, marked: emphasisOnCard);
  // 1.4.3: cards. The classic card's shape; a design draws at each
  // network's own.
  final cardShape = cardDesign == null ? c.textCardStyle.shape : TextCardShape.automatic;
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
        qualifiesForTextCard(d, variant, backgroundMediaId: backgroundPhotoId, everyNetwork: everyNetwork, postMakesCard: postMakesCard);
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
            // 1.3.5: cards. The post's style, and the @handle written in
            // place of the network's own: recorded only then, so a stand-in
            // for an untouched card has the parameters 1.3.4 gave it (the
            // previews draw the network's own @handle without it).
            byline: c.textCardStyle.handle,
            style: c.textCardStyle,
            // 1.4.3: cards. The picture this network gets for the shape.
            size: textCardFrameFor(adapter, a, variant, settings, story: story, shape: cardShape),
          ).copyWith(altText: textCardAltText(textCardText(post, target), attribution: cardDesign == null ? c.textCardStyle.attribution : null));
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
          'media.text_card',
          '$what ${signed ? 'a NEFORUM' : 'a plain'} text card${background == null ? '' : ' over your photo'}'
          // 1.4.1: where the card is a choice, say how to send the words alone.
          '${feedCard && kTextCardChoicePlatforms.contains(d.id) ? ' (Customize: text only)' : ''}',
          field: 'media'));
      if (cardFontMissing) {
        issues.add(ValidationIssue.info(
            'media.text_card_font_missing',
            'The font $cardFontFamily is not on this device, so the card uses ${(c.textCardFont ?? settings.textCardFont).label}. '
            '$cardFontHelp',
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
    // Disabled in Accounts, still in the selection of an old draft: publishing
    // skips it, so it is not one of the accounts this post goes to.
    if (!p.account.enabled) continue;
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

/// The clock [PostActions.schedule] and the schedule sheet judge a time by.
/// Replaced in tests.
final scheduleClockProvider = Provider<Clock>((ref) => systemClock);

/// The post's time, or a network's, is past or under a minute ahead: scheduling
/// it would send it at once. Nothing was saved.
class SchedulePassedException implements Exception {
  const SchedulePassedException();

  @override
  String toString() => 'SchedulePassedException';
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

  /// The saved post the composer edits, while the composer may still save over
  /// it ([isEditablePost]). Null for a new post, and for one that went out, is
  /// going out, failed in a run or was deleted since it was opened: its record is
  /// that run's, and words written over it are a new post.
  Future<Post?> _editedPost(ComposerState c) async {
    final id = c.editingPostId;
    if (id == null) return null;
    final post = await ref.read(servicesProvider).posts.get(id);
    return isEditablePost(post) ? post : null;
  }

  /// Saves the composer's post with [status]: over the post it edits while that
  /// can still be edited ([_editedPost]), otherwise as a new post, under [id]
  /// when given. Throws [EditedPostPublishedException], and saves nothing, when
  /// [id] is the edited post's and that post went out since [id] was chosen.
  Future<Post> _save(PostStatus status, {String? id}) async {
    final s = ref.read(servicesProvider);
    final c = ref.read(composerProvider);
    final now = DateTime.now();
    final edited = await _editedPost(c);
    final postId = id ?? edited?.id ?? _uuid.v7();
    if (edited == null && postId == c.editingPostId && await s.posts.get(postId) != null) throw const EditedPostPublishedException();
    // Only the post being edited is saved over, and only its own outcomes stay.
    final existing = edited?.id == postId ? edited : null;
    if (existing != null) await _releaseHeld(existing.id);
    var post = c.toPost(id: postId, status: status, now: now, createdAt: existing?.createdAt);
    // Networks that already have an edited post (the earlier times of a post
    // with a time per network) keep their outcome, so they never get it twice.
    // Never those of a post that went out: the new words would go nowhere and be
    // recorded as posted with that post's links.
    final current = existing == null ? null : await s.posts.get(existing.id);
    if (existing != null && !isEditablePost(current)) throw const EditedPostPublishedException();
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
        platformOf: (id) => accounts.where((a) => a.id == id).firstOrNull?.platformId,
        style: c.textCardStyle);
    // 1.3.1: cards. After the card choices, which replace the targets' extras.
    post = withCardDesigns(post, text: c.textCardDesign, audio: c.audioCardDesignToSave(ref.read(settingsProvider)));
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
        design: c.textCardDesign,
        cardStyle: c.textCardStyle);
    post = await attachFittedPhotos(s, post, ref.read(settingsProvider));
    post = await attachCaptionedPhotos(s, post, ref.read(settingsProvider), choices: c.captionOnPhoto, style: c.captionStyle);
    post = await attachAudioRenditions(s, post, ref.read(settingsProvider));
    // 1.3: video. A scheduled post gets its smaller copies of videos now,
    // while this device has a compositor: a background run has none and only
    // reuses them. Publishing now makes them in the run, with progress.
    if (status == PostStatus.scheduled) post = await attachShrunkVideos(s, post, ref.read(settingsProvider));
    await s.posts.upsert(post);
    // 1.3.5: cards. Saved: the text card editor's design changes are the post's.
    ref.read(composerProvider.notifier).forgetTextCardDesignEdits();
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
  ///
  /// Throws [SchedulePassedException], and saves nothing, when a network still
  /// to go has a time that has passed: the scheduler would send it at once. A
  /// composer can hold such a time for as long as its draft stays open.
  Future<Post> schedule() async {
    final c = ref.read(composerProvider);
    // A post that went out since it was opened is scheduled as a new one, every
    // network included ([_save]).
    final existing = await _editedPost(c);
    final now = ref.read(scheduleClockProvider)();
    for (final id in c.selected) {
      if (existing?.targetFor(id)?.isDone ?? false) continue;
      final at = c.overrides[id]?.scheduledAt ?? c.scheduledAt;
      if (at != null && !scheduleTimeAccepted(at, now)) throw const SchedulePassedException();
    }
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
  ///
  /// The post's id is the edited post's only while that post can still be
  /// edited ([isEditablePost]). Words written over a post that went out since it
  /// was opened are a new post: saved over it, they would keep its networks'
  /// outcomes, go to no network and be recorded as posted with its links.
  Future<Post> publishNow() async {
    final run = ref.read(publishRunProvider.notifier);
    run.prepare();
    final s = ref.read(servicesProvider);
    final c = ref.read(composerProvider);
    final guess = c.editingPostId ?? _uuid.v7();
    // At once, while the app is on screen: it is the one time Android lets it begin.
    final keeper = ref.read(publishRunKeeperProvider)..begin(guess);
    var id = guess;
    try {
      if (c.editingPostId != null && await _editedPost(c) == null) {
        id = _uuid.v7();
        // The new post's hold first, so the keep-alive never lapses between them.
        keeper.begin(id);
        unawaited(keeper.end(guess));
      }
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
      return await publishExisting(p.id, accountIds: c.selected);
    } finally {
      unawaited(keeper.end(id));
    }
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
    // At the tap, while NEFORUM is in front: Android only lets a visible app begin,
    // and that is when iOS gives time. Before anything is awaited, so a Cancel on
    // the notification finds the run at once.
    final keeper = ref.read(publishRunKeeperProvider)..begin(postId);
    final surface = ref.read(publishSurfaceProvider.notifier);
    PublishRunSession? session;
    final figures = ref.read(publishProgressProvider.notifier);
    // One tracker: the sheet and Activity read its figures, and the run's session,
    // which words them for Android's notification and iOS's Live Activity.
    final tracker = figures.begin(postId, onChange: (p) => session?.progress(p));
    Post? before;
    try {
      final networks = await _hostNetworks(postId, accountIds: accountIds, dueTargetsOnly: dueTargetsOnly);
      session = surface.start(postId, title: publishSurfaceTitle(networks.length), networks: networks);
      before = await ref.read(servicesProvider).posts.get(postId);
      return await _publishExisting(postId, signal, tracker, session, accountIds: accountIds, retryFailed: retryFailed, dueTargetsOnly: dueTargetsOnly);
    } on Object catch (e) {
      await ref.read(servicesProvider).concludeStoppedRun(postId, e);
      run.fail(postId, e);
      await session?.finish(null, error: '$e');
      if (before != null) await _announceStoppedRun(before);
      rethrow;
    } finally {
      if (session != null) {
        surface.remove(postId, session);
        // A run that ended some other way still lets its hold go.
        if (!session.isEnded) unawaited(session.finish(null, error: 'ended'));
      }
      active.end(postId, signal);
      figures.end(postId, tracker);
      unawaited(keeper.end(postId));
    }
  }

  /// The networks a run will post to: names and sizes, never the post's words.
  Future<List<PublishHostNetwork>> _hostNetworks(String postId, {Set<String>? accountIds, required bool dueTargetsOnly}) async {
    final s = ref.read(servicesProvider);
    final out = <PublishHostNetwork>[];
    try {
      final post = await s.posts.get(postId);
      if (post == null) return out;
      final bytes = post.media.fold<int>(0, (sum, m) => sum + m.sizeBytes);
      final now = DateTime.now();
      // 1.4.3: listed in the publishing order, as the run goes.
      for (final t in await s.publisher().targetsInPublishingOrder(post)) {
        if (t.isDone || (accountIds != null && !accountIds.contains(t.accountId)) || (dueTargetsOnly && !post.isTargetDue(t, now))) continue;
        final a = await s.accounts.get(t.accountId);
        final d = a == null ? null : s.registry.descriptor(a.platformId);
        if (d != null) out.add(PublishHostNetwork(id: t.accountId, name: d.name, bytes: bytes));
      }
    } on Object catch (e) {
      debugPrint('Could not list the networks of $postId: ${e.runtimeType}');
    }
    return out;
  }

  Future<Post> _publishExisting(String postId, CancellationSignal signal, PublishProgressTracker tracker, PublishRunSession session,
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
    // 1.4.3: in the publishing order, so the sheet's rows are in it before the plan.
    final inOrder = await s.publisher().targetsInPublishingOrder(due);
    final starting = accountIds == null
        ? {for (final t in inOrder) if (!dueTargetsOnly || due.isTargetDue(t, now)) t.accountId}
        : {for (final t in inOrder) if (accountIds.contains(t.accountId)) t.accountId, ...accountIds};
    run.start(postId, starting);
    // What the last run said about these networks is out of date now.
    await NotificationService.instance.cancelResults(postId, starting);
    // 1.3: video. Videos too big for a network get their smaller copy now,
    // with its progress on that network's row.
    final keeper = ref.read(publishRunKeeperProvider);
    post = await attachShrunkVideos(s, post, ref.read(settingsProvider),
        onProgress: (accountId, message) {
          run.progress(accountId, message);
          keeper.alive(postId);
        },
        cancellation: signal,
        onlyAccountIds: starting);
    await s.posts.upsert(post);
    final done = await s.publisher().publish(
          postId,
          interactive: true,
          onlyAccountIds: accountIds,
          retryFailed: retryFailed,
          onPlan: (plan) {
            tracker.plan(plan);
            keeper.planned(postId, plan);
          },
          onEvent: tracker.event,
          onOutcome: tracker.outcome,
          cancellation: signal,
          dueTargetsOnly: dueTargetsOnly,
          pause: session.pause,
        );
    final finalPost = await s.applySkips(postId) ?? done;
    run.finish(finalPost);
    await session.finish(tracker.current, unknown: {
      for (final t in finalPost.targets)
        if (t.result?.error?.outcomeUnknown == true) t.accountId,
    });
    try {
      // Networks still waiting for their own time keep their reminder.
      final next = finalPost.scheduledAt;
      if (finalPost.status == PostStatus.scheduled && finalPost.schedulesEachTarget && next != null && next.isAfter(DateTime.now())) {
        await ref.read(schedulerProvider).planReminders(finalPost);
      } else {
        await ref.read(schedulerProvider).cancelReminders(finalPost);
      }
      // In this order: deleting a post removes its notifications.
      final discarded = await _discardIfComplete(postId);
      await announcePublishResult(s, finalPost, discarded: discarded, delivery: _tappedDelivery(), onlyAccountIds: starting);
      await ref.read(notificationAccessProvider.notifier).refresh();
    } on Object catch (e) {
      // The post went out; tidying up afterwards must not look like a failure.
      debugPrint('After publishing $postId: $e');
    }
    return finalPost;
  }

  /// Asks the run publishing [postId] in this process to stop.
  void cancelPublishing(String postId) => cancelPublishRun(ref, postId);

  /// What the composer mentions, so deleting a post never takes a file the
  /// composer still shows (a duplicated post shares its photos).
  List<Object?> _composerReferences() {
    final c = ref.read(composerProvider);
    return [c.toPost(id: 'composer', status: PostStatus.draft, now: DateTime.now()).toJson(), c.captionStyle, c.textCardBackground];
  }

  /// Deletes [postId] once every network has it, when the setting keeps
  /// nothing after posting. True when it was deleted.
  Future<bool> _discardIfComplete(String postId) async {
    final discarded = await ref.read(servicesProvider).discardIfComplete(postId, inUse: _composerReferences());
    if (discarded) ref.read(schedulerProvider).updateTrayStatus();
    return discarded;
  }

  /// Who is watching as a run started from the app ends.
  RunEndDelivery _tappedDelivery() =>
      tappedRunDelivery(sheetOpen: ref.read(publishSheetOpenProvider) > 0, lifecycle: WidgetsBinding.instance.lifecycleState);

  /// A run that stopped with an error instead of an outcome: told about like
  /// any other when nobody is watching the sheet. Best effort.
  /// Only the networks the stopped run changed: a run refused before it
  /// started says nothing new about the others.
  Future<void> _announceStoppedRun(Post before) async {
    try {
      final s = ref.read(servicesProvider);
      final post = await s.posts.get(before.id);
      if (post == null || post.status == PostStatus.publishing) return;
      await announcePublishResult(s, post, delivery: _tappedDelivery(), onlyAccountIds: targetsChangedByRun(before, post));
    } on Object catch (e) {
      debugPrint('Could not announce the stopped run of ${before.id}: $e');
    }
  }

  /// Hand-off for one target, triggered from a list or a notification.
  /// The last hand-off of a post can complete it (see [_discardIfComplete]).
  Future<Post> runHandoff(String postId, String accountId) async {
    final s = ref.read(servicesProvider);
    final p = await s.publisher().runHandoff(postId, accountId);
    final done = await s.applySkips(postId) ?? p;
    if (done.targetFor(accountId)?.status != TargetStatus.awaitingHandoff) await NotificationService.instance.cancel('handoff:$postId:$accountId');
    await _discardIfComplete(postId);
    return done;
  }

  Future<Post> markHandedOff(String postId, String accountId, {bool done = true}) async {
    final p = await ref.read(servicesProvider).publisher().confirmHandoff(postId, accountId, completed: done);
    await NotificationService.instance.cancel('handoff:$postId:$accountId');
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

}
final postActionsProvider = Provider<PostActions>(PostActions.new);
