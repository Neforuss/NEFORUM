// 1.4.4: GIFs on Instagram. The API takes no GIF; NEFORUM keeps the GIF in
// the post (it was dropped before), the app makes an animated one an MP4 and
// a one-frame one a still JPEG ([PhotoFit.gifAsVideo]), and the adapter posts
// the MP4 as a Reel, a carousel video or a video story.

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/instagram/instagram_adapter.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

MediaAttachment _gif({String id = 'g1', int width = 480, int height = 270}) => MediaAttachment(
      id: id,
      path: '/tmp/$id.gif',
      mimeType: 'image/gif',
      sizeBytes: 900000,
      width: width,
      height: height,
      fileName: '$id.gif',
    );

/// The MP4 the app makes of [_gif]: a generated copy listing the GIF.
MediaAttachment _gifVideo({String id = 'gv1', int width = 1024, int height = 1280, String from = 'g1'}) => MediaAttachment(
      id: id,
      path: '/tmp/$id.mp4',
      mimeType: 'video/mp4',
      sizeBytes: 400000,
      width: width,
      height: height,
      durationMs: 6000,
      fileName: '$from (video).mp4',
      generated: true,
      derivedFrom: from,
      fitKey: 'gifVideo|k',
    );

void main() {
  final registry = builtinRegistry();
  final ig = registry.descriptor('instagram')!;
  final adapter = InstagramAdapter(sleep: (_) async {});
  final api = fakeAccount('instagram', tier: PlatformTier.byokApi, config: {'igUserId': '1784100', 'username': 'neforum_test'});
  final handoff = fakeAccount('instagram', tier: PlatformTier.handoff);
  final secrets = {
    'access_token': 'LONG',
    'expires_at': testNow.add(const Duration(days: 50)).toIso8601String(),
    'refreshed_at': testNow.subtract(const Duration(days: 1)).toIso8601String(),
  };

  group('the GIF stays in the post', () {
    Post post(List<MediaAttachment> media) {
      final now = DateTime(2026, 11, 16);
      return Post(id: 'p', text: 'Look', media: media, targets: const [PostTarget(accountId: 'ig')], createdAt: now, updatedAt: now);
    }

    test('Instagram keeps a GIF (it was dropped with "does not take that type of video" before 1.4.4)', () {
      final p = post([_gif()]);
      final v = const VariantResolver().resolve(p, p.targets.single, ig);
      expect(v.media.map((m) => m.id), ['g1']);
      expect(v.issues.where((i) => i.code == 'media.dropped'), isEmpty);
    });

    test('a network without the rule still drops a type it refuses (Threads: JPEG and PNG)', () {
      final d = registry.descriptor('threads')!;
      expect(d.media.imageMimeTypes, isNot(contains('image/gif')));
      final p = post([_gif()]);
      final v = const VariantResolver().resolve(p, p.targets.single, d);
      expect(v.media, isEmpty);
      expect(v.issues.map((i) => i.code), contains('media.dropped'));
    });

    test('only Instagram makes GIFs videos', () {
      for (final d in registry.descriptors) {
        expect(d.media.gifAsVideo, d.id == 'instagram', reason: d.id);
      }
    });
  });

  group('photo rules', () {
    PhotoFit fitFor(ConnectedAccount a, [PostVariant v = const PostVariant(text: 'x')]) => adapter.photoFit(a, v)!;

    test('the API fits GIFs: the feed and stories; a still JPEG is what the rules describe', () {
      final feed = fitFor(api);
      expect(feed.gifAsVideo, isTrue);
      final wide = _gif(width: 1000, height: 400);
      expect(feed.problemsOf(_gif()), [FitProblem.fileType], reason: '16:9 is inside 4:5 to 1.91:1, but no GIF');
      expect(feed.problemsOf(wide), [FitProblem.tooWide, FitProblem.fileType], reason: '2.5:1 is wider than 1.91:1');
      expect(feed.describe(wide, PhotoFitMode.pad), 'given borders to 1.91:1, made a still JPEG');
      final standIn = feed.standIn(wide, PhotoFitMode.pad);
      expect((standIn.mimeType, standIn.derivedFrom), ('image/jpeg', 'g1'));
      expect(feed.problemsOf(standIn), isEmpty);

      final story = fitFor(api, const PostVariant(text: '', extra: {'storyMode': true}));
      expect(story.gifAsVideo, isTrue);
      expect(story.problemsOf(_gif()), [FitProblem.fileType], reason: 'a story takes any shape');
      expect(story.problemsOf(_gif(width: 1080, height: 1920)), [FitProblem.fileType]);
    });

    test('the share sheet takes the GIF as it is', () {
      final fit = fitFor(handoff);
      expect(fit.gifAsVideo, isFalse);
      expect(fit.problemsOf(_gif()), isEmpty);
    });

    test('other networks never change a GIF', () {
      for (final id in ['mastodon', 'bluesky', 'threads', 'x']) {
        final fit = registry.byId(id)!.photoFit(fakeAccount(id, tier: PlatformTier.byokApi), const PostVariant(text: 'x'));
        expect(fit?.gifAsVideo ?? false, isFalse, reason: id);
        expect(fit?.problemsOf(_gif()) ?? const [], isEmpty, reason: id);
      }
    });

    test('a still photo is unchanged by the GIF rule', () {
      final feed = fitFor(api);
      expect(feed.problemsOf(fakeImage(width: 1080, height: 1080)), isEmpty);
      expect(feed.describe(fakeImage(mimeType: 'image/png', width: 1080, height: 1080), PhotoFitMode.pad), 'made a JPEG');
    });
  });

  group('validate', () {
    List<String> errors(PostVariant v, ConnectedAccount a) => adapter.validate(v, a).where((i) => i.isError).map((i) => i.code).toList();

    test('a GIF left as it is says what to do (photos never changed in Settings)', () {
      final issues = adapter.validate(PostVariant(text: 'x', media: [_gif(width: 1000, height: 1000)]), api);
      expect(issues.where((i) => i.isError).map((i) => i.code), ['instagram.gif']);
      expect(issues.firstWhere((i) => i.code == 'instagram.gif').message, contains('g1.gif is a GIF'));
    });

    test('hand-off takes a GIF', () {
      expect(errors(PostVariant(text: 'x', media: [_gif()]), handoff), isEmpty);
    });

    test('the video made of a GIF passes the feed and the story', () {
      expect(errors(PostVariant(text: 'x', media: [_gifVideo()]), api), isEmpty);
      final both = PostVariant(
        text: 'x',
        media: [_gifVideo()],
        storyMedia: [_gifVideo(id: 'gv2', width: 720, height: 1280)],
        extra: extraWithPlacement(const {}, PostPlacement.feedAndStory),
      );
      expect(errors(both, api), isEmpty);
    });
  });

  group('publish', () {
    test('Post + Story: the feed video is a Reel, the story a video story (STORIES with video_url)', () async {
      final bodies = <Map<String, dynamic>>[];
      Future<http.Response> handler(http.Request r) async {
        if (r.url.path.endsWith('/media')) {
          bodies.add(bodyOf(r));
          return http.Response('{"id":"C${bodies.length}"}', 200, headers: jsonHeaders);
        }
        if (r.url.path.endsWith('/media_publish')) return http.Response('{"id":"M${bodies.length}"}', 200, headers: jsonHeaders);
        return http.Response('{"status_code":"FINISHED","permalink":"https://www.instagram.com/p/x/"}', 200, headers: jsonHeaders);
      }

      final host = FakeMediaHost();
      final ctx = testContext(mediaHost: host, handler: handler);
      final v = PostVariant(
        text: 'Moving',
        media: [_gifVideo()],
        storyMedia: [_gifVideo(id: 'gv2', width: 720, height: 1280)],
        extra: extraWithPlacement(const {}, PostPlacement.feedAndStory),
      );
      final res = await adapter.publish(v, api, secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(host.uploaded.map((m) => (m.id, m.mimeType)), [('gv1', 'video/mp4'), ('gv2', 'video/mp4')]);
      expect(bodies, [
        {'media_type': 'REELS', 'video_url': 'https://cdn.example.test/gv1', 'caption': 'Moving'},
        {'media_type': 'STORIES', 'video_url': 'https://cdn.example.test/gv2'},
      ]);
    });

    test('a GIF video in a carousel is a VIDEO item', () async {
      final bodies = <Map<String, dynamic>>[];
      final ctx = testContext(
        mediaHost: FakeMediaHost(),
        handler: (r) async {
          if (r.url.path.endsWith('/media')) {
            bodies.add(bodyOf(r));
            return http.Response('{"id":"C${bodies.length}"}', 200, headers: jsonHeaders);
          }
          if (r.url.path.endsWith('/media_publish')) return http.Response('{"id":"M"}', 200, headers: jsonHeaders);
          return http.Response('{"status_code":"FINISHED"}', 200, headers: jsonHeaders);
        },
      );
      final v = PostVariant(text: 'Two', media: [fakeImage(width: 1080, height: 1350), _gifVideo()]);
      expect((await adapter.publish(v, api, secrets, ctx)).success, isTrue);
      expect(bodies[1], {'is_carousel_item': 'true', 'media_type': 'VIDEO', 'video_url': 'https://cdn.example.test/gv1'});
    });
  });
}
