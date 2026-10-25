import '../../model/artwork.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import 'art_handoff_common.dart';

/// Weasyl visual submissions via hand-off.
///
/// Weasyl's API only reads (no upload endpoint), so NEFORUM opens the visual
/// submission form with the title, description and tags ready and the rating
/// (General, Mature, Explicit: every rating is accepted) as a step.
class WeasylAdapter extends ArtHandoffAdapter {
  static const String uploadUrl = 'https://www.weasyl.com/submit/visual';

  /// Weasyl refuses submissions with fewer tags.
  static const int minTags = 2;

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'weasyl',
    name: 'Weasyl',
    iconKey: 'weasyl',
    homepage: 'https://www.weasyl.com/',
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      titleSupported: true,
      titleRequired: true,
      hashtagsAsField: true,
      notes: 'The text is the description; the title has its own field (NEFORUM uses the first line when the post has no '
          'title). Tags are separated by spaces; Weasyl needs at least 2.',
    ),
    media: MediaRules(
      maxImages: 1,
      requiresMedia: true,
      imageMaxBytes: 50 * 1024 * 1024,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif'},
      notes: 'One image per submission: JPEG, PNG or GIF up to 50 MB. An extra thumbnail is optional.',
    ),
    accountRequirements: 'Any Weasyl account. NEFORUM never signs in to Weasyl; you submit on weasyl.com.',
    apiCostSummary: "Free. Weasyl's API cannot upload, so NEFORUM prepares the submission and you finish it on weasyl.com.",
    setupGuide: 'docs/platforms/weasyl.md',
    categories: {PlatformCategory.art},
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  String get connectIntro => '''
**Weasyl works by hand-off.** There is nothing to create or sign in to.

Weasyl's API can read but not upload. When you publish artwork, NEFORUM opens the visual submission form, puts your
description on the clipboard, lists the **title** and **tags** to copy, and saves your image to Downloads so you can add
it. You set the rating and submit. Weasyl only receives artwork: turn on **Artwork** under **Post to**.''';

  @override
  String uploadUrlFor(PostVariant variant) => uploadUrl;

  @override
  String get tagSeparator => ' ';

  @override
  List<ArtUploadStep> uploadSteps(PostVariant variant) {
    final a = variant.artwork;
    return [
      filesStep(variant, into: 'the submission file field (a thumbnail is optional)'),
      ?titleStep(variant),
      const ArtUploadStep('Choose the category, and a folder if you use one.'),
      if (a != null)
        ArtUploadStep('Set the rating to **${a.maturity == ArtworkMaturity.adult ? 'Explicit' : maturityLabel(a.maturity)}**.'),
      ?descriptionStep(variant),
      ?tagsStep(variant),
      const ArtUploadStep('Submit the form. Weasyl may ask you to crop the thumbnail next.'),
    ];
  }

  @override
  List<ValidationIssue> siteIssues(PostVariant variant) => [
        if (variant.tags.length < minTags)
          ValidationIssue.warning('weasyl.tags', 'Weasyl needs at least 2 tags (${variant.tags.length} given)', field: 'tags'),
      ];
}
