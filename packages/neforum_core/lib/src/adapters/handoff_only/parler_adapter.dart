import '../../handoff/handoff_plan.dart';
import '../../model/account.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import '../../text/rules_validator.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../subscription_tiers.dart';
import 'handoff_common.dart';

/// Parler via hand-off.
///
/// Parler publishes no posting API, and the unofficial client
/// (parler-py-api) was archived on 2026-03-08. NEFORUM copies the post and opens the web composer at
/// app.parler.com/compose; the NEFORUM browser extension can fill it in.
///
/// The limits below were read from Parler's web app (its composer and the
/// code it loads) on 2026-11-13, because Parler's help centre states none of
/// them: 300 characters on a free account and 2000 with Premium, counted per
/// code point; at most 4 photos, GIFs and videos together; photos up to
/// 20 MB; videos up to 500 MB and 60 minutes.
class ParlerAdapter extends HandoffOnlyAdapter {
  /// The web composer: opens as a dialog over the feed.
  static const String composerUrl = 'https://app.parler.com/compose';

  /// Characters per post on a free account (the composer's counter).
  static const int freeMaxLength = 300;

  /// Characters per post with Parler Premium.
  static const int premiumMaxLength = 2000;

  /// "Maximum 4 attachments allowed": photos, GIFs and videos together.
  static const int maxAttachments = 4;

  /// "Photos must be 20 MB or smaller".
  static const int imageMaxBytes = 20 * 1024 * 1024;

  /// "Videos must be 500 MB or smaller".
  static const int videoMaxBytes = 500 * 1024 * 1024;

  /// "Videos must be 60 minutes or shorter".
  static const int videoMaxSeconds = 60 * 60;

  /// Config key of 1.4.3: the account has Parler Premium (2000 characters).
  /// 1.4.4 keeps the plan under [AccountSubscription.tierKey] and still writes
  /// this key, so a device on 1.4.3 reads the same plan through Sync.
  static const String premiumKey = 'premium';

  /// The id of Parler Premium among [plans].
  static const String premiumTierId = 'premium';

  /// Free (300 characters) or Parler Premium (2000), chosen by the person:
  /// Parler has no API that could say.
  static const SubscriptionPlans plans = SubscriptionPlans(
    fieldLabel: 'Parler Premium',
    help: 'Turn on if this account has Parler Premium: posts can then be $premiumMaxLength characters instead of '
        '$freeMaxLength.',
    tiers: [
      SubscriptionTier(id: SubscriptionTier.freeId, label: 'Parler free', summary: 'Posts up to $freeMaxLength characters'),
      SubscriptionTier(id: premiumTierId, label: 'Parler Premium', summary: 'Posts up to $premiumMaxLength characters'),
    ],
  );

  static PlatformDescriptor _build(int maxLength) => PlatformDescriptor(
        id: 'parler',
        name: 'Parler',
        iconKey: 'parler',
        homepage: 'https://parler.com/',
        tiers: const {PlatformTier.handoff},
        defaultTier: PlatformTier.handoff,
        text: TextRules(
          maxLength: maxLength,
          counting: CountingRule.codePoints,
          notes: 'Posts take $freeMaxLength characters on a free account and $premiumMaxLength with Parler Premium '
              '(turn on Premium for the account in NEFORUM). Parler counts every character as one, emoji included. '
              'Read from parler.com\'s composer; its help centre states no limit.',
        ),
        media: const MediaRules(
          maxImages: maxAttachments,
          maxVideos: maxAttachments,
          allowsMixedImageVideo: true,
          imageMaxBytes: imageMaxBytes,
          videoMaxBytes: videoMaxBytes,
          videoMaxSeconds: videoMaxSeconds,
          imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif', 'image/webp'},
          videoMimeTypes: {'video/mp4', 'video/quicktime', 'video/webm'},
          // Sound goes as a video of one still picture, made by the app.
          audioAsVideo: true,
          notes: 'Up to 4 photos, GIFs and videos per post, together. Photos (JPEG, PNG, GIF, WebP) up to 20 MB; '
              'videos (MP4, MOV, WebM) up to 500 MB and 60 minutes. Read from parler.com\'s composer.',
        ),
        personalAccountOk: true,
        accountRequirements: 'Any Parler account. NEFORUM never signs in to Parler; you post from app.parler.com '
            'or the Parler app.',
        apiCostSummary: 'Free. Parler has no public posting API, so NEFORUM copies your post and opens Parler\'s '
            'composer; you click Post.',
        setupGuide: 'docs/platforms/parler.md',
      );

  static final PlatformDescriptor _free = _build(freeMaxLength);
  static final PlatformDescriptor _premium = _build(premiumMaxLength);

  /// Whether [account] has Parler Premium: its plan ([AccountSubscription]),
  /// or for an account set up by 1.4.3, its `premium` switch.
  static bool isPremium(ConnectedAccount account) => ParlerAdapter().subscriptionTierOf(account)?.id == premiumTierId;

  @override
  SignInPolicy signInPolicyFor(ConnectedAccount account) => SignInPolicy.noConnection;

  @override
  PlatformDescriptor get descriptor => _free;

  @override
  PlatformDescriptor descriptorForAccount(ConnectedAccount account) =>
      subscriptionTierOf(account)?.id == premiumTierId ? _premium : _free;

  @override
  SubscriptionPlans? subscriptionPlansFor(PlatformTier tier) => tier == PlatformTier.handoff ? plans : null;

  /// 1.4.3 stored Parler Premium as `premium: true` (or "true" from the form).
  @override
  String? legacySubscriptionTierId(ConnectedAccount account) {
    final v = account.config[premiumKey];
    if (v == null) return null;
    return v == true || (v is String && v.trim().toLowerCase() == 'true') ? premiumTierId : SubscriptionTier.freeId;
  }

  /// The plan, and the 1.4.3 switch beside it for devices not yet on 1.4.4.
  @override
  ConnectedAccount withSubscriptionTier(ConnectedAccount account, String tierId,
      {SubscriptionSource source = SubscriptionSource.chosen, DateTime? at}) {
    final next = super.withSubscriptionTier(account, tierId, source: source, at: at);
    final config = {...next.config};
    if (tierId == premiumTierId) {
      config[premiumKey] = true;
    } else {
      config.remove(premiumKey);
    }
    return next.copyWith(config: config);
  }

  @override
  String get connectIntro => '''
**Parler works by hand-off only.** There is nothing to create or sign in to.

Parler publishes **no API for posting**, and the unofficial tool that posted for you has been archived. NEFORUM does
not use your Parler login.

When you publish, NEFORUM copies your text and opens [Parler's composer](https://app.parler.com/compose). Press
Ctrl+V (⌘V on a Mac), add your photos or video and click **Post**. With the NEFORUM browser extension paired, the
composer is filled in for you.

Parler posts take 300 characters, or 2000 with **Parler Premium**: turn on **Parler Premium** below if you have it.''';

  @override
  List<ConnectSpec> get connectSpecs {
    final base = super.connectSpecs.single;
    return [
      ConnectSpec(
        tier: base.tier,
        intro: base.intro,
        loopbackRedirectOk: false,
        customSchemeRedirectOk: false,
        fields: [...base.fields, plans.connectField],
      ),
    ];
  }

  /// Parler Premium is stored only when turned on, so a free account keeps
  /// the config 1.4.3 gave it. The form's `premium` answer of 1.4.3 still
  /// counts.
  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    final base = await super.connect(tier, input, ctx);
    final answer = input[AccountSubscription.tierKey] ?? input[premiumKey];
    if (plans.fromInput(answer)?.id != premiumTierId) return base;
    return ConnectResult(account: withSubscriptionTier(base.account, premiumTierId), secrets: base.secrets);
  }

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = RulesValidator.validate(variant, descriptorForAccount(account), tier: account.tier);
    // Sound files go as videos, so every file takes one of the 4 places.
    final n = variant.media.length;
    if (n > maxAttachments) {
      issues.add(ValidationIssue.error(
        'parler.too_many_attachments',
        '$n photos and videos; Parler takes at most $maxAttachments per post, together',
        field: 'media',
      ));
    }
    return issues;
  }

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final text = handoffFullText(variant);
    final hasMedia = variant.media.isNotEmpty;
    final steps = [
      "Parler's composer opens at app.parler.com (sign in if asked).",
      if (text.isNotEmpty) "Click **What's on your mind?** and press Ctrl+V (⌘V on a Mac): your text is on the clipboard.",
      if (hasMedia)
        'Add your photos or video: click **Save media to Downloads** here, then **Attach media** in Parler and pick '
            'them (or drag them in).',
      'Click **Post**.',
    ];
    return HandoffPlan(
      platformId: descriptor.id,
      preferred: HandoffMethod.manual,
      clipboardText: nonEmptyOrNull(text),
      shareText: nonEmptyOrNull(text),
      shareFiles: variant.media,
      desktopUrl: composerUrl,
      instructions: [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n'),
      mediaNote: 'Parler has no posting API and documents no link that fills in its composer, so your text is on the clipboard'
          '${hasMedia ? ' and you add the media yourself' : ''}. With the NEFORUM browser extension paired, '
          'it fills in the composer for you.',
    );
  }
}
