import '../../model/platform_descriptor.dart';
import '../connect_spec.dart';
import 'mastodon_instance.dart';

const _defaultMaxChars = 500;
const _defaultUrlWeight = 23;

const _text = TextRules(
  maxLength: _defaultMaxChars,
  counting: CountingRule.codePointsWithUrlWeight,
  urlWeight: _defaultUrlWeight,
  mentionCountsDomain: false,
  supportsThreads: true,
  supportsContentWarning: true,
  supportsHashtags: true,
  linkInText: true,
  notes:
      '500 is the vanilla Mastodon default; each server reports its own limit (GoToSocial, Akkoma and '
      'Mitra usually allow 5000). Every link counts as 23 characters, mentions count without their domain, '
      'and the content warning counts toward the same limit.',
);

const _media = MediaRules(
  maxImages: 4,
  maxVideos: 1,
  allowsMixedImageVideo: false,
  imageMaxBytes: 16777216,
  videoMaxBytes: 103809024,
  imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif', 'image/webp'},
  videoMimeTypes: {'video/mp4', 'video/webm', 'video/quicktime', 'video/ogg'},
  supportsAltText: true,
  notes:
      'Up to 4 images (16 MB each) or 1 video (99 MB) on vanilla Mastodon; images and video cannot be mixed. '
      'Each server reports its own limits (GoToSocial: 6 files, 40 MB). Pixelfed requires at least one image.',
);

/// The static descriptor (vanilla Mastodon defaults).
const mastodonDescriptor = PlatformDescriptor(
  id: 'mastodon',
  name: 'Mastodon',
  iconKey: 'mastodon',
  homepage: 'https://joinmastodon.org',
  family: 'mastodon-api',
  tiers: {PlatformTier.openApi, PlatformTier.handoff},
  defaultTier: PlatformTier.openApi,
  text: _text,
  media: _media,
  defaultQuotas: [
    QuotaRule(
      id: 'mastodon.requests_per_5min',
      limit: 300,
      window: Duration(minutes: 5),
      note:
          'Mastodon allows 300 API calls per account every 5 minutes; each post uses one call plus one per media file.',
      appliesToTier: PlatformTier.openApi,
    ),
    QuotaRule(
      id: 'mastodon.posts_per_day',
      limit: 1000,
      window: Duration(days: 1),
      note: 'Pixelfed caps posts at 1000 per day; vanilla Mastodon has no daily post cap.',
      appliesToTier: PlatformTier.openApi,
    ),
  ],
  personalAccountOk: true,
  accountRequirements:
      'Any normal account on a Mastodon-compatible server (Mastodon, Pleroma, Akkoma, GoToSocial, '
      'Friendica, Pixelfed, Mitra). You only type your server address and approve NEFORUM in the browser.',
  apiCostSummary:
      'Free on every server, with no developer account or app review. Mastodon allows about 300 API calls '
      'per 5 minutes, 30 media uploads per 30 minutes and 25 scheduled posts per day.',
  setupGuide: 'docs/platforms/mastodon.md',
  serverSideScheduling: true,
  supportsLinkField: false,
);

const _instanceField = ConnectField(
  key: 'instance',
  label: 'Server address',
  kind: FieldKind.url,
  placeholder: 'mastodon.social',
  help:
      'The server your account lives on, e.g. `mastodon.social`, `fosstodon.org` or `pixelfed.social`. '
      'You can also paste your full handle (`@you@mastodon.social`).',
);

/// Connect forms: OAuth (open API) and hand-off.
const mastodonConnectSpecs = [
  ConnectSpec(
    tier: PlatformTier.openApi,
    usesBrowser: true,
    intro:
        '**No developer account needed.** Type the address of your server and press Connect. NEFORUM '
        'registers itself on that server as an app called "NEFORUM", opens your browser, and you approve it '
        'there (sign in first if asked).\n\n'
        'NEFORUM asks only to publish posts and upload media (`write:statuses write:media profile` on '
        'Mastodon; `read write` on Pixelfed, GoToSocial, Pleroma/Akkoma and others).\n\n'
        'Works with Mastodon, Pleroma, Akkoma, GoToSocial, Friendica, Pixelfed and Mitra.',
    redirectNote:
        'Registered automatically: http://127.0.0.1:52771/callback on desktop, neforum://callback on '
        'mobile. If you enter your own client ID, register that same address in the app you created under '
        'Preferences > Development on your server.',
    loopbackRedirectOk: true,
    customSchemeRedirectOk: true,
    fields: [
      _instanceField,
      ConnectField(
        key: 'client_id',
        label: 'Client ID (advanced, optional)',
        required: false,
        help:
            'Only needed if your server blocks automatic app registration. Create an app under '
            'Preferences > Development > New application on your server with the scopes '
            '`write:statuses write:media profile` and the redirect URI shown above, then paste its '
            'Client key here.',
      ),
      ConnectField(
        key: 'client_secret',
        label: 'Client secret (advanced, optional)',
        kind: FieldKind.password,
        required: false,
        secret: true,
        help: 'The "Client secret" of the app you created yourself. Leave empty to let NEFORUM register itself.',
      ),
    ],
  ),
  ConnectSpec(
    tier: PlatformTier.handoff,
    intro:
        'NEFORUM will not sign in. When you publish, it opens your server\'s share page '
        '(`https://your.server/share?text=...`) with the text filled in, or the Mastodon app\'s share sheet '
        'with your images attached, and you press **Publish** yourself.\n\n'
        'The web share page exists only on Mastodon itself; on GoToSocial, Pixelfed and the others NEFORUM '
        'copies the text so you can paste it.',
    fields: [
      _instanceField,
      ConnectField(
        key: 'handle',
        label: 'Your handle (optional)',
        required: false,
        placeholder: '@you@mastodon.social',
        help: 'Only used as a label in NEFORUM.',
      ),
    ],
  ),
];

/// The descriptor with this account's server limits applied.
PlatformDescriptor mastodonDescriptorFor(MastodonInstanceProfile p) {
  final text = TextRules(
    maxLength: p.maxCharacters ?? _defaultMaxChars,
    counting: _text.counting,
    urlWeight: p.charactersReservedPerUrl ?? _defaultUrlWeight,
    mentionCountsDomain: false,
    supportsThreads: true,
    supportsContentWarning: true,
    supportsHashtags: true,
    linkInText: true,
    notes: _text.notes,
  );
  final media = MediaRules(
    maxImages: p.maxMediaAttachments ?? _media.maxImages,
    maxVideos: _media.maxVideos,
    requiresMedia: p.requiresMedia,
    allowsMixedImageVideo: false,
    imageMaxBytes: p.imageSizeLimit ?? _media.imageMaxBytes,
    videoMaxBytes: p.videoSizeLimit ?? _media.videoMaxBytes,
    imageMimeTypes: p.imageMimeTypes ?? _media.imageMimeTypes,
    videoMimeTypes: p.videoMimeTypes ?? (p.isPixelfed ? const <String>{} : _media.videoMimeTypes),
    supportsAltText: true,
    notes: _media.notes,
  );
  return PlatformDescriptor(
    id: mastodonDescriptor.id,
    name: p.isMastodon || p.baseUrl.isEmpty
        ? mastodonDescriptor.name
        : '${mastodonDescriptor.name} (${p.softwareLabel})',
    iconKey: mastodonDescriptor.iconKey,
    homepage: mastodonDescriptor.homepage,
    family: mastodonDescriptor.family,
    tiers: mastodonDescriptor.tiers,
    defaultTier: mastodonDescriptor.defaultTier,
    text: text,
    media: media,
    defaultQuotas: mastodonDescriptor.defaultQuotas,
    personalAccountOk: true,
    accountRequirements: mastodonDescriptor.accountRequirements,
    apiCostSummary: mastodonDescriptor.apiCostSummary,
    setupGuide: mastodonDescriptor.setupGuide,
    serverSideScheduling: p.supportsScheduling,
    supportsLinkField: false,
  );
}
