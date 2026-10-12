import 'package:neforum_core/neforum_core.dart' hide Visibility;

/// DIFFERENTIATION: one post, a version tuned for each network.
///
/// What works on X rarely works on LinkedIn or Instagram. These are the
/// one-tap changes the composer offers per version and each network's
/// conventions.
/// Everything here is plain text work on the user's own words: nothing is
/// generated or sent anywhere.
enum VersionTransform {
  fit('Fit to the limit'),
  hashtagsToEnd('Hashtags to the end'),
  fewerHashtags('Fewer hashtags'),
  noHashtags('No hashtags'),
  linkInBio('"Link in bio"'),
  noLink('Remove link'),
  airy('Airy paragraphs');

  const VersionTransform(this.label);
  final String label;
}

/// How posts usually look on one network.
class NetworkStyle {
  const NetworkStyle(this.tip, {this.maxHashtags = 3});

  /// One line of guidance shown above the version.
  final String tip;

  /// What "Fewer hashtags" keeps.
  final int maxHashtags;
}

const _chat = NetworkStyle('A message to people who joined your channel: conversational, no hashtags needed.');
const _blog = NetworkStyle(
  'Long form: a clear title, a strong first paragraph. Tags go in the tags field, not the text.',
);

/// Network conventions (platform id).
NetworkStyle styleFor(String platformId) => switch (platformId) {
      'x' => const NetworkStyle('Short and punchy; lead with the hook. One or two hashtags at most.', maxHashtags: 2),
      'linkedin' => const NetworkStyle(
          'Professional and personal: hook in the first two lines (the rest hides behind "…see more"), short paragraphs, up to 3 hashtags at the end.'),
      'instagram' => const NetworkStyle(
          'The caption supports the picture: front-load the first line, hashtags at the end. Links in captions are not clickable, so say "link in bio".', maxHashtags: 5),
      'tiktok' => const NetworkStyle('Short caption, a few relevant hashtags; links are not clickable, so point to your bio.', maxHashtags: 5),
      'threads' => const NetworkStyle('Conversational, like talking to friends. Threads shows one topic tag per post.', maxHashtags: 1),
      'facebook' => const NetworkStyle('Friendly and conversational; a question invites comments. Hashtags matter little here.', maxHashtags: 2),
      'bluesky' => const NetworkStyle('Casual and direct, 300 characters. A hashtag or two at most.', maxHashtags: 2),
      'mastodon' || 'misskey' => const NetworkStyle(
          'Hashtags are how people find posts here (there is no algorithm), so keep a few at the end; write them in CamelCase for screen readers.', maxHashtags: 5),
      'nostr' => const NetworkStyle('Plain notes; hashtags at the end help relays index them.'),
      'reddit' || 'lemmy' => const NetworkStyle(
          'The title carries the post; write for that community, no hashtags, no marketing tone.'),
      'youtube_posts' => const NetworkStyle(
          'Talk to your subscribers: a question or a poll works well. About 280 characters show before "Read more".'),
      'youtube' => const NetworkStyle('The description: first two lines matter most; hashtags at the end.'),
      'pinterest' => const NetworkStyle('Describe what people will find, with the words they would search for.'),
      'snapchat' => const NetworkStyle('A short caption on top of the picture.'),
      'tumblr' => const NetworkStyle('Tags go in the tags field, and people browse by them; the post can be playful.'),
      'google_business' => const NetworkStyle('What customers need: an offer, an event, opening hours. No hashtags.'),
      'telegram' || 'discord' || 'matrix' || 'whatsapp' => _chat,
      'wordpress' || 'ghost' || 'writefreely' || 'micropub' || 'devto' || 'hashnode' || 'substack' => _blog,
      _ => const NetworkStyle('Write it the way people there talk.'),
    };

final RegExp _tag = RegExp(r'(?<![\w#/])#([\p{L}\p{N}_]+)', unicode: true);
final RegExp _tagLine = RegExp(r'^\s*(#[\p{L}\p{N}_]+\s*)+$', unicode: true);

/// The hashtags of [text] in order (without `#`), deduplicated
/// case-insensitively, and the text with trailing hashtag-only lines removed
/// and inline hashtags turned into plain words.
(String, List<String>) _splitHashtags(String text) {
  final lines = text.trimRight().split('\n');
  final trailing = <String>[];
  while (lines.isNotEmpty && (lines.last.trim().isEmpty || _tagLine.hasMatch(lines.last))) {
    trailing.insert(0, lines.removeLast());
  }
  final body = lines.join('\n');
  final tags = <String>[];
  final seen = <String>{};
  void add(String t) {
    if (seen.add(t.toLowerCase())) tags.add(t);
  }

  final plain = body.replaceAllMapped(_tag, (m) {
    add(m[1]!);
    return m[1]!;
  });
  for (final l in trailing) {
    for (final m in _tag.allMatches(l)) {
      add(m[1]!);
    }
  }
  return (plain.trimRight(), tags);
}

/// Like [_splitHashtags] but leaves inline hashtags in place: only the
/// trailing hashtag lines are taken off.
(String, List<String>) _splitTrailingTags(String text) {
  final lines = text.trimRight().split('\n');
  final tags = <String>[];
  while (lines.isNotEmpty && (lines.last.trim().isEmpty || _tagLine.hasMatch(lines.last))) {
    final l = lines.removeLast();
    tags.insertAll(0, _tag.allMatches(l).map((m) => m[1]!));
  }
  return (lines.join('\n').trimRight(), tags);
}

String _withTags(String body, List<String> tags) => tags.isEmpty ? body : '${body.trimRight()}\n\n${tags.map((t) => '#$t').join(' ')}';

String _removeUrls(String text) {
  final urls = UrlDetector.find(text);
  if (urls.isEmpty) return text;
  final b = StringBuffer();
  var at = 0;
  for (final u in urls) {
    // A short label that only introduces the link ("Guide: https://…") goes too.
    b.write(text.substring(at, u.start).replaceFirstMapped(_linkLabel, (m) => m[1]!));
    at = u.end;
  }
  b.write(text.substring(at));
  return b
      .toString()
      .replaceAll(RegExp(r'[ \t]+([.,;:!?])'), r'$1')
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .replaceAll(RegExp(r'[:\s]+$'), '')
      .trim();
}

final RegExp _linkLabel = RegExp(r"(^|[.!?…]\s+|\n)([\p{L}\p{N}][\p{L}\p{N} '’-]{0,30}:\s*)$", unicode: true);

final RegExp _sentenceEnd = RegExp(r'(?<=[.!?…])\s+(?=[\p{Lu}\p{N}"“(])', unicode: true);

/// Applies [t] to [text] for a network with descriptor [d].
String applyTransform(VersionTransform t, String text, PlatformDescriptor d) {
  switch (t) {
    case VersionTransform.fit:
      final rules = d.text;
      if (rules.maxLength == null || TextCounter.fits(text, rules)) return text;
      return TextSplitter.truncate(text, rules);
    case VersionTransform.hashtagsToEnd:
      final (body, tags) = _splitHashtags(text);
      return _withTags(body, tags);
    case VersionTransform.fewerHashtags:
      final (body, tags) = _splitHashtags(text);
      return _withTags(body, tags.take(styleFor(d.id).maxHashtags).toList());
    case VersionTransform.noHashtags:
      return _splitHashtags(text).$1;
    case VersionTransform.linkInBio:
      final (body, tags) = _splitTrailingTags(text);
      final removed = _removeUrls(body);
      if (removed == body.trim()) return text;
      return _withTags('${removed.trimRight()}\n\nLink in bio.', tags);
    case VersionTransform.noLink:
      final (body, tags) = _splitTrailingTags(text);
      return _withTags(_removeUrls(body), tags);
    case VersionTransform.airy:
      final paragraphs = text.split(RegExp(r'\n\s*\n'));
      return [
        for (final p in paragraphs)
          p.length > 100 && !p.contains('\n') ? p.split(_sentenceEnd).map((s) => s.trim()).where((s) => s.isNotEmpty).join('\n\n') : p,
      ].join('\n\n');
  }
}

/// The changes worth offering for [text] on this network: only those that
/// would change something.
List<VersionTransform> usefulTransforms(String text, PlatformDescriptor d) => [
      for (final t in VersionTransform.values)
        if (t != VersionTransform.fit || !d.text.supportsThreads)
          if (applyTransform(t, text, d).trim() != text.trim()) t,
    ];
