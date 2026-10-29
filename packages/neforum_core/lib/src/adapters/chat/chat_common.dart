import '../../http/neforum_http.dart';
import '../../model/audio.dart';
import '../../model/media.dart';
import '../../model/publish_result.dart';

/// Helpers shared by the chat adapters (Telegram, Discord, Matrix).
///
/// Nothing in here talks to the network itself; it is text, value and error
/// handling so it can be unit-tested in isolation.

/// The messages of one post that goes out as several messages (thread
/// parts, media + text). Once one of them is live, a failure must be
/// reported through [PublishError.asPartialThread]: a retry would post the
/// earlier messages a second time.
class ChatMessages {
  final List<String> ids = [];

  /// How many messages the post needs in total.
  int total = 1;

  void add(String id) => ids.add(id);

  /// [error] as the post's failure: unchanged while nothing is live yet,
  /// otherwise a non-retryable partial failure naming the live messages.
  PublishError fail(PublishError error) =>
      error.asPartialThread(postedIds: ids, total: total > ids.length ? total : ids.length + 1);
}

/// Longest flood wait a chat adapter sits out between the messages of one
/// post. A longer wait fails the post (as a partial failure).
const Duration chatMaxFloodWait = Duration(seconds: 10);

/// Runs [send]. When it fails with a short flood wait ([floodWait] returns
/// how long the platform asked to wait, or `null` for any other error), waits
/// once and tries again. A 429 means the message was not accepted, so the
/// second try cannot duplicate it.
Future<T> chatSendWithFloodWait<T>(Future<T> Function() send, Duration? Function(Object error) floodWait) async {
  try {
    return await send();
  } on Object catch (e) {
    final wait = floodWait(e);
    if (wait == null || wait > chatMaxFloodWait) rethrow;
    await Future<void>.delayed(wait);
    return send();
  }
}

/// Maps an exception that is not an answer from the platform (network
/// failure, unreadable media file, ...) onto a [PublishError]. [secret] is
/// blanked out of the text: the Telegram bot token is part of every URL.
PublishError chatUnexpected(Object e, String host, {String? secret}) {
  var text = e.toString();
  if (secret != null && secret.isNotEmpty) text = text.replaceAll(secret, '<token>');
  if (NeforumHttp.isTransportError(e)) {
    return PublishError.network('Could not reach $host', raw: chatSnippet(text));
  }
  // dart:io is off limits in lib/, so recognise file errors by name.
  if (text.startsWith('FileSystemException') || text.contains('PathNotFoundException')) {
    return PublishError.configuration(
        'A media file for this post is missing or unreadable. Re-attach it and try again. (${chatSnippet(text, 200)})');
  }
  return PublishError.platform('Unexpected error while posting via $host: ${chatSnippet(text, 200)}');
}

/// Non-empty string or `null`.
String? chatStr(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

/// Integer from a JSON number or numeric string.
int? chatInt(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);

/// String form of a JSON id that may arrive as a number (Telegram) or a
/// string (Discord snowflakes).
String? chatId(Object? v) => v is num ? v.toInt().toString() : chatStr(v);

/// Truncates a body for [PublishError.raw].
String chatSnippet(String body, [int max = 600]) => body.length > max ? '${body.substring(0, max)}…' : body;

/// The file name to send for [m]; falls back to `<id>.<ext>`.
String chatFileName(MediaAttachment m) {
  final name = m.fileName?.trim();
  if (name != null && name.isNotEmpty) return name;
  return '${m.id}.${chatExtension(m.mimeType)}';
}

/// A file extension for a MIME type (`image/jpeg` -> `jpg`).
String chatExtension(String mime) {
  final audio = canonicalAudioMimeType(mime);
  if (audio != null) return audioExtensionFor(audio);
  final sub = mime.split('/').last.toLowerCase();
  return switch (sub) {
    'jpeg' => 'jpg',
    'quicktime' => 'mov',
    'x-m4v' => 'm4v',
    'svg+xml' => 'svg',
    _ => sub,
  };
}

/// Escapes `&`, `<`, `>` and `"` for HTML (valid for Telegram's HTML mode and
/// Matrix `formatted_body`).
String chatEscapeHtml(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

final RegExp _fence = RegExp(r'```([A-Za-z0-9_+-]*)\n?([\s\S]*?)```');
final RegExp _inlineCode = RegExp(r'`([^`\n]+)`');
final RegExp _mdLink = RegExp(r'\[([^\]\n]+)\]\((https?://[^\s)]+)\)');
final RegExp _bareUrl = RegExp(r'https?://[^\s<>"]+');
final RegExp _bold = RegExp(r'\*\*(?=\S)([^\n]*?\S)\*\*|__(?=\S)([^\n]*?\S)__');
final RegExp _strike = RegExp(r'~~(?=\S)([^\n]*?\S)~~');
final RegExp _italicStar = RegExp(r'(?<![\w*])\*(?=[^\s*])([^\n*]*?[^\s*])\*(?![\w*])');
final RegExp _italicUnderscore = RegExp(r'(?<![\w_])_(?=[^\s_])([^\n_]*?[^\s_])_(?![\w_])');

/// Converts a small, unambiguous Markdown subset into HTML: fenced and
/// inline code, `[label](https://url)`, `**bold**`/`__bold__`,
/// `*italic*`/`_italic_`, `~~strike~~` and `> ` quotes.
///
/// Returns `null` when [text] contains no Markdown at all, so callers can
/// send it as plain text instead. Everything else is HTML-escaped; URLs are
/// never touched by the emphasis rules.
///
/// With [brLineBreaks] (Matrix) newlines outside code blocks become `<br>`;
/// without it (Telegram, whose HTML mode keeps literal newlines) they stay.
String? chatMarkdownToHtml(String text, {bool brLineBreaks = false}) {
  var changed = false;
  final out = StringBuffer();
  var cursor = 0;
  for (final m in _fence.allMatches(text)) {
    out.write(_inline(text.substring(cursor, m.start), brLineBreaks, () => changed = true));
    final lang = m.group(1) ?? '';
    final code = chatEscapeHtml((m.group(2) ?? '').replaceFirst(RegExp(r'\n$'), ''));
    out.write(lang.isEmpty ? '<pre><code>$code</code></pre>' : '<pre><code class="language-$lang">$code</code></pre>');
    changed = true;
    cursor = m.end;
  }
  out.write(_inline(text.substring(cursor), brLineBreaks, () => changed = true));
  return changed ? out.toString() : null;
}

String _inline(String segment, bool br, void Function() markChanged) {
  if (segment.isEmpty) return '';
  final out = StringBuffer();
  var cursor = 0;
  for (final m in _inlineCode.allMatches(segment)) {
    out.write(_emphasis(segment.substring(cursor, m.start), br, markChanged));
    out.write('<code>${chatEscapeHtml(m.group(1)!)}</code>');
    markChanged();
    cursor = m.end;
  }
  out.write(_emphasis(segment.substring(cursor), br, markChanged));
  return out.toString();
}

String _emphasis(String plain, bool br, void Function() markChanged) {
  if (plain.isEmpty) return '';
  // Stash links and bare URLs so emphasis rules never rewrite them.
  final stash = <String>[];
  String keep(String html) {
    stash.add(html);
    return '\u0000${stash.length - 1}\u0000';
  }

  var s = plain.replaceAllMapped(_mdLink, (m) {
    markChanged();
    return keep('<a href="${chatEscapeHtml(m.group(2)!)}">${chatEscapeHtml(m.group(1)!)}</a>');
  });
  s = s.replaceAllMapped(_bareUrl, (m) => keep(chatEscapeHtml(m.group(0)!)));
  s = chatEscapeHtml(s);
  s = s.replaceAllMapped(_bold, (m) {
    markChanged();
    return '<b>${m.group(1) ?? m.group(2)}</b>';
  });
  s = s.replaceAllMapped(_strike, (m) {
    markChanged();
    return '<s>${m.group(1)}</s>';
  });
  s = s.replaceAllMapped(_italicStar, (m) {
    markChanged();
    return '<i>${m.group(1)}</i>';
  });
  s = s.replaceAllMapped(_italicUnderscore, (m) {
    markChanged();
    return '<i>${m.group(1)}</i>';
  });
  s = _quotes(s, br, markChanged);
  return s.replaceAllMapped(RegExp('\u0000(\\d+)\u0000'), (m) => stash[int.parse(m.group(1)!)]);
}

/// Groups consecutive `> ` lines (already escaped to `&gt; `) into
/// `<blockquote>` and applies the line-break style.
String _quotes(String s, bool br, void Function() markChanged) {
  final lines = s.split('\n');
  final out = <String>[];
  final quote = <String>[];
  final nl = br ? '<br>' : '\n';
  void flush() {
    if (quote.isEmpty) return;
    out.add('<blockquote>${quote.join(nl)}</blockquote>');
    quote.clear();
    markChanged();
  }

  for (final line in lines) {
    if (line.startsWith('&gt; ') || line == '&gt;') {
      quote.add(line.length > 5 ? line.substring(5) : '');
    } else {
      flush();
      out.add(line);
    }
  }
  flush();
  final buf = StringBuffer();
  for (var i = 0; i < out.length; i++) {
    buf.write(out[i]);
    if (i < out.length - 1) {
      // A blockquote is a block element: no extra <br> right after it.
      buf.write(br && out[i].endsWith('</blockquote>') ? '' : nl);
    }
  }
  return buf.toString();
}
