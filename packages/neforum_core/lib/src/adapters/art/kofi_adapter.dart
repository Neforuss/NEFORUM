import '../../model/artwork.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import 'art_handoff_common.dart';

/// Ko-fi image posts via hand-off.
///
/// Ko-fi's API only reports payments, so NEFORUM opens ko-fi.com with the
/// title, text and tags ready; the user starts an Image Post from their page.
/// Images in an Image Post also go to the Ko-fi gallery.
class KofiAdapter extends ArtHandoffAdapter {
  static const String homeUrl = 'https://ko-fi.com/';

  /// Free accounts; Ko-fi Gold takes up to 60 MB.
  static const int freeImageMaxBytes = 25 * 1024 * 1024;

  /// Ko-fi publishes no image count; the PostyBirb cross-poster sends up to 8
  /// gallery images.
  static const int maxImages = 8;

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'kofi',
    name: 'Ko-fi',
    iconKey: 'kofi',
    homepage: homeUrl,
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      titleSupported: true,
      hashtagsAsField: true,
      notes: 'The text is the post body; the title and tags have their own fields. Ko-fi publishes no text limit.',
    ),
    media: MediaRules(
      maxImages: maxImages,
      requiresMedia: true,
      imageMaxBytes: 60 * 1024 * 1024,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif'},
      notes: 'JPEG, PNG or GIF up to 25 MB (60 MB with Ko-fi Gold). Ko-fi publishes no image count; NEFORUM hands over up '
          'to 8, the gallery limit the PostyBirb cross-poster uses.',
    ),
    accountRequirements: 'Any Ko-fi creator page. NEFORUM never signs in to Ko-fi; you publish on ko-fi.com.',
    apiCostSummary: "Free. Ko-fi's API only reports payments, so NEFORUM prepares the image post and you publish it on ko-fi.com.",
    setupGuide: 'docs/platforms/kofi.md',
    categories: {PlatformCategory.art},
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  String get connectIntro => '''
**Ko-fi works by hand-off.** There is nothing to create or sign in to.

Ko-fi's API only reports payments; it cannot post. When you publish artwork, NEFORUM opens ko-fi.com, puts your text on
the clipboard, lists the **title** and **tags** to copy, and saves your images to Downloads. You start an Image Post on
your page, add them and publish. Ko-fi only receives artwork: turn on **Artwork** under **Post to**.''';

  @override
  String uploadUrlFor(PostVariant variant) => homeUrl;

  @override
  bool get opensUploadForm => false;

  @override
  List<ArtUploadStep> uploadSteps(PostVariant variant) => [
        const ArtUploadStep('Open your Ko-fi page and click **Create**, then **Add Something**, then **Image Post**.'),
        filesStep(variant, into: 'the image post'),
        ?titleStep(variant),
        ?descriptionStep(variant, field: 'the post body'),
        ?tagsStep(variant),
        const ArtUploadStep('Choose the audience: everyone, monthly supporters or specific membership tiers.'),
        const ArtUploadStep('Click **Publish**. The images also appear in your Ko-fi gallery.'),
      ];

  @override
  List<ValidationIssue> siteIssues(PostVariant variant) => [
        if (artworkFiles(variant).any((m) => m.isImage && m.sizeBytes > freeImageMaxBytes))
          const ValidationIssue.warning('kofi.image_size', 'Ko-fi takes images over 25 MB only with Ko-fi Gold', field: 'media'),
        if (variant.artwork?.maturity == ArtworkMaturity.adult)
          const ValidationIssue.warning('kofi.adult', 'Ko-fi is for a general audience: check its rules before posting explicit work', field: 'artwork'),
      ];
}
