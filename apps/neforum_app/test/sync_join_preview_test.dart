// The dry run before a device's first sync: what it says must be what the
// sync then does, it must change nothing, and the dialog must offer the
// choice the user makes.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/state/cloud_sync.dart';
import 'package:neforum_app/state/device_transfer.dart';
import 'package:neforum_app/state/media_host_config.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/settings/sync_section.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import 'sync_fixtures.dart';

const _timeout = Timeout(Duration(minutes: 3));
final _deviceOnly = kDeviceOnlySettings.keys.toSet();
final _deviceOnlyFields = kDeviceOnlyAccountFields.keys.toSet();

Future<SyncTestDevice> _computer(String folder) async {
  final d = SyncTestDevice(folder, settings: populatedSettings().copyWith(clearMediaHost: true, clearFallbackMediaHost: true));
  await d.addAccount(fakeAccount('x-1', 'x', tier: PlatformTier.byokApi, handle: '@me_x'), keys: {'access_token': 'fake-x'});
  await d.addAccount(fakeAccount('bluesky:did:plc:fake', 'bluesky', handle: 'me.bsky.social'), keys: {'app_password': 'fake-bsky'});
  await d.addAccount(fakeAccount('tumblr:fake', 'tumblr', tier: PlatformTier.byokApi, handle: 'fake'), keys: {'oauth_token': 'fake-tumblr'});
  await d.addMediaHost(MediaHostSlot.main, 'catbox', {'userhash': 'fake-userhash'});
  await d.addMediaHost(MediaHostSlot.fallback, 'litterbox', {'time': '72h'});
  return d;
}

SyncPreview _preview({
  SyncSeed seed = SyncSeed.file,
  int here = 1,
  int file = 16,
  Map<String, Object?> received = const {},
  Set<String> sent = const {},
  Map<String, String> merged = const {},
  Set<String> mergedInFile = const {},
  List<String> from = const ['DESKTOP-X (Windows)'],
  DateTime? hereOldest,
  DateTime? fileOldest,
}) =>
    SyncPreview(
      fileExists: true,
      firstJoin: true,
      seed: seed,
      here: SyncSideSummary(accounts: here, oldestConnection: hereOldest),
      file: SyncSideSummary(accounts: file, oldestConnection: fileOldest),
      received: received,
      sent: sent,
      mergedAccounts: merged,
      mergedInFile: mergedInFile,
      fromDevices: from,
    );

void main() {
  test('the dry run says what the first sync then does, settings and media hosts included, and changes nothing', () async {
    final folder = await syncFolderForTest(addTearDown);
    final a = await _computer(folder);
    await a.syncOnce();
    final b = SyncTestDevice(folder);
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    final file = File('$folder/$kSyncFileName');
    final bytes = file.readAsBytesSync();
    final before = await setupOf(b, deviceOnlySettings: _deviceOnly, deviceOnlyAccountFields: _deviceOnlyFields);
    final planner = await b.sync.joinPlanner(FolderSyncBackend(folder), b.passphrase);
    final preview = await planner.preview();
    planner.dispose();
    expect(file.readAsBytesSync(), bytes, reason: 'the dry run writes nothing into the file');
    expect(await setupOf(b, deviceOnlySettings: _deviceOnly, deviceOnlyAccountFields: _deviceOnlyFields), before, reason: 'nor anything here');
    expect(b.storage.json.containsKey('sync-state.json'), isFalse);

    final differing = [
      for (final e in syncedSettings(a.settings).entries)
        if ('${syncedSettings(b.settings)[e.key]}' != '${e.value}') e.key,
    ];
    final summary = describeJoinPreview(preview);
    expect(preview.seed, SyncSeed.file);
    expect(summary.headline, 'This device gets 3 accounts, 2 media hosts and ${differing.length} settings from ${preview.fromDevices.single}.');
    expect(summary.details, contains("Where the two differ, the sync file's setup wins (it has more accounts: 3 against 0 on this device)."));
    expect(summary.swapLabel, "Use this device's setup instead");

    await b.syncOnce();
    final after = await setupOf(b, deviceOnlySettings: _deviceOnly, deviceOnlyAccountFields: _deviceOnlyFields);
    expect((after['accounts']! as Map).length, 3, reason: 'the accounts the dry run announced arrived');
    expect(b.settings.mediaHostId, 'catbox');
    expect(b.settings.fallbackMediaHostId, 'litterbox');
    final changedSettings = [
      for (final k in kExportableSettings)
        if ('${syncedSettings(b.settings)[k]}' != '${syncedSettings(const AppSettings())[k]}') k,
    ];
    expect(changedSettings.toSet(), differing.toSet(), reason: 'the settings the dry run counted are the ones that changed');
    expect(preview.received.keys.where((k) => k.startsWith('setting:')).map((k) => k.substring(8)).toSet(), differing.toSet());
  }, timeout: _timeout);

  test('the device with more accounts is told its setup will be used, and the other choice turns it around', () async {
    final folder = await syncFolderForTest(addTearDown);
    final a = SyncTestDevice(folder, settings: otherSettings());
    await a.addAccount(fakeAccount('x-9', 'x', tier: PlatformTier.byokApi, handle: '@phone'), keys: {'access_token': 'fake-phone'});
    await a.syncOnce();
    final b = await _computer(folder);
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    final planner = await b.sync.joinPlanner(FolderSyncBackend(folder), b.passphrase);
    addTearDown(planner.dispose);

    final auto = await planner.preview();
    expect(auto.seed, SyncSeed.thisDevice);
    final summary = describeJoinPreview(auto);
    expect(summary.headline, "This device's setup will be used (it has more accounts: 3 against 1 in the sync file).");
    expect(summary.details.first, startsWith('This device also gets 1 account from '));
    expect(summary.details, contains(startsWith('The sync file gets 3 accounts, 2 media hosts and ')));
    expect(summary.swapLabel, "Use the sync file's setup instead");

    final swapped = await planner.preview(seed: SyncSeed.file);
    expect(swapped.seed, SyncSeed.file);
    expect(describeJoinPreview(swapped, chosen: true).details.first, "Where the two differ, the sync file's setup wins (as you chose).");
    expect(swapped.receivedOf('setting'), greaterThan(0), reason: "the file's settings would come here instead");
  }, timeout: _timeout);

  group('media hosts in the dry run match what the first sync does', () {
    Future<(SyncTestDevice, SyncTestDevice)> join(String folder, {required int fileAccounts, required int hereAccounts}) async {
      final a = SyncTestDevice(folder), b = SyncTestDevice(folder);
      for (var i = 0; i < fileAccounts; i++) {
        await a.addAccount(fakeAccount('x-a$i', 'x', tier: PlatformTier.byokApi, handle: '@a$i'), keys: {'access_token': 'fake-a$i'});
      }
      for (var i = 0; i < hereAccounts; i++) {
        await b.addAccount(fakeAccount('x-b$i', 'x', tier: PlatformTier.byokApi, handle: '@b$i'), keys: {'access_token': 'fake-b$i'});
      }
      return (a, b);
    }

    Future<SyncJoinSummary> dryRun(SyncTestDevice b, String folder) async {
      final planner = await b.sync.joinPlanner(FolderSyncBackend(folder), b.passphrase);
      final summary = describeJoinPreview(await planner.preview());
      planner.dispose();
      return summary;
    }

    test('only the hosts that arrive are counted (this device wins with its own main host)', () async {
      final folder = await syncFolderForTest(addTearDown);
      final (a, b) = await join(folder, fileAccounts: 1, hereAccounts: 2);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      await a.addMediaHost(MediaHostSlot.main, 'catbox', {'userhash': 'fake-userhash'});
      await a.addMediaHost(MediaHostSlot.fallback, 'litterbox', {'time': '72h'});
      await a.syncOnce();
      await b.addMediaHost(MediaHostSlot.main, 'catbox', {'userhash': 'fake-other-userhash'});
      final s = await dryRun(b, folder);
      expect(s.details, contains(startsWith('This device also gets 1 account and 1 media host from ')));
      expect(s.details.join(' '), isNot(contains('2 media hosts')));
      expect(s.details, contains("Your other devices' main media host (Catbox) is replaced by this device's own Catbox (other settings and keys) and removed: both slots are taken."));
      expect(s.details.last, 'Apart from that, nothing is deleted: what only one side has is kept.');
      await b.syncOnce();
      expect(b.settings.mediaHostId, 'catbox');
      expect(await b.secrets.read(MediaHostSlot.main.secretsKey), {'userhash': 'fake-other-userhash'}, reason: "this device's main host is unchanged");
      expect(b.settings.fallbackMediaHostId, 'litterbox', reason: 'the one host the dry run announced arrived');
    }, timeout: _timeout);

    test("the file wins: this device's main host moves to the empty fallback slot, with its keys, on both sides", () async {
      final folder = await syncFolderForTest(addTearDown);
      final (a, b) = await join(folder, fileAccounts: 2, hereAccounts: 1);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      await a.addMediaHost(MediaHostSlot.main, 'catbox', {'userhash': 'fake-userhash'});
      await a.syncOnce();
      await b.addMediaHost(MediaHostSlot.main, 's3',
          {'endpoint': 'https://s3.example.com', 'bucket': 'b', 'accessKeyId': 'FAKE', 'secretAccessKey': 'fake-secret', 'publicBaseUrl': 'https://cdn.example.com'});
      final s = await dryRun(b, folder);
      expect(s.headline, startsWith('This device gets 2 accounts and 1 media host from '));
      expect(s.details, contains("This device's main media host (S3-compatible bucket) moves to the fallback slot."));
      expect(s.details, contains('The sync file gets 1 account and 1 media host from this device.'));
      expect(s.details.last, 'Nothing is deleted: what only one side has is kept.');
      await b.syncOnce();
      await a.syncOnce();
      for (final d in [a, b]) {
        expect(d.settings.mediaHostId, 'catbox');
        expect(d.settings.fallbackMediaHostId, 's3');
        expect((await d.secrets.read(MediaHostSlot.fallback.secretsKey))?['secretAccessKey'], 'fake-secret', reason: 'the keys travel with the host');
      }
    }, timeout: _timeout);

    test('both slots taken by the winning side: the dry run names the host that is replaced, and that is what happens', () async {
      final folder = await syncFolderForTest(addTearDown);
      final (a, b) = await join(folder, fileAccounts: 2, hereAccounts: 1);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      await a.addMediaHost(MediaHostSlot.main, 'catbox', {'userhash': 'fake-userhash'});
      await a.addMediaHost(MediaHostSlot.fallback, 'litterbox', {'time': '72h'});
      await a.syncOnce();
      await b.addMediaHost(MediaHostSlot.main, 'webdav',
          {'webdavUrl': 'https://dav.example.com/m', 'username': 'u', 'password': 'fake-pass', 'publicUrlTemplate': 'https://dav.example.com/{path}'});
      final s = await dryRun(b, folder);
      expect(s.details, contains("This device's main media host (Nextcloud / WebDAV) is replaced by the sync file's Catbox and removed: both slots are taken."));
      expect(s.details.join(' '), isNot(contains('Nothing is deleted')));
      await b.syncOnce();
      expect([b.settings.mediaHostId, b.settings.fallbackMediaHostId], ['catbox', 'litterbox']);
    }, timeout: _timeout);
  });

  test('a device holding nothing that joins a file holding one account twice: nothing is said to come from it', () async {
    final folder = await syncFolderForTest(addTearDown);
    const mc = {'instance': 'https://m.example', 'domain': 'm.example', 'remoteAccountId': '42'};
    const u2 = '6f1c2d3e-0000-4abc-9def-000000000002', u3 = '6f1c2d3e-0000-4abc-9def-000000000003';
    final a = SyncTestDevice(folder), b = SyncTestDevice(folder), c = SyncTestDevice(folder), d = SyncTestDevice(folder);
    for (final x in [a, b, c, d]) {
      addTearDown(x.dispose);
    }
    await a.addAccount(fakeAccount('x-1', 'x', tier: PlatformTier.byokApi, handle: '@a'), keys: {'access_token': 'fake'});
    await a.syncOnce();
    await b.addAccount(fakeAccount(u2, 'mastodon', handle: '@me@m.example', config: mc));
    await c.addAccount(fakeAccount(u3, 'mastodon', handle: '@me@m.example', config: mc));
    await c.posts.upsert(Post.fromJson({
      'id': 'pc',
      'text': 'post pc',
      'createdAt': '2026-10-19T08:00:00.000Z',
      'updatedAt': '2026-10-19T08:00:00.000Z',
      'status': 'draft',
      'targets': [
        {'accountId': u3},
      ],
    }));
    // B and C join at the same moment, both over A's file: the cloud app
    // keeps C's write as a conflicted copy next to B's.
    final file = File('$folder/$kSyncFileName');
    final fromA = file.readAsBytesSync();
    await b.syncOnce();
    final fromB = file.readAsBytesSync();
    file.writeAsBytesSync(fromA);
    await c.syncOnce();
    File('$folder/NEFORUM (conflicted copy).neforumsync').writeAsBytesSync(file.readAsBytesSync());
    file.writeAsBytesSync(fromB);
    final planner = await d.sync.joinPlanner(FolderSyncBackend(folder), d.passphrase);
    final s = describeJoinPreview(await planner.preview());
    planner.dispose();
    expect(s.details.where((l) => l.contains('from this device')), isEmpty, reason: 'this device sends nothing of its own');
    expect(s.headline, startsWith('This device gets 2 accounts and 1 post from '));
    expect(s.details, contains(startsWith('The sync file holds 1 account twice')));
  }, timeout: _timeout);

  group('the dry run in words', () {
    test('what arrives, from which device, and why', () {
      final s = describeJoinPreview(_preview(received: {
        for (var i = 0; i < 16; i++) 'account:a$i': {},
        'mediaHosts:all': {'main': {'id': 'catbox'}, 'fallback': {'id': 'litterbox'}},
        for (var i = 0; i < 41; i++) 'setting:s$i': i,
      }));
      expect(s.headline, 'This device gets 16 accounts, 2 media hosts and 41 settings from DESKTOP-X (Windows).');
      expect(s.details, [
        "Where the two differ, the sync file's setup wins (it has more accounts: 16 against 1 on this device).",
        'Nothing is deleted: what only one side has is kept.',
      ]);
    });

    test('merged accounts, what goes out, several devices, singulars', () {
      final s = describeJoinPreview(_preview(
        here: 2,
        file: 2,
        hereOldest: DateTime.utc(2026, 5, 1),
        fileOldest: DateTime.utc(2025, 5, 1),
        received: {'account:a': {}, 'mediaHosts:all': {'main': {'id': 'catbox'}, 'fallback': null}, 'setting:theme': 'dark'},
        sent: {'account:b', 'post:p'},
        merged: {'here-id': 'file-id'},
        from: ['DESKTOP-X (Windows)', 'Phone (Android)', 'Tablet (iOS)'],
      ));
      expect(s.headline, 'This device gets 1 account, 1 media host and 1 setting from DESKTOP-X (Windows) and 2 other devices.');
      expect(s.details, [
        "Where the two differ, the sync file's setup wins (both have 2 accounts, and its oldest connection is older).",
        'The sync file gets 1 account and 1 post from this device.',
        '1 account connected on both becomes one, with the newer sign-in.',
        'Nothing is deleted: what only one side has is kept.',
      ]);
    });

    test('an account the sync file holds twice, which this device has in neither copy, is worded as such', () {
      final s = describeJoinPreview(_preview(received: {'account:a': {}}, merged: {'copy': 'kept', 'here-id': 'file-id'}, mergedInFile: {'copy'}));
      expect(s.details, containsAll([
        '1 account connected on both becomes one, with the newer sign-in.',
        'The sync file holds 1 account twice (two devices connected it at the same moment): it becomes one, with the newer sign-in.',
      ]));
      final only = describeJoinPreview(_preview(received: {'account:kept': {}}, merged: {'copy': 'kept'}, mergedInFile: {'copy'}));
      expect(only.details.join(' '), isNot(contains('connected on both')));
      expect(only.headline, startsWith('This device gets 1 account'));
    });

    test('this device wins; nothing to get; a full tie', () {
      final mine = describeJoinPreview(_preview(seed: SyncSeed.thisDevice, here: 16, file: 3, from: const []));
      expect(mine.headline, "This device's setup will be used (it has more accounts: 16 against 3 in the sync file).");
      final nothing = describeJoinPreview(_preview(from: const []));
      expect(nothing.headline, 'This device already has everything the sync file has.');
      final tie = describeJoinPreview(_preview(here: 0, file: 0, from: const []));
      expect(tie.details.first, "Where the two differ, the sync file's setup wins (both have 0 accounts, so the sync file stays as it is).");
    });
  });

  testWidgets('the dialog shows the dry run and answers with the choice', (tester) async {
    final answers = <SyncJoinChoice?>[];
    const summary = SyncJoinSummary(headline: 'This device gets 16 accounts.', details: ['Nothing is deleted.'], swapLabel: "Use this device's setup instead");
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light, AccentChoice.neforum),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => answers.add(await showDialog<SyncJoinChoice>(context: context, builder: (_) => const SyncJoinDialog(summary: summary))),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    for (final (button, answer) in [('Join', SyncJoinChoice.join), ("Use this device's setup instead", SyncJoinChoice.swap), ('Cancel', null)]) {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Join the sync file?'), findsOneWidget);
      expect(find.text('This device gets 16 accounts.'), findsOneWidget);
      expect(find.text('Nothing is deleted.'), findsOneWidget);
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      expect(answers.last, answer);
    }
  });
}
