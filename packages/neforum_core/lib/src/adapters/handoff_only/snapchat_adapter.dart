import '../../handoff/handoff_plan.dart';
import '../../model/account.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import 'handoff_common.dart';

/// Snapchat (My Story, Spotlight, friends) via hand-off.
///
/// Snapchat's posting API (Public Profile API, part of the Marketing API) is
/// for partner integrations on behalf of brands and creators, not personal
/// accounts. Creative Kit only opens Snapchat's own preview and needs a Snap
/// Kit client id that a FOSS app cannot share. NEFORUM therefore shares the
/// photo or video to the Snapchat app through the system share sheet and puts
/// the caption on the clipboard: Snapchat ignores shared text.
class SnapchatAdapter extends HandoffOnlyAdapter {
  /// Android package of the Snapchat app.
  static const String androidPackage = 'com.snapchat.android';

  /// iOS URL scheme that opens Snapchat.
  static const String iosScheme = 'snapchat://';

  /// Creative Kit caption limit ("Captions are limited to 250 characters").
  static const int captionMax = 250;

  /// Creative Kit: "Shared media must be 300 MB or smaller".
  static const int mediaMaxBytes = 300 * 1024 * 1024;

  /// Creative Kit: "Videos must be no more than 5 minutes in duration".
  static const int videoMaxSeconds = 5 * 60;

  /// Width / height above which a picture is no longer "vertical enough"
  /// for Snapchat's 9:16 canvas (9/16 = 0.5625).
  static const double _maxVerticalRatio = 0.75;

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'snapchat',
    name: 'Snapchat',
    iconKey: 'snapchat',
    homepage: 'https://www.snapchat.com/',
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      maxLength: captionMax,
      counting: CountingRule.utf16,
      notes: 'The caption is pasted by you inside Snapchat (Snapchat ignores shared text). '
          '250 characters is the Creative Kit caption limit; Snapchat does not say how it counts.',
    ),
    media: MediaRules(
      maxImages: 1,
      maxVideos: 1,
      requiresMedia: true,
      imageMaxBytes: mediaMaxBytes,
      videoMaxBytes: mediaMaxBytes,
      videoMaxSeconds: videoMaxSeconds,
      imageMimeTypes: {'image/jpeg', 'image/png'},
      videoMimeTypes: {'video/mp4', 'video/quicktime'},
      notes: 'One photo or video per Snap. PNG/JPEG or MP4/MOV, up to 300 MB; videos up to 5 minutes are '
          'split into 10-second Snaps. Use 9:16 (vertical) for best results.',
    ),
    personalAccountOk: true,
    accountRequirements: 'Any Snapchat account and the Snapchat app on your phone. NEFORUM never signs in '
        'to Snapchat; you post from the Snapchat app.',
    apiCostSummary: "Free. Snapchat's posting API is only for approved partners posting for brands and "
        'creators, so NEFORUM hands your photo or video to the Snapchat app and you tap Send.',
    setupGuide: 'docs/platforms/snapchat.md',
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  String get connectIntro => '''
**Snapchat works by hand-off only.** There is nothing to create or sign in to.

Snapchat's posting API (the *Public Profile API*, part of the Snap Marketing API) is only for approved partners that
post on behalf of brands and creators. It is not open to personal accounts. Snap's *Creative Kit* only opens
Snapchat's own editor and needs an app registered and reviewed by Snap.

When you publish on your phone, NEFORUM shares your **photo or video** to the Snapchat app and copies your caption to
the clipboard (Snapchat ignores shared text). You add the caption, choose **My Story**, **Spotlight** or friends, and tap
**Send**. Snapchat posts always need a photo or video.''';

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = [...super.validate(variant, account)];
    final wide = variant.media.any((m) => (m.aspectRatio ?? 0) > _maxVerticalRatio);
    if (wide) {
      issues.add(const ValidationIssue.info(
        'snapchat.aspect_ratio',
        'Snapchat is made for vertical 9:16 photos and videos; wider ones are cropped or shown with bars',
        field: 'media',
      ));
    }
    return issues;
  }

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final text = handoffFullText(variant);
    final hasMedia = variant.media.isNotEmpty;
    return HandoffPlan(
      platformId: descriptor.id,
      preferred: hasMedia ? HandoffMethod.shareSheet : HandoffMethod.manual,
      clipboardText: nonEmptyOrNull(text),
      shareFiles: variant.media,
      androidPackage: androidPackage,
      iosScheme: iosScheme,
      desktopUrl: 'https://www.snapchat.com/web/',
      instructions: hasMedia
          ? '1. Pick **Snapchat** in the share sheet; your photo or video opens in Snapchat.\n'
              '2. Tap the caption tool (**T**) and paste: your text is on the clipboard.\n'
              '3. Tap **Send To**, choose **My Story**, **Spotlight** or friends, and send.'
          : '1. Snapchat posts need a photo or video: add one in NEFORUM, or take one in Snapchat.\n'
              '2. Your text is on the clipboard: paste it with the caption tool (**T**).\n'
              '3. Tap **Send To** and choose **My Story**, **Spotlight** or friends.',
      mediaNote: 'Only the photo or video can be handed to Snapchat; it ignores shared text, so your caption is on '
          'the clipboard. Posting a Story from a computer is limited; use the phone app.',
    );
  }
}
