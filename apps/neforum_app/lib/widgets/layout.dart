import 'package:flutter/material.dart';

import '../brand/neforum_logo.dart';
import '../theme/tokens.dart';

/// Big editorial page title with optional subtitle and actions on the right.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.subtitle, this.actions = const [], this.eyebrow});

  final String title;
  final String? subtitle;

  /// Small uppercase label above the title.
  final String? eyebrow;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final compact = context.isCompact;
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (eyebrow != null) ...[
          Text(eyebrow!.toUpperCase(), style: context.text.labelSmall?.copyWith(color: nf.accent, letterSpacing: 1.6)),
          const SizedBox(height: Space.xs + 2),
        ],
        Text(title, style: compact ? context.text.headlineLarge : context.text.displaySmall),
        if (subtitle != null) ...[
          const SizedBox(height: Space.xs + 2),
          Text(subtitle!, style: context.text.bodyLarge?.copyWith(color: nf.textMuted)),
        ],
      ],
    );
    if (actions.isEmpty) return titleBlock;
    if (compact) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        titleBlock,
        const SizedBox(height: Space.lg),
        Wrap(spacing: Space.sm, runSpacing: Space.sm, children: actions),
      ]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Expanded(child: titleBlock),
      const SizedBox(width: Space.lg),
      Wrap(spacing: Space.sm, runSpacing: Space.sm, children: actions),
    ]);
  }
}

/// Scrollable page body with responsive gutters and an optional max width.
class PageBody extends StatefulWidget {
  const PageBody({super.key, required this.children, this.maxWidth = 1240, this.controller, this.bottomPadding = Space.x5, this.physics});

  final List<Widget> children;
  final double maxWidth;
  final ScrollController? controller;
  final double bottomPadding;

  /// Scroll physics; null = the platform's.
  final ScrollPhysics? physics;

  static EdgeInsets gutters(BuildContext context) {
    final w = context.width;
    final h = w < Breakpoints.compact ? Space.lg : (w < Breakpoints.expanded ? Space.xxl : Space.x4);
    return EdgeInsets.symmetric(horizontal: h);
  }

  /// Space above the first child.
  static double topPadding(BuildContext context) => context.isCompact ? Space.lg : (context.denseLayout ? Space.xxl : Space.x4);

  @override
  State<PageBody> createState() => _PageBodyState();
}

class _PageBodyState extends State<PageBody> {
  /// Used when no controller is given. Without one, the scrollbar falls back
  /// to the PrimaryScrollController, which desktop scroll views do not
  /// attach to ("The Scrollbar's ScrollController has no ScrollPosition
  /// attached" as soon as the page scrolls).
  ScrollController? _own;

  ScrollController get _controller => widget.controller ?? (_own ??= ScrollController());

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = PageBody.gutters(context);
    final controller = _controller;
    return Scrollbar(
      controller: controller,
      child: SingleChildScrollView(
        controller: controller,
        physics: widget.physics,
        padding: EdgeInsets.fromLTRB(g.left, PageBody.topPadding(context), g.right, widget.bottomPadding),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.maxWidth),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.children),
          ),
        ),
      ),
    );
  }
}

/// Section title used inside pages and cards.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.subtitle, this.trailing, this.icon});

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      if (icon != null) ...[Icon(icon, size: 18, color: nf.textMuted), const SizedBox(width: Space.sm)],
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(title, style: context.text.titleLarge),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!, style: context.text.bodySmall),
          ],
        ]),
      ),
      ?trailing,
    ]);
  }
}

/// Friendly empty state with the animated mark or an icon.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, required this.body, this.icon, this.action, this.compact = false});

  final String title;
  final String body;

  /// When null the NEFORUM mark is shown.
  final IconData? icon;
  final Widget? action;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? Space.xxl : Space.x6, horizontal: Space.xxl),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (icon == null)
          NeforumMark(size: compact ? 44 : 60)
        else
          Container(
            width: compact ? 52 : 68,
            height: compact ? 52 : 68,
            decoration: BoxDecoration(color: nf.accentSoft, borderRadius: Radii.rLg),
            child: Icon(icon, size: compact ? 24 : 30, color: nf.accent),
          ),
        SizedBox(height: compact ? Space.lg : Space.xxl),
        Text(title, textAlign: TextAlign.center, style: compact ? context.text.titleLarge : context.text.headlineSmall),
        const SizedBox(height: Space.sm),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(body, textAlign: TextAlign.center, style: context.text.bodyMedium?.copyWith(color: nf.textMuted)),
        ),
        if (action != null) ...[const SizedBox(height: Space.xxl), action!],
      ]),
    );
  }
}

/// Draws [child] at [scale] of its size, like a page zoomed out: it is laid
/// out `1 / scale` times wider than the space it gets, then shrunk to fit
/// that width. Taps still land on what is drawn.
class ScaledDown extends StatelessWidget {
  const ScaledDown({super.key, required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      if (!c.hasBoundedWidth) return child;
      return FittedBox(
        fit: BoxFit.fitWidth,
        alignment: Alignment.topLeft,
        child: SizedBox(width: c.maxWidth / scale, child: child),
      );
    });
  }
}

/// Lays out [children] in as many equal columns as fit [minItemWidth].
class ResponsiveGrid extends StatelessWidget {
  const ResponsiveGrid({super.key, required this.children, this.minItemWidth = 280, this.spacing = Space.lg, this.maxColumns = 4});

  final List<Widget> children;
  final double minItemWidth;
  final double spacing;
  final int maxColumns;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      var cols = ((c.maxWidth + spacing) / (minItemWidth + spacing)).floor().clamp(1, maxColumns);
      // Avoid a lonely last row (4 tiles as 3 + 1) when one fewer column
      // divides the items evenly.
      final n = children.length;
      if (n > cols && n % cols != 0 && cols - 1 >= 2 && n % (cols - 1) == 0) cols -= 1;
      final w = (c.maxWidth - spacing * (cols - 1)) / cols;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [for (final child in children) SizedBox(width: w, child: child)],
      );
    });
  }
}

/// Toast helper with tone-colored icon.
void showToast(BuildContext context, String message, {IconData? icon, Color? iconColor, String? actionLabel, VoidCallback? onAction}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final nf = context.nf;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Row(children: [
        if (icon != null) ...[Icon(icon, size: 18, color: iconColor ?? nf.bg), const SizedBox(width: Space.md)],
        Expanded(child: Text(message)),
      ]),
      action: actionLabel == null ? null : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
      width: context.isCompact ? null : 460,
    ));
}

/// Confirmation dialog. Returns true when confirmed.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool destructive = false,
}) async {
  final nf = context.nf;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Text(message)),
      actionsPadding: const EdgeInsets.fromLTRB(Space.xxl, 0, Space.xxl, Space.xl),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), style: TextButton.styleFrom(foregroundColor: nf.textMuted), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: destructive ? FilledButton.styleFrom(backgroundColor: nf.danger) : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}
