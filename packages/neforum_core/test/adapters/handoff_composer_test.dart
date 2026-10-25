// The composer pages the NEFORUM browser extension fills in on a computer
// (HandoffPlan.composerUrl) and the steps shown with them.

import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

void main() {
  final registry = builtinRegistry();
  HandoffPlan plan(String id, PostVariant v, {ConnectedAccount? account}) => registry.byId(id)!.buildHandoff(v, account: account)!;

  group('threads: the composer gets every part', () {
    const thread = PostVariant(text: 'Part one', threadParts: ['Part one', 'Part two', 'Part three']);

    test('X: the intent page, which the extension extends to a thread', () {
      final p = plan('x', thread);
      expect(p.composerUrl, p.webIntent);
      expect(p.composerUrl!.queryParameters['text'], 'Part one', reason: 'only the first part is in the link');
      expect(p.clipboardText, 'Part one\n\nPart two\n\nPart three');
      expect(p.composerInstructions, contains('adds the other 2 parts of the thread'));
      expect(p.composerInstructions, contains('**Post all**'));
      expect(p.instructions, contains('reply to your post'), reason: 'the steps without the extension stay');
    });

    test('Bluesky and Threads: the compose intent', () {
      for (final id in ['bluesky', 'threads']) {
        final p = plan(id, thread);
        expect(p.composerUrl, p.webIntent, reason: id);
        expect(p.composerInstructions, contains('the other 2'), reason: id);
      }
    });

    test('a single post with photos: the extension adds them, the by-hand note is not for this page', () {
      final p = plan('x', PostVariant(text: 'Pic', media: [fakeImage()]));
      expect(p.composerInstructions, contains('adds your photos or video'));
      expect(p.composerInstructions, isNot(contains('thread')));
      expect(p.mediaNote, isNotNull, reason: 'still shown without the extension');
      final plain = plan('bluesky', const PostVariant(text: 'Hi'));
      expect(plain.composerInstructions, '1. The Bluesky composer opens with your text filled in (sign in if asked).\n'
          '2. Check the text and select **Post**.');
    });
  });

  group('YouTube Posts', () {
    final channel = ConnectedAccount(
      id: 'yp',
      platformId: 'youtube_posts',
      tier: PlatformTier.handoff,
      displayName: 'YouTube Posts',
      createdAt: DateTime.utc(2026, 10, 25),
      config: const {'channel': '@examplechannel'},
    );

    test('the Posts tab (or youtube.com) is the page the extension fills in', () {
      expect(plan('youtube_posts', const PostVariant(text: 'Hi'), account: channel).composerUrl, Uri.parse('https://www.youtube.com/@examplechannel/posts'));
      expect(plan('youtube_posts', const PostVariant(text: 'Hi')).composerUrl, Uri.parse('https://www.youtube.com/'));
    });

    test('the steps name the poll, quiz or images it adds', () {
      final quiz = plan(
        'youtube_posts',
        const PostVariant(text: 'Capital of France?', poll: PostPoll(options: ['Paris', 'Lyon', 'Nice'], kind: PollKind.quiz, correctIndex: 0, explanation: 'It is Paris.')),
        account: channel,
      );
      expect(quiz.composerInstructions, contains('adds your question, the quiz with its 3 answers, the correct answer and the explanation'));
      expect(quiz.snippets.map((s) => s.label), ['Answer 1 (correct)', 'Answer 2', 'Answer 3', 'Explanation'], reason: 'still there to insert by hand');

      final poll = plan('youtube_posts', const PostVariant(text: 'Tea or coffee?', poll: PostPoll(options: ['Tea', 'Coffee'])));
      expect(poll.composerInstructions, contains('the poll with its 2 answers'));
      expect(poll.composerInstructions, contains('youtube.com opens'));

      final images = plan('youtube_posts', PostVariant(text: 'New art', media: [fakeImage(), fakeImage(id: 'img2')]), account: channel);
      expect(images.composerInstructions, contains('adds your text and your 2 images'));
      expect(images.composerInstructions, contains("Your channel's **Posts** tab opens"));
    });
  });

  group('WhatsApp', () {
    test('wa.me (which forwards to WhatsApp Web) with text; WhatsApp Web without', () {
      final withText = plan('whatsapp', const PostVariant(text: 'Hello'));
      expect(withText.composerUrl, withText.webIntent);
      expect(withText.composerUrl!.host, 'wa.me');
      expect(withText.composerInstructions, contains('adds your text'));
      final filesOnly = plan('whatsapp', PostVariant(text: '', media: [fakeImage()]));
      expect(filesOnly.composerUrl, Uri.parse('https://web.whatsapp.com/'));
      expect(filesOnly.composerInstructions, contains('adds your files'));
      expect(filesOnly.composerInstructions, contains('**Fill in again**'));
    });
  });
}
