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
  // Windows notifications show this next to the text (registered as the
  // app's IconUri, see lib/platform/notifications.dart).
  _png(at('assets/brand/notify_icon.png'), _render(256, tile: _Tile.rounded, inset: 0.02));
  // Vector copy of the logo (web splash, websites, documents).
  final svg = _svg(1024);
  File(at('assets/brand/logo.svg')).writeAsStringSync(svg);
  File(at('web/icons/logo.svg')).writeAsStringSync(svg);

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
    // Status bar icon for notifications (24dp, white; Android uses only the alpha).
    _png(at('android/app/src/main/res/drawable-${e.key}/ic_stat_neforum.png'), _render((24 * e.value).round(), tile: _Tile.none, radius: 0.44, mono: true, white: true));
    // Launch screen before Android 12 (later versions show the launcher icon).
    _png(at('android/app/src/main/res/drawable-${e.key}/splash_mark.png'), _render((96 * e.value).round(), tile: _Tile.rounded));
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
  // Launch screen: the tile at 120 pt on the deep purple background set in
  // LaunchScreen.storyboard.
  for (final (suffix, scale) in [('', 1), ('@2x', 2), ('@3x', 3)]) {
    _png(at('ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage$suffix.png'), _render(120 * scale, tile: _Tile.rounded));
  }

  // ---- macOS (Big Sur grid: 824/1024 body, soft shadow) ------------------------
  for (final s in [16, 32, 64, 128, 256, 512, 1024]) {
    _png(at('macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$s.png'), _render(s, tile: _Tile.rounded, inset: 100 / 1024, shadow: s >= 64));
  }

  // ---- Windows ------------------------------------------------------------------
  final winFrames = [for (final s in [16, 24, 32, 48, 64, 128, 256]) _render(s, tile: _Tile.rounded, inset: s <= 24 ? 0.0 : 0.03)];
  File(at('windows/runner/resources/app_icon.ico')).writeAsBytesSync(img.IcoEncoder().encodeImages(winFrames));
  // Installer artwork (24-bit BMP, which every Inno Setup 6 accepts), at
  // 100/150/200/250 % display scaling: the tile on the inner pages' white
  // header, and a purple side panel on the welcome and finish pages.
  for (final (pct, small, wide, tall) in [(100, 55, 164, 314), (150, 83, 246, 459), (200, 110, 328, 628), (250, 138, 410, 797)]) {
    _bmp(at('installer/wizard_small_$pct.bmp'), _onWhite(_render(small, tile: _Tile.rounded, inset: 0.04)));
    _bmp(at('installer/wizard_large_$pct.bmp'), _panel(wide, tall));
  }

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

void _bmp(String path, img.Image image) {
  File(path).writeAsBytesSync(img.encodeBmp(image));
  stdout.writeln('  $path (${image.width}x${image.height})');
}

/// [image] composited over white, without alpha.
img.Image _onWhite(img.Image image) {
  final out = img.Image(width: image.width, height: image.height);
  for (final p in image) {
    final a = p.a / 255;
    out.setPixelRgb(p.x, p.y, (p.r * a + 255 * (1 - a)).round(), (p.g * a + 255 * (1 - a)).round(), (p.b * a + 255 * (1 - a)).round());
  }
  return out;
}

/// The purple gradient [w] x [h] with the mark in the upper part (installer
/// side panel).
img.Image _panel(int w, int h) {
  final out = img.Image(width: w, height: h);
  final mark = MarkGeometry(w.toDouble(), cx: w / 2, cy: h * 0.40, radius: 0.30);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final (gr, gg, gb) = _gradient(((x + 0.5) / w + (y + 0.5) / h) / 2);
      final c = _markCov(x + 0.5, y + 0.5, mark);
      out.setPixelRgb(x, y, _mix(gr, _yellow.$1, c).round(), _mix(gg, _yellow.$2, c).round(), _mix(gb, _yellow.$3, c).round());
    }
  }
  return out;
}

/// The logo on its tile as SVG, [size] units square, from the same geometry.
String _svg(int size) {
  final s = size.toDouble();
  final m = MarkGeometry(s, cx: s / 2, cy: s / 2);
  String n(double v) {
    final t = v.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
    return t.isEmpty ? '0' : t;
  }

  final (cx, cy, r, ri) = (m.cx, m.cy, m.r, m.roofInner);
  final roof = 'M${n(cx - r)} ${n(cy)}L${n(cx)} ${n(cy - r)}L${n(cx + r)} ${n(cy)}L${n(cx + ri)} ${n(cy)}'
      'A${n(ri)} ${n(ri)} 0 0 0 ${n(cx - ri)} ${n(cy)}Z';
  final (a, b) = m.arc!;
  final arc = 'M${n(cx - b)} ${n(cy)}A${n(b)} ${n(b)} 0 0 1 ${n(cx + b)} ${n(cy)}L${n(cx + a)} ${n(cy)}'
      'A${n(a)} ${n(a)} 0 0 0 ${n(cx - a)} ${n(cy)}Z';
  // Each bar is the slice of the lower triangle between its top and bottom.
  final bars = [
    for (final (top, bottom) in m.bars)
      'M${n(cx - (r - top))} ${n(cy + top)}L${n(cx + (r - top))} ${n(cy + top)}'
          'L${n(cx + (r - bottom))} ${n(cy + bottom)}L${n(cx - (r - bottom))} ${n(cy + bottom)}Z',
  ].join();
  String hex((int, int, int) c) => '#${[c.$1, c.$2, c.$3].map((v) => v.toRadixString(16).padLeft(2, '0').toUpperCase()).join()}';
  return '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $size $size" width="$size" height="$size" role="img" aria-label="NEFORUM">
  <title>NEFORUM</title>
  <defs>
    <linearGradient id="nf-tile" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="${hex(_c0)}"/>
      <stop offset="0.5" stop-color="${hex(_c1)}"/>
      <stop offset="1" stop-color="${hex(_c2)}"/>
    </linearGradient>
    <mask id="nf-window" maskUnits="userSpaceOnUse" x="0" y="0" width="$size" height="$size">
      <rect width="$size" height="$size" fill="#fff"/>
      <circle cx="${n(cx)}" cy="${n(cy)}" r="${n(m.windowRadius)}" fill="#000"/>
    </mask>
  </defs>
  <rect width="$size" height="$size" rx="${n(s * 0.30)}" fill="url(#nf-tile)"/>
  <g fill="${hex(_yellow)}">
    <path d="$roof"/>
    <path d="$arc"/>
    <path d="$bars" mask="url(#nf-window)"/>
    <circle cx="${n(cx)}" cy="${n(cy)}" r="${n(m.pointRadius)}"/>
  </g>
</svg>
''';
}

/// Renders the icon at [size] px.
///
/// [inset] shrinks the tile inside the canvas (fraction of size), [radius]
/// is the diamond's half-diagonal as a fraction of the tile (or of the
/// canvas without a tile), [markless] draws only the tile, [mono] draws the
/// mark in black on transparency (template / monochrome icons), [opaque]
/// fills transparent pixels (iOS forbids alpha), [white] makes a [mono]
/// mark white instead of black (Android status bar icons).
img.Image _render(
  int size, {
  _Tile tile = _Tile.rounded,
  double inset = 0,
  double radius = MarkGeometry.defaultRadius,
  bool markless = false,
  bool mono = false,
  bool white = false,
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
          // One colour; alpha carries the shape.
          r = g = b = white ? 255 : 0;
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
