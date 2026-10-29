// The Linux desktop paths that a widget test can reach: the keyring when no
// Secret Service runs, the tray question to the runner, and the clipboard
// channel being used there. (The runner itself, linux/runner, is built and
// run by CI's linux job.)

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/clipboard_media.dart';
import 'package:neforum_app/platform/desktop.dart';
import 'package:neforum_app/platform/secure_secret_store.dart';

const _keyringChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// The keyring plugin: failing with libsecret's [failWith] code (as
/// flutter_secure_storage_linux reports it), or working on [data].
void _keyring({String? failWith, Map<String, String>? data}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_keyringChannel, (call) async {
    if (failWith != null) {
      throw PlatformException(code: failWith, message: 'secret_service_get_sync: The name org.freedesktop.secrets was not provided');
    }
    final args = call.arguments as Map;
    final key = args['key'] as String?;
    switch (call.method) {
      case 'read':
        return data![key];
      case 'write':
        data![key!] = args['value'] as String;
      case 'delete':
        data!.remove(key);
    }
    return null;
  });
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SecureSecretStore.unavailableReason.value = null);
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_keyringChannel, null);
    debugDefaultTargetPlatformOverride = null;
    SecureSecretStore.unavailableReason.value = null;
  });

  group('keyring on Linux', () {
    test('without a Secret Service every call says what to install, and the banner gets the same words', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      _keyring(failWith: 'Libsecret error');
      final store = SecureSecretStore();

      await expectLater(store.read('a'), throwsA(isA<SecretStoreUnavailableException>().having((e) => e.message, 'message', contains('GNOME Keyring or KWallet'))));
      expect(SecureSecretStore.unavailableReason.value, contains('Secret Service'));
      await expectLater(store.write('a', {'token': 't'}), throwsA(isA<SecretStoreUnavailableException>()));
      await expectLater(store.delete('a'), throwsA(isA<SecretStoreUnavailableException>()));
      // A failed write is not kept as if it were saved.
      await expectLater(store.read('a'), throwsA(isA<SecretStoreUnavailableException>()));
    });

    test('a locked keyring asks to unlock it', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      _keyring(failWith: 'KeyringLocked');
      await expectLater(SecureSecretStore().read('a'), throwsA(isA<SecretStoreUnavailableException>().having((e) => e.message, 'message', contains('locked'))));
      expect(SecureSecretStore.linuxKeyringMessage('KeyringLocked'), contains('Unlock it'));
    });

    test('the start-up check finds the problem, and clears it once the keyring answers', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      _keyring(failWith: 'Libsecret error');
      expect(await SecureSecretStore.verifyAvailable(), isFalse);
      expect(SecureSecretStore.unavailableReason.value, isNotNull);

      _keyring(data: {});
      expect(await SecureSecretStore.verifyAvailable(), isTrue);
      expect(SecureSecretStore.unavailableReason.value, isNull);
    });

    test('elsewhere the plugin error is passed on unchanged (and nothing is checked at start)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      _keyring(failWith: 'Some error');
      await expectLater(SecureSecretStore().read('a'), throwsA(isA<PlatformException>()));
      expect(SecureSecretStore.unavailableReason.value, isNull);
      expect(await SecureSecretStore.verifyAvailable(), isTrue);
    });

    test('a working keyring stores and reads back', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      _keyring(data: {});
      final store = SecureSecretStore();
      await store.write('acct', {'token': 'abc'});
      expect(await SecureSecretStore().read('acct'), {'token': 'abc'});
    });
  });

  group('tray on Linux', () {
    const channel = MethodChannel('neforum/desktop');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('asks the runner whether a panel shows tray icons', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final calls = <String>[];
      var answer = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return answer;
      });
      expect(await DesktopIntegration.instance.trayAvailable(), isFalse, reason: 'plain GNOME: closing the window must quit');
      answer = true;
      expect(await DesktopIntegration.instance.trayAvailable(), isTrue);
      expect(calls, ['statusNotifierHostAvailable', 'statusNotifierHostAvailable']);
    });

    test('a runner that cannot answer counts as no tray', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(await DesktopIntegration.instance.trayAvailable(), isFalse);
    });

    test('Windows and macOS always have one', () async {
      for (final p in [TargetPlatform.windows, TargetPlatform.macOS]) {
        debugDefaultTargetPlatformOverride = p;
        expect(await DesktopIntegration.instance.trayAvailable(), isTrue, reason: '$p');
      }
    });
  });

  group('clipboard on Linux', () {
    const channel = MethodChannel('neforum/clipboard');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('photos are copied and pasted through the runner', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(ClipboardMedia.supported, isTrue);
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'readImage');
        return {'png': png};
      });
      final pasted = await ClipboardMedia.readImage();
      expect(pasted!.png, png);

      messenger.setMockMethodCallHandler(channel, (call) async => {'files': ['/home/me/Pictures/cat.jpg']});
      expect((await ClipboardMedia.readImage())!.files, ['/home/me/Pictures/cat.jpg']);
    });
  });
}
