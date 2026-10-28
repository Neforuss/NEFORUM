import '../../model/platform_descriptor.dart';

/// Self-post body limit (PRAW docs: selftext max 40,000 characters).
const int redditBodyMax = 40000;

/// Title limit (official /dev/api: "up to 300 characters long").
const int redditTitleMax = 300;

/// Comment limit, used when the body of a link/image/video post is added as
/// the first comment.
const int redditCommentMax = 10000;

/// Official limits for `flair_id` / `flair_text` on `/api/submit`.
const int redditFlairIdMax = 36;
const int redditFlairTextMax = 64;

/// Static facts about Reddit.
const PlatformDescriptor redditDescriptor = PlatformDescriptor(
  id: 'reddit',
  name: 'Reddit',
  iconKey: 'reddit',
  homepage: 'https://www.reddit.com',
  tiers: {PlatformTier.byokApi, PlatformTier.handoff},
  defaultTier: PlatformTier.byokApi,
  text: TextRules(
    maxLength: redditBodyMax,
    // Reddit counts Unicode characters; UTF-16 units are never fewer, so this
    // keeps a safety margin for emoji.
    counting: CountingRule.utf16,
    titleMax: redditTitleMax,
    titleRequired: true,
    titleSupported: true,
    supportsThreads: false,
    // Mapped onto Reddit's spoiler tag.
    supportsContentWarning: true,
    supportsMarkdown: true,
    supportsHashtags: false,
    linkInText: false,
    notes: 'Every post goes to one subreddit (or your profile, u_yourname) and needs a title of up to 300 '
        'characters. The body is Markdown, up to 40,000 characters. Hashtags mean nothing on Reddit. '
        'Subreddits can add their own rules (required flair, no links, title words).',
  ),
  media: MediaRules(
    // Sound goes as a link to the file on the media host.
    audioAsLink: true,
    maxImages: 20,
    maxVideos: 1,
    allowsMixedImageVideo: false,
    imageMaxBytes: 20 * 1024 * 1024,
    videoMaxBytes: 1024 * 1024 * 1024,
    videoMaxSeconds: 15 * 60,
    imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif'},
    videoMimeTypes: {'video/mp4', 'video/quicktime'},
    supportsAltText: false,
    requiresPublicMediaUrl: false,
    notes: 'One image (image post), 2-20 images (gallery) or one MP4/MOV video. JPEG, PNG and GIF only. '
        'Reddit Help states 20 MB per image and 1 GB / 15 minutes per video. No alt text through the API.',
  ),
  defaultQuotas: [
    QuotaRule(
      id: 'reddit.requests_per_minute',
      limit: 100,
      window: Duration(minutes: 1),
      note: 'Reddit allows 100 API requests per minute per app (client ID). NEFORUM counts one per post; '
          'a post with media uses up to 6 requests',
      appliesToTier: PlatformTier.byokApi,
    ),
  ],
  personalAccountOk: true,
  accountRequirements: 'Any Reddit account. Automatic posting needs your own Reddit "installed app" (client ID). '
      'Since November 2025 Reddit approves new API apps by hand, so if you do not have one yet use hand-off.',
  apiCostSummary: 'The Reddit API is free for personal, non-commercial use, up to 100 requests per minute per app. '
      'Hand-off is free because you press Post yourself.',
  setupGuide: 'docs/platforms/reddit.md',
  serverSideScheduling: false,
  supportsLinkField: true,
);
