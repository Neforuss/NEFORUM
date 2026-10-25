import 'dart:async';

import 'package:http/http.dart' as http;

import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../model/account.dart';
import '../../model/artwork.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../mastodon/mastodon_adapter.dart';
import '../mastodon/mastodon_api.dart';
import '../mastodon/mastodon_instance.dart';
import 'art_api_common.dart';

/// Pixelfed's own defaults (config/pixelfed.php), used until the server
/// reports its limits.
abstract final class PixelfedDefaults {
  static const int maxCaption = 500;
  static const int maxPhotos = 4;
  static const int imageMaxBytes = 15000 * 1024;
  static const Set<String> mimeTypes = {'image/jpeg', 'image/png', 'image/gif'};
  static const int postsPerDay = 1000;
}

/// The descriptor with server [p]'s own limits applied.
PlatformDescriptor pixelfedDescriptorFor(MastodonInstanceProfile p) {
  final videoTypes = p.videoMimeTypes ?? const <String>{};
  return PlatformDescriptor(
    id: 'pixelfed',
    name: 'Pixelfed',
    iconKey: 'pixelfed',
    homepage: 'https://pixelfed.org',
    family: 'mastodon-api',
    tiers: const {PlatformTier.openApi, PlatformTier.handoff},
    defaultTier: PlatformTier.openApi,
    categories: const {PlatformCategory.art},
    text: TextRules(
      maxLength: p.maxCharacters ?? PixelfedDefaults.maxCaption,
      // Pixelfed counts characters (code points); UTF-16 units are never
      // fewer, so an over-long caption never gets through.
      counting: CountingRule.utf16,
      titleSupported: true,
      supportsContentWarning: true,
      notes: 'One caption: NEFORUM puts the title on its first line, then the description, then the tags as hashtags. '
          'Each server sets its own caption length (500 by default, 2,000 on pixelfed.social).',
    ),
    media: MediaRules(
      maxImages: p.maxMediaAttachments ?? PixelfedDefaults.maxPhotos,
      maxVideos: videoTypes.isEmpty ? 0 : 1,
      requiresMedia: true,
      imageMaxBytes: p.imageSizeLimit ?? PixelfedDefaults.imageMaxBytes,
      videoMaxBytes: p.videoSizeLimit,
      imageMimeTypes: p.imageMimeTypes ?? PixelfedDefaults.mimeTypes,
      videoMimeTypes: videoTypes,
      supportsAltText: true,
      notes: 'Every post needs an image, or a video on servers that take video. Each server sets its own limits (by '
          'default 4 photos of up to 15,000 KB as JPEG, PNG or GIF; pixelfed.social takes 20 files of 15 MB, including '
          'WebP and MP4).',
    ),
    defaultQuotas: const [
      QuotaRule(
        id: 'pixelfed.posts_per_day',
        limit: PixelfedDefaults.postsPerDay,
        window: Duration(days: 1),
        note: 'Pixelfed caps posts at 1000 per day.',
        appliesToTier: PlatformTier.openApi,
      ),
    ],
    accountRequirements: 'Any account on a Pixelfed server. You only type your server address and approve NEFORUM in '
        'the browser.',
    apiCostSummary: 'Free on every server, with no developer account or app review.',
    setupGuide: 'docs/platforms/pixelfed.md',
  );
}

/// The static descriptor (Pixelfed's own defaults).
final PlatformDescriptor pixelfedDescriptor = pixelfedDescriptorFor(
  const MastodonInstanceProfile(baseUrl: '', domain: '', software: MastodonSoftware.pixelfed),
);

const _instanceField = ConnectField(
  key: 'instance',
  label: 'Server address',
  kind: FieldKind.url,
  placeholder: 'pixelfed.social',
  help: 'The Pixelfed server your account lives on, e.g. `pixelfed.social`. You can also paste your full handle '
      '(`@you@pixelfed.social`).',
);

/// Connect forms: OAuth (open API) and hand-off.
const pixelfedConnectSpecs = [
  ConnectSpec(
    tier: PlatformTier.openApi,
    usesBrowser: true,
    intro: '**No developer account needed.** Type the address of your Pixelfed server and press Connect. NEFORUM '
        'registers itself on that server as an app called "NEFORUM", opens your browser, and you approve it there '
        '(sign in first if asked).\n\n'
        'NEFORUM asks for `read write`, the permission Pixelfed accepts, and uses it only to publish your posts.',
    redirectNote: 'Registered automatically: http://127.0.0.1:52771/callback on Windows and Linux, neforum://callback '
        'on Android, iOS and macOS. If you enter your own client ID, register that same address in the app you '
        'created on your server.',
    loopbackRedirectOk: true,
    customSchemeRedirectOk: true,
    fields: [
      _instanceField,
      ConnectField(
        key: 'client_id',
        label: 'Client ID (advanced, optional)',
        required: false,
        help: 'Only needed if your server does not let apps register themselves. Create an app on your server with '
            'the scopes `read write` and the redirect URI shown above, then paste its client ID here.',
      ),
      ConnectField(
        key: 'client_secret',
        label: 'Client secret (advanced, optional)',
        kind: FieldKind.password,
        required: false,
        secret: true,
        help: 'The client secret of the app you created yourself. Leave empty to let NEFORUM register itself.',
      ),
    ],
  ),
  ConnectSpec(
    tier: PlatformTier.handoff,
    intro: 'NEFORUM will not sign in. When you publish, it opens your server\'s **Create New Post** page and puts your '
        'caption on the clipboard; on a phone it shares your images to the app you pick. You press **Post** yourself.',
    fields: [
      _instanceField,
      ConnectField(
        key: 'handle',
        label: 'Your handle (optional)',
        required: false,
        placeholder: '@you@pixelfed.social',
        help: 'Only used as a label in NEFORUM.',
      ),
    ],
  ),
];

/// Pixelfed, the federated photo and art network, through its
/// Mastodon-compatible API: the Mastodon adapter's registration, sign-in,
/// upload and posting, with Pixelfed's own descriptor and the artwork rules.
///
/// Pixelfed has no title or rating fields: the title becomes the caption's
/// first line, and mature or adult work is marked sensitive.
class PixelfedAdapter extends MastodonAdapter {
  PixelfedAdapter({super.mediaPollInterval, super.maxMediaPolls, super.clock});

  @override
  PlatformDescriptor get descriptor => pixelfedDescriptor;

  @override
  List<ConnectSpec> get connectSpecs => pixelfedConnectSpecs;

  @override
  PlatformDescriptor descriptorFor(MastodonInstanceProfile p) => pixelfedDescriptorFor(p);

  /// Refuses servers that run other software (they belong under Mastodon),
  /// then connects as the Mastodon adapter does.
  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    final Uri base;
    try {
      base = MastodonInstanceProfile.normalizeInstance(input['instance'] ?? '');
    } on FormatException catch (e) {
      throw ConnectException(e.message, field: 'instance');
    }
    final software = await _softwareOf(base, ctx);
    if (software != null && !software.isPixelfed) {
      throw ConnectException(
        '${base.host} runs ${software.softwareLabel}, not Pixelfed. Add it as a Mastodon account instead.',
        field: 'instance',
      );
    }
    return super.connect(tier, input, ctx);
  }

  /// The server's software, or null when it cannot be told (the Mastodon
  /// connect then reports why).
  static Future<MastodonInstanceProfile?> _softwareOf(Uri base, AdapterContext ctx) async {
    try {
      final api = MastodonApi(ctx, base);
      final profile = await api.fetchInstance();
      if (profile == null) return null;
      final sw = await api.fetchNodeInfoSoftware();
      return sw == null ? profile : profile.withSoftware(sw.$1, sw.$2);
    } on HttpFailure {
      return null;
    } on TimeoutException {
      return null;
    } on http.ClientException {
      return null;
    }
  }

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) => super.validate(captionVariant(variant), account)
    // The Mastodon share page notes do not apply: Pixelfed's hand-off opens
    // its own composer.
    ..removeWhere((i) => i.code == 'media.required' || i.code == 'handoff.no_share_page' || i.code == 'handoff.media')
    // The server's own limits say whether a video can be the work.
    ..addAll(artworkIssues(variant, descriptorForAccount(account)));

  @override
  Future<PublishResult> publish(
    PostVariant variant,
    ConnectedAccount account,
    Map<String, String> secrets,
    AdapterContext ctx,
  ) async {
    if (account.tier != PlatformTier.handoff) {
      final rejection = artworkRejection(artworkIssues(variant, descriptorForAccount(account)));
      if (rejection != null) return PublishResult.failure(rejection);
    }
    return super.publish(captionVariant(variant), account, secrets, ctx);
  }

  /// [v] as Pixelfed takes it: the title on the caption's first line (unless
  /// the text already starts with it) and mature or adult work marked
  /// sensitive.
  static PostVariant captionVariant(PostVariant v) {
    final title = (v.title ?? '').trim();
    final text = v.text.trim();
    final caption = title.isEmpty || text.startsWith(title) ? v.text : (text.isEmpty ? title : '$title\n\n${v.text}');
    final rated = v.artwork != null && v.artwork!.maturity != ArtworkMaturity.general;
    return v.copyWith(text: caption, sensitive: v.sensitive || rated);
  }

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final p = account == null ? null : MastodonInstanceProfile.fromConfig(account.config);
    final hasServer = p != null && p.baseUrl.isNotEmpty;
    final caption = captionVariant(variant).text.trim();
    final files = variant.media.length;
    final where = hasServer ? p.domain : 'your Pixelfed server';
    final rated = captionVariant(variant).sensitive;
    final cw = variant.contentWarning?.trim() ?? '';
    // A video is the work on servers that take video (see [validate]).
    final noun = variant.media.any((m) => m.isVideo) ? 'files' : 'images';
    final steps = [
      'The **Create New Post** page on $where opens (sign in if asked).',
      if (files == 0)
        'Pixelfed needs an image: add one in NEFORUM first, or pick it there.'
      else
        'Add your ${files == 1 ? (variant.media.single.isVideo ? 'video' : 'image') : '$files $noun'}: click **Save '
            'media to Downloads** here, then pick ${files == 1 ? 'it' : 'them'} in the file picker. On a phone, share '
            '${files == 1 ? 'it' : 'them'} to your Pixelfed app instead.',
      if (caption.isNotEmpty) 'Paste the caption (it is on the clipboard).',
      if (rated) 'Turn on **Sensitive** (contains NSFW content).',
      if (cw.isNotEmpty) 'Add the content warning "$cw".',
      'Press **Post**.',
    ];
    return HandoffPlan(
      platformId: id,
      preferred: files > 0 ? HandoffMethod.shareSheet : HandoffMethod.manual,
      clipboardText: caption.isEmpty ? null : caption,
      shareText: caption.isEmpty ? null : caption,
      shareFiles: variant.media,
      desktopUrl: hasServer ? p.endpoint('/i/compose').toString() : 'https://pixelfed.org',
      instructions: [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n'),
      mediaNote: files == 0
          ? null
          : 'On a phone the $noun go through the share sheet to your Pixelfed app. On a computer, add them on the '
              'Create New Post page; the caption is on the clipboard.',
    );
  }
}
