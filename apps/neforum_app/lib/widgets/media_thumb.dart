import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../platform/media_library.dart';
import '../state/providers.dart';
import '../state/video_frames.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Square (or [aspect]) thumbnail of an attachment. Videos show a frame from
/// somewhere in them where this device can read one, with a play glyph and
/// their size; images with alt text get a small "ALT" tag.
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
    if (media.isVideo) {
      // 1.3: video. A frame from somewhere in the video, for this session
      // only; the gradient until it arrives, or when there is none.
      final frame = ref.watch(videoPreviewFrameProvider((mediaId: media.id, path: media.path))).value;
      content = Container(
        color: const Color(0xFF15161B),
        child: Stack(fit: StackFit.expand, children: [
          if (frame == null)
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF2B2F3A), Color(0xFF111217)],
                ),
              ),
            )
          else ...[
            // At most kPreviewFrameMaxSide pixels: decoded as it is.
            Image.memory(frame.png, fit: fit, gaplessPlayback: true),
            // Keeps the glyph and the size readable on a bright frame.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black.withValues(alpha: 0.08), Colors.black.withValues(alpha: 0.42)],
                ),
              ),
            ),
          ],
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
