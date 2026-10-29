import 'package:flutter/material.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../media/text_card.dart';
import '../platform/update_check.dart';
import '../theme/tokens.dart';
import '../theme/zoom.dart';

/// Networks whose terms explicitly forbid scripting their website: automatic
/// hand-off posting stays off for them unless the user removes them from the
/// exclusion list.
const kAutomationRestrictedPlatforms = ['x', 'linkedin', 'snapchat'];

/// Networks whose hand-off pages the NEFORUM browser extension fills in by
/// itself (its content scripts run on their sites: kExtensionPageHosts), so
/// automatic posting can apply to them. On other sites (blogs, Mastodon and
/// Misskey servers, Telegram...) no page could ever report back.
const kAutomaticPostingPlatforms = {
  'x', 'bluesky', 'threads', 'linkedin', 'facebook', 'youtube_posts', 'youtube', 'substack', //
  'tiktok', 'instagram', 'pinterest', 'reddit', 'tumblr', 'whatsapp', 'google_business', 'snapchat', //
  'behance', 'artstation', 'cara', 'pixiv', 'itaku', 'newgrounds', 'furaffinity', 'weasyl', //
  'kofi', 'artfol', 'fivehundredpx', 'dribbble', 'flickr',
};

/// A stored phone text size that can be used: 0.85 to 1.5, 1 otherwise.
double validTextScale(Object? scale) {
  if (scale is! num || !scale.isFinite) return 1;
  return scale.toDouble().clamp(0.85, 1.5);
}

/// The strongest blur of the background picture (Gaussian sigma in logical
/// pixels).
const double kMaxBackgroundBlur = 40;

/// The background picture's dim when none is stored.
const double kDefaultBackgroundDim = 0.4;

/// A stored background blur that can be used: 0 to [kMaxBackgroundBlur], 0
/// otherwise.
double validBackgroundBlur(Object? blur) {
  if (blur is! num || !blur.isFinite) return 0;
  return blur.toDouble().clamp(0, kMaxBackgroundBlur);
}

/// A stored background dim that can be used: 0 to 1, [kDefaultBackgroundDim]
/// otherwise.
double validBackgroundDim(Object? dim) {
  if (dim is! num || !dim.isFinite) return kDefaultBackgroundDim;
  return dim.toDouble().clamp(0, 1);
}

/// What happens to a post once every network has it (published, handed off
/// or skipped).
enum PublishedPostRetention {
  /// Delete the post and its media files right away.
  discardOnCompletion,
  retainSevenDays,
  retainThirtyDays,
  retainIndefinitely,
}

/// How Activity, the Queue and post details show times.
enum TimestampDisplay {
  /// "5 min ago", "Yesterday".
  relative,

  /// Weekday, date and time: "Sunday, 25 October 2026, 14:05".
  exact,
}

enum ClockFormat { system, twelveHour, twentyFourHour }

/// How the words of a text card are lined up, as in a word processor.
enum TextCardAlignment {
  left,
  center,
  right,
  justify,

  /// Every line, the last one included, spread across the full width.
  distributed,
}

enum CornerStyle { rounded, square }

/// Color of the navigation sidebar, rail and phone tab bar.
enum NavigationChromeStyle {
  /// NEFORUM purple in every theme.
  brand,

  /// Light in the light theme, dark in the dark theme.
  theme,

  /// The accent color.
  accent,
}

enum InterfaceDensity { comfortable, compact }

/// Everything the user can change in Settings. Persisted as settings.json.
@immutable
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.accent = AccentChoice.neforum,
    this.overflow = OverflowStrategy.threadOrError,
    this.threadNumbering = true,
    this.appendHashtags = true,
    this.appendLink = true,
    this.fallbackToHandoff = true,
    this.confirmBeforePosting = false,
    this.defaultVisibility = PostVisibility.public,
    this.startAtLogin = false,
    this.minimizeToTray = true,
    this.notifyOnPublish = true,
    this.mediaHostId,
    this.mediaHostConfig = const {},
    this.fallbackMediaHostId,
    this.fallbackMediaHostConfig = const {},
    this.defaultTargetIds = const [],
    this.onboarded = false,
    this.compactPreviews = false,
    this.textCards = true,
    this.textCardTheme = TextCardTheme.dark,
    this.textCardFont = TextCardFont.original,
    this.textCardPlainPlatforms = const [],
    this.delegateSchedules = true,
    this.browserExtension = true,
    this.browserQuickPost = true,
    this.browserOpenInFirst = true,
    this.photoFit = PhotoFitMode.pad,
    this.fillFramePlatforms = const ['tiktok', 'instagram'],
    this.captionPhotoPlatforms = const [],
    this.movedAccountIds = const [],
    this.movedAt,
    this.syncProviderId,
    this.syncConfig = const {},
    this.uiZoom = 1,
    this.publishedPostRetention = PublishedPostRetention.discardOnCompletion,
    this.timestampDisplay = TimestampDisplay.relative,
    this.clockFormat = ClockFormat.system,
    this.discordMentionEveryone = true,
    this.textCardHandleHiddenPlatforms = const [],
    this.textCardAlignment = TextCardAlignment.left,
    this.captionStyle = const {},
    this.cornerStyle = CornerStyle.rounded,
    this.navigationChrome = NavigationChromeStyle.brand,
    this.customAccentColor,
    this.interfaceDensity = InterfaceDensity.comfortable,
    this.mobileTextScale = 1,
    this.collapsedSettingsSections = const [],
    this.automaticHandoffPosting = false,
    this.automaticHandoffExcludedPlatforms = kAutomationRestrictedPlatforms,
    this.advanceHandoffOnReturn = true,
    this.artworkMaturity = ArtworkMaturity.general,
    this.artworkDisallowAiTraining = true,
    // 1.3: video
    this.shrinkOversizedVideos = false,
    // 1.3: appearance
    this.backgroundImagePath,
    this.backgroundBlur = 0,
    this.backgroundDim = kDefaultBackgroundDim,
    // 1.3: updates
    this.updateCheck = UpdateCheckMode.ask,
    this.updateCheckedAt,
    this.updateLatestRelease = const {},
    this.updateDismissedVersion,
    this.textCardEveryNetwork = false, // 1.3: cards
    this.audioTextTemplate = kDefaultAudioTextTemplate, // 1.3.1: audio tags
  });

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        themeMode: ThemeMode.values.asNameMap()[j['themeMode']] ?? ThemeMode.system,
        accent: AccentChoice.values.asNameMap()[j['accent']] ?? AccentChoice.neforum,
        overflow: OverflowStrategy.values.asNameMap()[j['overflow']] ?? OverflowStrategy.threadOrError,
        threadNumbering: j['threadNumbering'] as bool? ?? true,
        appendHashtags: j['appendHashtags'] as bool? ?? true,
        appendLink: j['appendLink'] as bool? ?? true,
        fallbackToHandoff: j['fallbackToHandoff'] as bool? ?? true,
        confirmBeforePosting: j['confirmBeforePosting'] as bool? ?? false,
        defaultVisibility: PostVisibility.values.asNameMap()[j['defaultVisibility']] ?? PostVisibility.public,
        startAtLogin: j['startAtLogin'] as bool? ?? false,
        minimizeToTray: j['minimizeToTray'] as bool? ?? true,
        notifyOnPublish: j['notifyOnPublish'] as bool? ?? true,
        mediaHostId: j['mediaHostId'] as String?,
        mediaHostConfig: Map<String, String>.from(j['mediaHostConfig'] as Map? ?? const {}),
        fallbackMediaHostId: j['fallbackMediaHostId'] as String?,
        fallbackMediaHostConfig: Map<String, String>.from(j['fallbackMediaHostConfig'] as Map? ?? const {}),
        defaultTargetIds: (j['defaultTargetIds'] as List? ?? const []).cast<String>(),
        onboarded: j['onboarded'] as bool? ?? false,
        compactPreviews: j['compactPreviews'] as bool? ?? false,
        textCards: j['textCards'] as bool? ?? true,
        textCardTheme: TextCardTheme.values.asNameMap()[j['textCardTheme']] ?? TextCardTheme.dark,
        textCardFont: TextCardFont.values.asNameMap()[j['textCardFont']] ?? TextCardFont.original,
        textCardPlainPlatforms: (j['textCardPlainPlatforms'] as List? ?? const []).cast<String>(),
        delegateSchedules: j['delegateSchedules'] as bool? ?? true,
        browserExtension: j['browserExtension'] as bool? ?? true,
        browserQuickPost: j['browserQuickPost'] as bool? ?? true,
        browserOpenInFirst: j['browserOpenInFirst'] as bool? ?? true,
        photoFit: PhotoFitMode.values.asNameMap()[j['photoFit']] ?? PhotoFitMode.pad,
        fillFramePlatforms: (j['fillFramePlatforms'] as List? ?? const ['tiktok', 'instagram']).cast<String>(),
        captionPhotoPlatforms: (j['captionPhotoPlatforms'] as List? ?? const []).cast<String>(),
        movedAccountIds: (j['movedAccountIds'] as List? ?? const []).cast<String>(),
        movedAt: DateTime.tryParse('${j['movedAt'] ?? ''}'),
        syncProviderId: j['syncProviderId'] as String?,
        syncConfig: Map<String, String>.from(j['syncConfig'] as Map? ?? const {}),
        uiZoom: validZoom(j['uiZoom']),
        publishedPostRetention:
            PublishedPostRetention.values.asNameMap()[j['publishedPostRetention']] ?? PublishedPostRetention.discardOnCompletion,
        timestampDisplay: TimestampDisplay.values.asNameMap()[j['timestampDisplay']] ?? TimestampDisplay.relative,
        clockFormat: ClockFormat.values.asNameMap()[j['clockFormat']] ?? ClockFormat.system,
        discordMentionEveryone: j['discordMentionEveryone'] as bool? ?? true,
        textCardHandleHiddenPlatforms: (j['textCardHandleHiddenPlatforms'] as List? ?? const []).cast<String>(),
        textCardAlignment: TextCardAlignment.values.asNameMap()[j['textCardAlignment']] ?? TextCardAlignment.left,
        captionStyle: Map<String, dynamic>.from(j['captionStyle'] as Map? ?? const {}),
        cornerStyle: CornerStyle.values.asNameMap()[j['cornerStyle']] ?? CornerStyle.rounded,
        navigationChrome: NavigationChromeStyle.values.asNameMap()[j['navigationChrome']] ?? NavigationChromeStyle.brand,
        customAccentColor: j['customAccentColor'] as int?,
        interfaceDensity: InterfaceDensity.values.asNameMap()[j['interfaceDensity']] ?? InterfaceDensity.comfortable,
        mobileTextScale: validTextScale(j['mobileTextScale']),
        collapsedSettingsSections: (j['collapsedSettingsSections'] as List? ?? const []).cast<String>(),
        automaticHandoffPosting: j['automaticHandoffPosting'] as bool? ?? false,
        automaticHandoffExcludedPlatforms:
            (j['automaticHandoffExcludedPlatforms'] as List? ?? kAutomationRestrictedPlatforms).cast<String>(),
        advanceHandoffOnReturn: j['advanceHandoffOnReturn'] as bool? ?? true,
        artworkMaturity: ArtworkMaturity.values.asNameMap()[j['artworkMaturity']] ?? ArtworkMaturity.general,
        artworkDisallowAiTraining: j['artworkDisallowAiTraining'] as bool? ?? true,
        // 1.3: video
        shrinkOversizedVideos: j['shrinkOversizedVideos'] as bool? ?? false,
        // 1.3: appearance
        backgroundImagePath: j['backgroundImagePath'] as String?,
        backgroundBlur: validBackgroundBlur(j['backgroundBlur']),
        backgroundDim: validBackgroundDim(j['backgroundDim']),
        // 1.3: updates
        updateCheck: UpdateCheckMode.values.asNameMap()[j['updateCheck']] ?? UpdateCheckMode.ask,
        updateCheckedAt: DateTime.tryParse('${j['updateCheckedAt'] ?? ''}'),
        updateLatestRelease: Map<String, dynamic>.from(j['updateLatestRelease'] as Map? ?? const {}),
        updateDismissedVersion: j['updateDismissedVersion'] as String?,
        textCardEveryNetwork: j['textCardEveryNetwork'] as bool? ?? false, // 1.3: cards
        audioTextTemplate: j['audioTextTemplate'] as String? ?? kDefaultAudioTextTemplate, // 1.3.1: audio tags
      );

  final ThemeMode themeMode;
  final AccentChoice accent;
  final OverflowStrategy overflow;
  final bool threadNumbering;
  final bool appendHashtags;
  final bool appendLink;

  /// Hand the post to the user when an API account runs out of quota.
  final bool fallbackToHandoff;
  final bool confirmBeforePosting;
  final PostVisibility defaultVisibility;

  /// Desktop only.
  final bool startAtLogin;

  /// Desktop only: closing the window keeps NEFORUM running in the tray so
  /// scheduled posts still go out.
  final bool minimizeToTray;
  final bool notifyOnPublish;

  /// Configured public media host (needed by Instagram/Threads APIs).
  final String? mediaHostId;

  /// Non-secret host settings; secret fields live in the keychain.
  final Map<String, String> mediaHostConfig;

  /// Optional second host, tried when the main one can't store a file.
  final String? fallbackMediaHostId;

  /// Non-secret settings of the fallback host.
  final Map<String, String> fallbackMediaHostConfig;

  /// Accounts pre-selected in a fresh composer.
  final List<String> defaultTargetIds;
  final bool onboarded;
  final bool compactPreviews;

  /// Turn text-only posts into an image card for platforms that require an
  /// image (Instagram, Pinterest, TikTok photos, Snapchat).
  final bool textCards;
  final TextCardTheme textCardTheme;

  /// Default typeface of a card's words.
  final TextCardFont textCardFont;

  /// Networks whose cards leave out the NEFORUM signature (plain cards).
  final List<String> textCardPlainPlatforms;

  bool textCardBranded(String platformId) => !textCardPlainPlatforms.contains(platformId);

  /// Let platforms that can (Mastodon, Facebook Pages, YouTube, Tumblr,
  /// WordPress, Ghost) hold scheduled posts, so they go out even when this
  /// device is off.
  final bool delegateSchedules;

  /// Desktop only: let the NEFORUM browser extension fill in hand-offs
  /// (a server on 127.0.0.1 that only paired browsers can use).
  final bool browserExtension;

  /// After filling in a page, the extension posts when the user presses
  /// Ctrl+Enter (⌘+Enter) or its Post now button. Never on its own.
  final bool browserQuickPost;

  /// Open hand-off pages in the first paired browser that is installed (the
  /// user's priority order) instead of the system's default browser.
  final bool browserOpenInFirst;

  /// What NEFORUM does with a photo a network does not take as it is (a shape,
  /// file type or size it refuses): a fitted copy for that network, with
  /// borders or cropped, or nothing (the post shows an error).
  final PhotoFitMode photoFit;

  /// Networks whose photos are fitted to the whole frame they show them in
  /// (TikTok 9:16, Instagram feed 4:5, stories 9:16), with [photoFit].
  final List<String> fillFramePlatforms;

  bool fillsFrame(String platformId) => fillFramePlatforms.contains(platformId);

  /// Networks whose first photo gets the caption written on it.
  final List<String> captionPhotoPlatforms;

  bool captionOnPhoto(String platformId) => captionPhotoPlatforms.contains(platformId);

  /// Accounts exported with "Move to another device" (Move): switched off
  /// here until the user confirms the other device has them. Device-only.
  final List<String> movedAccountIds;
  final DateTime? movedAt;

  /// The storage holding the shared sync file (a [SyncProvider] id), or
  /// `null` when sync is off. Device-only, like [syncConfig].
  final String? syncProviderId;

  /// Where the sync file is: `folder` (plus `bookmark` on a Mac), or the
  /// WebDAV `url` and `username`, or the S3 `endpoint`, `region`, `bucket`,
  /// `folder`, `accessKeyId` and `addressing`. The passphrase and passwords
  /// live in the keychain.
  final Map<String, String> syncConfig;

  bool get syncOn => syncProviderId != null;

  /// Desktop only: how big everything is drawn, 1 = 100% (Ctrl + / Ctrl −).
  /// Device-only: each screen needs its own.
  final double uiZoom;

  /// What happens to a post once every network has it.
  final PublishedPostRetention publishedPostRetention;

  final TimestampDisplay timestampDisplay;
  final ClockFormat clockFormat;

  /// Discord server posts start with @everyone (which notifies the channel).
  final bool discordMentionEveryone;

  /// Networks whose text cards leave out the account's @handle.
  final List<String> textCardHandleHiddenPlatforms;

  bool textCardShowsHandle(String platformId) => !textCardHandleHiddenPlatforms.contains(platformId);

  /// Default alignment of a text card's words.
  final TextCardAlignment textCardAlignment;

  /// Default style of captions written on photos (CaptionStyle.toJson).
  final Map<String, dynamic> captionStyle;

  final CornerStyle cornerStyle;
  final NavigationChromeStyle navigationChrome;

  /// ARGB of the user's own accent color, used when [accent] is the custom
  /// choice.
  final int? customAccentColor;

  final InterfaceDensity interfaceDensity;

  /// Phones and tablets: text size, 1 = the system size. Device-only.
  final double mobileTextScale;

  /// Settings sections the user folded away. Device-only.
  final List<String> collapsedSettingsSections;

  /// Desktop only: the browser extension fills in hand-offs and presses the
  /// network's Post button itself, also for scheduled posts while NEFORUM
  /// runs. Device-only.
  final bool automaticHandoffPosting;

  /// Networks that never get automatic posting, even when it is on (their
  /// terms forbid scripted posting). Device-only.
  final List<String> automaticHandoffExcludedPlatforms;

  /// Automatic posting is on, applies to [platformId]'s site, and the user
  /// did not leave that network out.
  bool postsHandoffAutomatically(String platformId) =>
      automaticHandoffPosting && kAutomaticPostingPlatforms.contains(platformId) && !automaticHandoffExcludedPlatforms.contains(platformId);

  /// After the user copies one part of a hand-off and comes back to NEFORUM,
  /// the next part is copied for them.
  final bool advanceHandoffOnReturn;

  /// Defaults for new artwork posts.
  final ArtworkMaturity artworkMaturity;
  final bool artworkDisallowAiTraining;

  // 1.3: video
  /// Videos over a network's size limit get a smaller copy for that network
  /// when posted, made on this device (lib/state/shrunk_videos.dart).
  final bool shrinkOversizedVideos;
  // 1.3: appearance

  /// The picture behind the pages (Settings > Appearance > Background), a
  /// copy in NEFORUM's data folder, or `null` for none. Device-only, like
  /// [uiZoom]: the file is on this device.
  final String? backgroundImagePath;

  /// How much the background picture is blurred: 0 (sharp) to
  /// [kMaxBackgroundBlur]. Device-only.
  final double backgroundBlur;

  /// How strongly the theme's background color covers the picture, 0 to 1.
  /// NEFORUM covers it more when text needs it to stay readable.
  /// Device-only.
  final double backgroundDim;
  // 1.3: updates

  /// Settings > Updates: whether NEFORUM looks for new versions by itself.
  /// Device-only.
  final UpdateCheckMode updateCheck;

  /// When neforus.com last answered an update check. Device-only.
  final DateTime? updateCheckedAt;

  /// The latest.json from that check (LatestRelease.toJson), so the banner
  /// survives a restart without asking again. Device-only.
  final Map<String, dynamic> updateLatestRelease;

  /// The newer version whose banner the user closed: it stays closed until
  /// a later one comes out (critical ones come back at the next start).
  /// Device-only.
  final String? updateDismissedVersion;
  /// 1.3: cards. New text-only posts start with the same text card on every
  /// network that takes images, not only on those that need one. Each post
  /// can change it.
  final bool textCardEveryNetwork;

  /// 1.3.1: audio tags. The post text "Use track details as the text" writes
  /// from a track's details ([renderAudioText]): `{artist} – {title}` and
  /// the other tokens of [audioTextTokens].
  final String audioTextTemplate;

  ResolverOptions get resolverOptions => ResolverOptions(
        overflow: overflow,
        threadNumbering: threadNumbering,
        appendHashtags: appendHashtags,
        appendLink: appendLink,
      );

  PublishOptions get publishOptions => PublishOptions(fallbackToHandoffOnQuota: fallbackToHandoff);

  AppSettings copyWith({
    ThemeMode? themeMode,
    AccentChoice? accent,
    OverflowStrategy? overflow,
    bool? threadNumbering,
    bool? appendHashtags,
    bool? appendLink,
    bool? fallbackToHandoff,
    bool? confirmBeforePosting,
    PostVisibility? defaultVisibility,
    bool? startAtLogin,
    bool? minimizeToTray,
    bool? notifyOnPublish,
    String? mediaHostId,
    bool clearMediaHost = false,
    Map<String, String>? mediaHostConfig,
    String? fallbackMediaHostId,
    bool clearFallbackMediaHost = false,
    Map<String, String>? fallbackMediaHostConfig,
    List<String>? defaultTargetIds,
    bool? onboarded,
    bool? compactPreviews,
    bool? textCards,
    TextCardTheme? textCardTheme,
    TextCardFont? textCardFont,
    List<String>? textCardPlainPlatforms,
    bool? delegateSchedules,
    bool? browserExtension,
    bool? browserQuickPost,
    bool? browserOpenInFirst,
    PhotoFitMode? photoFit,
    List<String>? fillFramePlatforms,
    List<String>? captionPhotoPlatforms,
    List<String>? movedAccountIds,
    DateTime? movedAt,
    bool clearMoved = false,
    String? syncProviderId,
    Map<String, String>? syncConfig,
    bool clearSync = false,
    double? uiZoom,
    PublishedPostRetention? publishedPostRetention,
    TimestampDisplay? timestampDisplay,
    ClockFormat? clockFormat,
    bool? discordMentionEveryone,
    List<String>? textCardHandleHiddenPlatforms,
    TextCardAlignment? textCardAlignment,
    Map<String, dynamic>? captionStyle,
    CornerStyle? cornerStyle,
    NavigationChromeStyle? navigationChrome,
    int? customAccentColor,
    InterfaceDensity? interfaceDensity,
    double? mobileTextScale,
    List<String>? collapsedSettingsSections,
    bool? automaticHandoffPosting,
    List<String>? automaticHandoffExcludedPlatforms,
    bool? advanceHandoffOnReturn,
    ArtworkMaturity? artworkMaturity,
    bool? artworkDisallowAiTraining,
    // 1.3: video
    bool? shrinkOversizedVideos,
    // 1.3: appearance
    String? backgroundImagePath,
    bool clearBackgroundImage = false,
    double? backgroundBlur,
    double? backgroundDim,
    // 1.3: updates
    UpdateCheckMode? updateCheck,
    DateTime? updateCheckedAt,
    Map<String, dynamic>? updateLatestRelease,
    String? updateDismissedVersion,
    bool? textCardEveryNetwork, // 1.3: cards
    String? audioTextTemplate, // 1.3.1: audio tags
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        accent: accent ?? this.accent,
        overflow: overflow ?? this.overflow,
        threadNumbering: threadNumbering ?? this.threadNumbering,
        appendHashtags: appendHashtags ?? this.appendHashtags,
        appendLink: appendLink ?? this.appendLink,
        fallbackToHandoff: fallbackToHandoff ?? this.fallbackToHandoff,
        confirmBeforePosting: confirmBeforePosting ?? this.confirmBeforePosting,
        defaultVisibility: defaultVisibility ?? this.defaultVisibility,
        startAtLogin: startAtLogin ?? this.startAtLogin,
        minimizeToTray: minimizeToTray ?? this.minimizeToTray,
        notifyOnPublish: notifyOnPublish ?? this.notifyOnPublish,
        mediaHostId: clearMediaHost ? null : (mediaHostId ?? this.mediaHostId),
        mediaHostConfig: clearMediaHost ? const {} : (mediaHostConfig ?? this.mediaHostConfig),
        fallbackMediaHostId: clearFallbackMediaHost ? null : (fallbackMediaHostId ?? this.fallbackMediaHostId),
        fallbackMediaHostConfig: clearFallbackMediaHost ? const {} : (fallbackMediaHostConfig ?? this.fallbackMediaHostConfig),
        defaultTargetIds: defaultTargetIds ?? this.defaultTargetIds,
        onboarded: onboarded ?? this.onboarded,
        compactPreviews: compactPreviews ?? this.compactPreviews,
        textCards: textCards ?? this.textCards,
        textCardTheme: textCardTheme ?? this.textCardTheme,
        textCardFont: textCardFont ?? this.textCardFont,
        textCardPlainPlatforms: textCardPlainPlatforms ?? this.textCardPlainPlatforms,
        delegateSchedules: delegateSchedules ?? this.delegateSchedules,
        browserExtension: browserExtension ?? this.browserExtension,
        browserQuickPost: browserQuickPost ?? this.browserQuickPost,
        browserOpenInFirst: browserOpenInFirst ?? this.browserOpenInFirst,
        photoFit: photoFit ?? this.photoFit,
        fillFramePlatforms: fillFramePlatforms ?? this.fillFramePlatforms,
        captionPhotoPlatforms: captionPhotoPlatforms ?? this.captionPhotoPlatforms,
        movedAccountIds: clearMoved ? const [] : (movedAccountIds ?? this.movedAccountIds),
        movedAt: clearMoved ? null : (movedAt ?? this.movedAt),
        syncProviderId: clearSync ? null : (syncProviderId ?? this.syncProviderId),
        syncConfig: clearSync ? const {} : (syncConfig ?? this.syncConfig),
        uiZoom: uiZoom ?? this.uiZoom,
        publishedPostRetention: publishedPostRetention ?? this.publishedPostRetention,
        timestampDisplay: timestampDisplay ?? this.timestampDisplay,
        clockFormat: clockFormat ?? this.clockFormat,
        discordMentionEveryone: discordMentionEveryone ?? this.discordMentionEveryone,
        textCardHandleHiddenPlatforms: textCardHandleHiddenPlatforms ?? this.textCardHandleHiddenPlatforms,
        textCardAlignment: textCardAlignment ?? this.textCardAlignment,
        captionStyle: captionStyle ?? this.captionStyle,
        cornerStyle: cornerStyle ?? this.cornerStyle,
        navigationChrome: navigationChrome ?? this.navigationChrome,
        customAccentColor: customAccentColor ?? this.customAccentColor,
        interfaceDensity: interfaceDensity ?? this.interfaceDensity,
        mobileTextScale: mobileTextScale ?? this.mobileTextScale,
        collapsedSettingsSections: collapsedSettingsSections ?? this.collapsedSettingsSections,
        automaticHandoffPosting: automaticHandoffPosting ?? this.automaticHandoffPosting,
        automaticHandoffExcludedPlatforms: automaticHandoffExcludedPlatforms ?? this.automaticHandoffExcludedPlatforms,
        advanceHandoffOnReturn: advanceHandoffOnReturn ?? this.advanceHandoffOnReturn,
        artworkMaturity: artworkMaturity ?? this.artworkMaturity,
        artworkDisallowAiTraining: artworkDisallowAiTraining ?? this.artworkDisallowAiTraining,
        // 1.3: video
        shrinkOversizedVideos: shrinkOversizedVideos ?? this.shrinkOversizedVideos,
        // 1.3: appearance
        backgroundImagePath: clearBackgroundImage ? null : (backgroundImagePath ?? this.backgroundImagePath),
        backgroundBlur: backgroundBlur ?? this.backgroundBlur,
        backgroundDim: backgroundDim ?? this.backgroundDim,
        // 1.3: updates
        updateCheck: updateCheck ?? this.updateCheck,
        updateCheckedAt: updateCheckedAt ?? this.updateCheckedAt,
        updateLatestRelease: updateLatestRelease ?? this.updateLatestRelease,
        updateDismissedVersion: updateDismissedVersion ?? this.updateDismissedVersion,
        textCardEveryNetwork: textCardEveryNetwork ?? this.textCardEveryNetwork, // 1.3: cards
        audioTextTemplate: audioTextTemplate ?? this.audioTextTemplate, // 1.3.1: audio tags
      );

  Map<String, dynamic> toJson() => {
        'themeMode': themeMode.name,
        'accent': accent.name,
        'overflow': overflow.name,
        'threadNumbering': threadNumbering,
        'appendHashtags': appendHashtags,
        'appendLink': appendLink,
        'fallbackToHandoff': fallbackToHandoff,
        'confirmBeforePosting': confirmBeforePosting,
        'defaultVisibility': defaultVisibility.name,
        'startAtLogin': startAtLogin,
        'minimizeToTray': minimizeToTray,
        'notifyOnPublish': notifyOnPublish,
        if (mediaHostId != null) 'mediaHostId': mediaHostId,
        'mediaHostConfig': mediaHostConfig,
        if (fallbackMediaHostId != null) 'fallbackMediaHostId': fallbackMediaHostId,
        'fallbackMediaHostConfig': fallbackMediaHostConfig,
        'defaultTargetIds': defaultTargetIds,
        'onboarded': onboarded,
        'compactPreviews': compactPreviews,
        'textCards': textCards,
        'textCardTheme': textCardTheme.name,
        'textCardFont': textCardFont.name,
        'textCardPlainPlatforms': textCardPlainPlatforms,
        'delegateSchedules': delegateSchedules,
        'browserExtension': browserExtension,
        'browserQuickPost': browserQuickPost,
        'browserOpenInFirst': browserOpenInFirst,
        'photoFit': photoFit.name,
        'fillFramePlatforms': fillFramePlatforms,
        'captionPhotoPlatforms': captionPhotoPlatforms,
        if (movedAccountIds.isNotEmpty) 'movedAccountIds': movedAccountIds,
        if (movedAt != null) 'movedAt': movedAt!.toIso8601String(),
        if (syncProviderId != null) 'syncProviderId': syncProviderId,
        if (syncConfig.isNotEmpty) 'syncConfig': syncConfig,
        if (uiZoom != 1) 'uiZoom': uiZoom,
        'publishedPostRetention': publishedPostRetention.name,
        'timestampDisplay': timestampDisplay.name,
        'clockFormat': clockFormat.name,
        'discordMentionEveryone': discordMentionEveryone,
        'textCardHandleHiddenPlatforms': textCardHandleHiddenPlatforms,
        'textCardAlignment': textCardAlignment.name,
        if (captionStyle.isNotEmpty) 'captionStyle': captionStyle,
        'cornerStyle': cornerStyle.name,
        'navigationChrome': navigationChrome.name,
        if (customAccentColor != null) 'customAccentColor': customAccentColor,
        'interfaceDensity': interfaceDensity.name,
        if (mobileTextScale != 1) 'mobileTextScale': mobileTextScale,
        if (collapsedSettingsSections.isNotEmpty) 'collapsedSettingsSections': collapsedSettingsSections,
        'automaticHandoffPosting': automaticHandoffPosting,
        'automaticHandoffExcludedPlatforms': automaticHandoffExcludedPlatforms,
        'advanceHandoffOnReturn': advanceHandoffOnReturn,
        'artworkMaturity': artworkMaturity.name,
        'artworkDisallowAiTraining': artworkDisallowAiTraining,
        // 1.3: video
        'shrinkOversizedVideos': shrinkOversizedVideos,
        // 1.3: appearance
        if (backgroundImagePath != null) 'backgroundImagePath': backgroundImagePath,
        if (backgroundBlur != 0) 'backgroundBlur': backgroundBlur,
        if (backgroundDim != kDefaultBackgroundDim) 'backgroundDim': backgroundDim,
        // 1.3: updates
        'updateCheck': updateCheck.name,
        if (updateCheckedAt != null) 'updateCheckedAt': updateCheckedAt!.toUtc().toIso8601String(),
        if (updateLatestRelease.isNotEmpty) 'updateLatestRelease': updateLatestRelease,
        if (updateDismissedVersion != null) 'updateDismissedVersion': updateDismissedVersion,
        'textCardEveryNetwork': textCardEveryNetwork, // 1.3: cards
        'audioTextTemplate': audioTextTemplate, // 1.3.1: audio tags
      };
}
