// Settings > Sync > Set up, driven like a user: the dry run's Join and "Use
// this device's setup instead" must reach sync-state.json, and the same
// storage with a wrong passphrase must be refused.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/state/cloud_sync.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/settings/sync_section.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'sync_fixtures.dart';

const _passphrase = 'a shared fake sync passphrase';

/// Lets real work (files, the passphrase stretching on its isolate) run
/// until [done] holds, pumping frames in between.
Future<void> _until(WidgetTester tester, bool Function() done, {int tries = 400}) async {
  for (var i = 0; i < tries && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    await tester.pump();
  }
  expect(done(), isTrue, reason: 'timed out');
}

void main() {
  late String folder;
  late AppServices services;
  late MemoryAppStorage storage;

  // A computer: there a folder is a plain folder.
  final computer = TargetPlatformVariant.only(TargetPlatform.windows);

  Future<void> prepare(WidgetTester tester, {bool alreadyOn = false}) async {
    await tester.runAsync(() async {
      folder = (await Directory.systemTemp.createTemp('neforum-setup-dialog-')).path;
      final a = SyncTestDevice(folder, passphrase: _passphrase);
      await a.addAccount(fakeAccount('x-file', 'x', tier: PlatformTier.byokApi, handle: '@file'), keys: {'access_token': 'fake'});
      await a.syncOnce();
      a.dispose();
      storage = MemoryAppStorage();
      services = await AppServices.create(demo: true, storage: storage);
      if (alreadyOn) await services.saveSettings(services.settings.copyWith(syncProviderId: 'folder', syncConfig: {'folder': folder}));
    });
    addTearDown(() => tester.runAsync(() => Directory(folder).delete(recursive: true)));
    await tester.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => SyncSetupDialog(opened: alreadyOn ? null : (bookmark: 'unused on a computer', name: folder, isFile: false)),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> fillAndTurnOn(WidgetTester tester, String passphrase) async {
    await tester.enterText(find.widgetWithText(TextField, 'Passphrase'), passphrase);
    await tester.tap(find.text('I have written the passphrase down'));
    await tester.pump();
    await tester.tap(find.text('Turn on sync'));
    await tester.pump();
  }

  bool joinDialogShown() => find.text('Join the sync file?').evaluate().isNotEmpty;

  testWidgets('"Use this device\'s setup instead", then Join: the swapped choice is what the first sync will use', (tester) async {
    await prepare(tester);
    await fillAndTurnOn(tester, _passphrase);
    await _until(tester, joinDialogShown);
    final swap = find.textContaining('setup instead');
    final swapLabel = (tester.widget<Text>(swap)).data!;
    final swapped = swapLabel == "Use this device's setup instead" ? SyncSeed.thisDevice : SyncSeed.file;
    await tester.tap(swap);
    await tester.pump();
    await _until(tester, () => joinDialogShown() && find.textContaining('as you chose').evaluate().isNotEmpty);
    await tester.tap(find.text('Join'));
    await _until(tester, () => storage.json.containsKey('sync-state.json'));
    expect(storage.json['sync-state.json'], SyncEngine.joinState(swapped));
    expect(services.settings.syncConfig['folder'], folder);
  }, variant: computer);

  testWidgets('Join: the seed the dry run showed is what the first sync will use', (tester) async {
    await prepare(tester);
    await fillAndTurnOn(tester, _passphrase);
    await _until(tester, joinDialogShown);
    final shown = find.textContaining("Use this device's setup instead").evaluate().isNotEmpty ? SyncSeed.file : SyncSeed.thisDevice;
    await tester.tap(find.text('Join'));
    await _until(tester, () => storage.json.containsKey('sync-state.json'));
    expect(storage.json['sync-state.json'], SyncEngine.joinState(shown));
  }, variant: computer);

  testWidgets('the same storage with a wrong passphrase is refused, and nothing is saved', (tester) async {
    await prepare(tester, alreadyOn: true);
    await fillAndTurnOn(tester, 'a wrong fake passphrase');
    await _until(tester, () => find.textContaining('The sync passphrase does not open the sync file').evaluate().isNotEmpty);
    expect(joinDialogShown(), isFalse, reason: 'the same file: no dry run');
    final saved = await tester.runAsync(() => services.secrets.read(kSyncSecretsKey));
    expect(saved?['passphrase'], isNot('a wrong fake passphrase'));
  }, variant: computer);

  test('a new WebDAV address, S3 bucket or folder is a new storage; a Mac bookmark is not', () {
    String id(String provider, Map<String, String> c, {bool phone = false}) => syncStorageIdentity(provider, c, filesApp: phone);
    expect(id('onedrive', {'folder': 'C:/Sync/NEFORUM'}), id('dropbox', {'folder': 'C:/Sync/NEFORUM', 'bookmark': 'mac-bookmark'}),
        reason: 'one folder is one file, whatever the cloud app is called');
    expect(id('onedrive', {'folder': 'C:/Sync/A'}), isNot(id('onedrive', {'folder': 'C:/Sync/B'})));
    expect(id('nextcloud', {'url': 'https://cloud.example.com/dav/a', 'username': 'u'}),
        isNot(id('nextcloud', {'url': 'https://cloud.example.com/dav/b', 'username': 'u'})));
    expect(id('nextcloud', {'url': 'https://cloud.example.com/dav/a/', 'username': 'u'}), id('nextcloud', {'url': 'https://Cloud.Example.com/dav/a', 'username': 'u'}));
    expect(id('r2', {'endpoint': 'https://acc.r2.cloudflarestorage.com', 'bucket': 'one'}), isNot(id('r2', {'endpoint': 'https://acc.r2.cloudflarestorage.com', 'bucket': 'two'})));
    expect(id('r2', {'endpoint': 'https://acc.r2.cloudflarestorage.com', 'bucket': 'b', 'folder': 'x'}),
        isNot(id('r2', {'endpoint': 'https://acc.r2.cloudflarestorage.com', 'bucket': 'b', 'folder': 'y'})));
    expect(id('icloud', {'folder': 'NEFORUM', 'bookmark': 'b1'}, phone: true), isNot(id('icloud', {'folder': 'NEFORUM', 'bookmark': 'b2'}, phone: true)));
    expect(id('googledrive-direct', {'clientId': 'a.apps.googleusercontent.com'}), isNot(id('googledrive-direct', {'clientId': 'b.apps.googleusercontent.com'})));
  });
}
