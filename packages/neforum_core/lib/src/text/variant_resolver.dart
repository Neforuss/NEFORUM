import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../audio/audio_publishing.dart';
import '../model/account.dart';
import '../model/media.dart';
import '../model/platform_descriptor.dart';
import '../model/post.dart';
import '../model/post_placement.dart';
import '../model/post_variant.dart';
import '../model/validation.dart';
import 'media_packer.dart';
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
    // The text the posts are made from, part by part, for a thread that has
    // to be split again when posts of media only join it.
    List<String>? textSource;
    if (cardOnly) {
      text = '';
      issues.add(ValidationIssue.info('text.card_only', '${d.name} gets only the text card; your words are in the picture and its description', field: 'text'));
    } else if (written.length > 1 && canThread) {
      // A thread the user wrote: one post per part.
      textSource = [...written.take(written.length - 1), withAdditions(written.last)];
      final thread = _writtenThread(textSource, d, issues);
      threadParts = thread.parts;
      starts = thread.starts;
      text = threadParts.first;
    } else {
      // Networks without threads (and hand-offs) get every part in one post.
      text = withAdditions(text);
      textSource = [text];
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
    // Photos and videos that do not fit in one post go on in further posts,
    // never dropped: the posts of the thread on a network whose every post
    // carries its own media, else a series of separate posts after this one.
    // A hand-off carries one post.
    final threaded = canThread && d.media.mediaPerThreadPart && !cardOnly;
    // A written thread there: each item goes with the first post made from
    // its part. Anywhere else all media starts with the one (or first) post.
    final byPart = threaded && threadParts.length > 1 && written.length > 1 && post.mediaParts.isNotEmpty;
    final buckets = <int, List<MediaAttachment>>{};
    for (final m in chosen) {
      var w = 0;
      if (byPart) {
        final part = post.partOf(m);
        w = (part >= 0 && part < writtenIndex.length ? writtenIndex[part] : written.length - 1).clamp(0, starts.length - 1);
      }
      (buckets[w] ??= []).add(m);
    }
    final inLaterParts = buckets.keys.any((w) => w > 0);
    final groupsByPart = {
      for (final w in buckets.keys.toList()..sort()) w: _mediaGroups(buckets[w]!, d, issues, part: inLaterParts ? starts[w] + 1 : null),
    };
    var media = const <MediaAttachment>[];
    var mediaPartIndexes = const <int>[];
    var seriesGroups = const <List<MediaAttachment>>[];
    if (threaded) {
      final placed = _placeInThread(
        threadParts.isEmpty ? [text] : threadParts,
        threadParts.isEmpty ? const [0] : starts,
        groupsByPart,
        source: textSource,
        d: d,
        issues: issues,
      );
      if (placed.posts.length > 1) {
        threadParts = placed.posts;
        text = threadParts.first;
      }
      media = placed.media;
      mediaPartIndexes = placed.media.length == placed.parts.length && placed.parts.any((i) => i > 0) ? placed.parts : const [];
    } else {
      final groups = groupsByPart[0] ?? const <List<MediaAttachment>>[];
      media = groups.firstOrNull ?? const [];
      if (groups.length > 1) {
        final rest = groups.skip(1).toList();
        if (account?.tier == PlatformTier.handoff) {
          final left = rest.fold(0, (n, g) => n + g.length);
          issues.add(ValidationIssue.warning(
              'media.left_out', 'A hand-off to ${d.name} is one post (${_perPost(d.media)}): $left more file(s) left out', field: 'media'));
        } else {
          seriesGroups = rest;
          issues.add(ValidationIssue.info(
              'media.series',
              '${d.name} takes ${_perPost(d.media)} per post${t.supportsThreads ? ', and media only on the first post of a thread' : ''}: '
                  'it gets ${groups.length} posts, one after the other',
              field: 'media'));
        }
      }
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

    // ---- series --------------------------------------------------------
    // The further posts: their media, numbered when threads are, and in the
    // feed only (a story goes with the first post).
    final contentWarning = t.supportsContentWarning ? (o.contentWarning ?? post.contentWarning) : null;
    final count = 1 + seriesGroups.length;
    final series = [
      for (var i = 0; i < seriesGroups.length; i++)
        PostVariant(
          text: options.threadNumbering ? '(${i + 2}/$count)' : '',
          title: title == null || !options.threadNumbering ? title : _numberedTitle(title, i + 1, count, t),
          media: seriesGroups[i],
          contentWarning: contentWarning,
          sensitive: o.sensitive ?? post.sensitive,
          visibility: o.visibility ?? post.visibility,
          language: post.language,
          tags: tags,
          extra: {...extra}
            ..remove(kPlacementKey)
            ..remove(kStoryModeKey),
          sourcePostId: post.id,
          artwork: post.artwork,
        ),
    ];
    if (series.isNotEmpty && options.threadNumbering) {
      // The first post's number, where it still fits.
      if (threadParts.isEmpty) {
        final numbered = '$text (1/$count)'.trim();
        if (TextCounter.fits(numbered, t)) text = numbered;
      }
      if (title != null) title = _numberedTitle(title, 0, count, t);
    }
    // A thread or series longer than the network lets an account post in a
    // while (Lemmy: 6 posts per 10 minutes) is refused before anything goes
    // out: say so here, where it can still be changed.
    final posts = math.max(1, threadParts.length) + series.length;
    if (posts > 1) {
      for (final rule in d.defaultQuotas) {
        if (rule.appliesToTier != null && account != null && rule.appliesToTier != account.tier) continue;
        if (posts > rule.limit) {
          issues.add(ValidationIssue.warning('quota.too_many_posts',
              '${d.name} takes ${rule.limit} ${rule.note}: these $posts posts are more than that', field: 'media'));
          break;
        }
      }
    }

    return PostVariant(
      text: text,
      threadParts: threadParts,
      title: title,
      link: link,
      media: media,
      contentWarning: contentWarning,
      sensitive: o.sensitive ?? post.sensitive,
      visibility: o.visibility ?? post.visibility,
      language: post.language,
      tags: tags,
      extra: extra,
      // Only PublishService.delegateSchedules asks for this; a normal publish
      // must never queue the post on the platform again. Each target gets its
      // own time when the post has a different time per network. A series is
      // published by the app itself, post after post, when it is due.
      scheduledAt: d.serverSideScheduling && delegateSchedule && series.isEmpty ? post.dueAtFor(target) : null,
      issues: issues,
      sourcePostId: post.id,
      poll: d.polls == null ? null : poll,
      artwork: post.artwork,
      storyMedia: storyMedia,
      mediaPartIndexes: mediaPartIndexes,
      seriesPosts: series,
    );
  }

  /// "4 photos or 1 video", "10 photos and videos": what one post holds.
  static String _perPost(MediaRules m) {
    String n(int count, String one, String many) => '$count ${count == 1 ? one : many}';
    if (m.maxVideos == 0) return n(m.maxImages, 'photo', 'photos');
    if (m.maxImages == 0) return n(m.maxVideos, 'video', 'videos');
    if (m.allowsMixedImageVideo && m.maxImages == m.maxVideos) return '${m.maxImages} photos and videos';
    return '${n(m.maxImages, 'photo', 'photos')} ${m.allowsMixedImageVideo ? 'and' : 'or'} ${n(m.maxVideos, 'video', 'videos')}';
  }

  /// [title] with the number of post [index] (from 0) of a series of
  /// [count], shortened to keep within the title limit.
  static String _numberedTitle(String title, int index, int count, TextRules t) {
    final label = ' (${index + 1}/$count)';
    final max = t.titleMax;
    if (max == null || title.length + label.length <= max) return '$title$label';
    return '${title.substring(0, math.max(0, max - label.length - 1)).trimRight()}…$label';
  }

  /// The posts of a thread on a network whose every post carries its own
  /// media: [textPosts] (`starts[w]` is the first post made from written
  /// part w), with the media groups of part w ([groups]) on that part's
  /// posts one by one and, when it has more groups than posts, posts of media
  /// only right after them. With thread numbering those posts count too; a
  /// thread whose longer numbers no longer fit is split again from [source].
  ///
  /// Returns the posts, the media in order and, for each item, the post that
  /// carries it.
  ({List<String> posts, List<MediaAttachment> media, List<int> parts}) _placeInThread(
      List<String> textPosts, List<int> starts, Map<int, List<List<MediaAttachment>>> groups,
      {required List<String>? source, required PlatformDescriptor d, required List<ValidationIssue> issues}) {
    ({List<String> posts, List<bool> textual, List<MediaAttachment> media, List<int> parts}) lay(List<String> posts, List<int> starts) {
      final out = <String>[];
      final textual = <bool>[];
      final media = <MediaAttachment>[];
      final parts = <int>[];
      for (var w = 0; w < starts.length; w++) {
        final end = w + 1 < starts.length ? starts[w + 1] : posts.length;
        final own = groups[w] ?? const <List<MediaAttachment>>[];
        final count = end - starts[w];
        for (var j = 0; j < math.max(count, own.length); j++) {
          out.add(j < count ? posts[starts[w] + j] : '');
          textual.add(j < count);
          if (j < own.length) {
            media.addAll(own[j]);
            parts.addAll([for (final _ in own[j]) out.length - 1]);
          }
        }
      }
      return (posts: out, textual: textual, media: media, parts: parts);
    }

    final laid = lay(textPosts, starts);
    final added = laid.posts.length - textPosts.length;
    if (added == 0) return (posts: laid.posts, media: laid.media, parts: laid.parts);
    final t = d.text;
    var result = laid;
    if (options.threadNumbering) {
      // The posts of media only count in the numbering: the text's own
      // numbers go, and every post gets its number of the whole thread.
      final plain = textPosts.length > 1
          ? [for (var i = 0; i < textPosts.length; i++) TextSplitter.withoutNumber(textPosts[i], i, textPosts.length)]
          : textPosts;
      result = lay(plain, starts);
      bool fits(List<String> posts, List<bool> textual) {
        final numbered = TextSplitter.number(posts);
        for (var i = 0; i < posts.length; i++) {
          if (textual[i] && !TextCounter.fits(numbered[i], t)) return false;
        }
        return true;
      }

      final splitsAgain = options.overflow == OverflowStrategy.threadOrError || options.overflow == OverflowStrategy.threadOrTruncate;
      if (source != null && splitsAgain && !fits(result.posts, result.textual)) {
        var reserve = TextSplitter.suffixLength(result.posts.length);
        for (var round = 0; round < 4; round++) {
          final again = TextSplitter.splitPartsWithStarts(source, t, numbering: false, room: reserve);
          result = lay(again.parts, again.starts);
          final need = TextSplitter.suffixLength(result.posts.length);
          if (need <= reserve) break;
          reserve = need;
        }
      }
      result = (
        posts: [for (final p in TextSplitter.number(result.posts)) p.trim()],
        textual: result.textual,
        media: result.media,
        parts: result.parts,
      );
    }
    issues
      ..removeWhere((i) => i.code == 'text.threaded')
      ..add(ValidationIssue.info('text.threaded', 'Published as a ${result.posts.length}-part thread on ${d.name}', field: 'text'))
      ..add(ValidationIssue.info('media.threaded',
          '${d.name} takes ${_perPost(d.media)} per post: the rest go in ${result.textual.where((x) => !x).length} more post(s) of the thread',
          field: 'media'));
    return (posts: result.posts, media: result.media, parts: result.parts);
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

  /// [media] as the posts that carry it on [d]: one group per post, in order
  /// ([packMediaIntoPosts]), without the files [d] cannot take at all. [part]
  /// (from 1) names the thread post the media belongs to in a warning, when
  /// the media goes with later parts.
  List<List<MediaAttachment>> _mediaGroups(List<MediaAttachment> media, PlatformDescriptor d, List<ValidationIssue> issues, {int? part}) {
    if (media.isEmpty) return const [];
    if (!media.any((x) => x.isAudio)) return _visualGroups(media, d, issues, part: part);
    final order = {for (var i = 0; i < media.length; i++) media[i]: i};
    List<MediaAttachment> inOrder(Iterable<MediaAttachment> items) => items.toList()..sort((a, b) => order[a]!.compareTo(order[b]!));
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
      // will when it is published, and the photo goes in the same post.
      final picture = visual.where((x) => x.kind == MediaKind.image && !x.isTextCard).firstOrNull;
      final counted = [
        for (final x in media)
          if (sound.contains(x) || (!x.isAudio && !identical(x, picture))) x,
      ];
      final groups = _visualGroups(counted, d, issues, part: part, asVideo: sound.toSet());
      if (picture == null) return groups;
      final withSound = groups.indexWhere((g) => g.any(sound.contains));
      if (withSound < 0) return groups;
      return [
        for (var i = 0; i < groups.length; i++) i == withSound ? inOrder([...groups[i], picture]) : groups[i],
      ];
    }
    if (sound.isNotEmpty && m.supportsAudio && !m.audioWithOtherMedia && visual.isNotEmpty && options.dropUnsupportedMedia) {
      issues.add(ValidationIssue.warning('media.audio_alone',
          '${d.name} takes a sound file on its own; ${visual.length} photo(s)/video(s) left out', field: 'media'));
      visual = const [];
    }
    final groups = _visualGroups(visual, d, issues, part: part);
    if (sound.isEmpty) return groups;
    // The sound goes with the first post.
    return [inOrder([...sound, ...?groups.firstOrNull]), ...groups.skip(1)];
  }

  /// The photos and videos of [media] as the posts that carry them on [d]
  /// ([packMediaIntoPosts]). A file [d] cannot take at all (a video where it
  /// takes none, a video type it refuses) is left out, with a warning.
  /// [asVideo]: sound files counted as the videos they become.
  List<List<MediaAttachment>> _visualGroups(List<MediaAttachment> media, PlatformDescriptor d, List<ValidationIssue> issues,
      {int? part, Set<MediaAttachment> asVideo = const {}}) {
    final m = d.media;
    if (media.isEmpty) return const [];
    bool video(MediaAttachment x) => x.isVideo || asVideo.contains(x);
    if (m.maxImages == 0 && m.maxVideos == 0) {
      if (options.dropUnsupportedMedia) {
        issues.add(ValidationIssue.warning('media.dropped', '${d.name} takes no media; ${media.length} file(s) dropped', field: 'media'));
        return const [];
      }
      return [media];
    }
    if (!options.dropUnsupportedMedia) return [media];
    final taken = <MediaAttachment>[];
    var noKind = 0, noType = 0;
    for (final x in media) {
      final isVideo = video(x);
      // A still photo of a type the platform refuses (a PNG for Instagram's
      // API) stays: the app turns it into one it takes (PhotoFit), and
      // otherwise the check says why. Dropping it would leave the target
      // without the photo the user picked for it.
      final typeOk = asVideo.contains(x) ||
          (isVideo ? m.videoMimeTypes.contains(x.mimeType) : m.imageMimeTypes.contains(x.mimeType) || x.kind == MediaKind.image);
      final kindOk = isVideo ? m.maxVideos > 0 : m.maxImages > 0;
      if (!kindOk) {
        noKind++;
      } else if (!typeOk) {
        noType++;
      } else {
        taken.add(x);
      }
    }
    final dropped = noKind + noType;
    if (dropped > 0) {
      final why = [
        if (noKind > 0) m.maxVideos == 0 ? '${d.name} takes no videos' : '${d.name} takes no photos',
        if (noType > 0) '${d.name} does not take that type of video',
      ].join('; ');
      issues.add(ValidationIssue.warning('media.dropped', '$dropped file(s) dropped${part == null ? '' : ' from part $part'}: $why', field: 'media'));
    }
    return packMediaIntoPosts(taken, m, isVideo: video);
  }

  static String _cleanTag(String tag) => tag.trim().replaceFirst(RegExp(r'^#'), '').replaceAll(RegExp(r'\s+'), '');
}
