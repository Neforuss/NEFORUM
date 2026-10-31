// 1.3.4: more photos and videos than one post holds are never dropped. They
// are packed into posts by each network's own limits (packMediaIntoPosts),
// as further posts of a thread where every post carries its own media, else
// as a series of separate posts after the first.

import 'dart:math';

import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

MediaAttachment _photo(int i) => fakeImage(id: 'p$i');
MediaAttachment _video(int i) => fakeVideo(id: 'v$i');

/// The fewest posts any split of [media] that keeps its order can have,
/// found by trying every split (dynamic programming): the check on
/// [packMediaIntoPosts] that does not share its logic.
int _fewestPosts(List<MediaAttachment> media, MediaRules rules) {
  bool fitsOnePost(List<MediaAttachment> group) {
    final videos = group.where((m) => m.isVideo).length;
    final images = group.length - videos;
    if (videos > rules.maxVideos || images > rules.maxImages) return false;
    return rules.allowsMixedImageVideo || videos == 0 || images == 0;
  }

  final best = List<int?>.filled(media.length + 1, null);
  best[0] = 0;
  for (var end = 1; end <= media.length; end++) {
    for (var start = 0; start < end; start++) {
      final before = best[start];
      if (before == null || !fitsOnePost(media.sublist(start, end))) continue;
      if (best[end] == null || before + 1 < best[end]!) best[end] = before + 1;
    }
  }
  return best[media.length]!;
}

Post _post(String text, List<MediaAttachment> media, {String accountId = 'acct-1', PostOverrides overrides = const PostOverrides()}) => Post(
      id: 'p',
      text: text,
      media: media,
      createdAt: testNow,
      updatedAt: testNow,
      targets: [PostTarget(accountId: accountId, overrides: overrides)],
    );

/// The tier through which [d] posts without the user's help, else null.
PlatformTier? _automaticTier(PlatformDescriptor d) => d.tiers.where((t) => t.isAutomatic).firstOrNull;

void main() {
  group('packMediaIntoPosts', () {
    test('every file once, in order, every post within the limits, and the fewest posts (2000 random cases)', () {
      final random = Random(1304);
      for (var round = 0; round < 2000; round++) {
        final rules = MediaRules(
          maxImages: 1 + random.nextInt(10),
          maxVideos: 1 + random.nextInt(4),
          allowsMixedImageVideo: random.nextBool(),
        );
        final media = [
          for (var i = 0; i < random.nextInt(41); i++) random.nextInt(4) == 0 ? _video(i) : _photo(i),
        ];
        final groups = packMediaIntoPosts(media, rules);
        final reason = 'round $round: ${rules.maxImages} photos/${rules.maxVideos} videos, mixed ${rules.allowsMixedImageVideo}, '
            '${media.map((m) => m.isVideo ? 'v' : 'p').join()}';
        expect([for (final g in groups) ...g], media, reason: '$reason: every file once, in order');
        expect(groups.every((g) => g.isNotEmpty), isTrue, reason: reason);
        for (final g in groups) {
          final videos = g.where((m) => m.isVideo).length;
          expect(videos, lessThanOrEqualTo(rules.maxVideos), reason: reason);
          expect(g.length - videos, lessThanOrEqualTo(rules.maxImages), reason: reason);
          if (!rules.allowsMixedImageVideo) expect(videos == 0 || videos == g.length, isTrue, reason: '$reason: not mixed');
        }
        expect(groups.length, _fewestPosts(media, rules), reason: '$reason: the fewest posts');
      }
    });

    test('twenty photos on X: five posts of four', () {
      final groups = packMediaIntoPosts([for (var i = 0; i < 20; i++) _photo(i)], const MediaRules(maxImages: 4, maxVideos: 1));
      expect(groups.map((g) => g.length), [4, 4, 4, 4, 4]);
    });

    test('photos and videos that do not mix: each video gets a post of its own, the photos around it stay together', () {
      final media = [_photo(0), _photo(1), _video(2), _photo(3), _photo(4), _photo(5), _photo(6), _photo(7), _video(8)];
      final groups = packMediaIntoPosts(media, const MediaRules(maxImages: 4, maxVideos: 1));
      expect(groups.map((g) => g.map((m) => m.id).join(',')), ['p0,p1', 'v2', 'p3,p4,p5,p6', 'p7', 'v8']);
    });

    test('a sound file counted as a video takes a video\'s place', () {
      final sound = MediaAttachment(id: 's', path: '/s.mp3', mimeType: 'audio/mpeg', sizeBytes: 9);
      final groups = packMediaIntoPosts([_photo(0), sound], const MediaRules(maxImages: 4, maxVideos: 1), isVideo: (m) => m.isVideo || m.isAudio);
      expect(groups.map((g) => g.map((m) => m.id).join(',')), ['p0', 's']);
    });

    test('nothing to pack, no posts', () {
      expect(packMediaIntoPosts(const [], const MediaRules(maxImages: 4)), isEmpty);
    });
  });

  group('twenty photos on every network NEFORUM has', () {
    final photos = [for (var i = 0; i < 20; i++) _photo(i)];
    final adapters = builtinAdapters();
    for (final adapter in adapters) {
      final tier = _automaticTier(adapter.descriptor);
      if (tier == null) continue; // hand-off only: see the hand-off test
      test('${adapter.descriptor.name}: every photo goes, within its limits', () {
        final account = fakeAccount(adapter.descriptor.id, tier: tier);
        final d = adapter.descriptorForAccount(account);
        final post = _post('Holiday', photos);
        final v = const VariantResolver().resolve(post, post.targets.single, d, account: account);
        final m = d.media;
        if (m.maxImages == 0) {
          // A network for videos only: the photos cannot go, and it says so.
          expect(v.media, isEmpty);
          expect(v.issues.firstWhere((i) => i.code == 'media.dropped').message, contains('takes no photos'));
          return;
        }
        expect(v.issues.where((i) => i.code == 'media.dropped'), isEmpty, reason: 'nothing dropped');
        final perPost = m.maxImages;
        final posts = (20 / perPost).ceil();
        final threaded = d.text.supportsThreads && m.mediaPerThreadPart;
        if (threaded) {
          expect(v.threadParts, hasLength(posts), reason: 'a thread of $posts posts');
          expect([for (var i = 0; i < posts; i++) ...v.mediaOfPart(i)], photos, reason: 'in order');
          expect(v.seriesPosts, isEmpty);
        } else {
          expect(v.seriesPosts, hasLength(posts - 1), reason: '${posts - 1} more posts after the first');
          expect([...v.media, for (final s in v.seriesPosts) ...s.media], photos, reason: 'in order');
          expect(v.issues.map((i) => i.code), posts > 1 ? contains('media.series') : isNot(contains('media.series')));
        }
        for (final group in [...v.mediaGroups, for (final s in v.seriesPosts) s.media]) {
          expect(group.length, lessThanOrEqualTo(perPost));
        }
        for (final check in [v, ...v.seriesPosts]) {
          final tooMany = RulesValidator.validate(check, d).where((i) => i.code.startsWith('media.too_many'));
          expect(tooMany, isEmpty, reason: 'every post passes its own media check');
        }
      });
    }

    test('a hand-off is one post: what does not fit is left out with a warning, never silently', () {
      final x = adapters.firstWhere((a) => a.descriptor.id == 'x');
      final account = fakeAccount('x', tier: PlatformTier.handoff);
      final post = _post('Holiday', photos);
      final v = const VariantResolver().resolve(post, post.targets.single, x.descriptorForAccount(account), account: account);
      expect(v.media, hasLength(4));
      expect(v.seriesPosts, isEmpty);
      expect(v.threadParts, isEmpty);
      expect(v.issues.firstWhere((i) => i.code == 'media.left_out').message, contains('16 more file(s)'));
    });
  });

  group('numbering', () {
    final x = builtinAdapters().firstWhere((a) => a.descriptor.id == 'x').descriptor;
    final photos = [for (var i = 0; i < 20; i++) _photo(i)];

    test('the posts of media only count in the thread\'s numbers', () {
      final post = _post('Holiday', photos);
      final v = const VariantResolver().resolve(post, post.targets.single, x, account: fakeAccount('x', tier: PlatformTier.byokApi));
      expect(v.threadParts, ['Holiday (1/5)', '(2/5)', '(3/5)', '(4/5)', '(5/5)']);
      expect(v.text, 'Holiday (1/5)');
    });

    test('without numbering the posts of media only have no text', () {
      final post = _post('Holiday', photos);
      final v = const VariantResolver(ResolverOptions(threadNumbering: false))
          .resolve(post, post.targets.single, x, account: fakeAccount('x', tier: PlatformTier.byokApi));
      expect(v.threadParts, ['Holiday', '', '', '', '']);
    });

    test('a long text split into a thread keeps every post within the limit with the longer numbers', () {
      // Two posts of words, then ten more of photos: every number is two digits.
      final words = List.filled(70, 'sunshine').join(' ');
      final post = _post(words, [for (var i = 0; i < 44; i++) _photo(i)]);
      final v = const VariantResolver().resolve(post, post.targets.single, x, account: fakeAccount('x', tier: PlatformTier.byokApi));
      expect(v.threadParts.length, greaterThanOrEqualTo(11));
      final n = v.threadParts.length;
      for (var i = 0; i < n; i++) {
        expect(v.threadParts[i], endsWith('(${i + 1}/$n)'));
        expect(TextCounter.fits(v.threadParts[i], x.text), isTrue, reason: 'post ${i + 1} fits');
      }
      expect(v.media, hasLength(44));
    });

    test('a series numbers its posts and its titles; later posts are feed posts only', () {
      final instagram = builtinAdapters().firstWhere((a) => a.descriptor.id == 'instagram').descriptor;
      final post = _post('Holiday', photos, overrides: const PostOverrides(extra: {kPlacementKey: 'feedAndStory'}));
      final v = const VariantResolver().resolve(post, post.targets.single, instagram, account: fakeAccount('instagram', tier: PlatformTier.byokApi));
      expect(v.text, 'Holiday (1/2)');
      expect(v.media, hasLength(10));
      expect(v.seriesPosts.single.text, '(2/2)');
      expect(v.seriesPosts.single.media.map((m) => m.id), [for (var i = 10; i < 20; i++) 'p$i']);
      expect(v.extra[kPlacementKey], 'feedAndStory', reason: 'the story goes with the first post');
      expect(v.seriesPosts.single.extra.containsKey(kPlacementKey), isFalse);
    });

    test('titles of a series are numbered and kept within the title limit', () {
      final reddit = builtinAdapters().firstWhere((a) => a.descriptor.id == 'reddit').descriptor;
      final title = List.filled(40, 'trip').join(' '); // 199 characters
      final post = _post('Holiday', [for (var i = 0; i < 30; i++) _photo(i)]).copyWith(title: title);
      final v = const VariantResolver().resolve(post, post.targets.single, reddit, account: fakeAccount('reddit', tier: PlatformTier.byokApi));
      expect(v.title, endsWith('(1/2)'));
      expect(v.seriesPosts.single.title, endsWith('(2/2)'));
      for (final t in [v.title!, v.seriesPosts.single.title!]) {
        expect(t.length, lessThanOrEqualTo(reddit.text.titleMax!));
      }
    });
  });

  test('with dropUnsupportedMedia off everything stays in the one post, as before', () {
    final x = builtinAdapters().firstWhere((a) => a.descriptor.id == 'x').descriptor;
    final post = _post('Holiday', [for (var i = 0; i < 6; i++) _photo(i)]);
    final v = const VariantResolver(ResolverOptions(dropUnsupportedMedia: false))
        .resolve(post, post.targets.single, x, account: fakeAccount('x', tier: PlatformTier.byokApi));
    expect(v.media, hasLength(6));
    expect(v.threadParts, isEmpty);
  });
}
