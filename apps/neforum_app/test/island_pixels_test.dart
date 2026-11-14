// tool/island_pixels.dart: what the iOS simulator job reads from the island's
// colours, on pictures drawn here the way the island draws them.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../tool/island_pixels.dart';

// The system colours, light and dark variants (Apple's Human Interface Guidelines).
const _red = [(255, 59, 48), (255, 69, 58)];
const _orange = [(255, 149, 0), (255, 159, 10)];
const _blue = [(0, 122, 255), (10, 132, 255)];

/// A 3x screen of an iPhone with an island, 402 by 874 points, Settings-grey under a
/// black island.
img.Image _screen() {
  final image = img.Image(width: 1206, height: 2622);
  img.fill(image, color: img.ColorRgb8(242, 242, 247));
  // The island: 37 pt high from 11 pt down, the compact pill about 250 pt wide.
  img.fillRect(image, x1: 603 - 375, y1: 33, x2: 603 + 375, y2: 144, color: img.ColorRgb8(0, 0, 0));
  return image;
}

/// A [size] pixel square of a colour, centred at x, y. fillRect includes both corners.
void _dot(img.Image image, int x, int y, (int, int, int) colour, {int size = 30}) => img.fillRect(image,
    x1: x - size ~/ 2, y1: y - size ~/ 2, x2: x - size ~/ 2 + size - 1, y2: y - size ~/ 2 + size - 1, color: img.ColorRgb8(colour.$1, colour.$2, colour.$3));

void main() {
  group('the hue of a pixel', () {
    test('system red, orange and blue, in both variants', () {
      for (final c in _red) {
        expect(islandHueOf(c.$1, c.$2, c.$3), IslandHue.red, reason: '$c');
      }
      for (final c in _orange) {
        expect(islandHueOf(c.$1, c.$2, c.$3), IslandHue.orange, reason: '$c');
      }
      for (final c in _blue) {
        expect(islandHueOf(c.$1, c.$2, c.$3), IslandHue.blue, reason: '$c');
      }
    });

    test('black, the island, white text, the grey ring track and Settings\' grey count as nothing', () {
      for (final c in [(0, 0, 0), (255, 255, 255), (64, 64, 64), (242, 242, 247), (128, 128, 128), (180, 180, 190)]) {
        expect(islandHueOf(c.$1, c.$2, c.$3), isNull, reason: '$c');
      }
    });

    test('green (a charging battery) and yellow are none of the three', () {
      expect(islandHueOf(52, 199, 89), isNull);
      expect(islandHueOf(255, 214, 10), isNull);
    });

    test('a dim antialiased edge does not count', () {
      expect(islandHueOf(90, 20, 18), isNull);
    });
  });

  group('reading the island', () {
    test('a live pill with a failure: blue on the left, red on the right', () {
      final s = _screen();
      _dot(s, 603 - 300, 88, _blue.last); // the ring and the paper plane
      _dot(s, 603 + 330, 88, _red.last); // the badge, beside the count
      final r = readIsland(s);
      expect(r.count(IslandHalf.left, IslandHue.blue), 900);
      expect(r.count(IslandHalf.right, IslandHue.red), 900);
      expect(r.count(IslandHalf.left, IslandHue.orange), 0);
      expect(checkIsland(r, require: ['right.red', 'left.blue'], forbid: ['left.orange']), isEmpty);
    });

    test('a stale pill: the orange pause shape on the left, no blue arc', () {
      final s = _screen();
      _dot(s, 603 - 300, 88, _orange.last);
      _dot(s, 603 + 330, 88, _red.last);
      final r = readIsland(s);
      expect(checkIsland(r, require: ['left.orange', 'right.red'], forbid: ['left.blue']), isEmpty);
      // The live check refuses this picture, and the stale check the live one.
      expect(checkIsland(r, forbid: ['left.orange']), hasLength(1));
    });

    test('a pill without the badge fails the red requirement, in words', () {
      final s = _screen();
      _dot(s, 603 - 300, 88, _blue.last);
      final problems = checkIsland(readIsland(s), require: ['right.red']);
      expect(problems.single, 'expected right.red in the island: 0 pixels, under $kIslandMinimumPixels');
    });

    test('colour below the status bar band is the app in front, not the island', () {
      final s = _screen();
      _dot(s, 603 + 330, 600, _red.last, size: 200);
      _dot(s, 603 - 300, 600, _orange.last, size: 200);
      final r = readIsland(s);
      expect(r.count(IslandHalf.right, IslandHue.red), 0);
      expect(r.count(IslandHalf.left, IslandHue.orange), 0);
    });

    test('the outer edges, where the clock and the battery are, are left out', () {
      final s = _screen();
      _dot(s, 40, 60, _red.last);
      _dot(s, 1170, 60, _blue.last);
      final r = readIsland(s);
      expect(r.count(IslandHalf.left, IslandHue.red), 0);
      expect(r.count(IslandHalf.right, IslandHue.blue), 0);
    });

    test('a few stray pixels are under the minimum', () {
      final s = _screen();
      _dot(s, 603 + 330, 88, _red.last, size: 4);
      final r = readIsland(s);
      expect(r.count(IslandHalf.right, IslandHue.red), 16);
      expect(checkIsland(r, require: ['right.red']), hasLength(1));
    });

    test('one line per half, for the log', () {
      final s = _screen();
      _dot(s, 603 + 330, 88, _red.last);
      expect(readIsland(s).describe(), ['left red=0 orange=0 blue=0', 'right red=900 orange=0 blue=0']);
    });
  });

  group('the command line', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('island_pixels'));
    tearDown(() => dir.deleteSync(recursive: true));

    String save(img.Image image) {
      final path = '${dir.path}/island.png';
      File(path).writeAsBytesSync(img.encodePng(image));
      return path;
    }

    test('exits 0 when every requirement holds, 1 when one does not', () {
      final s = _screen();
      _dot(s, 603 + 330, 88, _red.last);
      final path = save(s);
      final out = StringBuffer();
      expect(runIslandPixels([path, '--require', 'right.red', '--forbid', 'left.orange'], out: out), 0);
      expect(out.toString(), contains('right red=900'));
      final failed = StringBuffer();
      expect(runIslandPixels([path, '--require', 'left.orange'], out: failed), 1);
      expect(failed.toString(), contains('expected left.orange in the island'));
    });

    test('exits 2 on a missing picture or a requirement it cannot read', () {
      final out = StringBuffer();
      expect(runIslandPixels(['${dir.path}/none.png'], out: out), 2);
      expect(out.toString(), contains('cannot read'));
      final path = save(_screen());
      expect(runIslandPixels([path, '--require', 'middle.green'], out: StringBuffer()), 2);
      expect(runIslandPixels([path, '--require', 'right'], out: StringBuffer()), 2);
      expect(runIslandPixels([], out: StringBuffer()), 2);
      expect(runIslandPixels([path, '--bogus'], out: StringBuffer()), 2);
    });
  });
}
