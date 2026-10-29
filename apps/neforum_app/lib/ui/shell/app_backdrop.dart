import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../platform/background_images.dart';
import '../../theme/backdrop.dart';
import '../../theme/tokens.dart';

/// A background picture ready to paint: decoded for the window, blurred
/// once, with colors picked from it for the legibility check.
class PreparedBackdrop {
  PreparedBackdrop._(this.image, this.samples);

  /// What is painted, already blurred.
  final ui.Image image;

  /// RGBA bytes of pixels picked all over [image]: the nearest pixel at each
  /// point of a small grid, not an average, so the light and dark extremes
  /// text has to read on are kept.
  final Uint8List samples;

  void dispose() => image.dispose();
}

/// Decodes the picture in [bytes] just large enough to cover [target]
/// (physical pixels, never larger than the picture itself), blurs it by
/// [blurSigma] (physical pixels on screen) once, and samples its colors.
///
/// A strong blur removes the detail a full-size decode would hold, so then
/// it decodes at half the size (a quarter of the memory) and blurs half as
/// much: the same picture on screen.
Future<PreparedBackdrop> prepareBackdrop(Uint8List bytes, {required Size target, required double blurSigma}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final ui.Image decoded;
  final double sigma;
  try {
    final cover = math.max(target.width / descriptor.width, target.height / descriptor.height);
    final reduce = blurSigma >= 16 ? 0.5 : 1.0;
    final scale = math.min(1.0, cover * reduce);
    final width = math.max(1, (descriptor.width * scale).round());
    final height = math.max(1, (descriptor.height * scale).round());
    final codec = await descriptor.instantiateCodec(targetWidth: width, targetHeight: height);
    try {
      decoded = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
    // Screen pixels per decoded pixel: cover / scale.
    sigma = blurSigma * scale / cover;
  } finally {
    descriptor.dispose();
    buffer.dispose();
  }

  var shown = decoded;
  if (sigma >= 0.5) {
    final recorder = ui.PictureRecorder();
    final bounds = Rect.fromLTWH(0, 0, decoded.width.toDouble(), decoded.height.toDouble());
    Canvas(recorder)
      ..saveLayer(bounds, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma))
      ..drawImage(decoded, Offset.zero, Paint())
      ..restore();
    final picture = recorder.endRecording();
    try {
      shown = await picture.toImage(decoded.width, decoded.height);
    } finally {
      picture.dispose();
      decoded.dispose();
    }
  }

  try {
    return PreparedBackdrop._(shown, await _sample(shown));
  } on Object {
    shown.dispose();
    rethrow;
  }
}

/// Whether [bytes] are a picture this device can decode.
Future<bool> isDecodablePicture(Uint8List bytes) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final ok = descriptor.width > 0 && descriptor.height > 0;
      descriptor.dispose();
      return ok;
    } finally {
      buffer.dispose();
    }
  } on Object {
    return false;
  }
}

/// Nearest-pixel samples of [image] on a grid up to 160 wide.
Future<Uint8List> _sample(ui.Image image) async {
  final width = math.min(160, image.width);
  final height = math.max(1, (image.height * width / image.width).round());
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..filterQuality = FilterQuality.none,
  );
  final picture = recorder.endRecording();
  final grid = await picture.toImage(width, height);
  picture.dispose();
  try {
    final data = await grid.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    return data == null ? Uint8List(0) : data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    grid.dispose();
  }
}

/// sRGB channel (0 to 255) to linear light, as in [Color.computeLuminance].
final Float64List _linear = Float64List.fromList([
  for (var i = 0; i < 256; i++) i / 255 <= 0.04045 ? i / 255 / 12.92 : math.pow((i / 255 + 0.055) / 1.055, 2.4).toDouble(),
]);

/// The least opacity of a [scrim] laid over a picture at which every color
/// in [foregrounds] keeps a contrast of [ratio] with what is under it, on
/// all but the most extreme 0.5% of [samples] (RGBA bytes, see
/// [PreparedBackdrop.samples]).
///
/// A foreground that has less than [ratio] on the plain [scrim] (a custom
/// accent can) is held to nearly what it has there instead, so it never asks
/// for more than covering the picture completely.
double legibleScrimOpacity(Uint8List samples, Color scrim, List<Color> foregrounds, {double ratio = 4.5}) {
  final count = samples.length ~/ 4;
  if (count == 0) return 0;
  final sr = (scrim.r * 255).round(), sg = (scrim.g * 255).round(), sb = (scrim.b * 255).round();
  final targets = [
    for (final f in foregrounds) (luminance: f.computeLuminance(), ratio: math.min(ratio, contrastRatio(f.withValues(alpha: 1), scrim.withValues(alpha: 1)) * 0.97)),
  ];
  final allowed = count ~/ 200;

  bool legible(double opacity) {
    var failures = 0;
    for (var i = 0; i < samples.length; i += 4) {
      int mix(int top, int under) => (top * opacity + under * (1 - opacity)).round();
      final l = 0.2126 * _linear[mix(sr, samples[i])] + 0.7152 * _linear[mix(sg, samples[i + 1])] + 0.0722 * _linear[mix(sb, samples[i + 2])];
      for (final t in targets) {
        final c = (math.max(l, t.luminance) + 0.05) / (math.min(l, t.luminance) + 0.05);
        if (c < t.ratio) {
          if (++failures > allowed) return false;
          break;
        }
      }
    }
    return true;
  }

  if (legible(0)) return 0;
  var low = 0.0, high = 1.0;
  for (var step = 0; step < 10; step++) {
    final mid = (low + high) / 2;
    if (legible(mid)) {
      high = mid;
    } else {
      low = mid;
    }
  }
  return high;
}

/// The physical window size rounded up to a step of 256, so resizing a
/// window a little does not decode the picture again.
Size _bucket(Size physical) => Size((physical.width / 256).ceil() * 256.0, (physical.height / 256).ceil() * 256.0);

bool _covers(Size? bucket, Size need) => bucket != null && bucket.width >= need.width && bucket.height >= need.height;

typedef _BackdropKey = ({String path, double blur, double devicePixelRatio});

/// The last picture prepared, kept for the next [AppBackdrop] (a new
/// workspace, a rebuilt shell). One only: memory stays low.
class _BackdropCache {
  static ({_BackdropKey key, Size bucket, PreparedBackdrop backdrop})? _entry;

  static PreparedBackdrop? lookup(_BackdropKey key, Size need) {
    final e = _entry;
    return e != null && e.key == key && _covers(e.bucket, need) ? e.backdrop : null;
  }

  static void store(_BackdropKey key, Size bucket, PreparedBackdrop backdrop) {
    _entry?.backdrop.dispose();
    _entry = (key: key, bucket: bucket, backdrop: backdrop);
  }

  static void evict() {
    _entry?.backdrop.dispose();
    _entry = null;
  }
}

/// Paints the background picture (Settings > Appearance > Background)
/// behind [child]: the shell's navigation and pages. Pages leave their own
/// background transparent when [activeOf] is true; cards and other surfaces
/// keep their colors.
///
/// Over the picture lies the theme's background color at [dim] or more: as
/// much as the theme's text and muted text need to keep WCAG AA contrast
/// (4.5:1; 7:1 with the system's high contrast setting) on the lightest or
/// darkest parts of the picture, so light and dark themes both stay
/// readable over any picture. Text in other colors right on the page uses
/// `legibleOverBackdrop`.
///
/// The picture is decoded once at the window's size and blurred once (by
/// [blur], logical pixels), not every frame.
class AppBackdrop extends StatefulWidget {
  const AppBackdrop({super.key, required this.imagePath, this.blur = 0, this.dim = 0, required this.child});

  /// The picture, or null for none.
  final String? imagePath;
  final double blur;

  /// Least opacity of the theme's background color over the picture, 0 to 1.
  final double dim;
  final Widget child;

  /// Whether a background picture is behind [context] ([BackdropScope]).
  static bool activeOf(BuildContext context) => BackdropScope.activeOf(context);

  /// Prepares the picture at [path] for a window of [physicalSize] and keeps
  /// it for the [AppBackdrop] that shows it next. Tests call it outside the
  /// fake clock, where decoding can finish.
  @visibleForTesting
  static Future<void> precache(String path, {required double blur, required Size physicalSize, required double devicePixelRatio}) async {
    final bytes = await readBackgroundImage(path);
    if (bytes == null) throw StateError('No picture at $path');
    final bucket = _bucket(physicalSize);
    final backdrop = await prepareBackdrop(bytes, target: bucket, blurSigma: blur * devicePixelRatio);
    _BackdropCache.store((path: path, blur: blur, devicePixelRatio: devicePixelRatio), bucket, backdrop);
  }

  @override
  State<AppBackdrop> createState() => _AppBackdropState();
}

class _AppBackdropState extends State<AppBackdrop> {
  /// This widget's own clone of the shown picture.
  ui.Image? _image;
  Uint8List? _samples;
  _BackdropKey? _shownKey;
  Size? _shownBucket;

  _BackdropKey? _pendingKey;
  Size? _pendingBucket;
  int _generation = 0;
  Timer? _grow;

  /// The last legibility result, for its inputs.
  (Uint8List, Color, List<Color>, double)? _scrimInputs;
  double _scrimOpacity = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    MediaQuery.sizeOf(context); // Rebuild (and maybe decode larger) when the window grows.
    _sync();
  }

  @override
  void didUpdateWidget(AppBackdrop old) {
    super.didUpdateWidget(old);
    if (old.imagePath != widget.imagePath || old.blur != widget.blur) _sync();
  }

  @override
  void dispose() {
    _grow?.cancel();
    _generation++;
    _image?.dispose();
    super.dispose();
  }

  void _sync() {
    final path = widget.imagePath;
    if (path == null) {
      _grow?.cancel();
      _generation++;
      _pendingKey = null;
      _show(null, null, null);
      _BackdropCache.evict();
      return;
    }
    final view = View.of(context);
    if (view.physicalSize.isEmpty) return;
    final need = _bucket(view.physicalSize);
    final key = (path: path, blur: widget.blur, devicePixelRatio: view.devicePixelRatio);
    if (_shownKey == key && _covers(_shownBucket, need)) return;
    if (_pendingKey == key && _covers(_pendingBucket, need)) return;
    final cached = _BackdropCache.lookup(key, need);
    if (cached != null) {
      _grow?.cancel();
      _generation++;
      _pendingKey = null;
      _show(key, need, cached);
      return;
    }
    _grow?.cancel();
    if (_shownKey == key) {
      // The same picture in a window that grew: wait until resizing stops.
      _grow = Timer(const Duration(milliseconds: 300), () => _prepare(key, need));
    } else {
      _prepare(key, need);
    }
  }

  void _show(_BackdropKey? key, Size? bucket, PreparedBackdrop? backdrop) {
    _image?.dispose();
    _image = backdrop?.image.clone();
    _samples = backdrop?.samples;
    _shownKey = key;
    _shownBucket = bucket;
  }

  Future<void> _prepare(_BackdropKey key, Size bucket) async {
    final generation = ++_generation;
    _pendingKey = key;
    _pendingBucket = bucket;
    try {
      final bytes = await readBackgroundImage(key.path);
      if (bytes == null) throw StateError('The background picture is gone');
      final backdrop = await prepareBackdrop(bytes, target: bucket, blurSigma: key.blur * key.devicePixelRatio);
      if (!mounted || generation != _generation) {
        backdrop.dispose();
        return;
      }
      _BackdropCache.store(key, bucket, backdrop);
      _pendingKey = null;
      setState(() => _show(key, bucket, backdrop));
    } on Object catch (e) {
      debugPrint('Could not show the background picture: $e');
      if (!mounted || generation != _generation) return;
      _pendingKey = null;
      // The theme's own background then; the next change tries again.
      setState(() => _show(key, bucket, null));
    }
  }

  double _legibleOpacity(Uint8List samples, NfColors nf, double ratio) {
    // Other colors of text right on the page follow these two
    // (legibleOverBackdrop); text on cards is on the cards' own color.
    final foregrounds = [nf.text, nf.textMuted];
    final inputs = _scrimInputs;
    if (inputs != null && identical(inputs.$1, samples) && inputs.$2 == nf.bg && listEquals(inputs.$3, foregrounds) && inputs.$4 == ratio) {
      return _scrimOpacity;
    }
    _scrimInputs = (samples, nf.bg, foregrounds, ratio);
    return _scrimOpacity = legibleScrimOpacity(samples, nf.bg, foregrounds, ratio: ratio);
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final active = widget.imagePath != null;
    final image = _image;
    final samples = _samples;
    Widget? layer;
    if (active) {
      final ratio = MediaQuery.highContrastOf(context) ? 7.0 : 4.5;
      final scrim = samples == null ? 1.0 : math.max(widget.dim, _legibleOpacity(samples, nf, ratio));
      layer = RepaintBoundary(
        child: ColoredBox(
          color: nf.bg,
          child: AnimatedOpacity(
            opacity: image == null ? 0 : 1,
            duration: context.motion(Motion.slow),
            curve: Motion.standard,
            child: image == null
                ? const SizedBox.expand()
                : Stack(fit: StackFit.expand, children: [
                    RawImage(image: image, fit: BoxFit.cover, filterQuality: FilterQuality.medium),
                    ColoredBox(color: nf.bg.withValues(alpha: scrim)),
                  ]),
          ),
        ),
      );
    }
    // The same two children with or without a picture, so the pages under
    // it keep their state when it is turned on or off.
    return BackdropScope(
      active: active,
      child: Stack(fit: StackFit.expand, children: [
        Positioned.fill(child: layer ?? const SizedBox.shrink()),
        widget.child,
      ]),
    );
  }
}
