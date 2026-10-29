import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../media/audio_plan.dart';
import '../platform/media_library.dart';
import '../state/providers.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Square (or [aspect]) thumbnail of an attachment. Videos show a play glyph
/// and their size; sound files their name, length and size; images with alt
/// text get a small "ALT" tag.
class MediaThumb extends ConsumerWidget {
  const MediaThumb(this.media, {super.key, this.size = 96, this.aspect, this.radius, this.showAltTag = true, this.fit = BoxFit.cover});

  final MediaAttachment media;
  final double size;

  /// Width / height. Null = square.
  final double? aspect;
  final BorderRadius? radius;
  final bool showAltTag;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final storage = ref.watch(servicesProvider).storage;
    final w = aspect == null ? size : size * aspect!;
    final r = radius ?? Radii.circular(size * 0.14);
    final dpr = MediaQuery.devicePixelRatioOf(context);

    final Widget content;
    if (media.isAudio) {
      content = _AudioTile(media: media, size: size);
    } else if (media.isVideo) {
      content = Container(
        color: const Color(0xFF15161B),
        child: Stack(fit: StackFit.expand, children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF2B2F3A), Color(0xFF111217)],
              ),
            ),
          ),
          Center(
            child: Container(
              width: size * 0.36,
              height: size * 0.36,
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), shape: Radii.circleShape),
              child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: size * 0.24),
            ),
          ),
          Positioned(
            left: 6,
            bottom: 5,
            child: Text(formatBytes(media.sizeBytes), style: monoStyle(context, size: 10, color: Colors.white70)),
          ),
        ]),
      );
    } else {
      content = storage.image(media.path, fit: fit, cacheWidth: (w * dpr).round());
    }

    return ClipRRect(
      borderRadius: r,
      child: Container(
        width: w,
        height: size,
        color: nf.surfaceSunken,
        child: Stack(fit: StackFit.expand, children: [
          content,
          if (showAltTag && (media.altText ?? '').isNotEmpty)
            Positioned(
              left: 5,
              top: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.62), borderRadius: Radii.rXs),
                child: const Text('ALT', style: TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
              ),
            ),
          if (media.kind == MediaKind.gif)
            Positioned(
              right: 5,
              top: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.62), borderRadius: Radii.rXs),
                child: const Text('GIF', style: TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
              ),
            ),
        ]),
      ),
    );
  }
}

/// A sound file: its icon, name, length and size, and a "Lossless" badge
/// for a lossless file.
class _AudioTile extends StatelessWidget {
  const _AudioTile({required this.media, required this.size});
  final MediaAttachment media;
  final double size;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final ms = media.durationMs;
    final facts = [if (ms != null) formatAudioDuration(ms), formatBytes(media.sizeBytes)].join(' · ');
    final compact = size < 80;
    return Container(
      color: nf.accentSoft,
      padding: EdgeInsets.all(compact ? 6 : 9),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.graphic_eq_rounded, color: nf.accent, size: size * 0.24),
          const Spacer(),
          if (media.isLosslessAudio && !compact)
            Tooltip(
              message: 'Lossless: ${audioFormatLabel(media)}, sample for sample',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(color: nf.highlight, borderRadius: Radii.rXs),
                child: Text('LOSSLESS', style: TextStyle(color: nf.onHighlight, fontSize: 8.5, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
              ),
            ),
        ]),
        const Spacer(),
        if (!compact)
          Text(
            media.fileName ?? audioFormatLabel(media),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.text.labelSmall?.copyWith(color: nf.text, fontWeight: FontWeight.w600, height: 1.2),
          ),
        Text(facts, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: compact ? 9 : 10, color: nf.textMuted)),
      ]),
    );
  }
}
