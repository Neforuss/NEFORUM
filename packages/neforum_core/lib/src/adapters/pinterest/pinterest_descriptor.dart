import '../../model/platform_descriptor.dart';

/// Limits from the Pinterest API v5 OpenAPI description (PinCreate,
/// PinMediaSource*), the rate-limit and access-tier docs and the Help
/// Center pin specs (read 2026-10-07).
abstract final class PinterestLimits {
  static const int titleMax = 100;
  static const int descriptionMax = 800;
  static const int altTextMax = 500;
  static const int linkMax = 2048;

  /// The Save-button web route caps the description at 500 characters.
  static const int handoffDescriptionMax = 500;
  static const int maxImages = 5;
  static const int imageMaxBytes = 20 * 1024 * 1024;
  static const int videoMinSeconds = 4;
  static const int videoMaxSeconds = 5 * 60;
  static const int trialWritesPerDay = 300;
  static const int trialRequestsPerDay = 1000;
}

/// Static description of Pinterest for the UI and the publishing pipeline.
const PlatformDescriptor pinterestDescriptor = PlatformDescriptor(
  id: 'pinterest',
  name: 'Pinterest',
  iconKey: 'pinterest',
  homepage: 'https://www.pinterest.com',
  tiers: {PlatformTier.byokApi, PlatformTier.handoff},
  defaultTier: PlatformTier.byokApi,
  text: TextRules(
    maxLength: PinterestLimits.descriptionMax,
    // The API's maxLength counts characters (code points); counting UTF-16
    // units is never lower, so NEFORUM never lets an over-long Pin through.
    counting: CountingRule.utf16,
    titleMax: PinterestLimits.titleMax,
    titleSupported: true,
    titleRequired: false,
    supportsThreads: false,
    supportsContentWarning: false,
    supportsMarkdown: false,
    supportsHtml: false,
    supportsHashtags: true,
    hashtagsAsField: false,
    linkInText: false,
    notes: 'A Pin has a title (up to 100 characters), a description (up to 800) and a separate link field '
        '(the page the Pin leads to). Hashtags are plain text in the description. No threads or content warnings. '
        'When Pinterest is opened through the web hand-off only 500 characters of description are prefilled.',
  ),
  media: MediaRules(
    maxImages: PinterestLimits.maxImages,
    maxVideos: 1,
    requiresMedia: true,
    allowsMixedImageVideo: false,
    imageMaxBytes: PinterestLimits.imageMaxBytes,
    videoMaxSeconds: PinterestLimits.videoMaxSeconds,
    imageMimeTypes: {'image/jpeg', 'image/png'},
    videoMimeTypes: {'video/mp4', 'video/x-m4v'},
    supportsAltText: true,
    requiresPublicMediaUrl: false,
    notes: 'Every Pin needs an image or a video. One image, or 2 to 5 images as a carousel; JPEG or PNG, up to 20 MB. '
        'Or one MP4/M4V video, 4 seconds to 5 minutes. Images and video cannot be mixed. Recommended shape 2:3 '
        '(1000 x 1500 px), 9:16 for video. Alt text up to 500 characters (single-image Pins).',
  ),
  defaultQuotas: [
    QuotaRule(
      id: 'pinterest.trial.writes_per_day',
      limit: PinterestLimits.trialWritesPerDay,
      window: Duration(days: 1),
      note: 'Trial access: 300 Pin/board/media writes per app per day (a video Pin uses 2). '
          'Raise this if your app has Standard access (100 per minute).',
      appliesToTier: PlatformTier.byokApi,
    ),
    QuotaRule(
      id: 'pinterest.trial.requests_per_day',
      limit: PinterestLimits.trialRequestsPerDay,
      window: Duration(days: 1),
      note: 'Trial access: 1000 API calls per app per day in total.',
      appliesToTier: PlatformTier.byokApi,
    ),
  ],
  personalAccountOk: false,
  accountRequirements: 'Automatic posting needs a Pinterest business account (converting a personal account is free '
      'and keeps your profile) and your own Pinterest developer app, which Pinterest must approve before it works. '
      'Until Pinterest also grants the app Standard access, Pins it creates are only visible to you.',
  apiCostSummary: 'Free. With Trial access Pinterest allows about 300 new Pins and 1000 API calls per day, and the Pins '
      'stay private to you; Standard access (after a video review by Pinterest) makes them public.',
  setupGuide: 'docs/platforms/pinterest.md',
  serverSideScheduling: false,
  supportsLinkField: true,
);
