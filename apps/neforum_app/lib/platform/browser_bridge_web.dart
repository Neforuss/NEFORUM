import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:neforum_core/neforum_core.dart' show HandoffSnippet, SecretStore;

import 'browser_bridge.dart';

/// The web preview cannot listen on a port: no bridge.
BrowserBridge createBrowserBridge({required SecretStore secrets, required DateTime Function() clock, required List<int> ports, required String version}) =>
    _NoBrowserBridge(clock);

Future<String?> revealExtensionFiles() async => null;

Future<List<InstalledBrowser>> installedBrowsers({bool refresh = false}) async => const [];

Future<bool> browserAvailable(String id) async => false;

Future<bool> openInBrowser(String id, Uri url) async => false;

class _NoBrowserBridge extends BrowserBridge {
  _NoBrowserBridge(this._clock);

  final DateTime Function() _clock;
  final ValueNotifier<BrowserBridgeStatus> _status = ValueNotifier(const BrowserBridgeStatus(BrowserBridgeState.unsupported));
  final ValueNotifier<List<PairedBrowser>> _browsers = ValueNotifier(const []);
  final ValueNotifier<PairingCode?> _pairing = ValueNotifier(null);

  @override
  ValueListenable<BrowserBridgeStatus> get status => _status;
  @override
  ValueListenable<List<PairedBrowser>> get browsers => _browsers;
  @override
  ValueListenable<PairingCode?> get pairing => _pairing;
  @override
  Stream<BrowserFillResult> get results => const Stream.empty();
  @override
  BrowserJob? get job => null;
  @override
  DateTime now() => _clock();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  PairingCode startPairing() => PairingCode(code: '', expiresAt: _clock());
  @override
  void cancelPairing() {}
  @override
  Future<void> remove(String token) async {}
  @override
  Future<void> forgetAll() async {}
  @override
  Future<void> makeFirst(String token) async {}
  @override
  Future<void> setProgram(String token, InstalledBrowser program) async {}
  @override
  BrowserJob? createJob({
    required String platformId,
    required String platformName,
    required String url,
    required List<String> hosts,
    required String text,
    String? title,
    List<HandoffSnippet> snippets = const [],
    List<BrowserJobMedia> media = const [],
    String steps = '',
    bool quickPost = false,
    String? target,
  }) =>
      null;
  @override
  void clearJob([String? id]) {}
  @override
  Future<void> dispose() async {}
}
