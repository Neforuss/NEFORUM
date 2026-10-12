import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

MediaAttachment photo({int w = 3000, int h = 4000, String mime = 'image/jpeg', int size = 2000000, String id = 'p1'}) =>
    MediaAttachment(id: id, path: '/m/$id', mimeType: mime, sizeBytes: size, width: w, height: h, fileName: '$id.jpg');

ConnectedAccount account(String platformId, PlatformTier tier) =>
    ConnectedAccount(id: 'a', platformId: platformId, tier: tier, displayName: 'Me', createdAt: DateTime(2026, 10, 12));

void main() {
  const instagram = PhotoFit(minAspect: 0.8, maxAspect: 1.91, mimeTypes: {'image/jpeg'}, maxBytes: 8 * 1024 * 1024);

  group('PhotoFit', () {
    test('what a photo breaks', () {
      expect(instagram.problemsOf(photo()), [FitProblem.tooTall], reason: '3:4 is taller than 4:5');
      expect(instagram.problemsOf(photo(w: 4000, h: 1000)), [FitProblem.tooWide]);
      expect(instagram.problemsOf(photo(w: 4000, h: 5000)), isEmpty, reason: 'exactly 4:5');
      expect(instagram.problemsOf(photo(w: 1910, h: 1000)), isEmpty, reason: 'exactly 1.91:1');
      expect(instagram.problemsOf(photo(w: 2000, h: 2000, mime: 'image/png')), [FitProblem.fileType]);
      expect(instagram.problemsOf(photo(w: 2000, h: 2000, size: 9 * 1024 * 1024)), [FitProblem.fileSize]);
      expect(const PhotoFit(maxPixels: 100).problemsOf(photo(w: 10, h: 10)), [FitProblem.pixels], reason: 'must stay below');
      expect(const PhotoFit(maxSideSum: 10000).problemsOf(photo(w: 6000, h: 5000)), [FitProblem.pixels]);
    });

    test('GIFs and videos are never changed', () {
      final gif = photo(w: 100, h: 1000, mime: 'image/gif');
      final video = MediaAttachment(id: 'v', path: '/v', mimeType: 'video/mp4', sizeBytes: 1, width: 100, height: 1000);
      expect(instagram.problemsOf(gif), isEmpty);
      expect(instagram.problemsOf(video), isEmpty);
    });

    test('fitted size: borders keep the photo, cropping keeps the middle', () {
      expect(instagram.fittedSize(photo(), PhotoFitMode.pad), (width: 3200, height: 4000));
      expect(instagram.fittedSize(photo(), PhotoFitMode.crop), (width: 3000, height: 3750));
      expect(instagram.fittedSize(photo(w: 4000, h: 1000), PhotoFitMode.pad), (width: 4000, height: 2094));
      expect(instagram.fittedSize(photo(w: 4000, h: 1000), PhotoFitMode.crop), (width: 1910, height: 1000));
      expect(instagram.fittedSize(photo(w: 2000, h: 2000), PhotoFitMode.pad), (width: 2000, height: 2000));
    });

    test('fitted size: scaled down within pixel limits', () {
      final s = const PhotoFit(maxPixels: 36152320).fittedSize(photo(w: 8000, h: 6000), PhotoFitMode.pad)!;
      expect(s.width * s.height, lessThan(36152320));
      expect(s.width / s.height, closeTo(4 / 3, 0.001));
      final t = const PhotoFit(maxSideSum: 10000).fittedSize(photo(w: 9000, h: 3000), PhotoFitMode.pad)!;
      expect(t.width + t.height, lessThanOrEqualTo(10000));
    });

    test('the stand-in the composer checks passes the rules it was made for', () {
      for (final m in [photo(), photo(w: 4000, h: 1000), photo(mime: 'image/png', size: 20000000)]) {
        for (final mode in [PhotoFitMode.pad, PhotoFitMode.crop]) {
          final s = instagram.standIn(m, mode);
          expect(instagram.problemsOf(s), isEmpty, reason: '${m.width}x${m.height} ${m.mimeType} $mode');
          expect(s.derivedFrom, m.id);
          expect(s.path, m.path, reason: 'previews still show the photo');
        }
      }
    });

    test('words for the composer', () {
      expect(instagram.describe(photo(), PhotoFitMode.pad), 'given borders to 4:5');
      expect(instagram.describe(photo(), PhotoFitMode.crop), 'cropped to 4:5');
      expect(instagram.describe(photo(w: 4000, h: 1000, mime: 'image/png'), PhotoFitMode.pad), 'given borders to 1.91:1, made a JPEG');
      expect(PhotoFit.ratioLabel(0.75), '3:4');
      expect(PhotoFit.ratioLabel(10), '10:1');
      expect(PhotoFit.ratioLabel(0.1), '1:10');
    });

    test('the same rules and mode give the same key; anything else another', () {
      expect(instagram.keyFor(PhotoFitMode.pad), const PhotoFit(minAspect: 0.8, maxAspect: 1.91, mimeTypes: {'image/jpeg'}, maxBytes: 8388608).keyFor(PhotoFitMode.pad));
      expect(instagram.keyFor(PhotoFitMode.pad), isNot(instagram.keyFor(PhotoFitMode.crop)));
      expect(instagram.keyFor(PhotoFitMode.pad), isNot(instagram.copyWith(maxBytes: 1).keyFor(PhotoFitMode.pad)));
    });

    test('media JSON keeps where a fitted copy came from', () {
      const m = MediaAttachment(id: 'c', path: '/c', mimeType: 'image/jpeg', sizeBytes: 1, generated: true, derivedFrom: 'p1', fitKey: 'k');
      final back = MediaAttachment.fromJson(m.toJson());
      expect((back.derivedFrom, back.fitKey, back.generated, back.isTextCard), ('p1', 'k', true, false));
      expect(const MediaAttachment(id: 't', path: '/t', mimeType: 'image/jpeg', sizeBytes: 1, generated: true).isTextCard, isTrue);
    });
  });

  group('each network\'s photo rules', () {
    final registry = builtinRegistry();
    PhotoFit? fitFor(String id, PlatformTier tier, [PostVariant v = const PostVariant(text: 'x')]) =>
        registry.byId(id)!.photoFit(account(id, tier), v);

    test('Instagram: the API wants 4:5 to 1.91:1 JPEGs; stories any shape; the share sheet anything it can open', () {
      final api = fitFor('instagram', PlatformTier.byokApi)!;
      expect((api.minAspect, api.maxAspect, api.maxBytes), (0.8, 1.91, 8 * 1024 * 1024));
      expect(api.mimeTypes, {'image/jpeg'});
      expect(api.problemsOf(photo()), [FitProblem.tooTall], reason: 'the photo in the report: 0.75:1');
      final story = fitFor('instagram', PlatformTier.byokApi, const PostVariant(text: '', extra: {'storyMode': true}))!;
      expect((story.minAspect, story.maxAspect), (null, null));
      final handoff = fitFor('instagram', PlatformTier.handoff)!;
      expect(handoff.problemsOf(photo()), isEmpty, reason: 'the app crops by itself');
      expect(handoff.problemsOf(photo(mime: 'image/webp')), [FitProblem.fileType]);
    });

    test('Threads, LinkedIn, Telegram and X add their own limits', () {
      expect(fitFor('threads', PlatformTier.byokApi)!.problemsOf(photo(w: 11000, h: 1000)), contains(FitProblem.tooWide));
      expect(fitFor('linkedin', PlatformTier.byokApi)!.problemsOf(photo(w: 8000, h: 6000)), contains(FitProblem.pixels));
      expect(fitFor('telegram', PlatformTier.openApi)!.problemsOf(photo(w: 9000, h: 2000)), contains(FitProblem.pixels));
      expect(fitFor('telegram', PlatformTier.handoff), isNull);
      expect(fitFor('x', PlatformTier.byokApi)!.problemsOf(photo(w: 2000, h: 2000, size: 6 * 1024 * 1024)), contains(FitProblem.fileSize));
    });

    test('Bluesky and Mastodon have no shape rule', () {
      expect(fitFor('bluesky', PlatformTier.openApi)!.problemsOf(photo(w: 100, h: 1000)), isEmpty);
    });
  });
}
