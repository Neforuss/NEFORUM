import '../../model/artwork.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import 'art_handoff_common.dart';

/// ArtStation projects via hand-off.
///
/// ArtStation has no public API or developer program, and since September
/// 2026 it blocks automated tools at the network edge. NEFORUM opens the new
/// project editor in the user's own browser with the title, description and
/// tags ready (NoAI and CreatedWithAI added from the artwork details).
/// Mature work must be flagged.
class ArtStationAdapter extends ArtHandoffAdapter {
  static const String uploadUrl = 'https://www.artstation.com/myartstation/projects/new';

  /// Images must be larger than 400 x 400 and smaller than 10,000 x 10,000
  /// pixels, and under 10 MB.
  static const int imageMinSide = 400;
  static const int imageMaxSide = 10000;

  /// Video clips: free accounts 25 MB, Premium 250 MB; at most 1 minute.
  static const int freeVideoMaxBytes = 25 * 1024 * 1024;

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'artstation',
    name: 'ArtStation',
    iconKey: 'artstation',
    homepage: 'https://www.artstation.com/',
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      titleSupported: true,
      titleRequired: true,
      hashtagsAsField: true,
      notes: 'The text is the project description; the title has its own field (NEFORUM uses the first line when the post '
          'has no title). ArtStation publishes no description or tag limit.',
    ),
    media: MediaRules(
      maxImages: unlistedMediaLimit,
      maxVideos: unlistedMediaLimit,
      requiresMedia: true,
      allowsMixedImageVideo: true,
      imageMaxBytes: 10 * 1024 * 1024,
      videoMaxBytes: 250 * 1024 * 1024,
      videoMaxSeconds: 60,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif'},
      videoMimeTypes: {'video/mp4'},
      notes: 'Images larger than 400 x 400 and smaller than 10,000 x 10,000 pixels, under 10 MB (ArtStation recommends '
          'JPEG). MP4 clips up to 1 minute: 25 MB on free accounts, 250 MB with Premium.',
    ),
    accountRequirements: 'Any ArtStation account. NEFORUM never signs in to ArtStation; you publish the project on artstation.com.',
    apiCostSummary: 'Free. ArtStation has no public API, so NEFORUM prepares the project and you publish it on artstation.com.',
    setupGuide: 'docs/platforms/artstation.md',
    categories: {PlatformCategory.art},
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  String get connectIntro => '''
**ArtStation works by hand-off.** There is nothing to create or sign in to.

ArtStation has no public API and blocks automated tools. When you publish artwork, NEFORUM opens ArtStation's new
project page, puts your description on the clipboard, lists the **title** and **tags** to copy (with **NoAI** when you
ask not to train AI), and saves your files to Downloads so you can add them. ArtStation only receives artwork: turn on
**Artwork** under **Post to**.''';

  @override
  String uploadUrlFor(PostVariant variant) => uploadUrl;

  @override
  List<String> artworkTags(ArtworkDetails artwork) => [
        if (artwork.disallowAiTraining) 'NoAI',
        if (artwork.aiGenerated) 'CreatedWithAI',
      ];

  @override
  List<ArtUploadStep> uploadSteps(PostVariant variant) {
    final a = variant.artwork;
    final special = a == null ? const <String>[] : artworkTags(a);
    return [
      filesStep(variant, into: 'the project (MP4 clips as a **Video Clip**)'),
      ?titleStep(variant),
      ?descriptionStep(variant),
      const ArtUploadStep('Crop the cover thumbnail.'),
      const ArtUploadStep('Under **Categorization**, choose the **Mediums** and the **Subject Matter**, then the **Software Used**.'),
      if (tagsFor(variant).isNotEmpty)
        ArtUploadStep('Copy the **Tags** into the tags field${special.isEmpty ? '' : ' (they include ${special.join(' and ')})'}.', automatable: true),
      if (a != null && a.maturity != ArtworkMaturity.general)
        const ArtUploadStep('Tick the **mature content** checkbox. The cover thumbnail must not show mature content.'),
      const ArtUploadStep('Click **Publish**.'),
    ];
  }

  @override
  List<ValidationIssue> siteIssues(PostVariant variant) {
    final a = variant.artwork;
    final files = artworkFiles(variant);
    return [
      for (final m in files.where((m) => m.isImage && m.width != null && m.height != null))
        if (m.width! <= imageMinSide || m.height! <= imageMinSide)
          ValidationIssue.error('artstation.image_too_small',
              '${m.fileName ?? 'An image'} is ${m.width} x ${m.height}; ArtStation needs images larger than 400 x 400 pixels', field: 'media')
        else if (m.width! >= imageMaxSide || m.height! >= imageMaxSide)
          ValidationIssue.error('artstation.image_too_large',
              '${m.fileName ?? 'An image'} is ${m.width} x ${m.height}; ArtStation takes images smaller than 10,000 x 10,000 pixels', field: 'media'),
      if (files.any((m) => m.isVideo && m.sizeBytes > freeVideoMaxBytes))
        const ValidationIssue.warning('artstation.video_size', 'ArtStation takes clips over 25 MB only with Premium', field: 'media'),
      if (a != null && a.maturity != ArtworkMaturity.general)
        const ValidationIssue.info('artstation.mature', 'Tick the mature content checkbox on ArtStation', field: 'artwork'),
    ];
  }
}
