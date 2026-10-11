import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/file_export.dart';
import 'package:neforum_app/state/differentiation.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

void main() {
  final reg = builtinRegistry();
  PlatformDescriptor d(String id) => reg.descriptor(id)!;
  const post = 'Shipped v2 of my #keyboard firmware! Per-key RGB is smooth now. Guide: https://example.org/kb\n\n#opensource #diy #rgb';

  test('hashtags to the end keeps the words and moves every tag', () {
    final out = applyTransform(VersionTransform.hashtagsToEnd, post, d('instagram'));
    expect(out, 'Shipped v2 of my keyboard firmware! Per-key RGB is smooth now. Guide: https://example.org/kb\n\n#keyboard #opensource #diy #rgb');
  });

  test('fewer hashtags keeps the network maximum', () {
    expect(applyTransform(VersionTransform.fewerHashtags, post, d('x')), endsWith('\n\n#keyboard #opensource'));
    expect(applyTransform(VersionTransform.fewerHashtags, post, d('threads')), endsWith('\n\n#keyboard'));
  });

  test('no hashtags leaves plain words', () {
    final out = applyTransform(VersionTransform.noHashtags, post, d('reddit'));
    expect(out, isNot(contains('#')));
    expect(out, contains('my keyboard firmware'));
  });

  test('link in bio replaces links and keeps tags last', () {
    final out = applyTransform(VersionTransform.linkInBio, post, d('instagram'));
    expect(out, isNot(contains('https://')));
    expect(out, contains('smooth now.\n\nLink in bio.'), reason: 'the "Guide:" label goes with its link');
    expect(out, endsWith('#opensource #diy #rgb'));
    expect(applyTransform(VersionTransform.linkInBio, 'No link here', d('instagram')), 'No link here');
  });

  test('airy paragraphs split long paragraphs into sentences', () {
    const long = 'We rebuilt the firmware from scratch this spring. It took four months and two prototypes. '
        'Today it ships to everyone, and it is open source.';
    final out = applyTransform(VersionTransform.airy, long, d('linkedin'));
    expect(out.split('\n\n'), hasLength(3));
  });

  test('fit truncates only where the network cannot thread', () {
    final long = 'word ' * 200;
    expect(TextCounter.fits(applyTransform(VersionTransform.fit, long, d('instagram')), d('instagram').text), isTrue);
    expect(usefulTransforms(long, d('x')), isNot(contains(VersionTransform.fit)), reason: 'X threads long posts');
  });

  test('useful transforms are the ones that change something', () {
    expect(usefulTransforms('Plain words only', d('linkedin')), isEmpty);
    expect(usefulTransforms(post, d('instagram')), containsAll([VersionTransform.hashtagsToEnd, VersionTransform.linkInBio, VersionTransform.noLink]));
  });

  test('auto-differentiate gives each network its own shape', () {
    final ig = autoVersion(post, d('instagram'));
    final li = autoVersion(post, d('linkedin'));
    final rd = autoVersion(post, d('reddit'));
    final x = autoVersion(post, d('x'));
    expect(ig, contains('Link in bio.'));
    expect(rd, isNot(contains('#')));
    expect(x, endsWith('#keyboard #opensource'));
    expect({ig, li, rd, x}, hasLength(4), reason: 'four different versions');
    for (final id in reg.all.map((a) => a.id)) {
      expect(styleFor(id).tip, isNotEmpty, reason: id);
      expect(() => autoVersion(post, d(id)), returnsNormally, reason: id);
    }
  });

  test('export names are valid on every OS', () {
    expect(FileExport.safeName('NEFORUM card - Instagram: "big" <test>?.jpg'), 'NEFORUM card - Instagram big test.jpg');
    expect(FileExport.safeName('a' * 200).length, 80);
    expect(FileExport.safeName('..'), 'NEFORUM');
  });
}
