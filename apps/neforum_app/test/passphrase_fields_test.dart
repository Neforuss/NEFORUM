// 1.4.3: the backup passphrase fields (Move to another device: Export's own
// passphrase and Import's) write codes in capitals with dashes, leave custom
// passphrases as typed, and Import still opens a backup locked with the
// exact lowercase text before 1.4.3.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/settings/move_device.dart';
import 'package:neforum_app/widgets/passphrase_input.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'sync_fixtures.dart' show MemoryAppStorage;

const _fast = BackupKdfParams.testing;
const _payload = <String, dynamic>{'app': 'NEFORUM', 'payloadVersion': 1};

Future<BackupPayload> _openFast(Uint8List bytes, String passphrase) async =>
    BackupPayload.parse(await decryptBackup(bytes, passphrase, minimum: _fast));

/// Lets real work run until [done] holds, pumping frames in between.
Future<void> _until(WidgetTester tester, bool Function() done, {int tries = 200}) async {
  for (var i = 0; i < tries && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  expect(done(), isTrue, reason: 'timed out');
}

String _shown(WidgetTester tester, Finder field) => tester.widget<TextField>(field).controller!.text;

Future<void> _typeKeys(WidgetTester tester, Finder field, String text) async {
  for (final ch in text.split('')) {
    await tester.enterText(field, _shown(tester, field) + ch);
    await tester.pump();
  }
}

void main() {
  group('Import', () {
    final field = find.widgetWithText(TextField, 'Passphrase');

    /// Shows the passphrase step for a backup locked with [lockedWith];
    /// returns what the dialog popped through [result].
    Future<List<BackupPayload?>> show(WidgetTester tester, String lockedWith) async {
      final bytes = (await tester.runAsync(() => encryptBackup(_payload, lockedWith, params: _fast)))!;
      final result = <BackupPayload?>[];
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => result.add(
                  await showDialog<BackupPayload>(context: context, builder: (_) => BackupPassphraseDialog(bytes: bytes, open: _openFast))),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('keyboard hints and a code in shape as typed', (tester) async {
      await show(tester, 'K7QF-MZ3D-W9TB');
      final tf = tester.widget<TextField>(field);
      expect(tf.autocorrect, isFalse);
      expect(tf.enableSuggestions, isFalse);
      expect(tf.textCapitalization, TextCapitalization.none);
      expect(tf.inputFormatters?.whereType<PassphraseInputFormatter>(), hasLength(1));
      await _typeKeys(tester, field, 'k7qfmz3d');
      expect(_shown(tester, field), 'K7QF-MZ3D');
    });

    testWidgets('a backup locked with the code in shape opens when the code is typed in lowercase', (tester) async {
      final result = await show(tester, 'K7QF-MZ3D-W9TB');
      await _typeKeys(tester, field, 'k7qfmz3dw9tb');
      await tester.tap(find.text('Open'));
      await _until(tester, () => result.isNotEmpty);
      expect(result.single, isNotNull);
    });

    testWidgets('a backup locked with a lowercase code-shaped passphrase before 1.4.3 opens when typed as it was set', (tester) async {
      final result = await show(tester, 'k7qfmz3dw9tb');
      await _typeKeys(tester, field, 'k7qfmz3dw9tb');
      expect(_shown(tester, field), 'K7QF-MZ3D-W9TB');
      await tester.tap(find.text('Open'));
      await _until(tester, () => result.isNotEmpty);
      expect(result.single, isNotNull);
    });

    testWidgets('pasted in one go, the same', (tester) async {
      final result = await show(tester, 'k7qf-mz3d-w9tb');
      await tester.enterText(field, 'k7qf-mz3d-w9tb');
      await tester.pump();
      expect(_shown(tester, field), 'K7QF-MZ3D-W9TB');
      await tester.tap(find.text('Open'));
      await _until(tester, () => result.isNotEmpty);
      expect(result.single, isNotNull);
    });

    testWidgets('a custom passphrase is typed as is, and a wrong one is refused', (tester) async {
      final result = await show(tester, 'Correct horse 2026');
      await _typeKeys(tester, field, 'correct horse 2026');
      expect(_shown(tester, field), 'correct horse 2026', reason: 'never reshaped, never re-cased');
      await tester.tap(find.text('Open'));
      await _until(tester, () => find.text('Wrong passphrase or damaged file.').evaluate().isNotEmpty);
      expect(result, isEmpty);
      await tester.enterText(field, 'Correct horse 2026');
      await tester.tap(find.text('Open'));
      await _until(tester, () => result.isNotEmpty);
      expect(result.single, isNotNull);
    });
  });

  group('Export, my own passphrase', () {
    final field = find.widgetWithText(TextField, 'Your passphrase');

    Future<void> show(WidgetTester tester) async {
      final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: MemoryAppStorage())))!;
      await tester.pumpWidget(ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AccentChoice.neforum),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(context: context, builder: (_) => const ExportBackupDialog()),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Use my own passphrase'));
      await tester.tap(find.text('Use my own passphrase'));
      await tester.pumpAndSettle();
    }

    testWidgets('a code-shaped passphrase is written and kept in capitals with dashes, with the note; the strength meter still works',
        (tester) async {
      await show(tester);
      final tf = tester.widget<TextField>(field);
      expect(tf.autocorrect, isFalse);
      expect(tf.enableSuggestions, isFalse);
      expect(tf.textCapitalization, TextCapitalization.none);
      expect(find.text(kPassphraseCodeNote), findsNothing);

      await _typeKeys(tester, field, 'k7qfmz3');
      expect(_shown(tester, field), 'K7QF-MZ3');
      expect(find.text('At least 10 characters (14 or more recommended)'), findsOneWidget);
      expect(find.text(kPassphraseCodeNote), findsOneWidget);

      await _typeKeys(tester, field, 'dw9tb');
      expect(_shown(tester, field), 'K7QF-MZ3D-W9TB');
      expect(find.text('Good'), findsOneWidget);
    });

    testWidgets('any other passphrase is kept exactly as typed, without the note', (tester) async {
      await show(tester);
      await _typeKeys(tester, field, 'my cat Biscuit 7');
      expect(_shown(tester, field), 'my cat Biscuit 7');
      expect(find.text(kPassphraseCodeNote), findsNothing);
      expect(find.text('Good'), findsOneWidget);
    });
  });
}
