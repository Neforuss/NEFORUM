import 'dart:async';

/// Holds back the requests that make a post. iOS can stop a backgrounded app
/// at any moment, and a post made then has no answer anyone can read, so while
/// this is paused no new `AdapterContext.creating` call starts. Uploads are left
/// alone: re-sending a file costs time, posting twice is what must not happen.
class PublishPauseSignal {
  Completer<void>? _resumed;

  bool get isPaused => _resumed != null;

  void pause() => _resumed ??= Completer<void>();

  void resume() {
    _resumed?.complete();
    _resumed = null;
  }

  /// Completes at once when not paused, else on [resume].
  Future<void> get whenResumed => _resumed?.future ?? Future<void>.value();
}
