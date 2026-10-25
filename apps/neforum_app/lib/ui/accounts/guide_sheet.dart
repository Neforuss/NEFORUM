import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../brand/platform_brand.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import 'markdown_style.dart';

/// Shows the bundled setup guide for [platformId] (`docs/platforms/<id>.md`),
/// or another bundled guide when [platformId] is not a platform (for example
/// `media-hosts` for `docs/media-hosts.md`). [section] is the anchor of a
/// heading to open the guide at (`fallback-host`).
Future<void> showGuideSheet(BuildContext context, String platformId, {String? asset, String? section}) {
  final sheet = GuideSheet(platformId: platformId, asset: asset, section: section);
  if (context.isCompact) {
    return showModalBottomSheet<void>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => FractionallySizedBox(heightFactor: 0.92, child: sheet));
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 780, maxHeight: 860), child: sheet),
    ),
  );
}

class GuideSheet extends ConsumerWidget {
  const GuideSheet({super.key, required this.platformId, this.asset, this.section});
  final String platformId;

  /// Override the asset name (e.g. 'media-hosts.md').
  final String? asset;

  /// Anchor of the heading to show first, or null for the top.
  final String? section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final d = ref.watch(registryProvider).descriptor(platformId);
    final name = d?.name ?? platformId;
    final file = asset ?? '$platformId.md';
    final platformGuide = asset == null && d != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xl, Space.md, Space.md),
        child: Row(children: [
          if (platformGuide) ...[PlatformTile(platformId, size: 36), const SizedBox(width: Space.md)],
          Expanded(child: Text(platformGuide ? '$name setup guide' : 'Guide', style: context.text.headlineSmall)),
          IconButton(onPressed: () => Navigator.pop(context), tooltip: 'Close', icon: const Icon(Icons.close_rounded)),
        ]),
      ),
      Divider(height: 1, color: nf.border),
      Expanded(
        child: FutureBuilder<String>(
          future: rootBundle.loadString('assets/docs/$file'),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            if (snap.hasError || (snap.data ?? '').isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(Space.xxl),
                child: Text(
                  platformGuide ? 'The setup guide for $name is in docs/platforms/$file in the NEFORUM repository.' : 'This guide is $file in the docs folder of the NEFORUM repository.',
                  style: context.text.bodyMedium,
                ),
              );
            }
            return GuideBody(markdown: snap.data!, section: section, title: platformGuide ? '$name setup guide' : null);
          },
        ),
      ),
    ]);
  }
}

/// Whether a `##` heading names a numbered procedure: "Steps", or a heading
/// that starts with it ("Steps: Hand-off without keys").
bool isGuideProcedureHeading(String heading) => RegExp(r'^steps\b', caseSensitive: false).hasMatch(heading.trim());

/// One part of a guide, cut at its `##` headings.
@immutable
class GuideSection {
  const GuideSection({required this.title, required this.heading, required this.body, required this.anchors, required this.open});

  /// The `##` heading as plain text, or null for the text above the first
  /// one (the title and the introduction).
  final String? title;

  /// The heading line as written (`## Steps`), or empty for the introduction.
  final String heading;

  /// The markdown below the heading.
  final String body;

  /// Anchors of this section's heading and of every heading inside it.
  final Set<String> anchors;

  /// True for the leading part of the guide (the introduction and the
  /// numbered procedures right after it), which is always shown. False for an
  /// explanation section, shown as a panel that starts closed.
  final bool open;

  /// The section as markdown, heading included.
  String get markdown => heading.isEmpty ? body : '$heading\n\n$body';
}

/// Cuts a guide into its introduction and its `##` sections. The
/// introduction and every procedure section that follows it directly
/// ([isGuideProcedureHeading]) are [GuideSection.open]; every section after
/// the first explanation section is not. Headings inside fenced code blocks
/// are text, not headings.
List<GuideSection> parseGuide(String markdown) {
  final lines = markdown.replaceAll('\r\n', '\n').split('\n');
  final sections = <GuideSection>[];
  String? title;
  var heading = '';
  var body = <String>[];
  var anchors = <String>{};
  var leading = true;
  String? fence;

  void close() {
    final text = body.join('\n').trim();
    final name = title;
    if (name == null && text.isEmpty) return;
    if (name != null && !isGuideProcedureHeading(name)) leading = false;
    sections.add(GuideSection(title: name, heading: heading, body: text, anchors: anchors, open: leading));
  }

  for (final line in lines) {
    final marker = RegExp(r'^\s*(`{3,}|~{3,})').firstMatch(line)?.group(1);
    if (marker != null) {
      if (fence == null) {
        fence = marker;
      } else if (marker[0] == fence[0] && marker.length >= fence.length) {
        fence = null;
      }
    }
    final h = fence == null && marker == null ? RegExp(r'^\s{0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$').firstMatch(line) : null;
    if (h != null && h.group(1)!.length == 2) {
      close();
      final plain = _plainHeading(h.group(2)!);
      title = plain;
      heading = line.trim();
      body = [];
      anchors = {guideHeadingAnchor(plain)};
      continue;
    }
    if (h != null) anchors.add(guideHeadingAnchor(_plainHeading(h.group(2)!)));
    body.add(line);
  }
  close();
  return sections;
}

/// A heading as it reads: links keep their text, emphasis and code marks go.
String _plainHeading(String heading) => heading
    .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1)!)
    .replaceAll(RegExp(r'[*`]'), '')
    .trim();

/// The guide text: the introduction and the numbered steps open, every
/// explanation section ("How it works", "Limits", "Troubleshooting", ...) as
/// a titled panel that opens on tap, and "Show all details" to open them
/// all. Links to a heading open the panel that holds it.
///
/// It has its own scroll controller: a Scrollbar without one uses the
/// PrimaryScrollController, which desktop scroll views do not attach to, and
/// fails as soon as the guide scrolls.
class GuideBody extends StatefulWidget {
  const GuideBody({super.key, required this.markdown, this.section, this.title});
  final String markdown;

  /// Anchor of the heading to show first, or null for the top.
  final String? section;

  /// The title the sheet already shows above the text. A `#` title with the
  /// same words at the top of the guide is not repeated.
  final String? title;

  @override
  State<GuideBody> createState() => _GuideBodyState();
}

class _GuideBodyState extends State<GuideBody> {
  final ScrollController _scroll = ScrollController();
  late List<GuideSection> _sections;
  late List<GlobalKey> _keys;
  final Set<int> _expanded = {};

  @override
  void initState() {
    super.initState();
    _parse();
    final section = widget.section;
    if (section != null) WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(section));
  }

  @override
  void didUpdateWidget(GuideBody old) {
    super.didUpdateWidget(old);
    if (old.markdown != widget.markdown) {
      _expanded.clear();
      _parse();
    }
  }

  void _parse() {
    _sections = parseGuide(widget.markdown);
    final title = widget.title?.trim().toLowerCase();
    final intro = _sections.isEmpty ? null : _sections.first;
    if (title != null && intro != null && intro.title == null) {
      final lines = intro.body.split('\n');
      final h1 = RegExp(r'^#\s+(.*?)\s*$').firstMatch(lines.first);
      final words = h1 == null ? null : _plainHeading(h1.group(1)!).toLowerCase();
      const suffix = ' setup guide';
      if (words != null && (words == title || (title.endsWith(suffix) && words.endsWith(suffix)))) {
        final rest = lines.skip(1).join('\n').trim();
        _sections = [
          if (rest.isNotEmpty) GuideSection(title: null, heading: '', body: rest, anchors: intro.anchors, open: true),
          ..._sections.skip(1),
        ];
      }
    }
    _keys = [for (final _ in _sections) GlobalKey()];
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Iterable<int> get _panels sync* {
    for (var i = 0; i < _sections.length; i++) {
      if (!_sections[i].open) yield i;
    }
  }

  bool get _allExpanded => _panels.every(_expanded.contains);

  /// Opens the section that holds the heading [anchor] and scrolls to it.
  void _reveal(String anchor) {
    if (!mounted) return;
    final i = _sections.indexWhere((s) => s.anchors.contains(anchor));
    if (i < 0) return;
    if (!_sections[i].open && !_expanded.contains(i)) setState(() => _expanded.add(i));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _keys[i].currentContext;
      if (target != null && target.mounted) Scrollable.ensureVisible(target, duration: Motion.medium, curve: Motion.standard);
    });
  }

  void _toggleAll() => setState(() {
        if (_allExpanded) {
          _expanded.clear();
        } else {
          _expanded.addAll(_panels);
        }
      });

  @override
  Widget build(BuildContext context) {
    final panels = _panels.toList();
    final allExpanded = _allExpanded;
    return Scrollbar(
      controller: _scroll,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.lg, Space.xxl, Space.x4),
        child: SelectionArea(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < _sections.length; i++)
              if (_sections[i].open)
                Padding(
                  key: _keys[i],
                  padding: EdgeInsets.only(top: i == 0 ? 0 : Space.md),
                  child: NfMarkdown(_sections[i].markdown, selectable: false, onAnchor: _reveal),
                ),
            if (panels.isNotEmpty) ...[
              const SizedBox(height: Space.xxl),
              SelectionContainer.disabled(
                child: Row(children: [
                  Expanded(child: Text('Details', style: context.text.titleMedium)),
                  TextButton.icon(
                    onPressed: _toggleAll,
                    icon: Icon(allExpanded ? Icons.unfold_less_rounded : Icons.unfold_more_rounded, size: 18),
                    label: Text(allExpanded ? 'Hide all details' : 'Show all details'),
                  ),
                ]),
              ),
              const SizedBox(height: Space.sm),
              for (final i in panels)
                Padding(
                  key: _keys[i],
                  padding: const EdgeInsets.only(bottom: Space.sm),
                  child: _GuidePanel(
                    title: _sections[i].title!,
                    expanded: _expanded.contains(i),
                    onToggle: () => setState(() {
                      if (!_expanded.remove(i)) _expanded.add(i);
                    }),
                    child: NfMarkdown(_sections[i].body, selectable: false, onAnchor: _reveal),
                  ),
                ),
            ],
          ]),
        ),
      ),
    );
  }
}

/// One explanation section: its heading as a header that opens and closes
/// it, with the section's text below while open.
class _GuidePanel extends StatelessWidget {
  const _GuidePanel({required this.title, required this.expanded, required this.onToggle, required this.child});
  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return DecoratedBox(
      decoration: BoxDecoration(color: nf.surface, borderRadius: Radii.rMd, border: Border.all(color: nf.border)),
      child: ClipRRect(
        borderRadius: Radii.rMd,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SelectionContainer.disabled(
            child: Semantics(
              button: true,
              expanded: expanded,
              child: InkWell(
                onTap: onToggle,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.md, Space.md),
                  child: Row(children: [
                    Expanded(child: Text(title, style: context.text.titleSmall)),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: Motion.medium,
                      curve: Motion.standard,
                      child: Icon(Icons.expand_more_rounded, color: nf.textMuted),
                    ),
                  ]),
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: Motion.medium,
            curve: Motion.standard,
            alignment: Alignment.topCenter,
            child: expanded
                ? Padding(padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg), child: child)
                : const SizedBox(width: double.infinity),
          ),
        ]),
      ),
    );
  }
}
