import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import 'env.dart';

/// Pasted files (paths), or a pasted picture as PNG.
@immutable
class PastedMedia {
  const PastedMedia({this.files = const [], this.png});
  final List<String> files;
  final Uint8List? png;
}

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

  /// What a paste into the composer can attach (Windows and macOS): files
  /// copied in Explorer or Finder, or a picture (a screenshot, "Copy image" in
  /// a browser) as PNG bytes. Null when the clipboard holds neither.
  static Future<PastedMedia?> readImage() async {
    if (!supported) return null;
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('readImage');
      if (r == null || r.isEmpty) return null;
      final files = (r['files'] as List?)?.whereType<String>().toList() ?? const [];
      if (files.isNotEmpty) return PastedMedia(files: files);
      final png = r['png'];
      if (png is Uint8List && png.isNotEmpty) return PastedMedia(png: png);
      final dib = r['dib'];
      if (dib is Uint8List && dib.isNotEmpty) {
        final converted = await compute(pngFromDib, dib);
        if (converted != null) return PastedMedia(png: converted);
      }
    } on Object catch (e) {
      debugPrint('Could not read the clipboard: $e');
    }
    return null;
  }

  /// A PNG from a Windows device-independent bitmap (CF_DIB / CF_DIBV5), as
  /// older screenshot tools put on the clipboard. Null when it is not one.
  @visibleForTesting
  static Uint8List? pngFromDib(Uint8List dib) {
    if (dib.length < 40) return null;
    final d = ByteData.sublistView(dib);
    final headerSize = d.getUint32(0, Endian.little);
    if (headerSize < 40 || headerSize > dib.length) return null;
    final bits = d.getUint16(14, Endian.little);
    final compression = d.getUint32(16, Endian.little);
    var colours = d.getUint32(32, Endian.little);
    if (colours == 0 && bits <= 8) colours = 1 << bits;
    // BI_BITFIELDS with the classic header: three colour masks follow it.
    final masks = headerSize == 40 && compression == 3 ? 12 : 0;
    final offset = 14 + headerSize + masks + colours * 4;
    final file = Uint8List(14 + dib.length);
    ByteData.sublistView(file)
      ..setUint8(0, 0x42) // 'B'
      ..setUint8(1, 0x4D) // 'M'
      ..setUint32(2, file.length, Endian.little)
      ..setUint32(10, offset, Endian.little);
    file.setRange(14, file.length, dib);
    img.Image? image;
    try {
      image = img.decodeBmp(file);
    } on Object {
      image = null;
    }
    if (image == null) return null;
    // 32-bit bitmaps often leave the fourth byte at zero: that is not
    // "transparent", it is unused.
    if (image.numChannels == 4 && image.every((p) => p.a == 0)) {
      for (final p in image) {
        p.a = 255;
      }
    }
    return img.encodePng(image);
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
