import '../../model/artwork.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import 'art_handoff_common.dart';

/// pixiv illustrations via hand-off.
///
/// pixiv publishes no developer API (its only API is the private one of its
/// own app), and its terms forbid mechanical mass actions. NEFORUM opens the
/// illustration upload page, or shares to the pixiv app on phones, with the
/// title, caption and tags ready and the age restriction and AI-generated
/// choice as steps.
class PixivAdapter extends ArtHandoffAdapter {
  static const String uploadUrl = 'https://www.pixiv.net/illustration/create';

  /// Per image and per post.
  static const int imageMaxBytes = 32 * 1024 * 1024;
  static const int postMaxBytes = 200 * 1024 * 1024;

  /// Tags: up to 10 per work, 30 characters each.
  static const int maxTags = 10;
  static const int tagMaxLength = 30;

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'pixiv',
    name: 'pixiv',
    iconKey: 'pixiv',
    homepage: 'https://www.pixiv.net/',
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      titleSupported: true,
      titleRequired: true,
      hashtagsAsField: true,
      maxHashtags: maxTags,
      notes: 'The text is the caption; the title has its own field (NEFORUM uses the first line when the post has no '
          'title). Up to 10 tags of 30 characters each.',
    ),
    media: MediaRules(
      maxImages: unlistedMediaLimit,
      requiresMedia: true,
      imageMaxBytes: imageMaxBytes,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif'},
      notes: 'JPEG, PNG or GIF (no animated GIFs: pixiv uses Ugoira for animation), up to 32 MB each and 200 MB per post. '
          'pixiv states no image count.',
    ),
    accountRequirements: 'Any pixiv account, with the pixiv app on your phone or a browser. NEFORUM never signs in to pixiv.',
    apiCostSummary: 'Free. pixiv has no public API, so NEFORUM prepares the upload and you post it on pixiv.net or in the pixiv app.',
    setupGuide: 'docs/platforms/pixiv.md',
    categories: {PlatformCategory.art},
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  String get connectIntro => '''
**pixiv works by hand-off.** There is nothing to create or sign in to.

pixiv has no public API. When you publish artwork, NEFORUM opens pixiv's illustration upload page (on a phone, it shares
your images to the pixiv app), puts your caption on the clipboard, and lists the **title** and **tags** to copy. You set
the age restriction and the AI-generated choice and post. pixiv only receives artwork: turn on **Artwork** under
**Post to**.''';

  @override
  String uploadUrlFor(PostVariant variant) => uploadUrl;

  @override
  bool get appPostsWork => true;

  @override
  String? get androidPackage => 'jp.pxv.android';

  @override
  List<ArtUploadStep> uploadSteps(PostVariant variant) {
    final a = variant.artwork;
    return [
      filesStep(variant, into: "pixiv's file picker (drag the thumbnails to set the page order)"),
      ?titleStep(variant, field: '**Title**'),
      ?descriptionStep(variant, field: '**Caption**'),
      ?tagsStep(variant, field: '**Tags**'),
      if (a != null)
        ArtUploadStep(switch (a.maturity) {
          ArtworkMaturity.general => 'Set **Age restriction** to **All ages**.',
          ArtworkMaturity.mature =>
            "Set **Age restriction** to **All ages** and tick the box for slightly sexual content (choose **R-18** if pixiv's rules call for it).",
          ArtworkMaturity.adult => 'Set **Age restriction** to **R-18** (**R-18G** for grotesque content).',
        }),
      if (a != null) ArtUploadStep('Set **AI-generated** to **${a.aiGenerated ? 'Yes' : 'No'}**.'),
      const ArtUploadStep('Click **Post**.'),
    ];
  }

  @override
  List<ValidationIssue> siteIssues(PostVariant variant) {
    final total = artworkFiles(variant).fold<int>(0, (sum, m) => sum + m.sizeBytes);
    final long = variant.tags.where((t) => t.length > tagMaxLength).toList();
    return [
      if (total > postMaxBytes)
        ValidationIssue.error('pixiv.post_too_large', 'The images are ${megabytes(total)} together; pixiv takes up to 200 MB per post', field: 'media'),
      if (long.isNotEmpty)
        ValidationIssue.warning('pixiv.tag_too_long', 'pixiv tags are up to 30 characters: ${long.map((t) => '#$t').join(', ')}', field: 'tags'),
    ];
  }
}
