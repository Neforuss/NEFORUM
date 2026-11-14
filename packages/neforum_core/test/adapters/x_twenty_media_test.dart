// 1.4.3: X takes up to 20 photos and videos in one post (its create-post
// schema says media_ids maxItems 20; its prose still says 4 photos or 1 video,
// so it is unverified). NEFORUM tries the large post, and when X refuses it,
// posts the same post at once as a thread of 4 photos or 1 video per post,
// remembers the refusal for the account for 7 days, and tries again after.
// Every request here goes to a fake X.

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/x/x_adapter.dart';
import 'package:neforum_core/src/adapters/x/x_media_capacity.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: jsonHeaders);

/// X's answer to a post with more media than it takes, in the shape of its
/// other parameter errors (problem type invalid-request, the parameter named).
http.Response _tooMany(int n) => _json({
      'errors': [
        {
          'parameters': {'media.media_ids': List.generate(n, (i) => 'm${i + 1}')},
          'message': 'size must be between 1 and 4',
        },
      ],
      'title': 'Invalid Request',
      'detail': 'One or more parameters to your request was invalid.',
      'type': 'https://api.twitter.com/2/problems/invalid-request',
    }, 400);

ConnectedAccount _account({Map<String, dynamic> extra = const {}, PlatformTier tier = PlatformTier.byokApi}) => ConnectedAccount(
      id: 'x-42',
      platformId: 'x',
      tier: tier,
      displayName: 'Alice (@alice)',
      handle: '@alice',
      createdAt: testNow,
      config: {'authMode': 'oauth2', 'clientId': 'cid', 'userId': '42', ...extra},
    );

Map<String, dynamic> _record(String result, DateTime at) => {
      XMediaCapacity.configKey: {'result': result, 'at': at.toUtc().toIso8601String()},
    };

Map<String, String> _secrets(DateTime now) => {
      'access_token': 'at-1',
      'refresh_token': 'rt-1',
      'expires_at': now.add(const Duration(days: 30)).toUtc().toIso8601String(),
      'token_type': 'bearer',
    };

MediaAttachment _photo(int i) => fakeImage(id: 'p$i');
MediaAttachment _video(int i) => fakeVideo(id: 'v$i', sizeBytes: 64);
MediaAttachment _gif(int i) => fakeImage(id: 'g$i', mimeType: 'image/gif');

/// Photos with a video every fourth item: [n] items in all.
List<MediaAttachment> _mixed(int n) => [for (var i = 0; i < n; i++) i % 4 == 3 ? _video(i) : _photo(i)];

/// A fake X: uploads get ids m1, m2... in the order they arrive; posts get
/// t1, t2... Posts whose media X does not take while [refusesLarge] are
/// refused the way X refuses a parameter.
class _FakeX {
  bool refusesLarge = false;
  final requests = <http.Request>[];
  var _media = 0;
  var _posts = 0;

  List<Map<String, dynamic>> get creates => [for (final r in requests) if (r.url.path == '/2/tweets') bodyOf(r)];
  List<List<String>> get createdMedia => [for (final c in creates) [...?((c['media'] as Map?)?['media_ids'] as List?)?.cast<String>()]];
  int get uploads => requests.where((r) => r.url.path == '/2/media/upload' && r.method == 'POST' || r.url.path == '/2/media/upload/initialize').length;

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    final p = r.url.path;
    if (r.url.host != 'api.x.com') throw StateError('not X: ${r.url}');
    if (p == '/2/media/upload' && r.method == 'POST' || p == '/2/media/upload/initialize') {
      return _json({
        'data': {'id': 'm${++_media}'},
      });
    }
    if (p.endsWith('/append')) return http.Response('', 204);
    if (p.endsWith('/finalize')) {
      return _json({
        'data': {'id': p.split('/')[4]},
      });
    }
    if (p == '/2/media/metadata') return _json({'data': <String, Object>{}});
    if (p == '/2/tweets') {
      final ids = ((bodyOf(r)['media'] as Map?)?['media_ids'] as List?) ?? const [];
      if (refusesLarge && ids.length > 4) return _tooMany(ids.length);
      return _json({
        'data': {'id': 't${++_posts}'},
      }, 201);
    }
    return _json({'title': 'Not Found'}, 404);
  }
}

void main() {
  group('capacity: one place says how many media one X post takes', () {
    final now = testNow;

    test('an API account takes 20 photos and videos, mixed; a hand-off 4 photos or 1 video', () {
      final x = XAdapter(clock: () => now);
      final large = x.descriptorForAccount(_account()).media;
      expect(large.maxItems, 20);
      expect(large.allowsMixedImageVideo, isTrue);
      expect(large.gifAlone, isTrue);
      final handoff = x.descriptorForAccount(_account(tier: PlatformTier.handoff)).media;
      expect(handoff.maxImages, 4);
      expect(handoff.maxVideos, 1);
      expect(handoff.allowsMixedImageVideo, isFalse);
      expect(identical(x.descriptor.media, XMediaCapacity.classic), isTrue);
      expect(identical(large, XMediaCapacity.large), isTrue);
    });

    test('a refusal sends the account back to 4 for 7 days; then it tries 20 again', () {
      final x = XAdapter(clock: () => now);
      bool large(Map<String, dynamic> record) => x.descriptorForAccount(_account(extra: record)).media.maxItems == 20;
      expect(large(_record('refused', now.subtract(const Duration(days: 1)))), isFalse);
      expect(large(_record('refused', now.subtract(const Duration(days: 6, hours: 23)))), isFalse);
      expect(large(_record('refused', now.subtract(const Duration(days: 7)))), isTrue);
      expect(large(_record('accepted', now.subtract(const Duration(hours: 1)))), isTrue);
      expect(large(const {}), isTrue, reason: 'nothing known: assumed to take 20');
      expect(large({XMediaCapacity.configKey: 'garbage'}), isTrue);
      // A device whose clock ran ahead: a few hours count, days do not.
      expect(large(_record('refused', now.add(const Duration(hours: 3)))), isFalse);
      expect(large(_record('refused', now.add(const Duration(days: 3)))), isTrue);
    });

    test('days until the next try are whole days, at least one', () {
      expect(XMediaCapacity.daysUntilRetry(_account(extra: _record('refused', now)), now), 7);
      expect(XMediaCapacity.daysUntilRetry(_account(extra: _record('refused', now.subtract(const Duration(days: 6, hours: 23)))), now), 1);
      expect(XMediaCapacity.daysUntilRetry(_account(extra: _record('accepted', now)), now), isNull);
      expect(XMediaCapacity.daysUntilRetry(_account(), now), isNull);
    });

    test('which refusals are about the media', () {
      HttpFailure failure(int status, Object body) =>
          HttpFailure(NeforumResponse(status, jsonHeaders, utf8.encode(jsonEncode(body)), Uri.parse('https://api.x.com/2/tweets')));
      bool refuses(int status, Object body) => XMediaCapacity.refusesLargePost(failure(status, body));
      expect(XMediaCapacity.refusesLargePost(HttpFailure(NeforumResponse(400, jsonHeaders, utf8.encode(_tooMany(6).body), Uri.parse('https://api.x.com/2/tweets')))), isTrue);
      expect(refuses(400, {'errors': [{'message': 'Your media IDs are invalid.'}], 'title': 'Invalid Request'}), isTrue);
      expect(refuses(403, {'detail': 'You cannot attach more than 4 media to a post.', 'title': 'Forbidden', 'status': 403}), isTrue);
      expect(refuses(422, {'detail': 'Invalid media combination'}), isTrue);
      expect(refuses(400, {'title': 'Invalid Request', 'detail': 'One or more parameters to your request was invalid.'}), isTrue,
          reason: 'an unknown validation refusal of a large post');
      // Not about the media: these go on as they are.
      expect(refuses(403, {'detail': 'You are not allowed to create a Tweet with duplicate content.', 'title': 'Forbidden'}), isFalse);
      expect(refuses(403, {'detail': 'You are not permitted to perform this action.', 'title': 'Forbidden'}), isFalse);
      expect(refuses(400, {'errors': [{'parameters': {'text': ['x']}, 'message': 'text is too long'}], 'title': 'Invalid Request'}), isFalse);
      expect(refuses(401, {'detail': 'Unauthorized media'}), isFalse);
      expect(refuses(429, {'detail': 'Too Many Requests'}), isFalse);
      expect(refuses(503, {'detail': 'media service unavailable'}), isFalse);
    });

    test('classic posts: 4 photos, or 1 video, or 1 GIF', () {
      expect(XMediaCapacity.fitsClassicPost([for (var i = 0; i < 4; i++) _photo(i)]), isTrue);
      expect(XMediaCapacity.fitsClassicPost([for (var i = 0; i < 5; i++) _photo(i)]), isFalse);
      expect(XMediaCapacity.fitsClassicPost([_photo(0), _video(1)]), isFalse);
      expect(XMediaCapacity.fitsClassicPost([_video(0), _video(1)]), isFalse);
      expect(XMediaCapacity.fitsClassicPost([_gif(0)]), isTrue);
    });
  });

  group('the plan and the preview', () {
    final now = testNow;
    final x = XAdapter(clock: () => now);
    Post post(List<MediaAttachment> media) =>
        Post(id: 'p', text: 'Holiday', media: media, createdAt: now, updatedAt: now, targets: const [PostTarget(accountId: 'x-42')]);
    PostVariant plan(List<MediaAttachment> media, ConnectedAccount a) {
      final p = post(media);
      return const VariantResolver().resolve(p, p.targets.single, x.descriptorForAccount(a), account: a);
    }

    List<ValidationIssue> checked(PostVariant v, ConnectedAccount a) => [...v.issues, ...x.validate(v, a)];

    test('20 photos and videos: one post, in order, nothing flagged, and the preview says why', () {
      final media = _mixed(20);
      final v = plan(media, _account());
      expect(v.threadParts, isEmpty);
      expect(v.text, 'Holiday');
      expect(v.media, media);
      final issues = checked(v, _account());
      expect(issues.hasErrors, isFalse, reason: issues.map((i) => i.message).join('; '));
      expect(issues.map((i) => i.code).where((c) => c.startsWith('media.too_many') || c == 'media.mixed' || c == 'media.threaded'), isEmpty);
      final line = issues.singleWhere((i) => i.code == 'x.media_one_post');
      expect(line.severity, IssueSeverity.info);
      expect(line.message, 'X now takes up to 20 photos and videos in one post: these 20 go in one post. If X refuses them for '
          'this account, NEFORUM sends them as a thread right away.');
    });

    test('an account X took 20 from: the line says so', () {
      final a = _account(extra: _record('accepted', now.subtract(const Duration(days: 30))));
      final line = checked(plan(_mixed(6), a), a).singleWhere((i) => i.code == 'x.media_one_post');
      expect(line.message, 'X takes up to 20 photos and videos in one post for this account: these 6 go in one post.');
    });

    test('21: a post of 20 and a reply of 1', () {
      final media = _mixed(21);
      final v = plan(media, _account());
      expect(v.threadParts, ['Holiday (1/2)', '(2/2)']);
      expect(v.mediaOfPart(0), media.sublist(0, 20));
      expect(v.mediaOfPart(1), media.sublist(20));
      expect(checked(v, _account()).hasErrors, isFalse);
      // The check holds each post to 20.
      expect(x.validate(PostVariant(text: 'x', media: media), _account()).map((i) => i.code), contains('media.too_many'));
    });

    test('refused within 7 days: the classic thread, and the line says why', () {
      final a = _account(extra: _record('refused', now.subtract(const Duration(days: 2))));
      final media = [for (var i = 0; i < 20; i++) _photo(i)];
      final v = plan(media, a);
      expect(v.threadParts, ['Holiday (1/5)', '(2/5)', '(3/5)', '(4/5)', '(5/5)']);
      expect([for (var i = 0; i < 5; i++) v.mediaOfPart(i).length], [4, 4, 4, 4, 4]);
      final issues = checked(v, a);
      expect(issues.hasErrors, isFalse);
      expect(issues.singleWhere((i) => i.code == 'x.media_thread').message,
          'X refused more than 4 photos, more than one video, or photos with a video, in one post for this account; sent '
          'as a thread. NEFORUM tries one post again in 5 days.');
      expect(issues.map((i) => i.code), isNot(contains('x.media_one_post')));
    });

    test('two videos are a large post too, and the line names that case', () {
      final a = _account(extra: _record('refused', now.subtract(const Duration(days: 2))));
      final v = plan([_video(0), _video(1)], a);
      expect([for (var i = 0; i < v.threadParts.length; i++) v.mediaOfPart(i).length], [1, 1], reason: 'one video per post');
      final line = checked(v, a).singleWhere((i) => i.code == 'x.media_thread').message;
      expect(line, contains('more than one video'));
    });

    test('media that fits a classic post needs no line', () {
      for (final a in [_account(), _account(extra: _record('refused', now))]) {
        final v = plan([_photo(0), _photo(1)], a);
        expect(checked(v, a).map((i) => i.code), isNot(anyOf(contains('x.media_one_post'), contains('x.media_thread'))));
      }
    });

    test('an animated GIF goes in a post of its own, in both packings', () {
      final media = [_photo(0), _photo(1), _gif(2), _photo(3)];
      for (final a in [_account(), _account(extra: _record('refused', now))]) {
        final v = plan(media, a);
        expect([for (var i = 0; i < v.threadParts.length; i++) v.mediaOfPart(i).map((m) => m.id).join(',')], ['p0,p1', 'g2', 'p3']);
        expect(checked(v, a).hasErrors, isFalse, reason: 'no x.gif_alone');
      }
    });

    test('a hand-off stays at 4 per post', () {
      final a = _account(tier: PlatformTier.handoff);
      final v = plan([for (var i = 0; i < 6; i++) _photo(i)], a);
      expect(v.media, hasLength(4));
      expect(checked(v, a).map((i) => i.code), isNot(contains('x.media_one_post')));
    });
  });

  group('publishing', () {
    late DateTime now;
    late _FakeX fake;
    late InMemoryAccountRepository accounts;
    late InMemoryPostRepository posts;
    late PublishService service;

    PublishService serviceWith(Future<http.Response> Function(http.Request r) handler, SecretStore secrets) => PublishService(
          registry: AdapterRegistry([XAdapter(clock: () => now)]),
          accounts: accounts,
          posts: posts,
          secrets: secrets,
          quota: QuotaTracker(InMemoryQuotaRepository()),
          http: NeforumHttp(client: MockClient(handler), maxRetries: 0),
          clock: () => now,
          log: Logger('test', sink: (level, area, msg, [err]) {}),
          readMedia: (m) async => fakeJpegBytes,
        );

    setUp(() async {
      now = testNow;
      fake = _FakeX();
      accounts = InMemoryAccountRepository();
      posts = InMemoryPostRepository();
      final secrets = InMemorySecretStore();
      await secrets.write('x-42', _secrets(now));
      await accounts.upsert(_account());
      service = serviceWith(fake.handle, secrets);
    });

    Future<Post> publish(String id, List<MediaAttachment> media) async {
      await posts.upsert(Post(id: id, text: 'Holiday', media: media, createdAt: now, updatedAt: now, targets: const [PostTarget(accountId: 'x-42')]));
      return service.publish(id);
    }

    Future<XLargeMediaRecord?> record() async => XLargeMediaRecord.fromConfig((await accounts.get('x-42'))!);

    test('20 photos and videos, mixed: one create call with every id in order; the acceptance is recorded', () async {
      final p = await publish('a', _mixed(20));
      final t = p.targets.single;
      expect(t.status, TargetStatus.published, reason: '${t.result?.error}');
      expect(fake.uploads, 20);
      expect(fake.creates, hasLength(1));
      expect(fake.creates.single['text'], 'Holiday');
      expect(fake.createdMedia.single, [for (var i = 1; i <= 20; i++) 'm$i']);
      expect(t.result!.remoteId, 't1');
      expect(t.result!.threadRemoteIds, isEmpty);
      final r = (await record())!;
      expect(r.accepted, isTrue);
      expect(r.at, now);
    });

    test('a refused 6-item post goes out once as a 2-post thread, nothing uploaded twice; the refusal is recorded', () async {
      fake.refusesLarge = true;
      final media = [for (var i = 0; i < 6; i++) _photo(i)];
      final p = await publish('a', media);
      final t = p.targets.single;
      expect(t.status, TargetStatus.published, reason: '${t.result?.error}');
      expect(fake.uploads, 6, reason: 'the uploads are reused');
      expect(fake.creates, hasLength(3), reason: 'the refused try, then the thread');
      expect(fake.createdMedia[0], ['m1', 'm2', 'm3', 'm4', 'm5', 'm6']);
      expect(fake.creates[1], {
        'text': 'Holiday (1/2)',
        'media': {
          'media_ids': ['m1', 'm2', 'm3', 'm4'],
        },
      });
      expect(fake.creates[2], {
        'text': '(2/2)',
        'media': {
          'media_ids': ['m5', 'm6'],
        },
        'reply': {'in_reply_to_tweet_id': 't1'},
      });
      expect(t.result!.remoteId, 't1');
      expect(t.result!.remoteUrl, 'https://x.com/alice/status/t1');
      expect(t.result!.threadRemoteIds, ['t1', 't2']);
      final r = (await record())!;
      expect(r.accepted, isFalse);
      expect(r.at, now);
      // Other config is kept.
      expect((await accounts.get('x-42'))!.config['clientId'], 'cid');
    });

    test('within 7 days the next post goes as a thread without trying 20; after 7 days 20 is tried again', () async {
      fake.refusesLarge = true;
      await publish('a', [for (var i = 0; i < 6; i++) _photo(i)]);
      fake.requests.clear();

      now = testNow.add(const Duration(days: 6));
      var p = await publish('b', [for (var i = 0; i < 6; i++) _photo(i)]);
      expect(p.targets.single.status, TargetStatus.published);
      expect(fake.createdMedia.map((m) => m.length), [4, 2], reason: 'no refused try first');
      fake.requests.clear();

      // X now takes it: tried again, and the acceptance replaces the refusal.
      now = testNow.add(const Duration(days: 7, minutes: 1));
      fake.refusesLarge = false;
      p = await publish('c', [for (var i = 0; i < 6; i++) _photo(i)]);
      expect(p.targets.single.status, TargetStatus.published);
      expect(fake.createdMedia.map((m) => m.length), [6]);
      final r = (await record())!;
      expect(r.accepted, isTrue);
      expect(r.at, now);
    });

    test('a refusal that is not about the media is a plain failure: no thread, nothing recorded', () async {
      final secrets = InMemorySecretStore();
      await secrets.write('x-42', _secrets(now));
      service = serviceWith((r) async {
        if (r.url.path != '/2/tweets') return fake.handle(r);
        fake.requests.add(r);
        return _json({'detail': 'You are not allowed to create a Tweet with duplicate content.', 'title': 'Forbidden', 'status': 403}, 403);
      }, secrets);
      final p = await publish('a', [for (var i = 0; i < 6; i++) _photo(i)]);
      final t = p.targets.single;
      expect(t.status, TargetStatus.failed);
      expect(t.result!.error!.message, contains('duplicate'));
      expect(fake.requests.where((r) => r.url.path == '/2/tweets'), hasLength(1));
      expect(await record(), isNull);
    });
  });

  group('the adapter on its own', () {
    final x = XAdapter(clock: () => testNow);

    test('without a plan to go back to, the rest goes as classic replies; no duplicate', () async {
      final fake = _FakeX()..refusesLarge = true;
      final saved = <Map<String, Object?>>[];
      final ctx = AdapterContext(
        http: NeforumHttp(client: MockClient(fake.handle), maxRetries: 0),
        clock: () => testNow,
        log: Logger('test', sink: (level, area, msg, [err]) {}),
        readMedia: (m) async => fakeJpegBytes,
        onAccountConfig: (changes) async => saved.add(changes),
      );
      final media = [for (var i = 0; i < 6; i++) _photo(i)];
      final r = await x.publish(PostVariant(text: 'Holiday', media: media), _account(), _secrets(testNow), ctx);
      expect(r.success, isTrue, reason: '${r.error}');
      expect(fake.uploads, 6);
      // The replies carry media only: no text at all.
      expect(fake.creates.map((c) => c['text']), ['Holiday', 'Holiday', null]);
      expect(fake.createdMedia, [
        ['m1', 'm2', 'm3', 'm4', 'm5', 'm6'],
        ['m1', 'm2', 'm3', 'm4'],
        ['m5', 'm6'],
      ]);
      expect(fake.creates[2]['reply'], {'in_reply_to_tweet_id': 't1'});
      expect(r.threadRemoteIds, ['t1', 't2']);
      expect(saved, [
        {XMediaCapacity.configKey: {'result': 'refused', 'at': testNow.toIso8601String()}},
      ]);
    });

    test('refused on part 2 of a thread after part 1 is live: part 2 goes on the classic way, part 1 is not posted again', () async {
      final fake = _FakeX()..refusesLarge = true;
      var replans = 0;
      final ctx = AdapterContext(
        http: NeforumHttp(client: MockClient(fake.handle), maxRetries: 0),
        clock: () => testNow,
        log: Logger('test', sink: (level, area, msg, [err]) {}),
        readMedia: (m) async => fakeJpegBytes,
        replan: (a) async {
          replans++;
          return null;
        },
      );
      final second = [for (var i = 1; i < 7; i++) _photo(i)];
      final v = PostVariant(
        text: 'one',
        threadParts: const ['one', 'two', 'three'],
        media: [_photo(0), ...second],
        mediaPartIndexes: [0, for (final _ in second) 1],
      );
      final r = await x.publish(v, _account(), _secrets(testNow), ctx);
      expect(r.success, isTrue, reason: '${r.error}');
      expect(replans, 0, reason: 'part 1 is live: no new plan');
      expect(fake.creates.map((c) => c['text']), ['one', 'two', 'two', null, 'three']);
      expect(fake.createdMedia, [
        ['m1'],
        ['m2', 'm3', 'm4', 'm5', 'm6', 'm7'],
        ['m2', 'm3', 'm4', 'm5'],
        ['m6', 'm7'],
        <String>[],
      ]);
      expect(r.threadRemoteIds, ['t1', 't2', 't3', 't4']);
      expect(fake.creates[4]['reply'], {'in_reply_to_tweet_id': 't3'});
    });

    test('a classic-sized post X refuses for its media is not posted again: the error stands', () async {
      final fake = _FakeX();
      final ctx = AdapterContext(
        http: NeforumHttp(
            client: MockClient((r) async => r.url.path == '/2/tweets' ? _tooMany(4) : await fake.handle(r)), maxRetries: 0),
        clock: () => testNow,
        log: Logger('test', sink: (level, area, msg, [err]) {}),
        readMedia: (m) async => fakeJpegBytes,
        replan: (a) async => throw StateError('no new plan expected'),
      );
      final r = await x.publish(PostVariant(text: 'Four', media: [for (var i = 0; i < 4; i++) _photo(i)]), _account(), _secrets(testNow), ctx);
      expect(r.success, isFalse);
      expect(r.error!.kind, PublishErrorKind.validation);
    });
  });
}
