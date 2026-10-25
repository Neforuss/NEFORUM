import '../../model/artwork.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import 'art_handoff_common.dart';

/// Artfol posts via hand-off.
///
/// Artfol, an AI-free portfolio network, has no API. NEFORUM shares the
/// images to the Artfol app on phones and opens artfol.app on a computer,
/// with the title, caption and tags ready to copy. AI-generated art is not
/// accepted.
class ArtfolAdapter extends ArtHandoffAdapter {
  static const String homeUrl = 'https://artfol.app/';

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'artfol',
    name: 'Artfol',
    iconKey: 'artfol',
    homepage: homeUrl,
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      titleSupported: true,
      hashtagsAsField: true,
      notes: 'Artfol does not publish its fields or limits; NEFORUM gives you the title, caption and tags to copy.',
    ),
    media: MediaRules(
      maxImages: unlistedMediaLimit,
      requiresMedia: true,
      imageMimeTypes: {'image/jpeg', 'image/png'},
      notes: 'Artfol publishes no media limits. Older reviews mention one image per post.',
    ),
    accountRequirements: 'Any Artfol account, with the Artfol app on your phone or a browser. NEFORUM never signs in to Artfol.',
    apiCostSummary: 'Free. Artfol has no API, so NEFORUM hands your images to the Artfol app (or opens artfol.app) and you post.',
    setupGuide: 'docs/platforms/artfol.md',
    categories: {PlatformCategory.art},
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  String get connectIntro => '''
**Artfol works by hand-off.** There is nothing to create or sign in to.

Artfol has no API. When you publish artwork on your phone, NEFORUM shares your **images** to the Artfol app and copies
your caption; on a computer it opens artfol.app and saves your images to Downloads. Artfol is AI-free and only receives
artwork: turn on **Artwork** under **Post to**.''';

  @override
  String uploadUrlFor(PostVariant variant) => homeUrl;

  @override
  bool get opensUploadForm => false;

  @override
  bool get appPostsWork => true;

  @override
  List<ArtUploadStep> uploadSteps(PostVariant variant) => [
        const ArtUploadStep('Start a new post.'),
        filesStep(variant, into: 'the post'),
        ?titleStep(variant),
        ?descriptionStep(variant, field: 'the caption'),
        ?tagsStep(variant),
        const ArtUploadStep('Choose the categories, and a challenge if you are entering one.'),
        const ArtUploadStep('Post it.'),
      ];

  @override
  List<ValidationIssue> siteIssues(PostVariant variant) {
    final a = variant.artwork;
    if (a == null) return const [];
    return [
      if (a.aiGenerated) const ValidationIssue.error('artfol.ai', 'Artfol does not accept AI-generated art', field: 'artwork'),
      if (a.maturity == ArtworkMaturity.adult)
        const ValidationIssue.warning('artfol.adult', 'Artfol is for a general audience: check its rules before posting explicit work', field: 'artwork'),
    ];
  }
}
