import '../../model/platform_descriptor.dart';
import '../subscription_tiers.dart';

/// X's paid plans and what they change for NEFORUM (1.4.4).
///
/// Sources, read 2026-11-16:
/// * docs.x.com/x-api/posts/create-post: the `text` of `POST /2/tweets` is
///   "At most 280 characters unless the account has X Premium"; Post videos
///   are capped at 20 minutes and 8 GB by default and 125 minutes and 16 GB
///   for "X Premium / verified" accounts.
/// * docs.x.com/x-api/media/introduction: those caps follow "the
///   authenticated user's X Premium / verified status, not your developer API
///   plan", and "match the X app".
/// * help.x.com/en/using-x/x-premium: every X Premium tier (Basic, Premium,
///   Premium+) includes longer posts, "up to 25,000 characters".
/// * docs.x.com/x-api/users/get-my-user: `subscription_type` ("Basic,
///   Premium, PremiumPlus or None") and `verified_type` ("blue, government,
///   business or none") of the signed-in user.
///
/// Every paid plan has the same limits here, so [isPaid] is what the
/// descriptor asks. The newer "X Subscription" plans (Plus, Premium, Super,
/// Ultra) are not named in the API docs yet; an account X reports with any
/// other paid `subscription_type` gets [subscriptionId] and the Premium
/// limits, and the person can change it on the account card.
abstract final class XSubscription {
  static const String basicId = 'basic';
  static const String premiumId = 'premium';
  static const String premiumPlusId = 'premium_plus';
  static const String subscriptionId = 'x_subscription';
  static const String organizationId = 'verified_organization';

  /// A free account's post: 280 weighted characters.
  static const int freeMaxLength = 280;

  /// Longer posts of every X Premium tier.
  static const int paidMaxLength = 25000;

  /// Post videos by default: 20 minutes, 8 GB.
  static const int freeVideoMaxSeconds = 20 * 60;
  static const int freeVideoMaxBytes = 8 * 1024 * 1024 * 1024;

  /// Post videos of an X Premium or verified account: 125 minutes, 16 GB.
  static const int paidVideoMaxSeconds = 125 * 60;
  static const int paidVideoMaxBytes = 16 * 1024 * 1024 * 1024;

  static const String _paidSummary = 'Posts up to 25,000 characters; videos up to 125 minutes and 16 GB';

  static const List<SubscriptionTier> tiers = [
    SubscriptionTier(
        id: SubscriptionTier.freeId,
        label: 'X free',
        summary: 'Posts up to 280 characters (longer text becomes a thread); videos up to 20 minutes and 8 GB'),
    SubscriptionTier(id: basicId, label: 'X Premium Basic', summary: _paidSummary),
    SubscriptionTier(id: premiumId, label: 'X Premium', summary: _paidSummary),
    SubscriptionTier(id: premiumPlusId, label: 'X Premium+', summary: _paidSummary),
    SubscriptionTier(id: subscriptionId, label: 'The X Subscription (Plus, Premium, Super, Ultra)', summary: _paidSummary),
    SubscriptionTier(id: organizationId, label: 'Verified Organization', summary: _paidSummary),
  ];

  static const String _help = 'Every X Premium plan takes posts up to 25,000 characters and videos up to 125 '
      'minutes, so NEFORUM sends long text as one post instead of a thread.';

  /// API accounts: X says which plan the account has when it connects.
  static const SubscriptionPlans api = SubscriptionPlans(
    tiers: tiers,
    fieldLabel: 'X plan',
    help: '$_help NEFORUM reads the plan from X when you connect.',
    detectedBy: 'X',
  );

  /// Hand-off accounts: NEFORUM never signs in to X, so the person says.
  static const SubscriptionPlans handoff = SubscriptionPlans(
    tiers: tiers,
    fieldLabel: 'X plan',
    help: '$_help Choose the plan this X account has.',
  );

  /// Whether [tier] is a paid plan (all of them have the same limits).
  static bool isPaid(SubscriptionTier? tier) => tier != null && !tier.isFree;

  /// The plan X reports in `GET /2/users/me`, from its `subscription_type`
  /// and `verified_type`; null when X sent neither (nothing to go on).
  ///
  /// `subscription_type` decides when X sends it: Basic, Premium and
  /// PremiumPlus by name, None as free, any other value as a paid plan of The
  /// X Subscription. Without it, `verified_type` business or government is a
  /// Verified Organization, blue a paid plan of unknown name, none free.
  static String? tierIdFromProfile({Object? subscriptionType, Object? verifiedType}) {
    String norm(Object? v) => v is String ? v.toLowerCase().replaceAll(RegExp('[^a-z]'), '') : '';
    final sub = norm(subscriptionType);
    if (sub.isNotEmpty) {
      return switch (sub) {
        'none' || 'free' => SubscriptionTier.freeId,
        'basic' => basicId,
        'premium' => premiumId,
        'premiumplus' => premiumPlusId,
        _ => subscriptionId,
      };
    }
    return switch (norm(verifiedType)) {
      '' => null,
      'business' || 'government' => organizationId,
      'blue' => subscriptionId,
      _ => SubscriptionTier.freeId,
    };
  }

  /// [text] for an account on a paid plan: 25,000 characters.
  static TextRules paidText(TextRules text) => text.copyWith(
        maxLength: paidMaxLength,
        notes: 'Weighted count: most Latin/Cyrillic characters count 1, CJK and emoji count 2, every link counts 23. '
            'This account has an X Premium plan, so posts take up to 25,000 characters and long text goes as one '
            'post; timelines show the first 280 before "Show more".',
      );

  /// [media] for an account on a paid plan: videos up to 125 minutes, 16 GB.
  static MediaRules paidMedia(MediaRules media) => media.copyWith(
        videoMaxSeconds: paidVideoMaxSeconds,
        videoMaxBytes: paidVideoMaxBytes,
        notes: '${media.notes ?? ''} With this account\'s X Premium plan: videos up to 125 minutes and 16 GB.'.trim(),
      );
}
