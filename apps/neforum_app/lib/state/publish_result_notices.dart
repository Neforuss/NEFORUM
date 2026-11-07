import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../platform/notifications.dart';
import '../platform/storage.dart';
import '../platform/ui_bridge.dart';

/// How one target's network is named in a notification. [accountLabel] only
/// when two accounts of the post share the network.
typedef ResultNetworkName = ({String name, String? accountLabel});

/// What happens when a run ends.
enum RunEndDelivery {
  /// The sheet is open and visible: it is the result.
  none,

  /// An OS notification.
  notify,

  /// An OS notification, and if that cannot reach anyone, the app says so at
  /// the next chance ([UnseenResults]).
  notifyAndRemember,
}

/// D10 for a run the user started. The sheet open while NEFORUM is hidden still
/// shows the result on return, so nothing has to be remembered for that case.
RunEndDelivery tappedRunDelivery({required bool sheetOpen, required AppLifecycleState? lifecycle}) {
  final visible = canShowUi(canRaiseWindow: false, lifecycle: lifecycle);
  if (sheetOpen) return visible ? RunEndDelivery.none : RunEndDelivery.notify;
  return visible ? RunEndDelivery.notify : RunEndDelivery.notifyAndRemember;
}

/// D10 for a run nobody started by hand (the scheduler).
RunEndDelivery unattendedRunDelivery({required AppLifecycleState? lifecycle}) =>
    canShowUi(canRaiseWindow: false, lifecycle: lifecycle) ? RunEndDelivery.notify : RunEndDelivery.notifyAndRemember;

/// The accounts whose target a run changed: earlier runs already told about
/// the others.
Set<String> targetsChangedByRun(Post before, Post after) => {
      for (final t in after.targets)
        if (before.targetFor(t.accountId)?.status != t.status) t.accountId,
    };

String _short(String s, [int max = 90]) {
  final runes = s.trim().split('\n').first.runes.toList();
  return runes.length > max ? '${String.fromCharCodes(runes.take(max))}…' : String.fromCharCodes(runes);
}

String _shortText(String s) {
  final runes = s.runes.toList();
  return runes.length > 90 ? '${String.fromCharCodes(runes.take(90))}…' : s;
}

String _joinNames(List<String> names) {
  if (names.isEmpty) return 'your networks';
  if (names.length == 1) return names.first;
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

/// Whether Retry on a failed network's notification may post again. The
/// notification can be old, so this is read from the post as it is now: never
/// a network that has the post, never one that may have it.
bool notificationRetryAllowed(Post? post, String accountId) {
  final t = post?.targetFor(accountId);
  return t != null && t.status == TargetStatus.failed && !t.isPartlyLive && t.result?.error?.outcomeUnknown != true;
}

/// The notifications for [p] after a run: one per network that has something
/// to say, children first, and a summary when there is more than one.
///
/// [quotePostText]: only where the OS can hide a notification on the lock
/// screen (Android). [onlyAccountIds]: the networks this run touched; the
/// summary still counts the whole post. Pure, and every row is tested.
List<ResultNotice> publishResultNotices(
  Post p, {
  required bool discarded,
  required bool notifyOnPublish,
  Map<String, ResultNetworkName> networks = const {},
  String Function(DateTime when)? heldTime,
  Set<String>? onlyAccountIds,
  bool quotePostText = true,
}) {
  final waiting = p.targets.where((t) => t.status == TargetStatus.awaitingHandoff).toList();
  // The user stopped this run in Activity and has seen how it ended.
  if (waiting.isEmpty && p.targets.any((t) => t.status == TargetStatus.cancelled)) return const [];
  final text = quotePostText && !discarded && p.text.trim().isNotEmpty ? _shortText(p.text) : '';
  if (notifyOnPublish && p.targets.isNotEmpty && p.targets.every((t) => t.status == TargetStatus.skipped)) {
    // Every account of the post is switched off: it stays in Activity.
    return [
      ResultNotice(
        key: 'result:${p.id}',
        title: 'Not posted',
        body: 'The accounts for this post are switched off. It stays in Activity.',
        payload: 'post:${p.id}',
      ),
    ];
  }

  String nameOf(String accountId) => networks[accountId]?.name ?? 'A removed account';
  final open = discarded ? null : 'post:${p.id}';
  final groupKey = 'neforum.result.${p.id}';

  final children = <ResultNotice>[];
  for (final t in p.targets) {
    if (onlyAccountIds != null && !onlyAccountIds.contains(t.accountId)) continue;
    final id = t.accountId;
    final name = nameOf(id);
    // Hand-offs are told about whatever the setting says: they wait for the user.
    if (t.status == TargetStatus.awaitingHandoff) {
      final note = t.handoffNote;
      children.add(ResultNotice(
        key: 'handoff:${p.id}:$id',
        title: 'Time to post to $name',
        body: note == null ? 'Tap to finish in the app.' : _short(note),
        payload: 'handoff:${p.id}:$id',
      ));
      continue;
    }
    if (!notifyOnPublish) continue;
    final key = 'result:${p.id}:$id';
    switch (t.status) {
      case TargetStatus.published || TargetStatus.handedOff:
        final link = t.result?.remoteUrl;
        final linkUri = link == null ? null : Uri.tryParse(link);
        final web = linkUri != null && linkUri.hasAuthority && (linkUri.scheme == 'https' || linkUri.scheme == 'http');
        children.add(ResultNotice(
          key: key,
          title: 'Posted to $name',
          body: networks[id]?.accountLabel ?? '',
          payload: web ? postedPayload(postId: discarded ? null : p.id, link: link!) : open,
          action: web ? ResultNoticeAction.openLink : ResultNoticeAction.none,
        ));
      case TargetStatus.failed when t.isPartlyLive:
        final parts = t.result?.allRemoteIds.length ?? 0;
        final total = p.parts.length;
        children.add(ResultNotice(
          key: key,
          title: parts > 0 && total > 1 && parts < total ? '$name: $parts of $total parts posted' : '$name: partly posted',
          body: t.canResume ? 'Retry posts the rest.' : 'Check it before posting again.',
          payload: open,
        ));
      case TargetStatus.failed:
        final error = t.result?.error;
        final unknown = error?.outcomeUnknown == true;
        children.add(ResultNotice(
          key: key,
          title: unknown ? '$name: check before retrying' : '$name failed',
          body: _short(error?.message ?? ''),
          payload: unknown ? open : 'retry:${p.id}:$id',
          action: unknown ? ResultNoticeAction.none : ResultNoticeAction.retry,
        ));
      case TargetStatus.heldByPlatform:
        final when = t.result?.scheduledFor;
        children.add(ResultNotice(
          key: key,
          title: when == null || heldTime == null ? '$name has it scheduled' : '$name has it for ${heldTime(when)}',
          body: '',
          payload: open,
        ));
      default:
      // Cancelled, skipped, still pending or posting: no notification of its own.
    }
  }
  if (children.isEmpty) return const [];

  ResultNotice grouped(ResultNotice c) => ResultNotice(
        key: c.key,
        title: c.title,
        body: c.body,
        payload: c.payload,
        groupKey: groupKey,
        threadId: p.id,
        alerts: false,
        action: c.action,
      );

  if (children.length == 1) {
    final only = children.single;
    return [
      ResultNotice(
        key: only.key,
        title: only.title,
        body: only.body.isEmpty ? text : only.body,
        payload: only.payload,
        threadId: p.id,
        action: only.action,
      ),
    ];
  }

  final lines = [for (final c in children) c.title];
  return [
    ...children.map(grouped),
    ResultNotice(
      key: 'result:${p.id}',
      title: _summaryTitle(p, notifyOnPublish: notifyOnPublish, waitingNames: [for (final t in waiting) nameOf(t.accountId)]),
      body: text.isEmpty ? lines.join(' · ') : text,
      payload: open,
      groupKey: groupKey,
      threadId: p.id,
      isSummary: true,
      lines: lines,
    ),
  ];
}

String _summaryTitle(Post p, {required bool notifyOnPublish, required List<String> waitingNames}) {
  // Networks whose own time has not come yet are not part of the result.
  final reached = p.targets.where((t) => t.status != TargetStatus.pending && t.status != TargetStatus.publishing).length;
  final ok = p.targets.where((t) => t.status == TargetStatus.published || t.status == TargetStatus.handedOff).length;
  if (!notifyOnPublish || (ok == 0 && waitingNames.isNotEmpty)) return 'Time to post to ${_joinNames(waitingNames)}';
  if (ok == 0) return p.targets.any((t) => t.status == TargetStatus.heldByPlatform) ? 'Scheduled on its networks' : 'Not posted';
  return ok == reached ? 'Posted to $ok ${ok == 1 ? 'network' : 'networks'}' : 'Posted to $ok of $reached';
}

/// The notification for a run a closed NEFORUM left unfinished, sent when
/// recovery settles it. [p] is the settled post.
ResultNotice publishInterruptedNotice(Post p, {required String fallbackMessage}) {
  final failed = p.targets.where((t) => t.status == TargetStatus.failed).toList();
  final message = failed.map((t) => t.result?.error?.message).nonNulls.firstOrNull ?? fallbackMessage;
  return ResultNotice(key: 'result:${p.id}', title: 'Posting stopped', body: _short(message), payload: 'post:${p.id}');
}

/// One post that finished with nobody watching: only network names and
/// outcomes, never the post's text. The file is not synced.
@immutable
class UnseenResult {
  const UnseenResult({required this.postId, required this.at, required this.title, required this.lines});

  factory UnseenResult.fromJson(Map<String, dynamic> j) => UnseenResult(
        postId: j['postId'] as String? ?? '',
        at: DateTime.tryParse('${j['at'] ?? ''}') ?? DateTime.fromMillisecondsSinceEpoch(0),
        title: j['title'] as String? ?? '',
        lines: (j['lines'] as List? ?? const []).cast<String>(),
      );

  final String postId;
  final DateTime at;
  final String title;
  final List<String> lines;

  Map<String, dynamic> toJson() => {'postId': postId, 'at': at.toUtc().toIso8601String(), 'title': title, 'lines': lines};
}

/// What finished while nobody was watching, per device: a background task can
/// write this, and with notifications off it is the only way the user hears.
/// Holds no post text. Emptied once the OS could tell them or the app has.
class UnseenResults {
  UnseenResults(this._storage);

  static const fileName = 'unseen-results.json';
  static const maxEntries = 20;

  final AppStorage _storage;

  Future<({DateTime? lastAt, List<UnseenResult> entries})> read() async {
    try {
      final j = await _storage.readJson(fileName);
      if (j == null) return (lastAt: null, entries: const <UnseenResult>[]);
      return (
        lastAt: DateTime.tryParse('${j['lastAt'] ?? ''}'),
        entries: [
          for (final e in j['entries'] as List? ?? const [])
            if (e is Map) UnseenResult.fromJson(Map<String, dynamic>.from(e)),
        ],
      );
    } on Object catch (e) {
      debugPrint('Could not read $fileName: $e');
      return (lastAt: null, entries: const <UnseenResult>[]);
    }
  }

  Future<void> add(UnseenResult result) async {
    final current = await read();
    // A later run of the same post replaces what the earlier one said.
    final entries = [...current.entries.where((e) => e.postId != result.postId), result];
    await _write(result.at, entries.length > maxEntries ? entries.sublist(entries.length - maxEntries) : entries);
  }

  /// The list is empty after this; [UnseenResults.read]'s lastAt stays, since
  /// the banner compares it with when it was closed.
  Future<void> clearEntries() async => _write((await read()).lastAt, const []);

  /// Delete everything.
  Future<void> deleteAll() => _write(null, const []);

  Future<void> _write(DateTime? lastAt, List<UnseenResult> entries) async {
    try {
      await _storage.writeJson(fileName, {
        if (lastAt != null) 'lastAt': lastAt.toUtc().toIso8601String(),
        'entries': [for (final e in entries) e.toJson()],
      });
    } on Object catch (e) {
      debugPrint('Could not write $fileName: $e');
    }
  }
}
