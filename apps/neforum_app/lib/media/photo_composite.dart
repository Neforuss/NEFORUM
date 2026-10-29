import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

// Pictures NEFORUM saves with a photo in them (captions on photos, text cards
// over a photo) are composited here, on the CPU, in an isolate. The engine
// only rasterizes the words, on a transparent layer ([rasterizeWordsLayer]);
// the photo never becomes an engine image. On Windows, a photo uploaded as an
// engine image, drawn into a picture and read back could stall for good
// (NEFORUM 1.2.0 stopped responding while saving a captioned photo).

/// Rasterizes what [paint] draws on a transparent [width] x [height] picture
/// and reads it back as straight (not premultiplied) RGBA. Only for words,
/// shapes and colours: never draw an image here.
Future<Uint8List> rasterizeWordsLayer(int width, int height, void Function(Canvas canvas) paint) async {
  final recorder = ui.PictureRecorder();
  paint(Canvas(recorder, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble())));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  image.dispose();
  if (data == null) throw StateError('Could not read back the words layer');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// The part of a [width] x [height] image that covers an area of
/// [areaWidth] x [areaHeight], centred: (left, top, width, height).
({double x, double y, double w, double h}) coverSource(int width, int height, double areaWidth, double areaHeight) {
  final scale = math.max(areaWidth / width, areaHeight / height);
  final w = areaWidth / scale, h = areaHeight / scale;
  return (x: (width - w) / 2, y: (height - h) / 2, w: w, h: h);
}

/// Whether a placement is the plain centred cover of [coverSource].
bool isDefaultPlacement({double zoom = 1, double offsetX = 0, double offsetY = 0, bool contain = false}) =>
    !contain && zoom == 1 && offsetX == 0 && offsetY == 0;

/// Where a [width] x [height] photo goes in an area of [areaWidth] x
/// [areaHeight]: scaled to cover it (cut to fit) or, with [contain], to fit
/// inside it whole; then enlarged by [zoom] (1 or more). The focal point
/// ([offsetX], [offsetY], each -1 to 1) says which part stays in view when
/// the photo is larger than the area, and where it sits when it is smaller:
/// -1 the left (top) edge, 0 the centre, 1 the right (bottom) edge.
///
/// Returns the visible part of the photo (s: source pixels) and where it
/// goes in the area (d: area pixels); the scale is `dw / sw`. With every
/// choice at its default this is [coverSource] over the whole area.
({double sx, double sy, double sw, double sh, double dx, double dy, double dw, double dh}) photoPlacement(
    int width, int height, double areaWidth, double areaHeight,
    {double zoom = 1, double offsetX = 0, double offsetY = 0, bool contain = false}) {
  if (isDefaultPlacement(zoom: zoom, offsetX: offsetX, offsetY: offsetY, contain: contain)) {
    final c = coverSource(width, height, areaWidth, areaHeight);
    return (sx: c.x, sy: c.y, sw: c.w, sh: c.h, dx: 0, dy: 0, dw: areaWidth, dh: areaHeight);
  }
  final fit = contain ? math.min(areaWidth / width, areaHeight / height) : math.max(areaWidth / width, areaHeight / height);
  final scale = fit * zoom;
  (double, double, double, double) axis(int size, double area, double offset) {
    final shown = size * scale;
    final start = (area - shown) * (offset.clamp(-1.0, 1.0) + 1) / 2;
    final d0 = math.max(0.0, start), d1 = math.min(area, start + shown);
    return ((d0 - start) / scale, math.max(0.0, d1 - d0) / scale, d0, math.max(0.0, d1 - d0));
  }

  final (sx, sw, dx, dw) = axis(width, areaWidth, offsetX);
  final (sy, sh, dy, dh) = axis(height, areaHeight, offsetY);
  return (sx: sx, sy: sy, sw: sw, sh: sh, dx: dx, dy: dy, dw: dw, dh: dh);
}

/// [rgba] ([width] x [height], 4 channels) turned clockwise by
/// [quarterTurns] quarter turns, then mirrored left to right when [flip].
(Uint8List, int, int) orientRgba(Uint8List rgba, int width, int height, {int quarterTurns = 0, bool flip = false}) {
  final turns = quarterTurns % 4;
  if (turns == 0 && !flip) return (rgba, width, height);
  final w = turns.isOdd ? height : width, h = turns.isOdd ? width : height;
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      // The turned picture's pixel (tx, y), before the mirror.
      final tx = flip ? w - 1 - x : x;
      final (sx, sy) = switch (turns) {
        1 => (y, height - 1 - tx),
        2 => (width - 1 - tx, height - 1 - y),
        3 => (width - 1 - y, tx),
        _ => (tx, y),
      };
      final s = (sy * width + sx) * 4, o = (y * w + x) * 4;
      out[o] = rgba[s];
      out[o + 1] = rgba[s + 1];
      out[o + 2] = rgba[s + 2];
      out[o + 3] = rgba[s + 3];
    }
  }
  return (out, w, h);
}

/// A copy of [rgba] (straight, 4 channels) with the 4 x 5 colour [matrix]
/// applied to every pixel, row-major with offsets in 0 to 255, as
/// `ColorFilter.matrix` takes it. Alpha is kept.
Uint8List applyColorMatrix(Uint8List rgba, List<double> matrix) {
  final m = Float64List.fromList(matrix);
  final out = Uint8List.fromList(rgba);
  for (var o = 0; o < out.length; o += 4) {
    final r = out[o].toDouble(), g = out[o + 1].toDouble(), b = out[o + 2].toDouble(), a = out[o + 3].toDouble();
    out[o] = (m[0] * r + m[1] * g + m[2] * b + m[3] * a + m[4]).round().clamp(0, 255);
    out[o + 1] = (m[5] * r + m[6] * g + m[7] * b + m[8] * a + m[9]).round().clamp(0, 255);
    out[o + 2] = (m[10] * r + m[11] * g + m[12] * b + m[13] * a + m[14]).round().clamp(0, 255);
  }
  return out;
}

/// Share of the half diagonal a vignette leaves untouched.
const double kVignetteInnerRadius = 0.45;

/// The axis of a gradient at [angleDegrees] over an area of [width] x
/// [height]: its direction and half its length, so it runs corner to corner.
(double, double, double) _gradientAxis(double width, double height, double angleDegrees) {
  final a = angleDegrees * math.pi / 180;
  final dx = math.sin(a), dy = math.cos(a);
  return (dx, dy, math.max(1e-6, (dx.abs() * width + dy.abs() * height) / 2));
}

/// Where a gradient at [angleDegrees] starts and ends over [area], for a
/// preview drawn by the engine: the same axis as
/// [RgbFrame.blendLinearGradient].
(Offset, Offset) linearGradientEnds(Rect area, double angleDegrees) {
  final (dx, dy, half) = _gradientAxis(area.width, area.height, angleDegrees);
  final along = Offset(dx * half, dy * half);
  return (area.center - along, area.center + along);
}

/// An opaque picture being composed, as RGB bytes row by row. Starts black.
class RgbFrame {
  RgbFrame(this.width, this.height) : rgb = Uint8List(width * height * 3);

  final int width;
  final int height;
  final Uint8List rgb;

  /// Fills the frame top to bottom from [top] to [bottom] (0xRRGGBB).
  void fillVerticalGradient(int top, int bottom) {
    final tr = top >> 16 & 0xFF, tg = top >> 8 & 0xFF, tb = top & 0xFF;
    final br = bottom >> 16 & 0xFF, bg = bottom >> 8 & 0xFF, bb = bottom & 0xFF;
    for (var y = 0; y < height; y++) {
      final t = (y + 0.5) / height;
      final r = (tr + (br - tr) * t).round(), g = (tg + (bg - tg) * t).round(), b = (tb + (bb - tb) * t).round();
      var o = y * width * 3;
      for (var x = 0; x < width; x++, o += 3) {
        rgb[o] = r;
        rgb[o + 1] = g;
        rgb[o + 2] = b;
      }
    }
  }

  /// Lays [argb] over the whole frame, as see-through as its alpha.
  void blendColor(int argb) {
    final a = argb >>> 24 & 0xFF;
    if (a == 0) return;
    final inv = 255 - a;
    final r = (argb >> 16 & 0xFF) * a, g = (argb >> 8 & 0xFF) * a, b = (argb & 0xFF) * a;
    for (var o = 0; o < rgb.length; o += 3) {
      rgb[o] = (r + rgb[o] * inv + 127) ~/ 255;
      rgb[o + 1] = (g + rgb[o + 1] * inv + 127) ~/ 255;
      rgb[o + 2] = (b + rgb[o + 2] * inv + 127) ~/ 255;
    }
  }

  /// Draws [pixels] ([w] x [h]) with its top left at ([dx], [dy]), clipped
  /// to the frame: RGB copied, or RGBA (premultiplied when [premultiplied],
  /// else straight) laid over what is there.
  void draw(Uint8List pixels, int w, int h, int dx, int dy, {int channels = 4, bool premultiplied = false}) {
    final x0 = math.max(0, dx), x1 = math.min(width, dx + w);
    final y0 = math.max(0, dy), y1 = math.min(height, dy + h);
    for (var y = y0; y < y1; y++) {
      var s = ((y - dy) * w + (x0 - dx)) * channels;
      var o = (y * width + x0) * 3;
      for (var x = x0; x < x1; x++, s += channels, o += 3) {
        if (channels == 3) {
          rgb[o] = pixels[s];
          rgb[o + 1] = pixels[s + 1];
          rgb[o + 2] = pixels[s + 2];
          continue;
        }
        final a = pixels[s + 3];
        if (a == 0) continue;
        final inv = 255 - a;
        if (premultiplied) {
          rgb[o] = math.min(255, pixels[s] + (rgb[o] * inv + 127) ~/ 255);
          rgb[o + 1] = math.min(255, pixels[s + 1] + (rgb[o + 1] * inv + 127) ~/ 255);
          rgb[o + 2] = math.min(255, pixels[s + 2] + (rgb[o + 2] * inv + 127) ~/ 255);
        } else {
          rgb[o] = (pixels[s] * a + rgb[o] * inv + 127) ~/ 255;
          rgb[o + 1] = (pixels[s + 1] * a + rgb[o + 1] * inv + 127) ~/ 255;
          rgb[o + 2] = (pixels[s + 2] * a + rgb[o + 2] * inv + 127) ~/ 255;
        }
      }
    }
  }

  /// Covers the whole frame with the photo ([rgba], straight, [w] x [h]),
  /// centred and cut to fit, blurred by [sigma] pixels (0: sharp), over
  /// black. A strong blur is made at a reduced size and scaled up: it looks
  /// the same and takes a fraction of the time.
  void coverWith(Uint8List rgba, int w, int h, {double sigma = 0}) {
    final factor = sigma < 0.5 ? 1.0 : math.max(1.0, sigma / 2.5);
    final sw = math.max(1, (width / factor).round()), sh = math.max(1, (height / factor).round());
    final src = coverSource(w, h, sw.toDouble(), sh.toDouble());
    final small = resample(rgba, w, h, 4, x: src.x, y: src.y, w: src.w, h: src.h, dw: sw, dh: sh);
    // Premultiplied over black is the colour itself.
    var flat = Uint8List(sw * sh * 3);
    for (var i = 0, o = 0; o < flat.length; i += 4, o += 3) {
      flat[o] = small[i];
      flat[o + 1] = small[i + 1];
      flat[o + 2] = small[i + 2];
    }
    if (sigma >= 0.5) flat = gaussianBlurRgb(flat, sw, sh, sigma / factor);
    if (sw != width || sh != height) {
      flat = resample(flat, sw, sh, 3, x: 0, y: 0, w: sw.toDouble(), h: sh.toDouble(), dw: width, dh: height);
    }
    rgb.setAll(0, flat);
  }

  /// Fills the whole frame with [rgb] (0xRRGGBB).
  void fill(int rgb) {
    final r = rgb >> 16 & 0xFF, g = rgb >> 8 & 0xFF, b = rgb & 0xFF;
    for (var o = 0; o < this.rgb.length; o += 3) {
      this.rgb[o] = r;
      this.rgb[o + 1] = g;
      this.rgb[o + 2] = b;
    }
  }

  /// Places the photo ([rgba], straight, [w] x [h]) in the frame as
  /// [photoPlacement] says: cut to fill it, or whole on [fillRgb]
  /// ([contain]), enlarged by [zoom] around the focal point ([offsetX],
  /// [offsetY], -1 to 1), then blurred by [sigma] pixels like [coverWith].
  /// With every choice at its default this is exactly [coverWith].
  void placePhoto(Uint8List rgba, int w, int h,
      {double sigma = 0, double zoom = 1, double offsetX = 0, double offsetY = 0, bool contain = false, int fillRgb = 0}) {
    if (isDefaultPlacement(zoom: zoom, offsetX: offsetX, offsetY: offsetY, contain: contain)) {
      coverWith(rgba, w, h, sigma: sigma);
      return;
    }
    final factor = sigma < 0.5 ? 1.0 : math.max(1.0, sigma / 2.5);
    final sw = math.max(1, (width / factor).round()), sh = math.max(1, (height / factor).round());
    final place = photoPlacement(w, h, sw.toDouble(), sh.toDouble(), zoom: zoom, offsetX: offsetX, offsetY: offsetY, contain: contain);
    final small = RgbFrame(sw, sh)..fill(fillRgb);
    final x0 = place.dx.round(), y0 = place.dy.round();
    final dw = (place.dx + place.dw).round() - x0, dh = (place.dy + place.dh).round() - y0;
    if (dw > 0 && dh > 0 && place.sw > 0 && place.sh > 0) {
      final placed = resample(rgba, w, h, 4, x: place.sx, y: place.sy, w: place.sw, h: place.sh, dw: dw, dh: dh);
      small.draw(placed, dw, dh, x0, y0, premultiplied: true);
    }
    var flat = small.rgb;
    if (sigma >= 0.5) flat = gaussianBlurRgb(flat, sw, sh, sigma / factor);
    if (sw != width || sh != height) {
      flat = resample(flat, sw, sh, 3, x: 0, y: 0, w: sw.toDouble(), h: sh.toDouble(), dw: width, dh: height);
    }
    rgb.setAll(0, flat);
  }

  /// Lays a straight-line gradient from [startArgb] to [endArgb] over the
  /// whole frame, each as see-through as its alpha. [angleDegrees] turns it
  /// clockwise: 0 runs from the top down, 90 from left to right
  /// ([linearGradientEnds]).
  void blendLinearGradient(int startArgb, int endArgb, double angleDegrees) {
    final (dx, dy, half) = _gradientAxis(width.toDouble(), height.toDouble(), angleDegrees);
    final sa = startArgb >>> 24 & 0xFF, sr = startArgb >> 16 & 0xFF, sg = startArgb >> 8 & 0xFF, sb = startArgb & 0xFF;
    final ea = endArgb >>> 24 & 0xFF, er = endArgb >> 16 & 0xFF, eg = endArgb >> 8 & 0xFF, eb = endArgb & 0xFF;
    if (sa == 0 && ea == 0) return;
    final cx = width / 2, cy = height / 2;
    for (var y = 0; y < height; y++) {
      var o = y * width * 3;
      final py = (y + 0.5 - cy) * dy;
      for (var x = 0; x < width; x++, o += 3) {
        final t = ((((x + 0.5 - cx) * dx + py) / half + 1) / 2).clamp(0.0, 1.0);
        final a = (sa + (ea - sa) * t).round();
        if (a == 0) continue;
        final inv = 255 - a;
        final r = (sr + (er - sr) * t).round(), g = (sg + (eg - sg) * t).round(), b = (sb + (eb - sb) * t).round();
        rgb[o] = (r * a + rgb[o] * inv + 127) ~/ 255;
        rgb[o + 1] = (g * a + rgb[o + 1] * inv + 127) ~/ 255;
        rgb[o + 2] = (b * a + rgb[o + 2] * inv + 127) ~/ 255;
      }
    }
  }

  /// Darkens the frame towards its corners: nothing inside
  /// [kVignetteInnerRadius] of the half diagonal, then more and more black,
  /// up to [strength] (0 to 1) in the corners.
  void vignette(double strength) {
    if (strength <= 0) return;
    final cx = width / 2, cy = height / 2;
    final half = math.sqrt(cx * cx + cy * cy);
    for (var y = 0; y < height; y++) {
      var o = y * width * 3;
      final ry = y + 0.5 - cy;
      for (var x = 0; x < width; x++, o += 3) {
        final rx = x + 0.5 - cx;
        final d = math.sqrt(rx * rx + ry * ry) / half;
        final t = ((d - kVignetteInnerRadius) / (1 - kVignetteInnerRadius)).clamp(0.0, 1.0);
        final a = (strength * t * 255).round();
        if (a == 0) continue;
        final inv = 255 - a;
        rgb[o] = (rgb[o] * inv + 127) ~/ 255;
        rgb[o + 1] = (rgb[o + 1] * inv + 127) ~/ 255;
        rgb[o + 2] = (rgb[o + 2] * inv + 127) ~/ 255;
      }
    }
  }

  /// The frame as a JPEG (quality 92). Three channels: the picture is opaque.
  Uint8List encodeJpeg() =>
      img.encodeJpg(img.Image.fromBytes(width: width, height: height, bytes: rgb.buffer, bytesOffset: rgb.offsetInBytes, numChannels: 3), quality: 92);
}

/// For each destination pixel along one axis: the source pixels that make it
/// and their weights.
class _Taps {
  _Taps(this.first, this.count, this.weights, this.stride);
  final Int32List first;
  final Int32List count;
  final Float32List weights;
  final int stride;
}

/// A tent filter as wide as the scale when shrinking (every source pixel
/// counts), plain linear interpolation when enlarging.
_Taps _taps(double start, double length, int srcSize, int dstSize) {
  final scale = length / dstSize;
  final support = math.max(1.0, scale);
  final stride = (support * 2).ceil() + 2;
  final first = Int32List(dstSize), count = Int32List(dstSize), weights = Float32List(dstSize * stride);
  for (var d = 0; d < dstSize; d++) {
    final centre = start + (d + 0.5) * scale - 0.5;
    var a = math.max(0, (centre - support).floor() + 1);
    var b = math.min(srcSize - 1, (centre + support).ceil() - 1);
    if (b < a) a = b = centre.round().clamp(0, srcSize - 1);
    final n = math.min(stride, b - a + 1);
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final w = math.max(0.0, 1 - ((a + i) - centre).abs() / support);
      weights[d * stride + i] = w;
      sum += w;
    }
    if (sum <= 0) {
      weights[d * stride] = 1;
      sum = 1;
    }
    for (var i = 0; i < n; i++) {
      weights[d * stride + i] /= sum;
    }
    first[d] = a;
    count[d] = math.max(1, n);
  }
  return _Taps(first, count, weights, stride);
}

/// The part ([x], [y], [w], [h]) of [src] ([sw] x [sh], [channels] 3 for RGB
/// or 4 for straight RGBA) scaled to [dw] x [dh]. RGBA comes back
/// premultiplied, ready for [RgbFrame.draw].
Uint8List resample(Uint8List src, int sw, int sh, int channels,
    {required double x, required double y, required double w, required double h, required int dw, required int dh}) {
  final hx = _taps(x, w, sw, dw), vy = _taps(y, h, sh, dh);
  var rowLo = sh, rowHi = 0;
  for (var d = 0; d < dh; d++) {
    rowLo = math.min(rowLo, vy.first[d]);
    rowHi = math.max(rowHi, vy.first[d] + vy.count[d] - 1);
  }
  final rows = rowHi - rowLo + 1;
  final tmp = Float32List(dw * rows * channels);
  for (var r = 0; r < rows; r++) {
    final row = (rowLo + r) * sw * channels;
    for (var d = 0; d < dw; d++) {
      final f = hx.first[d], n = hx.count[d], wo = d * hx.stride;
      var c0 = 0.0, c1 = 0.0, c2 = 0.0, c3 = 0.0;
      for (var i = 0; i < n; i++) {
        final p = row + (f + i) * channels;
        final wt = hx.weights[wo + i];
        if (channels == 4) {
          final a = src[p + 3] * wt;
          c0 += src[p] * a;
          c1 += src[p + 1] * a;
          c2 += src[p + 2] * a;
          c3 += a;
        } else {
          c0 += src[p] * wt;
          c1 += src[p + 1] * wt;
          c2 += src[p + 2] * wt;
        }
      }
      final t = (r * dw + d) * channels;
      if (channels == 4) {
        tmp[t] = c0 / 255;
        tmp[t + 1] = c1 / 255;
        tmp[t + 2] = c2 / 255;
        tmp[t + 3] = c3;
      } else {
        tmp[t] = c0;
        tmp[t + 1] = c1;
        tmp[t + 2] = c2;
      }
    }
  }
  final out = Uint8List(dw * dh * channels);
  for (var d = 0; d < dh; d++) {
    final f = vy.first[d] - rowLo, n = vy.count[d], wo = d * vy.stride;
    for (var xx = 0; xx < dw; xx++) {
      for (var c = 0; c < channels; c++) {
        var v = 0.0;
        for (var i = 0; i < n; i++) {
          v += tmp[((f + i) * dw + xx) * channels + c] * vy.weights[wo + i];
        }
        out[(d * dw + xx) * channels + c] = v.round().clamp(0, 255);
      }
    }
  }
  return out;
}

/// [rgb] ([w] x [h]) blurred with a Gaussian of [sigma] pixels; the edges
/// are extended outwards, as the engine's clamp tile mode does.
Uint8List gaussianBlurRgb(Uint8List rgb, int w, int h, double sigma) {
  final radius = math.max(1, (sigma * 3).ceil());
  final kernel = Float64List(radius * 2 + 1);
  var sum = 0.0;
  for (var i = -radius; i <= radius; i++) {
    sum += kernel[i + radius] = math.exp(-(i * i) / (2 * sigma * sigma));
  }
  for (var i = 0; i < kernel.length; i++) {
    kernel[i] /= sum;
  }
  final tmp = Float32List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var r = 0.0, g = 0.0, b = 0.0;
      for (var k = -radius; k <= radius; k++) {
        final p = (y * w + (x + k).clamp(0, w - 1)) * 3;
        final wt = kernel[k + radius];
        r += rgb[p] * wt;
        g += rgb[p + 1] * wt;
        b += rgb[p + 2] * wt;
      }
      final o = (y * w + x) * 3;
      tmp[o] = r;
      tmp[o + 1] = g;
      tmp[o + 2] = b;
    }
  }
  final out = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var r = 0.0, g = 0.0, b = 0.0;
      for (var k = -radius; k <= radius; k++) {
        final p = ((y + k).clamp(0, h - 1) * w + x) * 3;
        final wt = kernel[k + radius];
        r += tmp[p] * wt;
        g += tmp[p + 1] * wt;
        b += tmp[p + 2] * wt;
      }
      final o = (y * w + x) * 3;
      out[o] = r.round().clamp(0, 255);
      out[o + 1] = g.round().clamp(0, 255);
      out[o + 2] = b.round().clamp(0, 255);
    }
  }
  return out;
}
