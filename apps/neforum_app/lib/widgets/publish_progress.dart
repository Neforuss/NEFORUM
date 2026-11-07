import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../state/providers.dart';
import '../state/publish_progress_view.dart';
import '../theme/tokens.dart';

const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

/// A run's figure: the number, "Posted to 2 of 5" beside it, and the bar. The
/// sheet, Activity and the post's page all show this one.
class PostProgressFigure extends StatelessWidget {
  const PostProgressFigure(this.progress, {super.key});

  /// The bar, for tests.
  static const Key barKey = ValueKey('post-progress-bar');

  final PostProgress progress;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final percent = percentLabel(progress.permille);
    final posted = postedLabel(progress);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        ExcludeSemantics(child: Text(percent, style: context.text.titleSmall?.copyWith(fontFeatures: _tabular))),
        const SizedBox(width: Space.sm),
        Expanded(
          child: ExcludeSemantics(
            child: Text(posted, textAlign: TextAlign.end, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: nf.textMuted)),
          ),
        ),
      ]),
      const SizedBox(height: Space.xs),
      ClipRRect(
        borderRadius: Radii.rPill,
        child: LinearProgressIndicator(
          key: barKey,
          value: progress.permille / 1000,
          minHeight: 5,
          semanticsLabel: 'Post progress, ${posted.toLowerCase()}',
          // A progress bar's value must be a plain number.
          semanticsValue: '${progress.permille ~/ 10}',
        ),
      ),
    ]);
  }
}

/// A run with no figure yet: it is still getting ready, and no number would be
/// true.
class PublishGettingReady extends StatelessWidget {
  const PublishGettingReady({super.key});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: Radii.rPill,
        child: const LinearProgressIndicator(key: PostProgressFigure.barKey, minHeight: 5, semanticsLabel: kGettingReady),
      );
}

/// What one network is doing: the stage line with its elapsed time, and its bar.
/// While a wait goes on the time moves and nothing else does.
class TargetProgressLine extends ConsumerStatefulWidget {
  const TargetProgressLine(this.target, {super.key, this.reportedAt});

  /// The target's bar, for tests.
  static Key barKey(String accountId) => ValueKey('target-progress-bar-$accountId');

  final TargetProgress target;

  /// When the figures were worked out.
  final DateTime? reportedAt;

  @override
  ConsumerState<TargetProgressLine> createState() => _TargetProgressLineState();
}

class _TargetProgressLineState extends ConsumerState<TargetProgressLine> {
  Timer? _tick;

  bool get _hasTime {
    final stage = widget.target.stage;
    return stage != null && stage != ProgressStage.handingOff;
  }

  void _sync() {
    if (_hasTime) {
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(TargetProgressLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final t = widget.target;
    final view = targetRowView(t, ref.read(publishClockProvider)(), reportedAt: widget.reportedAt);
    final bar = view.bar;
    // A progress bar's value must be a plain number.
    final figure = view.percent?.replaceAll('%', '');
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (view.activity) ...[
          Padding(
            padding: const EdgeInsets.only(top: 3, right: Space.xs + 2),
            child: ExcludeSemantics(child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: nf.accent))),
          ),
        ],
        Expanded(
          child: Text(view.line, maxLines: 3, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: nf.textMuted, fontFeatures: _tabular)),
        ),
      ]),
      if (bar != null) ...[
        const SizedBox(height: Space.xs),
        Row(children: [
          Expanded(
            // During a wait the line above says it all: there is no number to read out.
            child: ExcludeSemantics(
              excluding: figure == null,
              child: ClipRRect(
                borderRadius: Radii.rPill,
                child: LinearProgressIndicator(
                  key: TargetProgressLine.barKey(t.accountId),
                  value: bar,
                  minHeight: 3,
                  semanticsLabel: '${t.name} progress',
                  semanticsValue: figure,
                ),
              ),
            ),
          ),
          if (view.percent != null) ...[
            const SizedBox(width: Space.sm),
            ExcludeSemantics(child: Text(view.percent!, style: context.text.bodySmall?.copyWith(color: nf.textMuted, fontFeatures: _tabular))),
          ],
        ]),
      ],
    ]);
  }
}

/// How [post]'s run stands, for Activity and the post's page. A run of this process
/// shows the figure the sheet shows. A run in a background isolate says so, with no
/// number. Anything else shows nothing.
class PublishRunStatus extends ConsumerWidget {
  const PublishRunStatus({super.key, required this.post, this.padding = EdgeInsets.zero});

  final Post post;

  /// Around what it shows, and gone when it shows nothing.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inThisProcess = ref.watch(activePublishingProvider).containsKey(post.id);
    final Widget? shown;
    if (inThisProcess) {
      final live = ref.watch(publishProgressOfProvider(post.id));
      shown = live == null || live.total == 0
          ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(kGettingReady, style: context.text.bodySmall),
              const SizedBox(height: Space.xs),
              const PublishGettingReady(),
            ])
          : PostProgressFigure(live);
    } else if (post.status == PostStatus.publishing) {
      return _BackgroundRunNote(postId: post.id, padding: padding);
    } else {
      shown = null;
    }
    return shown == null ? const SizedBox.shrink() : Padding(padding: padding, child: shown);
  }
}

/// Says a background isolate has [postId]'s run, for as long as its journal entry
/// shows a recent heartbeat. Read from the file: nothing else crosses over.
class _BackgroundRunNote extends ConsumerStatefulWidget {
  const _BackgroundRunNote({required this.postId, required this.padding});
  final String postId;
  final EdgeInsets padding;

  @override
  ConsumerState<_BackgroundRunNote> createState() => _BackgroundRunNoteState();
}

class _BackgroundRunNoteState extends ConsumerState<_BackgroundRunNote> {
  Timer? _timer;
  bool _inBackground = false;

  Future<void> _check() async {
    final journal = ref.read(publishJournalProvider);
    final now = ref.read(publishClockProvider)();
    final entries = await journal.entries();
    if (!mounted) return;
    final found = isBackgroundRun(entries[widget.postId], journal, now);
    if (found != _inBackground) setState(() => _inBackground = found);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_check());
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(_check()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_inBackground) return const SizedBox.shrink();
    return Padding(padding: widget.padding, child: Text(kPostingInBackground, style: context.text.bodySmall));
  }
}
