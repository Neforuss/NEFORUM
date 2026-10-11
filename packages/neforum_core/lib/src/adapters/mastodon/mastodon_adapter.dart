import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../auth/oauth2_pkce.dart';
import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../http/transient_stub.dart' if (dart.library.io) '../../http/transient_io.dart';
import '../../model/account.dart';
import '../../model/media.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post.dart' show Visibility;
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../../text/rules_validator.dart';
import '../../text/text_counter.dart';
import '../../util/logger.dart' show Clock, systemClock;
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'mastodon_api.dart';
import 'mastodon_descriptor.dart';
import 'mastodon_instance.dart';

/// Mastodon and every server that speaks the Mastodon client API (Pleroma,
/// Akkoma, GoToSocial, Friendica, Pixelfed, Mitra, Iceshrimp.NET, ...).
///
/// Connecting registers NEFORUM as an OAuth app on the user's server at
/// runtime (`POST /api/v1/apps`), so the user never visits a developer
/// portal. The server's real limits are read from `/api/v2/instance` and kept
/// in the account config; [validate] checks posts against them.
class MastodonAdapter extends PlatformAdapter {
  MastodonAdapter({this.mediaPollInterval = const Duration(seconds: 2), this.maxMediaPolls = 90, Clock? clock})
    : _clock = clock ?? systemClock;

  /// How long to wait between `GET /api/v1/media/:id` polls while a video is
  /// being processed.
  final Duration mediaPollInterval;
  final int maxMediaPolls;

  /// "Now" for [validate], which gets no [AdapterContext]. Injectable for
  /// tests; [publish] uses `ctx.now` instead.
  final Clock _clock;

  static const String oob = 'urn:ietf:wg:oauth:2.0:oob';

  /// Granular scopes for Mastodon 4.3+ (`profile` lets verify_credentials
  /// work without read access).
  static const String scopesModern = 'write:statuses write:media profile';

  /// Granular scopes for Mastodon before 4.3, which does not know `profile`.
  static const String scopesLegacy = 'read:accounts write:statuses write:media';

  /// Umbrella scopes for the other servers (Pixelfed checks `write` itself).
  static const String scopesUmbrella = 'read write';

  /// Minimum lead time Mastodon, GoToSocial, Pleroma and Akkoma accept for
  /// `scheduled_at`. Mastodon and GoToSocial answer 422 below it; Pleroma and
  /// Akkoma silently publish the post immediately.
  static const Duration minScheduleLead = Duration(minutes: 5);

  /// Extra lead [validate] asks for on top of [minScheduleLead], to cover
  /// media uploads and a device clock that runs a little behind the server.
  static const Duration scheduleSafetyMargin = Duration(minutes: 1);

  /// Lead still required right before `POST /api/v1/statuses` is sent.
  static const Duration _sendLead = Duration(minutes: 5, seconds: 20);

  @override
  PlatformDescriptor get descriptor => mastodonDescriptor;

  @override
  List<ConnectSpec> get connectSpecs => mastodonConnectSpecs;

  /// The descriptor with this account's server limits applied.
  PlatformDescriptor descriptorFor(MastodonInstanceProfile p) => mastodonDescriptorFor(p);

  @override
  PlatformDescriptor descriptorForAccount(ConnectedAccount account) => descriptorFor(MastodonInstanceProfile.fromConfig(account.config));

  // ---------------------------------------------------------------------------
  // Connect
  // ---------------------------------------------------------------------------

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    final Uri base;
    try {
      base = MastodonInstanceProfile.normalizeInstance(input['instance'] ?? '');
    } on FormatException catch (e) {
      throw ConnectException(e.message, field: 'instance');
    }
    try {
      final profile = await _discover(MastodonApi(ctx, base));
      return tier == PlatformTier.handoff
          ? _connectHandoff(profile, input, ctx)
          : await _connectOAuth(profile, input, ctx);
    } on HttpFailure catch (e) {
      throw ConnectException(MastodonApi.mapFailure(e, now: ctx.now(), context: 'Connecting to ${base.host}').message);
    } on OAuthException catch (e) {
      throw ConnectException('Sign-in on ${base.host} failed: ${e.description ?? e.error ?? e.message}');
    } on TimeoutException {
      throw ConnectException(
        '${base.host} did not answer in time. Check the address and your connection.',
        field: 'instance',
      );
    } on http.ClientException catch (e) {
      throw ConnectException('Could not reach ${base.host}: ${e.message}', field: 'instance');
    }
  }

  Future<MastodonInstanceProfile> _discover(MastodonApi api) async {
    api.ctx.progress('Looking up ${api.base.host}');
    final profile = await api.fetchInstance();
    if (profile == null) {
      throw ConnectException(
        '${api.base.host} does not look like a Mastodon-compatible server '
        '(no /api/v2/instance or /api/v1/instance).',
        field: 'instance',
      );
    }
    final sw = await api.fetchNodeInfoSoftware();
    return sw == null ? profile : profile.withSoftware(sw.$1, sw.$2);
  }

  ConnectResult _connectHandoff(MastodonInstanceProfile p, Map<String, String> input, AdapterContext ctx) {
    final handle = (input['handle'] ?? '').trim();
    return ConnectResult(
      account: ConnectedAccount(
        id: const Uuid().v4(),
        platformId: id,
        tier: PlatformTier.handoff,
        displayName: handle.isEmpty ? 'Hand-off (${p.domain})' : '$handle (hand-off)',
        handle: handle.isEmpty ? null : handle,
        createdAt: ctx.now(),
        config: p.toConfig(),
      ),
    );
  }

  Future<ConnectResult> _connectOAuth(MastodonInstanceProfile p, Map<String, String> input, AdapterContext ctx) async {
    final api = MastodonApi(ctx, p.base);
    final meta = await api.fetchOAuthMetadata();
    final scopes = _scopesFor(p, meta);
    final spec = specFor(PlatformTier.openApi);
    final redirect = ctx.requireBroker().chooseRedirectUri(
      loopbackOk: spec.loopbackRedirectOk,
      customSchemeOk: spec.customSchemeRedirectOk,
      fixed: spec.fixedRedirectUri,
    );

    final ownId = (input['client_id'] ?? '').trim();
    final ownSecret = (input['client_secret'] ?? '').trim();
    final MastodonClientCredentials client;
    if (ownId.isNotEmpty) {
      if (ownSecret.isEmpty) {
        throw const ConnectException('Enter the client secret too (Mastodon needs both)', field: 'client_secret');
      }
      client = MastodonClientCredentials(ownId, ownSecret);
    } else {
      ctx.progress('Registering NEFORUM on ${p.domain}');
      client = await _registerApp(api, redirect, scopes);
    }

    // PKCE only where the server advertises it (Mastodon 4.3+) or where it is
    // known to be ignored safely (older Mastodon / Doorkeeper).
    final oauth = OAuth2Client(
      authorizationEndpoint: meta.authorizationEndpoint,
      tokenEndpoint: meta.tokenEndpoint,
      clientId: client.clientId,
      clientSecret: client.clientSecret,
      scopes: scopes.split(' '),
      usePkce: meta.pkceS256 || p.isMastodon,
      clientAuth: ClientAuth.body,
    );
    final req = oauth.buildAuthorizationUrl(redirectUri: redirect);
    ctx.progress('Waiting for you to approve NEFORUM in the browser');
    final back = await ctx.requireBroker().authorize(req.url, redirect);
    final code = _extractCode(oauth, back, req, redirect);
    final tokens = await oauth.exchangeCode(
      ctx.http,
      code: code,
      redirectUri: redirect,
      pkce: req.pkce,
      now: ctx.now(),
    );

    ctx.progress('Reading your profile');
    final me = await MastodonApi(ctx, p.base, accessToken: tokens.accessToken).verifyCredentials();
    final username = (me['username'] as String?) ?? (me['acct'] as String?) ?? 'unknown';
    final display = (me['display_name'] as String?)?.trim();
    return ConnectResult(
      account: ConnectedAccount(
        id: const Uuid().v4(),
        platformId: id,
        tier: PlatformTier.openApi,
        displayName: '${display == null || display.isEmpty ? username : display} (${p.domain})',
        handle: '@$username@${p.domain}',
        avatarUrl: me['avatar'] as String?,
        profileUrl: me['url'] as String?,
        createdAt: ctx.now(),
        config: {
          ...p.toConfig(),
          'remoteAccountId': '${me['id']}',
          'scopes': scopes,
          'redirectUri': redirect.toString(),
          'tokenEndpoint': meta.tokenEndpoint.toString(),
          if (meta.revocationEndpoint != null) 'revocationEndpoint': meta.revocationEndpoint.toString(),
        },
      ),
      secrets: tokens.toSecrets({'client_id': client.clientId, 'client_secret': client.clientSecret}),
    );
  }

  static String _scopesFor(MastodonInstanceProfile p, MastodonOAuthMetadata meta) {
    if (!p.isMastodon) return scopesUmbrella;
    if (meta.scopesSupported.contains('profile') || (p.apiVersion ?? 0) >= 2) return scopesModern;
    return scopesLegacy;
  }

  Future<MastodonClientCredentials> _registerApp(MastodonApi api, Uri redirect, String scopes) async {
    try {
      return await api.registerApp(redirectUri: redirect, scopes: scopes);
    } on HttpFailure catch (e) {
      final host = api.base.host;
      final why = MastodonApi.errorText(e.response) ?? 'HTTP ${e.statusCode}';
      throw ConnectException(switch (e.statusCode) {
        429 => '$host allows only a few app registrations per 10 minutes. Wait a little and try again.',
        404 || 403 =>
          '$host does not allow apps to register themselves ($why). Create an app in your server\'s '
              'settings and enter its client ID and secret under "advanced".',
        _ => 'Registering NEFORUM on $host failed: $why',
      });
    }
  }

  /// Like [OAuth2Client.extractCode], but also accepts a bare code pasted by
  /// the user in the out-of-band flow (no `state` comes back there).
  static String _extractCode(OAuth2Client oauth, Uri back, AuthorizationRequest req, Uri redirect) {
    final q = back.queryParameters;
    if (redirect.toString() == oob && q['error'] == null && q['state'] == null && (q['code'] ?? '').isNotEmpty) {
      return q['code']!;
    }
    return oauth.extractCode(back, req);
  }

  // ---------------------------------------------------------------------------
  // Tokens
  // ---------------------------------------------------------------------------

  /// Mastodon and GoToSocial tokens never expire, so this normally returns
  /// `null`. Pleroma/Akkoma issue expiring tokens with a refresh token.
  @override
  Future<Map<String, String>?> refreshSecrets(
    ConnectedAccount account,
    Map<String, String> secrets,
    AdapterContext ctx,
  ) async {
    if (account.tier == PlatformTier.handoff) return null;
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) {
      throw const AdapterException(PublishError.auth('No access token stored for this account. Reconnect it.'));
    }
    final now = ctx.now();
    if (!tokens.isExpired(now: now)) return null;
    final refresh = tokens.refreshToken;
    final clientId = secrets['client_id'];
    if (refresh == null || clientId == null) {
      throw const AdapterException(PublishError.auth('Your sign-in on this server expired. Reconnect the account.'));
    }
    final p = MastodonInstanceProfile.fromConfig(account.config);
    final tokenEndpoint = Uri.tryParse(account.configString('tokenEndpoint')) ?? p.endpoint('/oauth/token');
    final oauth = OAuth2Client(
      authorizationEndpoint: p.endpoint('/oauth/authorize'),
      tokenEndpoint: tokenEndpoint.host.isEmpty ? p.endpoint('/oauth/token') : tokenEndpoint,
      clientId: clientId,
      clientSecret: secrets['client_secret'],
      clientAuth: ClientAuth.body,
    );
    try {
      final fresh = await oauth.refresh(ctx.http, refreshToken: refresh, now: now);
      final out = fresh.toSecrets(secrets);
      if (fresh.expiresAt == null) out.remove(OAuthTokens.keyExpiresAt);
      return out;
    } on OAuthException catch (e) {
      throw AdapterException(e.toRefreshError(account.configString('instanceHost', 'Your server')));
    }
  }

  @override
  Future<void> disconnect(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final token = secrets[OAuthTokens.keyAccessToken];
    final clientId = secrets['client_id'];
    final clientSecret = secrets['client_secret'];
    if (token == null || clientId == null || clientSecret == null) return;
    final p = MastodonInstanceProfile.fromConfig(account.config);
    final configured = Uri.tryParse(account.configString('revocationEndpoint'));
    final endpoint = configured == null || configured.host.isEmpty ? p.endpoint('/oauth/revoke') : configured;
    try {
      await MastodonApi(ctx, p.base).revoke(endpoint, clientId: clientId, clientSecret: clientSecret, token: token);
    } on Object catch (e) {
      ctx.log.warn('Revoking the Mastodon token failed', e);
    }
  }

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) =>
      _validateAt(variant, account, _clock());

  List<ValidationIssue> _validateAt(PostVariant variant, ConnectedAccount account, DateTime now) {
    final p = MastodonInstanceProfile.fromConfig(account.config);
    final d = descriptorFor(p);
    final issues = RulesValidator.validate(variant, d, tier: account.tier);
    final cw = variant.contentWarning?.trim() ?? '';
    final max = d.text.maxLength;
    final parts = variant.isThread ? variant.threadParts : [variant.text];

    if (cw.isNotEmpty && max != null && !issues.any((i) => i.code == 'text.too_long')) {
      for (var i = 0; i < parts.length; i++) {
        final n = TextCounter.count('$cw${parts[i]}', d.text);
        if (n > max) {
          issues.add(
            ValidationIssue.error(
              'text.too_long_with_cw',
              '${parts.length > 1 ? 'Part ${i + 1}' : 'The post'} plus its content warning is $n/$max characters '
                  '(the warning counts toward the limit)',
              field: 'text',
            ),
          );
        }
      }
    }
    final spoilerMax = p.spoilerTextMax;
    if (spoilerMax != null && cw.runes.length > spoilerMax) {
      issues.add(
        ValidationIssue.error(
          'cw.too_long',
          'The content warning is ${cw.runes.length}/$spoilerMax characters on ${p.softwareLabel}',
          field: 'contentWarning',
        ),
      );
    }
    if (variant.visibility == Visibility.private && !p.supportsDirectVisibility) {
      issues.add(
        ValidationIssue.error(
          'visibility.unsupported',
          '${p.softwareLabel} does not support private (direct) posts',
          field: 'visibility',
        ),
      );
    }
    final desc = p.descriptionLimit;
    if (desc != null && variant.media.any((m) => (m.altText ?? '').length > desc)) {
      issues.add(
        ValidationIssue.warning(
          'media.alt_too_long',
          'Alt text longer than $desc characters will be shortened',
          field: 'media',
        ),
      );
    }
    _checkMatrix(variant.media, p, issues);
    if (account.tier == PlatformTier.openApi) _checkSchedule(variant, p, now, issues);
    if (account.tier == PlatformTier.handoff) {
      if (!p.hasSharePage) {
        issues.add(
          ValidationIssue.info(
            'handoff.no_share_page',
            '${p.softwareLabel} has no share page; the text will be copied for you to paste',
            field: 'text',
          ),
        );
      }
      if (variant.hasMedia) {
        issues.add(
          const ValidationIssue.info(
            'handoff.media',
            'Images can only be attached through the mobile share sheet, not the web share page',
            field: 'media',
          ),
        );
      }
    }
    return issues;
  }

  static void _checkMatrix(List<MediaAttachment> media, MastodonInstanceProfile p, List<ValidationIssue> issues) {
    for (final m in media) {
      final w = m.width;
      final h = m.height;
      if (w == null || h == null) continue;
      final limit = m.isVideo ? p.videoMatrixLimit : (m.kind == MediaKind.image ? p.imageMatrixLimit : null);
      if (limit != null && w * h > limit) {
        issues.add(
          ValidationIssue.error(
            'media.too_many_pixels',
            '${m.fileName ?? m.id} is ${w}x$h; this server accepts at most $limit pixels',
            field: 'media',
          ),
        );
      }
    }
  }

  /// Server-side scheduling checks. A time that has already passed is not an
  /// error: the post is then published now, without `scheduled_at` (which
  /// GoToSocial would read as a request to backdate the post).
  static void _checkSchedule(PostVariant v, MastodonInstanceProfile p, DateTime now, List<ValidationIssue> issues) {
    final at = v.scheduledAt;
    if (at == null || !at.isAfter(now)) return;
    if (!p.supportsScheduling) {
      issues.add(
        ValidationIssue.error(
          'schedule.unsupported',
          '${p.schedulingUnsupportedReason}; NEFORUM schedules this one on this device instead',
          field: 'scheduledAt',
        ),
      );
    } else if (at.isBefore(now.add(minScheduleLead + scheduleSafetyMargin))) {
      issues.add(
        ValidationIssue.error(
          'schedule.too_soon',
          '${p.softwareLabel} only holds posts scheduled at least ${minScheduleLead.inMinutes} minutes ahead; '
              'NEFORUM schedules this one on this device instead',
          field: 'scheduledAt',
        ),
      );
    } else if (v.isThread) {
      issues.add(
        const ValidationIssue.error(
          'schedule.thread',
          'A thread cannot be scheduled on the server (replies need the first post to exist); '
              'let NEFORUM schedule it instead',
          field: 'scheduledAt',
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Publish
  // ---------------------------------------------------------------------------

  @override
  Future<PublishResult> publish(
    PostVariant variant,
    ConnectedAccount account,
    Map<String, String> secrets,
    AdapterContext ctx,
  ) async {
    try {
      return await _publish(variant, account, secrets, ctx);
    } on Exception catch (e) {
      return PublishResult.failure(_toError(e, ctx));
    }
  }

  /// Maps whatever a request ran into onto a [PublishError].
  static PublishError _toError(Exception e, AdapterContext ctx, {String? context}) {
    if (e is AdapterException) return e.error;
    if (e is HttpFailure) return MastodonApi.mapFailure(e, now: ctx.now(), context: context);
    final prefix = context == null ? '' : '$context: ';
    if (e is TimeoutException) return PublishError.network('${prefix}The server did not answer in time');
    if (e is http.ClientException) {
      return PublishError.network('${prefix}Network error: ${e.message}', raw: e.toString());
    }
    if (isTransientIoError(e)) return PublishError.network('${prefix}Network error: $e');
    return PublishError.platform('${prefix}Unexpected error: $e', raw: e.toString());
  }

  Future<PublishResult> _publish(
    PostVariant v,
    ConnectedAccount account,
    Map<String, String> secrets,
    AdapterContext ctx,
  ) async {
    if (account.tier == PlatformTier.handoff) {
      throw const AdapterException(PublishError.unsupported('This is a hand-off account; use the hand-off instead'));
    }
    final p = MastodonInstanceProfile.fromConfig(account.config);
    if (p.baseUrl.isEmpty) {
      throw const AdapterException(PublishError.configuration('The server address is missing; reconnect the account'));
    }
    final token = OAuthTokens.fromSecrets(secrets);
    if (token == null) {
      throw const AdapterException(PublishError.auth('No access token stored for this account. Reconnect it.'));
    }
    final now = ctx.now();
    final errors = _validateAt(v, account, now).where((i) => i.isError).toList();
    if (errors.isNotEmpty) {
      final kind = switch (errors.first.code) {
        'schedule.unsupported' || 'schedule.thread' => PublishErrorKind.unsupported,
        _ => PublishErrorKind.validation,
      };
      throw AdapterException(PublishError(kind: kind, message: errors.map((e) => e.message).join('; ')));
    }
    final api = MastodonApi(
      ctx,
      p.base,
      accessToken: token.accessToken,
      pollInterval: mediaPollInterval,
      maxPolls: maxMediaPolls,
    );

    // A time that has passed means "publish now": never send it, GoToSocial
    // would backdate the post instead.
    final requested = v.scheduledAt;
    final schedule = requested != null && requested.isAfter(now) ? requested.toUtc() : null;
    if (requested != null && schedule == null) ctx.log.info('The scheduled time has passed; publishing now');

    // Media first, also for a scheduled post: the server stores the ids.
    final mediaIds = await _uploadAll(api, v.media, p, ctx);
    if (schedule != null && schedule.isBefore(ctx.now().add(_sendLead))) {
      throw AdapterException(
        PublishError.validation(
          'The scheduled time is now less than ${minScheduleLead.inMinutes} minutes away, '
          'too close for ${p.softwareLabel} to hold the post',
        ),
      );
    }

    final parts = v.isThread ? v.threadParts : [v.text];
    final ids = <String>[];
    String? firstUrl;
    for (var i = 0; i < parts.length; i++) {
      if (parts.length > 1) ctx.progress('Posting part ${i + 1} of ${parts.length}');
      final form = _statusForm(
        v,
        p,
        parts[i],
        mediaIds: i == 0 ? mediaIds : const [],
        replyTo: i == 0 ? null : ids.last,
        scheduledAt: schedule,
      );
      try {
        final res = await api.postStatus(
          form,
          idempotencyKey: _idempotencyKey(account, v, i, form, scheduled: schedule != null),
        );
        final id = _string(res['id']);
        if (id == null) {
          throw AdapterException(PublishError.platform('The server answered without a post id', raw: jsonEncode(res)));
        }
        if (schedule != null && _isScheduledStatus(res)) {
          final at = DateTime.tryParse(_string(res['scheduled_at']) ?? '')?.toUtc() ?? schedule;
          ctx.log.info('${p.domain} holds the post until $at (scheduled status $id)');
          return PublishResult.scheduled(remoteId: id, scheduledFor: at);
        }
        if (schedule != null) ctx.log.warn('${p.domain} ignored scheduled_at and published immediately');
        ids.add(id);
        firstUrl ??= _string(res['url']) ?? _string(res['uri']);
      } on Exception catch (e) {
        if (ids.isEmpty) rethrow;
        // Earlier parts are live: a retry would post them a second time.
        throw AdapterException(_toError(e, ctx).asPartialThread(postedIds: ids, total: parts.length));
      }
    }
    return PublishResult.ok(
      remoteId: ids.first,
      remoteUrl: firstUrl,
      threadRemoteIds: ids.length > 1 ? ids : const [],
      publishedAt: ctx.now(),
    );
  }

  /// A ScheduledStatus (`id`, `scheduled_at`, `params`) rather than a Status.
  static bool _isScheduledStatus(Map<String, dynamic> res) => res['scheduled_at'] is String && res['params'] is Map;

  static String? _string(Object? v) => switch (v) {
    final String s when s.isNotEmpty => s,
    final num n => '$n',
    _ => null,
  };

  Future<List<String>> _uploadAll(
    MastodonApi api,
    List<MediaAttachment> media,
    MastodonInstanceProfile p,
    AdapterContext ctx,
  ) async {
    final ids = <String>[];
    for (var i = 0; i < media.length; i++) {
      final m = media[i];
      ctx.progress('Uploading ${m.isVideo ? 'video' : 'image'} ${i + 1} of ${media.length}');
      final bytes = await _read(m, ctx);
      ids.add(await api.uploadMedia(m, bytes, descriptionLimit: p.descriptionLimit));
    }
    return ids;
  }

  static Future<Uint8List> _read(MediaAttachment m, AdapterContext ctx) async {
    try {
      return await ctx.readMedia(m);
    } on Exception catch (e) {
      throw AdapterException(PublishError.configuration('Could not read ${m.fileName ?? m.path}: $e'));
    }
  }

  static List<MapEntry<String, String>> _statusForm(
    PostVariant v,
    MastodonInstanceProfile p,
    String text, {
    required List<String> mediaIds,
    required String? replyTo,
    required DateTime? scheduledAt,
  }) {
    final cw = v.contentWarning?.trim() ?? '';
    final lang = _language(v.language);
    return [
      MapEntry('status', text),
      for (final id in mediaIds) MapEntry('media_ids[]', id),
      MapEntry('visibility', mastodonVisibility(v.visibility)),
      if (cw.isNotEmpty) MapEntry('spoiler_text', cw),
      if (v.sensitive) const MapEntry('sensitive', 'true'),
      if (lang != null) MapEntry('language', lang),
      if (replyTo != null) MapEntry('in_reply_to_id', replyTo),
      if (scheduledAt != null) MapEntry('scheduled_at', scheduledAt.toUtc().toIso8601String()),
      if (p.needsPlainContentType) const MapEntry('content_type', 'text/plain'),
    ];
  }

  /// NEFORUM visibility → Mastodon: followers = `private`, private = `direct`
  /// (a direct post without mentions is visible only to the author).
  static String mastodonVisibility(Visibility v) => switch (v) {
    Visibility.public => 'public',
    Visibility.unlisted => 'unlisted',
    Visibility.followers => 'private',
    Visibility.private => 'direct',
  };

  /// `en-GB` → `en`. Mastodon wants ISO 639-1 (or 639-3) codes.
  static String? _language(String? tag) {
    final primary = tag?.split(RegExp('[-_]')).first.toLowerCase();
    if (primary == null || !RegExp(r'^[a-z]{2,3}$').hasMatch(primary)) return null;
    return primary;
  }

  /// The `Idempotency-Key` for one status request.
  ///
  /// Immediate posts get a key derived from everything that defines the
  /// status except the freshly uploaded media ids, so a retry after a dropped
  /// connection gets the original status back instead of posting twice
  /// (Mastodon keeps keys for an hour; Pleroma/Akkoma replay the stored
  /// response), while an edited post gets a new key.
  ///
  /// Scheduled requests get a fresh key on every call. Mastodon shares one key
  /// space between scheduled and immediate posts and answers 404 once the
  /// earlier record is gone, and Pleroma/Akkoma would replay a scheduled post
  /// NEFORUM has since cancelled. HTTP-level retries inside the call still
  /// reuse the key. Random as well when the variant has no source post.
  static String _idempotencyKey(
    ConnectedAccount a,
    PostVariant v,
    int part,
    List<MapEntry<String, String>> form, {
    required bool scheduled,
  }) {
    final src = v.sourcePostId;
    if (src == null || scheduled) return const Uuid().v4();
    final fields = form.where((e) => e.key != 'media_ids[]').map((e) => '${e.key}=${e.value}').join('\n');
    final media = part == 0 ? v.media.map((m) => m.id).join(',') : '';
    final digest = sha256.convert(utf8.encode('neforum|${a.id}|$src|$part|$media|$fields'));
    return digest.toString().substring(0, 40);
  }

  // ---------------------------------------------------------------------------
  // Server-side scheduling
  // ---------------------------------------------------------------------------

  /// Takes back a post the server holds with
  /// `DELETE /api/v1/scheduled_statuses/:id`. 404/410 mean it is gone already
  /// (published or removed elsewhere), which counts as success.
  @override
  Future<void> cancelScheduled(
    PublishResult held,
    ConnectedAccount account,
    Map<String, String> secrets,
    AdapterContext ctx,
  ) async {
    final id = held.remoteId ?? '';
    if (id.isEmpty) {
      throw const AdapterException(
        PublishError.platform('No id was recorded for the scheduled post; remove it on the server itself'),
      );
    }
    final p = MastodonInstanceProfile.fromConfig(account.config);
    if (p.baseUrl.isEmpty) {
      throw const AdapterException(PublishError.configuration('The server address is missing; reconnect the account'));
    }
    final token = OAuthTokens.fromSecrets(secrets);
    if (token == null) {
      throw const AdapterException(PublishError.auth('No access token stored for this account. Reconnect it.'));
    }
    try {
      final removed = await MastodonApi(ctx, p.base, accessToken: token.accessToken).deleteScheduledStatus(id);
      ctx.log.info(
        removed ? 'Removed scheduled post $id from ${p.domain}' : 'Scheduled post $id was already gone from ${p.domain}',
      );
    } on Exception catch (e) {
      throw AdapterException(_toError(e, ctx, context: 'Removing the scheduled post from ${p.domain}'));
    }
  }

  // ---------------------------------------------------------------------------
  // Hand-off
  // ---------------------------------------------------------------------------

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final p = account == null ? null : MastodonInstanceProfile.fromConfig(account.config);
    final hasServer = p != null && p.baseUrl.isNotEmpty;
    final text = variant.text;
    final full = variant.isThread ? variant.threadParts.join('\n\n') : text;
    Uri? intent;
    if (hasServer && p.hasSharePage) {
      intent = p
          .endpoint('/share')
          .replace(
            queryParameters: {
              'text': text,
              if (variant.visibility != Visibility.public) 'visibility': mastodonVisibility(variant.visibility),
            },
          );
    }
    final preferred = variant.hasMedia
        ? HandoffMethod.shareSheet
        : (intent != null ? HandoffMethod.webIntent : HandoffMethod.manual);
    final where = hasServer ? p.domain : 'your server';
    final cw = variant.contentWarning?.trim() ?? '';
    return HandoffPlan(
      platformId: id,
      webIntent: intent,
      clipboardText: full,
      shareText: text,
      shareFiles: variant.media,
      androidPackage: 'org.joinmastodon.android',
      iosScheme: 'mastodon://',
      desktopUrl: hasServer ? p.baseUrl : 'https://joinmastodon.org/apps',
      preferred: preferred,
      instructions: [
        if (intent != null && !variant.hasMedia)
          '1. NEFORUM opens the composer on $where with your text filled in (sign in there if asked).'
        else if (variant.hasMedia)
          '1. Pick the Mastodon app (or your usual client) in the share sheet; your images are attached.'
        else
          '1. Open $where; your text is on the clipboard.',
        if (variant.hasMedia || intent == null)
          '2. Paste the text if it is not filled in already.'
        else
          '2. Check the text.',
        if (cw.isNotEmpty) '3. Add the content warning "$cw" with the CW button.',
        '${cw.isNotEmpty ? 4 : 3}. Press **Publish**.',
      ].join('\n'),
      mediaNote: variant.hasMedia
          ? 'The web share page cannot attach files; use the mobile share sheet, or attach them yourself in the composer.'
          : null,
    );
  }
}
