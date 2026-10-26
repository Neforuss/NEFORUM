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
import '../../platform/share_target.dart';
import '../../platform/ui_bridge.dart';
import '../../state/automatic_handoff.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../theme/zoom.dart';
import '../../widgets/badges.dart';
import '../../widgets/buttons.dart';
import '../../widgets/layout.dart';
import '../../widgets/media_thumb.dart';
import '../../widgets/surfaces.dart';
import '../accounts/guide_sheet.dart';

/// Shows the hand-off sheet (bottom sheet on phones, dialog elsewhere).
/// However it closes, the decision carries the note an automatic attempt
/// there left ([HandoffSheet.onHandoffNote]).
Future<HandoffDecision> showHandoffSheet(
  BuildContext context, {
  required HandoffPlan plan,
  required Post post,
  required ConnectedAccount account,
  required PostVariant variant,
}) async {
  String? note;
  final sheet = HandoffSheet(plan: plan, post: post, account: account, variant: variant, onHandoffNote: (n) => note = n);
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
  return (choice: r ?? HandoffChoice.later, note: note);
}

class HandoffSheet extends ConsumerStatefulWidget {
  const HandoffSheet({super.key, required this.plan, required this.post, required this.account, required this.variant, this.onHandoffNote});

  final HandoffPlan plan;
  final Post post;
  final ConnectedAccount account;
  final PostVariant variant;

  /// Called when automatic posting in this sheet ended without a confirmed
  /// post, with what the user should check before posting by hand (Post may
  /// have been pressed). The run keeps it as the target's
  /// [PostTarget.handoffNote], so the hand-off is never posted automatically
  /// again, whether the sheet closes with Later, Skip or a click outside it.
  final ValueChanged<String>? onHandoffNote;

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
  StreamSubscription<String>? _servedSub;

  /// Hand-offs go to the extension: a computer with a paired browser, not
  /// the demo workspace.
  bool get _extensionFills => ref.read(servicesProvider).extensionFillsHandoffs;

  /// The hand-off the extension was given, the page it is for, and what it
  /// reported back.
  BrowserJob? _job;
  Uri? _jobUrl;
  BrowserFillResult? _fill;

  /// The browser program the page was opened in; null for the system's
  /// default browser.
  InstalledBrowser? _openedIn;

  // ---- automatic posting ------------------------------------------------------

  /// How long the sheet waits for the extension to report, before (and
  /// after) its countdown, before it hands the post back to the user.
  static const Duration _automaticWait = Duration(minutes: 2);
  static const Duration _automaticPostingWait = Duration(minutes: 4);

  /// This hand-off is being posted automatically (the page was opened by
  /// itself, the job is marked automatic).
  bool _automatic = false;

  /// Why automatic posting ended without a post: the manual hand-off is up
  /// to the user from here.
  String? _automaticProblem;
  Timer? _automaticTimer;

  /// Automatic posting is under way: the page is the extension's until it
  /// posts or gives up, so nothing else opens or fills it in meanwhile.
  bool get _automaticRunning => _automatic && _automaticProblem == null && _fill?.posted != BrowserPostState.confirmed;

  /// What an earlier automatic attempt left to check on this target (Post
  /// may have been pressed already): it is never posted automatically again.
  String? get _handoffNote => widget.post.targetFor(widget.account.id)?.handoffNote;

  /// The page automatic posting opens: the platform's full composer, else its
  /// prefilled composer link, else its page. Null when this hand-off is not
  /// posted automatically: not a computer, no paired browser, the demo,
  /// automatic posting off for this network, another account of the user's
  /// on it, an earlier attempt left to check, or no page the extension
  /// fills in by itself.
  Future<Uri?> _automaticPage() async {
    if (_handoffNote != null) return null;
    if (!await automaticPostingApplies(ref.read(servicesProvider), widget.account)) return null;
    return automaticHandoffPage(plan);
  }

  Future<void> _startAutomatic() async {
    final url = await _automaticPage();
    if (url == null || !mounted) return;
    setState(() => _automatic = true);
    _waitForExtension(_automaticWait);
    await _openUrl(url, automatic: true);
  }

  /// Hands the post back to the user when the extension has not reported
  /// within [wait].
  void _waitForExtension(Duration wait) {
    _automaticTimer?.cancel();
    _automaticTimer = Timer(wait, () {
      if (!mounted || !_automatic || _fill?.posted == BrowserPostState.confirmed) return;
      final r = _fill;
      if (r != null && r.automatic == BrowserAutomaticState.countdown) {
        // The countdown ran, and nothing came after it: Post may have been pressed.
        _endAutomatic('The NEFORUM extension started posting on ${_hostOf(r)} but did not report back. Check the page; if the post went up, click I posted it.',
            note: automaticHandoffNote(r, _hostOf(r)));
      } else {
        _endAutomatic('The NEFORUM extension did not report back, so nothing was posted automatically. Check the page, or click Fill in again.');
      }
    });
  }

  /// Automatic posting is over without a post: no page posts this job by
  /// itself any more (another tab of the site included), though a post the
  /// user makes from the page still finishes the hand-off. [note]: what the
  /// page was left with (Post may have been pressed), kept with the target
  /// ([HandoffSheet.onHandoffNote]); null when nothing came back from it.
  void _endAutomatic(String problem, {String? note}) {
    _automaticTimer?.cancel();
    final job = _job;
    if (job != null && job.autoPost) _bridge.endAutomaticPosting(job.id);
    if (note != null) widget.onHandoffNote?.call(note);
    if (mounted) setState(() => _automaticProblem = problem);
  }

  /// "youtube.com", or "the page" when the report does not say.
  static String _hostOf(BrowserFillResult r) => bareHost(r.host).isEmpty ? 'the page' : bareHost(r.host);

  /// What the extension reported on an automatic job.
  void _onAutomaticResult(BrowserFillResult r) {
    final host = _hostOf(r);
    final message = r.message == null ? '' : ' ${_sentence(r.message!)}';
    final note = automaticHandoffNote(r, host);
    if (r.posted == BrowserPostState.confirmed) {
      _automaticTimer?.cancel();
      // Perhaps from another page of the site: the page that claimed the job
      // must not post it a second time.
      _bridge.endAutomaticPosting(r.jobId);
    } else if (r.posted == BrowserPostState.pressed) {
      _endAutomatic('Pressed Post on $host, but the page did not close the composer. Check it there; if the post went up, click I posted it.', note: note);
    } else {
      switch (r.automatic) {
        case BrowserAutomaticState.countdown:
          _waitForExtension(_automaticPostingWait);
        case BrowserAutomaticState.stopped:
          _endAutomatic('You stopped automatic posting on $host, so nothing was posted. Finish the post there, then click I posted it.', note: note);
        case BrowserAutomaticState.manual:
          _endAutomatic('Not posted automatically.$message Finish the post on $host, then click I posted it.', note: note);
        case BrowserAutomaticState.none:
          // An extension before 1.1.0 fills the page in but never posts by itself.
          _endAutomatic(
              r.status == BrowserFillStatus.filled
                  ? 'Filled in on $host, but your NEFORUM extension is older than 1.1.0 and does not post by itself. Post it there, or update the extension.'
                  : 'Not posted automatically: not everything was filled in.$message Finish the post on $host, then click I posted it.',
              note: note);
        case BrowserAutomaticState.otherPage:
          // Another page's fill: the page that posts the job reports for itself.
          break;
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _bridge = ref.read(servicesProvider).browserBridge;
    _fillSub = _bridge.results.listen((r) {
      if (!mounted || r.jobId != _job?.id) return;
      // Another page of the site filled the job in (another tab, a reload)
      // while the page that claimed it posts it: only a post made there counts.
      if (_automaticRunning && r.automatic == BrowserAutomaticState.otherPage && r.posted == BrowserPostState.none) return;
      setState(() => _fill = r);
      if (_job!.autoPost && _automaticProblem == null) _onAutomaticResult(r);
      // Posted from the page (with the extension's shortcut, or by itself on
      // an automatic job), and the composer closed: this hand-off is done, so
      // move on (to the next one, if any).
      if (r.posted == BrowserPostState.confirmed) {
        Future<void>.delayed(const Duration(milliseconds: 1600), () {
          if (mounted && _fill?.jobId == r.jobId) Navigator.pop(context, HandoffChoice.posted);
        });
      }
    });
    // The page is still fetching the job or its files: the wait for its
    // first report starts over.
    _servedSub = _bridge.served.listen((id) {
      if (mounted && id == _job?.id && _automaticRunning && _fill == null) _waitForExtension(_automaticWait);
    });
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    // Automatic posting opens the page by itself, once the sheet is up.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_startAutomatic()));
  }

  @override
  void dispose() {
    unawaited(_fillSub?.cancel());
    unawaited(_servedSub?.cancel());
    _automaticTimer?.cancel();
    _lifecycle.dispose();
    // Closed sheet, finished hand-off: the page must not be filled in again.
    final job = _job;
    if (job != null) _bridge.clearJob(job.id);
    super.dispose();
  }

  /// Gives the post to the browser extension, which fills in the composer
  /// at [url] (when a browser is paired and [url] is a web page).
  /// [automatic]: it posts by itself once everything is filled in.
  void _sendToExtension(Uri url, {bool automatic = false}) {
    if (!_extensionFills || !(url.isScheme('http') || url.isScheme('https'))) return;
    final media = ref.read(servicesProvider).media;
    final d = ref.read(registryProvider).descriptor(widget.account.platformId);
    final job = _bridge.createJob(
      platformId: widget.account.platformId,
      platformName: d?.name ?? widget.account.platformId,
      url: url.toString(),
      hosts: browserJobHosts(url, platformId: widget.account.platformId),
      text: _text,
      title: widget.variant.title,
      snippets: plan.snippets,
      media: browserJobMedia(plan.shareFiles, media.read),
      steps: plan.instructions,
      quickPost: ref.read(settingsProvider).browserQuickPost,
      autoPost: automatic,
      details: BrowserJobDetails.fromVariant(widget.variant),
      target: _openedIn?.id,
    );
    if (job == null) return;
    setState(() {
      _job = job;
      _jobUrl = url;
      _fill = null;
    });
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
    final where = _openedIn == null ? '' : ' in ${_openedIn!.name}';
    final post = _job!.quickPost ? 'Check it, then press $_postKeys on the page (or Post).' : 'Check it and press Post.';
    final automatic = _job!.autoPost;
    final problem = r?.posted == BrowserPostState.confirmed ? null : _automaticProblem;
    final (IconData icon, Color color, String text) = problem != null
        ? (Icons.warning_amber_rounded, nf.warning, problem)
        : switch ((r?.status, r?.posted, r?.automatic)) {
            (_, BrowserPostState.confirmed, _) => (Icons.check_circle_rounded, nf.success, 'Posted on $host. Marking this hand-off as done…'),
            (_, BrowserPostState.pressed, _) => (Icons.info_outline_rounded, nf.info, 'Pressed Post on $host, but the page did not close the composer. Check it there; if the post went up, click I posted it.'),
            (null, _, _) => automatic
                ? (Icons.extension_outlined, nf.info, 'Posting automatically: the NEFORUM extension$where is filling this in…')
                : (Icons.extension_outlined, nf.info, 'The NEFORUM extension$where is filling this in…'),
            (_, _, BrowserAutomaticState.countdown) =>
              (Icons.timer_outlined, nf.info, 'Filled in on $host${what.isEmpty ? '' : ': $what'}. The extension posts it in 3 seconds; Stop on the page keeps it unposted.'),
            (BrowserFillStatus.filled, _, _) => (Icons.check_circle_rounded, nf.success, 'Filled in on $host${what.isEmpty ? '' : ': $what'}. $post'),
            (BrowserFillStatus.partial, _, _) => (Icons.warning_amber_rounded, nf.warning, 'Partly filled in on $host${what.isEmpty ? '' : ': $what'}.$message Do the rest with the steps below.'),
            (BrowserFillStatus.failed, _, _) => (Icons.error_outline_rounded, nf.danger, 'The extension could not fill in $host.$message Use the steps below.'),
          };
    return _Callout(
      icon: icon,
      color: color,
      text: text,
      // Not while automatic posting is under way: a second fill could post
      // from a page the extension is about to post from.
      action: _jobUrl == null || _automaticRunning
          ? null
          : TextButton.icon(
              onPressed: () {
                // By hand from here: the new job is not automatic.
                _automaticTimer?.cancel();
                setState(() {
                  _automatic = false;
                  _automaticProblem = null;
                });
                _sendToExtension(_jobUrl!);
              },
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
    if (_text.isNotEmpty) _markCopied(0);
    if (!quiet) showToast(context, 'Text copied. Paste it when the composer opens.', icon: Icons.check_circle_rounded);
  }

  /// Ctrl+V, or ⌘V on a Mac.
  static String get _pasteKeys => Env.isMacOS ? '⌘V' : 'Ctrl+V';

  /// How to paste here: the keys on a computer, Paste in the app on a phone.
  static String get _pasteHow => Env.isMobile ? 'Paste it in the app' : 'Press $_pasteKeys';

  /// Photos that can go on the clipboard (videos are dragged in instead).
  List<MediaAttachment> get _photos => [for (final m in plan.shareFiles) if (m.isImage) m];

  final Set<String> _copiedPhotos = {};

  /// Puts photo [m] on the clipboard for pasting into the composer.
  Future<bool> _copyPhoto(MediaAttachment m, {bool quiet = false}) async {
    final bytes = await ref.read(servicesProvider).media.read(m);
    final ok = await ClipboardMedia.copyImage(bytes, path: m.path);
    if (!mounted) return ok;
    if (ok) {
      setState(() => _copiedPhotos.add(m.id));
      _markCopied(_pasteItems.indexWhere((item) => item.photo == m));
    }
    if (!quiet) {
      showToast(
        context,
        ok
            ? Env.isMobile
                ? 'Photo copied. Paste it in the app.'
                : 'Photo copied. Press $_pasteKeys in the composer.'
            : Env.isMobile
                ? 'Could not copy the photo. Share it instead.'
                : 'Could not copy the photo. Use Save media to Downloads and drag it in.',
        icon: ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
      );
    }
    return ok;
  }

  /// Index into [_pasteItems] of what "Copy next" copies.
  int _next = 0;

  /// Everything there is to paste, in order: the text, the snippets (poll
  /// answers and the like), then each photo (where photos can be copied).
  List<({String label, MediaAttachment? photo, Future<bool> Function({bool quiet}) copy})> get _pasteItems {
    final photos = _photos;
    return [
      if (_text.isNotEmpty) (label: 'Text', photo: null, copy: ({bool quiet = false}) => _copy(quiet: quiet).then((_) => true)),
      for (final s in plan.snippets)
        (
          label: s.label,
          photo: null,
          copy: ({bool quiet = false}) async {
            await Clipboard.setData(ClipboardData(text: s.text));
            if (mounted && !quiet) showToast(context, '${s.label} copied. $_pasteHow.', icon: Icons.check_circle_rounded);
            return true;
          },
        ),
      if (ClipboardMedia.supported)
        for (var i = 0; i < photos.length; i++)
          (
            label: photos.length == 1 ? 'Photo' : 'Photo ${i + 1} of ${photos.length}',
            photo: photos[i],
            copy: ({bool quiet = false}) => _copyPhoto(photos[i], quiet: quiet),
          ),
    ];
  }

  Future<void> _copyNext() async {
    final items = _pasteItems;
    if (items.isEmpty) return;
    final i = _next % items.length;
    await items[i].copy();
    if (mounted) setState(() => _next = i + 1);
    _markCopied(i);
  }

  // ---- advance on return ------------------------------------------------------
  //
  // Where nothing can fill the page in (phones, and computers without a
  // paired browser), the parts of a hand-off are copied one after another:
  // the user copies one, leaves NEFORUM to paste it, and when NEFORUM is in
  // front again the next part is already on the clipboard.

  late final AppLifecycleListener _lifecycle;

  /// Something was copied to paste in another app...
  bool _copiedToPaste = false;

  /// ...and NEFORUM went to the background since.
  bool _away = false;

  /// What is on the clipboard now ("Photo 2 of 3 copied. Paste it.").
  String? _clipboardNote;

  bool get _advancesOnReturn =>
      ref.read(settingsProvider).advanceHandoffOnReturn && (Env.isMobile || (Env.isDesktop && !_extensionFills)) && _pasteItems.length > 1;

  /// The item of [_pasteItems] copied last, by any button; the part copied on
  /// return is the one after it.
  int _lastCopied = -1;

  /// Item [index] of [_pasteItems] was copied to paste somewhere else.
  void _markCopied(int index) {
    if (index < 0) return;
    _copiedToPaste = true;
    _lastCopied = index;
  }

  void _onLifecycle(AppLifecycleState state) {
    if (!mounted || !_advancesOnReturn) return;
    if (state == AppLifecycleState.resumed) {
      if (!_away) return;
      _away = false;
      unawaited(_advance());
    } else if (_copiedToPaste && state != AppLifecycleState.detached) {
      // Window in the background (computer), or another app in front (phone).
      _away = true;
    }
  }

  /// Copies the next part. A photo that cannot be copied is skipped, and the
  /// note says so.
  Future<void> _advance() async {
    final items = _pasteItems;
    final skipped = <String>[];
    for (var index = _lastCopied + 1; index < items.length; index++) {
      final item = items[index];
      final ok = await item.copy(quiet: true);
      if (!mounted) return;
      // "Copy next" follows along.
      setState(() => _next = index + 1);
      _lastCopied = index;
      if (ok) {
        setState(() => _clipboardNote = [for (final s in skipped) '$s could not be copied here, so it was skipped.', '${item.label} copied. $_pasteHow.'].join(' '));
        return;
      }
      skipped.add(item.label);
    }
    final leftOut = _photos.isNotEmpty && !ClipboardMedia.supported;
    setState(() {
      _copiedToPaste = false;
      _clipboardNote = [
        for (final s in skipped) '$s could not be copied here, so it was skipped.',
        'That was the last part: everything has been copied.',
        if (leftOut) 'Photos cannot be copied on this computer: use Save media to Downloads.',
      ].join(' ');
    });
  }

  /// Ctrl+Enter, or ⌘+Enter on a Mac: the extension's Post shortcut.
  static String get _postKeys => Env.isMacOS ? '⌘+Enter' : 'Ctrl+Enter';

  /// The program of the first paired browser (in the user's order) that can
  /// be started, when hand-offs should open there; null for the system's
  /// default browser.
  Future<InstalledBrowser?> _firstChoice(Uri url) async {
    if (!_extensionFills || !ref.read(settingsProvider).browserOpenInFirst) return null;
    if (!(url.isScheme('http') || url.isScheme('https'))) return null;
    return (await _bridge.firstChoice())?.program;
  }

  /// Opens [url] (in the first-choice browser when set) after giving the
  /// extension the job. [automatic]: the job posts by itself.
  Future<void> _openUrl(Uri url, {bool automatic = false}) async {
    await _copy(quiet: true);
    _noteFirstCopy();
    final program = await _firstChoice(url);
    if (!mounted) return;
    // The job first (for the browser it opens in), so the page finds it.
    _openedIn = program;
    _sendToExtension(url, automatic: automatic);
    var ok = program != null && await BrowserBridge.openInBrowser(program.id, url);
    if (!ok) {
      if (program != null && mounted) {
        // That browser would not start: the default one, and any browser fills in.
        _openedIn = null;
        _sendToExtension(url, automatic: automatic);
      }
      ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    }
    if (!mounted) return;
    setState(() => _launched = ok || _launched);
    if (!ok) {
      showToast(context, 'Could not open $url', icon: Icons.error_outline_rounded);
      if (automatic) _endAutomatic('NEFORUM could not open the page, so nothing was posted automatically. Use the steps below.');
    }
  }

  /// After the first copy (Open, Share): says that the next part follows
  /// when the user comes back.
  void _noteFirstCopy() {
    if (!mounted || !_advancesOnReturn || _text.isEmpty || _clipboardNote != null) return;
    setState(() => _clipboardNote = 'Text copied. $_pasteHow, then come back here: the next part is copied for you.');
  }

  Future<void> _share(BuildContext buttonContext) async {
    // Read the anchor before any await: iPad/macOS need it for the popover.
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null ? null : windowRectOf(buttonContext, box);
    await _copy(quiet: true);
    _noteFirstCopy();
    // Android: straight into the network's app (its share sheet when the
    // app is missing), the caption on the clipboard and in the share.
    final package = plan.androidPackage ?? '';
    if (ShareTarget.supported && package.isNotEmpty) {
      final outcome = await ShareTarget.shareToApp(
        package: package,
        files: [for (final m in plan.shareFiles) (path: m.path, mimeType: m.mimeType)],
        text: plan.shareText ?? _text,
      );
      if (outcome != ShareTargetOutcome.unavailable) {
        if (mounted) setState(() => _launched = true);
        return;
      }
    }
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
    // With the extension, the platform's full composer (it fills in files
    // too) instead of a simplified text-only intent page.
    final composer = _extensionFills ? plan.composerUrl : null;
    final steps = _steps(composer != null ? plan.composerInstructions ?? plan.instructions : plan.instructions);
    final appTarget = _appUrl();
    final extensionStatus = _extensionStatus(nf);
    // Listening, nobody paired, and something to open: say the extension
    // exists (the demo gives it nothing to fill in).
    final extensionHint = Env.isDesktop &&
        !ref.read(servicesProvider).demo &&
        _job == null &&
        _bridge.status.value.listening &&
        _bridge.browsers.value.isEmpty &&
        (plan.webIntent != null || appTarget != null);
    // While the extension posts automatically, nothing opens the page again.
    final opens = !_automaticRunning;
    final note = _handoffNote;

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
    if (composer != null) {
      if (opens) addAction(PrimaryAction(label: 'Open $name composer', icon: Icons.open_in_new_rounded, expand: true, onPressed: () => _openUrl(composer)));
    } else if (shareFirst) {
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
    if (composer == null && plan.webIntent != null && opens) {
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
    if (opens && composer == null && appTarget != null && plan.webIntent == null && !shareFirst) {
      addAction(PrimaryAction(label: 'Open $name', icon: Icons.open_in_new_rounded, expand: true, onPressed: () => _openUrl(appTarget)));
    } else if (opens && composer == null && appTarget != null && (plan.webIntent == null || shareFirst)) {
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
                for (var i = 0; i < plan.snippets.length; i++) ...[
                  const SizedBox(height: Space.sm),
                  _SnippetRow(snippet: plan.snippets[i], onCopied: () => _markCopied((_text.isEmpty ? 0 : 1) + i)),
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
                              shape: Radii.circleBorder,
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
                      Env.isMobile
                          ? 'Copy a photo with its button, then paste it in the app (touch and hold the text box, then Paste). '
                              'If the app does not take pasted photos, share them instead.'
                          : 'Copy a photo with its button, then press $_pasteKeys in the composer. If the site does not take '
                              'pasted photos, use Save media to Downloads and drag them in.',
                      style: context.text.bodySmall?.copyWith(color: nf.textMuted),
                    ),
                  ],
                ],
                // The note is about doing it by hand; the extension adds the files itself.
                if (plan.mediaNote != null && composer == null) ...[
                  const SizedBox(height: Space.md),
                  _Callout(icon: Icons.info_outline_rounded, color: nf.info, text: plan.mediaNote!),
                ],
                // An earlier automatic attempt: check the page before posting.
                if (note != null) ...[
                  const SizedBox(height: Space.md),
                  _Callout(icon: Icons.warning_amber_rounded, color: nf.warning, text: note),
                ],
                if (extensionStatus != null) ...[
                  const SizedBox(height: Space.md),
                  AnimatedSwitcher(
                    duration: Motion.medium,
                    child: KeyedSubtree(
                      key: ValueKey('${_job?.id} ${_fill?.status} ${_fill?.automatic} ${_automaticProblem != null}'),
                      child: extensionStatus,
                    ),
                  ),
                ],
                // What is on the clipboard now, when parts are copied in turn.
                if (_clipboardNote != null && _advancesOnReturn) ...[
                  const SizedBox(height: Space.md),
                  _Callout(
                    icon: Icons.content_paste_go_rounded,
                    color: nf.info,
                    text: _clipboardNote!,
                    action: _lastCopied + 1 < pasteItems.length
                        ? TextButton.icon(
                            onPressed: () => unawaited(_advance()),
                            icon: const Icon(Icons.skip_next_rounded, size: 16),
                            label: Text('Copy next: ${pasteItems[_lastCopied + 1].label}'),
                          )
                        : null,
                  ),
                ],
                const SizedBox(height: Space.xl),
                for (var i = 0; i < steps.length; i++) _Step(index: i + 1, text: steps[i]),
                const SizedBox(height: Space.lg),
                ...actions,
                // Where parts are copied in turn: the switch for it, at hand
                // (phones have no Browser extension settings).
                if ((Env.isMobile || (Env.isDesktop && !_extensionFills)) && pasteItems.length > 1)
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text('Copy the next part when I come back', style: context.text.bodyMedium),
                    value: ref.watch(settingsProvider).advanceHandoffOnReturn,
                    onChanged: (v) {
                      ref.read(settingsProvider.notifier).update((x) => x.copyWith(advanceHandoffOnReturn: v));
                      if (!v) setState(() => _clipboardNote = null);
                    },
                  ),
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
            decoration: BoxDecoration(color: nf.accentSoft, shape: Radii.circleShape),
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
  const _SnippetRow({required this.snippet, this.onCopied});
  final HandoffSnippet snippet;

  /// Called after the copy button put the value on the clipboard.
  final VoidCallback? onCopied;

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
            if (!mounted) return;
            setState(() => _copied = true);
            widget.onCopied?.call();
          },
        ),
      ]),
    );
  }
}