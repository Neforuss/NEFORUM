import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/ui_bridge.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _Bridge implements UiBridge {
  _Bridge(this.interactive);

  @override
  final bool interactive;
  int sheets = 0;

  @override
  Future<String?> askPaste(Uri authorizationUrl, Uri redirectUri) async => null;

  @override
  Future<HandoffDecision> showHandoff(HandoffPlan plan, {required Post post, required ConnectedAccount account, required PostVariant variant}) async {
    sheets++;
    return (choice: HandoffChoice.posted, note: null);
  }
}

void main() {
  group('canShowUi', () {
    test('a phone can only show what is on screen', () {
      bool phone(AppLifecycleState? s) => canShowUi(canRaiseWindow: false, lifecycle: s);
      expect(phone(AppLifecycleState.resumed), isTrue);
      expect(phone(AppLifecycleState.inactive), isTrue);
      expect(phone(null), isTrue, reason: 'no report yet: starting up, or a test');
      expect(phone(AppLifecycleState.hidden), isFalse);
      expect(phone(AppLifecycleState.paused), isFalse);
      expect(phone(AppLifecycleState.detached), isFalse);
    });

    test('a desktop app brings its window up', () {
      for (final s in AppLifecycleState.values) {
        expect(canShowUi(canRaiseWindow: true, lifecycle: s), isTrue, reason: s.name);
      }
    });
  });

  group('AppHandoffLauncher', () {
    final plan = HandoffPlan(platformId: 'x', instructions: 'Tap Post', clipboardText: 'hi');
    final post = Post(id: 'p', text: 'hi', createdAt: DateTime(2026), updatedAt: DateTime(2026));
    const target = PostTarget(accountId: 'a');
    const variant = PostVariant(text: 'hi');
    final account = ConnectedAccount(id: 'a', platformId: 'x', tier: PlatformTier.handoff, displayName: 'A', createdAt: DateTime(2026));
    final before = UiBridge.instance;
    tearDown(() => UiBridge.instance = before);

    test('hidden UI defers at once: no sheet waiting where nobody sees it', () async {
      final bridge = _Bridge(false);
      UiBridge.instance = bridge;
      final r = await AppHandoffLauncher().launch(plan, post: post, target: target, variant: variant, account: account);
      expect(r.outcome, HandoffOutcome.deferred);
      expect(bridge.sheets, 0);
    });

    test('visible UI shows the sheet', () async {
      final bridge = _Bridge(true);
      UiBridge.instance = bridge;
      final r = await AppHandoffLauncher().launch(plan, post: post, target: target, variant: variant, account: account);
      expect(r.outcome, HandoffOutcome.launched);
      expect(bridge.sheets, 1);
    });
  });
}
