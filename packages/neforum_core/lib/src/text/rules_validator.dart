import 'package:characters/characters.dart';

import '../model/platform_descriptor.dart';
import '../model/poll.dart';
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

    // --- poll / quiz -----------------------------------------------------
    final poll = v.poll;
    final pr = d.polls;
    if (poll != null && pr != null) issues.addAll(_validatePoll(poll, pr, v, d.name));

    // --- tier-specific ---------------------------------------------------
    if (tier == PlatformTier.handoff && v.isThread) {
      issues.add(const ValidationIssue.warning('thread.handoff', 'Threads cannot be handed off; only the first part will be prefilled', field: 'text'));
    }
    return issues;
  }

  static List<ValidationIssue> _validatePoll(PostPoll poll, PollRules r, PostVariant v, String name) {
    final issues = <ValidationIssue>[];
    final options = poll.cleanOptions;
    final what = poll.isQuiz ? 'quiz' : 'poll';
    if (v.text.trim().isEmpty) {
      issues.add(ValidationIssue.error('poll.no_question', 'Write the $what question as the post text', field: 'text'));
    }
    if (poll.isQuiz && !r.quizzes) {
      issues.add(ValidationIssue.error('poll.no_quizzes', '$name has polls but no quizzes', field: 'poll'));
    }
    if (poll.imageOptions && !r.imagePolls) {
      issues.add(ValidationIssue.error('poll.no_image_polls', '$name has no image polls', field: 'poll'));
    }
    if (options.length < r.minOptions || options.length > r.maxOptions) {
      issues.add(ValidationIssue.error(
        'poll.option_count',
        'A $name $what needs ${r.minOptions} to ${r.maxOptions} answers (${options.length} given)',
        field: 'poll',
      ));
    }
    if (options.length != poll.options.length) {
      issues.add(const ValidationIssue.warning('poll.empty_option', 'Empty answers are left out', field: 'poll'));
    }
    final max = poll.imageOptions ? r.imageOptionMaxLength : (poll.isQuiz ? r.quizOptionMaxLength : r.optionMaxLength);
    if (max != null) {
      for (var i = 0; i < options.length; i++) {
        final n = options[i].characters.length;
        if (n > max) {
          issues.add(ValidationIssue.error('poll.option_too_long', 'Answer ${i + 1} is $n/$max characters for $name', field: 'poll'));
        }
      }
    }
    if (poll.isQuiz) {
      final c = poll.correctIndex;
      if (c == null || c < 0 || c >= poll.options.length || poll.options[c].trim().isEmpty) {
        issues.add(const ValidationIssue.error('poll.no_correct', 'Mark the correct answer of the quiz', field: 'poll'));
      }
      final e = poll.explanation?.trim() ?? '';
      if (r.quizExplanationMaxLength != null && e.characters.length > r.quizExplanationMaxLength!) {
        issues.add(ValidationIssue.error(
          'poll.explanation_too_long',
          'The explanation is ${e.characters.length}/${r.quizExplanationMaxLength} characters for $name',
          field: 'poll',
        ));
      }
    }
    if (poll.imageOptions) {
      final images = v.media.where((m) => m.isImage).length;
      if (images != options.length) {
        issues.add(ValidationIssue.error(
          'poll.image_count',
          'An image poll needs one image per answer ($images image${images == 1 ? '' : 's'}, ${options.length} answers)',
          field: 'poll',
        ));
      }
    }
    return issues;
  }

  static String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
