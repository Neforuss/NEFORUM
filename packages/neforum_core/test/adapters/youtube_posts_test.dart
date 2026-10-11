import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/youtube/youtube_posts_adapter.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

void main() {
  final adapter = YouTubePostsAdapter();
  final ctx = testContext(handler: (_) async => http.Response('', 500));
  final acct = fakeAccount('youtube_posts', tier: PlatformTier.handoff);
  List<String> codes(PostVariant v) => adapter.validate(v, acct).map((i) => i.code).toList();

  group('descriptor', () {
    test('is a hand-off platform separate from YouTube videos', () {
      final d = adapter.descriptor;
      expect(d.id, 'youtube_posts');
      expect(d.name, 'YouTube Posts');
      expect(d.tiers, {PlatformTier.handoff});
      expect(d.serverSideScheduling, isFalse);
      expect(d.personalAccountOk, isTrue);
      expect(d.setupGuide, 'docs/platforms/youtube_posts.md');
      expect(builtinRegistry().byId('youtube_posts'), isA<YouTubePostsAdapter>());
      expect(builtinRegistry().byId('youtube'), isNot(isA<YouTubePostsAdapter>()));
    });

    test('limits match YouTube Help "Create a post"', () {
      final m = adapter.descriptor.media;
      expect(m.maxImages, 10);
      expect(m.maxVideos, 0, reason: 'posts link existing videos, they cannot upload one');
      expect(m.requiresMedia, isFalse);
      expect(m.imageMaxBytes, 16 * 1024 * 1024);
      expect(m.imageMimeTypes, {'image/jpeg', 'image/png', 'image/gif', 'image/webp'});
      expect(adapter.descriptor.text.maxLength, isNull, reason: 'YouTube publishes no length limit');
    });
  });

  group('connect', () {
    test('needs nothing; the channel is optional', () async {
      final r = await adapter.connect(PlatformTier.handoff, const {}, ctx);
      expect(r.account.platformId, 'youtube_posts');
      expect(r.account.tier, PlatformTier.handoff);
      expect(r.account.displayName, 'YouTube Posts');
      expect(r.secrets, isEmpty);
    });

    test('takes a handle, a channel link or a channel id', () async {
      expect(YouTubePostsAdapter.parseChannel('robinmakes'), '@robinmakes');
      expect(YouTubePostsAdapter.parseChannel('@robin.makes'), '@robin.makes');
      expect(YouTubePostsAdapter.parseChannel('https://www.youtube.com/@robinmakes/videos'), '@robinmakes');
      expect(YouTubePostsAdapter.parseChannel('youtube.com/@robinmakes'), '@robinmakes');
      expect(YouTubePostsAdapter.parseChannel('https://m.youtube.com/channel/UC1234567890abcdefghijkl'), 'channel/UC1234567890abcdefghijkl');
      expect(YouTubePostsAdapter.parseChannel('UC1234567890abcdefghijkl'), 'channel/UC1234567890abcdefghijkl');
      expect(YouTubePostsAdapter.parseChannel('@café_ü'), '@café_ü');
      expect(YouTubePostsAdapter.parseChannel('  '), isNull);

      final r = await adapter.connect(PlatformTier.handoff, const {'channel': 'https://www.youtube.com/@robinmakes'}, ctx);
      expect(r.account.handle, '@robinmakes');
      expect(r.account.displayName, '@robinmakes');
      expect(r.account.profileUrl, 'https://www.youtube.com/@robinmakes');
      expect(r.account.config['channel'], '@robinmakes');
    });

    test('rejects what is not a channel', () {
      expect(() => YouTubePostsAdapter.parseChannel('https://example.com/@robin'), throwsA(isA<ConnectException>()));
      expect(() => YouTubePostsAdapter.parseChannel('https://www.youtube.com/watch?v=abc'), throwsA(isA<ConnectException>()));
      expect(() => YouTubePostsAdapter.parseChannel('@ab'), throwsA(isA<ConnectException>()));
      expect(() => YouTubePostsAdapter.parseChannel('has spaces in it'), throwsA(isA<ConnectException>()));
    });

    test('only the hand-off tier', () {
      expect(() => adapter.connect(PlatformTier.byokApi, const {}, ctx), throwsA(isA<ConnectException>()));
    });
  });

  group('validate', () {
    test('text-only and image posts are fine; empty is not', () {
      expect(codes(const PostVariant(text: 'New video Friday!')), isEmpty);
      expect(codes(PostVariant(text: '', media: [fakeImage()])), isEmpty);
      expect(codes(const PostVariant(text: '  ')), contains('post.empty'));
    });

    test('long posts get a "Read more" note, not an error', () {
      final v = PostVariant(text: 'word ' * 80);
      final issues = adapter.validate(v, acct);
      expect(issues.map((i) => i.code), contains('youtube_posts.read_more'));
      expect(issues.hasErrors, isFalse);
    });

    test('videos cannot be uploaded in a post', () {
      expect(adapter.validate(PostVariant(text: 'x', media: [fakeVideo()]), acct).hasErrors, isTrue);
    });
  });

  group('polls and quizzes', () {
    List<String> pollCodes(PostVariant v) => adapter.validate(v, acct).map((i) => i.code).toList();
    const question = 'Which thumbnail?';

    test('limits come from YouTube Help', () {
      final p = adapter.descriptor.polls!;
      expect((p.minOptions, p.maxOptions, p.optionMaxLength), (2, 4, 65));
      expect((p.quizzes, p.quizOptionMaxLength, p.quizExplanationMaxLength), (true, 80, 500));
      expect((p.imagePolls, p.imageOptionMaxLength), (true, 36));
    });

    test('a text poll with 2 to 4 short answers is valid', () {
      expect(pollCodes(const PostVariant(text: question, poll: PostPoll(options: ['Red', 'Blue']))), isEmpty);
      expect(pollCodes(const PostVariant(text: question, poll: PostPoll(options: ['A', 'B', 'C', 'D', 'E']))), contains('poll.option_count'));
      expect(pollCodes(const PostVariant(text: question, poll: PostPoll(options: ['Only one']))), contains('poll.option_count'));
      expect(pollCodes(PostVariant(text: question, poll: PostPoll(options: ['x' * 66, 'ok']))), contains('poll.option_too_long'));
      expect(pollCodes(const PostVariant(text: '', poll: PostPoll(options: ['a', 'b']))), contains('poll.no_question'));
    });

    test('a quiz needs a correct answer and allows 80-character answers', () {
      final ok = PostVariant(text: question, poll: PostPoll(kind: PollKind.quiz, options: ['x' * 80, 'b'], correctIndex: 1, explanation: 'Because.'));
      expect(pollCodes(ok), isEmpty);
      expect(pollCodes(const PostVariant(text: question, poll: PostPoll(kind: PollKind.quiz, options: ['a', 'b']))), contains('poll.no_correct'));
      expect(pollCodes(PostVariant(text: question, poll: PostPoll(kind: PollKind.quiz, options: ['a', 'b'], correctIndex: 0, explanation: 'e' * 501))),
          contains('poll.explanation_too_long'));
    });

    test('an image poll needs one image per 36-character caption', () {
      final two = [fakeImage(), fakeImage(id: 'img2')];
      expect(pollCodes(PostVariant(text: question, media: two, poll: const PostPoll(imageOptions: true, options: ['Left', 'Right']))), isEmpty);
      expect(pollCodes(PostVariant(text: question, media: [fakeImage()], poll: const PostPoll(imageOptions: true, options: ['Left', 'Right']))),
          contains('poll.image_count'));
      expect(pollCodes(PostVariant(text: question, media: two, poll: PostPoll(imageOptions: true, options: ['x' * 37, 'ok']))),
          contains('poll.option_too_long'));
    });

    test('images next to a text poll are left out with a warning', () {
      final v = PostVariant(text: question, media: [fakeImage()], poll: const PostPoll(options: ['a', 'b']));
      expect(pollCodes(v), contains('youtube_posts.poll_images'));
      expect(adapter.buildHandoff(v)!.shareFiles, isEmpty);
    });

    test('hand-off: question on the clipboard, each answer copyable, correct answer named', () {
      final plan = adapter.buildHandoff(const PostVariant(
        text: question,
        poll: PostPoll(kind: PollKind.quiz, options: ['Red', '', 'Blue', 'Green'], correctIndex: 2, explanation: 'Blue pops on dark mode.'),
      ))!;
      expect(plan.clipboardText, question);
      expect(plan.snippets.map((s) => (s.label, s.text)).toList(), [
        ('Answer 1', 'Red'),
        ('Answer 2 (correct)', 'Blue'),
        ('Answer 3', 'Green'),
        ('Explanation', 'Blue pops on dark mode.'),
      ]);
      expect(plan.instructions, contains('**quiz**'));
      expect(plan.instructions, contains('Mark answer 2 as correct: "Blue"'));
    });

    test('hand-off of an image poll shares the images and captions them', () {
      final plan = adapter.buildHandoff(PostVariant(
        text: question,
        media: [fakeImage(), fakeImage(id: 'img2')],
        poll: const PostPoll(imageOptions: true, options: ['Left', 'Right']),
      ))!;
      expect(plan.shareFiles, hasLength(2));
      expect(plan.snippets.map((s) => s.label), ['Image 1 caption', 'Image 2 caption']);
      expect(plan.instructions, contains('image poll'));
    });

    test('other platforms get the post without the poll', () {
      final post = Post(
        id: 'p',
        text: question,
        createdAt: testNow,
        updatedAt: testNow,
        poll: const PostPoll(options: ['a', 'b']),
        targets: const [PostTarget(accountId: 'a')],
      );
      const resolver = VariantResolver();
      final yt = resolver.resolve(post, post.targets.single, adapter.descriptor);
      expect(yt.poll, isNotNull);
      final x = builtinRegistry().descriptor('x')!;
      final v = resolver.resolve(post, post.targets.single, x);
      expect(v.poll, isNull);
      expect(v.issues.map((i) => i.code), contains('poll.unsupported'));
      expect(Post.fromJson(post.toJson()).poll, post.poll);
    });
  });

  group('hand-off', () {
    test('copies the text and opens YouTube with Create > Create post steps', () {
      final plan = adapter.buildHandoff(const PostVariant(text: 'Behind the scenes of Friday’s video'))!;
      expect(plan.platformId, 'youtube_posts');
      expect(plan.preferred, HandoffMethod.manual);
      expect(plan.webIntent, isNull, reason: 'YouTube has no prefill link');
      expect(plan.clipboardText, 'Behind the scenes of Friday’s video');
      expect(plan.desktopUrl, 'https://www.youtube.com/');
      expect(plan.androidPackage, 'com.google.android.youtube');
      expect(plan.iosScheme, 'youtube://');
      expect(plan.instructions, contains('**Create** > **Create post**'));
      expect(plan.instructions, isNot(contains('images')));
    });

    test('images travel with the plan and the steps say how to add them', () {
      final plan = adapter.buildHandoff(PostVariant(text: 'Two shots', media: [fakeImage(), fakeImage(id: 'img2')]))!;
      expect(plan.shareFiles, hasLength(2));
      expect(plan.instructions, contains('2 images'));
      expect(plan.mediaNote, contains('images'));
    });

    test('a thread becomes one post', () {
      final plan = adapter.buildHandoff(const PostVariant(text: 'one', threadParts: ['one', 'two']))!;
      expect(plan.clipboardText, 'one\n\ntwo');
    });

    test('publish() never posts', () async {
      final r = await adapter.publish(const PostVariant(text: 'x'), acct, const {}, ctx);
      expect(r.isFailure, isTrue);
      expect(r.error!.kind, PublishErrorKind.unsupported);
    });
  });
}
