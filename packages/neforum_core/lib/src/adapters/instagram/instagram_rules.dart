import '../../model/media.dart';
import '../../model/photo_fit.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_placement.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';

/// Static facts about Instagram, taken from the Instagram Platform docs
/// (content publishing guide, IG User Media reference, error-code reference;
/// re-checked 2026-10-11 against developers.facebook.com/documentation/
/// instagram-platform) and `docs/research/instagram.json`.
class InstagramRules {
  InstagramRules._();

  static const int captionMax = 2200;
  static const int maxHashtags = 30;
  static const int maxMentions = 20;
  static const int altTextMax = 1000;
  static const int carouselMax = 10;
  static const int imageMaxBytes = 8 * 1024 * 1024;
  static const int reelMaxBytes = 300 * 1024 * 1024;
  static const int reelMaxSeconds = 15 * 60;
  static const int storyVideoMaxBytes = 100 * 1024 * 1024;
  static const int storyVideoMaxSeconds = 60;
  static const int videoMinSeconds = 3;

  /// Feed / carousel images: 4:5 (0.8) to 1.91:1.
  static const double minFeedRatio = 0.8;
  static const double maxFeedRatio = 1.91;
  static const double _ratioTolerance = 0.005;

  /// What the Instagram app accepts through the share sheet (hand-off tier).
  static const Set<String> handoffImageTypes = {'image/jpeg', 'image/png', 'image/gif'};

  static const PlatformDescriptor descriptor = PlatformDescriptor(
    id: 'instagram',
    name: 'Instagram',
    iconKey: 'instagram',
    homepage: 'https://www.instagram.com/',
    tiers: {PlatformTier.handoff, PlatformTier.byokApi},
    defaultTier: PlatformTier.handoff,
    personalAccountOk: false,
    setupGuide: 'docs/platforms/instagram.md',
    serverSideScheduling: false,
    supportsLinkField: false,
    accountRequirements:
        'Hand-off works with any Instagram account, including personal ones: NEFORUM copies the caption and '
        'hands the photo or video to the Instagram app. Automatic posting needs a professional (Business or '
        'Creator) account and your own free Meta developer app; personal accounts cannot use the API.',
    apiCostSummary:
        'The Instagram API is free. Meta\'s docs give each account 100 API posts per rolling 24 hours in one place '
        'and 50 in two others; NEFORUM counts up to 100 and treats Instagram\'s own limit error as a quota problem. '
        'Photos must be put on a public media host you configure because Instagram downloads them from a link.',
    text: TextRules(
      maxLength: captionMax,
      counting: CountingRule.utf16,
      supportsHashtags: true,
      maxHashtags: maxHashtags,
      linkInText: false,
      notes: 'Caption up to 2,200 characters, 30 hashtags and 20 @mentions. Links in captions are not '
          'clickable. Stories have no caption.',
    ),
    media: MediaRules(
      maxImages: carouselMax,
      maxVideos: carouselMax,
      requiresMedia: true,
      allowsMixedImageVideo: true,
      imageMaxBytes: imageMaxBytes,
      videoMaxBytes: reelMaxBytes,
      videoMaxSeconds: reelMaxSeconds,
      imageMimeTypes: {'image/jpeg'},
      videoMimeTypes: {'video/mp4', 'video/quicktime'},
      supportsAltText: true,
      requiresPublicMediaUrl: true,
      notes: 'One photo, one video (posted as a Reel) or a carousel of 2-10 items. The API takes JPEG only, '
          'up to 8 MB, aspect ratio 4:5 to 1.91:1. Reels: MP4/MOV, 3 s to 15 min, up to 300 MB. '
          'Story videos: 3-60 s, up to 100 MB.',
    ),
    defaultQuotas: [
      QuotaRule(
        id: 'instagram.posts_per_day',
        limit: 100,
        window: Duration(hours: 24),
        note: 'API-published posts per account in a rolling 24 hours (a carousel counts as one). The content '
            'publishing guide says 100; its carousel section and the content_publishing_limit reference say 50.',
        appliesToTier: PlatformTier.byokApi,
      ),
    ],
  );

  /// Instagram-specific checks layered on the generic rules validator.
  static List<ValidationIssue> check(PostVariant v, PlatformTier tier, List<ValidationIssue> generic) {
    final handoff = tier == PlatformTier.handoff;
    final story = isStory(v);
    final out = <ValidationIssue>[];
    for (final issue in generic) {
      // The share sheet accepts PNG/GIF and the app crops by itself, so the
      // API-only media rules do not apply to hand-off.
      if (handoff && (issue.code == 'media.image_type' || issue.code == 'media.image_too_large')) continue;
      // Alt text cannot travel through the share sheet, and stories take none.
      if ((handoff || story) && issue.code == 'media.no_alt') continue;
      // Too many hashtags is a hard API error (2207010), not just a warning.
      if (issue.code == 'hashtags.too_many' && !handoff) {
        out.add(ValidationIssue.error(issue.code, issue.message, field: issue.field));
        continue;
      }
      out.add(issue);
    }

    if (handoff) {
      for (final m in v.media.where((m) => m.isImage)) {
        if (!handoffImageTypes.contains(m.mimeType)) {
          out.add(ValidationIssue.error('media.image_type', '${m.mimeType} cannot be shared to Instagram', field: 'media'));
        }
      }
    }

    final mentions = RegExp(r'(?<![\w@])@[A-Za-z0-9._]+').allMatches(v.text).length;
    if (mentions > maxMentions) {
      out.add(ValidationIssue.error('instagram.too_many_mentions',
          '$mentions @mentions; Instagram allows $maxMentions per caption',
          field: 'text'));
    }

    if (v.media.length > carouselMax && !story) {
      out.add(ValidationIssue.error('instagram.carousel_too_big',
          '${v.media.length} files; an Instagram carousel holds at most $carouselMax',
          field: 'media'));
    }

    for (final m in v.media) {
      final alt = m.altText ?? '';
      if (alt.length > altTextMax) {
        out.add(ValidationIssue.error('instagram.alt_too_long',
            'Alt text for ${_name(m)} is ${alt.length}/$altTextMax characters',
            field: 'media'));
      }
      if (m.isVideo && m.durationMs != null && m.durationMs! < videoMinSeconds * 1000) {
        out.add(ValidationIssue.error('instagram.video_too_short',
            '${_name(m)} is shorter than $videoMinSeconds seconds',
            field: 'media'));
      }
    }

    if (story) {
      out.addAll(_storyIssues(v, handoff));
    } else if (!handoff) {
      out.addAll(_feedIssues(v));
    }
    return out;
  }

  static List<ValidationIssue> _storyIssues(PostVariant v, bool handoff) {
    final out = <ValidationIssue>[];
    if (v.media.length > 1) {
      out.add(ValidationIssue.info('instagram.story_frames',
          'Each of the ${v.media.length} files becomes a story frame of its own', field: 'media'));
    }
    if (v.text.trim().isNotEmpty && !handoff) {
      out.add(const ValidationIssue.warning('instagram.story_no_caption',
          'Instagram stories have no caption; the text will not be posted', field: 'text'));
    }
    for (final m in v.media.where((m) => m.isVideo)) {
      if (m.sizeBytes > storyVideoMaxBytes) {
        out.add(ValidationIssue.error('instagram.story_video_too_large',
            '${_name(m)} is larger than 100 MB, the limit for story videos', field: 'media'));
      }
      if (m.durationMs != null && m.durationMs! > storyVideoMaxSeconds * 1000) {
        out.add(ValidationIssue.error('instagram.story_video_too_long',
            '${_name(m)} is longer than $storyVideoMaxSeconds seconds, the limit for story videos', field: 'media'));
      }
    }
    return out;
  }

  static List<ValidationIssue> _feedIssues(PostVariant v) {
    final out = <ValidationIssue>[];
    final images = v.media.where((m) => m.isImage).toList();
    for (final m in images) {
      final r = m.aspectRatio;
      if (r == null) continue;
      if (r < minFeedRatio - _ratioTolerance || r > maxFeedRatio + _ratioTolerance) {
        out.add(ValidationIssue.error('instagram.aspect_ratio',
            '${_name(m)} has aspect ratio ${r.toStringAsFixed(2)}:1; Instagram feed photos must be between 4:5 and 1.91:1',
            field: 'media'));
      }
      if (m.width != null && m.width! < 320) {
        out.add(ValidationIssue.warning('instagram.image_small',
            '${_name(m)} is ${m.width} px wide; Instagram scales photos narrower than 320 px up', field: 'media'));
      }
    }
    if (v.media.length > 1) {
      final first = v.media.first.aspectRatio;
      final differs = first != null &&
          v.media.skip(1).any((m) => m.aspectRatio != null && (m.aspectRatio! - first).abs() > 0.02);
      if (differs) {
        out.add(const ValidationIssue.info('instagram.carousel_crop',
            'Instagram crops every carousel item to the aspect ratio of the first one', field: 'media'));
      }
    } else if (v.media.length == 1 && v.media.first.isVideo) {
      final r = v.media.first.aspectRatio;
      if (r != null && (r - 9 / 16).abs() > 0.02) {
        out.add(const ValidationIssue.info('instagram.reel_ratio',
            'This video will be posted as a Reel; 9:16 (vertical) looks best', field: 'media'));
      }
    }
    final noAltNeeded = v.media.length == 1 && v.media.first.isVideo;
    if (noAltNeeded && (v.media.first.altText ?? '').isNotEmpty) {
      out.add(const ValidationIssue.info('instagram.alt_ignored',
          'Instagram does not take alt text for Reels; it will be dropped', field: 'media'));
    }
    return out;
  }

  /// The photos Instagram takes. The API: JPEG up to 8 MB, and feed and
  /// carousel photos between 4:5 and 1.91:1 (stories take any shape). The
  /// share sheet (hand-off): JPEG, PNG or GIF; the app crops by itself.
  static PhotoFit photoFit(PlatformTier tier, PostVariant v) {
    if (tier == PlatformTier.handoff) return const PhotoFit(mimeTypes: handoffImageTypes, label: 'Instagram');
    return PhotoFit(
      minAspect: isStory(v) ? null : minFeedRatio,
      maxAspect: isStory(v) ? null : maxFeedRatio,
      mimeTypes: const {'image/jpeg'},
      maxBytes: imageMaxBytes,
      label: isStory(v) ? 'Instagram stories' : 'Instagram feed photos',
    );
  }

  /// The variant is placed as a story only ([PostPlacement.story]; also the
  /// 1.2 flag `extra['storyMode']`). A Post + Story variant is checked and
  /// fitted as its two copies ([validatePlacements]).
  static bool isStory(PostVariant v) => v.placement == PostPlacement.story;

  static String _name(MediaAttachment m) => m.fileName ?? m.id;
}
