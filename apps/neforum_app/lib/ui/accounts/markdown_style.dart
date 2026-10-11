import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

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

/// Convenience widget. Selectable by default: setup steps are full of
/// addresses, scopes and redirect URIs people copy into other sites, so the
/// whole block can be drag-selected (across paragraphs) and copied, while
/// links still open on tap.
class NfMarkdown extends StatelessWidget {
  const NfMarkdown(this.data, {super.key, this.small = false, this.selectable = true});
  final String data;
  final bool small;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final body = MarkdownBody(
      data: data,
      styleSheet: neforumMarkdown(context, small: small),
      onTapLink: openMarkdownLink,
    );
    return selectable ? SelectionArea(child: body) : body;
  }
}
