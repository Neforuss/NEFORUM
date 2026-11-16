import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../auth/jwt.dart';
import '../../auth/oauth2_pkce.dart';
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
import '../platform_adapter.dart';
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
        'the browser, or paste a personal access token from your server\'s settings.',
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

/// The connect form's personal access token field. A token here replaces the
/// browser sign-in.
const String pixelfedTokenField = 'access_token';

/// The connect form's field for the token's end date (`YYYY-MM-DD`).
const String pixelfedTokenEndField = 'token_end_date';

/// Connect forms: OAuth or a personal access token (open API), and hand-off.
const pixelfedConnectSpecs = [
  ConnectSpec(
    tier: PlatformTier.openApi,
    usesBrowser: true,
    intro: '**No developer account needed.** Type the address of your Pixelfed server and press Connect. NEFORUM '
        'registers itself on that server as an app called "NEFORUM", opens your browser, and you approve it there '
        '(sign in first if asked).\n\n'
        'NEFORUM asks for `read write`, the permission Pixelfed accepts, and uses it only to publish your posts.\n\n'
        '**Or paste a personal access token** instead of using the browser: on your server open **Settings > '
        'Applications > Personal Access Tokens**, create one with `read` and `write`, and paste it below.',
    redirectNote: 'Registered automatically: http://127.0.0.1:52771/callback on Windows and Linux, neforum://callback '
        'on Android, iOS and macOS. If you enter your own client ID, register that same address in the app you '
        'created on your server.',
    loopbackRedirectOk: true,
    customSchemeRedirectOk: true,
    fields: [
      _instanceField,
      ConnectField(
        key: pixelfedTokenField,
        label: 'Personal access token (optional)',
        kind: FieldKind.password,
        required: false,
        secret: true,
        help: 'Leave empty to sign in through the browser. Or create one on your server under Settings > '
            'Applications > Personal Access Tokens with the scopes `read` and `write`, and paste it here.',
      ),
      ConnectField(
        key: pixelfedTokenEndField,
        label: 'Token end date (optional)',
        required: false,
        placeholder: 'YYYY-MM-DD',
        help: 'Only with a personal access token. Leave empty and NEFORUM reads the date from the token, or counts '
            'one year from today (how long Pixelfed tokens last). NEFORUM warns you two weeks before it ends.',
      ),
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
  SignInPolicy signInPolicyFor(ConnectedAccount account) => SignInPolicies.pixelfed(account);

  /// Laravel Passport revokes a refresh token once it is used
  /// (`$revokeRefreshTokenAfterUse = true`), so two devices can end each
  /// other's sign-in. A personal access token has no refresh token.
  @override
  bool rotatesRefreshTokensFor(ConnectedAccount account) => account.tier != PlatformTier.handoff && !usesPersonalToken(account);

  /// [account] signed in with a pasted personal access token, not the browser.
  static bool usesPersonalToken(ConnectedAccount account) => account.config['authMethod'] == 'token';

  /// How long before the access token ends a post renews it. On defaults the
  /// refresh token outlives the access token by only 35 days, so renewing only
  /// once the access token is dead left just days 365 to 400 to post in.
  static const Duration earlyRenewal = Duration(days: 30);

  /// Any post within [earlyRenewal] of the access token's end, once it can be
  /// renewed.
  @override
  bool renewsEarly(ConnectedAccount account, Map<String, String> secrets, DateTime now) {
    if (account.tier == PlatformTier.handoff) return false;
    final tokens = OAuthTokens.fromSecrets(secrets);
    return tokens != null &&
        !tokens.isExpired(now: now) &&
        tokens.isExpired(now: now, leeway: earlyRenewal) &&
        (tokens.refreshToken ?? '').isNotEmpty &&
        (secrets['client_id'] ?? '').isNotEmpty;
  }

  /// As the Mastodon adapter, and also early ([renewsEarly]). A renewal that
  /// could not run leaves the token posting. A refusal goes up, because the old
  /// token may be dead too: another device may have spent this refresh token,
  /// which the coordinator can find out. Where nothing explains it, the publish
  /// service posts on the token.
  ///
  /// A personal access token cannot be renewed. Once the token's own date
  /// (its JWT `exp`) has passed, the person has to make a new one; a date they
  /// typed or NEFORUM counted is not proof enough to stop a post, so the
  /// server answers then.
  @override
  Future<Map<String, String>?> refreshSecrets(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier == PlatformTier.handoff) return null;
    if (usesPersonalToken(account)) {
      final token = OAuthTokens.fromSecrets(secrets)?.accessToken;
      if (token == null || token.isEmpty) {
        throw const AdapterException(PublishError.auth('No access token stored for this account. Reconnect it.'));
      }
      final end = jwtExpiry(token);
      if (end != null && !ctx.now().isBefore(end)) {
        throw AdapterException(PublishError.auth(personalTokenEndedMessage(account.configString('domain', 'your server'))));
      }
      return null;
    }
    if (!renewsEarly(account, secrets, ctx.now())) return super.refreshSecrets(account, secrets, ctx);
    try {
      return await renewToken(account, secrets, OAuthTokens.fromSecrets(secrets)!, ctx);
    } on AdapterException catch (e) {
      if (e.error.kind == PublishErrorKind.auth) rethrow;
      ctx.log.warn('The early Pixelfed renewal failed; the current token still works: ${e.error.kind.name}');
      return null;
    } on Exception catch (e) {
      ctx.log.warn('The early Pixelfed renewal failed; the current token still works (${e.runtimeType})');
      return null;
    }
  }

  @override
  PlatformDescriptor get descriptor => pixelfedDescriptor;

  @override
  List<ConnectSpec> get connectSpecs => pixelfedConnectSpecs;

  @override
  PlatformDescriptor descriptorFor(MastodonInstanceProfile p) => pixelfedDescriptorFor(p);

  /// Refuses servers that run other software (they belong under Mastodon),
  /// then connects as the Mastodon adapter does, or with the personal access
  /// token the person pasted.
  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    final Uri base;
    try {
      base = MastodonInstanceProfile.normalizeInstance(input['instance'] ?? '');
    } on FormatException catch (e) {
      throw ConnectException(e.message, field: 'instance');
    }
    final token = personalToken(input[pixelfedTokenField] ?? '');
    if (tier == PlatformTier.openApi && token.isNotEmpty) {
      return _connectPersonalToken(base, token, input[pixelfedTokenEndField] ?? '', ctx);
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

  /// What the person pasted, without the spaces and a `Bearer ` prefix copied
  /// along with it.
  static String personalToken(String raw) => raw.trim().replaceFirst(RegExp(r'^bearer\s+', caseSensitive: false), '').trim();

  /// What a post says once a personal access token has ended.
  static String personalTokenEndedMessage(String host) =>
      'Your Pixelfed personal access token has ended. Create a new one on $host under Settings > Applications > '
      'Personal Access Tokens (read and write), then reconnect the account with it.';

  /// The end date typed into the connect form: `YYYY-MM-DD` (the start of that
  /// day, UTC, so NEFORUM never warns late) or a full ISO 8601 date. Null when
  /// left empty. Throws [ConnectException] for anything else, and for a date
  /// that has passed at [now].
  static DateTime? parseTokenEndDate(String raw, {required DateTime now}) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    DateTime? end;
    final day = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);
    if (day != null) {
      final y = int.parse(day.group(1)!), m = int.parse(day.group(2)!), d = int.parse(day.group(3)!);
      final t = DateTime.utc(y, m, d);
      // DateTime rolls 2027-02-30 over to March: refuse it instead.
      if (t.year == y && t.month == m && t.day == d) end = t;
    } else if (s.contains('T')) {
      end = DateTime.tryParse(s)?.toUtc();
    }
    if (end == null) {
      throw const ConnectException('Enter the token\'s end date as YYYY-MM-DD, for example 2027-11-16, or leave it empty.',
          field: pixelfedTokenEndField);
    }
    if (!now.isBefore(end)) {
      throw const ConnectException('That end date has passed, so the token no longer works. Create a new one.',
          field: pixelfedTokenEndField);
    }
    return end;
  }

  /// When a personal access token ends, and where that date came from: the
  /// earlier of the date the person typed and the token's own `exp` (a
  /// Pixelfed token is a JWT), so NEFORUM never warns late. With neither, one
  /// year from [now]: Passport's default life for these tokens.
  static (DateTime, SignInDateSource) personalTokenEnd(String token, DateTime? entered, {required DateTime now}) {
    final own = jwtSignInEnd(token, now: now);
    if (entered != null && (own == null || entered.isBefore(own))) return (entered, SignInDateSource.userEntered);
    if (own != null) return (own, SignInDateSource.serverReported);
    return (now.toUtc().add(SignInPolicies.pixelfedPersonalTokenLife), SignInDateSource.computed);
  }

  /// Connects with a pasted personal access token: checks the server is
  /// Pixelfed, checks the token with `GET /api/v1/accounts/verify_credentials`,
  /// and stores it with its end date. No app is registered and no browser
  /// opens.
  Future<ConnectResult> _connectPersonalToken(Uri base, String token, String endInput, AdapterContext ctx) async {
    final now = ctx.now();
    final entered = parseTokenEndDate(endInput, now: now);
    try {
      ctx.progress('Looking up ${base.host}');
      final api = MastodonApi(ctx, base);
      final found = await api.fetchInstance();
      if (found == null) {
        throw ConnectException('${base.host} does not look like a Pixelfed server (no /api/v1/instance).', field: 'instance');
      }
      final sw = await api.fetchNodeInfoSoftware();
      final p = sw == null ? found : found.withSoftware(sw.$1, sw.$2);
      if (!p.isPixelfed) {
        throw ConnectException('${base.host} runs ${p.softwareLabel}, not Pixelfed. Add it as a Mastodon account instead.',
            field: 'instance');
      }
      ctx.progress('Checking your token');
      final Map<String, dynamic> me;
      try {
        me = await MastodonApi(ctx, p.base, accessToken: token).verifyCredentials();
      } on HttpFailure catch (e) {
        throw switch (e.statusCode) {
          401 => ConnectException(
              '${p.domain} did not accept this token (HTTP 401). Check that you copied all of it, and that it was not '
              'revoked and has not ended. If it has, create a new one under Settings > Applications > Personal '
              'Access Tokens.',
              field: pixelfedTokenField),
          403 => ConnectException(
              '${p.domain} refused to show your profile with this token (HTTP 403). Create a token with the scopes '
              '`read` and `write`.',
              field: pixelfedTokenField),
          _ => e,
        };
      }
      final username = (me['username'] as String?) ?? (me['acct'] as String?) ?? 'unknown';
      final display = (me['display_name'] as String?)?.trim();
      final (end, source) = personalTokenEnd(token, entered, now: now);
      return ConnectResult(
        account: ConnectedAccount(
          id: const Uuid().v4(),
          platformId: id,
          tier: PlatformTier.openApi,
          displayName: '${display == null || display.isEmpty ? username : display} (${p.domain})',
          handle: '@$username@${p.domain}',
          avatarUrl: me['avatar'] as String?,
          profileUrl: me['url'] as String?,
          createdAt: now,
          config: {
            ...p.toConfig(),
            'remoteAccountId': '${me['id']}',
            'authMethod': 'token',
          },
        ),
        secrets: OAuthTokens(accessToken: token, tokenType: 'Bearer', expiresAt: end)
            .toSecrets({SignInSecretKeys.expiresAtSource: source.name}),
      );
    } on HttpFailure catch (e) {
      throw ConnectException(MastodonApi.mapFailure(e, now: now, context: 'Connecting to ${base.host}').message);
    } on TimeoutException {
      throw ConnectException('${base.host} did not answer in time. Check the address and your connection.', field: 'instance');
    } on http.ClientException catch (e) {
      throw ConnectException('Could not reach ${base.host}: ${e.message}', field: 'instance');
    }
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
