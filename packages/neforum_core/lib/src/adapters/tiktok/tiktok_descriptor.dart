import '../../model/platform_descriptor.dart';
import '../connect_spec.dart';

/// Static description of TikTok (numbers from the Content Posting API
/// reference and media transfer guide, checked 2026-10-10).
const tiktokDescriptor = PlatformDescriptor(
  id: 'tiktok',
  name: 'TikTok',
  iconKey: 'tiktok',
  homepage: 'https://www.tiktok.com',
  tiers: {PlatformTier.handoff, PlatformTier.byokApi},
  defaultTier: PlatformTier.handoff,
  text: TextRules(
    // Direct Post video `title` (the caption): "2200 UTF-16 runes".
    maxLength: 2200,
    counting: CountingRule.utf16,
    // Photo posts only: post_info.title, "90 in UTF-16 runes".
    titleMax: 90,
    titleSupported: true,
    supportsThreads: false,
    supportsContentWarning: false,
    supportsHashtags: true,
    hashtagsAsField: false,
    // Links in TikTok captions are not clickable.
    linkInText: false,
    notes: 'The caption is the video "title" (max 2200 UTF-16 code units; #hashtags and @mentions inline). '
        'Photo posts use the text as the description (max 4000) and the post title as the photo title (max 90). '
        'Links in captions are not clickable.',
  ),
  media: MediaRules(
    // Sound goes as a video of one still picture, made by the app.
    audioAsVideo: true,
    maxImages: 35,
    maxVideos: 1,
    requiresMedia: true,
    allowsMixedImageVideo: false,
    imageMaxBytes: 20 * 1024 * 1024,
    videoMaxBytes: 4 * 1024 * 1024 * 1024,
    videoMaxSeconds: 600,
    imageMimeTypes: {'image/jpeg', 'image/webp'},
    videoMimeTypes: {'video/mp4', 'video/quicktime', 'video/webm'},
    supportsAltText: false,
    // Videos are uploaded directly (FILE_UPLOAD); only photos need a public
    // URL, which validate()/publish() check separately.
    requiresPublicMediaUrl: false,
    notes: 'One video (MP4/MOV/WebM, 360-4096 px per side, 23-60 fps, up to 10 min and 4 GB) or 1-35 photos '
        '(JPEG/WebP, max 1080p, 20 MB each). Via the API, photos can only be pulled by TikTok from an HTTPS URL '
        'on a domain you verified in your TikTok developer app.',
  ),
  defaultQuotas: [
    QuotaRule(
      id: 'tiktok.posts_per_day',
      limit: 15,
      window: Duration(days: 1),
      note: 'TikTok caps API posts per creator per day (shared by every app; the exact number varies by account, ~15 is typical).',
      appliesToTier: PlatformTier.byokApi,
    ),
    QuotaRule(
      id: 'tiktok.init_per_minute',
      limit: 6,
      window: Duration(minutes: 1),
      note: 'Each access token may start at most 6 uploads per minute.',
      appliesToTier: PlatformTier.byokApi,
    ),
    // TikTok also limits pending inbox drafts (about 5 per 24 h), but that
    // only applies to upload-to-inbox, not direct posts, so it is not tracked
    // locally; the API's spam_risk_too_many_pending_share maps to quota.
  ],
  personalAccountOk: true,
  accountRequirements: 'Hand-off works with any TikTok account: NEFORUM opens TikTok with your video and copies the caption. '
      '"Your own API keys" needs your own TikTok developer app, and UNTIL TIKTOK AUDITS THAT APP EVERY POST IS PRIVATE '
      '("Only me") and your TikTok account itself must be set to private.',
  apiCostSummary: 'Free: TikTok sells no API plan. But an unaudited app (which is what you get) can only post PRIVATE videos '
      'that nobody else sees, and TikTok allows roughly 15 API posts per account per day.',
  setupGuide: 'docs/platforms/tiktok.md',
  serverSideScheduling: false,
  supportsLinkField: false,
);

const _byokIntro = '''
**Heads-up: with your own TikTok app, posts are PRIVATE.** TikTok forces every post made by an *unaudited* app to "Only me", and the TikTok account must itself be set to private. Public posting needs TikTok's Content Posting audit, which individual apps rarely pass. If you want public posts, use the Hand-off tier instead.

1. Sign in at [developers.tiktok.com](https://developers.tiktok.com/apps) and create an app (**Manage apps > Connect an app**).
2. Add the products **Login Kit** and **Content Posting API** (turn on **Direct Post**).
3. Unreviewed apps cannot sign anyone in, so open **Sandbox**, create a sandbox and under **Target users** add your own TikTok account (it can take up to an hour to show up).
4. In the sandbox's **Login Kit** settings choose **Desktop** and add this redirect URI exactly: `http://127.0.0.1:52771/callback`
5. Tick the scopes **user.info.basic**, **video.publish** and **video.upload**.
6. Copy the sandbox's **Client key** and **Client secret** into the fields below, then click Connect and approve in the browser.

TikTok does not accept `neforum://` redirects, so connect this account from NEFORUM on Windows or macOS.
''';

/// Connect specs: hand-off (no setup) and BYOK Content Posting API.
const tiktokConnectSpecs = <ConnectSpec>[
  ConnectSpec(
    tier: PlatformTier.handoff,
    intro: 'Nothing to set up. When you publish, NEFORUM copies your caption and opens TikTok (app share sheet on '
        'phones, TikTok Studio upload page on desktop) with your video attached. You paste the caption and tap Post.',
    fields: [
      ConnectField(
        key: 'display_name',
        label: 'Name for this account',
        required: false,
        placeholder: 'My TikTok',
        help: 'Only shown inside NEFORUM.',
      ),
    ],
    loopbackRedirectOk: false,
    customSchemeRedirectOk: false,
  ),
  ConnectSpec(
    tier: PlatformTier.byokApi,
    usesBrowser: true,
    intro: _byokIntro,
    redirectNote: 'Register http://127.0.0.1:52771/callback under Login Kit > Desktop (TikTok rejects custom schemes).',
    loopbackRedirectOk: true,
    customSchemeRedirectOk: false,
    fields: [
      ConnectField(
        key: 'client_key',
        label: 'Client key',
        placeholder: 'aw1b2c3d4e5f6g7h',
        help: 'From your TikTok app (use the sandbox credentials until the app is approved).',
      ),
      ConnectField(
        key: 'client_secret',
        label: 'Client secret',
        kind: FieldKind.password,
        secret: true,
        help: 'Shown next to the client key. Stored only in this device\'s secure storage.',
      ),
    ],
  ),
];
