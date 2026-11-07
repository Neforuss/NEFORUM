import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'env.dart';

/// One network as a run starts. Names and sizes only: the post's text never goes
/// over this channel, because iOS and an Android lock screen show what it carries.
@immutable
class PublishHostNetwork {
  const PublishHostNetwork({required this.id, required this.name, required this.bytes});

  final String id;
  final String name;
  final int bytes;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'bytes': bytes};
}

/// What the operating system's side tells a run.
sealed class PublishHostEvent {
  const PublishHostEvent();
}

/// The person pressed Cancel outside the app.
class PublishHostCancelRequested extends PublishHostEvent {
  const PublishHostCancelRequested(this.postId);
  final String postId;
}

/// The system took back the time it gave. On iOS a person's Stop in the system's
/// own view looks the same.
class PublishHostTimedOut extends PublishHostEvent {
  const PublishHostTimedOut();
}

/// The app's time is about to end and it will be frozen.
class PublishHostWindowClosing extends PublishHostEvent {
  const PublishHostWindowClosing();
}

/// Keeps a run going outside the app and shows it there: channel
/// `neforum/publish_host`. Nothing here may stop a run: a host that fails only
/// means no surface.
abstract interface class PublishHost {
  Stream<PublishHostEvent> get events;

  /// True when the system's side took the run on.
  Future<bool> begin({required String postId, required String title, required List<PublishHostNetwork> networks});

  /// [snapshot] comes from `PublishSurfaceState.toSnapshot`.
  Future<void> update(Map<String, Object?> snapshot);

  Future<void> end({required String postId, required String summary});
}

/// Desktop, demo and tests: nothing outside the app to keep or show.
class NoopPublishHost implements PublishHost {
  const NoopPublishHost();

  @override
  Stream<PublishHostEvent> get events => const Stream.empty();

  @override
  Future<bool> begin({required String postId, required String title, required List<PublishHostNetwork> networks}) async => false;

  @override
  Future<void> update(Map<String, Object?> snapshot) async {}

  @override
  Future<void> end({required String postId, required String summary}) async {}
}

/// The Android and iOS side, both behind one channel.
class ChannelPublishHost implements PublishHost {
  ChannelPublishHost({@visibleForTesting this._channel = const MethodChannel('neforum/publish_host')});

  final MethodChannel _channel;
  final _events = StreamController<PublishHostEvent>.broadcast();
  bool _listening = false;

  /// The translation from a native call to an event, kept apart for tests.
  @visibleForTesting
  static PublishHostEvent? eventOf(MethodCall call) => switch (call.method) {
        'cancelRequested' => switch (call.arguments) {
            {'postId': final String postId} => PublishHostCancelRequested(postId),
            _ => null,
          },
        'timedOut' => const PublishHostTimedOut(),
        'windowClosing' => const PublishHostWindowClosing(),
        _ => null,
      };

  void _listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      final event = eventOf(call);
      if (event != null) _events.add(event);
    });
  }

  @override
  Stream<PublishHostEvent> get events => _events.stream;

  @override
  Future<bool> begin({required String postId, required String title, required List<PublishHostNetwork> networks}) async {
    try {
      _listen();
      return await _channel.invokeMethod<bool>('begin', {
            'postId': postId,
            'title': title,
            'networks': [for (final n in networks) n.toJson()],
          }) ??
          false;
    } on Object catch (e) {
      debugPrint('Publish host not available: ${e.runtimeType}');
      return false;
    }
  }

  @override
  Future<void> update(Map<String, Object?> snapshot) async {
    try {
      await _channel.invokeMethod<void>('update', snapshot);
    } on Object {
      // No surface, and the run goes on.
    }
  }

  @override
  Future<void> end({required String postId, required String summary}) async {
    try {
      await _channel.invokeMethod<void>('end', {'postId': postId, 'summary': summary});
    } on Object {
      // Nothing to end.
    }
  }
}

/// The host for this platform.
PublishHost publishHostForPlatform({required bool demo}) => !demo && Env.isMobile ? ChannelPublishHost() : const NoopPublishHost();
