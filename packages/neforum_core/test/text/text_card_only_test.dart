import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

/// A network with a 50-character limit and threads that takes images.
const _network = PlatformDescriptor(
  id: 'short',
  name: 'Short',
  tiers: {PlatformTier.openApi},
  defaultTier: PlatformTier.openApi,
  text: TextRules(maxLength: 50, supportsThreads: true),
  media: MediaRules(maxImages: 4, supportsAltText: true),
  accountRequirements: '',
  apiCostSummary: '',
);

const _card = MediaAttachment(id: 'card', path: '/card.jpg', mimeType: 'image/jpeg', sizeBytes: 1, generated: true, altText: 'words');
const _photo = MediaAttachment(id: 'photo', path: '/photo.jpg', mimeType: 'image/jpeg', sizeBytes: 1);

PostVariant _resolve({required List<String> mediaIds, required bool cardOnly, String text = 'Short words'}) {
  final post = Post(
    id: 'p',
    text: text,
    media: const [_card, _photo],
    link: 'https://example.org',
    createdAt: testNow,
    updatedAt: testNow,
    targets: [
      PostTarget(accountId: 'acct-1', overrides: PostOverrides(mediaIds: mediaIds, extra: {if (cardOnly) kTextCardOnlyKey: true})),
    ],
  );
  return const VariantResolver().resolve(post, post.targets.single, _network, account: fakeAccount(_network.id));
}

void main() {
  test('the card alone goes without the text, link or thread', () {
    final v = _resolve(mediaIds: ['card'], cardOnly: true, text: 'A long text that would need a thread on this network, ' * 3);
    expect(v.text, isEmpty);
    expect(v.threadParts, isEmpty);
    expect(v.media.single.altText, 'words');
    expect(v.issues.any((i) => i.code == 'text.card_only'), isTrue);
    expect(v.issues.any((i) => i.code == 'text.threaded' || i.code == 'text.too_long'), isFalse);
  });

  test('without the key, the text goes along with the card', () {
    final v = _resolve(mediaIds: ['card'], cardOnly: false);
    expect(v.text, startsWith('Short words'));
    expect(v.text, contains('https://example.org'));
  });

  test('the key does nothing once the target has a photo of its own', () {
    final v = _resolve(mediaIds: ['photo'], cardOnly: true);
    expect(v.text, startsWith('Short words'));
    expect(v.issues.any((i) => i.code == 'text.card_only'), isFalse);
  });
}
