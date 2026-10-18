import '../../handoff/handoff_plan.dart';
import '../../model/account.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import '../handoff_only/handoff_common.dart';
import 'video_site_common.dart';

/// BitChute videos via hand-off.
///
/// BitChute uploads only through its website (no API). NEFORUM opens
/// bitchute.com with the title, description and up to three search hashtags
/// ready to paste. BitChute can also import new YouTube uploads by itself
/// once its support team has verified the channel.
class BitChuteAdapter extends HandoffOnlyAdapter {
  static const String uploadUrl = 'https://www.bitchute.com/';
  static const int titleMax = 100;
  static const int descriptionMax = 3000;
  static const int maxTags = 3;

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'bitchute',
    name: 'BitChute',
    iconKey: 'bitchute',
    homepage: 'https://www.bitchute.com/',
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      maxLength: descriptionMax,
      titleSupported: true,
      titleRequired: true,
      titleMax: titleMax,
      hashtagsAsField: true,
      maxHashtags: maxTags,
      notes: 'Title up to 100 characters, description up to 3,000 (5,000 for members), up to three search hashtags.',
    ),
    media: MediaRules(
      maxVideos: 1,
      requiresMedia: true,
      videoMimeTypes: {
        'video/mp4',
        'video/quicktime',
        'video/webm',
        'video/x-matroska',
        'video/x-msvideo',
        'video/x-ms-wmv',
        'video/3gpp',
        'video/ogg',
        'video/x-m4v',
      },
      notes: 'One video per upload (MP4, MOV, AVI, WMV, 3GP, OGG, WEBM, MKV, M4V). BitChute asks for a thumbnail: '
          'pick a frame of the video or your own picture.',
    ),
    accountRequirements: 'A BitChute account with a channel. NEFORUM never signs in to BitChute; you upload on '
        'bitchute.com.',
    apiCostSummary: 'Free. BitChute uploads only through its website, so NEFORUM prepares the upload and you publish '
        'it there.',
    setupGuide: 'docs/platforms/bitchute.md',
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  String get connectIntro => '''
**BitChute works by hand-off.** There is nothing to create or sign in to.

BitChute uploads only through its website. When you publish, NEFORUM opens bitchute.com, puts your description on the
clipboard, lists the **title** and up to three **search hashtags** to copy, and saves your video to Downloads. On BitChute,
click the **upload** icon (top right), pick the video, choose a thumbnail and publish.

Tip: BitChute can also copy your new YouTube videos automatically once its support team verifies your channel
(BitChute help: "Automatically send your YouTube videos to BitChute").''';

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = [...super.validate(variant, account)];
    if (variant.tags.length > maxTags) {
      issues.add(const ValidationIssue.info('bitchute.tags', 'BitChute takes up to three search hashtags; the first three are used',
          field: 'tags'));
    }
    return issues;
  }

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) => videoSiteHandoff(
        variant,
        platformId: descriptor.id,
        name: descriptor.name,
        uploadUrl: uploadUrl,
        titleMax: titleMax,
        maxTags: maxTags,
        extraStep: 'Click the **upload** icon (top right) first if the upload form is not open, and pick a thumbnail.',
      );
}
