import 'dart:async';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../auth/oauth2_pkce.dart';
import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../model/account.dart';
import '../../model/media.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../../text/url_detector.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'facebook_api.dart';
import 'facebook_specs.dart';

/// Facebook Pages through the Graph API (bring your own Meta app), plus a
/// hand-off tier for personal profiles and anyone without a developer app.
///
/// Personal profiles cannot be posted to through any API: Meta removed
/// `publish_actions` in 2018, and the Groups API was removed in April 2024.
/// The API tier therefore only targets Pages the user manages.
class FacebookAdapter extends PlatformAdapter {
  FacebookAdapter();

  static const String platformId = 'facebook';

  // Config keys (non-secret, ConnectedAccount.config).
  static const String cfgAppId = 'app_id';
  static const String cfgPageId = 'page_id';
  static const String cfgPageName = 'page_name';
  static const String cfgUserId = 'user_id';
  static const String cfgUserName = 'user_name';
  static const String cfgAvailablePages = 'available_pages';
  static const String cfgScopes = 'scopes';
  static const String cfgPageUrl = 'page_url';

  // Secret keys. The Page token is stored under OAuthTokens.keyAccessToken.
  static const String secAppSecret = 'app_secret';
  static const String secUserToken = 'user_access_token';
  static const String secUserTokenExpiresAt = 'user_token_expires_at';

  /// Page permissions requested by default. pages_manage_posts depends on
  /// pages_read_engagement and pages_show_list (permissions reference);
  /// business_management lets /me/accounts list Pages owned by a business
  /// portfolio.
  static const List<String> defaultScopes = [
    'pages_show_list',
    'pages_read_engagement',
    'pages_manage_posts',
    'business_management',
  ];

  static const Duration _minScheduleLead = Duration(minutes: 10);
  static const Duration _maxScheduleFeed = Duration(days: 30);
  static const Duration _maxScheduleVideo = Duration(days: 180);
  static const Duration _videoTimeout = Duration(minutes: 30);

  @override
  PlatformDescriptor get descriptor => facebookDescriptor;

  @override
  List<ConnectSpec> get connectSpecs => facebookConnectSpecs;

  // ---------------------------------------------------------------------
  // connect
  // ---------------------------------------------------------------------

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    switch (tier) {
      case PlatformTier.handoff:
        return _connectHandoff(input, ctx);
      case PlatformTier.byokApi:
        return _connectApi(input, ctx);
      case PlatformTier.openApi:
      case PlatformTier.webSession:
        throw ConnectException('Facebook does not support the "${tier.label}" tier in NEFORUM');
    }
  }

  Future<ConnectResult> _connectHandoff(Map<String, String> input, AdapterContext ctx) async {
    final pageUrl = (input[cfgPageUrl] ?? '').trim();
    if (pageUrl.isNotEmpty) {
      final u = Uri.tryParse(pageUrl);
      if (u == null || !u.hasScheme || !u.host.contains('facebook.com')) {
        throw const ConnectException('Enter a facebook.com address, e.g. https://www.facebook.com/YourPage', field: cfgPageUrl);
      }
    }
    return ConnectResult(
      account: ConnectedAccount(
        id: 'facebook-handoff-${const Uuid().v4()}',
        platformId: platformId,
        tier: PlatformTier.handoff,
        displayName: 'Facebook (hand-off)',
        createdAt: ctx.now(),
        profileUrl: pageUrl.isEmpty ? null : pageUrl,
        config: {if (pageUrl.isNotEmpty) cfgPageUrl: pageUrl},
      ),
    );
  }

  Future<ConnectResult> _connectApi(Map<String, String> input, AdapterContext ctx) async {
    final appId = (input[cfgAppId] ?? '').trim();
    final appSecret = (input[secAppSecret] ?? '').trim();
    if (!RegExp(r'^\d{5,}$').hasMatch(appId)) {
      throw const ConnectException('The App ID is the long number at the top of your Meta app dashboard', field: cfgAppId);
    }
    if (appSecret.isEmpty) {
      throw const ConnectException('Paste the App Secret from App settings > Basic', field: secAppSecret);
    }
    final scopes = _parseScopes(input[cfgScopes]);
    final pasted = (input[secUserToken] ?? '').trim();

    try {
      final shortToken = pasted.isNotEmpty ? pasted : await _browserLogin(appId, appSecret, scopes, ctx);
      ctx.progress('Exchanging for a long-lived token');
      final userTokens = await _longLivedToken(appId, appSecret, shortToken, ctx);
      final user = await _getJson(ctx, 'me', {'fields': 'id,name'}, userTokens.accessToken, appSecret);
      ctx.progress('Fetching your Pages');
      final pages = await _listPages(ctx, userTokens.accessToken, appSecret);
      final page = _choosePage(pages, input['page']);
      final others = pages.map((p) => p.toSummary()).toList();

      final secrets = OAuthTokens(accessToken: page.accessToken).toSecrets({
        secAppSecret: appSecret,
        secUserToken: userTokens.accessToken,
        if (userTokens.expiresAt != null) secUserTokenExpiresAt: userTokens.expiresAt!.toUtc().toIso8601String(),
      });
      return ConnectResult(
        account: ConnectedAccount(
          id: 'facebook-${page.id}',
          platformId: platformId,
          tier: PlatformTier.byokApi,
          displayName: page.name,
          handle: page.name,
          profileUrl: page.link ?? 'https://www.facebook.com/${page.id}',
          createdAt: ctx.now(),
          config: {
            cfgAppId: appId,
            cfgPageId: page.id,
            cfgPageName: page.name,
            if (optString(user, 'id') != null) cfgUserId: optString(user, 'id'),
            if (optString(user, 'name') != null) cfgUserName: optString(user, 'name'),
            cfgAvailablePages: others,
            cfgScopes: scopes.join(','),
          },
        ),
        secrets: secrets,
      );
    } on HttpFailure catch (f) {
      throw ConnectException(_connectMessage(f));
    } on OAuthException catch (e) {
      throw ConnectException('Facebook sign-in failed: ${e.description ?? e.error ?? e.message}');
    }
  }

  /// Runs Facebook Login in the browser. Facebook only redirects to
  /// registered HTTPS URIs, so the broker (a paste-the-address broker in
  /// practice) is asked for [facebookLoginSuccessUri]. Meta's desktop guidance
  /// is `response_type=token`, which puts the user token in the fragment; a
  /// pasted `code` is exchanged as a fallback.
  Future<String> _browserLogin(String appId, String appSecret, List<String> scopes, AdapterContext ctx) async {
    final broker = ctx.broker;
    if (broker == null) {
      throw const ConnectException(
          'Sign-in needs a browser here. Alternatively paste a user access token from the Graph API Explorer.',
          field: secUserToken);
    }
    final redirect = broker.chooseRedirectUri(loopbackOk: false, customSchemeOk: false, fixed: facebookLoginSuccessUri);
    final client = OAuth2Client(
      authorizationEndpoint: facebookAuthorizeEndpoint,
      tokenEndpoint: facebookTokenEndpoint,
      clientId: appId,
      clientSecret: appSecret,
      scopes: scopes,
      scopeSeparator: ',',
      usePkce: false,
      clientAuth: ClientAuth.body,
      extraAuthorizationParams: const {'response_type': 'token'},
    );
    final req = client.buildAuthorizationUrl(redirectUri: redirect);
    // AuthCancelled propagates to the caller unchanged.
    final back = await broker.authorize(req.url, redirect, timeout: const Duration(minutes: 10));
    final p = redirectParams(back);
    if (p['error'] != null || p['error_code'] != null) {
      final why = p['error_description'] ?? p['error_message'] ?? p['error_reason'] ?? p['error'] ?? p['error_code'];
      throw ConnectException('Facebook refused the sign-in: $why');
    }
    final state = p['state'];
    if (state != null && state != req.state) {
      throw const ConnectException('The pasted address belongs to a different sign-in attempt; try again.');
    }
    final token = p['access_token'];
    if (token != null && token.isNotEmpty) return token;
    final code = p['code'];
    if (code != null && code.isNotEmpty) {
      final t = await client.exchangeCode(ctx.http, code: code, redirectUri: redirect, now: ctx.now());
      return t.accessToken;
    }
    throw const ConnectException(
        'No access token found. Copy the full address of the "Success" page (it contains #access_token=...) and paste it.');
  }

  /// Collects query and fragment parameters from what the broker returned,
  /// unwrapping the case where a paste broker treated a fragment-only URL (or
  /// a bare token) as a "code".
  static Map<String, String> redirectParams(Uri back) {
    final out = <String, String>{};
    void addFrom(Uri u) {
      out.addAll(u.queryParameters);
      final frag = u.fragment;
      if (frag.isNotEmpty && frag.contains('=')) {
        try {
          out.addAll(Uri.splitQueryString(frag));
        } on ArgumentError {
          // Malformed fragment; ignore.
        } on FormatException {
          // Malformed fragment; ignore.
        }
      }
    }

    addFrom(back);
    final code = out['code'];
    if (code != null) {
      if (code.contains('://')) {
        final inner = Uri.tryParse(code);
        if (inner != null) {
          out.remove('code');
          addFrom(inner);
        }
      } else if (code.contains('access_token=')) {
        out.remove('code');
        out.addAll(Uri.splitQueryString(code.replaceFirst(RegExp(r'^[#?]'), '')));
      } else if (code.startsWith('EAA')) {
        // A bare user access token (they start with "EAA").
        out.remove('code');
        out['access_token'] = code;
      }
    }
    return out;
  }

  Future<OAuthTokens> _longLivedToken(String appId, String appSecret, String shortToken, AdapterContext ctx) async {
    final res = await ctx.http.get(facebookTokenEndpoint.replace(queryParameters: {
      'grant_type': 'fb_exchange_token',
      'client_id': appId,
      'client_secret': appSecret,
      'fb_exchange_token': shortToken,
    }));
    final json = res.jsonMap;
    if (optString(json, 'access_token') == null) {
      throw const ConnectException('Facebook did not return a long-lived token; check the App ID and App Secret.');
    }
    return OAuthTokens.fromTokenResponse(json, now: ctx.now());
  }

  Future<List<FacebookPage>> _listPages(AdapterContext ctx, String userToken, String appSecret) async {
    final pages = <FacebookPage>[];
    Uri? next = graphUri('me/accounts', withToken({'fields': 'id,name,access_token,tasks,link', 'limit': '100'}, userToken, appSecret));
    var guard = 0;
    while (next != null && guard++ < 10) {
      final json = (await ctx.http.get(next)).jsonMap;
      final data = json['data'];
      if (data is List) {
        for (final item in data) {
          final p = FacebookPage.fromJson(item);
          if (p != null) pages.add(p);
        }
      }
      final paging = json['paging'];
      final nextUrl = paging is Map ? paging['next'] : null;
      next = nextUrl is String && nextUrl.isNotEmpty ? Uri.tryParse(nextUrl) : null;
    }
    return pages;
  }

  FacebookPage _choosePage(List<FacebookPage> pages, String? wanted) {
    if (pages.isEmpty) {
      throw const ConnectException(
          'Facebook returned no Pages. NEFORUM can only post to Pages you manage (personal profiles cannot be posted to '
          'through the API). In the Facebook dialog make sure you select your Page(s), and that your role on the Page '
          'includes creating content.');
    }
    final w = (wanted ?? '').trim();
    if (w.isNotEmpty) {
      final match = pages.where((p) => p.id == w || p.name.toLowerCase() == w.toLowerCase()).toList();
      if (match.isEmpty) {
        throw ConnectException('No Page called "$w". Your Pages: ${pages.map((p) => '${p.name} (${p.id})').join(', ')}',
            field: 'page');
      }
      if (!match.first.canCreateContent) {
        throw ConnectException('Your role on "${match.first.name}" does not allow creating posts.', field: 'page');
      }
      return match.first;
    }
    return pages.firstWhere((p) => p.canCreateContent,
        orElse: () => throw const ConnectException('None of your Pages lets you create posts with your current role.'));
  }

  static List<String> _parseScopes(String? raw) {
    final s = (raw ?? '').split(RegExp(r'[\s,]+')).map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
    return s.isEmpty ? defaultScopes : s;
  }

  static String _connectMessage(HttpFailure f) {
    final err = GraphError.parse(f.response.jsonMap);
    if (err == null) return 'Facebook returned HTTP ${f.statusCode} while connecting';
    if (err.code == 101 || err.code == 1) return 'Facebook rejected the App ID/App Secret: ${err.display}';
    if (err.code == 190) return 'The Facebook token is invalid or expired: ${err.display}';
    return 'Facebook error while connecting: ${err.display}';
  }

  Future<Map<String, dynamic>> _getJson(
      AdapterContext ctx, String path, Map<String, String> query, String token, String? appSecret) async {
    final res = await ctx.http.get(graphUri(path, withToken(query, token, appSecret)));
    return res.jsonMap;
  }

  // ---------------------------------------------------------------------
  // refresh
  // ---------------------------------------------------------------------

  /// Page tokens derived from a long-lived user token do not expire (Meta:
  /// "Long-lived Page access token do not have an expiration date") and
  /// there is no refresh grant, so there is nothing to refresh. They are
  /// invalidated by password changes, role loss or app removal, which surface
  /// as `auth` errors at publish time.
  @override
  Future<Map<String, String>?> refreshSecrets(
      ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.byokApi) return null;
    if (OAuthTokens.fromSecrets(secrets) == null) {
      throw const AdapterException(PublishError.auth('No Facebook Page token stored; reconnect the account.'));
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // validate
  // ---------------------------------------------------------------------

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = super.validate(variant, account);
    if (account.tier == PlatformTier.handoff) {
      if (variant.text.trim().isNotEmpty) {
        issues.add(const ValidationIssue.info('handoff.paste_text',
            'Facebook does not let other apps prefill your text; NEFORUM copies it to the clipboard for you to paste.',
            field: 'text'));
      }
      return issues;
    }
    if (account.configString(cfgPageId).isEmpty) {
      issues.add(const ValidationIssue.error('account.no_page', 'No Facebook Page selected; reconnect the account.',
          field: 'account'));
    }
    final hasImages = variant.media.any((m) => m.isImage);
    final link = (variant.link ?? '').trim();
    if (hasImages && link.isNotEmpty && !_textHasLink(variant.text, link)) {
      issues.add(const ValidationIssue.info('link.in_caption',
          'Photo posts cannot carry a link preview on Facebook; the link is added to the text.',
          field: 'link'));
    }
    final at = variant.scheduledAt;
    if (at != null) {
      final now = DateTime.now();
      final isVideo = variant.media.any((m) => m.isVideo);
      final max = isVideo ? _maxScheduleVideo : _maxScheduleFeed;
      if (at.isBefore(now.add(_minScheduleLead))) {
        issues.add(const ValidationIssue.error(
            'schedule.too_soon', 'Facebook can only schedule posts at least 10 minutes ahead.',
            field: 'schedule'));
      } else if (at.isAfter(now.add(max))) {
        issues.add(ValidationIssue.error('schedule.too_far',
            'Facebook schedules ${isVideo ? 'videos up to 6 months' : 'posts up to 30 days'} ahead.',
            field: 'schedule'));
      }
    }
    return issues;
  }

  // ---------------------------------------------------------------------
  // publish
  // ---------------------------------------------------------------------

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    try {
      if (account.tier != PlatformTier.byokApi) {
        return PublishResult.failure(const PublishError.unsupported('This Facebook account is set up for hand-off only.'));
      }
      final pageId = account.configString(cfgPageId);
      if (pageId.isEmpty) {
        return PublishResult.failure(const PublishError.configuration('No Facebook Page selected; reconnect the account.'));
      }
      final tokens = OAuthTokens.fromSecrets(secrets);
      if (tokens == null) {
        return PublishResult.failure(const PublishError.auth('No Facebook Page token stored; reconnect the account.'));
      }
      final call = _PageCall(ctx, pageId, tokens.accessToken, secrets[secAppSecret]);
      final schedule = _scheduleFields(variant, ctx);
      final text = variant.isThread ? variant.threadParts.join('\n\n') : variant.text;

      final videos = variant.media.where((m) => m.isVideo).toList();
      final images = variant.media.where((m) => m.isImage).toList();
      if (videos.isNotEmpty) {
        if (images.isNotEmpty || videos.length > 1) {
          return PublishResult.failure(const PublishError.validation('Facebook posts take one video and no photos alongside it.'));
        }
        return await _publishVideo(call, videos.single, variant, _withLink(text, variant.link), schedule);
      }
      if (images.length == 1) {
        return await _publishSinglePhoto(call, images.single, _withLink(text, variant.link), schedule);
      }
      if (images.length > 1) {
        return await _publishMultiPhoto(call, images, _withLink(text, variant.link), schedule);
      }
      return await _publishFeed(call, text, variant.link, schedule);
    } on AdapterException catch (e) {
      return PublishResult.failure(e.error);
    } on HttpFailure catch (f) {
      return PublishResult.failure(mapGraphFailure(f));
    } on TimeoutException catch (e) {
      return PublishResult.failure(PublishError.network('Facebook did not answer in time', raw: '$e'));
    } on Exception catch (e) {
      return PublishResult.failure(PublishError.network('Could not reach Facebook: $e', raw: '$e'));
    }
  }

  Future<PublishResult> _publishFeed(_PageCall call, String text, String? link, Map<String, String> schedule) async {
    call.ctx.progress('Posting to Facebook');
    final json = await call.form('feed', {
      if (text.trim().isNotEmpty) 'message': text,
      if (link != null && link.trim().isNotEmpty) 'link': link.trim(),
      ...schedule,
    });
    return _postResult(requireString(json, 'id', 'a post id'));
  }

  Future<PublishResult> _publishSinglePhoto(
      _PageCall call, MediaAttachment image, String caption, Map<String, String> schedule) async {
    call.ctx.progress('Uploading image 1 of 1');
    final json = await call.upload('photos', {
      if (caption.trim().isNotEmpty) 'caption': caption,
      ..._altText(image),
      ...schedule,
    }, image, await _read(call.ctx, image));
    final postId = optString(json, 'post_id');
    if (postId != null) return _postResult(postId);
    final photoId = requireString(json, 'id', 'a photo id');
    return PublishResult.ok(remoteId: photoId, remoteUrl: 'https://www.facebook.com/$photoId', publishedAt: call.ctx.now());
  }

  Future<PublishResult> _publishMultiPhoto(
      _PageCall call, List<MediaAttachment> images, String message, Map<String, String> schedule) async {
    final scheduled = schedule.isNotEmpty;
    final ids = <String>[];
    for (var i = 0; i < images.length; i++) {
      call.ctx.progress('Uploading image ${i + 1} of ${images.length}');
      final json = await call.upload('photos', {
        'published': 'false',
        // Unpublished uploads are deleted after ~24 h unless marked temporary;
        // scheduled posts may go out later than that.
        if (scheduled) 'temporary': 'true',
        ..._altText(images[i]),
      }, images[i], await _read(call.ctx, images[i]));
      ids.add(requireString(json, 'id', 'a photo id'));
    }
    call.ctx.progress('Creating the Facebook post');
    final json = await call.form('feed', {
      if (message.trim().isNotEmpty) 'message': message,
      for (var i = 0; i < ids.length; i++) 'attached_media[$i]': '{"media_fbid":"${ids[i]}"}',
      ...schedule,
      if (scheduled) 'unpublished_content_type': 'SCHEDULED',
    });
    return _postResult(requireString(json, 'id', 'a post id'));
  }

  Future<PublishResult> _publishVideo(_PageCall call, MediaAttachment video, PostVariant variant, String description,
      Map<String, String> schedule) async {
    final bytes = await _read(call.ctx, video);
    call.ctx.progress('Uploading video (${(bytes.length / (1024 * 1024)).toStringAsFixed(1)} MB)');
    final title = (variant.extraAs<String>('videoTitle') ?? variant.title ?? '').trim();
    final json = await call.upload('videos', {
      if (description.trim().isNotEmpty) 'description': description,
      if (title.isNotEmpty) 'title': title,
      ...schedule,
    }, video, bytes, timeout: _videoTimeout);
    final id = requireString(json, 'id', 'a video id');
    return PublishResult.ok(
      remoteId: id,
      remoteUrl: 'https://www.facebook.com/${call.pageId}/videos/$id',
      publishedAt: call.ctx.now(),
    );
  }

  /// `published=false` + `scheduled_publish_time` when the schedule was
  /// delegated to Facebook.
  Map<String, String> _scheduleFields(PostVariant v, AdapterContext ctx) {
    final at = v.scheduledAt;
    if (at == null) return const {};
    if (at.isBefore(ctx.now().add(_minScheduleLead))) {
      throw const AdapterException(
          PublishError.validation('Facebook can only schedule posts at least 10 minutes ahead.'));
    }
    return {
      'published': 'false',
      'scheduled_publish_time': '${at.toUtc().millisecondsSinceEpoch ~/ 1000}',
    };
  }

  Map<String, String> _altText(MediaAttachment m) {
    final alt = (m.altText ?? '').trim();
    return alt.isEmpty ? const {} : {'alt_text_custom': alt};
  }

  Future<Uint8List> _read(AdapterContext ctx, MediaAttachment m) async {
    try {
      return await ctx.readMedia(m);
    } on Exception catch (e) {
      throw AdapterException(PublishError.configuration('Could not read ${m.fileName ?? m.path}: $e'));
    }
  }

  PublishResult _postResult(String postId) {
    final parts = postId.split('_');
    final url = parts.length == 2
        ? 'https://www.facebook.com/${parts[0]}/posts/${parts[1]}'
        : 'https://www.facebook.com/$postId';
    return PublishResult.ok(remoteId: postId, remoteUrl: url);
  }

  static bool _textHasLink(String text, String link) =>
      text.contains(link) || UrlDetector.find(text).any((u) => u.normalized == link);

  /// Photo and video posts have no link field, so the link goes into the text.
  static String _withLink(String text, String? link) {
    final l = (link ?? '').trim();
    if (l.isEmpty || _textHasLink(text, l)) return text;
    return text.trim().isEmpty ? l : '$text\n\n$l';
  }

  // ---------------------------------------------------------------------
  // hand-off
  // ---------------------------------------------------------------------

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final text = variant.isThread ? variant.threadParts.join('\n\n') : variant.text;
    final explicit = (variant.link ?? '').trim();
    final found = UrlDetector.find(text);
    final link = explicit.isNotEmpty ? explicit : (found.isEmpty ? null : found.first.normalized);
    final full = _withLink(text, explicit.isEmpty ? null : explicit);
    final hasMedia = variant.media.isNotEmpty;

    Uri? intent;
    if (link != null) {
      // `quote` used to prefill the message; Meta deprecated it and the
      // sharer now only honours `u`. Sent anyway in case it is honoured, but
      // dropped when it would make the URL unreasonably long.
      intent = Uri.https('www.facebook.com', '/sharer/sharer.php', {
        'u': link,
        if (text.trim().isNotEmpty) 'quote': text,
      });
      if (intent.toString().length > 2000) {
        intent = Uri.https('www.facebook.com', '/sharer/sharer.php', {'u': link});
      }
    }
    final configured = account?.configString(cfgPageUrl) ?? '';
    final desktopUrl = configured.isNotEmpty ? configured : 'https://www.facebook.com/';

    final HandoffMethod preferred;
    final String instructions;
    if (hasMedia) {
      preferred = HandoffMethod.shareSheet;
      instructions = '1. Your text is already on the clipboard.\n'
          '2. Choose **Facebook** in the share sheet; your ${variant.media.length == 1 ? 'file is' : 'files are'} attached.\n'
          '3. To post as your Page, switch to the Page profile in the composer.\n'
          '4. Tap the text box, paste, and tap **Post**.';
    } else if (intent != null) {
      preferred = HandoffMethod.webIntent;
      instructions = '1. Your text is already on the clipboard.\n'
          '2. Facebook\'s share window opens with your link.\n'
          '3. Paste your text into the message box (Facebook ignores prefilled text) and press **Post**.';
    } else {
      preferred = HandoffMethod.manual;
      instructions = '1. Your text is already on the clipboard.\n'
          '2. Facebook opens; click **What\'s on your mind?** (on your Page if you post as a Page).\n'
          '3. Paste and press **Post**.';
    }
    return HandoffPlan(
      platformId: platformId,
      instructions: instructions,
      webIntent: intent,
      clipboardText: full.trim().isEmpty ? null : full,
      shareText: full.trim().isEmpty ? null : full,
      shareFiles: variant.media,
      androidPackage: 'com.facebook.katana',
      iosScheme: 'fb://',
      desktopUrl: desktopUrl,
      preferred: preferred,
      mediaNote: hasMedia
          ? 'Facebook never accepts a caption from other apps; NEFORUM put your text on the clipboard so you can paste it.'
          : null,
    );
  }
}

/// Small helper bundling everything a Page-scoped Graph call needs.
class _PageCall {
  _PageCall(this.ctx, this.pageId, this.token, this.appSecret);

  final AdapterContext ctx;
  final String pageId;
  final String token;
  final String? appSecret;

  Future<Map<String, dynamic>> form(String edge, Map<String, String> params) async {
    final res = await ctx.http.postForm(graphUri('$pageId/$edge'), withToken(params, token, appSecret));
    return res.jsonMap;
  }

  Future<Map<String, dynamic>> upload(String edge, Map<String, String> fields, MediaAttachment media, Uint8List bytes,
      {Duration? timeout}) async {
    final res = await ctx.http.send(
      'POST',
      graphUri('$pageId/$edge'),
      fields: withToken(fields, token, appSecret),
      files: [
        HttpFilePart(
          field: 'source',
          bytes: bytes,
          fileName: media.fileName ?? 'upload${_ext(media.mimeType)}',
          contentType: media.mimeType,
        ),
      ],
      timeout: timeout,
    );
    return res.jsonMap;
  }

  static String _ext(String mime) => switch (mime) {
        'image/jpeg' => '.jpg',
        'image/png' => '.png',
        'image/gif' => '.gif',
        'image/bmp' => '.bmp',
        'image/tiff' => '.tiff',
        'video/quicktime' => '.mov',
        _ when mime.startsWith('video/') => '.mp4',
        _ => '',
      };
}
