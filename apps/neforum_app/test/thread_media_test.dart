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
}
