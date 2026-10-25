/// Shared pieces of the art sites NEFORUM posts to through an API
/// (DeviantArt, Dribbble, Pixelfed, Flickr, Inkbunny): the artwork checks,
/// the title and description they take, a multipart body with repeated
/// fields, and the hand-off to an upload page.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../model/artwork.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../../text/rules_validator.dart';

/// The checks every art site makes: the post is artwork
/// ([PostVariant.artwork]) and carries at least one image.
List<ValidationIssue> artworkIssues(PostVariant v, String siteName) => [
      if (!v.isArtwork)
        ValidationIssue.error(
          'art.not_artwork',
          '$siteName only receives artwork. Turn on Artwork for this post, or leave $siteName out.',
          field: 'account',
        ),
      if (!v.media.any((m) => m.isImage))
        ValidationIssue.error('art.image_required', '$siteName needs at least one image.', field: 'media'),
    ];

/// [RulesValidator.validate] for an art site, with [artworkIssues] in place
/// of the generic "needs an image or a video".
List<ValidationIssue> validateArtwork(PostVariant v, PlatformDescriptor d, {PlatformTier? tier}) =>
    RulesValidator.validate(v, d, tier: tier)
      ..removeWhere((i) => i.code == 'media.required')
      ..addAll(artworkIssues(v, d.name));

/// The error [validateArtwork] stops a publish with: every error message,
/// as one validation failure. Null when there is none.
PublishError? artworkRejection(List<ValidationIssue> issues) {
  final errors = issues.where((i) => i.isError).toList();
  if (errors.isEmpty) return null;
  return PublishError.validation(errors.map((i) => i.message).join('; '));
}

/// The work's title: the post's title, else its first line, at most [max]
/// characters when given.
String artworkTitle(PostVariant v, {int? max}) {
  final t = (v.title ?? '').trim();
  final title = t.isNotEmpty ? t : v.text.trim().split('\n').first.trim();
  if (max == null || title.length <= max) return title;
  return '${title.substring(0, max - 1).trimRight()}…';
}

/// The work's description: the post's text, thread parts joined.
String artworkDescription(PostVariant v) => (v.isThread ? v.threadParts.join('\n\n') : v.text).trim();

/// The rating in words, for hand-off steps.
String maturityLabel(ArtworkMaturity m) => switch (m) {
      ArtworkMaturity.general => 'general audiences',
      ArtworkMaturity.mature => 'mature',
      ArtworkMaturity.adult => 'adult (explicit)',
    };

/// A `multipart/form-data` body that may repeat a field name (`tags[]`,
/// `uploadedfile[]`), which [NeforumHttp.multipart]'s field map cannot. Send
/// [bytes] with [contentType] through [NeforumHttp.send].
class MultipartBody {
  MultipartBody({String? boundary}) : boundary = boundary ?? _randomBoundary();

  final String boundary;
  final BytesBuilder _out = BytesBuilder(copy: false);

  String get contentType => 'multipart/form-data; boundary=$boundary';

  /// Adds a text field. Call it again with the same [name] to repeat it.
  void field(String name, String value) {
    _out
      ..add(utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="${_quote(name)}"\r\n\r\n'))
      ..add(utf8.encode(value))
      ..add(_crlf);
  }

  /// Adds a file part.
  void file(String name, Uint8List bytes, {required String fileName, required String contentType}) {
    _out
      ..add(utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="${_quote(name)}"; '
          'filename="${_quote(fileName)}"\r\nContent-Type: $contentType\r\n\r\n'))
      ..add(bytes)
      ..add(_crlf);
  }

  /// The finished body. Adds the closing boundary; call once.
  Uint8List get bytes {
    _out.add(utf8.encode('--$boundary--\r\n'));
    return _out.takeBytes();
  }

  static final _crlf = utf8.encode('\r\n');

  /// Quotes and line breaks cannot appear inside a header parameter.
  static String _quote(String s) => s.replaceAll('"', '%22').replaceAll('\r', ' ').replaceAll('\n', ' ');

  static String _randomBoundary() {
    final r = Random.secure();
    return 'neforum-${List.generate(24, (_) => r.nextInt(36).toRadixString(36)).join()}';
  }
}

/// Hand-off to an art site's upload page: the description on the clipboard,
/// the title and tags to copy one by one, the rating and AI labels as steps,
/// and the images in the share sheet on phones (first when the site has an
/// app, [hasApp]) or in Downloads on a computer.
HandoffPlan artworkHandoff(
  PostVariant v, {
  required String platformId,
  required String name,
  required String uploadUrl,
  bool hasApp = false,
  bool browserExtensionFills = false,
  String? androidPackage,
  int? titleMax,
  int? maxTags,
  String tagSeparator = ', ',
  String openStep = '',
  String descriptionStep = '',
  String continueStep = '',
  List<String> ratingSteps = const [],
  String finishStep = '',
}) {
  final title = artworkTitle(v, max: titleMax);
  final description = artworkDescription(v);
  final tags = maxTags == null ? v.tags : v.tags.take(maxTags).toList();
  final files = v.media.length;
  final steps = [
    openStep.isNotEmpty ? openStep : "$name's upload page opens (sign in if asked).",
    if (files == 0)
      '$name needs an image: add one in NEFORUM first, or pick it on $name.'
    else
      "Add your ${files == 1 ? 'image' : '$files files'}: click **Save media to Downloads** here, then pick "
          "${files == 1 ? 'it' : 'them'} in $name's file picker (or drag ${files == 1 ? 'it' : 'them'} in).",
    if (title.isNotEmpty) 'Copy the **Title** into the title field.',
    if (description.isNotEmpty)
      descriptionStep.isNotEmpty ? descriptionStep : 'Paste the description (it is on the clipboard).',
    if (continueStep.isNotEmpty) continueStep,
    if (tags.isNotEmpty) 'Copy the **Tags** into the tags field.',
    ...ratingSteps,
    finishStep.isNotEmpty ? finishStep : 'Publish on $name.',
  ];
  final instructions = [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n');
  return HandoffPlan(
    platformId: platformId,
    preferred: hasApp && files > 0 ? HandoffMethod.shareSheet : HandoffMethod.manual,
    clipboardText: description.isEmpty ? null : description,
    shareText: description.isEmpty ? null : description,
    shareFiles: v.media,
    androidPackage: androidPackage,
    desktopUrl: uploadUrl,
    composerUrl: browserExtensionFills ? Uri.parse(uploadUrl) : null,
    composerInstructions: browserExtensionFills
        ? [
            "1. $name's upload page opens in your browser and the NEFORUM extension fills in the images, title, "
                'description and tags.',
            for (var i = 0; i < ratingSteps.length; i++) '${i + 2}. ${ratingSteps[i]}',
            '${ratingSteps.length + 2}. Check everything, then publish on $name.',
          ].join('\n')
        : null,
    snippets: [
      if (title.isNotEmpty) HandoffSnippet('Title', title),
      if (tags.isNotEmpty) HandoffSnippet('Tags', tags.join(tagSeparator)),
    ],
    instructions: instructions,
    mediaNote: files == 0
        ? null
        : hasApp
            ? 'On a phone, share the images to the $name app. On a computer, upload them on $name\'s website: '
                'NEFORUM prepares the title, description and tags.'
            : '$name has no app to share to, so you upload the images on its website; NEFORUM prepares the title, '
                'description and tags.',
  );
}
