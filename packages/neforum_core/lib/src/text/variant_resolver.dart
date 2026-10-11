import 'package:meta/meta.dart';

import '../model/account.dart';
import '../model/media.dart';
import '../model/platform_descriptor.dart';
import '../model/post.dart';
import '../model/post_variant.dart';
import '../model/validation.dart';
import 'text_counter.dart';
import 'text_splitter.dart';
import 'url_detector.dart';

/// How to handle text that is too long for a platform.
enum OverflowStrategy {
  /// Split into a thread when the platform supports it, else error.
  threadOrError,

  /// Split into a thread when the platform supports it, else truncate.
  threadOrTruncate,

  /// Always truncate with an ellipsis.
  truncate,

  /// Never change the text; report an error.
  error,
}

@immutable
class ResolverOptions {
  const ResolverOptions({
    this.overflow = OverflowStrategy.threadOrError,
    this.threadNumbering = true,
    this.appendHashtags = true,
    this.appendLink = true,
    this.dropUnsupportedMedia = true,
  });

  final OverflowStrategy overflow;
  final bool threadNumbering;

  /// Append `#tags` from [Post.tags] to the text when the platform has no
  /// separate tag field.
  final bool appendHashtags;

  /// Append [Post.link] to the text when the platform has no link field and
  /// the link is not already in the text.
  final bool appendLink;

  /// Silently drop media the platform cannot take (e.g. video on a
  /// text-only tier) instead of failing.
  final bool dropUnsupportedMedia;
}

/// Turns the master [Post] into the [PostVariant] for one target.
class VariantResolver {
  const VariantResolver([this.options = const ResolverOptions()]);

  final ResolverOptions options;

  /// With [delegateSchedule] the variant carries the post's schedule so the
  /// adapter hands it to the platform's own scheduler (only for platforms
  /// with `serverSideScheduling`).
  PostVariant resolve(Post post, PostTarget target, PlatformDescriptor d, {ConnectedAccount? account, bool delegateSchedule = false}) {
    final o = target.overrides;
    final issues = <ValidationIssue>[];
    final t = d.text;

    // ---- media ---------------------------------------------------------
    // Generated media (text cards) only goes where a target asks for it.
    var media = o.mediaIds == null
        ? post.media.where((m) => !m.generated).toList()
        : [for (final id in o.mediaIds!) ...post.media.where((m) => m.id == id)];
    media = _filterMedia(media, d, issues);

    // ---- text ----------------------------------------------------------
    var text = (o.text ?? post.text).trimRight();
    final link = o.link ?? post.link;
    final tags = post.tags.where((x) => x.trim().isNotEmpty).map(_cleanTag).toList();

    if (link != null && link.isNotEmpty && !d.supportsLinkField && options.appendLink && t.linkInText) {
      final already = UrlDetector.find(text).any((u) => u.normalized == Uri.tryParse(link)?.toString() || u.text == link);
      if (!already) text = text.isEmpty ? link : '$text\n\n$link';
    }
    if (tags.isNotEmpty && t.supportsHashtags && !t.hashtagsAsField && options.appendHashtags && o.text == null) {
      final missing = tags.where((x) => !RegExp('(?<!\\w)#${RegExp.escape(x)}(?!\\w)', caseSensitive: false).hasMatch(text)).toList();
      if (missing.isNotEmpty) {
        final line = missing.map((x) => '#$x').join(' ');
        text = text.isEmpty ? line : '$text\n\n$line';
      }
    }

    // ---- overflow ------------------------------------------------------
    var threadParts = const <String>[];
    if (t.maxLength != null && !TextCounter.fits(text, t)) {
      final n = TextCounter.count(text, t);
      final canThread = t.supportsThreads && (account == null || account.tier.isAutomatic);
      switch (options.overflow) {
        case OverflowStrategy.threadOrError:
        case OverflowStrategy.threadOrTruncate:
          if (canThread) {
            threadParts = TextSplitter.split(text, t, numbering: options.threadNumbering);
            text = threadParts.first;
            issues.add(ValidationIssue.info('text.threaded', 'Published as a ${threadParts.length}-part thread on ${d.name}', field: 'text'));
          } else if (options.overflow == OverflowStrategy.threadOrTruncate) {
            text = TextSplitter.truncate(text, t);
            issues.add(ValidationIssue.warning('text.truncated', 'Truncated from $n to ${t.maxLength} characters for ${d.name}', field: 'text'));
          } else {
            issues.add(ValidationIssue.error('text.too_long', 'Text is $n/${t.maxLength} characters for ${d.name}; shorten it or add a per-network version', field: 'text'));
          }
        case OverflowStrategy.truncate:
          text = TextSplitter.truncate(text, t);
          issues.add(ValidationIssue.warning('text.truncated', 'Truncated from $n to ${t.maxLength} characters for ${d.name}', field: 'text'));
        case OverflowStrategy.error:
          issues.add(ValidationIssue.error('text.too_long', 'Text is $n/${t.maxLength} characters for ${d.name}', field: 'text'));
      }
    }

    // ---- title ---------------------------------------------------------
    var title = o.title ?? post.title;
    if (t.titleSupported && (title == null || title.trim().isEmpty) && t.titleRequired) {
      // Derive a title from the first line so Reddit/Lemmy/blog posts work
      // without a separate field.
      final firstLine = (o.text ?? post.text).split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
      if (firstLine.isNotEmpty) {
        title = t.titleMax != null && firstLine.length > t.titleMax! ? '${firstLine.substring(0, t.titleMax! - 1)}…' : firstLine;
        issues.add(ValidationIssue.info('title.derived', 'Title taken from the first line for ${d.name}', field: 'title'));
      }
    }
    if (!t.titleSupported) title = null;

    // ---- extra ---------------------------------------------------------
    final extra = <String, dynamic>{
      if (account != null) ...(account.config['postDefaults'] as Map?)?.cast<String, dynamic>() ?? const {},
      ...o.extra,
    };

    return PostVariant(
      text: text,
      threadParts: threadParts,
      title: title,
      link: link,
      media: media,
      contentWarning: t.supportsContentWarning ? (o.contentWarning ?? post.contentWarning) : null,
      sensitive: o.sensitive ?? post.sensitive,
      visibility: o.visibility ?? post.visibility,
      language: post.language,
      tags: tags,
      extra: extra,
      // Only PublishService.delegateSchedules asks for this; a normal publish
      // must never queue the post on the platform again.
      scheduledAt: d.serverSideScheduling && delegateSchedule ? post.scheduledAt : null,
      issues: issues,
      sourcePostId: post.id,
    );
  }

  List<MediaAttachment> _filterMedia(List<MediaAttachment> media, PlatformDescriptor d, List<ValidationIssue> issues) {
    final m = d.media;
    if (media.isEmpty) return media;
    if (!m.supportsAnyMedia) {
      if (options.dropUnsupportedMedia) {
        issues.add(ValidationIssue.warning('media.dropped', '${d.name} takes no media; ${media.length} file(s) dropped', field: 'media'));
        return const [];
      }
      return media;
    }
    var out = <MediaAttachment>[];
    var images = 0, videos = 0, dropped = 0;
    for (final x in media) {
      final isVideo = x.isVideo;
      final typeOk = isVideo ? m.videoMimeTypes.contains(x.mimeType) : m.imageMimeTypes.contains(x.mimeType);
      final countOk = isVideo ? videos < m.maxVideos : images < m.maxImages;
      if (!typeOk || !countOk) {
        if (!options.dropUnsupportedMedia) {
          out.add(x);
          continue;
        }
        dropped++;
        continue;
      }
      if (isVideo) {
        videos++;
      } else {
        images++;
      }
      out.add(x);
    }
    if (!m.allowsMixedImageVideo && images > 0 && videos > 0 && options.dropUnsupportedMedia) {
      // Keep whichever came first.
      final firstIsVideo = out.first.isVideo;
      final kept = out.where((x) => x.isVideo == firstIsVideo).toList();
      dropped += out.length - kept.length;
      out = kept;
    }
    if (dropped > 0) {
      issues.add(ValidationIssue.warning('media.dropped', '$dropped file(s) dropped: ${d.name} allows ${m.maxImages} image(s)/${m.maxVideos} video(s)${m.allowsMixedImageVideo ? '' : ', not mixed'}', field: 'media'));
    }
    return out;
  }

  static String _cleanTag(String tag) => tag.trim().replaceFirst(RegExp(r'^#'), '').replaceAll(RegExp(r'\s+'), '');
}
