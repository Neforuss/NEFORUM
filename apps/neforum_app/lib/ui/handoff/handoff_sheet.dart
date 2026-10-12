import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../brand/platform_brand.dart';
import '../../platform/browser_bridge.dart';
import '../../platform/clipboard_media.dart';
import '../../platform/env.dart';
import '../../platform/file_export.dart';
import '../../platform/ui_bridge.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/buttons.dart';
import '../../widgets/layout.dart';
import '../../widgets/media_thumb.dart';
import '../../widgets/surfaces.dart';
import '../accounts/guide_sheet.dart';

/// Shows the hand-off sheet (bottom sheet on phones, dialog elsewhere).
Future<HandoffChoice> showHandoffSheet(
  BuildContext context, {
  required HandoffPlan plan,
  required Post post,
  required ConnectedAccount account,
  required PostVariant variant,
}) async {
  final sheet = HandoffSheet(plan: plan, post: post, account: account, variant: variant);
  final HandoffChoice? r;
  if (context.isCompact) {
    r = await showModalBottomSheet<HandoffChoice>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => sheet);
  } else {
    r = await showDialog<HandoffChoice>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760), child: sheet),
      ),
    );
  }
  return r ?? HandoffChoice.later;
}

class HandoffSheet extends ConsumerStatefulWidget {
  const HandoffSheet({super.key, required this.plan, required this.post, required this.account, required this.variant});

  final HandoffPlan plan;
  final Post post;
  final ConnectedAccount account;
  final PostVariant variant;

  @override
  ConsumerState<HandoffSheet> createState() => _HandoffSheetState();
}

class _HandoffSheetState extends ConsumerState<HandoffSheet> {
  bool _copied = false;
  bool _launched = false;

  /// Where Save media to Downloads put the files.
  String? _saved;

  HandoffPlan get plan => widget.plan;

  String get _text => plan.clipboardText ?? plan.shareText ?? widget.variant.text;

  // ---- NEFORUM browser extension -------------------------------------------

  late final BrowserBridge _bridge;
  StreamSubscription<BrowserFillResult>? _fillSub;

  /// The hand-off the extension was given, the page it is for, and what it
  /// reported back.
  BrowserJob? _job;
  Uri? _jobUrl;
  BrowserFillResult? _fill;

  @override
  void initState() {
    super.initState();
    _bridge = ref.read(servicesProvider).browserBridge;
    _fillSub = _bridge.results.listen((r) {
      if (mounted && r.jobId == _job?.id) setState(() => _fill = r);
    });
  }

  @override
  void dispose() {
    unawaited(_fillSub?.cancel());
    // Closed sheet, finished hand-off: the page must not be filled in again.
    final job = _job;
    if (job != null) _bridge.clearJob(job.id);
    super.dispose();
  }

  /// Gives the post to the browser extension, which fills in the composer
  /// at [url] (when a browser is paired and [url] is a web page).
  void _sendToExtension(Uri url) {
    if (!_bridge.canFill || !(url.isScheme('http') || url.isScheme('https'))) return;
    final media = ref.read(servicesProvider).media;
    final d = ref.read(registryProvider).descriptor(widget.account.platformId);
    final job = _bridge.createJob(
      platformId: widget.account.platformId,
      platformName: d?.name ?? widget.account.platformId,
      url: url.toString(),
      hosts: browserJobHosts(url),
      text: _text,
      title: widget.variant.title,
      snippets: plan.snippets,
      media: [
        for (final m in plan.shareFiles)
          BrowserJobMedia(name: _fileName(m), mimeType: m.mimeType, size: m.sizeBytes, isVideo: m.isVideo, read: () => media.read(m)),
      ],
      steps: plan.instructions,
    );
    if (job == null) return;
    setState(() {
      _job = job;
      _jobUrl = url;
      _fill = null;
    });
  }

  static String _fileName(MediaAttachment m) {
    if ((m.fileName ?? '').isNotEmpty) return m.fileName!;
    final ext = p.extension(m.path).isEmpty ? (m.isVideo ? '.mp4' : '.jpg') : p.extension(m.path);
    return m.generated ? 'NEFORUM card$ext' : '${m.id}$ext';
  }

  /// "text and 2 photos", "1 video", "" for nothing.
  String _filledWhat(BrowserFillResult r) {
    final files = _job?.media ?? const <BrowserJobMedia>[];
    final noun = files.isNotEmpty && files.every((m) => m.isVideo)
        ? (r.media == 1 ? 'video' : 'videos')
        : files.any((m) => m.isVideo)
            ? (r.media == 1 ? 'file' : 'files')
            : (r.media == 1 ? 'photo' : 'photos');
    return [if (r.text) 'text', if (r.media > 0) '${r.media} $noun'].join(' and ');
  }

  static String _sentence(String s) => RegExp(r'[.!?…]$').hasMatch(s) ? s : '$s.';

  /// "The NEFORUM extension is filling this in…", then what it reported.
  Widget? _extensionStatus(NfColors nf) {
    if (_job == null) return null;
    final r = _fill;
    final host = r == null || bareHost(r.host).isEmpty ? 'the page' : bareHost(r.host);
    final what = r == null ? '' : _filledWhat(r);
    final message = r?.message == null ? '' : ' ${_sentence(r!.message!)}';
    final (IconData icon, Color color, String text) = switch (r?.status) {
      null => (Icons.extension_outlined, nf.info, 'The NEFORUM extension is filling this in…'),
      BrowserFillStatus.filled => (Icons.check_circle_rounded, nf.success, 'Filled in on $host${what.isEmpty ? '' : ': $what'}. Check it and press Post.'),
      BrowserFillStatus.partial => (Icons.warning_amber_rounded, nf.warning, 'Partly filled in on $host${what.isEmpty ? '' : ': $what'}.$message Do the rest with the steps below.'),
      BrowserFillStatus.failed => (Icons.error_outline_rounded, nf.danger, 'The extension could not fill in $host.$message Use the steps below.'),
    };
    return _Callout(
      icon: icon,
      color: color,
      text: text,
      action: _jobUrl == null
          ? null
          : TextButton.icon(
              onPressed: () => _sendToExtension(_jobUrl!),
              icon: const Icon(Icons.replay_rounded, size: 16),
              label: const Text('Fill in again'),
            ),
    );
  }

  Future<void> _copy({bool quiet = false}) async {
    await Clipboard.setData(ClipboardData(text: _text));
    if (!mounted) return;
    setState(() {
      _copied = true;
      // The text is the first thing "Copy next" hands out.
      if (_next == 0 && _text.isNotEmpty) _next = 1;
    });
    if (!quiet) showToast(context, 'Text copied. Paste it when the composer opens.', icon: Icons.check_circle_rounded);
  }

  /// Ctrl+V, or ⌘V on a Mac.
  static String get _pasteKeys => Env.isMacOS ? '⌘V' : 'Ctrl+V';

  /// Photos that can go on the clipboard (videos are dragged in instead).
  List<MediaAttachment> get _photos => [for (final m in plan.shareFiles) if (m.isImage) m];

  final Set<String> _copiedPhotos = {};

  /// Puts photo [m] on the clipboard for pasting into the composer.
  Future<bool> _copyPhoto(MediaAttachment m) async {
    final bytes = await ref.read(servicesProvider).media.read(m);
    final ok = await ClipboardMedia.copyImage(bytes, path: m.path);
    if (!mounted) return ok;
    if (ok) setState(() => _copiedPhotos.add(m.id));
    showToast(
      context,
      ok ? 'Photo copied. Press $_pasteKeys in the composer.' : 'Could not copy the photo. Use Save media to Downloads and drag it in.',
      icon: ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
    );
    return ok;
  }

  /// Index into [_pasteItems] of what "Copy next" copies.
  int _next = 0;

  /// Everything there is to paste, in order: the text, the snippets (poll
  /// answers and the like), then each photo.
  List<({String label, Future<void> Function() copy})> get _pasteItems {
    final photos = _photos;
    return [
      if (_text.isNotEmpty) (label: 'Text', copy: () => _copy()),
      for (final s in plan.snippets)
        (
          label: s.label,
          copy: () async {
            await Clipboard.setData(ClipboardData(text: s.text));
            if (mounted) showToast(context, '${s.label} copied. Press $_pasteKeys.', icon: Icons.check_circle_rounded);
          },
        ),
      if (ClipboardMedia.supported)
        for (var i = 0; i < photos.length; i++)
          (label: photos.length == 1 ? 'Photo' : 'Photo ${i + 1} of ${photos.length}', copy: () => _copyPhoto(photos[i]).then((_) {})),
    ];
  }

  Future<void> _copyNext() async {
    final items = _pasteItems;
    if (items.isEmpty) return;
    final i = _next % items.length;
    await items[i].copy();
    if (mounted) setState(() => _next = i + 1);
  }

  Future<void> _openUrl(Uri url) async {
    await _copy(quiet: true);
    if (mounted) _sendToExtension(url);
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!mounted) return;
    setState(() => _launched = ok || _launched);
    if (!ok) showToast(context, 'Could not open $url', icon: Icons.error_outline_rounded);
  }

  Future<void> _share(BuildContext buttonContext) async {
    // Read the anchor before any await: iPad/macOS need it for the popover.
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    await _copy(quiet: true);
    final media = ref.read(servicesProvider).media;
    final files = <XFile>[];
    for (final m in plan.shareFiles) {
      if (Env.isWeb) {
        files.add(XFile.fromData(await media.read(m), mimeType: m.mimeType, name: m.fileName ?? m.id));
      } else {
        files.add(XFile(m.path, mimeType: m.mimeType, name: m.fileName));
      }
    }
    final r = await SharePlus.instance.share(
      ShareParams(text: files.isEmpty ? (plan.shareText ?? _text) : plan.shareText, files: files.isEmpty ? null : files, sharePositionOrigin: origin),
    );
    if (!mounted) return;
    setState(() => _launched = _launched || r.status == ShareResultStatus.success || r.status == ShareResultStatus.unavailable);
  }

  /// Desktop has no share sheet for files: save copies with readable names
  /// into a dated folder under Downloads/NEFORUM and open that folder with
  /// the files selected, ready to drag into the browser's upload box.
  Future<void> _saveMedia(String platformName) async {
    final media = ref.read(servicesProvider).media;
    final files = <ExportFile>[];
    var n = 0;
    for (final m in plan.shareFiles) {
      n++;
      final ext = p.extension(m.fileName ?? m.path).isEmpty ? '.jpg' : p.extension(m.fileName ?? m.path);
      final name = m.generated
          ? 'NEFORUM card - $platformName$ext'
          : '$n${(m.fileName ?? '').isEmpty ? ext : ' - ${m.fileName}'}';
      files.add(ExportFile(name, await media.read(m), mimeType: m.mimeType));
    }
    final words = widget.variant.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty && !w.startsWith('http')).take(5).join(' ');
    final folder = '${DateFormat('yyyy-MM-dd HHmm').format(DateTime.now())} $platformName${words.isEmpty ? '' : ' - $words'}';
    try {
      final r = await FileExport.save(folder, files);
      if (!mounted) return;
      setState(() => _saved = r.location);
      showToast(context, 'Saved ${files.length} ${files.length == 1 ? 'file' : 'files'} to ${r.location}', icon: Icons.download_done_rounded);
    } on Object catch (e) {
      if (mounted) showToast(context, 'Could not save the files: $e', icon: Icons.error_outline_rounded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final d = ref.watch(registryProvider).descriptor(widget.account.platformId);
    final name = d?.name ?? widget.account.platformId;
    final steps = _steps(plan.instructions);
    final appTarget = _appUrl();
    final extensionStatus = _extensionStatus(nf);
    // Listening, nobody paired, and something to open: say the extension exists.
    final extensionHint = Env.isDesktop && _job == null && _bridge.status.value.listening && _bridge.browsers.value.isEmpty && (plan.webIntent != null || appTarget != null);

    final actions = <Widget>[];
    void addAction(Widget w) => actions.add(
      Padding(
        padding: const EdgeInsets.only(bottom: Space.sm),
        child: w,
      ),
    );

    // Phones put the share sheet first; a computer's share menu rarely has
    // the network's app, so there the composer link or manual steps lead.
    final shareFirst = plan.preferred == HandoffMethod.shareSheet && Env.isMobile;
    if (shareFirst) {
      addAction(
        Builder(
          builder: (bc) => PrimaryAction(
            label: plan.hasMedia ? 'Share ${plan.shareFiles.length == 1 ? 'photo' : '${plan.shareFiles.length} files'} to $name' : 'Share to $name',
            icon: Icons.ios_share_rounded,
            expand: true,
            onPressed: () => _share(bc),
          ),
        ),
      );
    }
    if (plan.webIntent != null) {
      final w = PrimaryAction(label: 'Open $name composer', icon: Icons.open_in_new_rounded, expand: true, onPressed: () => _openUrl(plan.webIntent!));
      addAction(
        shareFirst
            ? OutlinedButton.icon(
                onPressed: () => _openUrl(plan.webIntent!),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: Text('Open $name composer'),
              )
            : w,
      );
    }
    if (!shareFirst && plan.hasMedia && Env.hasShareSheet) {
      addAction(
        Builder(
          builder: (bc) =>
              OutlinedButton.icon(onPressed: () => _share(bc), icon: const Icon(Icons.ios_share_rounded, size: 18), label: const Text('Share with media')),
        ),
      );
    }
    if (appTarget != null && plan.webIntent == null && !shareFirst) {
      addAction(PrimaryAction(label: 'Open $name', icon: Icons.open_in_new_rounded, expand: true, onPressed: () => _openUrl(appTarget)));
    } else if (appTarget != null && (plan.webIntent == null || shareFirst)) {
      addAction(OutlinedButton.icon(onPressed: () => _openUrl(appTarget), icon: const Icon(Icons.open_in_new_rounded, size: 18), label: Text('Open $name')));
    }
    // On a computer: hand out the text, snippets and photos one per click,
    // so posting is click here, paste there, repeat.
    final pasteItems = _pasteItems;
    if (Env.isDesktop && pasteItems.length > 1) {
      final done = _next >= pasteItems.length;
      addAction(OutlinedButton.icon(
        onPressed: _copyNext,
        icon: Icon(done ? Icons.replay_rounded : Icons.content_paste_go_rounded, size: 18),
        label: Text(done ? 'All copied. Start again with the text' : 'Copy next: ${pasteItems[_next].label}'),
      ));
    }
    if (plan.hasMedia && (Env.isDesktop || Env.isWeb)) {
      addAction(OutlinedButton.icon(
        onPressed: () => _saveMedia(name),
        icon: Icon(_saved == null ? Icons.download_rounded : Icons.download_done_rounded, size: 18),
        label: Text(_saved == null ? 'Save media to Downloads' : 'Saved: open again'),
      ));
    }

    final footer = Padding(
      padding: const EdgeInsets.fromLTRB(Space.xl, Space.md, Space.xl, Space.lg),
      child: Row(
        children: [
          TextButton(
            onPressed: () => Navigator.pop(context, HandoffChoice.skip),
            style: TextButton.styleFrom(foregroundColor: nf.textMuted),
            child: const Text('Skip'),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.pop(context, HandoffChoice.later),
            style: TextButton.styleFrom(foregroundColor: nf.textMuted),
            child: const Text('Later'),
          ),
          const SizedBox(width: Space.sm),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, HandoffChoice.posted),
            style: FilledButton.styleFrom(backgroundColor: _launched ? nf.success : null),
            icon: const Icon(Icons.check_rounded, size: 18),
            label: const Text('I posted it'),
          ),
        ],
      ),
    );

    // Content scrolls; the decision buttons stay pinned at the bottom.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(Space.xxl, Space.lg, Space.xxl, Space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    PlatformTile(widget.account.platformId, size: 48),
                    const SizedBox(width: Space.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Finish on $name', style: context.text.headlineSmall),
                          const SizedBox(height: 2),
                          Text(widget.account.handle ?? widget.account.displayName, style: context.text.bodySmall?.copyWith(color: nf.textFaint)),
                        ],
                      ),
                    ),
                    const TierBadge(PlatformTier.handoff, dense: false),
                  ],
                ),
                const SizedBox(height: Space.xl),

                // Text to paste.
                NfWell(
                  padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.sm, Space.md),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 160),
                          child: SingleChildScrollView(child: SelectableText(_text.isEmpty ? '(no text)' : _text, style: context.text.bodyMedium)),
                        ),
                      ),
                      const SizedBox(width: Space.sm),
                      ToolButton(
                        icon: _copied ? Icons.check_rounded : Icons.copy_rounded,
                        tooltip: _copied ? 'Copied' : 'Copy text',
                        active: _copied,
                        onPressed: _copy,
                      ),
                    ],
                  ),
                ),
                for (final sn in plan.snippets) ...[
                  const SizedBox(height: Space.sm),
                  _SnippetRow(snippet: sn),
                ],
                if (plan.hasMedia) ...[
                  const SizedBox(height: Space.md),
                  SizedBox(
                    height: 72,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: plan.shareFiles.length,
                      separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
                      itemBuilder: (_, i) {
                        final m = plan.shareFiles[i];
                        final thumb = MediaThumb(m, size: 72);
                        if (!ClipboardMedia.supported || !m.isImage) return thumb;
                        final n = _photos.indexOf(m) + 1;
                        final copied = _copiedPhotos.contains(m.id);
                        return Stack(children: [
                          thumb,
                          Positioned(
                            right: 3,
                            bottom: 3,
                            child: Material(
                              color: copied ? nf.success : Colors.black.withValues(alpha: 0.62),
                              shape: const CircleBorder(),
                              child: IconButton(
                                tooltip: _photos.length == 1 ? 'Copy photo' : 'Copy photo $n',
                                iconSize: 15,
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                                padding: EdgeInsets.zero,
                                color: Colors.white,
                                icon: Icon(copied ? Icons.check_rounded : Icons.copy_rounded),
                                onPressed: () => _copyPhoto(m),
                              ),
                            ),
                          ),
                        ]);
                      },
                    ),
                  ),
                  if (ClipboardMedia.supported && _photos.isNotEmpty) ...[
                    const SizedBox(height: Space.xs + 2),
                    Text(
                      'Copy a photo with its button, then press $_pasteKeys in the composer. If the site does not take '
                      'pasted photos, use Save media to Downloads and drag them in.',
                      style: context.text.bodySmall?.copyWith(color: nf.textMuted),
                    ),
                  ],
                ],
                if (plan.mediaNote != null) ...[
                  const SizedBox(height: Space.md),
                  _Callout(icon: Icons.info_outline_rounded, color: nf.info, text: plan.mediaNote!),
                ],
                if (extensionStatus != null) ...[
                  const SizedBox(height: Space.md),
                  AnimatedSwitcher(
                    duration: Motion.medium,
                    child: KeyedSubtree(key: ValueKey('${_job?.id} ${_fill?.status}'), child: extensionStatus),
                  ),
                ],
                const SizedBox(height: Space.xl),
                for (var i = 0; i < steps.length; i++) _Step(index: i + 1, text: steps[i]),
                const SizedBox(height: Space.lg),
                ...actions,
                if (extensionHint)
                  Row(children: [
                    Icon(Icons.extension_outlined, size: 16, color: nf.textFaint),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: Text(
                        'Get the NEFORUM browser extension to fill this in for you: Settings > Browser extension.',
                        style: context.text.bodySmall?.copyWith(color: nf.textFaint),
                      ),
                    ),
                    TextButton(
                      onPressed: () => showGuideSheet(context, 'browser-extension', asset: 'browser-extension.md'),
                      style: TextButton.styleFrom(foregroundColor: nf.textMuted, visualDensity: VisualDensity.compact),
                      child: const Text('Guide'),
                    ),
                  ]),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: nf.border),
        footer,
      ],
    );
  }

  Uri? _appUrl() {
    if (Env.isIOS && plan.iosScheme != null) return Uri.tryParse(plan.iosScheme!);
    if (plan.desktopUrl != null) return Uri.tryParse(plan.desktopUrl!);
    return null;
  }

  static List<String> _steps(String instructions) {
    final lines = instructions.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    return [for (final l in lines) l.replaceFirst(RegExp(r'^(\d+[.)]|[-*•])\s*'), '')];
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.index, required this.text});
  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: nf.accentSoft, shape: BoxShape.circle),
            child: Text(
              '$index',
              style: monoStyle(context, size: 12, color: nf.accent, weight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(text.replaceAll('**', ''), style: context.text.bodyMedium),
            ),
          ),
        ],
      ),
    );
  }
}

class _Callout extends StatelessWidget {
  const _Callout({required this.icon, required this.color, required this.text, this.action});
  final IconData icon;
  final Color color;
  final String text;

  /// A button under the text (e.g. "Fill in again").
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withValues(alpha: nf.isDark ? 0.14 : 0.07), nf.surface),
        borderRadius: Radii.rMd,
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: Space.sm + 2),
          Expanded(
            child: action == null
                ? Text(text, style: context.text.bodySmall?.copyWith(color: nf.text))
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(text, style: context.text.bodySmall?.copyWith(color: nf.text)),
                    const SizedBox(height: Space.xs),
                    action!,
                  ]),
          ),
        ],
      ),
    );
  }
}

/// One extra value to paste into its own field (a poll answer, a caption, the
/// tags), with its own copy button.
class _SnippetRow extends StatefulWidget {
  const _SnippetRow({required this.snippet});
  final HandoffSnippet snippet;

  @override
  State<_SnippetRow> createState() => _SnippetRowState();
}

class _SnippetRowState extends State<_SnippetRow> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return NfWell(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.sm, Space.sm),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.snippet.label, style: context.text.labelSmall?.copyWith(color: nf.textFaint)),
            const SizedBox(height: 2),
            SelectableText(widget.snippet.text, style: context.text.bodyMedium),
          ]),
        ),
        ToolButton(
          icon: _copied ? Icons.check_rounded : Icons.copy_rounded,
          tooltip: _copied ? 'Copied' : 'Copy ${widget.snippet.label.toLowerCase()}',
          active: _copied,
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: widget.snippet.text));
            if (mounted) setState(() => _copied = true);
          },
        ),
      ]),
    );
  }
}