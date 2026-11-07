import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../platform/env.dart';

/// What kind of device a scheduled post waits on.
enum ScheduleDevice {
  ios,
  android,
  desktop,
  web;

  static ScheduleDevice get current => Env.isIOS
      ? ios
      : Env.isAndroid
          ? android
          : Env.isDesktop
              ? desktop
              : web;
}

enum ScheduleNoteKind {
  /// The sign-in has ended, or the network last refused it.
  signInEnded,
  signInRefused,

  /// Nothing renews it and it ends before the post.
  signInEndsFirst,

  /// A post through it would renew it, and with no post it ends first.
  signInRenewsFirst,

  /// The vendor's announced end of this way of signing in comes first (X keys).
  signInDeadlineFirst,

  /// Turned off: the post skips it.
  turnedOff,

  /// A hand-off or a phone tap at a time people sleep through.
  nightTimeTap,

  /// A long time to wait on this device.
  farAwayOnDevice,

  /// The network's own limit, in its adapter's words.
  beyondHold,

  /// NEFORUM hands it to the network.
  heldByPlatform,

  /// It waits on this device.
  deviceOn,

  /// A reminder to tap Post.
  handoff,

  /// The browser extension posts it.
  automaticHandoff,
}

enum ScheduleNoteTone { danger, warning, info }

/// One line under the schedule. Warnings never block Schedule; only a time in
/// the past does.
@immutable
class ScheduleNote {
  const ScheduleNote(this.kind, this.tone, this.text, {this.accounts = 1});
  final ScheduleNoteKind kind;
  final ScheduleNoteTone tone;
  final String text;

  /// How many accounts it covers, which orders notes of one tone.
  final int accounts;
}

/// One network a post is scheduled for, as the notes need it.
@immutable
class ScheduleNoteTarget {
  const ScheduleNoteTarget({
    required this.account,
    required this.name,
    required this.at,
    required this.plan,
    this.status,
    this.policy,
    this.automaticHandoff = false,
  });

  final ConnectedAccount account;

  /// The network's name, with the handle when the post goes to two accounts on it.
  final String name;

  /// This target's own time.
  final DateTime at;

  /// The same decision the hand-over makes.
  final ScheduleHoldPlan plan;

  /// From the status file: never a keychain read.
  final SignInStatus? status;
  final SignInPolicy? policy;

  /// The browser extension posts this hand-off.
  final bool automaticHandoff;
}

/// The targets of [post] still to go, with [holdPlanFor]'s answer for each.
/// [post] must already carry the time being considered.
List<ScheduleNoteTarget> scheduleNoteTargets({
  required Post post,
  required Iterable<ConnectedAccount> accounts,
  required AdapterRegistry registry,
  required VariantResolver resolver,
  required Map<String, SignInStatus> statuses,
  required bool delegateSchedules,
  required DateTime now,
  bool Function(ConnectedAccount account)? automaticHandoff,
}) {
  final byId = {for (final a in accounts) a.id: a};
  final rows = <(PostTarget, ConnectedAccount, PlatformAdapter)>[];
  for (final t in post.targets) {
    if (t.isDone) continue;
    final a = byId[t.accountId];
    final adapter = a == null ? null : registry.byId(a.platformId);
    if (a != null && adapter != null) rows.add((t, a, adapter));
  }
  final seen = <String, int>{};
  for (final (_, a, _) in rows) {
    seen[a.platformId] = (seen[a.platformId] ?? 0) + 1;
  }
  final out = <ScheduleNoteTarget>[];
  for (final (t, a, adapter) in rows) {
    final at = post.dueAtFor(t);
    if (at == null) continue;
    final network = adapter.descriptorForAccount(a).name;
    out.add(ScheduleNoteTarget(
      account: a,
      name: (seen[a.platformId] ?? 0) > 1 ? '$network (${a.handle ?? a.displayName})' : network,
      at: at,
      plan: delegateSchedules
          ? holdPlanFor(post, t, account: a, adapter: adapter, resolver: resolver, now: now)
          : const ScheduleHoldPlan.stays(ScheduleHoldRefusal.notOffered),
      status: statuses[a.id],
      policy: adapter.signInPolicyFor(a),
      automaticHandoff: automaticHandoff?.call(a) ?? false,
    ));
  }
  return out;
}

/// A post more than this far ahead that waits on this device gets a warning.
const Duration kFarAwayOnDevice = Duration(days: 30);

/// Hours in which a post that needs a tap warns: before 7:00 and from 23:00.
bool isNightTime(DateTime local) => local.hour < 7 || local.hour >= 23;

/// What to say about a schedule, most serious first. Every line is computed for
/// these times: nothing here is a general promise about a network.
///
/// Reads the status file's dates and never a keychain, so a stuck keychain
/// cannot hold up the sheet (D14).
List<ScheduleNote> scheduleNotes(
  List<ScheduleNoteTarget> targets, {
  required DateTime now,
  required ScheduleDevice device,
  required String Function(DateTime) clock,
  bool closeKeepsRunning = true,
}) {
  final deviceLine = _deviceLine(device, closeKeepsRunning: closeKeepsRunning);
  if (targets.isEmpty) return [ScheduleNote(ScheduleNoteKind.deviceOn, ScheduleNoteTone.info, _capitalized(deviceLine), accounts: 0)];

  final notes = <ScheduleNote>[];
  final turnedOff = <String>[];
  final ended = <String>[];
  final refused = <String>[];
  final held = <String>[];
  final onDevice = <String>[];
  final farAway = <String>[];
  final handoff = <String>[];
  final automatic = <String>[];
  final limits = <String>{};
  final limitCount = <String, int>{};
  final night = <String, List<String>>{};

  void nightCheck(ScheduleNoteTarget t) {
    final local = t.at.toLocal();
    if (isNightTime(local)) (night[clock(local)] ??= []).add(t.name);
  }

  for (final t in targets) {
    if (!t.account.enabled) {
      turnedOff.add(t.name);
      continue;
    }
    if (t.account.tier == PlatformTier.handoff) {
      if (t.automaticHandoff) {
        automatic.add(t.name);
      } else {
        handoff.add(t.name);
        nightCheck(t);
      }
      if (t.at.difference(now) > kFarAwayOnDevice) farAway.add(t.name);
      continue;
    }

    final end = _SignInEnd.of(t);
    final isOver = end != null && !now.isBefore(end.at);
    if (isOver) {
      ended.add(t.name);
    } else if (t.status?.lastAuthFailure != null) {
      refused.add(t.name);
    }
    // At hand-over a sign-in that ended fails, and the post stays here.
    final goes = t.plan.handsOver && !isOver;
    if (goes) {
      held.add(t.name);
      continue;
    }
    if (end != null && !isOver && !t.at.isBefore(end.at)) notes.add(end.note(t.name));
    if (t.plan.refusal == ScheduleHoldRefusal.timeRefused) {
      final m = t.plan.message!;
      limits.add(m);
      limitCount[m] = (limitCount[m] ?? 0) + 1;
    }
    onDevice.add(t.name);
    if (t.at.difference(now) > kFarAwayOnDevice) farAway.add(t.name);
    if (device == ScheduleDevice.ios) nightCheck(t);
  }

  if (ended.isNotEmpty) {
    notes.add(ScheduleNote(ScheduleNoteKind.signInEnded, ScheduleNoteTone.danger,
        '${_join(ended)} ${ended.length == 1 ? 'needs' : 'need'} reconnecting now, or this post fails there.',
        accounts: ended.length));
  }
  if (refused.isNotEmpty) {
    notes.add(ScheduleNote(ScheduleNoteKind.signInRefused, ScheduleNoteTone.warning,
        '${_join(refused)} refused the sign-in the last time NEFORUM tried. Reconnect ${refused.length == 1 ? 'it' : 'them'} before this post.',
        accounts: refused.length));
  }
  if (turnedOff.isNotEmpty) {
    notes.add(ScheduleNote(ScheduleNoteKind.turnedOff, ScheduleNoteTone.warning,
        '${_join(turnedOff)} ${turnedOff.length == 1 ? 'is' : 'are'} turned off, so this post skips ${turnedOff.length == 1 ? 'it' : 'them'}.',
        accounts: turnedOff.length));
  }
  night.forEach((time, names) {
    notes.add(ScheduleNote(ScheduleNoteKind.nightTimeTap, ScheduleNoteTone.warning, '${_join(names)}: this lands at $time and needs you to tap.', accounts: names.length));
  });
  if (farAway.isNotEmpty) {
    notes.add(ScheduleNote(ScheduleNoteKind.farAwayOnDevice, ScheduleNoteTone.warning,
        '${_join(farAway)}: this is more than ${kFarAwayOnDevice.inDays} days away and waits on this device. Keep NEFORUM installed and signed in here until then.',
        accounts: farAway.length));
  }
  for (final m in limits) {
    notes.add(ScheduleNote(ScheduleNoteKind.beyondHold, ScheduleNoteTone.info, m, accounts: limitCount[m]!));
  }
  if (held.isNotEmpty) {
    notes.add(ScheduleNote(ScheduleNoteKind.heldByPlatform, ScheduleNoteTone.info,
        'NEFORUM hands this post to ${_join(held)}, which ${held.length == 1 ? 'publishes' : 'publish'} it even if this device is off. If ${held.length == 1 ? 'it refuses' : 'one refuses'}, the post stays on this device.',
        accounts: held.length));
  }
  if (onDevice.isNotEmpty) {
    notes.add(ScheduleNote(ScheduleNoteKind.deviceOn, ScheduleNoteTone.info, '${_join(onDevice)}: $deviceLine', accounts: onDevice.length));
  }
  if (handoff.isNotEmpty) {
    notes.add(ScheduleNote(ScheduleNoteKind.handoff, ScheduleNoteTone.info, '${_join(handoff)}: you get a reminder to tap Post.', accounts: handoff.length));
  }
  if (automatic.isNotEmpty) {
    notes.add(ScheduleNote(ScheduleNoteKind.automaticHandoff, ScheduleNoteTone.info,
        '${_join(automatic)}: the NEFORUM browser extension posts this at its time. If it cannot, it waits for you to tap Post.',
        accounts: automatic.length));
  }

  // Most serious first, then the note covering the most accounts. Stable.
  final order = [for (var i = 0; i < notes.length; i++) i]
    ..sort((a, b) {
      final tone = notes[a].tone.index.compareTo(notes[b].tone.index);
      if (tone != 0) return tone;
      final covers = notes[b].accounts.compareTo(notes[a].accounts);
      return covers != 0 ? covers : a.compareTo(b);
    });
  return [for (final i in order) notes[i]];
}

/// When a sign-in stops working, and how to say so.
class _SignInEnd {
  const _SignInEnd(this.at, {required this.about, required this.early, required this.deadline, required this.renews});

  /// The status file's date, or the policy's announced end when that is sooner
  /// or the file has no entry yet.
  static _SignInEnd? of(ScheduleNoteTarget t) {
    final status = t.status;
    final deadline = t.policy?.hardDeadline;
    final date = status?.expiresAt;
    if (deadline != null && (date == null || deadline.isBefore(date))) {
      return _SignInEnd(deadline, about: false, early: t.policy?.earlyRevocationPossible ?? false, deadline: true, renews: false);
    }
    if (status == null || date == null) return null;
    return _SignInEnd(date, about: status.about, early: status.earlyRevocationPossible, deadline: status.isHardDeadline, renews: status.renewsItself);
  }

  final DateTime at;
  final bool about;
  final bool early;
  final bool deadline;
  final bool renews;

  String get _date {
    final day = DateFormat.yMMMd().format(at.toLocal());
    return '${about ? 'about ' : ''}$day${early ? ' at the latest' : ''}';
  }

  ScheduleNote note(String name) {
    if (deadline) {
      return ScheduleNote(ScheduleNoteKind.signInDeadlineFirst, ScheduleNoteTone.danger,
          "$name stops accepting this way of signing in on $_date, before this post. Reconnect it first or this post fails there.");
    }
    if (renews) {
      return ScheduleNote(ScheduleNoteKind.signInRenewsFirst, ScheduleNoteTone.warning,
          "$name's sign-in renews when NEFORUM posts there. With no post before $_date, it ends first and this post fails there.");
    }
    return ScheduleNote(ScheduleNoteKind.signInEndsFirst, ScheduleNoteTone.danger, "$name's sign-in ends $_date, before this post. Reconnect it first or this post fails there.");
  }
}

/// [closeKeepsRunning]: closing the window leaves NEFORUM in the tray, so the
/// line can say so. Off in Settings, closing it quits, and the post waits.
String _deviceLine(ScheduleDevice device, {required bool closeKeepsRunning}) => switch (device) {
      ScheduleDevice.ios => 'at the scheduled time you get a notification with a Publish now button (iOS does not let apps post on a timer).',
      ScheduleDevice.android => 'goes out in the background, usually within a few minutes of its time. Android can delay it while the phone is idle.',
      ScheduleDevice.desktop => closeKeepsRunning
          ? 'keep NEFORUM running (it stays in the tray when you close the window) and it goes out on time.'
          : 'keep NEFORUM running with its window open and it goes out on time.',
      ScheduleDevice.web => 'scheduling works in the installed apps; the web preview only stores the time.',
    };

String _capitalized(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

String _join(List<String> names) {
  if (names.length == 1) return names.first;
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}
