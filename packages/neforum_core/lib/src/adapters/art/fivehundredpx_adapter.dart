import '../../model/artwork.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import 'art_handoff_common.dart';

/// 500px photos via hand-off.
///
/// 500px closed its public API in 2018, so NEFORUM shares the photos to the
/// 500px app on phones and opens 500px.com on a computer, with the title,
/// description and keywords ready to copy. Mature work is marked NSFW.
class FiveHundredPxAdapter extends ArtHandoffAdapter {
  static const String homeUrl = 'https://500px.com/';

  /// Photos per upload.
  static const int maxImages = 30;

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'fivehundredpx',
    name: '500px',
    iconKey: 'fivehundredpx',
    homepage: homeUrl,
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      titleSupported: true,
      hashtagsAsField: true,
      notes: 'The text is the photo description; the title and keywords have their own fields.',
    ),
    media: MediaRules(
      maxImages: maxImages,
      requiresMedia: true,
      imageMimeTypes: {'image/jpeg'},
      notes: 'Up to 30 photos per upload; 500px recommends JPEG. Free (Basic) accounts get 60 uploads a month, and '
          'deleting a photo does not give one back. 500px watermarks uploads.',
    ),
    accountRequirements: 'Any 500px account, with the 500px app on your phone or a browser. NEFORUM never signs in to 500px.',
    apiCostSummary: 'Free. 500px closed its API in 2018, so NEFORUM hands your photos to the 500px app (or opens 500px.com) '
        'and you publish.',
    setupGuide: 'docs/platforms/fivehundredpx.md',
    categories: {PlatformCategory.art},
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  String get connectIntro => '''
**500px works by hand-off.** There is nothing to create or sign in to.

500px closed its API in 2018. When you publish artwork on your phone, NEFORUM shares your **photos** to the 500px app
and copies your description; on a computer it opens 500px.com and saves your photos to Downloads. 500px only receives
artwork: turn on **Artwork** under **Post to**.''';

  @override
  String uploadUrlFor(PostVariant variant) => homeUrl;

  @override
  bool get opensUploadForm => false;

  @override
  bool get appPostsWork => true;

  @override
  List<ArtUploadStep> uploadSteps(PostVariant variant) {
    final a = variant.artwork;
    return [
      const ArtUploadStep('Click **Upload** at the top right.'),
      filesStep(variant, into: 'the uploader'),
      ?titleStep(variant),
      ?descriptionStep(variant),
      ?tagsStep(variant, field: 'the keywords field'),
      const ArtUploadStep('Choose a category, and the location, licence and privacy you want.'),
      if (a != null && a.maturity != ArtworkMaturity.general) const ArtUploadStep('Turn on **NSFW**.'),
      const ArtUploadStep('Click **Publish**.'),
    ];
  }

  @override
  List<ValidationIssue> siteIssues(PostVariant variant) => [
        if (variant.artwork != null && variant.artwork!.maturity != ArtworkMaturity.general)
          const ValidationIssue.info('fivehundredpx.nsfw', 'Turn on NSFW for this photo on 500px', field: 'artwork'),
      ];
}
