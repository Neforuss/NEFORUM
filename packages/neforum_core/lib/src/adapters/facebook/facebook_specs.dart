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
**Posts to a Facebook Page you manage** (no app can post to personal profiles or groups). You need your own free Meta app; you are its admin, so no App Review.

1. Open <https://developers.facebook.com/apps/creation/>, pick the use case **Manage everything on your Page** and finish the wizard. If it asks for a business portfolio, **I don't want to connect a business portfolio yet** is fine for posting to your own Page.
2. **Use cases > Manage everything on your Page > Customize**: click **Add** next to `pages_read_engagement` (it is not there by default) and next to `pages_manage_posts` if it shows **Add**. `pages_show_list` and `business_management` are already there.
3. **App settings > Basic**: copy the **App ID** and the **App Secret** (click **Show**) into the fields below.
4. Open <https://developers.facebook.com/tools/explorer/>. Check that **Meta App** shows your app: the Explorer remembers the last app you used. Leave **User or Page** as it is (it may say **Get Token**); don't pick a Page there. Add the four permissions above. If one is missing from the Explorer's list, it isn't added to your app yet: go back to step 2.
5. Click **Generate Access Token**. It makes a User token, which is what NEFORUM needs. In the pop-up, approve the app and pick the Pages to share (picking only the Page you post to is enough). Copy the token into the **User access token** field.
6. Press **Connect**. NEFORUM turns the token into a Page token that does not expire.
7. So that people other than you see the posts, **Publish** the app (left menu). As of October 2026 Meta only requires a privacy policy URL; an app icon and a data deletion URL are optional.

**Browser sign-in (not recommended):** if you leave the token field empty, NEFORUM opens Facebook's sign-in page instead. It returns to `https://www.facebook.com/connect/login_success.html`, and Meta won't let you register that address ("This can't be a Facebook URL"), so it may not work. If Facebook's sign-in page says the URL is blocked, use the token steps above.
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
    redirectNote: 'Only used by browser sign-in, which is not the recommended route; pasting a token (steps 4 and 5) '
        'needs no redirect. Meta won\'t let you register this address (its dashboard answers "This can\'t be a '
        'Facebook URL" in Valid OAuth Redirect URIs and Authorize callback URL), so there is nothing to register. '
        'If Facebook\'s sign-in page says the URL is blocked, paste a token from the Graph API Explorer instead.',
    loopbackRedirectOk: false,
    customSchemeRedirectOk: false,
    fixedRedirectUri: facebookLoginSuccessUri,
    fields: const [
      ConnectField(
        key: 'app_id',
        label: 'App ID',
        placeholder: '1234567890123456',
        help: 'Your app at developers.facebook.com/apps > **App settings > Basic** > App ID (also shown at the top '
            'of the dashboard).',
      ),
      ConnectField(
        key: 'app_secret',
        label: 'App Secret',
        kind: FieldKind.password,
        secret: true,
        help: '**App settings > Basic** > App Secret, click **Show** (Facebook may ask for your password). Needed '
            'for the long-lived token; stays on this device.',
      ),
      ConnectField(
        key: 'user_access_token',
        label: 'User access token from the Graph API Explorer',
        kind: FieldKind.password,
        required: false,
        secret: true,
        help: '**Recommended.** developers.facebook.com/tools/explorer > check that **Meta App** shows your app > '
            'leave **User or Page** as it is > **Generate Access Token** (steps 4 and 5). Leave empty only to try '
            'browser sign-in, which Meta may block.',
      ),
      ConnectField(
        key: 'page',
        label: 'Page name, username, ID or link',
        required: false,
        help: 'Any of these works: the Page\'s name, its username, its ID or its link (for example '
            '`facebook.com/examplebakery`). Leave empty to use the first Page you can post to. To switch Pages, '
            'connect again with another one.',
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
