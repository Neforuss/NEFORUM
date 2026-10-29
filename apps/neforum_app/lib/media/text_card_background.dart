import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:neforum_core/neforum_core.dart' show MediaAttachment;

import 'photo_composite.dart';
import 'photo_pixels.dart';

/// Colour of a card's words over a background photo.
enum TextCardTextColor {
  /// White over a dark photo, black over a light one.
  automatic('Automatic'),
  white('White'),
  black('Black');

  const TextCardTextColor(this.label);
  final String label;
}

/// How a card's background photo fills the card.
enum TextCardBackgroundFit {
  /// Scaled to fill the whole card, cut to fit.
  cover('Fill the card'),

  /// The whole photo, on the card's own colour where it leaves room.
  contain('Whole photo');

  const TextCardBackgroundFit(this.label);
  final String label;
}

/// Where a card's words sit, top to bottom, in the room the card leaves them.
enum TextCardTextPosition {
  top('Top'),
  center('Middle'),
  bottom('Bottom');

  const TextCardTextPosition(this.label);
  final String label;

  /// 0 for the top, 0.5 for the middle, 1 for the bottom.
  double get anchor => switch (this) { top => 0, center => 0.5, bottom => 1 };
}

/// A photo behind a text card's words: one of the post's photos or one picked
/// only for the card. It is placed (cover or contain, panned, zoomed, turned,
/// mirrored), adjusted (brightness, contrast, saturation, black and white,
/// a colour tint), blurred, dimmed, and can have a gradient and a vignette
/// laid over it. The photo is only used inside the card; it is not posted by
/// itself.
///
/// Kept as JSON in the composer ([toJson], with the photo) and in each card's
/// render parameters ([toRenderParameters], the photo by id). Only choices
/// that differ from their defaults are written, so cards made before 1.3
/// (photo, blur, dimming, text colour, box) keep parameters equal to what
/// they are rendered with now, and are not made again.
@immutable
class TextCardBackground {
  const TextCardBackground({
    required this.photo,
    this.blur = 12,
    this.dimming = 0.35,
    this.textColor = TextCardTextColor.automatic,
    this.textBox = false,
    this.offsetX = 0,
    this.offsetY = 0,
    this.zoom = 1,
    this.fit = TextCardBackgroundFit.cover,
    this.quarterTurns = 0,
    this.flipHorizontal = false,
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.blackAndWhite = false,
    this.tintColor = defaultTintColor,
    this.tintStrength = 0,
    this.gradientStart = defaultGradientStart,
    this.gradientEnd = defaultGradientEnd,
    this.gradientAngle = 0,
    this.gradientStrength = 0,
    this.vignette = 0,
    this.textPosition = TextCardTextPosition.center,
  });

  /// Null when [j] holds no usable photo.
  static TextCardBackground? tryParse(Map<String, dynamic>? j) {
    final raw = j?['photo'];
    if (j == null || raw is! Map) return null;
    try {
      return _read(j, MediaAttachment.fromJson(Map<String, dynamic>.from(raw)));
    } on Object {
      return null;
    }
  }

  /// The background described by a card's render parameters, with its photo
  /// looked up by id.
  static TextCardBackground? fromRenderParameters(Map<String, dynamic>? p, MediaAttachment? Function(String id) photoOf) {
    final id = p?['mediaId'];
    final photo = id is String ? photoOf(id) : null;
    if (p == null || photo == null) return null;
    return _read(p, photo);
  }

  static TextCardBackground _read(Map<String, dynamic> j, MediaAttachment photo) => TextCardBackground(
        photo: photo,
        blur: _number(j['blur'], 0, maxBlur) ?? 12,
        dimming: _number(j['dimming'], 0, maxDimming) ?? 0.35,
        textColor: TextCardTextColor.values.asNameMap()[j['textColor']] ?? TextCardTextColor.automatic,
        textBox: j['textBox'] == true,
        offsetX: _number(j['offsetX'], -1, 1) ?? 0,
        offsetY: _number(j['offsetY'], -1, 1) ?? 0,
        zoom: _number(j['zoom'], 1, maxZoom) ?? 1,
        fit: TextCardBackgroundFit.values.asNameMap()[j['fit']] ?? TextCardBackgroundFit.cover,
        quarterTurns: j['quarterTurns'] is int ? (j['quarterTurns'] as int) % 4 : 0,
        flipHorizontal: j['flipHorizontal'] == true,
        brightness: _number(j['brightness'], -1, 1) ?? 0,
        contrast: _number(j['contrast'], -1, 1) ?? 0,
        saturation: _number(j['saturation'], -1, 1) ?? 0,
        blackAndWhite: j['blackAndWhite'] == true,
        tintColor: _color(j['tintColor']) ?? defaultTintColor,
        tintStrength: _number(j['tintStrength'], 0, 1) ?? 0,
        gradientStart: _color(j['gradientStart']) ?? defaultGradientStart,
        gradientEnd: _color(j['gradientEnd']) ?? defaultGradientEnd,
        gradientAngle: _number(j['gradientAngle'], 0, 360) ?? 0,
        gradientStrength: _number(j['gradientStrength'], 0, 1) ?? 0,
        vignette: _number(j['vignette'], 0, 1) ?? 0,
        textPosition: TextCardTextPosition.values.asNameMap()[j['textPosition']] ?? TextCardTextPosition.center,
      );

  static double? _number(Object? v, double min, double max) => v is num && v.isFinite ? v.toDouble().clamp(min, max) : null;
  static int? _color(Object? v) => v is int ? v | 0xFF000000 : null;

  static const double maxBlur = 30;
  static const double maxDimming = 0.8;
  static const double maxZoom = 4;
  static const int defaultTintColor = 0xFF7D00FF;
  static const int defaultGradientStart = 0xFF7D00FF;
  static const int defaultGradientEnd = 0xFF000000;

  final MediaAttachment photo;

  /// Blur strength (Gaussian sigma) in pixels at 1080 wide, 0 to 30.
  final double blur;

  /// Black laid over the photo, 0 to 0.8.
  final double dimming;
  final TextCardTextColor textColor;

  /// A soft box behind the words, for busy photos.
  final bool textBox;

  /// The photo's focal point, -1 (left, top) to 1 (right, bottom); see
  /// [photoPlacement].
  final double offsetX;
  final double offsetY;

  /// 1 (the photo as [fit] places it) to [maxZoom].
  final double zoom;
  final TextCardBackgroundFit fit;

  /// Clockwise quarter turns of the photo, 0 to 3.
  final int quarterTurns;

  /// Mirrors the photo left to right (after turning it).
  final bool flipHorizontal;

  /// Each -1 to 1; 0 leaves the photo as it is.
  final double brightness;
  final double contrast;
  final double saturation;
  final bool blackAndWhite;

  /// ARGB of the tint and how strongly it colours the photo, 0 to 1.
  final int tintColor;
  final double tintStrength;

  /// ARGB at the gradient's start and end, its angle (clockwise degrees, 0
  /// runs from the top down) and how opaque it is, 0 to 1.
  final int gradientStart;
  final int gradientEnd;
  final double gradientAngle;
  final double gradientStrength;

  /// Darkening towards the corners, 0 to 1.
  final double vignette;

  /// Where the words sit, top to bottom.
  final TextCardTextPosition textPosition;

  bool get contain => fit == TextCardBackgroundFit.contain;

  /// The photo is turned or mirrored.
  bool get oriented => quarterTurns % 4 != 0 || flipHorizontal;

  /// The colour adjustments as one 4 x 5 matrix (row-major, offsets in 0 to
  /// 255, as `ColorFilter.matrix` takes it): saturation (none for black and
  /// white), then contrast, brightness and the tint. Null when they leave the
  /// photo as it is.
  List<double>? get colorMatrix {
    if (brightness == 0 && contrast == 0 && saturation == 0 && !blackAndWhite && tintStrength == 0) return null;
    var m = _identity;
    if (blackAndWhite || saturation != 0) {
      final s = blackAndWhite ? 0.0 : 1 + saturation;
      const lr = 0.2126, lg = 0.7152, lb = 0.0722;
      m = _multiply([
        lr * (1 - s) + s, lg * (1 - s), lb * (1 - s), 0, 0,
        lr * (1 - s), lg * (1 - s) + s, lb * (1 - s), 0, 0,
        lr * (1 - s), lg * (1 - s), lb * (1 - s) + s, 0, 0,
        0, 0, 0, 1, 0,
      ], m);
    }
    if (contrast != 0) {
      final k = 1 + contrast;
      final o = 128 * (1 - k);
      m = _multiply([k, 0, 0, 0, o, 0, k, 0, 0, o, 0, 0, k, 0, o, 0, 0, 0, 1, 0], m);
    }
    if (brightness != 0) {
      final o = 128 * brightness;
      m = _multiply([1, 0, 0, 0, o, 0, 1, 0, 0, o, 0, 0, 1, 0, o, 0, 0, 0, 1, 0], m);
    }
    if (tintStrength > 0) {
      // Multiplies the photo by the colour: shadows stay dark, light parts
      // take the colour.
      double channel(int shift) => 1 - tintStrength + tintStrength * (tintColor >> shift & 0xFF) / 255;
      m = _multiply([channel(16), 0, 0, 0, 0, 0, channel(8), 0, 0, 0, 0, 0, channel(0), 0, 0, 0, 0, 0, 1, 0], m);
    }
    return m;
  }

  static const List<double> _identity = [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];

  /// [a] after [b]: both 4 x 5 colour matrices.
  static List<double> _multiply(List<double> a, List<double> b) => [
        for (var r = 0; r < 4; r++)
          for (var c = 0; c < 5; c++)
            a[r * 5] * b[c] + a[r * 5 + 1] * b[5 + c] + a[r * 5 + 2] * b[10 + c] + a[r * 5 + 3] * b[15 + c] + (c == 4 ? a[r * 5 + 4] : 0),
      ];

  /// The gradient's ends as ARGB with [gradientStrength] in their alpha;
  /// null without a gradient.
  (int, int)? get gradientColors {
    if (gradientStrength <= 0) return null;
    int withStrength(int argb) => (((argb >>> 24 & 0xFF) * gradientStrength).round().clamp(0, 255) << 24) | (argb & 0xFFFFFF);
    return (withStrength(gradientStart), withStrength(gradientEnd));
  }

  TextCardBackground copyWith({
    MediaAttachment? photo,
    double? blur,
    double? dimming,
    TextCardTextColor? textColor,
    bool? textBox,
    double? offsetX,
    double? offsetY,
    double? zoom,
    TextCardBackgroundFit? fit,
    int? quarterTurns,
    bool? flipHorizontal,
    double? brightness,
    double? contrast,
    double? saturation,
    bool? blackAndWhite,
    int? tintColor,
    double? tintStrength,
    int? gradientStart,
    int? gradientEnd,
    double? gradientAngle,
    double? gradientStrength,
    double? vignette,
    TextCardTextPosition? textPosition,
  }) =>
      TextCardBackground(
        photo: photo ?? this.photo,
        blur: blur ?? this.blur,
        dimming: dimming ?? this.dimming,
        textColor: textColor ?? this.textColor,
        textBox: textBox ?? this.textBox,
        offsetX: offsetX ?? this.offsetX,
        offsetY: offsetY ?? this.offsetY,
        zoom: zoom ?? this.zoom,
        fit: fit ?? this.fit,
        quarterTurns: (quarterTurns ?? this.quarterTurns) % 4,
        flipHorizontal: flipHorizontal ?? this.flipHorizontal,
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
        blackAndWhite: blackAndWhite ?? this.blackAndWhite,
        tintColor: tintColor ?? this.tintColor,
        tintStrength: tintStrength ?? this.tintStrength,
        gradientStart: gradientStart ?? this.gradientStart,
        gradientEnd: gradientEnd ?? this.gradientEnd,
        gradientAngle: gradientAngle ?? this.gradientAngle,
        gradientStrength: gradientStrength ?? this.gradientStrength,
        vignette: vignette ?? this.vignette,
        textPosition: textPosition ?? this.textPosition,
      );

  /// This background with every 1.3 choice back at its default: placement,
  /// adjustments, overlays and text position. Blur, dimming, text colour and
  /// box are kept.
  TextCardBackground withDefaultEffects() =>
      TextCardBackground(photo: photo, blur: blur, dimming: dimming, textColor: textColor, textBox: textBox);

  /// Every choice, with the photo: the composer keeps colours chosen while
  /// their strength is 0, so turning a tint or gradient on restores them.
  Map<String, dynamic> toJson() => {'photo': photo.toJson(), ..._choices(effectiveOnly: false)};

  /// The choices that change the picture.
  Map<String, dynamic> toRenderParameters() => _choices(effectiveOnly: true);

  Map<String, dynamic> _choices({required bool effectiveOnly}) => {
        'mediaId': photo.id,
        'blur': blur,
        'dimming': dimming,
        'textColor': textColor.name,
        'textBox': textBox,
        // Since 1.3, written only when they differ from the default.
        if (offsetX != 0) 'offsetX': offsetX,
        if (offsetY != 0) 'offsetY': offsetY,
        if (zoom != 1) 'zoom': zoom,
        if (fit != TextCardBackgroundFit.cover) 'fit': fit.name,
        if (quarterTurns % 4 != 0) 'quarterTurns': quarterTurns % 4,
        if (flipHorizontal) 'flipHorizontal': true,
        if (brightness != 0) 'brightness': brightness,
        if (contrast != 0) 'contrast': contrast,
        // Black and white leaves no saturation to change.
        if (saturation != 0 && (!blackAndWhite || !effectiveOnly)) 'saturation': saturation,
        if (blackAndWhite) 'blackAndWhite': true,
        if (tintColor != defaultTintColor && (tintStrength > 0 || !effectiveOnly)) 'tintColor': tintColor,
        if (tintStrength > 0) 'tintStrength': tintStrength,
        if (gradientStart != defaultGradientStart && (gradientStrength > 0 || !effectiveOnly)) 'gradientStart': gradientStart,
        if (gradientEnd != defaultGradientEnd && (gradientStrength > 0 || !effectiveOnly)) 'gradientEnd': gradientEnd,
        if (gradientAngle != 0 && (gradientStrength > 0 || !effectiveOnly)) 'gradientAngle': gradientAngle,
        if (gradientStrength > 0) 'gradientStrength': gradientStrength,
        if (vignette > 0) 'vignette': vignette,
        if (textPosition != TextCardTextPosition.center) 'textPosition': textPosition.name,
      };
}

/// A [TextCardBackground] with its photo decoded: as an engine [image] for a
/// preview on screen, or as [pixels] for a saved card, which is composited on
/// the CPU ([composeTextCard]).
@immutable
class TextCardBackdrop {
  const TextCardBackdrop({this.image, this.pixels, required this.luminance, required this.background})
      : assert(image != null || pixels != null);

  /// For previews on screen only: never drawn into a picture that is read
  /// back (on some Windows PCs that never finished).
  final ui.Image? image;

  /// The photo, upright, for a saved card.
  final PhotoPixels? pixels;

  /// Average brightness of the photo, 0 (black) to 1 (white).
  final double luminance;
  final TextCardBackground background;

  /// Colour of the words: the choice, or for automatic white over a dark
  /// photo and black over a light one (after dimming).
  Color get foreground => switch (background.textColor) {
        TextCardTextColor.white => const Color(0xFFFFFFFF),
        TextCardTextColor.black => const Color(0xFF000000),
        TextCardTextColor.automatic => luminance * (1 - background.dimming) < 0.55 ? const Color(0xFFFFFFFF) : const Color(0xFF000000),
      };

  /// Paints the preview [image] over [frame] the way [composeTextCard] saves
  /// it: placed, turned, adjusted, blurred, dimmed, with the gradient and the
  /// vignette. [unit] is the picture's width / 1080; [cardColor] fills the
  /// room a whole photo ([TextCardBackgroundFit.contain]) leaves. Paints
  /// nothing for a backdrop made for a saved card.
  void paint(Canvas canvas, Rect frame, double unit, {Color cardColor = const Color(0xFF000000)}) {
    final image = this.image;
    if (image == null) return;
    final b = background;
    final turned = b.quarterTurns.isOdd;
    final iw = turned ? image.height : image.width, ih = turned ? image.width : image.height;
    final place = photoPlacement(iw, ih, frame.width, frame.height, zoom: b.zoom, offsetX: b.offsetX, offsetY: b.offsetY, contain: b.contain);
    final scale = place.sw > 0 ? place.dw / place.sw : 1.0;
    // The whole turned photo, of which the frame shows a part.
    final shown = Rect.fromLTWH(frame.left + place.dx - place.sx * scale, frame.top + place.dy - place.sy * scale, iw * scale, ih * scale);
    final sigma = b.blur * unit;
    final matrix = b.colorMatrix;
    canvas.save();
    canvas.clipRect(frame);
    canvas.drawRect(frame, Paint()..color = b.contain ? cardColor : const Color(0xFF000000));
    canvas.save();
    canvas.translate(shown.center.dx, shown.center.dy);
    if (b.flipHorizontal) canvas.scale(-1, 1);
    if (b.quarterTurns % 4 != 0) canvas.rotate(b.quarterTurns * math.pi / 2);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromCenter(center: Offset.zero, width: turned ? shown.height : shown.width, height: turned ? shown.width : shown.height),
      Paint()
        ..filterQuality = FilterQuality.high
        ..colorFilter = matrix == null ? null : ColorFilter.matrix(matrix)
        ..imageFilter = sigma > 0.01 ? ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp) : null,
    );
    canvas.restore();
    if (b.dimming > 0) canvas.drawRect(frame, Paint()..color = Color.fromRGBO(0, 0, 0, b.dimming));
    final gradient = b.gradientColors;
    if (gradient != null) {
      final (start, end) = linearGradientEnds(frame, b.gradientAngle);
      canvas.drawRect(frame, Paint()..shader = ui.Gradient.linear(start, end, [Color(gradient.$1), Color(gradient.$2)]));
    }
    if (b.vignette > 0) {
      final radius = math.sqrt(frame.width * frame.width + frame.height * frame.height) / 2;
      canvas.drawRect(
        frame,
        Paint()
          ..shader = ui.Gradient.radial(frame.center, radius, [const Color(0x00000000), Color.fromRGBO(0, 0, 0, b.vignette)],
              const [kVignetteInnerRadius, 1]),
      );
    }
    canvas.restore();
  }

  void dispose() => image?.dispose();
}

/// Longest side a card's background photo is decoded at: enough for a
/// 1080 x 1920 card, which blurs it anyway.
const int kBackdropMaxSide = 1920;

/// Decodes the photo in [bytes] for a saved card with [background]. Null when
/// it cannot be read.
Future<TextCardBackdrop?> decodeTextCardBackdrop(Uint8List bytes, TextCardBackground background) async {
  final px = await decodePhotoPixels(bytes, maxSide: kBackdropMaxSide);
  if (px == null) return null;
  return TextCardBackdrop(pixels: px, luminance: px.luminance, background: background);
}

/// Everything [composeTextCard] needs, sent to an isolate: plain values only.
@immutable
class TextCardComposeJob {
  const TextCardComposeJob({
    required this.photo,
    required this.words,
    required this.width,
    required this.height,
    required this.blur,
    required this.dimming,
    this.offsetX = 0,
    this.offsetY = 0,
    this.zoom = 1,
    this.contain = false,
    this.cardRgb = 0,
    this.quarterTurns = 0,
    this.flipHorizontal = false,
    this.colorMatrix,
    this.gradientStartArgb = 0,
    this.gradientEndArgb = 0,
    this.gradientAngle = 0,
    this.vignette = 0,
  });

  /// The job for a card over [background], whose own colour is [cardColor].
  factory TextCardComposeJob.forBackground(
      {required PhotoPixels photo,
      required Uint8List words,
      required int width,
      required int height,
      required TextCardBackground background,
      required Color cardColor}) {
    final gradient = background.gradientColors;
    return TextCardComposeJob(
      photo: photo,
      words: words,
      width: width,
      height: height,
      blur: background.blur,
      dimming: background.dimming,
      offsetX: background.offsetX,
      offsetY: background.offsetY,
      zoom: background.zoom,
      contain: background.contain,
      cardRgb: cardColor.toARGB32() & 0xFFFFFF,
      quarterTurns: background.quarterTurns % 4,
      flipHorizontal: background.flipHorizontal,
      colorMatrix: background.colorMatrix,
      gradientStartArgb: gradient?.$1 ?? 0,
      gradientEndArgb: gradient?.$2 ?? 0,
      gradientAngle: background.gradientAngle,
      vignette: background.vignette,
    );
  }

  final PhotoPixels photo;

  /// The card without its background: straight RGBA, [width] x [height].
  final Uint8List words;
  final int width;
  final int height;

  /// [TextCardBackground.blur] and [TextCardBackground.dimming].
  final double blur;
  final double dimming;

  /// [TextCardBackground.offsetX], [TextCardBackground.offsetY],
  /// [TextCardBackground.zoom] and [TextCardBackground.contain].
  final double offsetX;
  final double offsetY;
  final double zoom;
  final bool contain;

  /// The card's own colour (0xRRGGBB), around a whole photo.
  final int cardRgb;
  final int quarterTurns;
  final bool flipHorizontal;

  /// [TextCardBackground.colorMatrix].
  final List<double>? colorMatrix;

  /// [TextCardBackground.gradientColors]; both 0 without a gradient.
  final int gradientStartArgb;
  final int gradientEndArgb;
  final double gradientAngle;
  final double vignette;
}

/// A card over a background photo as a JPEG (quality 92), composed on the
/// CPU: the photo turned and mirrored, its colours adjusted, placed (cut to
/// fill, or whole on the card's colour; panned and zoomed), blurred and
/// dimmed, the gradient and the vignette over it, then the card's words, rule
/// and footer. Every step left at its default is skipped, so such a card is
/// byte for byte what NEFORUM made before 1.3. Run with [compute].
Uint8List composeTextCard(TextCardComposeJob job) {
  var rgba = job.photo.rgba;
  var w = job.photo.width, h = job.photo.height;
  if (job.quarterTurns % 4 != 0 || job.flipHorizontal) {
    (rgba, w, h) = orientRgba(rgba, w, h, quarterTurns: job.quarterTurns, flip: job.flipHorizontal);
  }
  final matrix = job.colorMatrix;
  if (matrix != null) rgba = applyColorMatrix(rgba, matrix);
  final frame = RgbFrame(job.width, job.height)
    ..placePhoto(rgba, w, h,
        sigma: job.blur * job.width / 1080,
        zoom: job.zoom,
        offsetX: job.offsetX,
        offsetY: job.offsetY,
        contain: job.contain,
        fillRgb: job.cardRgb);
  if (job.dimming > 0) frame.blendColor((job.dimming * 255).round().clamp(0, 255) << 24);
  if (job.gradientStartArgb != 0 || job.gradientEndArgb != 0) frame.blendLinearGradient(job.gradientStartArgb, job.gradientEndArgb, job.gradientAngle);
  if (job.vignette > 0) frame.vignette(job.vignette);
  frame.draw(job.words, job.width, job.height, 0, 0);
  return frame.encodeJpeg();
}
