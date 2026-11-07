import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/activity/target_chip.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

const _uploadAdvice = 'A slow or busy connection usually causes this. Retry when nothing else is uploading, or use a smaller file.';
const _usualAdvice = 'This is usually temporary: a connection problem or the platform being busy. Retry in a minute.';

Future<void> _showError(WidgetTester tester, PublishError error) async {
  final target = PostTarget(accountId: 'a', status: TargetStatus.failed, result: PublishResult.failure(error));
  final post = Post(id: 'p', text: 'x', createdAt: DateTime.utc(2026, 11, 6), updatedAt: DateTime.utc(2026, 11, 6), targets: [target]);
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AccentChoice.neforum),
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) => TextButton(onPressed: () => showTargetError(context, ref, post, target, 'Mastodon'), child: const Text('Open')),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a cut-off upload reads in plain words, with the system text in the details box', (tester) async {
    const raw = 'ClientException with SocketException: Write failed (OS Error: An established connection was aborted, errno = 10053), uri=https://mastodon.example\n'
        '2516582 of 8493465 bytes handed to the connection, 96 s, attempt 3';
    await _showError(
      tester,
      const PublishError.network('The upload to mastodon.example was cut off (tried 3 times). Nothing was posted.', raw: raw, uploadInterrupted: true),
    );
    final message = find.text('The upload to mastodon.example was cut off (tried 3 times). Nothing was posted.');
    expect(message, findsOneWidget);
    expect(find.text(_uploadAdvice), findsOneWidget);
    expect(find.text(_usualAdvice), findsNothing);
    expect(find.widgetWithText(SelectableText, raw), findsOneWidget, reason: 'the details box keeps the raw text');

    // Only the details box may carry the system's words.
    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      final text = t.data ?? '';
      for (final word in ['errno', 'ClientException', 'SocketException', 'Write failed']) {
        expect(text, isNot(contains(word)));
      }
    }
  });

  testWidgets('any other network error keeps its usual advice', (tester) async {
    await _showError(tester, const PublishError.network('The connection to mastodon.example failed.', raw: 'errno = 10054'));
    expect(find.text(_usualAdvice), findsOneWidget);
    expect(find.text(_uploadAdvice), findsNothing);
  });

  test('the advice follows what is known about the upload', () {
    const cut = PublishError.network('cut off', uploadInterrupted: true);
    expect(targetErrorAdvice(cut), _uploadAdvice);
    // A thread with live parts cannot be retried from the start, but Retry
    // posts the rest of it.
    expect(targetErrorAdvice(cut.asResumableThread(postedIds: const ['a'], total: 2)), _uploadAdvice);
    // The upload that is the post went out whole and no answer came.
    const unknown = PublishError(kind: PublishErrorKind.network, message: 'not confirmed', uploadInterrupted: true);
    expect(targetErrorAdvice(unknown), 'Look on the site first: it may be there. Retry only if it is not.');
    expect(targetErrorAdvice(const PublishError.network('x')), _usualAdvice);
    expect(targetErrorAdvice(const PublishError.validation('x')), contains('rejected the content'));
  });
}
