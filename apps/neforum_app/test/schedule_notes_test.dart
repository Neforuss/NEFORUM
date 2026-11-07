// What the schedule sheet says about a time: computed for that time from the
// same decision the hand-over makes, and from the sign-in status file. Real
// adapters: their rules are what the text must not contradict.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/ui/compose/schedule_notes.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

void main() {
  // Facebook's rules read the real clock, so these times are relative to it.
  final now = DateTime.now();
  DateTime days(int n) => now.add(Duration(days: n));
  // A wall clock hour in the daytime.
  DateTime atHour(int hour) {
    final d = days(5);
    return DateTime(d.year, d.month, d.day, hour, 12);
  }

  ConnectedAccount account(String platform, {PlatformTier tier = PlatformTier.openApi, bool enabled = true, Map<String, dynamic> config = const {}, String? id, String? handle}) =>
      ConnectedAccount(id: id ?? platform, platformId: platform, tier: tier, displayName: platform, handle: handle, enabled: enabled, createdAt: now, config: config);

  SignInStatus status(String id, DateTime? end, {bool renews = false, bool about = false, bool early = false, DateTime? refused}) => SignInStatus(
        accountId: id,
        limit: SignInLimit.date,
        source: SignInDateSource.serverReported,
        renewsItself: renews,
        state: renews ? SignInState.renewsUntil : SignInState.endsOn,
        expiresAt: end,
        about: about,
        earlyRevocationPossible: early,
        lastAuthFailure: refused,
      );

  List<ScheduleNote> notes(
    List<ConnectedAccount> accounts,
    DateTime at, {
    Map<String, DateTime>? eachAt,
    Map<String, SignInStatus> statuses = const {},
    bool delegate = true,
    ScheduleDevice device = ScheduleDevice.desktop,
    String text = 'Hello there',
    List<String> parts = const [],
    Set<String> automatic = const {},
    DateTime? clockNow,
    Map<String, PostTarget>? targets,
  }) {
    final post = Post(
      id: 'p',
      text: text,
      additionalParts: parts,
      createdAt: now,
      updatedAt: now,
      scheduledAt: at,
      status: PostStatus.scheduled,
      targets: [
        for (final a in accounts) targets?[a.id] ?? PostTarget(accountId: a.id, overrides: PostOverrides(scheduledAt: eachAt?[a.id])),
      ],
    );
    return scheduleNotes(
      scheduleNoteTargets(
        post: post,
        accounts: accounts,
        registry: builtinRegistry(),
        resolver: const VariantResolver(),
        statuses: statuses,
        delegateSchedules: delegate,
        now: clockNow ?? now,
        automaticHandoff: (a) => automatic.contains(a.id),
      ),
      now: clockNow ?? now,
      device: device,
      clock: (t) => '${t.hour}:${t.minute.toString().padLeft(2, '0')}',
    );
  }

  Iterable<ScheduleNoteKind> kinds(List<ScheduleNote> n) => n.map((e) => e.kind);
  String textOf(List<ScheduleNote> n, ScheduleNoteKind k) => n.firstWhere((e) => e.kind == k).text;

  final facebook = account('facebook', config: const {'pageId': 'page-1'});
  final mastodon = account('mastodon', config: const {'instance': 'https://social.example.test'});
  final bluesky = account('bluesky');
  final linkedin = account('linkedin');
  final threads = account('threads');

  group('held by the platform', () {
    test('a network that holds this time: says NEFORUM hands it over, and what happens if that fails', () {
      final n = notes([mastodon], atHour(12));
      expect(kinds(n), [ScheduleNoteKind.heldByPlatform]);
      expect(n.single.text, contains('hands this post to Mastodon'));
      expect(n.single.text, contains('even if this device is off'));
      expect(n.single.text, contains('stays on this device'));
    });

    test('Facebook 40 days out stays on the device, in the adapter\'s own words (bug 1)', () {
      final n = notes([facebook], days(40));
      expect(kinds(n), isNot(contains(ScheduleNoteKind.heldByPlatform)));
      expect(textOf(n, ScheduleNoteKind.beyondHold), contains('up to 30 days'));
      expect(kinds(n), contains(ScheduleNoteKind.deviceOn));
      expect(kinds(n), contains(ScheduleNoteKind.farAwayOnDevice));
    });

    test('Facebook 10 minutes out stays on the device too (bug 1)', () {
      final n = notes([facebook], now.add(const Duration(minutes: 10)));
      expect(kinds(n), isNot(contains(ScheduleNoteKind.heldByPlatform)));
      expect(textOf(n, ScheduleNoteKind.beyondHold), contains('at least'));
    });

    test('Facebook 3 days out is held', () {
      expect(kinds(notes([facebook], days(3))), [ScheduleNoteKind.heldByPlatform]);
    });

    test('a thread is never promised, saved or composed (bug 1)', () {
      final n = notes([mastodon], atHour(12), text: 'First part', parts: const ['Second part']);
      expect(kinds(n), [ScheduleNoteKind.deviceOn]);
    });

    test('the setting off keeps everything on the device, with no talk of limits', () {
      final n = notes([facebook], days(40), delegate: false);
      expect(kinds(n), isNot(contains(ScheduleNoteKind.heldByPlatform)));
      expect(kinds(n), isNot(contains(ScheduleNoteKind.beyondHold)));
      expect(kinds(n), contains(ScheduleNoteKind.deviceOn));
    });

    test('a turned off account is skipped, never promised (bug 1)', () {
      final n = notes([account('mastodon', enabled: false, config: const {'instance': 'https://social.example.test'})], atHour(12));
      expect(kinds(n), [ScheduleNoteKind.turnedOff]);
      expect(n.single.text, contains('skips'));
    });

    test('a target that already went says nothing', () {
      final done = PostTarget(accountId: mastodon.id, status: TargetStatus.published, result: PublishResult.ok(remoteId: 'x'));
      expect(kinds(notes([mastodon, bluesky], atHour(12), targets: {mastodon.id: done})), [ScheduleNoteKind.deviceOn]);
    });

    test('a target already tried cannot be handed over', () {
      final tried = PostTarget(accountId: mastodon.id, attempts: 1);
      expect(kinds(notes([mastodon], atHour(12), targets: {mastodon.id: tried})), [ScheduleNoteKind.deviceOn]);
    });

    test('a sign-in that has ended is not promised: the hand-over would fail', () {
      final n = notes([mastodon], atHour(12), statuses: {mastodon.id: status(mastodon.id, days(-1))});
      expect(kinds(n), [ScheduleNoteKind.signInEnded, ScheduleNoteKind.deviceOn]);
    });

    test('a held post skips the sign-in warning: the platform publishes it', () {
      final n = notes([mastodon], days(3), statuses: {mastodon.id: status(mastodon.id, days(2))});
      expect(kinds(n), [ScheduleNoteKind.heldByPlatform]);
    });
  });

  group('sign-in ends first', () {
    test('nothing renews it: danger, date, reconnect', () {
      final n = notes([linkedin], days(40), statuses: {linkedin.id: status(linkedin.id, days(20))});
      expect(n.first.kind, ScheduleNoteKind.signInEndsFirst);
      expect(n.first.tone, ScheduleNoteTone.danger);
      expect(n.first.text, contains("LinkedIn's sign-in ends"));
      expect(n.first.text, contains('before this post'));
    });

    test('ending after the post, or right on it: only on it warns', () {
      expect(kinds(notes([linkedin], days(5), statuses: {linkedin.id: status(linkedin.id, days(20))})), isNot(contains(ScheduleNoteKind.signInEndsFirst)));
      final end = days(5);
      expect(kinds(notes([linkedin], end, statuses: {linkedin.id: status(linkedin.id, end)})), contains(ScheduleNoteKind.signInEndsFirst));
    });

    test('renews when NEFORUM posts: softer, and says what would save it', () {
      final n = notes([threads], days(40), statuses: {threads.id: status(threads.id, days(20), renews: true)});
      expect(n.first.kind, ScheduleNoteKind.signInRenewsFirst);
      expect(n.first.tone, ScheduleNoteTone.warning);
      expect(n.first.text, contains('renews when NEFORUM posts'));
    });

    test('early revocation reads "at the latest", an estimate reads "about"', () {
      final n = notes([threads], days(40), statuses: {threads.id: status(threads.id, days(20), renews: true, about: true, early: true)});
      expect(n.first.text, contains('at the latest'));
      expect(n.first.text, contains('about '));
      final bare = notes([linkedin], days(40), statuses: {linkedin.id: status(linkedin.id, days(20))});
      expect(bare.first.text, isNot(contains('at the latest')));
      expect(bare.first.text, isNot(contains('about ')));
    });

    test('no date, no warning', () {
      expect(kinds(notes([bluesky], days(40), statuses: {bluesky.id: status(bluesky.id, null)})), isNot(contains(ScheduleNoteKind.signInEndsFirst)));
    });

    test('the network refused it last time', () {
      final n = notes([linkedin], days(5), statuses: {linkedin.id: status(linkedin.id, days(20), refused: days(-1))});
      expect(textOf(n, ScheduleNoteKind.signInRefused), contains('refused the sign-in'));
    });
  });

  group('X keys', () {
    final keys = account('x', config: const {'authMode': 'oauth1'});
    final deadline = DateTime.utc(2027, 1, 31);
    final before = DateTime.utc(2026, 11, 6);

    test('a draw after the deadline warns, even with no status file entry yet', () {
      final n = notes([keys], DateTime.utc(2027, 3, 1), clockNow: before);
      expect(n.first.kind, ScheduleNoteKind.signInDeadlineFirst);
      expect(n.first.tone, ScheduleNoteTone.danger);
      expect(n.first.text, contains('2027'));
      expect(n.first.text, contains('Reconnect'));
    });

    test('a date from the status file that is later does not hide it', () {
      final n = notes([keys], DateTime.utc(2027, 3, 1), clockNow: before, statuses: {keys.id: status(keys.id, DateTime.utc(2028))});
      expect(n.first.kind, ScheduleNoteKind.signInDeadlineFirst);
    });

    test('a draw before the deadline does not, and the deadline passed reads as ended', () {
      expect(kinds(notes([keys], DateTime.utc(2027, 1, 2), clockNow: before)), isNot(contains(ScheduleNoteKind.signInDeadlineFirst)));
      expect(kinds(notes([keys], deadline.add(const Duration(days: 20)), clockNow: deadline.add(const Duration(days: 1)))), contains(ScheduleNoteKind.signInEnded));
    });

    test('browser sign-in is not on that deadline', () {
      final oauth2 = account('x', config: const {'authMode': 'oauth2'});
      expect(kinds(notes([oauth2], DateTime.utc(2027, 3, 1), clockNow: before)), isNot(contains(ScheduleNoteKind.signInDeadlineFirst)));
    });
  });

  group('this device', () {
    test('each device says its own line', () {
      expect(notes([bluesky], atHour(12), device: ScheduleDevice.desktop).single.text, contains('keep NEFORUM running'));
      expect(notes([bluesky], atHour(12), device: ScheduleDevice.android).single.text, contains('in the background'));
      expect(notes([bluesky], atHour(12), device: ScheduleDevice.ios).single.text, contains('Publish now'));
      expect(notes([bluesky], atHour(12), device: ScheduleDevice.web).single.text, contains('installed apps'));
    });

    test('more than 30 days away on this device warns; exactly under it does not; held does not', () {
      expect(textOf(notes([bluesky], days(31)), ScheduleNoteKind.farAwayOnDevice), contains('more than 30 days'));
      expect(kinds(notes([bluesky], days(29))), isNot(contains(ScheduleNoteKind.farAwayOnDevice)));
      expect(kinds(notes([mastodon], days(100))), isNot(contains(ScheduleNoteKind.farAwayOnDevice)));
    });

    test('no targets yet still says what the device does', () {
      expect(scheduleNotes(const [], now: now, device: ScheduleDevice.desktop, clock: (_) => '').single.text, startsWith('Keep NEFORUM running'));
    });
  });

  group('hand-offs and the night', () {
    final handoff = account('instagram', tier: PlatformTier.handoff);

    test('a hand-off gets a reminder', () {
      final n = notes([handoff], atHour(12));
      expect(kinds(n), [ScheduleNoteKind.handoff]);
      expect(n.single.text, contains('reminder to tap Post'));
    });

    test('at night it warns, by the time it lands', () {
      final n = notes([handoff], atHour(3));
      expect(n.first.kind, ScheduleNoteKind.nightTimeTap);
      expect(n.first.text, 'Instagram: this lands at 3:12 and needs you to tap.');
    });

    test('the hours that count as night', () {
      for (final (hour, night) in const [(0, true), (6, true), (7, false), (12, false), (22, false), (23, true)]) {
        expect(kinds(notes([handoff], atHour(hour))).contains(ScheduleNoteKind.nightTimeTap), night, reason: 'hour $hour');
      }
    });

    test('an iPhone needs a tap for anything on the device; other devices do not', () {
      expect(kinds(notes([bluesky], atHour(3), device: ScheduleDevice.ios)), contains(ScheduleNoteKind.nightTimeTap));
      expect(kinds(notes([bluesky], atHour(3), device: ScheduleDevice.android)), isNot(contains(ScheduleNoteKind.nightTimeTap)));
      expect(kinds(notes([mastodon], atHour(3), device: ScheduleDevice.ios)), isNot(contains(ScheduleNoteKind.nightTimeTap)), reason: 'held');
    });

    test('automatic posting through the extension makes no promise of a tap', () {
      final n = notes([handoff], atHour(3), automatic: {handoff.id});
      expect(kinds(n), [ScheduleNoteKind.automaticHandoff]);
      expect(n.single.text, contains('browser extension'));
    });

    test('a hand-off far away still waits on this device', () {
      expect(kinds(notes([handoff], days(60))), contains(ScheduleNoteKind.farAwayOnDevice));
    });
  });

  group('order and grouping', () {
    test('danger first, then by how many accounts a note covers', () {
      final handoff = account('instagram', tier: PlatformTier.handoff);
      final n = notes([bluesky, linkedin, mastodon, handoff], atHour(12).add(const Duration(days: 40)), statuses: {linkedin.id: status(linkedin.id, days(2))});
      expect(n.first.kind, ScheduleNoteKind.signInEndsFirst);
      final tones = [for (final x in n) x.tone.index];
      expect(tones, [...tones]..sort());
    });

    test('networks are joined in one line; two accounts on one network keep apart', () {
      final other = account('bluesky', id: 'bluesky-2', handle: 'second.example.test');
      final one = account('bluesky', id: 'bluesky-1', handle: 'first.example.test');
      final n = notes([one, other, linkedin], atHour(12));
      expect(n.single.kind, ScheduleNoteKind.deviceOn);
      expect(n.single.text, startsWith('Bluesky (first.example.test), Bluesky (second.example.test) and LinkedIn:'));
    });

    test('each network is judged at its own time', () {
      final n = notes([facebook, bluesky], days(3), eachAt: {facebook.id: days(40), bluesky.id: days(2)});
      expect(kinds(n), isNot(contains(ScheduleNoteKind.heldByPlatform)), reason: 'Facebook at its own 40 days');
      expect(textOf(n, ScheduleNoteKind.farAwayOnDevice), startsWith('Facebook:'));
    });
  });

  test('D14: the sheet reads no keychain and has no rule of its own about holding', () {
    for (final path in ['lib/ui/compose/schedule_sheet.dart', 'lib/ui/compose/schedule_notes.dart']) {
      final source = File(path).readAsStringSync();
      for (final banned in ['signInExpiry', 'accountConnectionProvider', 'connectionSecretsProvider', 'secrets.read', 'serverSideScheduling']) {
        expect(source, isNot(contains(banned)), reason: '$path: $banned');
      }
    }
  });
}
