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
/// Locals has no public posting API. Posts are written in a community, on
/// its feed at `locals.com/<community>/feed` or in the Locals app, by its
/// creator and team or by supporters where the community allows member
/// posts. NEFORUM copies the post and opens the community the account was
/// connected with, where the NEFORUM browser extension fills in Locals'
/// composer (the "Regular Post" dialog).
///
/// Limits read from Locals' composer while signed in (2026-11-13): the body
/// counter stops at 15,000 characters, the title field at 255; the
/// community's settings allow 10 photos of up to 20 MB per post (another
/// community showed 5), or one video, one sound file or one PDF, never two
/// kinds together. Earlier, from the help centre ("How do I upload videos,
/// podcasts and photos?", updated 2024-04-03, and "How do I leave a post on
/// the Locals app?"): video and sound up to 5 minutes and under 200 MB for
/// members; Publish needs at least 10 characters in the app.
class LocalsAdapter extends HandoffOnlyAdapter {
  /// Where NEFORUM goes when the account has no community: the signed-in
  /// news feed (posts from the communities you follow; it has no composer).
  static const String feedUrl = 'https://locals.com/_/feed';

  /// Android package of the Locals.com app (linked from locals.com).
  static const String androidPackage = 'com.locals.localsapp';

  /// The composer's counter: "0/15,000".
  static const int maxTextLength = 15000;

  /// The title field's `maxlength`.
  static const int titleMax = 255;

  /// The community's `post_photo_limit` (and "You can upload up to 10
  /// photos in one post." in the help centre).
  static const int maxImages = 10;

  /// Another community's `post_photo_limit`: the cap is set per community.
  static const int smallCommunityMaxImages = 5;

  /// `limits.content.photo`: 20 MB a photo.
  static const int imageMaxBytes = 20 * 1024 * 1024;

  /// Members: "5 min duration and below 200MBs". Creators' limits depend on
  /// the community's plan, so these are warnings, not errors.
  static const int memberMediaMaxBytes = 200 * 1024 * 1024;
  static const int memberMediaMaxSeconds = 5 * 60;

  /// The Locals app keeps Publish greyed out below 10 characters.
  static const int minTextLength = 10;

  /// Config key: the community, as in its address `locals.com/<community>`.
  static const String communityKey = 'community';

  /// First parts of locals.com paths that are Locals' own pages, never a
  /// community (`locals.com/_/feed`, `locals.com/legacy/profile`).
  static const Set<String> _reservedPaths = {'_', 'legacy', 'feed', 'login', 'signup', 'register', 'settings', 'search', 'www'};

  static const PlatformDescriptor _descriptor = PlatformDescriptor(
    id: 'locals',
    name: 'Locals',
    iconKey: 'locals',
    homepage: 'https://locals.com/',
    tiers: {PlatformTier.handoff},
    defaultTier: PlatformTier.handoff,
    text: TextRules(
      maxLength: maxTextLength,
      counting: CountingRule.utf16,
      titleSupported: true,
      titleMax: titleMax,
      notes: 'Up to 15,000 characters, plain text (no bold, links or lists), and an optional title of up to 255. '
          'The Locals app needs at least 10 characters before Publish works. Articles (with a cover) are a separate '
          'kind of post you write on Locals.',
    ),
    media: MediaRules(
      maxImages: maxImages,
      imageMaxBytes: imageMaxBytes,
      // One video, one sound file or one PDF, alone: Locals' composer takes
      // one kind of media per post.
      maxVideos: 1,
      allowsMixedImageVideo: false,
      imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif', 'image/webp'},
      videoMimeTypes: {
        'video/mpeg', 'video/mp4', 'video/ogg', 'video/quicktime', 'video/webm', //
        'video/x-ms-wmv', 'video/x-flv', 'video/3gpp', 'video/3gpp2', 'video/x-msvideo', 'video/x-m4v',
      },
      maxAudios: 1,
      audioMimeTypes: {AudioMimeTypes.mp3, AudioMimeTypes.m4a, AudioMimeTypes.wav},
      audioWithOtherMedia: false,
      notes: 'Up to 10 photos (JPEG, PNG, GIF, WebP; 20 MB each) per post; some communities allow 5. Or one video, '
          'one sound file or one PDF, on its own: one kind of media per post. Videos and sound files: up to 5 '
          'minutes and under 200 MB for members, by the community\'s plan for creators. NEFORUM does not send PDFs.',
    ),
    personalAccountOk: true,
    accountRequirements: 'A Locals account that can post in a community: its creator or team, or a supporter '
        'where the community lets members post. NEFORUM never signs in to Locals.',
    apiCostSummary: 'Free. Locals has no public posting API, so NEFORUM copies your post and opens your '
        'community on locals.com, where the NEFORUM browser extension can fill it in; you click Publish.',
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
and opens your community's feed on locals.com (or the Locals app on Android). With the NEFORUM browser extension, the
post is filled in for you; otherwise click **Regular Post**, press Ctrl+V (⌘V on a Mac), add your photos or video and
click **Publish**.

Only a community's creator and team, and supporters in communities that allow member posts, can post on Locals. Enter
your **community** below so NEFORUM opens the right one.''';

  /// [input] as a community (the `name` of `locals.com/name`), or null when
  /// empty. Takes the name, a link to any page of the community
  /// (`locals.com/name/feed`) or its older address `name.locals.com`.
  /// Throws [ConnectException] for anything else.
  static String? parseCommunity(String? input) {
    var s = (input ?? '').trim().toLowerCase();
    if (s.isEmpty) return null;
    s = s.replaceFirst(RegExp(r'^[a-z][a-z0-9+.-]*://'), '');
    final parts = s.split(RegExp(r'[?#]')).first.split('/');
    final host = parts.first;
    String name;
    if (host == 'locals.com' || host == 'www.locals.com') {
      // locals.com/name/feed: the first part of the path.
      name = parts.length > 1 ? parts[1] : '';
    } else if (host.endsWith('.locals.com')) {
      name = host.substring(0, host.length - '.locals.com'.length);
      if (name.startsWith('www.')) name = name.substring(4);
    } else {
      // Just the name (a path after it, "name/feed", is the community's page).
      name = host;
    }
    if (!RegExp(r'^[a-z0-9](?:[a-z0-9_-]{0,61}[a-z0-9])?$').hasMatch(name) || _reservedPaths.contains(name)) {
      throw const ConnectException(
        'Enter the community as it is in its address: for locals.com/name, enter name.',
        field: communityKey,
      );
    }
    return name;
  }

  /// The community feed of [account] (where Locals' composer is), or null
  /// when it has none.
  static String? communityUrl(ConnectedAccount? account) {
    final c = account?.config[communityKey];
    return c is String && c.isNotEmpty ? 'https://locals.com/$c/feed' : null;
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
            placeholder: 'locals.com/name',
            help: 'Optional. The community you post in, as in its address (locals.com/name): enter name, or paste the '
                'link. Empty: NEFORUM opens your Locals news feed and you go to the community yourself.',
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
        displayName: labelled ? null : 'locals.com/$community',
        profileUrl: 'https://locals.com/$community/feed',
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
    final photos = variant.media.where((m) => m.isImage).length;
    if (photos > smallCommunityMaxImages && photos <= maxImages) {
      issues.add(const ValidationIssue.warning(
        'locals.photo_limit_varies',
        'Some Locals communities take only $smallCommunityMaxImages photos per post; if yours does, keep '
            '$smallCommunityMaxImages and post the others separately',
        field: 'media',
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
    final title = (variant.title ?? '').trim();
    final hasMedia = variant.media.isNotEmpty;
    final community = communityUrl(account);
    final steps = [
      community == null
          ? 'Your Locals news feed opens (sign in if asked). It has no composer: open your community\'s feed '
              '(locals.com/your community/feed).'
          : 'Your community\'s feed opens on locals.com (sign in if asked).',
      '${text.isEmpty ? 'Click **Regular Post**' : 'Click **Regular Post** and press Ctrl+V (⌘V on a Mac) in the post: your '
          'text is on the clipboard'}. In the app: My Communities, then **+**.',
      if (title.isNotEmpty) 'Copy the **Title** from here into **Title:**.',
      if (hasMedia)
        'Add your photos, video or sound with the buttons under the post: click **Save media to Downloads** here, '
            'then pick them on Locals. Keep the page open until the upload ends.',
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
      snippets: [if (title.isNotEmpty) HandoffSnippet('Title', title)],
      instructions: [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n'),
      mediaNote: 'Locals has no posting API and no link that fills in a post, so your text is on the clipboard'
          '${hasMedia ? ' and you add the media yourself' : ''}. With the NEFORUM browser extension, the post is '
          'filled in for you.',
    );
  }
}
