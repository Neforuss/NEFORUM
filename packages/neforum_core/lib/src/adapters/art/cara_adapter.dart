import '../../model/artwork.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import 'art_handoff_common.dart';

/// Cara posts via hand-off.
///
/// Cara has no API of any kind and keeps its site behind a bot wall. NEFORUM
/// shares the images to the Cara app on phones and opens cara.app on a
/// computer, with the post text on the clipboard. Cara hosts no NSFW work and
/// keeps AI-generated work out of portfolios.
class CaraAdapter extends ArtHandoffAdapter {
  static const String homeUrl = 'https://cara.app/';

  /// Post text limit.
  static const int textMax = 1200;

  /// Cara publishes no image limit; users report 10 per post.
  static const int maxImages = 10;

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'cara',
    name: 'Cara',
    iconKey: 'cara',
    homepage: homeUrl,
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      maxLength: textMax,
      notes: 'Post text up to 1,200 characters. Cara has no title field, so tags go into the text as hashtags.',
    ),
    media: MediaRules(
      maxImages: maxImages,
      requiresMedia: true,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif'},
      notes: 'Images and GIFs. Cara publishes no file size or image limit; users report 10 images per post, so NEFORUM '
          'hands over up to 10. Videos only as YouTube or Sketchfab embeds. Images cannot be changed after posting.',
    ),
    accountRequirements: 'Any Cara account, with the Cara app on your phone or a browser. NEFORUM never signs in to Cara.',
    apiCostSummary: 'Free. Cara has no API, so NEFORUM hands your images to the Cara app (or opens cara.app) and you post.',
    setupGuide: 'docs/platforms/cara.md',
    categories: {PlatformCategory.art},
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  String get connectIntro => '''
**Cara works by hand-off.** There is nothing to create or sign in to.

Cara has no API. When you publish artwork on your phone, NEFORUM shares your **images** to the Cara app and copies your
text; on a computer it opens cara.app and saves your images to Downloads. Cara hosts no NSFW work and only receives
artwork: turn on **Artwork** under **Post to**.''';

  @override
  String uploadUrlFor(PostVariant variant) => homeUrl;

  @override
  bool get opensUploadForm => false;

  @override
  bool get appPostsWork => true;

  @override
  String? get androidPackage => 'com.caraproject.app';

  @override
  List<ArtUploadStep> uploadSteps(PostVariant variant) {
    final ai = variant.artwork?.aiGenerated ?? false;
    return [
      const ArtUploadStep('Click **Post** to open the composer.'),
      filesStep(variant, into: 'the composer'),
      ?descriptionStep(variant, field: 'the post text'),
      const ArtUploadStep('Crop the thumbnail.'),
      if (ai)
        const ArtUploadStep('Leave **Add to Portfolio** off and label the post as made with AI: Cara keeps AI-generated work out of portfolios.')
      else
        const ArtUploadStep('Tick **Add to Portfolio** to show the work in your portfolio too (optional).'),
      const ArtUploadStep('Click **Post**. Cara cannot change the images afterwards, only the text.'),
    ];
  }

  @override
  List<ValidationIssue> siteIssues(PostVariant variant) {
    final a = variant.artwork;
    if (a == null) return const [];
    return [
      if (a.maturity == ArtworkMaturity.adult)
        const ValidationIssue.error('cara.adult', 'Cara does not host NSFW work', field: 'artwork')
      else if (a.maturity == ArtworkMaturity.mature)
        const ValidationIssue.warning('cara.mature', 'Cara does not host NSFW work: check that this piece is within its rules', field: 'artwork'),
      if (a.aiGenerated)
        const ValidationIssue.warning('cara.ai', 'Cara keeps AI-generated work out of portfolios and asks for an AI label', field: 'artwork'),
    ];
  }
}
