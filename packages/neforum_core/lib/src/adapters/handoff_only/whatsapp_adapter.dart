import '../../handoff/handoff_plan.dart';
import '../../model/account.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import 'handoff_common.dart';

/// WhatsApp (chats, Status and Channels) via hand-off.
///
/// There is no API for Status or Channels, and the paid WhatsApp Business
/// Platform only sends messages to customers. NEFORUM therefore opens
/// WhatsApp with the text prefilled (`https://wa.me/?text=`) or shares the
/// media to the WhatsApp app; the user picks a chat, "My status" or a Channel
/// in WhatsApp's own picker and taps Send.
class WhatsAppAdapter extends HandoffOnlyAdapter {
  /// Android package of the consumer WhatsApp app.
  static const String androidPackage = 'com.whatsapp';

  /// Android package of the WhatsApp Business app (same share target).
  static const String businessAndroidPackage = 'com.whatsapp.w4b';

  /// iOS URL scheme (`whatsapp://send?text=` opens a prefilled message).
  static const String iosScheme = 'whatsapp://';

  /// Status videos longer than this may be cut by WhatsApp (unverified,
  /// rolled out in 2024; older clients use 30 s).
  static const int statusVideoSeconds = 60;

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'whatsapp',
    name: 'WhatsApp',
    iconKey: 'whatsapp',
    homepage: 'https://www.whatsapp.com/',
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      // WhatsApp documents no message length limit; Status text and Channel
      // updates are typed in WhatsApp itself.
      maxLength: null,
      counting: CountingRule.utf16,
      supportsHashtags: false,
      notes: 'WhatsApp publishes no text limit for messages. NEFORUM prefills a message; '
          'you choose a chat, My status or a Channel inside WhatsApp.',
    ),
    media: MediaRules(
      // WhatsApp Help Center (web/desktop): up to 100 photos or videos at once.
      maxImages: 100,
      maxVideos: 100,
      allowsMixedImageVideo: true,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/webp', 'image/gif'},
      videoMimeTypes: {'video/mp4', 'video/quicktime', 'video/3gpp'},
      notes: 'Shared through the share sheet; WhatsApp compresses photos and videos. '
          'Status shows one photo or video per update.',
    ),
    personalAccountOk: true,
    accountRequirements: 'Any WhatsApp account with the WhatsApp app on your phone, or WhatsApp Web / '
        'WhatsApp Desktop on a computer. NEFORUM never signs in to WhatsApp.',
    apiCostSummary: 'Free. WhatsApp has no API for Status or Channels, and its paid Business Platform only '
        'sends messages to customers, so NEFORUM opens WhatsApp for you and you tap Send.',
    setupGuide: 'docs/platforms/whatsapp.md',
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  String get connectIntro => '''
**WhatsApp works by hand-off only.** There is nothing to create or sign in to.

WhatsApp has no public API for posting to **Status** or **Channels**. The WhatsApp Business Platform (Cloud API) is a paid
service for businesses to message their customers; it needs a Meta business portfolio and a dedicated phone number, and it
cannot post Status or Channel updates either.

When you publish, NEFORUM opens WhatsApp with your text already filled in (or shares your photos and videos to the
WhatsApp app). You then pick a chat, **My status** or one of your **Channels**, and tap **Send**.''';

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = [...super.validate(variant, account)];
    final longVideo = variant.media.any(
        (m) => m.isVideo && m.durationMs != null && m.durationMs! > statusVideoSeconds * 1000);
    if (longVideo) {
      issues.add(const ValidationIssue.info(
        'whatsapp.status_video_length',
        'WhatsApp Status may cut videos longer than about $statusVideoSeconds seconds; chats and Channels take longer ones',
        field: 'media',
      ));
    }
    if (variant.media.length > 1) {
      issues.add(const ValidationIssue.info(
        'whatsapp.status_multiple',
        'On Status every photo or video becomes its own update',
        field: 'media',
      ));
    }
    return issues;
  }

  /// `https://wa.me/?text=<percent-encoded>`: no recipient, so WhatsApp asks
  /// who to send it to. wa.me redirects to `api.whatsapp.com/send/?text=`,
  /// which hands over to WhatsApp Web on desktop.
  static Uri webIntentFor(String text) => Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}');

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final text = handoffFullText(variant);
    final hasMedia = variant.media.isNotEmpty;
    return HandoffPlan(
      platformId: descriptor.id,
      preferred: hasMedia ? HandoffMethod.shareSheet : HandoffMethod.webIntent,
      webIntent: text.isEmpty ? null : webIntentFor(text),
      clipboardText: nonEmptyOrNull(text),
      shareText: nonEmptyOrNull(text),
      shareFiles: variant.media,
      androidPackage: androidPackage,
      iosScheme: iosScheme,
      desktopUrl: 'https://web.whatsapp.com/',
      instructions: hasMedia
          ? '1. Pick **WhatsApp** in the share sheet (on a computer, open WhatsApp Web or Desktop and attach the files).\n'
              '2. Choose **My status**, one of your **Channels**, or a chat.\n'
              '3. Your text is on the clipboard; paste it as the caption if it is not there already.\n'
              '4. Tap **Send**.'
          : '1. WhatsApp opens with your text filled in.\n'
              '2. Choose a chat or one of your **Channels** and tap **Send**.\n'
              '3. For a text **Status**: open **Updates**, tap the pencil, paste the text (it is on the clipboard) and send.',
      mediaNote: 'WhatsApp decides where the post goes: NEFORUM cannot preselect Status or a Channel. '
          'Your text is also on the clipboard in case WhatsApp drops it.',
    );
  }
}
