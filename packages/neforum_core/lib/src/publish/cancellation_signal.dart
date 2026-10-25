import 'dart:async';

/// Thrown by work that stopped because its [CancellationSignal] was
/// cancelled (an HTTP request aborted, a retry pause cut short).
class OperationCancelledException implements Exception {
  const OperationCancelledException();

  @override
  String toString() => 'The operation was cancelled';
}

/// Lets the user stop running work: the publish service checks it between
/// targets, and [NeforumHttp] aborts the request in flight when it fires.
/// Cancelling is final; a new run needs a new signal.
class CancellationSignal {
  final _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  /// Completes (never with an error) when [cancel] is called.
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  /// Throws [OperationCancelledException] once [cancel] was called.
  void throwIfCancelled() {
    if (isCancelled) throw const OperationCancelledException();
  }
}
