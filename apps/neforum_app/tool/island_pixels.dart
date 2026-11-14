// Reads the colours of the Dynamic Island in an iPhone simulator screenshot, for
// tool/ci_live_activity_simulator.sh. Text is read with Vision there; what has no
// text is read here: the red failure badge beside the count, the orange pause
// shape of a stale activity, and the blue ring and mark of a live one.
//
//   dart run tool/island_pixels.dart island.png \
//     [--require right.red] [--require left.orange] [--forbid left.blue]
//
// Prints one line per half of the island band ("left red=0 orange=812 blue=0"),
// then every requirement that failed, and exits 1 if one did.
//
// The band is the top 6% of the screen, where the island sits on every iPhone
// with one, minus the outer 12% at each side, where the status bar's clock and
// icons are (white, so they would not count anyway). The island is drawn dark
// whatever the system appearance, so only saturated, bright pixels count.

import 'dart:io';

import 'package:image/image.dart' as img;

/// The colours the island's content uses: system red, orange and blue.
enum IslandHue { red, orange, blue }

/// The two halves of the band, split at the camera.
enum IslandHalf { left, right }

/// Pixels of one hue in one half below this are antialiasing or noise. A badge or
/// mark at 3x is several hundred.
const int kIslandMinimumPixels = 40;

/// The hue of one pixel, or null when it is dark, grey, white or another colour.
/// System red is near 3 degrees, orange near 36, blue near 210, in both the light
/// and the dark variants.
IslandHue? islandHueOf(int r, int g, int b) {
  final high = [r, g, b].reduce((a, c) => a > c ? a : c);
  final low = [r, g, b].reduce((a, c) => a < c ? a : c);
  if (high < 140) return null; // dark, or the island itself
  final chroma = high - low;
  if (chroma / high < 0.55) return null; // grey, white, or washed out
  double hue;
  if (high == r) {
    hue = 60 * (((g - b) / chroma) % 6);
  } else if (high == g) {
    hue = 60 * (((b - r) / chroma) + 2);
  } else {
    hue = 60 * (((r - g) / chroma) + 4);
  }
  if (hue < 0) hue += 360;
  if (hue < 15 || hue >= 340) return IslandHue.red;
  if (hue >= 25 && hue < 45) return IslandHue.orange; // yellow is near 50
  if (hue >= 195 && hue < 240) return IslandHue.blue;
  return null;
}

/// How many pixels of each hue each half of the island band holds.
class IslandReading {
  IslandReading(this.counts);

  final Map<IslandHalf, Map<IslandHue, int>> counts;

  int count(IslandHalf half, IslandHue hue) => counts[half]![hue]!;

  /// One line per half, as the CI log shows it.
  List<String> describe() => [
        for (final half in IslandHalf.values) '${half.name} ${[for (final hue in IslandHue.values) '${hue.name}=${count(half, hue)}'].join(' ')}',
      ];
}

/// Counts the island band of [image].
IslandReading readIsland(img.Image image) {
  final counts = {for (final half in IslandHalf.values) half: {for (final hue in IslandHue.values) hue: 0}};
  final bottom = (image.height * 0.06).round();
  final left = (image.width * 0.12).round();
  final right = image.width - left;
  final middle = image.width ~/ 2;
  for (var y = 0; y < bottom; y++) {
    for (var x = left; x < right; x++) {
      final p = image.getPixel(x, y);
      final hue = islandHueOf((p.rNormalized * 255).round(), (p.gNormalized * 255).round(), (p.bNormalized * 255).round());
      if (hue == null) continue;
      final half = x < middle ? IslandHalf.left : IslandHalf.right;
      counts[half]![hue] = counts[half]![hue]! + 1;
    }
  }
  return IslandReading(counts);
}

/// A requirement as the script writes it: "right.red".
(IslandHalf, IslandHue) parseIslandSpot(String spot) {
  final parts = spot.split('.');
  if (parts.length != 2) throw FormatException('expected half.hue, as in right.red', spot);
  final half = IslandHalf.values.where((h) => h.name == parts[0]).firstOrNull;
  final hue = IslandHue.values.where((h) => h.name == parts[1]).firstOrNull;
  if (half == null || hue == null) throw FormatException('expected left|right . red|orange|blue', spot);
  return (half, hue);
}

/// Every requirement [reading] does not meet, in words for the CI log.
List<String> checkIsland(IslandReading reading, {List<String> require = const [], List<String> forbid = const [], int minimum = kIslandMinimumPixels}) {
  int at(String spot) {
    final (half, hue) = parseIslandSpot(spot);
    return reading.count(half, hue);
  }

  return [
    for (final spot in require)
      if (at(spot) < minimum) 'expected $spot in the island: ${at(spot)} pixels, under $minimum',
    for (final spot in forbid)
      if (at(spot) >= minimum) 'expected no $spot in the island: ${at(spot)} pixels',
  ];
}

/// The command line. Returns the exit code.
int runIslandPixels(List<String> args, {StringSink? out}) {
  final sink = out ?? stdout;
  String? path;
  final require = <String>[];
  final forbid = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if ((arg == '--require' || arg == '--forbid') && i + 1 < args.length) {
      (arg == '--require' ? require : forbid).add(args[++i]);
    } else if (!arg.startsWith('--') && path == null) {
      path = arg;
    } else {
      sink.writeln('usage: island_pixels.dart picture.png [--require half.hue] [--forbid half.hue]');
      return 2;
    }
  }
  if (path == null) {
    sink.writeln('usage: island_pixels.dart picture.png [--require half.hue] [--forbid half.hue]');
    return 2;
  }
  for (final spot in [...require, ...forbid]) {
    try {
      parseIslandSpot(spot);
    } on FormatException catch (e) {
      sink.writeln('${e.message}: $spot');
      return 2;
    }
  }
  final file = File(path);
  final image = file.existsSync() ? img.decodeImage(file.readAsBytesSync()) : null;
  if (image == null) {
    sink.writeln('cannot read $path as a picture');
    return 2;
  }
  final reading = readIsland(image);
  reading.describe().forEach(sink.writeln);
  final problems = checkIsland(reading, require: require, forbid: forbid);
  problems.forEach(sink.writeln);
  return problems.isEmpty ? 0 : 1;
}

void main(List<String> args) {
  exitCode = runIslandPixels(args);
}
