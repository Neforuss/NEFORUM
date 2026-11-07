import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'env.dart';

/// One network of a run, for the native surface. [bytes] sizes its part of the bar.
@immutable
class PublishHostNetwork {
  const PublishHostNetwork({required this.id, required this.name, required this.bytes});

  final String id;
  final String name;
  final int bytes;

  Map<String, Object?> toMap() => {'id': id, 'name': name, 'bytes': bytes};
}

/// What native asks of Dart.
sealed class PublishHostSignal {
  const PublishHostSignal();
}

/// The Cancel button on the run's notification.
class PublishHostCancelRequested extends PublishHostSignal {
  const PublishHostCancelRequested(this.postId);
  final String postId;
}

/// The OS ended the time it allows for background work.
class PublishHostTimedOut extends PublishHostSignal {
  const PublishHostTimedOut();
}

/// The window is going away while a run goes on.
class PublishHostWindowClosing extends PublishHostSignal {
  const PublishHostWindowClosing();
}

/// The run's notification was tapped.
class PublishHostOpenPost extends PublishHostSignal {
  const PublishHostOpenPost(this.postId);
  final String postId;
}

/// What keeps a publish run alive outside the app, on channel `neforum/publish_host`.
/// It never holds the post's text. Every call may fail: the caller
/// ([PublishRunKeeper]) never lets that touch the run.
abstract class PublishHost {
  /// Starts or refreshes the keep-alive for [postId]. True when the OS agreed.
  Future<bool> begin({required String postId, required String title, required List<PublishHostNetwork> networks});

  /// [snapshot] is [PublishSurfaceState.toSnapshot].
  Future<void> update(Map<String, Object?> snapshot);

  Future<void> end({required String postId, required String summary});

  Stream<PublishHostSignal> get signals;

  void dispose();
}

/// Desktop, the demo workspace and tests: nothing to keep alive.
class NoPublishHost implements PublishHost {
  const NoPublishHost();

  @override
  Future<bool> begin({required String postId, required String title, required List<PublishHostNetwork> networks}) async => true;
  @override
  Future<void> update(Map<String, Object?> snapshot) async {}
  @override
  Future<void> end({required String postId, required String summary}) async {}
  @override
  Stream<PublishHostSignal> get signals => const Stream.empty();
  @override
  void dispose() {}
}

/// The native side: `PublishHost.kt` on Android.
class ChannelPublishHost implements PublishHost {
  ChannelPublishHost({@visibleForTesting MethodChannel? channel}) : _channel = channel ?? const MethodChannel(kPublishHostChannel) {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;
  final _signals = StreamController<PublishHostSignal>.broadcast();

  Future<void> _handle(MethodCall call) async {
    final args = call.arguments;
    final postId = args is Map ? args['postId'] : null;
    switch (call.method) {
      case 'cancelRequested' when postId is String:
        _signals.add(PublishHostCancelRequested(postId));
      case 'timedOut':
        _signals.add(const PublishHostTimedOut());
      case 'windowClosing':
        _signals.add(const PublishHostWindowClosing());
      case 'openPost' when postId is String:
        _signals.add(PublishHostOpenPost(postId));
    }
  }

  @override
  Future<bool> begin({required String postId, required String title, required List<PublishHostNetwork> networks}) async =>
      await _channel.invokeMethod<bool>('begin', {
        'postId': postId,
        'title': title,
        'networks': [for (final n in networks) n.toMap()],
      }) ??
      false;

  @override
  Future<void> update(Map<String, Object?> snapshot) => _channel.invokeMethod<void>('update', snapshot);

  @override
  Future<void> end({required String postId, required String summary}) => _channel.invokeMethod<void>('end', {'postId': postId, 'summary': summary});


  @override
  Stream<PublishHostSignal> get signals => _signals.stream;

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    unawaited(_signals.close());
  }
}

const String kPublishHostChannel = 'neforum/publish_host';

/// `ApplicationExitInfo` numbers that mean the person stopped the app: Force stop, or
/// Stop in Task Manager.
const Set<int> kExitReasonsByUser = {10, 11};

/// Why the previous process of this app ended, in `ApplicationExitInfo` numbers. Null
/// when the OS does not say. Leaves the trace `publish-exit reason=<n>`.
Future<int?> readLastExitReason() async {
  if (!Env.isAndroid) return null;
  try {
    final reason = await const MethodChannel(kPublishHostChannel).invokeMethod<int>('lastExitReason');
    debugPrint('publish-exit reason=$reason');
    return reason;
  } on Object catch (e) {
    debugPrint('publish-exit unknown: ${e.runtimeType}');
    return null;
  }
}

/// The host for this device. iOS joins when `PublishRunKeeper.swift` exists.
PublishHost createPublishHost({required bool demo}) {
  if (!Env.isAndroid || demo) return const NoPublishHost();
  try {
    return ChannelPublishHost();
  } on Object catch (e) {
    // No messenger to talk over. Posting never depends on the keep-alive.
    debugPrint('publish-host unavailable: ${e.runtimeType}');
    return const NoPublishHost();
  }
}
