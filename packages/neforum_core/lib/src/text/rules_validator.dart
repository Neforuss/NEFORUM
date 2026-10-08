import '../model/platform_descriptor.dart';
import '../model/post_variant.dart';
import '../model/validation.dart';
import 'text_counter.dart';

/// Generic checks derived purely from a [PlatformDescriptor]. Adapters add
/// platform-specific ones on top.
class RulesValidator {
  RulesValidator._();

  static List<ValidationIssue> validate(PostVariant v, PlatformDescriptor d, {PlatformTier? tier}) {
    final issues = <ValidationIssue>[];
    final t = d.text;
    final m = d.media;

    // --- text -----------------------------------------------------------
    final parts = v.isThread ? v.threadParts : [v.text];
    if (t.maxLength != null) {
      for (var i = 0; i < parts.length; i++) {
        final n = TextCounter.count(parts[i], t);
        if (n > t.maxLength!) {
          issues.add(ValidationIssue.error(
            'text.too_long',
            '${parts.length > 1 ? 'Part ${i + 1} is' : 'Text is'} $n/${t.maxLength} characters for ${d.name}',
            field: 'text',
          ));
        }
      }
    }
    final textEmpty = v.text.trim().isEmpty;
    if (textEmpty && v.media.isEmpty && (v.title ?? '').trim().isEmpty && (v.link ?? '').trim().isEmpty) {
      issues.add(const ValidationIssue.error('post.empty', 'Nothing to post', field: 'text'));
    }

    // --- title ----------------------------------------------------------
    if (t.titleRequired && (v.title ?? '').trim().isEmpty) {
      issues.add(ValidationIssue.error('title.required', '${d.name} posts need a title', field: 'title'));
    }
    if (t.titleMax != null && v.title != null && v.title!.length > t.titleMax!) {
      issues.add(ValidationIssue.error('title.too_long', 'Title is ${v.title!.length}/${t.titleMax} characters', field: 'title'));
    }

    // --- hashtags -------------------------------------------------------
    if (t.maxHashtags != null) {
      final inText = RegExp(r'(?<!\w)#\w+').allMatches(v.text).length;
      final total = t.hashtagsAsField ? v.tags.length : inText;
      if (total > t.maxHashtags!) {
        issues.add(ValidationIssue.warning('hashtags.too_many', '$total hashtags; ${d.name} allows ${t.maxHashtags}', field: 'text'));
      }
    }

    // --- media ----------------------------------------------------------
    final images = v.media.where((x) => x.isImage).toList();
    final videos = v.media.where((x) => x.isVideo).toList();
    if (m.requiresMedia && v.media.isEmpty) {
      issues.add(ValidationIssue.error('media.required', '${d.name} posts need at least one image or video', field: 'media'));
    }
    if (!m.supportsAnyMedia && v.media.isNotEmpty) {
      issues.add(ValidationIssue.warning('media.unsupported', '${d.name} does not take media; it will be dropped', field: 'media'));
    } else {
      if (images.length > m.maxImages) {
        issues.add(ValidationIssue.error('media.too_many_images', '${images.length} images; ${d.name} allows ${m.maxImages}', field: 'media'));
      }
      if (videos.length > m.maxVideos) {
        issues.add(ValidationIssue.error('media.too_many_videos', '${videos.length} videos; ${d.name} allows ${m.maxVideos}', field: 'media'));
      }
      if (images.isNotEmpty && videos.isNotEmpty && !m.allowsMixedImageVideo) {
        issues.add(ValidationIssue.error('media.mixed', '${d.name} cannot mix images and video in one post', field: 'media'));
      }
      for (final x in images) {
        if (m.imageMaxBytes != null && x.sizeBytes > m.imageMaxBytes!) {
          issues.add(ValidationIssue.error('media.image_too_large', '${x.fileName ?? x.id} is ${_mb(x.sizeBytes)}; limit ${_mb(m.imageMaxBytes!)}', field: 'media'));
        }
        if (!m.imageMimeTypes.contains(x.mimeType)) {
          issues.add(ValidationIssue.error('media.image_type', '${x.mimeType} is not accepted by ${d.name}', field: 'media'));
        }
      }
      for (final x in videos) {
        if (m.videoMaxBytes != null && x.sizeBytes > m.videoMaxBytes!) {
          issues.add(ValidationIssue.error('media.video_too_large', '${x.fileName ?? x.id} is ${_mb(x.sizeBytes)}; limit ${_mb(m.videoMaxBytes!)}', field: 'media'));
        }
        if (m.videoMaxSeconds != null && x.durationMs != null && x.durationMs! > m.videoMaxSeconds! * 1000) {
          issues.add(ValidationIssue.error('media.video_too_long', 'Video is ${(x.durationMs! / 1000).round()}s; limit ${m.videoMaxSeconds}s', field: 'media'));
        }
        if (!m.videoMimeTypes.contains(x.mimeType)) {
          issues.add(ValidationIssue.error('media.video_type', '${x.mimeType} is not accepted by ${d.name}', field: 'media'));
        }
      }
    }
    if (m.supportsAltText && v.media.any((x) => (x.altText ?? '').isEmpty)) {
      issues.add(const ValidationIssue.info('media.no_alt', 'Add alt text for accessibility', field: 'media'));
    }

    // --- tier-specific ---------------------------------------------------
    if (tier == PlatformTier.handoff && v.isThread) {
      issues.add(const ValidationIssue.warning('thread.handoff', 'Threads cannot be handed off; only the first part will be prefilled', field: 'text'));
    }
    return issues;
  }

  static String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
