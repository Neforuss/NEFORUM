import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'media.dart';
import 'platform_descriptor.dart';

/// How a photo that breaks a platform's shape rule is made to fit.
enum PhotoFitMode {
  /// Borders are added (filled with a soft blur of the photo): nothing is cut.
  pad,

  /// Borders are added, filled with the photo's dominant colours flowing
  /// from its edges (like Instagram stories): nothing is cut.
  color,

  /// The photo is cut to the nearest shape the platform takes, around its
  /// centre.
  crop,

  /// Photos are left alone; a photo that breaks a rule stops the post.
  off,
}

/// The photos a platform takes, as rules a photo can be changed to meet:
/// shape, file type, file size and pixel limits. NEFORUM makes a fitted copy
/// of a photo that breaks one ([PhotoFit.problemsOf]) instead of failing the
/// post. GIFs are never changed (they would lose their animation), nor are
/// videos.
@immutable
class PhotoFit {
  const PhotoFit({
    this.minAspect,
    this.maxAspect,
    this.mimeTypes,
    this.maxBytes,
    this.maxPixels,
    this.maxSideSum,
    this.exactSizes,
    this.label = '',
  });

  /// The platform's generic photo rules: file types and size.
  factory PhotoFit.fromRules(MediaRules m) => PhotoFit(
        mimeTypes: m.imageMimeTypes.isEmpty ? null : m.imageMimeTypes,
        maxBytes: m.imageMaxBytes,
      );

  /// Narrowest and widest shape taken, as width / height (Instagram feed:
  /// 0.8 to 1.91).
  final double? minAspect;
  final double? maxAspect;

  /// File types taken; any other becomes a JPEG.
  final Set<String>? mimeTypes;
  final int? maxBytes;

  /// Width x height must stay below this (LinkedIn).
  final int? maxPixels;

  /// Width + height may be at most this (Telegram).
  final int? maxSideSum;

  /// The only pixel sizes taken (Dribbble's API: 800 x 600 or 400 x 300). A
  /// photo of any other size is brought to the shape and then scaled, up or
  /// down, to exactly the first of them.
  final List<({int width, int height})>? exactSizes;

  /// Where the rules come from, for messages ("Instagram feed photos").
  final String label;

  /// Shapes within this much of a limit count as inside it.
  static const double aspectTolerance = 0.005;

  PhotoFit copyWith({
    double? minAspect,
    double? maxAspect,
    Set<String>? mimeTypes,
    int? maxBytes,
    int? maxPixels,
    int? maxSideSum,
    List<({int width, int height})>? exactSizes,
    String? label,
  }) =>
      PhotoFit(
        minAspect: minAspect ?? this.minAspect,
        maxAspect: maxAspect ?? this.maxAspect,
        mimeTypes: mimeTypes ?? this.mimeTypes,
        maxBytes: maxBytes ?? this.maxBytes,
        maxPixels: maxPixels ?? this.maxPixels,
        maxSideSum: maxSideSum ?? this.maxSideSum,
        exactSizes: exactSizes ?? this.exactSizes,
        label: label ?? this.label,
      );

  /// [width] x [height] is one of [exactSizes] (always true without them).
  bool hasExactSize(int width, int height) =>
      exactSizes == null || exactSizes!.any((s) => s.width == width && s.height == height);

  /// Can NEFORUM change [m] at all? Still photos only.
  static bool canFit(MediaAttachment m) => m.kind == MediaKind.image;

  /// What [m] breaks, in words ("its shape (3:4)", "its size"). Empty when it
  /// is fine as it is, or cannot be changed.
  List<FitProblem> problemsOf(MediaAttachment m) {
    if (!canFit(m)) return const [];
    final out = <FitProblem>[];
    final r = m.aspectRatio;
    if (r != null) {
      if (minAspect != null && r < minAspect! - aspectTolerance) out.add(FitProblem.tooTall);
      if (maxAspect != null && r > maxAspect! + aspectTolerance) out.add(FitProblem.tooWide);
    }
    if (mimeTypes != null && !mimeTypes!.contains(m.mimeType)) out.add(FitProblem.fileType);
    if (maxBytes != null && m.sizeBytes > maxBytes!) out.add(FitProblem.fileSize);
    final w = m.width, h = m.height;
    if (w != null && h != null) {
      if (maxPixels != null && w * h >= maxPixels!) out.add(FitProblem.pixels);
      if (maxSideSum != null && w + h > maxSideSum!) out.add(FitProblem.pixels);
      if (!hasExactSize(w, h) && !out.contains(FitProblem.pixels)) out.add(FitProblem.pixels);
    }
    return out;
  }

  /// The pixel size of [m]'s fitted copy with [mode]: the shape brought within
  /// [minAspect]..[maxAspect] (borders added or edges cut), then scaled down
  /// within [maxPixels] and [maxSideSum]. Null when the size is unknown.
  ({int width, int height})? fittedSize(MediaAttachment m, PhotoFitMode mode) {
    final w0 = m.width, h0 = m.height;
    if (w0 == null || h0 == null || w0 <= 0 || h0 <= 0) return null;
    if (exactSizes != null && exactSizes!.isNotEmpty) {
      return hasExactSize(w0, h0) ? (width: w0, height: h0) : exactSizes!.first;
    }
    var w = w0.toDouble(), h = h0.toDouble();
    final r = w / h;
    double? target;
    if (minAspect != null && r < minAspect! - aspectTolerance) target = minAspect;
    if (maxAspect != null && r > maxAspect! + aspectTolerance) target = maxAspect;
    if (target != null && mode != PhotoFitMode.off) {
      final tooTall = r < target;
      if (mode == PhotoFitMode.pad || mode == PhotoFitMode.color) {
        // Borders: keep the photo, widen (too tall) or heighten (too wide).
        if (tooTall) {
          w = h * target;
        } else {
          h = w / target;
        }
      } else {
        // Crop: keep the long side's centre.
        if (tooTall) {
          h = w / target;
        } else {
          w = h * target;
        }
      }
    }
    var scale = 1.0;
    if (maxPixels != null && w * h >= maxPixels!) scale = math.min(scale, math.sqrt((maxPixels! - 1) / (w * h)));
    if (maxSideSum != null && w + h > maxSideSum!) scale = math.min(scale, maxSideSum! / (w + h));
    return (width: math.max(1, (w * scale).floor()), height: math.max(1, (h * scale).floor()));
  }

  /// The file type of the fitted copy: the original's when the platform takes
  /// it (PNG stays PNG), else JPEG.
  String fittedMimeType(MediaAttachment m) => mimeTypes == null || mimeTypes!.contains(m.mimeType) ? m.mimeType : 'image/jpeg';

  /// What the fitted copy of [m] will look like before it is made: its size,
  /// type and (at most) [maxBytes]. The composer checks this stand-in, so a
  /// photo NEFORUM will fit does not show as an error.
  MediaAttachment standIn(MediaAttachment m, PhotoFitMode mode) {
    final size = fittedSize(m, mode);
    return MediaAttachment(
      id: m.id,
      path: m.path,
      mimeType: fittedMimeType(m),
      sizeBytes: maxBytes == null ? m.sizeBytes : math.min(m.sizeBytes, maxBytes!),
      width: size?.width ?? m.width,
      height: size?.height ?? m.height,
      altText: m.altText,
      fileName: m.fileName,
      generated: m.generated,
      derivedFrom: m.id,
    );
  }

  /// Identifies these rules with [mode], so a fitted copy made for them can be
  /// reused (two platforms with the same rules share one copy).
  String keyFor(PhotoFitMode mode) =>
      '${mode.name}|${minAspect ?? ''}|${maxAspect ?? ''}|${(mimeTypes?.toList()?..sort())?.join(',') ?? ''}|${maxBytes ?? ''}|${maxPixels ?? ''}|${maxSideSum ?? ''}'
      '${exactSizes == null ? '' : '|${exactSizes!.map((s) => '${s.width}x${s.height}').join(',')}'}';

  /// "fitted to 4:5 with borders", "made a JPEG", "made smaller": what fitting
  /// does to [m], for the composer.
  String describe(MediaAttachment m, PhotoFitMode mode) {
    final problems = problemsOf(m);
    final parts = <String>[];
    if (problems.contains(FitProblem.tooTall) || problems.contains(FitProblem.tooWide)) {
      final target = problems.contains(FitProblem.tooTall) ? minAspect! : maxAspect!;
      parts.add('${switch (mode) {
        PhotoFitMode.crop => 'cropped',
        PhotoFitMode.color => 'given a colour fill',
        _ => 'given borders',
      }} to ${ratioLabel(target)}');
    }
    if (problems.contains(FitProblem.fileType)) parts.add('made a JPEG');
    final exact = fittedSize(m, mode);
    if (problems.contains(FitProblem.pixels)) {
      parts.add(exactSizes != null && exact != null ? 'resized to ${exact.width} x ${exact.height}' : 'scaled down');
    }
    if (problems.contains(FitProblem.fileSize)) parts.add('made smaller');
    return parts.join(', ');
  }

  /// 0.8 -> "4:5", 1.91 -> "1.91:1", 0.75 -> "3:4".
  static String ratioLabel(double r) {
    for (final (a, b) in const [(1, 1), (4, 5), (5, 4), (3, 4), (4, 3), (2, 3), (3, 2), (9, 16), (16, 9), (1, 2), (2, 1)]) {
      if ((a / b - r).abs() < 0.006) return '$a:$b';
    }
    if (r >= 1) return '${_trim(r)}:1';
    return '1:${_trim(1 / r)}';
  }

  static String _trim(double v) => v.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
}

/// What a photo breaks.
enum FitProblem { tooTall, tooWide, fileType, fileSize, pixels }
