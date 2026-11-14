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
import 'package:neforum_app/widgets/passphrase_input.dart';
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

  /// [filePassphrase]: what the sync file in the folder is locked with, or
  /// `null` for an empty folder. [stored]: the passphrase this device keeps
  /// (with [alreadyOn]).
  Future<void> prepare(WidgetTester tester, {bool alreadyOn = false, String? filePassphrase = _passphrase, String? stored}) async {
    await tester.runAsync(() async {
      folder = (await Directory.systemTemp.createTemp('neforum-setup-dialog-')).path;
      if (filePassphrase != null) {
        final a = SyncTestDevice(folder, passphrase: filePassphrase);
        await a.addAccount(fakeAccount('x-file', 'x', tier: PlatformTier.byokApi, handle: '@file'), keys: {'access_token': 'fake'});
        await a.syncOnce();
        a.dispose();
      }
      storage = MemoryAppStorage();
      services = await AppServices.create(demo: true, storage: storage);
      if (alreadyOn) await services.saveSettings(services.settings.copyWith(syncProviderId: 'folder', syncConfig: {'folder': folder}));
      if (stored != null) await services.secrets.write(kSyncSecretsKey, {'passphrase': stored});
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

  // 1.4.3: the passphrase field writes codes in capitals with dashes.
  final field = find.widgetWithText(TextField, 'Passphrase');
  String shown(WidgetTester tester) => tester.widget<TextField>(field).controller!.text;

  /// Types [text] one key at a time at the end of the field.
  Future<void> typeKeys(WidgetTester tester, String text) async {
    for (final ch in text.split('')) {
      await tester.enterText(field, shown(tester) + ch);
      await tester.pump();
    }
  }

  Future<void> turnOn(WidgetTester tester) async {
    await tester.tap(find.text('I have written the passphrase down'));
    await tester.pump();
    await tester.tap(find.text('Turn on sync'));
    await tester.pump();
  }

  Future<String?> savedPassphrase(WidgetTester tester) async => (await tester.runAsync(() => services.secrets.read(kSyncSecretsKey)))?['passphrase'];

  testWidgets('the passphrase field: keyboard hints, codes in shape as typed and pasted, custom passphrases untouched', (tester) async {
    await prepare(tester, filePassphrase: null);
    final tf = tester.widget<TextField>(field);
    expect(tf.autocorrect, isFalse);
    expect(tf.enableSuggestions, isFalse);
    expect(tf.textCapitalization, TextCapitalization.none, reason: 'a custom passphrase must come out exactly as typed');
    expect(tf.keyboardType, TextInputType.text, reason: 'a computer');
    expect(tf.inputFormatters?.whereType<PassphraseInputFormatter>(), hasLength(1));

    await typeKeys(tester, 'k7qfm');
    expect(shown(tester), 'K7QF-M');
    expect(tester.widget<TextField>(field).controller!.selection, const TextSelection.collapsed(offset: 6));
    expect(find.text(kPassphraseCodeNote), findsOneWidget);

    await tester.enterText(field, 'k7qf mz3d w9tb xc4n p2rv h8lg');
    await tester.pump();
    expect(shown(tester), 'K7QF-MZ3D-W9TB-XC4N-P2RV-H8LG', reason: 'a paste');

    await tester.enterText(field, '');
    await typeKeys(tester, 'hello there');
    expect(shown(tester), 'hello there');
    expect(find.text(kPassphraseCodeNote), findsNothing);

    await tester.tap(find.byTooltip('Generate'));
    await tester.pump();
    final generated = shown(tester);
    expect(formatPassphraseCode(generated), generated, reason: 'a generated code is already in shape');
    expect(find.text(kPassphraseCodeNote), findsOneWidget);
  }, variant: computer);

  testWidgets('on Android the passphrase keyboard is the visible-password one', (tester) async {
    expect(passphraseKeyboardType, TextInputType.visiblePassword);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a new sync file: a code-shaped passphrase typed in lowercase is kept in capitals with dashes, as shown', (tester) async {
    await prepare(tester, filePassphrase: null);
    await typeKeys(tester, 'k7qfmz3dw9tb');
    expect(shown(tester), 'K7QF-MZ3D-W9TB');
    await turnOn(tester);
    await _until(tester, () => services.settings.syncProviderId == 'folder');
    expect(await savedPassphrase(tester), 'K7QF-MZ3D-W9TB');
  }, variant: computer);

  testWidgets('joining a file locked with a lowercase code-shaped passphrase before 1.4.3: typed as it was set, it still opens', (tester) async {
    await prepare(tester, filePassphrase: 'k7qfmz3dw9tb');
    await typeKeys(tester, 'k7qfmz3dw9tb');
    expect(shown(tester), 'K7QF-MZ3D-W9TB');
    await turnOn(tester);
    await _until(tester, () => joinDialogShown() || find.textContaining('does not open').evaluate().isNotEmpty);
    expect(joinDialogShown(), isTrue, reason: 'the exact text typed opened it');
    await tester.tap(find.text('Join'));
    await _until(tester, () => storage.json.containsKey('sync-state.json'));
    expect(await savedPassphrase(tester), 'k7qfmz3dw9tb', reason: 'the passphrase that opens the file is the one kept');
  }, variant: computer);

  testWidgets('joining a file locked with the code in shape: typed in lowercase with spaces, it opens', (tester) async {
    await prepare(tester, filePassphrase: 'K7QF-MZ3D-W9TB');
    await tester.enterText(field, 'k7qf mz3d w9tb');
    await turnOn(tester);
    await _until(tester, () => joinDialogShown() || find.textContaining('does not open').evaluate().isNotEmpty);
    expect(joinDialogShown(), isTrue);
    await tester.tap(find.text('Join'));
    await _until(tester, () => storage.json.containsKey('sync-state.json'));
    expect(await savedPassphrase(tester), 'K7QF-MZ3D-W9TB');
  }, variant: computer);

  testWidgets('the same storage: a stored lowercase passphrase is shown as stored, and typed again it still opens', (tester) async {
    await prepare(tester, alreadyOn: true, filePassphrase: 'k7qfmz3dw9tb', stored: 'k7qfmz3dw9tb');
    expect(shown(tester), 'k7qfmz3dw9tb', reason: 'not reshaped until edited');
    await tester.enterText(field, '');
    await typeKeys(tester, 'k7qfmz3dw9tb');
    expect(shown(tester), 'K7QF-MZ3D-W9TB');
    // Already ticked: this device has the passphrase stored.
    await tester.tap(find.text('Turn on sync'));
    await tester.pump();
    const joined = 'Sync is on: this device joined the sync file';
    await _until(tester, () => find.text(joined).evaluate().isNotEmpty || find.textContaining('does not open').evaluate().isNotEmpty);
    expect(find.textContaining('does not open'), findsNothing);
    expect(await savedPassphrase(tester), 'k7qfmz3dw9tb');
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
