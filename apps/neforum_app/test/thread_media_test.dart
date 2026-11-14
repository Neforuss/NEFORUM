// Attachments placed in thread parts: the composer keeps each one with its
// part when parts are added, removed or left empty, and the drafts keep it.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/composer_draft.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _MemoryStorage implements AppStorage {
  final Map<String, Object> _json = {};
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => _json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => _json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async => 'mem://$id.$extension';
  @override
  Future<Uint8List> readMedia(String path) async => Uint8List(0);
  @override
  Future<void> deleteMedia(String path) async {}
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) => const SizedBox();
}

MediaAttachment _image(String id) => MediaAttachment(id: id, path: '/m/$id.png', mimeType: 'image/png', sizeBytes: 10, altText: 'alt $id');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('toPost closes the gaps of empty parts and leaves out the first part', () {
    final c = ComposerState(
      text: 'One',
      additionalParts: const ['', 'Three', 'Four'],
      media: [_image('a'), _image('b'), _image('c'), _image('d')],
      mediaParts: const {'a': 0, 'b': 1, 'c': 2, 'd': 3, 'gone': 3},
    );
    final post = c.toPost(id: 'p', status: PostStatus.draft, now: DateTime.utc(2026));
    expect(post.parts, ['One', 'Three', 'Four']);
    // b sat in the empty part 2: it goes with part 1. "gone" is not attached.
    expect(post.mediaParts, {'c': 1, 'd': 2});
  });

  test('the draft keeps the composer part numbers, empty parts included', () {
    final c = ComposerState(
      text: 'One',
      additionalParts: const ['', 'Three'],
      media: [_image('a'), _image('b')],
      mediaParts: const {'b': 2},
    );
    final back = composerDraftFromJson(composerDraftToJson(c))!;
    expect(back.additionalParts, ['', 'Three']);
    expect(back.mediaParts, {'b': 2});
  });

  test('adding, removing and undoing parts keeps each attachment with its part', () async {
    final s = await AppServices.create(demo: true, storage: _MemoryStorage());
    final container = ProviderContainer(overrides: [servicesProvider.overrideWithValue(s)]);
    addTearDown(container.dispose);
    final n = container.read(composerProvider.notifier);
    n.fillThread(['One', 'Two', 'Three'], [_image('a'), _image('b'), _image('c')], const {'a': 0, 'b': 1, 'c': 2});
    var c = container.read(composerProvider);
    expect(c.text, 'One');
    expect(c.additionalParts, ['Two', 'Three']);
    expect(c.mediaParts, {'b': 1, 'c': 2});

    // A new part after the first: the later parts' media moves with them.
    n.addPart(after: 0);
    c = container.read(composerProvider);
    expect(c.additionalParts, ['', 'Two', 'Three']);
    expect(c.mediaParts, {'b': 2, 'c': 3});

    // Removing "Two" hands its image to the part before it.
    final revision = c.revision;
    n.removePart(2);
    c = container.read(composerProvider);
    expect(c.additionalParts, ['', 'Three']);
    expect(c.mediaParts, {'b': 1, 'c': 2});
    n.undoRemovePart(2, 'Two', revision: revision);
    expect(container.read(composerProvider).mediaParts, {'b': 1, 'c': 3});

    n.setMediaPart('c', 0);
    expect(container.read(composerProvider).mediaParts, {'b': 1});
    n.removeMedia('b');
    expect(container.read(composerProvider).mediaParts, isEmpty);
  });

  // 1.4.3: thread media.
  group('media for each part', () {
    late ProviderContainer container;
    late ComposerNotifier n;
    ComposerState c() => container.read(composerProvider);
    List<String> ids(int part) => [for (final m in c().mediaOfPart(part)) m.id];

    setUp(() async {
      final s = await AppServices.create(demo: true, storage: _MemoryStorage());
      container = ProviderContainer(overrides: [servicesProvider.overrideWithValue(s)]);
      n = container.read(composerProvider.notifier);
      n.fillThread(['One', 'Two', 'Three'], [_image('a'), _image('b'), _image('c')], const {'a': 0, 'b': 1, 'c': 2});
    });
    tearDown(() => container.dispose());

    test('media added to a part goes with that part; past the last, with the last', () {
      n.addMedia([_image('b2'), _image('b3')], part: 1);
      n.addMedia([_image('z')], part: 9);
      n.addMedia([_image('a2')]);
      expect(ids(0), ['a', 'a2']);
      expect(ids(1), ['b', 'b2', 'b3']);
      expect(ids(2), ['c', 'z']);
      final post = c().toPost(id: 'p', status: PostStatus.draft, now: DateTime.utc(2026));
      expect(post.mediaParts, {'b': 1, 'b2': 1, 'b3': 1, 'c': 2, 'z': 2});
    });

    test("reordering a part's tray leaves the other parts' media in place", () {
      n.addMedia([_image('b2'), _image('b3')], part: 1);
      n.addMedia([_image('a2')]);
      // Post order: a b c b2 b3 a2. b3 to the front of part 2.
      n.moveMediaInPart(1, 2, 0);
      expect(ids(1), ['b3', 'b', 'b2']);
      expect(c().media.map((m) => m.id), ['a', 'b3', 'c', 'b', 'b2', 'a2']);
      expect(ids(0), ['a', 'a2']);
      expect(ids(2), ['c']);
      // Out of range does nothing.
      n.moveMediaInPart(1, 7, 0);
      expect(ids(1), ['b3', 'b', 'b2']);
    });

    test('moving a part moves its words and media together, the first part included', () {
      final revision = c().revision;
      n.movePart(2, 1);
      expect([c().text, ...c().additionalParts], ['One', 'Three', 'Two']);
      expect(ids(1), ['c']);
      expect(ids(2), ['b']);
      expect(c().revision, greaterThan(revision), reason: 'the editors take the new words');

      n.movePart(1, 0);
      expect([c().text, ...c().additionalParts], ['Three', 'One', 'Two']);
      expect(ids(0), ['c']);
      expect(ids(1), ['a']);
      expect(ids(2), ['b']);
      expect(c().mediaParts, {'a': 1, 'b': 2}, reason: 'the first part needs no entry');

      n.movePart(0, 2);
      expect([c().text, ...c().additionalParts], ['One', 'Two', 'Three']);
      expect(c().mediaParts, {'b': 1, 'c': 2});

      final before = c();
      n.movePart(0, 3);
      n.movePart(-1, 0);
      n.movePart(1, 1);
      expect(identical(c(), before), isTrue, reason: 'impossible moves change nothing');
    });

    test('undoing a removed part puts its media back in it', () {
      n.addMedia([_image('b2')], part: 1);
      final revision = c().revision;
      n.removePart(1);
      expect(ids(0), ['a', 'b', 'b2']);
      // b2 was removed in the meantime: it stays removed.
      n.removeMedia('b2');
      expect(n.undoRemovePart(1, 'Two', revision: revision, mediaIds: const ['b', 'b2']), isTrue);
      expect([c().text, ...c().additionalParts], ['One', 'Two', 'Three']);
      expect(ids(1), ['b']);
      expect(ids(2), ['c']);
      expect(c().mediaParts.containsKey('b2'), isFalse);
    });
  });
}
