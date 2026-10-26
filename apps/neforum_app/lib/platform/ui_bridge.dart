import 'package:neforum_core/neforum_core.dart' hide Visibility;

/// What the user chose in the hand-off sheet.
enum HandoffChoice {
  /// "I posted it" — the target is done.
  posted,

  /// Closed the sheet / "Later" — keep it waiting.
  later,

  /// "Skip this one".
  skip,
}

/// How the hand-off sheet closed: the user's [choice], and [note], what an
/// automatic attempt in the sheet left for the user to check before posting
/// by hand when it ended without a confirmed post ([PostTarget.handoffNote]);
/// null when there was none.
typedef HandoffDecision = ({HandoffChoice choice, String? note});

/// Lets non-UI services (auth, hand-off) ask the UI to show something.
/// The app shell registers the real implementation at startup; until then
/// (and in background isolates) the defaults below make everything wait or
/// defer instead of crashing.
abstract class UiBridge {
  static UiBridge instance = _HeadlessBridge();

  /// Whether a window/screen is available to show UI on.
  bool get interactive;

  /// Asks the user to paste the redirect URL after signing in.
  Future<String?> askPaste(Uri authorizationUrl, Uri redirectUri);

  /// Shows the hand-off sheet and returns what the user did.
  Future<HandoffDecision> showHandoff(HandoffPlan plan, {required Post post, required ConnectedAccount account, required PostVariant variant});
}

class _HeadlessBridge implements UiBridge {
  @override
  bool get interactive => false;

  @override
  Future<String?> askPaste(Uri authorizationUrl, Uri redirectUri) async => null;

  @override
  Future<HandoffDecision> showHandoff(HandoffPlan plan, {required Post post, required ConnectedAccount account, required PostVariant variant}) async =>
      (choice: HandoffChoice.later, note: null);
}

/// [HandoffLauncher] that shows the hand-off sheet through [UiBridge].
class AppHandoffLauncher implements HandoffLauncher {
  AppHandoffLauncher({this.onSkip});

  /// Called when the user chooses "Skip"; the app marks the target skipped
  /// once the publish run finishes.
  final void Function(String postId, String accountId)? onSkip;

  @override
  Future<HandoffResult> launch(HandoffPlan plan, {required Post post, required PostTarget target, required PostVariant variant, required ConnectedAccount account}) async {
    final ui = UiBridge.instance;
    if (!ui.interactive) return HandoffResult.deferred;
    final (:choice, :note) = await ui.showHandoff(plan, post: post, account: account, variant: variant);
    switch (choice) {
      case HandoffChoice.posted:
        return HandoffResult.launched;
      case HandoffChoice.later:
        // The run keeps the note with the target, so the hand-off is never
        // posted automatically again.
        return HandoffResult(HandoffOutcome.deferred, note: note);
      case HandoffChoice.skip:
        onSkip?.call(post.id, account.id);
        return HandoffResult(HandoffOutcome.deferred, note: note);
    }
  }
}
