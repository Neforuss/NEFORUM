import '../../handoff/handoff_plan.dart';
import '../../model/post_variant.dart';

/// The title a video site gets: the post's title, else its first line (at
/// most [max] characters).
String videoTitle(PostVariant v, {required int max}) {
  final t = (v.title ?? '').trim();
  final title = t.isNotEmpty ? t : v.text.trim().split('\n').first.trim();
  return title.length <= max ? title : '${title.substring(0, max - 1).trimRight()}…';
}

/// The description: the post's text (thread parts joined).
String videoDescription(PostVariant v) => (v.isThread ? v.threadParts.join('\n\n') : v.text).trim();

/// Hand-off to a video site's upload page: the description on the clipboard,
/// the title and tags to copy one by one, the video in the share sheet on
/// phones and in Downloads on a computer.
HandoffPlan videoSiteHandoff(
  PostVariant v, {
  required String platformId,
  required String name,
  required String uploadUrl,
  required int titleMax,
  int? maxTags,
  String? androidPackage,
  String extraStep = '',
}) {
  final title = videoTitle(v, max: titleMax);
  final description = videoDescription(v);
  final tags = maxTags == null ? v.tags : v.tags.take(maxTags).toList();
  final hasVideo = v.media.isNotEmpty;
  final steps = [
    "$name's upload page opens (sign in if asked).",
    hasVideo
        ? "Choose your video: click **Save media to Downloads** here, then pick it in $name's file picker (or drag it in)."
        : '$name needs a video: add one in NEFORUM first, or pick it on $name.',
    'Copy the **Title** into the title field and paste the description (it is on the clipboard).',
    if (tags.isNotEmpty) 'Copy the **Tags** into the tags field.',
    if (extraStep.isNotEmpty) extraStep,
    'Publish on $name.',
  ];
  return HandoffPlan(
    platformId: platformId,
    preferred: HandoffMethod.manual,
    clipboardText: description.isEmpty ? null : description,
    shareFiles: v.media,
    androidPackage: androidPackage,
    desktopUrl: uploadUrl,
    snippets: [
      if (title.isNotEmpty) HandoffSnippet('Title', title),
      if (tags.isNotEmpty) HandoffSnippet('Tags', tags.join(', ')),
    ],
    instructions: [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n'),
    mediaNote: '$name has no upload API that NEFORUM can use, so you upload the video on its website yourself; '
        'NEFORUM prepares the title, description and tags.',
  );
}
