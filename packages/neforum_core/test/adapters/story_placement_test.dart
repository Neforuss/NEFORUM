import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/facebook/facebook_adapter.dart';
import 'package:neforum_core/src/adapters/instagram/instagram_adapter.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: jsonHeaders);

const _feedAndStory = {kPlacementKey: 'feedAndStory'};
const _story = {kPlacementKey: 'story'};

void main() {
  group('placement', () {
    test('read from the placement key, else the 1.2 storyMode flag, else the feed', () {
      expect(placementOfExtra(const {}), PostPlacement.feed);
      expect(placementOfExtra(const {kStoryModeKey: true}), PostPlacement.story);
      expect(placementOfExtra(const {kStoryModeKey: false}), PostPlacement.feed);
      expect(placementOfExtra(const {kPlacementKey: 'feedAndStory', kStoryModeKey: true}), PostPlacement.feedAndStory);
      expect(placementOfExtra(const {kPlacementKey: 'nonsense'}), PostPlacement.feed);
    });

    test('written with the 1.2 flag in step, so older devices post a story as a story', () {
      expect(extraWithPlacement(const {'x': 1}, PostPlacement.story), {'x': 1, kPlacementKey: 'story', kStoryModeKey: true});
      expect(extraWithPlacement(const {kStoryModeKey: true}, PostPlacement.feedAndStory), {kPlacementKey: 'feedAndStory'});
      expect(extraWithPlacement(const {kPlacementKey: 'story', kStoryModeKey: true}, PostPlacement.feed), isEmpty);
    });

    test('the story copy has no caption and shows the story media, the feed copy keeps everything else', () {
      final feedPhoto = fakeImage(id: 'feed', width: 1080, height: 1350);
      final storyPhoto = fakeImage(id: 'story', width: 1080, height: 1920);
      final v = PostVariant(text: 'Caption', media: [feedPhoto], storyMedia: [storyPhoto], extra: _feedAndStory);
      final story = v.asStory();
      expect(story.text, isEmpty);
      expect(story.media.single.id, 'story');
      expect(story.placement, PostPlacement.story);
      final feed = v.asFeed();
      expect(feed.text, 'Caption');
      expect(feed.media.single.id, 'feed');
      expect(feed.placement, PostPlacement.feed);
      // Without copies of its own the story shows the feed media.
      expect(PostVariant(text: '', media: [feedPhoto], extra: _feedAndStory).storyFrames.single.id, 'feed');
    });

    test('the resolver hands the story copies listed on the target to the adapter', () {
      final post = Post(
        id: 'p',
        text: 'Hi',
        createdAt: testNow,
        updatedAt: testNow,
        media: [fakeImage(id: 'a'), fakeImage(id: 'b')],
        targets: const [PostTarget(accountId: 'acct-1', overrides: PostOverrides(mediaIds: ['a'], storyMediaIds: ['b'], extra: _feedAndStory))],
      );
      final v = const VariantResolver().resolve(post, post.targets.single, InstagramAdapter().descriptor);
      expect(v.media.map((m) => m.id), ['a']);
      expect(v.storyMedia.map((m) => m.id), ['b']);
    });
  });

  group('Instagram', () {
    final adapter = InstagramAdapter(sleep: (_) async {});
    final account = fakeAccount('instagram', tier: PlatformTier.byokApi, config: {'igUserId': '1784100', 'username': 'neforum_test'});
    final secrets = {
      'access_token': 'LONG',
      'token_type': 'Bearer',
      'expires_at': testNow.add(const Duration(days: 50)).toIso8601String(),
      'refreshed_at': testNow.subtract(const Duration(days: 1)).toIso8601String(),
    };

    test('Post + Story: the feed post keeps its caption and 4:5 rule, the story its 60 s limit, each on its own', () {
      // A 9:16 photo is fine for the story but not for the feed.
      final tall = PostVariant(text: 'Caption', media: [fakeImage(width: 1080, height: 1920)], extra: _feedAndStory);
      final issues = adapter.validate(tall, account);
      expect(issues.where((i) => i.isError).map((i) => i.code), ['instagram.aspect_ratio']);
      expect(issues.where((i) => i.code == 'instagram.story_no_caption'), isEmpty, reason: 'the caption goes on the feed post');

      // A 2-minute Reel is fine for the feed but too long for the story.
      final reel = PostVariant(text: 'Caption', media: [fakeVideo(durationMs: 120000)], extra: _feedAndStory);
      final errors = adapter.validate(reel, account).where((i) => i.isError).toList();
      expect(errors.map((i) => i.code), ['instagram.story_video_too_long']);
      expect(errors.single.message, startsWith('Story: '));

      // The story's own 9:16 copy leaves the 4:5 feed photo alone.
      final fitted = PostVariant(
          text: 'Caption',
          media: [fakeImage(id: 'feed', width: 1080, height: 1350)],
          storyMedia: [fakeImage(id: 'story', width: 1080, height: 1920)],
          extra: _feedAndStory);
      expect(adapter.validate(fitted, account).hasErrors, isFalse);
    });

    test('Post + Story publishes the feed post, then one STORIES container per frame, and records every id', () async {
      final calls = <http.Request>[];
      var container = 0;
      var published = 0;
      final host = FakeMediaHost();
      final ctx = testContext(
        mediaHost: host,
        handler: (r) async {
          calls.add(r);
          final p = r.url.path;
          if (p == '/v25.0/1784100/media') return _json({'id': 'C${++container}'});
          if (p == '/v25.0/1784100/media_publish') return _json({'id': 'M${++published}'});
          if (p == '/v25.0/M1') return _json({'permalink': 'https://www.instagram.com/p/feed/'});
          return _json({'status_code': 'FINISHED'});
        },
      );
      final v = PostVariant(
        text: 'Caption',
        media: [fakeImage(id: 'feed', width: 1080, height: 1350)],
        storyMedia: [fakeImage(id: 's1', width: 1080, height: 1920), fakeImage(id: 's2', width: 1080, height: 1920)],
        extra: _feedAndStory,
      );
      final res = await adapter.publish(v, account, secrets, ctx);

      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteId, 'M1');
      expect(res.remoteUrl, 'https://www.instagram.com/p/feed/');
      expect(res.additionalRemoteIds, ['M2', 'M3']);
      expect(res.allRemoteIds, ['M1', 'M2', 'M3']);
      expect(host.uploaded.map((m) => m.id), ['feed', 's1', 's2']);
      expect(host.deleted, hasLength(3));

      final creates = calls.where((c) => c.url.path.endsWith('/media')).map(bodyOf).toList();
      expect(creates, [
        {'image_url': 'https://cdn.example.test/feed', 'caption': 'Caption', 'alt_text': 'A test image'},
        {'media_type': 'STORIES', 'image_url': 'https://cdn.example.test/s1'},
        {'media_type': 'STORIES', 'image_url': 'https://cdn.example.test/s2'},
      ]);
      final publishes = calls.where((c) => c.url.path.endsWith('/media_publish')).map(bodyOf).toList();
      expect(publishes, [
        {'creation_id': 'C1'},
        {'creation_id': 'C2'},
        {'creation_id': 'C3'},
      ]);
    });

    test('a story of several photos posts one frame each; the first id is the result, the others are recorded', () async {
      var published = 0;
      final bodies = <Map<String, dynamic>>[];
      final ctx = testContext(
        mediaHost: FakeMediaHost(),
        handler: (r) async {
          if (r.url.path.endsWith('/media')) {
            bodies.add(bodyOf(r));
            return _json({'id': 'C${bodies.length}'});
          }
          if (r.url.path.endsWith('/media_publish')) return _json({'id': 'S${++published}'});
          return _json({'status_code': 'FINISHED'});
        },
      );
      final v = PostVariant(text: '', media: [fakeImage(id: 'a'), fakeVideo(id: 'b')], extra: _story);
      final res = await adapter.publish(v, account, secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteId, 'S1');
      expect(res.additionalRemoteIds, ['S2']);
      expect(bodies, [
        {'media_type': 'STORIES', 'image_url': 'https://cdn.example.test/a'},
        {'media_type': 'STORIES', 'video_url': 'https://cdn.example.test/b'},
      ]);
    });

    test('a story frame that fails after the feed post went live keeps the live ids and is not retryable', () async {
      var published = 0;
      final ctx = testContext(
        mediaHost: FakeMediaHost(),
        handler: (r) async {
          final p = r.url.path;
          if (p.endsWith('/media')) return bodyOf(r)['media_type'] == 'STORIES' ? _json({'error': {'message': 'boom', 'code': 2}}, 500) : _json({'id': 'C1'});
          if (p.endsWith('/media_publish')) return _json({'id': 'M${++published}'});
          return _json({'status_code': 'FINISHED'});
        },
      );
      final v = PostVariant(text: 'Caption', media: [fakeImage(width: 1080, height: 1350)], extra: _feedAndStory);
      final res = await adapter.publish(v, account, secrets, ctx);
      expect(res.success, isFalse);
      expect(res.remoteId, 'M1');
      expect(res.error!.retryable, isFalse);
      expect(res.error!.message, contains('already live on Instagram (M1)'));
    });

    test('hand-off for Post + Story says to share once more as a story', () {
      final plan = adapter.buildHandoff(PostVariant(text: 'Caption', media: [fakeImage()], extra: _feedAndStory));
      expect(plan.instructions, contains('pick **Story**'));
      expect(plan.clipboardText, 'Caption');
    });
  });

  group('Facebook Page stories', () {
    final adapter = FacebookAdapter();
    final account = fakeAccount('facebook',
        tier: PlatformTier.byokApi, config: {'page_id': '123', 'app_id': '987654321', 'page_name': 'My Page'});
    const secrets = {'access_token': 'PAGE_TOKEN', 'app_secret': 'APPSECRET'};

    test('only the API tier offers stories', () {
      expect(adapter.supportsStories(account), isTrue);
      expect(adapter.supportsStories(fakeAccount('facebook', tier: PlatformTier.handoff)), isFalse);
    });

    test('story rules: needs a file, videos 3-60 s, and Facebook cannot hold a story', () {
      List<String> errors(PostVariant v) => adapter.validate(v, account).where((i) => i.isError).map((i) => i.code).toList();
      expect(errors(const PostVariant(text: 'words', extra: _story)), contains('facebook.story_media'));
      expect(errors(PostVariant(text: '', media: [fakeVideo(durationMs: 61000)], extra: _story)), ['facebook.story_video_too_long']);
      expect(errors(PostVariant(text: '', media: [fakeVideo(durationMs: 2000)], extra: _story)), ['facebook.story_video_too_short']);
      // Several videos are several frames, not a refused Page post.
      expect(errors(PostVariant(text: '', media: [fakeVideo(id: 'a'), fakeVideo(id: 'b')], extra: _story)), isEmpty);
      // A text post can be the feed copy of Post + Story only when the story has a file.
      expect(errors(PostVariant(text: 'Hi', media: [fakeImage()], extra: _feedAndStory)), isEmpty);
      final held = PostVariant(text: 'Hi', media: [fakeImage()], extra: _feedAndStory, scheduledAt: testNow.add(const Duration(days: 1)));
      expect(errors(held), contains('schedule.story'));
    });

    test('Post + Story: Page photo post, then an unpublished photo and photo_stories, then a video story in three phases',
        () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        final p = r.url.path;
        if (p == '/v25.0/123/photos') {
          final fields = multipartFieldsOf(r);
          return fields['published'] == 'false' ? _json({'id': 'PH2'}) : _json({'id': 'PH1', 'post_id': '123_9'});
        }
        if (p == '/v25.0/123/photo_stories') return _json({'success': true, 'post_id': 'ST1'});
        if (p == '/v25.0/123/video_stories') {
          return bodyOf(r)['upload_phase'] == 'start'
              ? _json({'video_id': 'V1', 'upload_url': 'https://rupload.facebook.com/video-upload/v25.0/V1'})
              : _json({'success': true, 'post_id': 'ST2'});
        }
        if (r.url.host == 'rupload.facebook.com') return _json({'success': true});
        return _json({}, 404);
      });
      final v = PostVariant(
        text: 'Caption',
        media: [fakeImage(id: 'feed')],
        storyMedia: [fakeImage(id: 'frame'), fakeVideo(id: 'clip')],
        extra: _feedAndStory,
      );
      final res = await adapter.publish(v, account, secrets, ctx);

      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteId, '123_9');
      expect(res.additionalRemoteIds, ['ST1', 'ST2']);
      expect(calls.map((c) => '${c.method} ${c.url.host == 'rupload.facebook.com' ? 'rupload' : c.url.path}'), [
        'POST /v25.0/123/photos',
        'POST /v25.0/123/photos',
        'POST /v25.0/123/photo_stories',
        'POST /v25.0/123/video_stories',
        'POST rupload',
        'POST /v25.0/123/video_stories',
      ]);
      expect(multipartFieldsOf(calls[0])['caption'], 'Caption');
      expect(multipartFieldsOf(calls[1])['published'], 'false');
      expect(multipartFieldsOf(calls[1]).containsKey('caption'), isFalse, reason: 'stories have no caption');
      expect(bodyOf(calls[2])['photo_id'], 'PH2');
      expect(bodyOf(calls[3])['upload_phase'], 'start');
      final upload = calls[4];
      expect(upload.headers['Authorization'], 'OAuth PAGE_TOKEN');
      expect(upload.headers['offset'], '0');
      expect(upload.headers['file_size'], '${fakeJpegBytes.length}');
      expect(upload.bodyBytes, fakeJpegBytes);
      expect(bodyOf(calls[5]), containsPair('upload_phase', 'finish'));
      expect(bodyOf(calls[5]), containsPair('video_id', 'V1'));
    });

    test('removing a held copy deletes every recorded id, stories included', () async {
      final deleted = <String>[];
      final ctx = testContext(handler: (r) async {
        expect(r.method, 'DELETE');
        deleted.add(r.url.pathSegments.last);
        return deleted.length == 2 ? _json({}, 404) : _json({'success': true});
      });
      final held = PublishResult.ok(remoteId: '123_9', additionalRemoteIds: const ['ST1', 'ST2']);
      await adapter.cancelScheduled(held, account, secrets, ctx);
      expect(deleted, ['123_9', 'ST1', 'ST2'], reason: 'a copy that is already gone counts as removed');
    });
  });

  group('PublishResult', () {
    test('additional ids survive a JSON round trip, also on a partial failure', () {
      final ok = PublishResult.fromJson(PublishResult.ok(remoteId: 'M1', additionalRemoteIds: const ['S1']).toJson());
      expect(ok.additionalRemoteIds, ['S1']);
      final partial = PublishResult.fromJson(PublishResult.partialFailure(const PublishError.platform('story failed'),
              remoteId: 'M1', additionalRemoteIds: const ['S1'])
          .toJson());
      expect(partial.success, isFalse);
      expect(partial.allRemoteIds, ['M1', 'S1']);
      // Results saved by 1.2 have none.
      expect(PublishResult.fromJson(const {'success': true, 'remoteId': 'X'}).additionalRemoteIds, isEmpty);
    });
  });
}
