import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'env.dart';

/// One network as a run starts. Names and sizes only: the post's text never goes
/// over this channel, because iOS and an Android lock screen show what it carries.
/// [bytes] sizes its part of Android's bar.
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

/// The Cancel button on Android's notification.
class PublishHostCancelRequested extends PublishHostSignal {
  const PublishHostCancelRequested(this.postId);
  final String postId;
}

/// The OS took back the time it gave: Android's limit for the service, or iOS's
/// continued task expiring. On iOS a person's Stop in the system's own view looks
/// the same.
class PublishHostTimedOut extends PublishHostSignal {
  const PublishHostTimedOut();
}

/// The window is going away while a run goes on. On Android the Activity ends and
/// the engine stays; on iOS the app's time is about to end and it will be frozen.
class PublishHostWindowClosing extends PublishHostSignal {
  const PublishHostWindowClosing();
}

/// Android's run notification was tapped.
class PublishHostOpenPost extends PublishHostSignal {
  const PublishHostOpenPost(this.postId);
  final String postId;
}

/// Keeps a publish run going outside the app and shows it there, on channel
/// [kPublishHostChannel]: `PublishHost.kt` on Android, `PublishRunKeeper.swift` on
/// iOS. It never holds the post's text. Nothing here may stop a run: a host that
/// fails only means no surface, and the caller ([PublishRunKeeper]) never lets a
/// failure touch the run.
///
/// Dart to native:
/// * `begin {postId, title, networks: [{id, name, bytes}]} -> bool`: true when the
///   OS took the run on. A second `begin` for the same post refreshes its networks
///   (Android) or asks for new time after a stop (iOS).
/// * `update snapshot`: `PublishSurfaceState.toSnapshot`, one per run, each with
///   its `postId`.
/// * `end {postId, summary}`.
/// * `lastExitReason -> int?`: Android only.
///
/// Native to Dart: `cancelRequested {postId}`, `timedOut`, `windowClosing`,
/// `openPost {postId}`.
abstract class PublishHost {
  /// True when the OS took the run on.
  Future<bool> begin({required String postId, required String title, required List<PublishHostNetwork> networks});

  /// [snapshot] is `PublishSurfaceState.toSnapshot`.
  Future<void> update(Map<String, Object?> snapshot);

  Future<void> end({required String postId, required String summary});

  Stream<PublishHostSignal> get signals;

  void dispose();
}

/// Desktop, the demo workspace and tests: nothing to keep alive, so nothing to refuse.
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

/// The Android and iOS side, both behind one channel. A channel nobody answers
/// (no native side in this engine) is no surface: `begin` says false, the rest do
/// nothing.
class ChannelPublishHost implements PublishHost {
  ChannelPublishHost({@visibleForTesting MethodChannel? channel}) : _channel = channel ?? const MethodChannel(kPublishHostChannel);

  final MethodChannel _channel;
  final _signals = StreamController<PublishHostSignal>.broadcast();
  bool _listening = false;

  /// The translation from a native call to a signal, kept apart for tests.
  @visibleForTesting
  static PublishHostSignal? signalOf(MethodCall call) {
    final args = call.arguments;
    final postId = args is Map ? args['postId'] : null;
    return switch (call.method) {
      'cancelRequested' when postId is String => PublishHostCancelRequested(postId),
      'timedOut' => const PublishHostTimedOut(),
      'windowClosing' => const PublishHostWindowClosing(),
      'openPost' when postId is String => PublishHostOpenPost(postId),
      _ => null,
    };
  }

  /// Only once someone listens or a run begins: an isolate that only ends a run (a
  /// notification action on iOS) never takes the channel's handler.
  void _listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      final signal = signalOf(call);
      if (signal != null && !_signals.isClosed) _signals.add(signal);
    });
  }

  @override
  Future<bool> begin({required String postId, required String title, required List<PublishHostNetwork> networks}) async {
    _listen();
    try {
      return await _channel.invokeMethod<bool>('begin', {
            'postId': postId,
            'title': title,
            'networks': [for (final n in networks) n.toMap()],
          }) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> update(Map<String, Object?> snapshot) async {
    try {
      await _channel.invokeMethod<void>('update', snapshot);
    } on MissingPluginException {
      // No surface, and the run goes on.
    }
  }

  @override
  Future<void> end({required String postId, required String summary}) async {
    try {
      await _channel.invokeMethod<void>('end', {'postId': postId, 'summary': summary});
    } on MissingPluginException {
      // Nothing to end.
    }
  }

  @override
  Stream<PublishHostSignal> get signals {
    _listen();
    return _signals.stream;
  }

  @override
  void dispose() {
    if (_listening) _channel.setMethodCallHandler(null);
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

/// The host for this device: the channel on Android and iOS, nothing elsewhere or
/// in the demo.
PublishHost createPublishHost({required bool demo}) {
  if (demo || !(Env.isAndroid || Env.isIOS)) return const NoPublishHost();
  try {
    return ChannelPublishHost();
  } on Object catch (e) {
    // No messenger to talk over. Posting never depends on the keep-alive.
    debugPrint('publish-host unavailable: ${e.runtimeType}');
    return const NoPublishHost();
  }
}
