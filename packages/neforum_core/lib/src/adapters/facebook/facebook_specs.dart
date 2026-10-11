import '../../model/platform_descriptor.dart';
import '../connect_spec.dart';
import 'facebook_api.dart';

/// What NEFORUM knows about Facebook. Numbers come from the Graph API
/// reference pages (read 2026-10-07): 63,206-character message limit, photos
/// up to 10 MB in jpeg/bmp/png/gif/tiff, non-resumable video uploads up to
/// 1 GB and 20 minutes, Pages API budget of 4800 calls x engaged users per
/// rolling 24 hours.
const PlatformDescriptor facebookDescriptor = PlatformDescriptor(
  id: 'facebook',
  name: 'Facebook',
  iconKey: 'facebook',
  homepage: 'https://www.facebook.com',
  tiers: {PlatformTier.byokApi, PlatformTier.handoff},
  defaultTier: PlatformTier.handoff,
  personalAccountOk: false,
  serverSideScheduling: true,
  supportsLinkField: true,
  setupGuide: 'docs/platforms/facebook.md',
  accountRequirements:
      'Automatic posting works only for Facebook Pages you manage, through a free Meta developer app you create '
      'yourself; personal profiles and groups cannot be posted to by any app. For a personal profile, use hand-off: '
      'NEFORUM copies your text and opens Facebook so you can paste and post.',
  apiCostSummary:
      'The Graph API is free. Meta allows about 4,800 calls per day multiplied by the number of people who engaged '
      'with your Page, which is plenty for normal posting; new Pages with no engagement get much less.',
  text: TextRules(
    maxLength: 63206,
    counting: CountingRule.utf16,
    supportsThreads: false,
    supportsContentWarning: false,
    supportsHashtags: true,
    linkInText: true,
    notes: 'Feed shows "See more" after roughly 477 characters. Facebook does not document how the 63,206 limit is '
        'counted; NEFORUM counts UTF-16 code units.',
  ),
  media: MediaRules(
    maxImages: 10,
    maxVideos: 1,
    allowsMixedImageVideo: false,
    imageMaxBytes: 10 * 1024 * 1024,
    videoMaxBytes: 1024 * 1024 * 1024,
    videoMaxSeconds: 20 * 60,
    imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif', 'image/bmp', 'image/tiff'},
    videoMimeTypes: {
      'video/mp4',
      'video/quicktime',
      'video/x-m4v',
      'video/x-matroska',
      'video/x-msvideo',
      'video/x-ms-wmv',
      'video/3gpp',
      'video/x-flv',
      'video/mpeg',
      'video/ogg',
      'video/mp2t',
    },
    supportsAltText: true,
    requiresPublicMediaUrl: false,
    notes: 'Photos are uploaded directly (no media host needed). Keep PNGs under 1 MB to avoid pixelation. '
        'One video per post; videos are not mixed with photos.',
  ),
  defaultQuotas: [
    QuotaRule(
      id: 'facebook.pages_calls_per_day',
      limit: 4800,
      window: Duration(hours: 24),
      note: 'Pages API budget: 4800 calls x engaged users per rolling 24 h (NEFORUM counts posts; a multi-photo '
          'post really uses one call per photo plus one).',
      appliesToTier: PlatformTier.byokApi,
    ),
  ],
);

const String _byokIntro = '''
**Posts to a Facebook Page you manage** (not to a personal profile: Meta has not allowed that since 2018).
You need your own free Meta developer app. You stay its admin, so no App Review is needed.

1. Open <https://developers.facebook.com/apps> and click **Create app**. Pick the use case
   **Manage everything on your Page** (or app type **Business**) and connect your Page's business portfolio if asked.
2. In the use case's **Customize** screen make sure these permissions are added:
   `pages_show_list`, `pages_read_engagement`, `pages_manage_posts`, `business_management`.
3. Open **Facebook Login (for Business) > Settings**: switch on **Client OAuth login**, **Web OAuth login** and
   **Embedded browser OAuth login**, and add this to **Valid OAuth Redirect URIs**:
   `https://www.facebook.com/connect/login_success.html`
4. In **App settings > Basic** copy the **App ID** and **App Secret** (click Show). Fill in a Privacy Policy URL,
   icon and category; if your app has a Development/Live switch, set it to **Live**, otherwise only you can see the posts.
5. Press Connect. Facebook opens: approve and **select your Page(s)**. You end up on a page that says
   "Success": copy the **whole address** from the address bar and paste it into NEFORUM.
''';

const String _handoffIntro = '''
Works for **personal profiles and Pages** without any developer setup. When you publish, NEFORUM copies
your text to the clipboard and opens Facebook (the share sheet with your photos on a phone, the share window
for links, or facebook.com). You paste the text and tap **Post** yourself: Facebook does not let other apps
fill in your text.
''';

/// Connect forms for both tiers.
final List<ConnectSpec> facebookConnectSpecs = [
  ConnectSpec(
    tier: PlatformTier.byokApi,
    usesBrowser: true,
    intro: _byokIntro,
    redirectNote: 'Register exactly https://www.facebook.com/connect/login_success.html as a Valid OAuth Redirect URI. '
        'Facebook Login rejects http://127.0.0.1 and neforum:// redirects.',
    loopbackRedirectOk: false,
    customSchemeRedirectOk: false,
    fixedRedirectUri: facebookLoginSuccessUri,
    fields: const [
      ConnectField(
        key: 'app_id',
        label: 'App ID',
        placeholder: '1234567890123456',
        help: 'Meta app dashboard > App settings > Basic.',
      ),
      ConnectField(
        key: 'app_secret',
        label: 'App Secret',
        kind: FieldKind.password,
        secret: true,
        help: 'App settings > Basic > App Secret (Show). Needed for the long-lived token; stays on this device.',
      ),
      ConnectField(
        key: 'page',
        label: 'Page name or ID',
        required: false,
        help: 'Leave empty to use the first Page you can post to. All your Pages are listed in the account '
            'details after connecting; reconnect with another name to switch Pages.',
      ),
      ConnectField(
        key: 'user_access_token',
        label: 'User access token (optional)',
        kind: FieldKind.password,
        required: false,
        secret: true,
        help: 'Advanced: skip the browser sign-in by pasting a user token for YOUR app from the Graph API Explorer '
            '(https://developers.facebook.com/tools/explorer) with the permissions above.',
      ),
      ConnectField(
        key: 'scopes',
        label: 'Permissions (advanced)',
        required: false,
        defaultValue: 'pages_show_list,pages_read_engagement,pages_manage_posts,business_management',
        help: 'Comma-separated. Remove business_management if Facebook says "Invalid Scopes".',
      ),
    ],
  ),
  const ConnectSpec(
    tier: PlatformTier.handoff,
    intro: _handoffIntro,
    fields: [
      ConnectField(
        key: 'page_url',
        label: 'Your profile or Page address (optional)',
        kind: FieldKind.url,
        required: false,
        placeholder: 'https://www.facebook.com/YourPage',
        help: 'Opened on desktop when there is no link to share.',
      ),
    ],
  ),
];
