import 'package:uuid/uuid.dart';

import '../../handoff/handoff_plan.dart';
import '../../model/account.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../handoff_only/handoff_common.dart';

/// YouTube Posts: the text, image, poll and quiz posts on a channel's Posts
/// tab (called the Community tab until 2025), YouTube's equivalent of a
/// tweet. Separate from [YouTubeAdapter], which uploads videos.
///
/// The YouTube Data API has no way to create posts: its resources cover
/// videos, playlists, comments and channel settings only, and it dropped
/// channel discussions on 2024-04-30 (developers.google.com/youtube/v3/
/// revision_history). Tools that automate posts drive YouTube's private web
/// API with the user's cookies, which YouTube's terms forbid. So NEFORUM
/// hands the post off: text on the clipboard, then youtube.com or the
/// YouTube app, where the user picks Create > Create post.
class YouTubePostsAdapter extends HandoffOnlyAdapter {
  /// Help page the limits below come from ("Create a post",
  /// support.google.com/youtube/answer/7124474).
  static const String helpUrl = 'https://support.google.com/youtube/answer/7124474';

  /// Create > Create post is in the top bar of every youtube.com page.
  static const String desktopUrl = 'https://www.youtube.com/';
  static const String androidPackage = 'com.google.android.youtube';
  static const String iosScheme = 'youtube://';

  /// "Up to 10 images per post, which can include animated GIFs", JPG, PNG,
  /// GIF or WEBP, up to 16 MB each.
  static const int maxImages = 10;
  static const int imageMaxBytes = 16 * 1024 * 1024;

  /// Longer posts are cut off behind "Read more" at about this length.
  static const int previewLength = 280;

  /// YouTube handles: 3 to 30 letters, digits, underscores, hyphens or dots
  /// (letters from any script).
  static final RegExp _handle = RegExp(r'^@[\p{L}\p{N}._-]{3,30}$', unicode: true);
  static final RegExp _channelId = RegExp(r'^UC[\w-]{22}$');

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'youtube_posts',
    name: 'YouTube Posts',
    iconKey: 'youtube',
    homepage: 'https://www.youtube.com/',
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      counting: CountingRule.utf16,
      notes: 'YouTube publishes no length limit for posts; viewers see about the first 280 characters before '
          '"Read more". Polls and quizzes are added in YouTube.',
    ),
    media: MediaRules(
      maxImages: maxImages,
      imageMaxBytes: imageMaxBytes,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif', 'image/webp'},
      notes: 'Up to 10 images or GIFs, JPG/PNG/GIF/WEBP, 16 MB each; square (1:1) shows best in the feed. '
          'A post cannot upload a video: paste a YouTube video link instead.',
    ),
    accountRequirements: 'Any channel with advanced features turned on (YouTube Studio > Settings > Channel > Feature '
        'eligibility) that is not set as "Made for Kids". There is no subscriber minimum. NEFORUM never signs in '
        'to YouTube; you post on youtube.com or in the YouTube app.',
    apiCostSummary: "Free. YouTube's API can upload videos but cannot create posts, so NEFORUM uses hand-off: it "
        'copies your text and opens YouTube, where you choose Create > Create post. For videos, connect "YouTube".',
    setupGuide: 'docs/platforms/youtube_posts.md',
  );

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  String get defaultDisplayName => 'YouTube Posts';

  @override
  String get connectIntro => '''
**YouTube Posts work by hand-off.** These are the text and image posts on your channel's **Posts** tab (once called
the Community tab), not videos or Shorts. For videos, connect **YouTube** instead.

YouTube's API can upload videos but has no way to create posts, and the tools that fake it drive YouTube's website with
your login cookies, which YouTube's terms forbid. So when you publish, NEFORUM copies your text and opens YouTube. Choose
**Create** > **Create post** (on a phone: the **+** button, then **Post**), paste, add your images and select **Post**.

Your channel needs advanced features turned on (YouTube Studio > **Settings** > **Channel** > **Feature eligibility**)
and must not be set as Made for Kids. There is no subscriber minimum.''';

  @override
  List<ConnectSpec> get connectSpecs => [
        ConnectSpec(
          tier: PlatformTier.handoff,
          intro: connectIntro,
          loopbackRedirectOk: false,
          customSchemeRedirectOk: false,
          fields: [
            const ConnectField(
              key: 'channel',
              label: 'Your channel',
              required: false,
              help: 'Optional. Your handle (@name) or channel link, so NEFORUM can show which channel this is.',
              placeholder: '@yourchannel',
            ),
            ConnectField(
              key: 'label',
              label: 'Label',
              required: false,
              help: labelHelp,
              placeholder: defaultDisplayName,
            ),
          ],
        ),
      ];

  /// Normalises what the user typed into `@handle` or `channel/UC…`.
  /// Returns null for an empty field; throws [ConnectException] for
  /// something that is not a channel.
  static String? parseChannel(String input) {
    var s = input.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('http://') || s.startsWith('https://') || s.startsWith('www.') || s.startsWith('youtube.com')) {
      final uri = Uri.tryParse(s.startsWith('http') ? s : 'https://$s');
      final host = uri?.host.toLowerCase() ?? '';
      if (uri == null || !(host == 'youtube.com' || host.endsWith('.youtube.com'))) {
        throw const ConnectException('That is not a youtube.com channel link', field: 'channel');
      }
      final seg = uri.pathSegments.where((x) => x.isNotEmpty).toList();
      if (seg.length >= 2 && seg.first == 'channel' && _channelId.hasMatch(seg[1])) return 'channel/${seg[1]}';
      if (seg.isEmpty || !seg.first.startsWith('@')) {
        throw const ConnectException('Use your channel link (youtube.com/@name) or just @name', field: 'channel');
      }
      s = Uri.decodeComponent(seg.first);
    }
    if (_channelId.hasMatch(s)) return 'channel/$s';
    if (!s.startsWith('@')) s = '@$s';
    if (!_handle.hasMatch(s)) {
      throw const ConnectException('A YouTube handle is @ plus 3 to 30 letters, numbers, dots, dashes or underscores',
          field: 'channel');
    }
    return s;
  }

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier != PlatformTier.handoff) {
      throw ConnectException('${descriptor.name} only supports the "${PlatformTier.handoff.label}" tier in NEFORUM');
    }
    final channel = parseChannel(input['channel'] ?? '');
    final label = (input['label'] ?? '').trim();
    if (label.length > HandoffOnlyAdapter.maxLabelLength) {
      throw const ConnectException('Please keep the label under ${HandoffOnlyAdapter.maxLabelLength} characters', field: 'label');
    }
    final handle = channel != null && channel.startsWith('@') ? channel : null;
    return ConnectResult(
      account: ConnectedAccount(
        id: '$id:handoff:${const Uuid().v4()}',
        platformId: id,
        tier: PlatformTier.handoff,
        displayName: label.isNotEmpty ? label : (handle ?? defaultDisplayName),
        handle: handle,
        profileUrl: channel == null ? null : 'https://www.youtube.com/$channel',
        createdAt: ctx.now(),
        config: {
          if (label.isNotEmpty) 'label': label,
          if (channel != null) 'channel': channel,
        },
      ),
    );
  }

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = [...super.validate(variant, account)];
    if (handoffFullText(variant).length > previewLength) {
      issues.add(const ValidationIssue.info(
        'youtube_posts.read_more',
        'YouTube shows about the first $previewLength characters; the rest is behind "Read more"',
        field: 'text',
      ));
    }
    return issues;
  }

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final text = handoffFullText(variant);
    final images = variant.media.length;
    final steps = <String>[
      'On youtube.com select **Create** > **Create post** at the top of the page. In the YouTube app tap **+** '
          '(Create), then **Post**.',
      if (text.isNotEmpty) 'Paste your text: it is on the clipboard.',
      if (images > 0)
        'Choose the image option and add your ${images == 1 ? 'image' : '$images images'}. On a phone, use '
            '**Share with media** first to save ${images == 1 ? 'it' : 'them'} to your photos.',
      'Select **Post** (or the arrow next to it to schedule).',
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
      mediaNote: 'YouTube has no link that opens a prefilled post, so your text is on the clipboard'
          '${images > 0 ? ' and you add the images in its post editor' : ''}.',
    );
  }
}
