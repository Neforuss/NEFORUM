import 'loopback_relay.dart';

/// Web never gets a relay, so there is nothing to [LoopbackRelay.restart] or
/// close either.
Future<LoopbackRelay> startLoopbackRelay(Uri redirectUri, {required Uri callback}) async =>
    throw UnsupportedError('A browser cannot run the local server that catches sign-ins');
