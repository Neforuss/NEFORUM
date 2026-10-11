import '../../handoff/handoff_plan.dart';
import '../../model/account.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import 'handoff_common.dart';

/// Google Business Profile updates ("posts") via hand-off.
///
/// The Business Profile API (`localPosts`) exists, but every Google Cloud
/// project starts with a quota of 0 requests per minute until Google approves
/// a separate access application, which needs a verified profile older than
/// 60 days and a business website. A FOSS app cannot ship one shared approved
/// project, so NEFORUM opens business.google.com (or the Google Maps app) with
/// the text on the clipboard and the user adds the post there
/// (Posts > Add post > Update).
class GoogleBusinessAdapter extends HandoffOnlyAdapter {
  /// Where owners manage their profile on a computer.
  static const String desktopUrl = 'https://business.google.com/';

  /// The standalone Google My Business app (`com.google.android.apps.vega`)
  /// was retired in 2022 (its Play listing is gone); owners now manage their
  /// profile on Google Search / business.google.com or in Google Maps.
  static const String androidPackage = 'com.google.android.apps.maps';

  /// Google Maps iOS URL scheme.
  static const String iosScheme = 'comgooglemaps://';

  /// Widely cited post limit (not on Google's own help pages).
  static const int summaryMax = 1500;

  /// Google Business Profile photo guidelines: 10 KB to 5 MB.
  static const int photoMaxBytes = 5 * 1024 * 1024;

  /// Google Business Profile video guidelines: up to 75 MB, 30 seconds.
  static const int videoMaxBytes = 75 * 1024 * 1024;
  static const int videoMaxSeconds = 30;

  /// Rough phone-number pattern: digit groups with the usual separators.
  static final RegExp _phone = RegExp(r'(?<![\w/.])\+?\(?\d{1,4}\)?(?:[\s.-]?\d{2,4}){2,4}(?![\w/])');

  /// True when [text] seems to contain a phone number (9 or more digits in
  /// one group run, so dates like 2026-10-07 do not count).
  static bool hasPhoneNumber(String text) =>
      _phone.allMatches(text).any((m) => m[0]!.replaceAll(RegExp(r'\D'), '').length >= 9);

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'google_business',
    name: 'Google Business Profile',
    iconKey: 'google_business',
    homepage: 'https://business.google.com/',
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      maxLength: summaryMax,
      counting: CountingRule.utf16,
      supportsHashtags: false,
      notes: 'Updates allow about 1,500 characters (widely cited; Google does not publish the number). '
          'Event and offer posts also have a title, which you type in Google.',
    ),
    media: MediaRules(
      maxImages: 1,
      maxVideos: 1,
      imageMaxBytes: photoMaxBytes,
      videoMaxBytes: videoMaxBytes,
      videoMaxSeconds: videoMaxSeconds,
      imageMimeTypes: {'image/jpeg', 'image/png'},
      videoMimeTypes: {'video/mp4', 'video/quicktime'},
      notes: 'Photos JPG/PNG, 10 KB to 5 MB, at least 250 x 250 px (720 x 720 recommended). '
          'Videos up to 30 seconds and 75 MB, 720p or higher.',
    ),
    personalAccountOk: false,
    accountRequirements: 'You must be an owner or manager of a verified Google Business Profile. '
        'NEFORUM never signs in to Google; you add the update on business.google.com or in Google Maps.',
    apiCostSummary: "Free. Google's Business Profile API only works after Google approves a separate access "
        'request for your own Google Cloud project, so NEFORUM uses hand-off: it copies your text and opens Google.',
    setupGuide: 'docs/platforms/google_business.md',
    supportsLinkField: true,
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  String get connectIntro => '''
**Google Business Profile works by hand-off only.** There is nothing to create or sign in to.

Google does have a Business Profile API, but every new Google Cloud project starts with a quota of **0 requests** until
Google approves an *Application for Basic API Access*. To apply you must manage a profile that has been verified and
active for 60+ days and have a website for the business. NEFORUM is a free, open-source app and cannot share one approved
project between its users, so it does not use the API.

When you publish, NEFORUM copies your text and opens [business.google.com](https://business.google.com/) (on a phone:
your Business Profile in the Google Maps app). Choose **Posts** > **Add post** > **Update**, paste, add your photo and
select **Post**. You need to be an owner or manager of a verified Business Profile.''';

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = [...super.validate(variant, account)];
    if (hasPhoneNumber(variant.text)) {
      issues.add(const ValidationIssue.warning(
        'google_business.phone_in_text',
        'Google may remove posts with unverified contact details; add a "Call now" button instead of a phone number',
        field: 'text',
      ));
    }
    return issues;
  }

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final text = handoffFullText(variant);
    final link = (variant.link ?? '').trim();
    final hasMedia = variant.media.isNotEmpty;
    // Labels from Google's help page "How to make a post & track its status
    // for your Business Profile" (support.google.com/business/answer/7390603).
    final steps = <String>[
      'Open your profile on **business.google.com** (phone: your Business Profile in the Google Maps app), choose '
          '**Posts** > **Add post** and pick **Update**.',
      hasMedia
          ? 'Paste your text (it is on the clipboard) and add your photo or video.'
          : 'Paste your text: it is on the clipboard.',
      if (link.isNotEmpty) 'Under **Button**, pick **Learn more** and enter $link',
      'Select **Post**.',
    ];
    return HandoffPlan(
      platformId: descriptor.id,
      preferred: HandoffMethod.manual,
      clipboardText: nonEmptyOrNull(text),
      shareFiles: variant.media,
      androidPackage: androidPackage,
      iosScheme: iosScheme,
      desktopUrl: desktopUrl,
      instructions: [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n'),
      mediaNote: 'Google has no link that opens a prefilled update, so your text is on the clipboard'
          '${hasMedia ? ' and you add the photo or video yourself' : ''}.',
    );
  }
}
