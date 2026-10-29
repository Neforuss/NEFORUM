import '../../model/platform_descriptor.dart';
import '../connect_spec.dart';

/// Video MIME types YouTube accepts for upload. The API takes `video/*`
/// (or `application/octet-stream`); these are the containers YouTube lists.
const youtubeVideoMimeTypes = {
  'video/mp4',
  'video/quicktime',
  'video/webm',
  'video/x-msvideo',
  'video/x-ms-wmv',
  'video/x-flv',
  'video/3gpp',
  'video/mpeg',
  'video/x-matroska',
};

/// Static description of YouTube (YouTube Data API v3 `videos` resource
/// and `videos.insert` reference, quota page last updated 2026-10-08).
const youtubeDescriptor = PlatformDescriptor(
  id: 'youtube',
  name: 'YouTube',
  iconKey: 'youtube',
  homepage: 'https://www.youtube.com',
  tiers: {PlatformTier.byokApi, PlatformTier.handoff},
  defaultTier: PlatformTier.byokApi,
  text: TextRules(
    // The post text is the video description: "maximum length of 5000
    // bytes", no '<' or '>'.
    maxLength: 5000,
    counting: CountingRule.utf8Bytes,
    // snippet.title: "maximum length of 100 characters", required.
    titleMax: 100,
    titleRequired: true,
    titleSupported: true,
    supportsThreads: false,
    supportsContentWarning: false,
    supportsHashtags: true,
    // snippet.tags: all tags together max 500 characters (checked in
    // validate(); there is no count limit).
    hashtagsAsField: true,
    linkInText: true,
    notes: 'Title max 100 characters, description max 5000 bytes (UTF-8); neither may contain < or >. '
        'Tags go into the tags field: all tags together max 500 characters, counting the commas between them '
        'and two quote marks for every tag that contains a space.',
  ),
  media: MediaRules(
    // Sound goes as a video of one still picture, made by the app.
    audioAsVideo: true,
    maxImages: 0,
    maxVideos: 1,
    requiresMedia: true,
    allowsMixedImageVideo: false,
    // "Maximum file size: 256GB"; channels allow up to 12 hours.
    videoMaxBytes: 256 * 1024 * 1024 * 1024,
    videoMaxSeconds: 12 * 60 * 60,
    imageMimeTypes: {},
    videoMimeTypes: youtubeVideoMimeTypes,
    supportsAltText: false,
    requiresPublicMediaUrl: false,
    notes: 'Exactly one video per post (up to 12 hours / 256 GB; channels that are not phone-verified are limited '
        'to 15 minutes). Vertical or square clips of 3 minutes or less automatically become Shorts.',
  ),
  defaultQuotas: [
    QuotaRule(
      id: 'youtube.uploads_per_day',
      limit: 100,
      window: Duration(days: 1),
      note: '100 videos.insert calls/day per Google Cloud project (own bucket since 2026-06-01; '
          'other calls share 10,000 units/day). Resets at midnight Pacific.',
      appliesToTier: PlatformTier.byokApi,
    ),
  ],
  personalAccountOk: true,
  accountRequirements: 'A Google account with a YouTube channel. "Your own API keys" also needs a free Google Cloud '
      'project with an OAuth client that you create yourself (about 10 minutes); hand-off only needs the YouTube app '
      'or website.',
  apiCostSummary: 'Free: Google gives every project 100 uploads a day and sells no paid plan. Uploads from a project '
      'Google has not audited (yours) may be locked to PRIVATE by YouTube; if that happens, use hand-off for public videos.',
  setupGuide: 'docs/platforms/youtube.md',
  serverSideScheduling: true,
  supportsLinkField: false,
);

/// The loopback redirect the desktop broker listens on.
const youtubeLoopbackRedirect = 'http://127.0.0.1:52771/callback';

const _byokIntro = '''
**Heads-up: YouTube may make these uploads PRIVATE.** YouTube's help pages say videos uploaded through an API project that Google has not audited are locked as private (no appeal; you would re-upload them in YouTube). Your own project is unaudited. Google's API reference changed its wording on 2026-10-08, so NEFORUM checks what YouTube reports after each upload and warns you. For guaranteed public videos, use the Hand-off tier.

1. Open [console.cloud.google.com/projectcreate](https://console.cloud.google.com/projectcreate) and create a project (any name, e.g. "NEFORUM for me").
2. Enable **YouTube Data API v3**: [APIs & Services > Library > YouTube Data API v3](https://console.cloud.google.com/apis/library/youtube.googleapis.com) > **Enable**.
3. Open **Google Auth Platform** (formerly "OAuth consent screen"): [console.cloud.google.com/auth/overview](https://console.cloud.google.com/auth/overview) > **Get started**. Enter an app name and your e-mail, choose **External**, finish.
4. Under **Audience**, click **Publish app** so it is *In production*. (In *Testing* mode Google signs you out every 7 days; if you stay in Testing, add your own Google address as a test user.)
5. Under **Data Access** > **Add or remove scopes**, add `https://www.googleapis.com/auth/youtube.upload`, `https://www.googleapis.com/auth/youtube.readonly` and `https://www.googleapis.com/auth/youtube.force-ssl`, then **Save**. (The last one lets NEFORUM delete a video YouTube is holding for a scheduled post when you edit or cancel that post.)
6. Under **Clients** > **Create client**, pick Application type **Desktop app**. Desktop clients need no redirect URI: NEFORUM signs in through `$youtubeLoopbackRedirect` automatically.
7. Copy the **Client ID** and **Client secret** into the fields below and click Connect.
8. Google will warn "Google hasn't verified this app". That is your own app: click **Advanced** > **Go to (your app name)**, then tick **every** YouTube box. Without the "manage your videos" box, scheduled posts stay on this device and are uploaded at their time.

Google only accepts `http://127.0.0.1` sign-ins for this kind of client (not `neforum://`), so connect from NEFORUM on Windows or macOS.
''';

/// Connect specs: BYOK YouTube Data API, and hand-off (no setup).
const youtubeConnectSpecs = <ConnectSpec>[
  ConnectSpec(
    tier: PlatformTier.byokApi,
    usesBrowser: true,
    intro: _byokIntro,
    redirectNote: 'Create a "Desktop app" OAuth client; it accepts $youtubeLoopbackRedirect without registration. '
        'Google rejects neforum:// (custom schemes must contain a dot and belong to an iOS/Android client).',
    loopbackRedirectOk: true,
    customSchemeRedirectOk: false,
    fields: [
      ConnectField(
        key: 'client_id',
        label: 'Client ID',
        placeholder: '1234567890-abc123.apps.googleusercontent.com',
        help: 'From Google Auth Platform > Clients (type "Desktop app").',
      ),
      ConnectField(
        key: 'client_secret',
        label: 'Client secret',
        kind: FieldKind.password,
        required: false,
        secret: true,
        help: 'Shown when you create the Desktop app client (or under the client\'s details). '
            'Stored only in this device\'s secure storage.',
      ),
    ],
  ),
  ConnectSpec(
    tier: PlatformTier.handoff,
    intro: 'Nothing to set up. When you publish, NEFORUM copies your title and description to the clipboard and '
        'hands the video to the YouTube app (phones) or opens the YouTube upload page (desktop). You paste the text, '
        'choose the visibility and tap Publish.',
    fields: [
      ConnectField(
        key: 'display_name',
        label: 'Name for this account',
        required: false,
        placeholder: 'My channel',
        help: 'Only shown inside NEFORUM.',
      ),
    ],
    loopbackRedirectOk: false,
    customSchemeRedirectOk: false,
  ),
];
