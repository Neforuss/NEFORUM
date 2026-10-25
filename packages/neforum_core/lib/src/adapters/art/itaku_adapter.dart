import '../../handoff/handoff_plan.dart';
import '../../model/artwork.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import 'art_handoff_common.dart';

/// Itaku gallery uploads via hand-off.
///
/// Itaku's web app uses an internal API that is not offered to anyone else,
/// so NEFORUM opens the right upload page (one image, several images, or a
/// video) with the title, description, tags and content warning ready, and
/// the maturity rating (SFW, Questionable, NSFW) as a step. AI-generated
/// images are not allowed in its feed or public gallery.
class ItakuAdapter extends ArtHandoffAdapter {
  static const String imageUploadUrl = 'https://itaku.ee/new/image';
  static const String imagesUploadUrl = 'https://itaku.ee/new/images';
  static const String videoUploadUrl = 'https://itaku.ee/new/video';

  static const int descriptionMax = 5000;
  static const int titleMax = 100;
  static const int contentWarningMax = 30;

  /// Itaku refuses images with fewer tags.
  static const int minTags = 5;

  /// Free accounts; supporters can upload more.
  static const int freeImageMaxBytes = 10 * 1024 * 1024;
  static const int freeBatchMaxBytes = 250 * 1024 * 1024;
  static const int freeVideoMaxBytes = 250 * 1024 * 1024;

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'itaku',
    name: 'Itaku',
    iconKey: 'itaku',
    homepage: 'https://itaku.ee/',
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      maxLength: descriptionMax,
      titleSupported: true,
      titleRequired: true,
      titleMax: titleMax,
      hashtagsAsField: true,
      supportsContentWarning: true,
      notes: 'Description up to 5,000 characters, title up to 100, content warning up to 30. Itaku needs at least 5 tags.',
    ),
    media: MediaRules(
      maxImages: unlistedMediaLimit,
      maxVideos: 1,
      requiresMedia: true,
      imageMaxBytes: 100 * 1024 * 1024,
      notes: 'Up to 100 images per upload, or one video. Free accounts take images up to 10 MB (250 MB per upload) and '
          'videos up to 250 MB; supporters can upload more.',
    ),
    accountRequirements: 'Any Itaku account. NEFORUM never signs in to Itaku; you submit on itaku.ee.',
    apiCostSummary: 'Free. Itaku has no public API, so NEFORUM prepares the upload and you submit it on itaku.ee.',
    setupGuide: 'docs/platforms/itaku.md',
    categories: {PlatformCategory.art},
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  String get connectIntro => '''
**Itaku works by hand-off.** There is nothing to create or sign in to.

Itaku has no public API. When you publish artwork, NEFORUM opens Itaku's upload page, puts your description on the
clipboard, lists the **title**, **tags** and content warning to copy, and saves your files to Downloads so you can add
them. You set the maturity rating and submit. Itaku only receives artwork: turn on **Artwork** under **Post to**.''';

  @override
  String uploadUrlFor(PostVariant variant) {
    final files = artworkFiles(variant);
    if (files.any((m) => m.isVideo)) return videoUploadUrl;
    return files.length > 1 ? imagesUploadUrl : imageUploadUrl;
  }

  @override
  List<HandoffSnippet> extraSnippets(PostVariant variant) {
    final cw = (variant.contentWarning ?? '').trim();
    return [if (cw.isNotEmpty) HandoffSnippet('Content warning', cw)];
  }

  @override
  List<ArtUploadStep> uploadSteps(PostVariant variant) {
    final a = variant.artwork;
    return [
      filesStep(variant, into: 'the drop zone'),
      ?titleStep(variant),
      ?descriptionStep(variant),
      ?tagsStep(variant),
      if ((variant.contentWarning ?? '').trim().isNotEmpty)
        const ArtUploadStep('Copy the **Content warning** into the content warning field.', automatable: true),
      if (a != null)
        ArtUploadStep('Set **Maturity rating** to **${switch (a.maturity) {
          ArtworkMaturity.general => 'SFW',
          ArtworkMaturity.mature => 'Questionable',
          ArtworkMaturity.adult => 'NSFW',
        }}**.'),
      const ArtUploadStep('Choose gallery folders and the visibility if you want to.'),
      const ArtUploadStep('Click **Submit** and confirm the maturity check.'),
    ];
  }

  @override
  List<ValidationIssue> siteIssues(PostVariant variant) {
    final files = artworkFiles(variant);
    final images = files.where((m) => m.isImage).toList();
    final batch = images.fold<int>(0, (sum, m) => sum + m.sizeBytes);
    final cw = (variant.contentWarning ?? '').trim();
    return [
      if (variant.tags.length < minTags)
        ValidationIssue.warning('itaku.tags', 'Itaku needs at least 5 tags (${variant.tags.length} given)', field: 'tags'),
      if (cw.length > contentWarningMax)
        ValidationIssue.warning('itaku.content_warning', 'Itaku content warnings are up to 30 characters (${cw.length} given)', field: 'contentWarning'),
      if (images.any((m) => m.sizeBytes > freeImageMaxBytes))
        const ValidationIssue.warning('itaku.image_size', 'Free Itaku accounts take images up to 10 MB', field: 'media'),
      if (images.length > 1 && batch > freeBatchMaxBytes)
        ValidationIssue.warning('itaku.batch_size', 'The images are ${megabytes(batch)} together; free Itaku accounts take 250 MB per upload', field: 'media'),
      if (files.any((m) => m.isVideo && m.sizeBytes > freeVideoMaxBytes))
        const ValidationIssue.warning('itaku.video_size', 'Free Itaku accounts take videos up to 250 MB', field: 'media'),
      if (variant.artwork?.aiGenerated ?? false)
        const ValidationIssue.error('itaku.ai', 'Itaku does not allow AI-generated images in its feed or public gallery', field: 'artwork'),
    ];
  }
}
