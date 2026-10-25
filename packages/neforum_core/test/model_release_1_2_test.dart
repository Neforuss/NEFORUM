import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 25, 12);

  test('thread parts and artwork survive JSON', () {
    final post = Post(
      id: 'p1',
      text: 'First part',
      createdAt: now,
      updatedAt: now,
      additionalParts: const ['Second part', 'Third part'],
      artwork: const ArtworkDetails(maturity: ArtworkMaturity.mature, aiGenerated: true, disallowAiTraining: false),
    );
    final back = Post.fromJson(post.toJson());
    expect(back.additionalParts, ['Second part', 'Third part']);
    expect(back.parts, ['First part', 'Second part', 'Third part']);
    expect(back.isThread, isTrue);
    expect(back.artwork, post.artwork);
    expect(back.isArtwork, isTrue);
  });

  test('posts without the new fields read as before', () {
    final post = Post(id: 'p2', text: 'Only text', createdAt: now, updatedAt: now);
    final json = post.toJson();
    expect(json.containsKey('additionalParts'), isFalse);
    expect(json.containsKey('artwork'), isFalse);
    final back = Post.fromJson(json);
    expect(back.additionalParts, isEmpty);
    expect(back.artwork, isNull);
    expect(back.copyWith(artwork: const ArtworkDetails()).copyWith(clearArtwork: true).artwork, isNull);
  });

  test('media render parameters survive JSON', () {
    const media = MediaAttachment(
      id: 'm1',
      path: '/media/m1.jpg',
      mimeType: 'image/jpeg',
      sizeBytes: 10,
      generated: true,
      renderParameters: {'kind': 'textCard', 'alignment': 'center'},
    );
    final back = MediaAttachment.fromJson(media.toJson());
    expect(back.renderParameters, {'kind': 'textCard', 'alignment': 'center'});
    expect(back.copyWith(altText: 'x').renderParameters, media.renderParameters);
  });

  test('cancelled targets are not done and survive JSON', () {
    const target = PostTarget(accountId: 'a', status: TargetStatus.cancelled);
    expect(target.isDone, isFalse);
    expect(PostTarget.fromJson(target.toJson()).status, TargetStatus.cancelled);
  });

  test('the resolver passes artwork to every variant', () {
    final post = Post(id: 'p3', text: 'A drawing', createdAt: now, updatedAt: now, artwork: const ArtworkDetails());
    final registry = builtinRegistry();
    final adapter = registry.byId('mastodon')!;
    final account = ConnectedAccount(
        id: 'acc', platformId: 'mastodon', handle: '@me', displayName: 'Me', tier: PlatformTier.openApi, createdAt: now);
    final variant = VariantResolver(const ResolverOptions()).resolve(post, const PostTarget(accountId: 'acc'), adapter.descriptor, account: account);
    expect(variant.isArtwork, isTrue);
  });
}
