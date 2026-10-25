import '../../model/artwork.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import 'art_handoff_common.dart';

/// Newgrounds art via hand-off.
///
/// Newgrounds' only API (Newgrounds.io) covers game medals and scoreboards,
/// nothing for art. NEFORUM opens the new art project form with the title,
/// description and tags ready. Newgrounds rates the work (E, T, M, A) from
/// the artist's answers, so adult work is welcome when rated; the Art Portal
/// does not take AI-generated art.
class NewgroundsAdapter extends ArtHandoffAdapter {
  static const String uploadUrl = 'https://www.newgrounds.com/projects/art/new';

  static const int maxTags = 12;

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'newgrounds',
    name: 'Newgrounds',
    iconKey: 'newgrounds',
    homepage: 'https://www.newgrounds.com/art',
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      titleSupported: true,
      titleRequired: true,
      hashtagsAsField: true,
      maxHashtags: maxTags,
      notes: 'The text is the description; the title has its own field (NEFORUM uses the first line when the post has no '
          'title). Up to 12 tags.',
    ),
    media: MediaRules(
      maxImages: unlistedMediaLimit,
      requiresMedia: true,
      imageMaxBytes: 150 * 1024 * 1024,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif', 'image/webp'},
      notes: 'GIF, JPEG, PNG or WebP, up to 150 MB per image (Newgrounds community wiki). Art reaches the Art Portal once '
          'the artist is scouted.',
    ),
    accountRequirements: 'Any Newgrounds account. NEFORUM never signs in to Newgrounds; you publish on newgrounds.com.',
    apiCostSummary: 'Free. Newgrounds has no API for art, so NEFORUM prepares the project and you publish it on newgrounds.com.',
    setupGuide: 'docs/platforms/newgrounds.md',
    categories: {PlatformCategory.art},
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  String get connectIntro => '''
**Newgrounds works by hand-off.** There is nothing to create or sign in to.

Newgrounds has no API for art. When you publish artwork, NEFORUM opens the new art project form, puts your description on
the clipboard, lists the **title** and **tags** to copy, and saves your images to Downloads so you can add them. You
answer the rating questions and publish. Newgrounds only receives artwork: turn on **Artwork** under **Post to**.''';

  @override
  String uploadUrlFor(PostVariant variant) => uploadUrl;

  @override
  List<ArtUploadStep> uploadSteps(PostVariant variant) {
    final a = variant.artwork;
    final rating = switch (a?.maturity) {
      ArtworkMaturity.general => ' Work for everyone is rated E.',
      ArtworkMaturity.adult => ' Explicit work is rated A.',
      _ => '',
    };
    return [
      filesStep(variant, into: 'the project'),
      const ArtUploadStep('Crop the thumbnail.'),
      ?titleStep(variant),
      ?descriptionStep(variant),
      ?tagsStep(variant),
      const ArtUploadStep('Choose the category: 3D Art, Comic, Fine Art, Illustration, Pixel Art or Other.'),
      ArtUploadStep('Answer the rating questions (nudity, violence, explicit text, adult themes); Newgrounds rates the work '
          'E, T, M or A from your answers.$rating'),
      const ArtUploadStep('Tick **finished piece** to include it in the Art Portal (optional).'),
      const ArtUploadStep('Click **Publish** and agree to the terms. The form saves each field as you go.'),
    ];
  }

  @override
  List<ValidationIssue> siteIssues(PostVariant variant) => [
        if (variant.artwork?.aiGenerated ?? false)
          const ValidationIssue.warning(
              'newgrounds.ai', 'The Newgrounds Art Portal does not accept AI-generated art (minor AI help that you disclose aside)', field: 'artwork'),
      ];
}
