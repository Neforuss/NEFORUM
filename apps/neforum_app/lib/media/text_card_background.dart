import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:neforum_core/neforum_core.dart' show MediaAttachment;

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

/// A photo behind a text card's words: one of the post's photos or one picked
/// only for the card, cover-fitted, blurred and dimmed. The photo is only used
/// inside the card; it is not posted by itself.
///
/// Kept as JSON in the composer ([toJson], with the photo) and in each card's
/// render parameters ([toRenderParameters], the photo by id).
@immutable
class TextCardBackground {
  const TextCardBackground({
    required this.photo,
    this.blur = 12,
    this.dimming = 0.35,
    this.textColor = TextCardTextColor.automatic,
    this.textBox = false,
  });

  /// Null when [j] holds no usable photo.
  static TextCardBackground? tryParse(Map<String, dynamic>? j) {
    final raw = j?['photo'];
    if (j == null || raw is! Map) return null;
    try {
      return TextCardBackground(
        photo: MediaAttachment.fromJson(Map<String, dynamic>.from(raw)),
        blur: _number(j['blur'], 0, maxBlur) ?? 12,
        dimming: _number(j['dimming'], 0, maxDimming) ?? 0.35,
        textColor: TextCardTextColor.values.asNameMap()[j['textColor']] ?? TextCardTextColor.automatic,
        textBox: j['textBox'] == true,
      );
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
    return TextCardBackground(
      photo: photo,
      blur: _number(p['blur'], 0, maxBlur) ?? 12,
      dimming: _number(p['dimming'], 0, maxDimming) ?? 0.35,
      textColor: TextCardTextColor.values.asNameMap()[p['textColor']] ?? TextCardTextColor.automatic,
      textBox: p['textBox'] == true,
    );
  }

  static double? _number(Object? v, double min, double max) => v is num && v.isFinite ? v.toDouble().clamp(min, max) : null;

  static const double maxBlur = 30;
  static const double maxDimming = 0.8;

  final MediaAttachment photo;

  /// Blur strength (Gaussian sigma) in pixels at 1080 wide, 0 to 30.
  final double blur;

  /// Black laid over the photo, 0 to 0.8.
  final double dimming;
  final TextCardTextColor textColor;

  /// A soft box behind the words, for busy photos.
  final bool textBox;

  TextCardBackground copyWith({MediaAttachment? photo, double? blur, double? dimming, TextCardTextColor? textColor, bool? textBox}) =>
      TextCardBackground(
        photo: photo ?? this.photo,
        blur: blur ?? this.blur,
        dimming: dimming ?? this.dimming,
        textColor: textColor ?? this.textColor,
        textBox: textBox ?? this.textBox,
      );

  Map<String, dynamic> toJson() => {'photo': photo.toJson(), ...toRenderParameters()};

  Map<String, dynamic> toRenderParameters() => {
        'mediaId': photo.id,
        'blur': blur,
        'dimming': dimming,
        'textColor': textColor.name,
        'textBox': textBox,
      };
}

/// A [TextCardBackground] with its photo decoded, ready to paint.
@immutable
class TextCardBackdrop {
  const TextCardBackdrop({required this.image, required this.luminance, required this.background});

  final ui.Image image;

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

  /// Paints the photo over [frame]: cover-fitted, blurred and dimmed. [unit] is
  /// the picture's width / 1080.
  void paint(Canvas canvas, Rect frame, double unit) {
    final iw = image.width.toDouble(), ih = image.height.toDouble();
    final scale = math.max(frame.width / iw, frame.height / ih);
    final src = Rect.fromCenter(center: Offset(iw / 2, ih / 2), width: frame.width / scale, height: frame.height / scale);
    final sigma = background.blur * unit;
    canvas.save();
    canvas.clipRect(frame);
    canvas.drawRect(frame, Paint()..color = const Color(0xFF000000));
    canvas.drawImageRect(
      image,
      src,
      frame,
      Paint()
        ..filterQuality = FilterQuality.high
        ..imageFilter = sigma > 0.01 ? ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp) : null,
    );
    if (background.dimming > 0) canvas.drawRect(frame, Paint()..color = Color.fromRGBO(0, 0, 0, background.dimming));
    canvas.restore();
  }

  void dispose() => image.dispose();
}

/// Longest side a card's background photo is decoded at: enough for a
/// 1080 x 1920 card, which blurs it anyway.
const int kBackdropMaxSide = 1920;

/// Decodes the photo in [bytes] for [background]. Null when it cannot be read.
Future<TextCardBackdrop?> decodeTextCardBackdrop(Uint8List bytes, TextCardBackground background) async {
  final px = await decodePhotoPixels(bytes, maxSide: kBackdropMaxSide);
  if (px == null) return null;
  final image = await imageFromPixels(px);
  return TextCardBackdrop(image: image, luminance: px.luminance, background: background);
}

