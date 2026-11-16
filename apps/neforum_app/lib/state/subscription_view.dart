import 'package:intl/intl.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

// 1.4.4: an account's paid plan in words, for the connect form and the
// account card. The plan itself lives in core (AccountSubscription,
// PlatformAdapter.subscriptionTierOf); docs/paid-tiers.md lists the networks.

/// The connect form's line for a plan the network reports itself.
String subscriptionDetectedNote(SubscriptionPlans plans) => plans.help;

/// What the account card says about [account]'s plan, under its name:
/// who set it and what it changes.
///
/// "Read from X on 16 Nov 2026. Posts up to 25,000 characters; ..."
/// "Chosen by you. Posts up to 2000 characters"
/// "X has not said yet; NEFORUM uses Standard channel. ..." (detected plans
/// with nothing stored)
String subscriptionCardLine(PlatformAdapter adapter, ConnectedAccount account) {
  final plans = adapter.subscriptionPlansFor(account.tier);
  final tier = adapter.subscriptionTierOf(account);
  if (plans == null || tier == null) return '';
  final stored = AccountSubscription.storedTierId(account) != null || adapter.legacySubscriptionTierId(account) != null;
  final at = AccountSubscription.checkedAt(account);
  final String who;
  if (!stored) {
    who = plans.detected
        ? '${plans.detectedBy} has not said yet. Reconnect to ask, or choose it here.'
        : 'Not set: NEFORUM uses the free limits. Choose your plan if you pay for one.';
  } else if (AccountSubscription.sourceOf(account) == SubscriptionSource.detected) {
    who = at == null ? 'Read from ${plans.detectedBy}.' : 'Read from ${plans.detectedBy} on ${DateFormat('d MMM y').format(at.toLocal())}.';
  } else {
    who = 'Chosen by you.';
  }
  return '$who ${tier.summary}.';
}
