import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'env.dart';

/// Puts a photo on the system clipboard so it can be pasted into a web
/// composer with Ctrl+V / ⌘V, next to the text a hand-off already copies.
///
/// Flutter's [Clipboard] only carries text, so this goes through the
/// "neforum/clipboard" channel in the Windows and macOS runners
/// (windows/runner/flutter_window.cpp, macos/Runner/MainFlutterWindow.swift).
/// Browsers read pasted pictures as PNG; the original file rides along for
/// places that accept pasted files and keep its own format.
abstract final class ClipboardMedia {
  static const MethodChannel _channel = MethodChannel('neforum/clipboard');

  /// Photos can be copied here (phones hand photos over by the share sheet).
  static bool get supported => Env.isWindows || Env.isMacOS;

  /// Longest side of the pasted picture. Networks scale photos to about this
  /// size anyway, and it keeps the PNG small enough for their upload limits.
  static const int maxSide = 2048;

  /// Copies the image in [bytes] (JPEG, PNG, WebP, GIF) and, on desktop, the
  /// file at [path]. Returns false when nothing could be copied.
  static Future<bool> copyImage(Uint8List bytes, {String? path}) async {
    if (!supported) return false;
    try {
      final image = await _decode(bytes);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final rgba = Env.isWindows ? await image.toByteData(format: ui.ImageByteFormat.rawRgba) : null;
      final args = <String, Object?>{
        if (png != null) 'png': png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        if (rgba != null) 'dib': dibFromRgba(rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes), image.width, image.height),
        if (path != null && path.isNotEmpty) 'path': path,
      };
      image.dispose();
      return await _channel.invokeMethod<bool>('copyImage', args) ?? false;
    } on Object catch (e) {
      debugPrint('Could not copy the image: $e');
      return false;
    }
  }

  static Future<ui.Image> _decode(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
      final longest = w > h ? w : h;
      if (longest <= maxSide) return ui.TargetImageSize(width: w, height: h);
      final scale = maxSide / longest;
      return ui.TargetImageSize(width: (w * scale).round(), height: (h * scale).round());
    });
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  /// A Windows device-independent bitmap (BITMAPINFOHEADER, 32-bit BGRA,
  /// rows bottom-up) from straight RGBA pixels.
  @visibleForTesting
  static Uint8List dibFromRgba(Uint8List rgba, int width, int height) {
    const header = 40;
    final out = Uint8List(header + width * height * 4);
    ByteData.sublistView(out)
      ..setUint32(0, header, Endian.little)
      ..setInt32(4, width, Endian.little)
      ..setInt32(8, height, Endian.little) // positive: bottom-up
      ..setUint16(12, 1, Endian.little) // planes
      ..setUint16(14, 32, Endian.little) // bits per pixel
      ..setUint32(16, 0, Endian.little) // BI_RGB
      ..setUint32(20, width * height * 4, Endian.little);
    for (var y = 0; y < height; y++) {
      var src = y * width * 4;
      var dst = header + (height - 1 - y) * width * 4;
      for (var x = 0; x < width; x++, src += 4, dst += 4) {
        out[dst] = rgba[src + 2];
        out[dst + 1] = rgba[src + 1];
        out[dst + 2] = rgba[src];
        out[dst + 3] = rgba[src + 3];
      }
    }
    return out;
  }
}
