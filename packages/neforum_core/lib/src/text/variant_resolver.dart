import 'package:meta/meta.dart';

import '../audio/audio_publishing.dart';
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

/// [PostOverrides.extra] key: `true` when a target whose only media are
/// NEFORUM text cards ([MediaAttachment.isTextCard]) gets the card without the
/// post's text (the card carries the words, and its alt text has them). With
/// any other media the key has no effect.
const String kTextCardOnlyKey = 'textCardOnly';

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
    // Sound files (and the copies made from them) carry the tags they go out
    // with: the file's own under the user's edits.
    final chosen = post.withEffectiveAudioTags(o.mediaIds == null
        ? post.media.where((m) => !m.generated).toList()
        : [for (final id in o.mediaIds!) ...post.media.where((m) => m.id == id)]);
    // The story's own copies (Post + Story), checked by the adapter.
    final storyIds = o.storyMediaIds;
    final storyMedia = storyIds == null ? const <MediaAttachment>[] : [for (final id in storyIds) ...post.media.where((m) => m.id == id)];
    // The text card alone: no text, so no thread and no length to check.
    final cardOnly = o.extra[kTextCardOnlyKey] == true && chosen.isNotEmpty && chosen.every((m) => m.isTextCard);

    // ---- text ----------------------------------------------------------
    // The parts the user wrote ([Post.parts]). A per-network version is one
    // text and replaces all of them. writtenIndex maps each part of the post
    // to the written part that takes its media: an empty part's media goes
    // with the part before it (or the first one).
    final written = <String>[];
    final writtenIndex = <int>[];
    if (o.text == null) {
      for (final p in post.parts) {
        if (p.trim().isNotEmpty) written.add(p.trimRight());
        writtenIndex.add(written.isEmpty ? 0 : written.length - 1);
      }
    }
    final canThread = t.supportsThreads && (account == null || account.tier.isAutomatic);
    var text = (o.text ?? written.join('\n\n')).trimRight();
    final link = o.link ?? post.link;
    final tags = post.tags.where((x) => x.trim().isNotEmpty).map(_cleanTag).toList();

    // The link and hashtags go at the end: of the text, or of the last part
    // of a thread.
    final additions = <String>[];
    var probe = text;
    if (link != null && link.isNotEmpty && !d.supportsLinkField && options.appendLink && t.linkInText) {
      final already = UrlDetector.find(probe).any((u) => u.normalized == Uri.tryParse(link)?.toString() || u.text == link);
      if (!already) {
        additions.add(link);
        probe = '$probe\n\n$link';
      }
    }
    if (tags.isNotEmpty && t.supportsHashtags && !t.hashtagsAsField && options.appendHashtags && o.text == null) {
      final missing = tags.where((x) => !RegExp('(?<!\\w)#${RegExp.escape(x)}(?!\\w)', caseSensitive: false).hasMatch(probe)).toList();
      if (missing.isNotEmpty) additions.add(missing.map((x) => '#$x').join(' '));
    }
    String withAdditions(String s) => [if (s.isNotEmpty) s, ...additions].join('\n\n');

    // ---- overflow ------------------------------------------------------
    var threadParts = const <String>[];
    // Where each written part begins in threadParts (media placement).
    var starts = const <int>[0];
    if (cardOnly) {
      text = '';
      issues.add(ValidationIssue.info('text.card_only', '${d.name} gets only the text card; your words are in the picture and its description', field: 'text'));
    } else if (written.length > 1 && canThread) {
      // A thread the user wrote: one post per part.
      final thread = _writtenThread([...written.take(written.length - 1), withAdditions(written.last)], d, issues);
      threadParts = thread.parts;
      starts = thread.starts;
      text = threadParts.first;
    } else {
      // Networks without threads (and hand-offs) get every part in one post.
      text = withAdditions(text);
      if (written.length > 1) {
        issues.add(ValidationIssue.info('text.parts_joined', '${d.name} gets the ${written.length} parts as one post', field: 'text'));
      }
    }
    if (!cardOnly && threadParts.isEmpty && t.maxLength != null && !TextCounter.fits(text, t)) {
      final n = TextCounter.count(text, t);
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

    // ---- media placement -----------------------------------------------
    // A written thread on a network that takes media in every post: each
    // item goes with the first post made from its part, and the limits apply
    // per post. Anywhere else all media goes with the one (or first) post.
    var media = const <MediaAttachment>[];
    var mediaPartIndexes = const <int>[];
    if (threadParts.length > 1 && written.length > 1 && d.media.mediaPerThreadPart && post.mediaParts.isNotEmpty && chosen.isNotEmpty) {
      final groups = [for (var i = 0; i < threadParts.length; i++) <MediaAttachment>[]];
      for (final m in chosen) {
        final part = post.partOf(m);
        final w = part >= 0 && part < writtenIndex.length ? writtenIndex[part] : written.length - 1;
        groups[starts[w.clamp(0, starts.length - 1)].clamp(0, groups.length - 1)].add(m);
      }
      if (groups.skip(1).any((g) => g.isNotEmpty)) {
        final placed = <MediaAttachment>[];
        final indexes = <int>[];
        for (var i = 0; i < groups.length; i++) {
          if (groups[i].isEmpty) continue;
          final kept = _filterMedia(groups[i], d, issues, part: groups.length > 1 ? i + 1 : null);
          placed.addAll(kept);
          indexes.addAll([for (final _ in kept) i]);
        }
        media = placed;
        mediaPartIndexes = indexes;
      } else {
        media = _filterMedia(chosen, d, issues);
      }
    } else {
      media = _filterMedia(chosen, d, issues);
    }

    // ---- title ---------------------------------------------------------
    var title = o.title ?? post.title;
    if (t.titleSupported && (title == null || title.trim().isEmpty) && t.titleRequired) {
      // Derive a title from the first line so Reddit/Lemmy/blog posts work
      // without a separate field.
      final firstLine = (o.text ?? written.firstOrNull ?? '').split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
      if (firstLine.isNotEmpty) {
        title = t.titleMax != null && firstLine.length > t.titleMax! ? '${firstLine.substring(0, t.titleMax! - 1)}…' : firstLine;
        issues.add(ValidationIssue.info('title.derived', 'Title taken from the first line for ${d.name}', field: 'title'));
      }
    }
    if (!t.titleSupported) title = null;

    // ---- poll ----------------------------------------------------------
    final poll = post.poll;
    if (poll != null && d.polls == null) {
      issues.add(ValidationIssue.info('poll.unsupported', '${d.name} has no polls; it gets the post without the poll', field: 'poll'));
    }

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
      // must never queue the post on the platform again. Each target gets its
      // own time when the post has a different time per network.
      scheduledAt: d.serverSideScheduling && delegateSchedule ? post.dueAtFor(target) : null,
      issues: issues,
      sourcePostId: post.id,
      poll: d.polls == null ? null : poll,
      artwork: post.artwork,
      storyMedia: storyMedia,
      mediaPartIndexes: mediaPartIndexes,
    );
  }

  /// The thread for [parts] the user wrote. A part longer than the limit is
  /// split further, truncated or reported, as [ResolverOptions.overflow]
  /// says for long text; numbering counts every final part.
  ///
  /// `starts[i]` is the index of the first post made from `parts[i]`.
  ({List<String> parts, List<int> starts}) _writtenThread(List<String> parts, PlatformDescriptor d, List<ValidationIssue> issues) {
    final t = d.text;
    final numbering = options.threadNumbering;
    List<String> thread;
    var starts = [for (var i = 0; i < parts.length; i++) i];
    switch (options.overflow) {
      case OverflowStrategy.threadOrError:
      case OverflowStrategy.threadOrTruncate:
        final split = TextSplitter.splitPartsWithStarts(parts, t, numbering: numbering);
        thread = split.parts;
        starts = split.starts;
      case OverflowStrategy.truncate:
        final reserve = numbering ? TextSplitter.suffixLength(parts.length) : 0;
        final shortened = [for (final p in parts) TextSplitter.truncate(p, t, reserve: reserve)];
        for (var i = 0; i < parts.length; i++) {
          if (shortened[i] != parts[i]) {
            issues.add(ValidationIssue.warning('text.truncated',
                'Part ${i + 1} truncated from ${TextCounter.count(parts[i], t)} to ${t.maxLength! - reserve} characters for ${d.name}',
                field: 'text'));
          }
        }
        thread = numbering ? TextSplitter.number(shortened) : shortened;
      case OverflowStrategy.error:
        thread = numbering ? TextSplitter.number(parts) : parts;
        // Same words as RulesValidator, so the two reports read as one.
        for (var i = 0; i < thread.length; i++) {
          final n = TextCounter.count(thread[i], t);
          if (t.maxLength != null && n > t.maxLength!) {
            issues.add(ValidationIssue.error('text.too_long', 'Part ${i + 1} is $n/${t.maxLength} characters for ${d.name}', field: 'text'));
          }
        }
    }
    issues.add(ValidationIssue.info('text.threaded', 'Published as a ${thread.length}-part thread on ${d.name}', field: 'text'));
    return (parts: thread, starts: starts);
  }

  /// [part] (from 1) names the thread post the media belongs to in the
  /// warning, when the limits apply per post.
  List<MediaAttachment> _filterMedia(List<MediaAttachment> media, PlatformDescriptor d, List<ValidationIssue> issues, {int? part}) {
    if (media.isEmpty) return media;
    if (!media.any((x) => x.isAudio)) return _filterVisualMedia(media, d, issues, part: part);
    final m = d.media;
    final sound = <MediaAttachment>[];
    var droppedSound = 0;
    for (final x in media.where((x) => x.isAudio)) {
      // A type the network refuses stays, like a photo: the app sends its
      // Standard copy where it can, and otherwise the check says why.
      // Dropping it would post without the track the user picked.
      final keep = m.supportsAudio ? sound.length < m.maxAudios : (m.audioAsVideo || m.audioAsLink);
      if (keep || !options.dropUnsupportedMedia) {
        sound.add(x);
      } else {
        droppedSound++;
      }
    }
    if (droppedSound > 0) {
      issues.add(ValidationIssue.warning(
          'media.audio_dropped',
          m.supportsAudio
              ? '$droppedSound sound file(s) left out: ${d.name} takes ${m.maxAudios} per post'
              : '${d.name} takes no sound files; $droppedSound left out',
          field: 'media'));
    }
    var visual = media.where((x) => !x.isAudio).toList();
    if (sound.isNotEmpty && !m.supportsAudio && m.audioAsVideo) {
      // The app turns each sound file into a video whose picture is the
      // first photo: the sound counts as a video at its place, as that video
      // will when it is published, and the photo as part of it.
      final picture = visual.where((x) => x.kind == MediaKind.image && !x.isTextCard).firstOrNull;
      final counted = [
        for (final x in media)
          if (sound.contains(x) || (!x.isAudio && !identical(x, picture))) x,
      ];
      final kept = _filterVisualMedia(counted, d, issues, part: part, asVideo: sound.toSet()).toSet();
      return [for (final x in media) if (kept.contains(x) || identical(x, picture)) x];
    }
    if (sound.isNotEmpty && m.supportsAudio && !m.audioWithOtherMedia && visual.isNotEmpty && options.dropUnsupportedMedia) {
      issues.add(ValidationIssue.warning('media.audio_alone',
          '${d.name} takes a sound file on its own; ${visual.length} photo(s)/video(s) left out', field: 'media'));
      visual = const [];
    }
    final kept = {...sound, ..._filterVisualMedia(visual, d, issues, part: part)};
    return [for (final x in media) if (kept.contains(x)) x];
  }

  /// [asVideo]: sound files counted as the videos they become.
  List<MediaAttachment> _filterVisualMedia(List<MediaAttachment> media, PlatformDescriptor d, List<ValidationIssue> issues,
      {int? part, Set<MediaAttachment> asVideo = const {}}) {
    final m = d.media;
    if (media.isEmpty) return media;
    bool video(MediaAttachment x) => x.isVideo || asVideo.contains(x);
    if (m.maxImages == 0 && m.maxVideos == 0) {
      if (options.dropUnsupportedMedia) {
        issues.add(ValidationIssue.warning('media.dropped', '${d.name} takes no media; ${media.length} file(s) dropped', field: 'media'));
        return const [];
      }
      return media;
    }
    var out = <MediaAttachment>[];
    var images = 0, videos = 0, dropped = 0;
    for (final x in media) {
      final isVideo = video(x);
      // A still photo of a type the platform refuses (a PNG for Instagram's
      // API) stays: the app turns it into one it takes (PhotoFit), and
      // otherwise the check says why. Dropping it would leave the target
      // without the photo the user picked for it.
      final typeOk = asVideo.contains(x) ||
          (isVideo ? m.videoMimeTypes.contains(x.mimeType) : m.imageMimeTypes.contains(x.mimeType) || x.kind == MediaKind.image);
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
      final firstIsVideo = video(out.first);
      final kept = out.where((x) => video(x) == firstIsVideo).toList();
      dropped += out.length - kept.length;
      out = kept;
    }
    if (dropped > 0) {
      issues.add(ValidationIssue.warning('media.dropped', '$dropped file(s) dropped${part == null ? '' : ' from part $part'}: ${d.name} allows ${m.maxImages} image(s)/${m.maxVideos} video(s)${m.allowsMixedImageVideo ? '' : ', not mixed'}', field: 'media'));
    }
    return out;
  }

  static String _cleanTag(String tag) => tag.trim().replaceFirst(RegExp(r'^#'), '').replaceAll(RegExp(r'\s+'), '');
}
