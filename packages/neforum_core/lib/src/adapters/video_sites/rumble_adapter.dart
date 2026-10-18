import '../../handoff/handoff_plan.dart';
import '../../model/account.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../handoff_only/handoff_common.dart';
import 'video_site_common.dart';

/// Rumble videos via hand-off.
///
/// Rumble has no self-serve upload API (as of October 2026 its developer
/// offerings are for live streams and approved partners), so NEFORUM opens
/// rumble.com's upload page with the title, description and tags ready to
/// paste, and the video saved to Downloads to pick.
class RumbleAdapter extends HandoffOnlyAdapter {
  static const String uploadUrl = 'https://rumble.com/upload.php';
  static const int titleMax = 100;

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'rumble',
    name: 'Rumble',
    iconKey: 'rumble',
    homepage: 'https://rumble.com/',
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      maxLength: 5000,
      titleSupported: true,
      titleRequired: true,
      titleMax: titleMax,
      hashtagsAsField: true,
      notes: 'The text is the video description; the title goes in its own field (NEFORUM uses the first line '
          'when the post has no title). Rumble does not publish its exact limits.',
    ),
    media: MediaRules(
      maxVideos: 1,
      requiresMedia: true,
      videoMimeTypes: {'video/mp4', 'video/quicktime', 'video/webm', 'video/x-matroska', 'video/x-msvideo', 'video/x-ms-wmv'},
      notes: 'One video per upload. You pick the file on rumble.com.',
    ),
    accountRequirements: 'Any Rumble account. NEFORUM never signs in to Rumble; you upload on rumble.com.',
    apiCostSummary: 'Free. Rumble has no upload API for personal accounts, so NEFORUM prepares the upload and you '
        'publish it on rumble.com.',
    setupGuide: 'docs/platforms/rumble.md',
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  String get connectIntro => '''
**Rumble works by hand-off.** There is nothing to create or sign in to.

Rumble has no upload API that a personal account can use. When you publish, NEFORUM opens Rumble's upload page, puts your
description on the clipboard, lists the **title** and **tags** to copy, and saves your video to Downloads so you can pick
it in Rumble's file picker. Rumble posts always need a video.''';

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) => videoSiteHandoff(
        variant,
        platformId: descriptor.id,
        name: descriptor.name,
        uploadUrl: uploadUrl,
        titleMax: titleMax,
        androidPackage: 'com.rumble.battles',
        extraStep: 'Choose a category, the licence and the visibility Rumble asks for.',
      );
}
