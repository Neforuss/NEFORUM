import 'package:meta/meta.dart';

import '../adapters/platform_adapter.dart';
import '../model/account.dart';
import '../model/platform_descriptor.dart';
import '../model/post.dart';
import '../model/post_variant.dart';
import '../model/validation.dart';
import '../text/variant_resolver.dart';

/// Why a target stays on this device instead of going to its platform.
enum ScheduleHoldRefusal {
  /// The account is gone, or no adapter knows its platform.
  noAccount,

  /// Turned off, or a hand-off account.
  notAutomatic,

  /// The platform has no scheduler of its own.
  notOffered,

  /// Already published, skipped or tried: only a pending target is handed over.
  notPending,

  /// No time, or one that has passed.
  notAhead,

  /// A thread or a series: later parts need the first one's id.
  severalParts,

  /// The platform's rules refuse this time ([ScheduleHoldPlan.message] says
  /// why): too soon or too far ahead.
  timeRefused,

  /// The post has some other problem on this platform.
  invalid,
}

/// Whether a scheduled target would be handed to its platform.
///
/// One decision for two callers, so that they cannot disagree:
/// [PublishService.delegateSchedules] acts on it, and the schedule sheet words
/// its promises from it. A plan that says yes can still end on this device, if
/// the sign-in, the quota or the network says no at hand-over, so text built on
/// it says what NEFORUM will try and what happens if that fails.
@immutable
class ScheduleHoldPlan {
  const ScheduleHoldPlan.handOver(PostVariant this.variant)
      : refusal = null,
        message = null;
  const ScheduleHoldPlan.stays(ScheduleHoldRefusal this.refusal, {this.message}) : variant = null;

  /// The copy to send. Null when [refusal] is set.
  final PostVariant? variant;
  final ScheduleHoldRefusal? refusal;

  /// The platform's own words for [ScheduleHoldRefusal.timeRefused] and
  /// [ScheduleHoldRefusal.invalid].
  final String? message;

  bool get handsOver => refusal == null;
}

/// The [ScheduleHoldPlan] for [target] of [post] at [now]. Synchronous and
/// reads no keys: [PlatformAdapter.validate] already runs on every keystroke.
ScheduleHoldPlan holdPlanFor(
  Post post,
  PostTarget target, {
  required ConnectedAccount? account,
  required PlatformAdapter? adapter,
  required VariantResolver resolver,
  required DateTime now,
}) {
  if (account == null || adapter == null) return const ScheduleHoldPlan.stays(ScheduleHoldRefusal.noAccount);
  if (!account.enabled || !account.tier.isAutomatic) return const ScheduleHoldPlan.stays(ScheduleHoldRefusal.notAutomatic);
  final descriptor = adapter.descriptorForAccount(account);
  if (!descriptor.serverSideScheduling) return const ScheduleHoldPlan.stays(ScheduleHoldRefusal.notOffered);
  if (target.status != TargetStatus.pending || target.attempts > 0) return const ScheduleHoldPlan.stays(ScheduleHoldRefusal.notPending);
  final at = post.dueAtFor(target);
  if (at == null || !at.isAfter(now)) return const ScheduleHoldPlan.stays(ScheduleHoldRefusal.notAhead);
  final variant = resolver.resolve(post, target, descriptor, account: account, delegateSchedule: true);
  // A thread cannot be held: its replies need the first part's id.
  if (variant.scheduledAt == null || variant.isThread) return const ScheduleHoldPlan.stays(ScheduleHoldRefusal.severalParts);
  final List<ValidationIssue> issues;
  try {
    issues = [...variant.issues, ...adapter.validate(variant, account)];
  } on Object {
    return const ScheduleHoldPlan.stays(ScheduleHoldRefusal.invalid);
  }
  final errors = issues.errors.toList();
  if (errors.isEmpty) return ScheduleHoldPlan.handOver(variant);
  final aboutTime = errors.where((i) => i.field == 'scheduledAt').firstOrNull;
  return aboutTime != null
      ? ScheduleHoldPlan.stays(ScheduleHoldRefusal.timeRefused, message: aboutTime.message)
      : ScheduleHoldPlan.stays(ScheduleHoldRefusal.invalid, message: errors.first.message);
}
