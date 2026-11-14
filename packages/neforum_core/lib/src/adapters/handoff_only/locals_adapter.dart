import '../../handoff/handoff_plan.dart';
import '../../model/account.dart';
import '../../model/audio.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/validation.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import 'handoff_common.dart';

/// Locals (locals.com, owned by Rumble) via hand-off.
///
/// Locals has no public posting API. Posts are written in a community, on its
/// website (`name.locals.com`) or in the Locals app, by its creator and team
/// or by supporters where the community allows member posts. NEFORUM copies
/// the post and opens the community the account was connected with.
///
/// Limits from Locals' help centre ("How do I upload videos, podcasts and
/// photos?", updated 2024-04-03, and "How do I leave a post on the Locals
/// app?"): up to 10 photos per post; video and sound up to 5 minutes and
/// under 200 MB for members, by the community's plan for creators; Publish
/// needs at least 10 characters in the app. No character limit is published.
class LocalsAdapter extends HandoffOnlyAdapter {
  /// Where NEFORUM goes when the account has no community: the signed-in feed.
  static const String feedUrl = 'https://locals.com/feed';

  /// Android package of the Locals.com app (linked from locals.com).
  static const String androidPackage = 'com.locals.localsapp';

  /// "You can upload up to 10 photos in one post."
  static const int maxImages = 10;

  /// Members: "5 min duration and below 200MBs". Creators' limits depend on
  /// the community's plan, so these are warnings, not errors.
  static const int memberMediaMaxBytes = 200 * 1024 * 1024;
  static const int memberMediaMaxSeconds = 5 * 60;

  /// The Locals app keeps Publish greyed out below 10 characters.
  static const int minTextLength = 10;

  /// Config key: the community's name, as in `name.locals.com`.
  static const String communityKey = 'community';

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'locals',
    name: 'Locals',
    iconKey: 'locals',
    homepage: 'https://locals.com/',
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      // Locals publishes no character limit for posts.
      maxLength: null,
      counting: CountingRule.utf16,
      notes: 'Locals publishes no character limit for posts. The Locals app needs at least 10 characters before '
          'Publish works. Articles (with a title and a cover) are a separate kind of post you write on Locals.',
    ),
    media: MediaRules(
      maxImages: maxImages,
      // Locals does not say how many videos a post takes, or whether photos
      // and video mix; NEFORUM allows one video or one sound file, alone.
      maxVideos: 1,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif', 'image/webp'},
      videoMimeTypes: {
        'video/mpeg', 'video/mp4', 'video/ogg', 'video/quicktime', 'video/webm', //
        'video/x-ms-wmv', 'video/x-flv', 'video/3gpp', 'video/3gpp2',
      },
      maxAudios: 1,
      audioMimeTypes: {AudioMimeTypes.mp3, AudioMimeTypes.m4a, AudioMimeTypes.wav},
      notes: 'Up to 10 photos (JPEG, PNG, GIF, WebP) per post. Videos and sound files: up to 5 minutes and under '
          '200 MB for members, by the community\'s plan for creators. Locals does not say whether a post takes '
          'more than one video or photos with a video, so NEFORUM sends one video alone (unverified).',
    ),
    personalAccountOk: true,
    accountRequirements: 'A Locals account that can post in a community: its creator or team, or a supporter '
        'where the community lets members post. NEFORUM never signs in to Locals.',
    apiCostSummary: 'Free. Locals has no public posting API, so NEFORUM copies your post and opens your '
        'community on locals.com; you click Publish.',
    setupGuide: 'docs/platforms/locals.md',
  );

  @override
  SignInPolicy signInPolicyFor(ConnectedAccount account) => SignInPolicy.noConnection;

  @override
  PlatformDescriptor get descriptor => _descriptor;

  @override
  String get connectIntro => '''
**Locals works by hand-off only.** There is nothing to create or sign in to.

Locals has **no public API for posting**, so NEFORUM does not post for you. When you publish, NEFORUM copies your text
and opens your community on locals.com (or the Locals app on Android). Click **Write a Post**, press Ctrl+V (⌘V on a
Mac), add your photos or video and click **Publish**.

Only a community's creator and team, and supporters in communities that allow member posts, can post on Locals. Enter
your **community** below so NEFORUM opens the right one.''';

  /// [input] as a community name (`name` of `name.locals.com`), or null
  /// when empty. Takes the name, the host or a link to any page of it.
  /// Throws [ConnectException] for anything else.
  static String? parseCommunity(String? input) {
    var s = (input ?? '').trim().toLowerCase();
    if (s.isEmpty) return null;
    s = s.replaceFirst(RegExp(r'^[a-z][a-z0-9+.-]*://'), '');
    s = s.split(RegExp(r'[/?#]')).first;
    if (s.endsWith('.locals.com')) s = s.substring(0, s.length - '.locals.com'.length);
    if (s.startsWith('www.')) s = s.substring(4);
    if (!RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$').hasMatch(s) || s == 'www') {
      throw const ConnectException(
        'Enter the community as it is in its address: for name.locals.com, enter name.',
        field: communityKey,
      );
    }
    return s;
  }

  /// The community page of [account], or null when it has none.
  static String? communityUrl(ConnectedAccount? account) {
    final c = account?.config[communityKey];
    return c is String && c.isNotEmpty ? 'https://$c.locals.com/' : null;
  }

  @override
  List<ConnectSpec> get connectSpecs {
    final base = super.connectSpecs.single;
    return [
      ConnectSpec(
        tier: base.tier,
        intro: base.intro,
        loopbackRedirectOk: false,
        customSchemeRedirectOk: false,
        fields: [
          ...base.fields,
          const ConnectField(
            key: communityKey,
            label: 'Community',
            required: false,
            placeholder: 'name.locals.com',
            help: 'Optional. The community you post in, as in its address (name.locals.com). Empty: NEFORUM opens '
                'your Locals feed and you go to the community yourself.',
          ),
        ],
      ),
    ];
  }

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    final community = parseCommunity(input[communityKey]);
    final base = await super.connect(tier, input, ctx);
    if (community == null) return base;
    final a = base.account;
    final labelled = (input['label'] ?? '').trim().isNotEmpty;
    return ConnectResult(
      account: a.copyWith(
        displayName: labelled ? null : '$community.locals.com',
        profileUrl: 'https://$community.locals.com/',
        config: {...a.config, communityKey: community},
      ),
    );
  }

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = [...super.validate(variant, account)];
    final text = handoffFullText(variant);
    if (text.isNotEmpty && text.length < minTextLength) {
      issues.add(const ValidationIssue.warning(
        'locals.text_too_short',
        'The Locals app needs at least $minTextLength characters before you can publish',
        field: 'text',
      ));
    }
    final big = variant.media.where((m) =>
        (m.isVideo || m.isAudio) &&
        (m.sizeBytes >= memberMediaMaxBytes || (m.durationMs ?? 0) > memberMediaMaxSeconds * 1000));
    if (big.isNotEmpty) {
      issues.add(const ValidationIssue.warning(
        'locals.member_media_limit',
        'Locals members can post videos and sound up to 5 minutes and under 200 MB; a creator\'s limit depends '
            'on the community\'s plan',
        field: 'media',
      ));
    }
    return issues;
  }

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final text = handoffFullText(variant);
    final hasMedia = variant.media.isNotEmpty;
    final community = communityUrl(account);
    final steps = [
      community == null
          ? 'Your Locals feed opens (sign in if asked): go to the community you post in.'
          : 'Your community opens on locals.com (sign in if asked).',
      '${text.isEmpty ? 'Click **Write a Post**' : 'Click **Write a Post** and press Ctrl+V (⌘V on a Mac): your text is on '
          'the clipboard'}. In the app: My Communities, then **+**.',
      if (hasMedia)
        'Add your photos, video or sound under **Add Content**: click **Save media to Downloads** here, then pick '
            'them on Locals. Keep the page open until the upload ends.',
      'Click **Publish**.',
    ];
    return HandoffPlan(
      platformId: descriptor.id,
      // Locals does not say its app takes shared files, so nothing relies on it.
      preferred: HandoffMethod.manual,
      clipboardText: nonEmptyOrNull(text),
      shareText: nonEmptyOrNull(text),
      shareFiles: variant.media,
      androidPackage: androidPackage,
      desktopUrl: community ?? feedUrl,
      instructions: [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n'),
      mediaNote: 'Locals has no posting API and no link that fills in a post, so your text is on the clipboard'
          '${hasMedia ? ' and you add the media yourself' : ''}.',
    );
  }
}
