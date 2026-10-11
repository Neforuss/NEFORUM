import '../../handoff/handoff_plan.dart';
import '../../model/account.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import 'handoff_common.dart';

/// Substack Notes via hand-off.
///
/// Substack has no publishing API at all: its official Developer API is
/// read-only profile data, and unofficial tools drive undocumented endpoints
/// with a browser cookie, which Substack's terms forbid. The Notes composer
/// accepts no URL parameters, so NEFORUM copies the text and opens Substack;
/// the user pastes it into "What's on your mind?" and taps Post.
class SubstackAdapter extends HandoffOnlyAdapter {
  /// The signed-in home feed, which has the Notes composer on top.
  static const String desktopUrl = 'https://substack.com/home';

  /// Android package of the Substack app (from research; not confirmed on
  /// an official Substack page).
  static const String androidPackage = 'com.substack.app';

  /// Substack Notes FAQ: "add up to 6 images or GIFs".
  static const int maxImages = 6;

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'substack',
    name: 'Substack Notes',
    iconKey: 'substack',
    homepage: 'https://substack.com/',
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      // Substack publishes no Notes limit ("We dare you to try to figure out
      // the character limit").
      maxLength: null,
      counting: CountingRule.utf16,
      supportsHashtags: false,
      notes: 'Substack publishes no character limit for Notes. Bold, italic and @mentions are added in the '
          'composer; a pasted URL becomes a link preview.',
    ),
    media: MediaRules(
      maxImages: maxImages,
      maxVideos: 1,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif', 'image/webp'},
      videoMimeTypes: {'video/mp4', 'video/quicktime'},
      notes: 'Up to 6 images or GIFs per note (GIFs from the web only). Video in notes is newer and only '
          'documented in the app; images and video cannot be mixed.',
    ),
    personalAccountOk: true,
    accountRequirements: 'Any Substack account (you do not need your own publication). NEFORUM never signs in '
        'to Substack; you post from substack.com or the Substack app.',
    apiCostSummary: 'Free. Substack has no API for posting Notes, so NEFORUM copies your text and opens Substack; '
        'you paste it and tap Post.',
    setupGuide: 'docs/platforms/substack.md',
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  String get connectIntro => '''
**Substack Notes work by hand-off only.** There is nothing to create or sign in to.

Substack has **no API for posting**. Its official Developer API only reads public profile data, and the unofficial
tools that post for you use your browser login on undocumented parts of the site, which Substack's terms of use do not
allow. NEFORUM does not do that.

When you publish, NEFORUM copies your text and opens [substack.com](https://substack.com/home). Click
**What's on your mind?** (or **+** in the Notes tab), paste, add your images and click **Post**.''';

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = [...super.validate(variant, account)];
    if (variant.media.any((m) => m.mimeType == 'image/gif')) {
      issues.add(const ValidationIssue.info(
        'substack.gif_web_only',
        'Substack lets you add GIFs to a note on the web only, not in the app',
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
      preferred: HandoffMethod.manual,
      clipboardText: nonEmptyOrNull(text),
      shareText: nonEmptyOrNull(text),
      shareFiles: variant.media,
      androidPackage: androidPackage,
      desktopUrl: desktopUrl,
      instructions: '1. On Substack, click **What\'s on your mind?** at the top of Home (app: Notes tab, then **+**).\n'
          '2. Paste your text: it is on the clipboard.\n'
          '${hasMedia ? '3. Add your images or video with the photo icon.\n4. Click **Post**.' : '3. Click **Post**.'}',
      mediaNote: 'Substack has no link that opens a prefilled note, so your text is on the clipboard'
          '${hasMedia ? ' and you attach the media yourself' : ''}.',
    );
  }
}
