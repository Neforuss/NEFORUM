import 'package:meta/meta.dart';

import 'audio.dart' show AudioMimeTypes;

/// How a platform can be reached by NEFORUM.
///
/// A platform may support several tiers; the user picks one when connecting
/// an account (and can keep two accounts for the same platform, one per tier).
enum PlatformTier {
  /// Open, free API with no app review and no business-account requirement
  /// (Mastodon, Bluesky, Nostr, Telegram bots, Discord webhooks, ...).
  openApi,

  /// Official API that works, but the user must register their own developer
  /// app ("bring your own keys") and lives inside a free-tier quota or an
  /// unreviewed-app restriction (X, LinkedIn, YouTube, Threads, ...).
  byokApi,

  /// No usable API for this account type. NEFORUM prepares everything (text on
  /// the clipboard, media in the share sheet, a prefilled web composer) and the
  /// user taps "Post" in the platform's own app or site. Works for personal
  /// accounts on Instagram, TikTok, Facebook, Snapchat, WhatsApp, ...
  handoff,

  /// Experimental: NEFORUM drives the platform's own website inside an embedded
  /// browser that the user has signed into. Fully automatic but fragile and
  /// may violate the platform's terms of service.
  webSession,
}

extension PlatformTierLabel on PlatformTier {
  String get label => switch (this) {
        PlatformTier.openApi => 'Open API',
        PlatformTier.byokApi => 'Your own API keys',
        PlatformTier.handoff => 'Hand-off (share sheet)',
        PlatformTier.webSession => 'Web session (experimental)',
      };

  /// True when NEFORUM can publish without the user touching anything.
  bool get isAutomatic => this != PlatformTier.handoff;
}

/// How a platform counts characters against its limit.
enum CountingRule {
  /// One per user-perceived character (grapheme cluster). Bluesky.
  graphemes,

  /// One per UTF-16 code unit (JavaScript `.length`). Threads, LinkedIn, most.
  utf16,

  /// One per UTF-8 byte.
  utf8Bytes,

  /// twitter-text v3 weighted counting: most Latin/Cyrillic/… characters
  /// weigh 1, everything else (CJK, emoji) weighs 2, and every URL weighs 23
  /// regardless of its length.
  weightedX,

  /// Code points (runes), with every URL counted as [TextRules.urlWeight].
  /// Mastodon.
  codePointsWithUrlWeight,
}

/// Text constraints and features for one platform.
@immutable
class TextRules {
  const TextRules({
    this.maxLength,
    this.counting = CountingRule.utf16,
    this.urlWeight,
    this.titleMax,
    this.titleRequired = false,
    this.titleSupported = false,
    this.supportsThreads = false,
    this.supportsContentWarning = false,
    this.supportsMarkdown = false,
    this.supportsHtml = false,
    this.supportsHashtags = true,
    this.hashtagsAsField = false,
    this.maxHashtags,
    this.mentionCountsDomain = true,
    this.linkInText = true,
    this.notes,
  });

  /// `null` means unlimited (Nostr, Matrix).
  final int? maxLength;
  final CountingRule counting;

  /// When set, every URL counts as this many characters (X: 23, Mastodon: 23).
  final int? urlWeight;
  final int? titleMax;
  final bool titleRequired;
  final bool titleSupported;

  /// The platform has replies/threads, so an over-long post can be split into
  /// a chain instead of truncated.
  final bool supportsThreads;
  final bool supportsContentWarning;
  final bool supportsMarkdown;
  final bool supportsHtml;
  final bool supportsHashtags;

  /// The platform has a dedicated tags field (Tumblr, YouTube, DEV.to,
  /// WordPress). Tags then go there instead of being appended as `#tags`.
  final bool hashtagsAsField;
  final int? maxHashtags;

  /// Mastodon counts `@user@example.org` as `@user` only.
  final bool mentionCountsDomain;

  /// When the post has a [Post.link] and the platform has no link field, the
  /// resolver appends the link to the text. Set false for platforms where a
  /// link in the body is pointless (YouTube description still fine → true).
  final bool linkInText;
  final String? notes;
}

/// Media constraints for one platform.
@immutable
class MediaRules {
  const MediaRules({
    this.maxImages = 0,
    this.maxVideos = 0,
    this.requiresMedia = false,
    this.allowsMixedImageVideo = false,
    this.imageMaxBytes,
    this.videoMaxBytes,
    this.videoMaxSeconds,
    this.imageMimeTypes = const {'image/jpeg', 'image/png', 'image/gif', 'image/webp'},
    this.videoMimeTypes = const {'video/mp4', 'video/quicktime'},
    this.supportsAltText = false,
    this.requiresPublicMediaUrl = false,
    this.notes,
    this.maxAudios = 0,
    this.audioMaxBytes,
    this.audioMimeTypes = const {},
    this.keepsAudioBytes = false,
    this.audioWithOtherMedia = false,
    this.audioAsVideo = false,
    this.audioAsLink = false,
  });

  final int maxImages;
  final int maxVideos;
  final bool requiresMedia;
  final bool allowsMixedImageVideo;
  final int? imageMaxBytes;
  final int? videoMaxBytes;
  final int? videoMaxSeconds;
  final Set<String> imageMimeTypes;
  final Set<String> videoMimeTypes;
  final bool supportsAltText;

  /// Instagram and Threads cannot accept an upload: the media must already be
  /// reachable at a public HTTPS URL. NEFORUM uses a configured [MediaHost].
  final bool requiresPublicMediaUrl;
  final String? notes;

  /// Sound files a post can carry as sound (a playable file, not a video).
  /// 0: the network takes no sound file, see [audioAsVideo] and
  /// [audioAsLink].
  final int maxAudios;
  final int? audioMaxBytes;

  /// Canonical sound types it takes ([AudioMimeTypes]).
  final Set<String> audioMimeTypes;

  /// The network serves the file it was given, byte for byte, so a lossless
  /// original stays lossless. False where it re-encodes (Mastodon makes an
  /// MP3) or does not say.
  final bool keepsAudioBytes;

  /// A sound file can go in the same post as photos or videos. False: the
  /// sound goes alone and the other files are left out.
  final bool audioWithOtherMedia;

  /// The network takes video but no sound file: the track goes as a video
  /// that shows one still picture for its whole length (X, Bluesky,
  /// Instagram...). The app makes that video.
  final bool audioAsVideo;

  /// The network takes no sound file and no video for it: the track goes as
  /// a link to the file on the user's media host (Nostr, Lemmy, Reddit,
  /// blogs).
  final bool audioAsLink;

  bool get supportsAnyMedia => maxImages > 0 || maxVideos > 0 || maxAudios > 0;

  /// The network takes sound files as sound.
  bool get supportsAudio => maxAudios > 0;
}

/// Poll and quiz limits for platforms that have them.
@immutable
class PollRules {
  const PollRules({
    required this.maxOptions,
    this.minOptions = 2,
    this.optionMaxLength,
    this.quizzes = false,
    this.quizOptionMaxLength,
    this.quizExplanationMaxLength,
    this.imagePolls = false,
    this.imageOptionMaxLength,
    this.notes,
  });

  final int minOptions;
  final int maxOptions;
  final int? optionMaxLength;

  /// The platform has quizzes (one correct answer).
  final bool quizzes;
  final int? quizOptionMaxLength;
  final int? quizExplanationMaxLength;

  /// Polls whose options are the post's images with captions.
  final bool imagePolls;
  final int? imageOptionMaxLength;
  final String? notes;
}

/// A rate/quota limit NEFORUM tracks locally so that it can warn before the
/// platform rejects a post (or fall back to hand-off).
@immutable
class QuotaRule {
  const QuotaRule({
    required this.id,
    required this.limit,
    required this.window,
    required this.note,
    this.appliesToTier,
  });

  /// Stable identifier, e.g. `x.free.posts_per_month`.
  final String id;
  final int limit;
  final Duration window;
  final String note;

  /// When set, only accounts connected with this tier are subject to the rule.
  final PlatformTier? appliesToTier;
}

/// Kinds of site that change how posts are routed to them.
enum PlatformCategory {
  /// Art portfolio and gallery sites (DeviantArt, ArtStation, Behance, ...).
  art,
}

/// Everything the UI and the publishing pipeline need to know about one
/// platform, independent of any particular account.
@immutable
class PlatformDescriptor {
  const PlatformDescriptor({
    required this.id,
    required this.name,
    required this.tiers,
    required this.defaultTier,
    required this.text,
    required this.media,
    required this.accountRequirements,
    required this.apiCostSummary,
    this.iconKey,
    this.homepage,
    this.defaultQuotas = const [],
    this.personalAccountOk = true,
    this.setupGuide,
    this.serverSideScheduling = false,
    this.supportsLinkField = false,
    this.family,
    this.polls,
    this.categories = const {},
  });

  /// Stable identifier used in storage and the registry, e.g. `mastodon`.
  final String id;
  final String name;

  /// Icon name resolved by the UI layer.
  final String? iconKey;
  final String? homepage;
  final Set<PlatformTier> tiers;
  final PlatformTier defaultTier;
  final TextRules text;
  final MediaRules media;
  final List<QuotaRule> defaultQuotas;

  /// False when the official API refuses personal accounts
  /// (Instagram, Facebook, Pinterest, Google Business Profile).
  final bool personalAccountOk;

  /// One or two sentences, shown when the user adds an account.
  final String accountRequirements;

  /// One or two sentences on cost and quota, shown when the user adds an account.
  final String apiCostSummary;

  /// Relative path of the markdown setup guide (`docs/byok/x.md`).
  final String? setupGuide;

  /// The platform itself can hold a scheduled post (Mastodon `scheduled_at`,
  /// YouTube `publishAt`). NEFORUM can then hand the schedule over.
  final bool serverSideScheduling;

  /// Posts have a dedicated link field (Reddit link posts, Pinterest, Lemmy,
  /// blog platforms).
  final bool supportsLinkField;

  /// Groups compatible software, e.g. `mastodon-api` for Pleroma/GoToSocial.
  final String? family;

  /// Set when posts can carry a poll or quiz ([PostPoll]).
  final PollRules? polls;

  /// What kind of site this is, where it matters for choosing targets.
  final Set<PlatformCategory> categories;

  /// A portfolio or gallery site for artwork: it only receives artwork posts
  /// ([Post.artwork]).
  bool get isArtPlatform => categories.contains(PlatformCategory.art);

  bool supportsTier(PlatformTier t) => tiers.contains(t);

  @override
  String toString() => 'PlatformDescriptor($id)';
}
