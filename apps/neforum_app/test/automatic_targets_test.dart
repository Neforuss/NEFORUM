// 1.4.3: "Automatic only" picks the automatic accounts whose rules take the
// post, and the targets then follow the post: a video added brings in the
// accounts that take it now, taking it away takes them out again, and what
// the user ticked or unticked by hand stays as they left it.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/automatic_targets.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/composer_draft.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _MemoryStorage implements AppStorage {
  final Map<String, Object> json = {'settings.json': {'updateCheck': 'off'}};
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async => 'mem://$id.$extension';
  @override
  Future<Uint8List> readMedia(String path) async => Uint8List(0);
  @override
  Future<void> deleteMedia(String path) async {}
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => SizedBox(width: width, height: height);
}

ConnectedAccount _account(String platformId, {PlatformTier? tier, bool enabled = true}) => ConnectedAccount(
      id: platformId,
      platformId: platformId,
      tier: tier ?? builtinRegistry().descriptor(platformId)!.defaultTier,
      displayName: platformId,
      createdAt: DateTime.utc(2026, 10, 1),
      enabled: enabled,
    );

const _photo = MediaAttachment(id: 'photo', path: 'mem://photo.jpg', mimeType: 'image/jpeg', sizeBytes: 2048, fileName: 'photo.jpg');
const _video = MediaAttachment(id: 'clip', path: 'mem://clip.mp4', mimeType: 'video/mp4', sizeBytes: 4096, fileName: 'clip.mp4');
const _sound = MediaAttachment(id: 'track', path: 'mem://track.mp3', mimeType: 'audio/mpeg', sizeBytes: 4096, fileName: 'track.mp3');

/// Mastodon, Bluesky, YouTube videos, Odysee and Pinterest post automatically;
/// Instagram goes by hand-off.
List<ConnectedAccount> _accounts() => [
      _account('mastodon'),
      _account('bluesky'),
      _account('youtube'),
      _account('odysee'),
      _account('pinterest'),
      _account('instagram', tier: PlatformTier.handoff),
    ];

Future<ProviderContainer> _container({List<ConnectedAccount>? accounts}) async {
  final services = await AppServices.create(demo: true, storage: _MemoryStorage());
  final list = accounts ?? _accounts();
  final c = ProviderContainer(overrides: [
    servicesProvider.overrideWithValue(services),
    isDemoProvider.overrideWithValue(false),
    accountsProvider.overrideWith((ref) => Stream.value(list)),
  ]);
  addTearDown(c.dispose);
  c.listen(accountsProvider, (_, _) {});
  c.listen(composerProvider, (_, _) {});
  await c.read(accountsProvider.future);
  c.read(composerProvider.notifier).selectAccounts(const []);
  return c;
}

void main() {
  final registry = builtinRegistry();
  PlatformDescriptor d(String id) => registry.descriptor(id)!;

  group('which networks take the post', () {
    String? reason(String id, List<MediaAttachment> media, {bool words = true, bool textCards = true}) =>
        automaticSkipReason(d(id), media: media, hasWords: words, textCards: textCards);

    test('video sites need a video, or a sound file they take; a photo or a card of words is not one', () {
      for (final id in const ['youtube', 'odysee', 'rumble', 'bitchute']) {
        expect(d(id).isVideoPlatform, isTrue, reason: id);
        expect(reason(id, const []), 'Needs a video', reason: id);
        expect(reason(id, const [_photo]), 'Needs a video', reason: id);
        expect(reason(id, const [_video]), isNull, reason: id);
      }
      expect(reason('youtube', const [_sound]), isNull, reason: 'a still-picture video of the track');
      expect(reason('odysee', const [_sound]), isNull, reason: 'Odysee publishes the sound file as it is');
      expect(reason('rumble', const [_sound]), isNull, reason: 'a still-picture video of the track');
      const silentVideos = PlatformDescriptor(
        id: 'clips',
        name: 'Clips',
        tiers: {PlatformTier.openApi},
        defaultTier: PlatformTier.openApi,
        text: TextRules(),
        media: MediaRules(maxVideos: 1, requiresMedia: true),
        accountRequirements: '',
        apiCostSummary: '',
        categories: {PlatformCategory.video},
      );
      expect(automaticSkipReason(silentVideos, media: const [_sound], hasWords: true, textCards: true), 'Needs a video', reason: 'no sound files at all');
      expect(d('youtube_posts').isVideoPlatform, isFalse, reason: 'text and image posts');
      expect(reason('youtube_posts', const []), isNull);
    });

    test('a network that needs a photo takes the words as a text card, unless text cards are off or there are no words', () {
      expect(reason('pinterest', const []), isNull);
      expect(reason('pinterest', const [], textCards: false), 'Needs a photo or video');
      expect(reason('pinterest', const [], words: false), 'Needs a photo or video');
      expect(reason('pinterest', const [_photo], textCards: false), isNull);
      expect(reason('pinterest', const [_video], words: false), isNull);
    });

    test('networks that need no file take any post; files NEFORUM made do not count', () {
      for (final id in const ['mastodon', 'bluesky', 'x']) {
        expect(reason(id, const [], words: false), isNull, reason: id);
        expect(reason(id, const [_video]), isNull, reason: id);
      }
      const card = MediaAttachment(id: 'card', path: 'mem://card.jpg', mimeType: 'image/jpeg', sizeBytes: 10, generated: true);
      expect(reason('pinterest', const [card], textCards: false), 'Needs a photo or video');
    });

    test('the reason names what the network takes', () {
      const photoOnly = PlatformDescriptor(
        id: 'photos',
        name: 'Photos',
        tiers: {PlatformTier.openApi},
        defaultTier: PlatformTier.openApi,
        text: TextRules(),
        media: MediaRules(maxImages: 4, requiresMedia: true),
        accountRequirements: '',
        apiCostSummary: '',
      );
      expect(automaticSkipReason(photoOnly, media: const [_video], hasWords: false, textCards: true), 'Needs a photo');
      expect(automaticSkipReason(photoOnly, media: const [_photo], hasWords: false, textCards: true), isNull);
    });
  });

  group('Automatic only', () {
    test('a words-only post leaves out YouTube videos and Odysee, and says why', () async {
      final c = await _container();
      c.read(composerProvider.notifier)
        ..setText('Hello everyone')
        ..selectAutomatic();
      final s = c.read(composerProvider);
      expect(s.selected, {'mastodon', 'bluesky', 'pinterest'}, reason: 'Instagram goes by hand-off; Pinterest gets a text card');
      expect(s.automaticTargets, isTrue);
      expect(s.targetChoices, {for (final id in const ['mastodon', 'bluesky', 'pinterest']) id: TargetChoice.automatic});
      expect(c.read(automaticSkipReasonsProvider), {'youtube': 'Needs a video', 'odysee': 'Needs a video'});
    });

    test('a photo post leaves them out too; a video post takes them all', () async {
      final c = await _container();
      final n = c.read(composerProvider.notifier)
        ..addMedia(const [_photo])
        ..selectAutomatic();
      expect(c.read(composerProvider).selected, {'mastodon', 'bluesky', 'pinterest'});
      n
        ..removeMedia(_photo.id)
        ..addMedia(const [_video])
        ..selectAutomatic();
      expect(c.read(composerProvider).selected, {'mastodon', 'bluesky', 'youtube', 'odysee', 'pinterest'});
      expect(c.read(automaticSkipReasonsProvider), isEmpty);
    });

    test('adding a video adds the video sites, and removing it removes them again', () async {
      final c = await _container();
      final n = c.read(composerProvider.notifier)
        ..setText('Watch this')
        ..selectAutomatic();
      n.addMedia(const [_video]);
      var s = c.read(composerProvider);
      expect(s.selected, containsAll(const ['youtube', 'odysee']));
      expect(s.targetChoices['youtube'], TargetChoice.automatic);
      expect(c.read(automaticSkipReasonsProvider), isEmpty);

      n.removeMedia(_video.id);
      s = c.read(composerProvider);
      expect(s.selected, {'mastodon', 'bluesky', 'pinterest'});
      expect(s.targetChoices.containsKey('youtube'), isFalse);
      expect(c.read(automaticSkipReasonsProvider), {'youtube': 'Needs a video', 'odysee': 'Needs a video'});

      // And again: following the post goes on.
      n.addMedia(const [_video]);
      expect(c.read(composerProvider).selected, containsAll(const ['youtube', 'odysee']));
    });

    test('an account unticked by hand is never added back', () async {
      final c = await _container();
      final n = c.read(composerProvider.notifier)
        ..setText('Watch this')
        ..selectAutomatic()
        ..addMedia(const [_video])
        ..toggleAccount('youtube')
        ..toggleAccount('mastodon');
      expect(c.read(composerProvider).targetChoices['youtube'], TargetChoice.unticked);

      n.removeMedia(_video.id);
      n.addMedia(const [_video]);
      final s = c.read(composerProvider);
      expect(s.selected, isNot(contains('youtube')));
      expect(s.selected, isNot(contains('mastodon')));
      expect(s.selected, contains('odysee'), reason: 'NEFORUM still follows the others');
    });

    test('an account ticked by hand is never taken away', () async {
      final c = await _container();
      final n = c.read(composerProvider.notifier)
        ..setText('Coming soon')
        ..selectAutomatic()
        ..toggleAccount('youtube')
        ..toggleAccount('instagram');
      expect(c.read(automaticSkipReasonsProvider), {'odysee': 'Needs a video'}, reason: 'chosen by hand, it needs no reason');

      n
        ..addMedia(const [_video])
        ..removeMedia(_video.id)
        ..clearPost();
      final s = c.read(composerProvider);
      expect(s.selected, containsAll(const ['youtube', 'instagram']));
      expect(s.targetChoices['youtube'], TargetChoice.ticked);
      expect(s.selected, isNot(contains('odysee')));
    });

    test('a text card network comes in with the words, and the empty post leaves it out again', () async {
      final c = await _container();
      final n = c.read(composerProvider.notifier)..selectAutomatic();
      expect(c.read(composerProvider).selected, {'mastodon', 'bluesky'});
      expect(c.read(automaticSkipReasonsProvider)['pinterest'], 'Needs a photo or video');
      n.setText('H');
      expect(c.read(composerProvider).selected, {'mastodon', 'bluesky', 'pinterest'});
      n.setText('');
      expect(c.read(composerProvider).selected, {'mastodon', 'bluesky'});
    });

    test("an account's own choice of files decides for it", () async {
      final c = await _container();
      final n = c.read(composerProvider.notifier)
        ..addMedia(const [_photo, _video])
        ..selectAutomatic();
      expect(c.read(composerProvider).selected, contains('odysee'));
      n.setOverride('odysee', const PostOverrides(mediaIds: ['photo']));
      expect(c.read(composerProvider).selected, isNot(contains('odysee')), reason: 'its post holds only the photo');
    });

    test('All, None or any whole choice ends following the post', () async {
      final c = await _container();
      final n = c.read(composerProvider.notifier)
        ..setText('Words')
        ..selectAutomatic()
        ..selectAccounts(const ['mastodon']);
      expect(c.read(composerProvider).automaticTargets, isFalse);
      expect(c.read(composerProvider).targetChoices, isEmpty);
      n.addMedia(const [_video]);
      expect(c.read(composerProvider).selected, {'mastodon'});
      expect(c.read(automaticSkipReasonsProvider), isEmpty);
    });

    test('from the filter, only the accounts shown are chosen, and the others stay as they were', () async {
      final c = await _container();
      final n = c.read(composerProvider.notifier)
        ..selectAccounts(const ['bluesky', 'instagram'])
        ..setText('Words')
        ..selectAutomatic(among: const ['mastodon', 'youtube', 'instagram']);
      var s = c.read(composerProvider);
      expect(s.selected, {'mastodon', 'bluesky'}, reason: 'Instagram was shown and goes by hand-off');
      expect(s.targetChoices['bluesky'], TargetChoice.ticked);
      expect(s.targetChoices['odysee'], TargetChoice.unticked);
      n.addMedia(const [_video]);
      s = c.read(composerProvider);
      expect(s.selected, {'mastodon', 'bluesky', 'youtube'}, reason: 'Odysee was not shown, so it stays out');
    });

    test('the composer started over keeps following, with the hand choices', () async {
      final c = await _container();
      final n = c.read(composerProvider.notifier)
        ..setText('Watch this')
        ..addMedia(const [_video])
        ..selectAutomatic()
        ..toggleAccount('bluesky')
        ..reset();
      final s = c.read(composerProvider);
      expect(s.automaticTargets, isTrue);
      expect(s.selected, {'mastodon'}, reason: 'the next post has no video, no words for the card, and Bluesky was unticked');
      n.reset(keepTargets: false);
      expect(c.read(composerProvider).automaticTargets, isFalse);
    });

    test('loading a saved post ends following', () async {
      final c = await _container();
      final n = c.read(composerProvider.notifier)
        ..setText('Words')
        ..selectAutomatic();
      final saved = c.read(composerProvider).toPost(id: 'p1', status: PostStatus.draft, now: DateTime.utc(2026, 11, 1));
      n.load(saved);
      expect(c.read(composerProvider).automaticTargets, isFalse);
      n.addMedia(const [_video]);
      expect(c.read(composerProvider).selected, isNot(contains('youtube')));
    });

    test('a post kept across a restart keeps following, with the hand choices', () async {
      final c = await _container();
      c.read(composerProvider.notifier)
        ..setText('Watch this')
        ..selectAutomatic()
        ..toggleAccount('youtube')
        ..toggleAccount('bluesky');
      final kept = composerDraftFromJson(composerDraftToJson(c.read(composerProvider)))!;
      expect(kept.automaticTargets, isTrue);
      expect(kept.targetChoices, c.read(composerProvider).targetChoices);
      expect(composerDraftFromJson({...composerDraftToJson(c.read(composerProvider)), 'targetChoices': {'x': 'nonsense'}})!.targetChoices, isEmpty);

      final c2 = await _container();
      final n2 = c2.read(composerProvider.notifier)..restore(kept);
      n2.addMedia(const [_video]);
      final s = c2.read(composerProvider);
      expect(s.selected, containsAll(const ['youtube', 'odysee']));
      expect(s.selected, isNot(contains('bluesky')));
    });
  });
}
