import 'package:meta/meta.dart';

import '../model/account.dart';
import 'connect_spec.dart';

// 1.4.4: paid plans that raise a network's limits, per account.
//
// Some networks let a paying account post more: X Premium posts take 25,000
// characters instead of 280 and videos up to 125 minutes; Parler Premium posts
// take 2000 characters instead of 300; a verified YouTube channel uploads
// videos over 15 minutes. Each adapter declares the plans that change its
// limits for one way of posting ([SubscriptionPlans], through
// `PlatformAdapter.subscriptionPlansFor`), and NEFORUM keeps the plan of each
// account in its config ([AccountSubscription]). The adapter's
// `descriptorForAccount` then gives that account's limits, so the rules
// check, the text splitter (no thread when one long post fits), the media
// rules and the previews all follow the account's plan.
//
// Where the network says which plan an account has (X's `subscription_type`,
// YouTube's `longUploadsStatus`), NEFORUM reads it when the account connects
// or reconnects ([SubscriptionSource.detected]). Otherwise the person chooses
// it on the connect form and can change it on the account card
// ([SubscriptionSource.chosen]). docs/paid-tiers.md lists every network.

/// One plan of a network: the free one, or a paid one that changes limits.
@immutable
class SubscriptionTier {
  const SubscriptionTier({required this.id, required this.label, required this.summary});

  /// The id of every network's free plan.
  static const String freeId = 'free';

  /// Stable id, stored in the account's config ([AccountSubscription.tierKey]).
  final String id;

  /// What the network calls the plan, e.g. "X Premium".
  final String label;

  /// What it changes in NEFORUM, in a few words: "Posts up to 25,000
  /// characters, videos up to 125 minutes".
  final String summary;

  bool get isFree => id == freeId;

  @override
  bool operator ==(Object other) => other is SubscriptionTier && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'SubscriptionTier($id)';
}

/// How NEFORUM knows an account's plan.
enum SubscriptionSource {
  /// The person chose it (connect form or account card).
  chosen,

  /// The network said so when the account connected or reconnected.
  detected,
}

/// The plans of one network that change what NEFORUM may post through one
/// way of posting ([PlatformTier]).
@immutable
class SubscriptionPlans {
  const SubscriptionPlans({
    required this.tiers,
    required this.fieldLabel,
    required this.help,
    this.detectedBy,
    this.assumedId = SubscriptionTier.freeId,
  });

  /// Every plan; the first is the free one ([SubscriptionTier.freeId]).
  final List<SubscriptionTier> tiers;

  /// Name of the choice on the connect form and the account card: "Parler
  /// Premium" for a switch, "X plan" for a list.
  final String fieldLabel;

  /// One or two sentences under the choice: what it changes.
  final String help;

  /// The network that reports the plan when the account connects ("X",
  /// "YouTube"), or null when the person chooses it.
  final String? detectedBy;

  /// The plan of an account whose plan nobody has stored or read yet. The
  /// free one, except where assuming it would refuse posts that went before
  /// 1.4.4 (YouTube: channels connected earlier keep their 12 hours until a
  /// reconnect reads the real answer).
  final String assumedId;

  /// The network reports the plan; the person can still change it.
  bool get detected => detectedBy != null;

  SubscriptionTier get free => tiers.first;

  /// Two plans read as a switch ("Parler Premium" on or off); more as a list.
  bool get isSwitch => tiers.length == 2;

  /// The plan with [id], or null when there is none.
  SubscriptionTier? tierWithId(String? id) => tiers.where((t) => t.id == id).firstOrNull;

  /// The plan the connect form's answer [raw] names: "true" / "false" for a
  /// switch, or a plan's id or label for a list. Null when [raw] names none.
  SubscriptionTier? fromInput(String? raw) {
    final v = (raw ?? '').trim();
    if (v.isEmpty) return null;
    final lower = v.toLowerCase();
    if (isSwitch && (lower == 'true' || lower == 'false')) return lower == 'true' ? tiers[1] : free;
    return tierWithId(v) ?? tiers.where((t) => t.label.toLowerCase() == lower).firstOrNull;
  }

  /// The connect form's question, under [AccountSubscription.tierKey]: a
  /// switch for two plans, a list of their labels for more. Starts on the
  /// free plan.
  ConnectField get connectField => isSwitch
      ? ConnectField(
          key: AccountSubscription.tierKey,
          label: fieldLabel,
          kind: FieldKind.boolean,
          required: false,
          defaultValue: 'false',
          help: help,
        )
      : ConnectField(
          key: AccountSubscription.tierKey,
          label: fieldLabel,
          kind: FieldKind.select,
          required: false,
          defaultValue: free.label,
          options: [for (final t in tiers) t.label],
          help: help,
        );
}

/// Where an account keeps its plan: three keys of [ConnectedAccount.config],
/// so the plan travels with the account through Sync and backups.
abstract final class AccountSubscription {
  /// The plan's [SubscriptionTier.id]; also the connect form's field key.
  static const String tierKey = 'subscriptionTier';

  /// [SubscriptionSource.name]: who set it.
  static const String sourceKey = 'subscriptionSource';

  /// When the network last reported it (UTC, ISO 8601); detected plans only.
  static const String checkedAtKey = 'subscriptionCheckedAt';

  /// The plan id stored on [account], or null when none is.
  static String? storedTierId(ConnectedAccount account) {
    final v = account.config[tierKey];
    return v is String && v.trim().isNotEmpty ? v.trim() : null;
  }

  /// Who set [account]'s plan; [SubscriptionSource.chosen] when unknown.
  static SubscriptionSource sourceOf(ConnectedAccount account) =>
      account.config[sourceKey] == SubscriptionSource.detected.name ? SubscriptionSource.detected : SubscriptionSource.chosen;

  /// When the network last reported [account]'s plan, or null.
  static DateTime? checkedAt(ConnectedAccount account) {
    final v = account.config[checkedAtKey];
    return v is String ? DateTime.tryParse(v) : null;
  }

  /// The config entries that store [tierId], set by [source] at [at].
  static Map<String, dynamic> entries(String tierId, {required SubscriptionSource source, DateTime? at}) => {
        tierKey: tierId,
        sourceKey: source.name,
        if (source == SubscriptionSource.detected && at != null) checkedAtKey: at.toUtc().toIso8601String(),
      };
}
