import '../../model/account.dart';
import '../../model/artwork.dart';
import '../../model/photo_fit.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import 'art_handoff_common.dart';

/// Behance projects via hand-off.
///
/// Behance no longer issues API keys (behance.net/dev is gone) and its old
/// API never had a way to create or publish a project, so NEFORUM opens the
/// project editor with the title, description and tags ready to copy and the
/// images saved to Downloads. Adult content is allowed when the project is
/// flagged.
class BehanceAdapter extends ArtHandoffAdapter {
  static const String uploadUrl = 'https://www.behance.net/portfolio/editor';

  /// "Upload at least 808x632" for the cover.
  static const int coverMinWidth = 808;
  static const int coverMinHeight = 632;

  /// Project images: at most 50 MB and 32 megapixels.
  static const int imageMaxBytes = 50 * 1024 * 1024;
  static const int imageMaxPixels = 32000000;

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'behance',
    name: 'Behance',
    iconKey: 'behance',
    homepage: 'https://www.behance.net/',
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      titleSupported: true,
      titleRequired: true,
      hashtagsAsField: true,
      maxHashtags: 10,
      notes: 'The text is the project description; the title goes in Project Title (NEFORUM uses the first line when the '
          'post has no title). Up to 10 project tags. Behance publishes no description limit.',
    ),
    media: MediaRules(
      maxImages: unlistedMediaLimit,
      maxVideos: unlistedMediaLimit,
      requiresMedia: true,
      allowsMixedImageVideo: true,
      imageMaxBytes: imageMaxBytes,
      videoMaxBytes: 1024 * 1024 * 1024,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif'},
      videoMimeTypes: {
        'video/mp4',
        'video/quicktime',
        'video/mpeg',
        'video/x-m4v',
        'video/x-msvideo',
        'video/x-flv',
        'video/x-ms-wmv',
        'video/x-ms-asf',
        'video/3gpp',
        'video/3gpp2',
      },
      notes: 'JPEG, PNG or GIF images up to 50 MB and 32 megapixels, and videos under 1 GB. Behance sets no limit on '
          'images per project. The cover must be at least 808 x 632 pixels and cannot be a GIF.',
    ),
    accountRequirements: 'Any Behance (Adobe) account. NEFORUM never signs in to Behance; you publish the project on behance.net.',
    apiCostSummary: 'Free. Behance no longer issues API keys and never offered a way to publish projects through one, so '
        'NEFORUM prepares the project and you publish it on behance.net.',
    setupGuide: 'docs/platforms/behance.md',
    categories: {PlatformCategory.art},
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  String get connectIntro => '''
**Behance works by hand-off.** There is nothing to create or sign in to.

Behance no longer issues API keys, and its API never had a way to publish a project. When you publish artwork, NEFORUM
opens Behance's project editor, puts your description on the clipboard, lists the **title** and **tags** to copy, and
saves your images to Downloads so you can add them. Behance only receives artwork: turn on **Artwork** under **Post to**.''';

  @override
  String uploadUrlFor(PostVariant variant) => uploadUrl;

  @override
  PhotoFit? photoFit(ConnectedAccount account, PostVariant variant) =>
      super.photoFit(account, variant)?.copyWith(maxPixels: imageMaxPixels);

  @override
  List<ArtUploadStep> uploadSteps(PostVariant variant) {
    final a = variant.artwork;
    return [
      filesStep(variant, into: 'the project canvas (**Image** in the Add Content panel)'),
      const ArtUploadStep('Click **Continue** and set the **Cover Image** (at least 808 x 632 pixels, not a GIF).'),
      ?titleStep(variant, field: '**Project Title**'),
      const ArtUploadStep('Choose at least one **Creative Field**.'),
      ?tagsStep(variant, field: '**Project Tags**'),
      if (a != null && a.aiGenerated) const ArtUploadStep('List the AI tools you used under **Tools Used** (Behance asks for this).'),
      if (a != null && a.maturity != ArtworkMaturity.general) const ArtUploadStep('Tick **This project contains adult content**.'),
      ?descriptionStep(variant, field: 'the description under **Co-owners, Credits, and More**'),
      const ArtUploadStep('Click **Publish**. Behance does not save projects on its own.'),
    ];
  }

  @override
  List<ValidationIssue> siteIssues(PostVariant variant) {
    final a = variant.artwork;
    final images = artworkFiles(variant).where((m) => m.isImage).toList();
    final stills = images.where((m) => m.mimeType != 'image/gif').toList();
    return [
      if (a != null && a.maturity != ArtworkMaturity.general)
        const ValidationIssue.info('behance.adult_content', 'Tick "This project contains adult content" on Behance', field: 'artwork'),
      if (a != null && a.aiGenerated)
        const ValidationIssue.info('behance.ai_tools', 'Behance asks you to list the AI tools you used under Tools Used', field: 'artwork'),
      if (images.isNotEmpty && stills.isEmpty)
        const ValidationIssue.warning('behance.cover_gif', 'A Behance cover cannot be a GIF: add a JPEG or PNG for it', field: 'media'),
      if (stills.isNotEmpty && stills.every((m) => m.width != null && m.height != null && (m.width! < coverMinWidth || m.height! < coverMinHeight)))
        const ValidationIssue.warning('behance.cover_size', 'A Behance cover needs an image of at least 808 x 632 pixels', field: 'media'),
    ];
  }
}
