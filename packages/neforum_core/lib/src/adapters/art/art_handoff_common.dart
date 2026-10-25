import '../../handoff/handoff_plan.dart';
import '../../model/account.dart';
import '../../model/artwork.dart';
import '../../model/media.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import '../handoff_only/handoff_common.dart';

/// Images (or videos) NEFORUM hands to an art site that publishes no
/// per-post limit.
const int unlistedMediaLimit = 100;

const int _mb = 1024 * 1024;

/// [bytes] in megabytes, for messages ("12.5 MB").
String megabytes(int bytes) => '${(bytes / _mb).toStringAsFixed(1)} MB';

/// The files of [v] that are the work itself: NEFORUM text cards are never
/// artwork, so they are left out.
List<MediaAttachment> artworkFiles(PostVariant v) => [
      for (final m in v.media)
        if (!m.isTextCard) m,
    ];

/// Checks every art site makes: the post is artwork ([PostVariant.artwork])
/// and carries the work itself, an image (or a video where [d] takes one).
List<ValidationIssue> artworkIssues(PostVariant v, PlatformDescriptor d) {
  final m = d.media;
  final works = artworkFiles(v).where((x) => x.isVideo ? m.maxVideos > 0 : m.maxImages > 0);
  return [
    if (!v.isArtwork)
      ValidationIssue.error('art.not_artwork', '${d.name} only takes artwork. Turn on Artwork under Post to.', field: 'artwork'),
    if (works.isEmpty)
      ValidationIssue.error(
        'art.media_required',
        m.maxVideos > 0 ? '${d.name} needs your artwork: add an image or a video' : '${d.name} needs your artwork: add an image',
        field: 'media',
      ),
  ];
}

/// The rating on sites whose scale matches NEFORUM's (General, Mature,
/// Adult).
String maturityLabel(ArtworkMaturity m) => switch (m) {
      ArtworkMaturity.general => 'General',
      ArtworkMaturity.mature => 'Mature',
      ArtworkMaturity.adult => 'Adult',
    };

/// One step of uploading a work on an art site.
class ArtUploadStep {
  const ArtUploadStep(this.text, {this.automatable = false});

  /// Markdown, one action.
  final String text;

  /// The NEFORUM browser extension does this step itself (it attaches the
  /// files and fills in the title, description and tags), so the step is
  /// left out when the extension fills in the page.
  final bool automatable;
}

/// Base class for art portfolio and gallery sites that NEFORUM can only reach
/// by hand-off (Behance, ArtStation, Cara, pixiv, ...).
///
/// The work goes up on the site's own upload page: NEFORUM opens it, puts
/// the description on the clipboard, offers the title and tags to copy and
/// the files to save or share, and lists the site's fields (rating, AI label)
/// as numbered steps. Only artwork posts are accepted ([artworkIssues]).
abstract class ArtHandoffAdapter extends HandoffOnlyAdapter {
  /// The page where the upload for [variant] starts (sign-in protected).
  String uploadUrlFor(PostVariant variant);

  /// [uploadUrlFor] is the upload form itself, which the NEFORUM browser
  /// extension can fill in. False when it is the site's home page and the
  /// form opens from a button there.
  bool get opensUploadForm => true;

  /// The site's app can post work: phones offer the share sheet first.
  bool get appPostsWork => false;

  /// Android package of the site's app, when known.
  String? get androidPackage => null;

  /// Between tags in the site's tag field.
  String get tagSeparator => ', ';

  /// Tags the site uses for the artwork details (ArtStation's NoAI tag),
  /// put before the post's own tags.
  List<String> artworkTags(ArtworkDetails artwork) => const [];

  /// Values to copy beyond the title and the tags.
  List<HandoffSnippet> extraSnippets(PostVariant variant) => const [];

  /// The steps once the page is open, in the site's order, ending with the
  /// step that publishes.
  List<ArtUploadStep> uploadSteps(PostVariant variant);

  /// This site's own checks (rating, AI rules, tag counts), on top of the
  /// generic rules and [artworkIssues].
  List<ValidationIssue> siteIssues(PostVariant variant) => const [];

  /// Explains the hand-off in the sheet.
  String get mediaNote => '${descriptor.name} has no upload API that NEFORUM can use, so you upload the work on '
      '${appPostsWork ? 'its app or website' : 'its website'} yourself; NEFORUM prepares the title, description and tags.';

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) => [
        // artworkIssues says what is missing in the words of an art site.
        for (final i in super.validate(variant, account))
          if (i.code != 'media.required') i,
        ...artworkIssues(variant, descriptor),
        ...siteIssues(variant),
      ];

  /// The tags as the site gets them: [artworkTags] first, then the post's
  /// own, cut to the site's limit.
  List<String> tagsFor(PostVariant variant) {
    final all = [
      ...?(variant.artwork == null ? null : artworkTags(variant.artwork!)),
      for (final t in variant.tags)
        if (t.isNotEmpty) t,
    ];
    final max = descriptor.text.maxHashtags;
    return max == null ? all : all.take(max).toList();
  }

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final name = descriptor.name;
    final url = uploadUrlFor(variant);
    final files = artworkFiles(variant);
    final title = (variant.title ?? '').trim();
    final tags = tagsFor(variant);
    final steps = uploadSteps(variant);
    final page = opensUploadForm ? "$name's upload page" : name;
    final open = appPostsWork
        ? 'On a phone, pick **$name** in the share sheet. On a computer, $page opens; sign in if asked.'
        : '$page opens (sign in if asked).';
    return HandoffPlan(
      platformId: id,
      preferred: appPostsWork && files.isNotEmpty ? HandoffMethod.shareSheet : HandoffMethod.manual,
      clipboardText: nonEmptyOrNull(handoffFullText(variant)),
      shareFiles: files,
      androidPackage: androidPackage,
      desktopUrl: url,
      composerUrl: opensUploadForm ? Uri.parse(url) : null,
      composerInstructions: opensUploadForm
          ? _numbered([
              "$name's upload page opens in your browser (sign in if asked).",
              'The NEFORUM extension adds your files, title, description and tags. Copy anything it misses from here.',
              for (final s in steps)
                if (!s.automatable) s.text,
            ])
          : null,
      snippets: [
        if (title.isNotEmpty) HandoffSnippet('Title', title),
        if (tags.isNotEmpty) HandoffSnippet('Tags', tags.join(tagSeparator)),
        ...extraSnippets(variant),
      ],
      instructions: _numbered([open, for (final s in steps) s.text]),
      mediaNote: mediaNote,
    );
  }

  static String _numbered(List<String> steps) => [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n');

  // ---- step helpers ------------------------------------------------------

  /// Adds the files to the form: saved to Downloads, then picked or dragged
  /// in. Without files, a reminder that the site needs the work.
  ArtUploadStep filesStep(PostVariant variant, {String into = 'the upload form'}) {
    final files = artworkFiles(variant);
    if (files.isEmpty) return ArtUploadStep('${descriptor.name} needs your artwork: add an image in NEFORUM first.');
    final noun = files.any((m) => m.isVideo) ? (files.length == 1 ? 'file' : 'files') : (files.length == 1 ? 'image' : 'images');
    final where = appPostsWork ? 'On a computer, click' : 'Click';
    return ArtUploadStep('$where **Save media to Downloads** here, then add the $noun in $into (or drag them in).', automatable: true);
  }

  /// Copies the title, when the post has one.
  ArtUploadStep? titleStep(PostVariant variant, {String field = 'the title field'}) =>
      (variant.title ?? '').trim().isEmpty ? null : ArtUploadStep('Copy the **Title** into $field.', automatable: true);

  /// Pastes the description, when the post has one.
  ArtUploadStep? descriptionStep(PostVariant variant, {String field = 'the description field'}) => handoffFullText(variant).isEmpty
      ? null
      : ArtUploadStep('Paste the description into $field (it is on the clipboard).', automatable: true);

  /// Copies the tags, when there are any.
  ArtUploadStep? tagsStep(PostVariant variant, {String field = 'the tags field'}) =>
      tagsFor(variant).isEmpty ? null : ArtUploadStep('Copy the **Tags** into $field.', automatable: true);
}
