import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import 'guide_sheet.dart';

/// Markdown styled to match the app (connect intros, setup guides).
MarkdownStyleSheet neforumMarkdown(BuildContext context, {bool small = false}) {
  final nf = context.nf;
  final t = context.text;
  final body = (small ? t.bodySmall : t.bodyMedium)!.copyWith(color: small ? nf.textMuted : nf.text, height: 1.55);
  return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
    p: body,
    a: body.copyWith(color: nf.accent, decoration: TextDecoration.underline, decorationColor: nf.accent.withValues(alpha: 0.4)),
    strong: body.copyWith(fontWeight: FontWeight.w700),
    em: body.copyWith(fontStyle: FontStyle.italic),
    h1: t.headlineSmall,
    h2: t.titleLarge,
    h3: t.titleMedium,
    h4: t.titleSmall,
    h1Padding: const EdgeInsets.only(top: Space.md, bottom: Space.xs),
    h2Padding: const EdgeInsets.only(top: Space.lg, bottom: Space.xs),
    h3Padding: const EdgeInsets.only(top: Space.md),
    listBullet: body,
    listIndent: 22,
    blockSpacing: small ? Space.sm : Space.md,
    code: monoStyle(context, size: small ? 11.5 : 12.5, color: nf.text).copyWith(backgroundColor: nf.surfaceSunken),
    codeblockDecoration: BoxDecoration(color: nf.surfaceSunken, borderRadius: Radii.rSm, border: Border.all(color: nf.border)),
    codeblockPadding: const EdgeInsets.all(Space.md),
    blockquote: body.copyWith(color: nf.textMuted),
    blockquoteDecoration: BoxDecoration(
      color: nf.surfaceSunken,
      borderRadius: Radii.rSm,
      border: Border(left: BorderSide(color: nf.accent, width: 3)),
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, Space.sm),
    tableHead: body.copyWith(fontWeight: FontWeight.w700),
    tableBody: body,
    tableBorder: TableBorder.all(color: nf.border),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs + 2),
    horizontalRuleDecoration: BoxDecoration(border: Border(top: BorderSide(color: nf.border))),
  );
}

/// Opens links from markdown in the system browser.
void openMarkdownLink(String text, String? href, String title) {
  if (href == null) return;
  final uri = Uri.tryParse(href);
  if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http' || uri.scheme == 'mailto')) return;
  launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// The bundled guide a relative link in a guide points to, as a file name
/// under assets/docs (`../media-hosts.md` gives `media-hosts.md`), or null
/// for any other link. The guides sit in one folder in the app, so the same
/// links work on GitHub and in NEFORUM.
String? guideAssetForLink(String? href) {
  if (href == null) return null;
  final uri = Uri.tryParse(href);
  if (uri == null || uri.hasScheme || uri.hasAuthority || uri.pathSegments.isEmpty) return null;
  final name = uri.pathSegments.last;
  return RegExp(r'^[a-z0-9_-]+\.md$').hasMatch(name) ? name : null;
}

/// The heading a relative link points to, as an anchor: `#fallback-host` and
/// `media-hosts.md#fallback-host` both give `fallback-host`. Null for a link
/// without one and for links to other sites.
String? guideAnchorForLink(String? href) {
  if (href == null) return null;
  final uri = Uri.tryParse(href);
  if (uri == null || uri.hasScheme || uri.hasAuthority || !uri.hasFragment || uri.fragment.isEmpty) return null;
  return uri.fragment.toLowerCase();
}

/// The anchor of a heading as GitHub makes it, so that links between and
/// within the guides work the same on GitHub and in NEFORUM: lower case,
/// punctuation removed, spaces become hyphens ("Fallback host" gives
/// `fallback-host`, "Steps: Hand-off" gives `steps-hand-off`).
String guideHeadingAnchor(String heading) => heading
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{M}\p{N} _-]', unicode: true), '')
    .replaceAll(' ', '-');

/// Convenience widget. Selectable by default: setup steps are full of
/// addresses, scopes and redirect URIs people copy into other sites, so the
/// whole block can be drag-selected (across paragraphs) and copied, while
/// links still open on tap.
///
/// A link to another guide opens that guide (at the heading it names, if
/// any). A link to a heading of the same text (`#anchor`) goes to
/// [onAnchor]; without it such links do nothing.
class NfMarkdown extends StatelessWidget {
  const NfMarkdown(this.data, {super.key, this.small = false, this.selectable = true, this.onAnchor});
  final String data;
  final bool small;
  final bool selectable;
  final ValueChanged<String>? onAnchor;

  @override
  Widget build(BuildContext context) {
    final body = MarkdownBody(
      data: data,
      styleSheet: neforumMarkdown(context, small: small),
      onTapLink: (text, href, title) {
        final anchor = guideAnchorForLink(href);
        if (href != null && href.startsWith('#')) {
          if (anchor != null) onAnchor?.call(anchor);
          return;
        }
        final guide = guideAssetForLink(href);
        if (guide == null) return openMarkdownLink(text, href, title);
        showGuideSheet(context, guide.substring(0, guide.length - 3), section: anchor);
      },
    );
    return selectable ? SelectionArea(child: body) : body;
  }
}
