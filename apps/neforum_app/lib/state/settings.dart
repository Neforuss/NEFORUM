import 'package:flutter/material.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../media/text_card.dart';
import '../theme/tokens.dart';

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
    this.defaultTargetIds = const [],
    this.onboarded = false,
    this.compactPreviews = false,
    this.textCards = true,
    this.textCardTheme = TextCardTheme.dark,
    this.textCardPlainPlatforms = const [],
    this.delegateSchedules = true,
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
        defaultTargetIds: (j['defaultTargetIds'] as List? ?? const []).cast<String>(),
        onboarded: j['onboarded'] as bool? ?? false,
        compactPreviews: j['compactPreviews'] as bool? ?? false,
        textCards: j['textCards'] as bool? ?? true,
        textCardTheme: TextCardTheme.values.asNameMap()[j['textCardTheme']] ?? TextCardTheme.dark,
        textCardPlainPlatforms: (j['textCardPlainPlatforms'] as List? ?? const []).cast<String>(),
        delegateSchedules: j['delegateSchedules'] as bool? ?? true,
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

  /// Accounts pre-selected in a fresh composer.
  final List<String> defaultTargetIds;
  final bool onboarded;
  final bool compactPreviews;

  /// Turn text-only posts into an image card for platforms that require an
  /// image (Instagram, Pinterest, TikTok photos, Snapchat).
  final bool textCards;
  final TextCardTheme textCardTheme;

  /// Networks whose cards leave out the NEFORUM signature (plain cards).
  final List<String> textCardPlainPlatforms;

  bool textCardBranded(String platformId) => !textCardPlainPlatforms.contains(platformId);

  /// Let platforms that can (Mastodon, Facebook Pages, YouTube, Tumblr,
  /// WordPress, Ghost) hold scheduled posts, so they go out even when this
  /// device is off.
  final bool delegateSchedules;

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
    List<String>? defaultTargetIds,
    bool? onboarded,
    bool? compactPreviews,
    bool? textCards,
    TextCardTheme? textCardTheme,
    List<String>? textCardPlainPlatforms,
    bool? delegateSchedules,
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
        defaultTargetIds: defaultTargetIds ?? this.defaultTargetIds,
        onboarded: onboarded ?? this.onboarded,
        compactPreviews: compactPreviews ?? this.compactPreviews,
        textCards: textCards ?? this.textCards,
        textCardTheme: textCardTheme ?? this.textCardTheme,
        textCardPlainPlatforms: textCardPlainPlatforms ?? this.textCardPlainPlatforms,
        delegateSchedules: delegateSchedules ?? this.delegateSchedules,
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
        'defaultTargetIds': defaultTargetIds,
        'onboarded': onboarded,
        'compactPreviews': compactPreviews,
        'textCards': textCards,
        'textCardTheme': textCardTheme.name,
        'textCardPlainPlatforms': textCardPlainPlatforms,
        'delegateSchedules': delegateSchedules,
      };
}
