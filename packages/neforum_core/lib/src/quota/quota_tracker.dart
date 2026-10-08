import 'package:meta/meta.dart';

import '../model/account.dart';
import '../model/platform_descriptor.dart';
import '../storage/repositories.dart';
import '../util/logger.dart';

@immutable
class QuotaStatus {
  const QuotaStatus({required this.rule, required this.used, required this.limit, this.resetsAt});

  final QuotaRule rule;
  final int used;
  final int limit;

  /// When the oldest counted event leaves the window.
  final DateTime? resetsAt;

  int get remaining => (limit - used).clamp(0, limit);
  bool get exhausted => used >= limit;
  double get fraction => limit == 0 ? 1 : (used / limit).clamp(0, 1);

  @override
  String toString() => '${rule.id}: $used/$limit';
}

/// Local bookkeeping of how many quota-consuming calls each account made,
/// so NEFORUM can warn before the platform refuses and fall back to hand-off.
///
/// This is an estimate: it only knows what NEFORUM itself sent.
class QuotaTracker {
  QuotaTracker(this._repo, {Clock? clock, Logger? log})
      : _now = clock ?? systemClock,
        _log = log ?? Logger('quota');

  final QuotaRepository _repo;
  final Clock _now;
  final Logger _log;

  List<QuotaRule> rulesFor(ConnectedAccount account, PlatformDescriptor d) =>
      d.defaultQuotas.where((r) => r.appliesToTier == null || r.appliesToTier == account.tier).toList();

  int limitFor(ConnectedAccount account, QuotaRule rule) => account.quotaOverrides[rule.id] ?? rule.limit;

  Future<List<QuotaStatus>> status(ConnectedAccount account, PlatformDescriptor d) async {
    final out = <QuotaStatus>[];
    final now = _now();
    for (final rule in rulesFor(account, d)) {
      final since = now.subtract(rule.window);
      final used = await _repo.countSince(account.id, rule.id, since);
      final oldest = await _repo.oldestSince(account.id, rule.id, since);
      out.add(QuotaStatus(
        rule: rule,
        used: used,
        limit: limitFor(account, rule),
        resetsAt: oldest?.add(rule.window),
      ));
    }
    return out;
  }

  /// The first rule that [needed] more calls would exceed, or `null`.
  Future<QuotaStatus?> firstExceeded(ConnectedAccount account, PlatformDescriptor d, {int needed = 1}) async {
    for (final s in await status(account, d)) {
      if (s.used + needed > s.limit) return s;
    }
    return null;
  }

  /// Records [count] consumed calls against every applicable rule.
  Future<void> record(ConnectedAccount account, PlatformDescriptor d, {int count = 1}) async {
    final at = _now();
    for (final rule in rulesFor(account, d)) {
      await _repo.record(QuotaEvent(accountId: account.id, ruleId: rule.id, at: at, count: count));
    }
    _log.debug('Recorded $count call(s) for ${account.displayName}');
  }

  /// Drops events older than the longest window any platform uses (31 days
  /// covers monthly caps).
  Future<void> prune({Duration keep = const Duration(days: 31)}) => _repo.prune(_now().subtract(keep));
}
