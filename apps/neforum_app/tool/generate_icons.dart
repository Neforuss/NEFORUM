// Renders the NEFORUM mark (a yellow diamond on the purple tile: the
// broadcast sign, a point with an arc and the roof over it, on top; bars
// below) into every icon the platforms need. Colors match Brand.markGradient and Brand.yellow in
// lib/theme/tokens.dart; the shape comes from lib/brand/mark_geometry.dart,
// the same geometry the app paints.
//
//   dart run tool/generate_icons.dart
//
// Pure Dart (package:image), anti-aliased with signed distance fields and
// blended in linear light, so the icons are reproducible from source and
// need no design tool.

import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:neforum_app/brand/mark_geometry.dart';

const _c0 = (0x94, 0x26, 0xFF); // light purple
const _c1 = (0x7D, 0x00, 0xFF); // NEFORUM purple
const _c2 = (0x5C, 0x00, 0xC4); // deep purple
const _yellow = (0xFF, 0xFF, 0x00);

void main() {
  final root = Directory.current.path;
  String at(String rel) => '$root/$rel'.replaceAll('\\', '/');

  // ---- Shared sources -------------------------------------------------------
  _png(at('assets/brand/icon.png'), _render(1024, tile: _Tile.rounded));
  _png(at('assets/brand/icon_foreground.png'), _render(1024, tile: _Tile.none, radius: 0.30));

  // ---- Android ----------------------------------------------------------------
  const densities = {'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0};
  for (final e in densities.entries) {
    final legacy = (48 * e.value).round();
    final adaptive = (108 * e.value).round();
    _png(at('android/app/src/main/res/mipmap-${e.key}/ic_launcher.png'), _render(legacy, tile: _Tile.rounded, inset: 0.04));
    _png(at('android/app/src/main/res/mipmap-${e.key}/ic_launcher_round.png'), _render(legacy, tile: _Tile.circle, inset: 0.02));
    // Adaptive icon layers: the foreground mark must sit inside the central
    // 72dp circle of the 108dp canvas (radius 0.333; the tips reach 0.29).
    _png(at('android/app/src/main/res/mipmap-${e.key}/ic_launcher_foreground.png'), _render(adaptive, tile: _Tile.none, radius: 0.29));
    _png(at('android/app/src/main/res/mipmap-${e.key}/ic_launcher_background.png'), _render(adaptive, tile: _Tile.square, markless: true));
    // Monochrome layer for Android 13 themed icons.
    _png(at('android/app/src/main/res/mipmap-${e.key}/ic_launcher_monochrome.png'), _render(adaptive, tile: _Tile.none, radius: 0.29, mono: true));
  }
  final anydpi = File(at('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml'));
  anydpi.parent.createSync(recursive: true);
  const adaptiveXml = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
''';
  anydpi.writeAsStringSync(adaptiveXml);
  File(at('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml')).writeAsStringSync(adaptiveXml);

  // ---- iOS (no transparency, the OS applies the mask) -------------------------
  const iosSizes = {
    'Icon-App-20x20@1x.png': 20, 'Icon-App-20x20@2x.png': 40, 'Icon-App-20x20@3x.png': 60,
    'Icon-App-29x29@1x.png': 29, 'Icon-App-29x29@2x.png': 58, 'Icon-App-29x29@3x.png': 87,
    'Icon-App-40x40@1x.png': 40, 'Icon-App-40x40@2x.png': 80, 'Icon-App-40x40@3x.png': 120,
    'Icon-App-60x60@2x.png': 120, 'Icon-App-60x60@3x.png': 180,
    'Icon-App-76x76@1x.png': 76, 'Icon-App-76x76@2x.png': 152,
    'Icon-App-83.5x83.5@2x.png': 167, 'Icon-App-1024x1024@1x.png': 1024,
  };
  for (final e in iosSizes.entries) {
    _png(at('ios/Runner/Assets.xcassets/AppIcon.appiconset/${e.key}'), _render(e.value, tile: _Tile.square, opaque: true));
  }

  // ---- macOS (Big Sur grid: 824/1024 body, soft shadow) ------------------------
  for (final s in [16, 32, 64, 128, 256, 512, 1024]) {
    _png(at('macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$s.png'), _render(s, tile: _Tile.rounded, inset: 100 / 1024, shadow: s >= 64));
  }

  // ---- Windows ------------------------------------------------------------------
  final winFrames = [for (final s in [16, 24, 32, 48, 64, 128, 256]) _render(s, tile: _Tile.rounded, inset: s <= 24 ? 0.0 : 0.03)];
  File(at('windows/runner/resources/app_icon.ico')).writeAsBytesSync(img.IcoEncoder().encodeImages(winFrames));

  // ---- Tray ---------------------------------------------------------------------
  final trayFrames = [for (final s in [16, 20, 24, 32, 48]) _render(s, tile: _Tile.rounded)];
  File(at('assets/tray/tray_icon.ico')).writeAsBytesSync(img.IcoEncoder().encodeImages(trayFrames));
  // macOS menu bar: template image (black + alpha), 22pt @2x.
  _png(at('assets/tray/tray_icon.png'), _render(44, tile: _Tile.none, radius: 0.46, mono: true));

  // ---- Web ----------------------------------------------------------------------
  // Maskable icons keep the mark inside the central circle of radius 0.4.
  _png(at('web/icons/Icon-192.png'), _render(192, tile: _Tile.rounded, inset: 0.04));
  _png(at('web/icons/Icon-512.png'), _render(512, tile: _Tile.rounded, inset: 0.04));
  _png(at('web/icons/Icon-maskable-192.png'), _render(192, tile: _Tile.square, radius: 0.33, opaque: true));
  _png(at('web/icons/Icon-maskable-512.png'), _render(512, tile: _Tile.square, radius: 0.33, opaque: true));
  _png(at('web/favicon.png'), _render(64, tile: _Tile.rounded));

  stdout.writeln('Icons written.');
}

enum _Tile { none, rounded, circle, square }

void _png(String path, img.Image image) {
  final f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(img.encodePng(image, level: 9));
  stdout.writeln('  $path (${image.width}x${image.height})');
}

/// Renders the icon at [size] px.
///
/// [inset] shrinks the tile inside the canvas (fraction of size), [radius]
/// is the diamond's half-diagonal as a fraction of the tile (or of the
/// canvas without a tile), [markless] draws only the tile, [mono] draws the
/// mark in black on transparency (template / monochrome icons), [opaque]
/// fills transparent pixels (iOS forbids alpha).
img.Image _render(
  int size, {
  _Tile tile = _Tile.rounded,
  double inset = 0,
  double radius = MarkGeometry.defaultRadius,
  bool markless = false,
  bool mono = false,
  bool opaque = false,
  bool shadow = false,
}) {
  final im = img.Image(width: size, height: size, numChannels: 4);
  final s = size.toDouble();
  final pad = s * inset;
  final tileSize = s - pad * 2;
  final tl = pad;
  final cornerRadius = tileSize * 0.30;
  final cx = s / 2, cy = s / 2;

  final mark = MarkGeometry(tileSize, cx: cx, cy: cy, radius: radius);

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final px = x + 0.5, py = y + 0.5;

      // Tile coverage.
      double tileCov;
      switch (tile) {
        case _Tile.none:
          tileCov = 0;
        case _Tile.square:
          tileCov = 1;
        case _Tile.circle:
          tileCov = _cov(math.sqrt(math.pow(px - cx, 2) + math.pow(py - cy, 2)) - tileSize / 2);
        case _Tile.rounded:
          tileCov = _cov(_roundedRectSdf(px, py, tl, tl, tileSize, tileSize, cornerRadius));
      }

      // Gradient along the diagonal of the tile.
      final t = (((px - tl) + (py - tl)) / (2 * tileSize)).clamp(0.0, 1.0);
      final (gr, gg, gb) = _gradient(t);

      var r = gr, g = gg, b = gb, a = tileCov;

      if (shadow && tile == _Tile.rounded && tileCov < 1) {
        // Soft drop shadow under the macOS tile.
        final d = _roundedRectSdf(px, py - s * 0.012, tl, tl, tileSize, tileSize, cornerRadius);
        final sh = (1 - (d / (s * 0.035)).clamp(0.0, 1.0)) * 0.28;
        final outA = a + sh * (1 - a);
        if (outA > 0) {
          r = (r * a) / outA;
          g = (g * a) / outA;
          b = (b * a) / outA;
        }
        a = outA;
      }

      if (!markless) {
        final markCov = _markCov(px, py, mark);
        if (mono) {
          // Black shapes; alpha carries the shape.
          r = 0;
          g = 0;
          b = 0;
          a = math.max(a, markCov);
        } else if (markCov > 0) {
          // Yellow over the tile, mixed in linear light so the edges stay
          // clean instead of going brown (yellow and purple are opposites).
          r = _mix(r, _yellow.$1, markCov);
          g = _mix(g, _yellow.$2, markCov);
          b = _mix(b, _yellow.$3, markCov);
          a = a + markCov * (1 - a);
        }
      }

      if (opaque && a < 1) {
        // Composite over the gradient (iOS/maskable must be fully opaque).
        r = r * a + gr * (1 - a);
        g = g * a + gg * (1 - a);
        b = b * a + gb * (1 - a);
        a = 1;
      }

      im.setPixelRgba(x, y, r.round().clamp(0, 255), g.round().clamp(0, 255), b.round().clamp(0, 255), (a * 255).round().clamp(0, 255));
    }
  }
  return im;
}

double _cov(double d) => (0.5 - d).clamp(0.0, 1.0);

double _roundedRectSdf(double px, double py, double x, double y, double w, double h, double r) {
  final cx = x + w / 2, cy = y + h / 2;
  final qx = (px - cx).abs() - (w / 2 - r);
  final qy = (py - cy).abs() - (h / 2 - r);
  final ox = math.max(qx, 0.0), oy = math.max(qy, 0.0);
  return math.sqrt(ox * ox + oy * oy) + math.min(math.max(qx, qy), 0.0) - r;
}

/// Coverage of the mark at (px, py), from signed distances (negative inside):
/// roof, arc, bars and point, as laid out by [MarkGeometry].
double _markCov(double px, double py, MarkGeometry m) {
  final dx = px - m.cx, dy = py - m.cy;
  final rho = math.sqrt(dx * dx + dy * dy);
  // Signed distance to a diamond of half-diagonal h is (|x| + |y| - h) / √2.
  final dDiamond = (dx.abs() + dy.abs() - m.r) / math.sqrt2;
  // Top half of the diamond, outside the roof's inner circle.
  var d = math.max(math.max(dDiamond, dy), m.roofInner - rho);
  if (m.arc case (final inner, final outer)) {
    d = math.min(d, math.max(math.max(inner - rho, rho - outer), dy));
  }
  var dBars = double.infinity;
  for (final (top, bottom) in m.bars) {
    dBars = math.min(dBars, math.max(top - dy, dy - bottom));
  }
  d = math.min(d, math.max(math.max(dDiamond, dBars), m.windowRadius - rho));
  d = math.min(d, rho - m.pointRadius);
  return _cov(d);
}

/// Mixes sRGB channel [from] toward [to] by [t] in linear light.
double _mix(double from, int to, double t) {
  double lin(double c) => (c /= 255) <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  final l = lin(from) + (lin(to.toDouble()) - lin(from)) * t;
  return 255 * (l <= 0.0031308 ? l * 12.92 : 1.055 * math.pow(l, 1 / 2.4) - 0.055);
}

(double, double, double) _gradient(double t) {
  (double, double, double) mix((int, int, int) a, (int, int, int) b, double u) =>
      (a.$1 + (b.$1 - a.$1) * u, a.$2 + (b.$2 - a.$2) * u, a.$3 + (b.$3 - a.$3) * u);
  return t < 0.5 ? mix(_c0, _c1, t / 0.5) : mix(_c1, _c2, (t - 0.5) / 0.5);
}
