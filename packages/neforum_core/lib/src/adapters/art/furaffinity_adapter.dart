import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import 'art_handoff_common.dart';

/// Fur Affinity submissions via hand-off.
///
/// Fur Affinity has no API and sits behind bot protection. NEFORUM opens the
/// submission page with the title, description and keywords ready and the
/// rating (General, Mature, Adult: every rating is accepted) as a step. Its
/// upload policy forbids AI-generated work.
class FurAffinityAdapter extends ArtHandoffAdapter {
  static const String uploadUrl = 'https://www.furaffinity.net/submit/';

  /// Keyword rules the open-source PostyBirb cross-poster checks: at least 3
  /// keywords of 3 or more characters, 500 characters in all.
  static const int minKeywords = 3;
  static const int keywordMinLength = 3;
  static const int keywordsMaxLength = 500;

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'furaffinity',
    name: 'Fur Affinity',
    iconKey: 'furaffinity',
    homepage: 'https://www.furaffinity.net/',
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      titleSupported: true,
      titleRequired: true,
      hashtagsAsField: true,
      notes: 'The text is the description; the title has its own field (NEFORUM uses the first line when the post has no '
          'title). Keywords are separated by spaces: at least 3 of 3 or more characters, 500 characters in all.',
    ),
    media: MediaRules(
      maxImages: 1,
      requiresMedia: true,
      imageMaxBytes: 10 * 1024 * 1024,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif'},
      notes: 'One file per submission, about 10 MB (Fur Affinity shrinks large images). An extra thumbnail is optional.',
    ),
    accountRequirements: 'Any Fur Affinity account. NEFORUM never signs in to Fur Affinity; you submit on furaffinity.net.',
    apiCostSummary: 'Free. Fur Affinity has no API, so NEFORUM prepares the submission and you finish it on furaffinity.net.',
    setupGuide: 'docs/platforms/furaffinity.md',
    categories: {PlatformCategory.art},
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  String get connectIntro => '''
**Fur Affinity works by hand-off.** There is nothing to create or sign in to.

Fur Affinity has no API. When you publish artwork, NEFORUM opens the submission page, puts your description on the
clipboard, lists the **title** and **keywords** to copy, and saves your image to Downloads so you can add it. You set the
rating and finalize. Fur Affinity only receives artwork: turn on **Artwork** under **Post to**.''';

  @override
  String uploadUrlFor(PostVariant variant) => uploadUrl;

  @override
  String get tagSeparator => ' ';

  @override
  List<ArtUploadStep> uploadSteps(PostVariant variant) {
    final a = variant.artwork;
    return [
      const ArtUploadStep('Choose **Artwork** as the submission type.'),
      filesStep(variant, into: 'the upload step (a thumbnail is optional)'),
      ?titleStep(variant),
      ?descriptionStep(variant),
      ?tagsStep(variant, field: 'the keywords field'),
      if (a != null) ArtUploadStep('Set the rating to **${maturityLabel(a.maturity)}**.'),
      const ArtUploadStep('Choose the category, theme, species and gender, and a folder if you use one.'),
      const ArtUploadStep('Click **Finalize**.'),
    ];
  }

  @override
  List<ValidationIssue> siteIssues(PostVariant variant) {
    final usable = variant.tags.where((t) => t.length >= keywordMinLength).length;
    final length = variant.tags.join(' ').length;
    return [
      if (usable < minKeywords)
        const ValidationIssue.warning('furaffinity.keywords', 'Fur Affinity needs at least 3 keywords of 3 or more characters', field: 'tags'),
      if (length > keywordsMaxLength)
        ValidationIssue.warning('furaffinity.keywords_length', 'The keywords are $length characters; Fur Affinity takes 500', field: 'tags'),
      if (variant.artwork?.aiGenerated ?? false)
        const ValidationIssue.error('furaffinity.ai', 'Fur Affinity does not accept AI-generated work', field: 'artwork'),
    ];
  }
}
