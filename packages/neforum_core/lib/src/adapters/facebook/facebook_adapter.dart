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

  /// Facebook's own minimum: `scheduled_publish_time` "must be between 10
  /// minutes and 30 days from the time of the API request" (Pages API posts
  /// guide; the /feed reference says 75 days, NEFORUM uses the stricter 30).
  static const Duration minScheduleLead = Duration(minutes: 10);

  /// [validate] asks for this much extra lead so that a slow upload or a
  /// skewed clock cannot push the request inside Facebook's minimum. Posts
  /// closer than that stay on NEFORUM's own scheduler.
  static const Duration scheduleLeadMargin = Duration(minutes: 5);
  static const Duration maxScheduleFeed = Duration(days: 30);

  /// /{page-id}/videos: "between 10 mins and 6 months" (180 days, rounded down).
  static const Duration maxScheduleVideo = Duration(days: 180);
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
      final OAuthTokens userTokens;
      try {
        userTokens = await _longLivedToken(appId, appSecret, shortToken, ctx);
      } on HttpFailure catch (f) {
        final err = GraphError.parse(f.response.jsonMap);
        if (err != null && isWrongAppError(err)) {
          throw ConnectException(wrongAppMessage(appId, err, await _tokenApp(ctx, shortToken, appId, appSecret)));
        }
        if (pasted.isEmpty || err?.code != 190) rethrow;
        throw ConnectException(
            'Facebook did not accept the pasted token (${err!.display}). Explorer tokens expire after one to two '
            'hours: generate a fresh one with Meta App set to this same app (leave User or Page as it is), click '
            'Generate Access Token and paste all of it.',
            field: secUserToken);
      }
      final user = await _getJson(ctx, 'me', {'fields': 'id,name'}, userTokens.accessToken, appSecret);
      await _checkPermissions(ctx, userTokens.accessToken, appSecret, fromExplorer: pasted.isNotEmpty);
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
      throw ConnectException(_connectMessage(f, appId));
    } on OAuthException catch (e) {
      throw ConnectException('${_sentence('Facebook sign-in failed: ${e.description ?? e.error ?? e.message}')} '
          '$_useTokenHint');
    }
  }

  static const String _useTokenHint =
      'Pasting a token from the Graph API Explorer is the recommended way to connect (see the steps above).';

  static String _sentence(String s) => RegExp(r'[.!?]$').hasMatch(s.trimRight()) ? s.trimRight() : '${s.trimRight()}.';

  /// Runs Facebook Login in the browser, the secondary route. The broker (a
  /// paste-the-address broker in practice) is asked for
  /// [facebookLoginSuccessUri], which Meta's dashboard will not let users
  /// register, so this may be refused; the Graph API Explorer token is the
  /// documented route. Meta's desktop guidance is `response_type=token`,
  /// which puts the user token in the fragment; a pasted `code` is exchanged
  /// as a fallback.
  Future<String> _browserLogin(String appId, String appSecret, List<String> scopes, AdapterContext ctx) async {
    final broker = ctx.broker;
    if (broker == null) {
      throw const ConnectException(
          'Paste a user access token from the Graph API Explorer (steps 4 and 5); browser sign-in is not available '
          'here.',
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
      throw ConnectException('${_sentence('Facebook refused the sign-in: $why')} $_useTokenHint');
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

  /// Permissions without which NEFORUM cannot list Pages or post
  /// (`pages_manage_posts` depends on the other two, permissions reference).
  static const List<String> requiredPermissions = ['pages_show_list', 'pages_read_engagement', 'pages_manage_posts'];

  /// Reads `GET /me/permissions` and fails early, with a fix, when a
  /// required permission was not granted. Best effort: when Facebook does not
  /// answer, the publish-time error mapping still catches it.
  Future<void> _checkPermissions(AdapterContext ctx, String userToken, String appSecret,
      {required bool fromExplorer}) async {
    final NeforumResponse res;
    try {
      res = await ctx.http.get(graphUri('me/permissions', withToken(const {}, userToken, appSecret)),
          throwOnError: false);
    } on Exception catch (e) {
      ctx.log.debug('Could not read the granted Facebook permissions: $e');
      return;
    }
    final data = res.jsonMap['data'];
    if (!res.ok || data is! List) return;
    final granted = {
      for (final p in data)
        if (p is Map && p['status'] == 'granted') '${p['permission']}',
    };
    final missing = requiredPermissions.where((p) => !granted.contains(p)).toList();
    if (missing.isEmpty) return;
    throw ConnectException(fromExplorer
        ? 'The token is missing ${missing.join(', ')}. In the Graph API Explorer add them under Permissions, click '
            'Generate Access Token again, allow everything and select your Page. If one is not in the Explorer\'s '
            'list, it is not added to your app yet: add it under Use cases > Customize first.'
        : 'Facebook did not grant ${missing.join(', ')}. Make sure they are added to your app '
            '(Use cases > Customize), connect again and keep every permission switched on.',
        field: fromExplorer ? secUserToken : null);
  }

  /// Fields read for each Page in `GET /me/accounts`; `username` and `link`
  /// let the Page field match a Page by its web address.
  static const String pageFields = 'id,name,access_token,tasks,link,username';

  Future<List<FacebookPage>> _listPages(AdapterContext ctx, String userToken, String appSecret) async {
    final pages = <FacebookPage>[];
    Uri? next = graphUri('me/accounts', withToken({'fields': pageFields, 'limit': '100'}, userToken, appSecret));
    var guard = 0;
    while (next != null && guard++ < 10) {
      final NeforumResponse res;
      try {
        res = await ctx.http.get(next);
      } on HttpFailure catch (f) {
        final err = GraphError.parse(f.response.jsonMap);
        // "(#100) Tried accessing nonexisting field (accounts) on node type (Page)".
        if (err != null && err.code == 100 && err.message.contains('(Page)')) {
          throw const ConnectException(
              'This is a Page access token; NEFORUM needs a User token and finds your Pages itself. In the Graph API '
              'Explorer don\'t pick a Page under "User or Page" (choose User Token if it is listed), click Generate '
              'Access Token and paste that token.',
              field: secUserToken);
        }
        rethrow;
      }
      final json = res.jsonMap;
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
          'through the API). In the Generate Access Token pop-up (or the Facebook sign-in dialog) make sure you pick '
          'your Page(s), and that your role on the Page includes creating content.');
    }
    final w = (wanted ?? '').trim();
    if (w.isNotEmpty) {
      // Name, username, id or a pasted Page address; ids first, then
      // usernames (also read from the Page's link), then names.
      final key = facebookPageKey(w).toLowerCase();
      bool sameText(String? a, String b) => a != null && a.toLowerCase() == b;
      final match = [
        ...pages.where((p) => p.id == key),
        ...pages.where((p) => sameText(p.username, key) || (p.link != null && sameText(facebookPageKey(p.link!), key))),
        ...pages.where((p) => sameText(p.name, w.toLowerCase()) || sameText(p.name, key)),
      ];
      if (match.isEmpty) {
        final list = pages.map((p) => '${p.name} (${[if (p.username != null) p.username, p.id].join(', ')})').join('; ');
        throw ConnectException(
            'No Page matches "$w". Enter a Page name, username, ID or link, or leave the field empty. Your Pages: $list',
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

  /// Graph's answer when a token belongs to another Meta app, typically a
  /// Graph API Explorer token made while the Explorer's **Meta App** showed a
  /// different app: `The access token does not belong to application <id>`
  /// (error 1, from the `fb_exchange_token` call).
  static bool isWrongAppError(GraphError err) => err.message.toLowerCase().contains('does not belong to application');

  /// Explains a token made for another Meta app without blaming the App ID or
  /// App Secret. [tokenApp] is what `debug_token` said about the token, when
  /// it answered.
  static String wrongAppMessage(String appId, GraphError err, FacebookTokenApp? tokenApp) {
    final fix = 'In the Graph API Explorer set Meta App to the app whose App ID is $appId, click Generate Access '
        'Token again and paste the new token.';
    if (tokenApp != null && tokenApp.appId != appId) {
      final which = tokenApp.name == null ? 'App ID ${tokenApp.appId}' : '"${tokenApp.name}" (App ID ${tokenApp.appId})';
      return 'This token was made for a different Meta app, $which. The App ID you entered is $appId. $fix '
          '(Facebook said: ${err.display})';
    }
    return 'This token was made for a different Meta app. $fix The App ID and App Secret can stay as they are. '
        '(Facebook said: ${err.display})';
  }

  /// Asks `GET /debug_token` which app [token] belongs to, so the error can
  /// name it. Tries the app's own access token (`<app id>|<app secret>`)
  /// first and then the token itself, since Meta may refuse to describe
  /// another app's token to this app. Best effort: `null` when neither works.
  Future<FacebookTokenApp?> _tokenApp(AdapterContext ctx, String token, String appId, String appSecret) async {
    for (final caller in ['$appId|$appSecret', token]) {
      try {
        final res = await ctx.http.get(graphUri('debug_token', {'input_token': token, 'access_token': caller}),
            throwOnError: false);
        final data = res.jsonMap['data'];
        if (!res.ok || data is! Map) continue;
        final info = Map<String, dynamic>.from(data);
        final id = optString(info, 'app_id');
        if (id != null) return FacebookTokenApp(id, optString(info, 'application'));
      } on Exception catch (e) {
        ctx.log.debug('Facebook debug_token failed: $e');
      }
    }
    return null;
  }

  static String _connectMessage(HttpFailure f, String appId) {
    final err = GraphError.parse(f.response.jsonMap);
    if (err == null) return 'Facebook returned HTTP ${f.statusCode} while connecting';
    if (isWrongAppError(err)) return wrongAppMessage(appId, err, null);
    if (err.code == 101 || err.code == 1) {
      return 'Facebook rejected the App ID/App Secret: ${err.display}. Copy both again from App settings > Basic '
          '(click Show for the secret).';
    }
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
    final link = (variant.link ?? '').trim();
    if (variant.media.isNotEmpty && link.isNotEmpty && !_textHasLink(variant.text, link)) {
      issues.add(const ValidationIssue.info('link.in_caption',
          'Photo and video posts cannot carry a link preview on Facebook; the link is added to the text.',
          field: 'link'));
    }
    final at = variant.scheduledAt;
    if (at != null) {
      final issue = scheduleIssue(at, isVideo: _isVideoPost(variant), now: DateTime.now());
      if (issue != null) issues.add(issue);
    }
    return issues;
  }

  /// Whether Facebook can hold a post for [at]. `null` when it can, or when
  /// [at] is already due (the post is then simply published now).
  static ValidationIssue? scheduleIssue(DateTime at, {required bool isVideo, required DateTime now}) {
    if (!at.isAfter(now)) return null;
    final minLead = minScheduleLead + scheduleLeadMargin;
    if (at.isBefore(now.add(minLead))) {
      return ValidationIssue.error(
          'schedule.too_soon',
          'Facebook can hold a post only when it is at least ${minLead.inMinutes} minutes ahead '
              '(Facebook\'s minimum is ${minScheduleLead.inMinutes}); NEFORUM schedules this one itself.',
          field: 'scheduledAt');
    }
    final max = isVideo ? maxScheduleVideo : maxScheduleFeed;
    if (at.isAfter(now.add(max))) {
      return ValidationIssue.error(
          'schedule.too_far',
          'Facebook holds ${isVideo ? 'videos up to 6 months' : 'posts up to 30 days'} ahead; '
              'NEFORUM schedules this one itself.',
          field: 'scheduledAt');
    }
    return null;
  }

  static bool _isVideoPost(PostVariant v) => v.media.any((m) => m.isVideo);

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
      final hold = _holdUntil(variant, ctx);
      final schedule = hold == null ? const <String, String>{} : _scheduleFields(hold);
      final text = variant.isThread ? variant.threadParts.join('\n\n') : variant.text;

      final videos = variant.media.where((m) => m.isVideo).toList();
      final images = variant.media.where((m) => m.isImage).toList();
      final _Posted posted;
      if (videos.isNotEmpty) {
        if (images.isNotEmpty || videos.length > 1) {
          return PublishResult.failure(const PublishError.validation('Facebook posts take one video and no photos alongside it.'));
        }
        posted = await _publishVideo(call, videos.single, variant, _withLink(text, variant.link), schedule);
      } else if (images.length == 1) {
        posted = await _publishSinglePhoto(call, images.single, _withLink(text, variant.link), schedule);
      } else if (images.length > 1) {
        posted = await _publishMultiPhoto(call, images, _withLink(text, variant.link), schedule);
      } else {
        posted = await _publishFeed(call, text, variant.link, schedule);
      }
      if (hold != null) {
        return PublishResult.scheduled(remoteId: posted.id, scheduledFor: hold, remoteUrl: posted.url);
      }
      return PublishResult.ok(remoteId: posted.id, remoteUrl: posted.url, publishedAt: ctx.now());
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

  Future<_Posted> _publishFeed(_PageCall call, String text, String? link, Map<String, String> schedule) async {
    call.ctx.progress('Posting to Facebook');
    final json = await call.form('feed', {
      if (text.trim().isNotEmpty) 'message': text,
      if (link != null && link.trim().isNotEmpty) 'link': link.trim(),
      ...schedule,
    });
    return _Posted.post(requireString(json, 'id', 'a post id'));
  }

  /// One photo: the post id when Facebook returns it (it is what a scheduled
  /// post is deleted by), else the photo id, which is deletable too.
  Future<_Posted> _publishSinglePhoto(
      _PageCall call, MediaAttachment image, String caption, Map<String, String> schedule) async {
    call.ctx.progress('Uploading image 1 of 1');
    final json = await call.upload('photos', {
      if (caption.trim().isNotEmpty) 'caption': caption,
      ..._altText(image),
      ...schedule,
    }, image, await _read(call.ctx, image));
    final postId = optString(json, 'post_id');
    if (postId != null) return _Posted.post(postId);
    final photoId = requireString(json, 'id', 'a photo id');
    return _Posted(photoId, 'https://www.facebook.com/$photoId');
  }

  Future<_Posted> _publishMultiPhoto(
      _PageCall call, List<MediaAttachment> images, String message, Map<String, String> schedule) async {
    final scheduled = schedule.isNotEmpty;
    final ids = <String>[];
    for (var i = 0; i < images.length; i++) {
      call.ctx.progress('Uploading image ${i + 1} of ${images.length}');
      final json = await call.upload('photos', {
        'published': 'false',
        // Page photos reference: "If the photo is used in a scheduled post,
        // temporary=true must be used."
        if (scheduled) 'temporary': 'true',
        ..._altText(images[i]),
      }, images[i], await _read(call.ctx, images[i]));
      ids.add(requireString(json, 'id', 'a photo id'));
    }
    call.ctx.progress('Creating the Facebook post');
    // Scheduled multi-photo posts need published, scheduled_publish_time and
    // unpublished_content_type together (Page photos reference).
    final json = await call.form('feed', {
      if (message.trim().isNotEmpty) 'message': message,
      for (var i = 0; i < ids.length; i++) 'attached_media[$i]': '{"media_fbid":"${ids[i]}"}',
      ...schedule,
      if (scheduled) 'unpublished_content_type': 'SCHEDULED',
    });
    return _Posted.post(requireString(json, 'id', 'a post id'));
  }

  Future<_Posted> _publishVideo(_PageCall call, MediaAttachment video, PostVariant variant, String description,
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
    return _Posted(id, 'https://www.facebook.com/${call.pageId}/videos/$id');
  }

  /// The time Facebook should hold the post until, or `null` to publish now
  /// (no schedule, or one that is already due). Throws a validation error
  /// when Facebook would refuse the time.
  DateTime? _holdUntil(PostVariant v, AdapterContext ctx) {
    final at = v.scheduledAt;
    if (at == null) return null;
    final now = ctx.now();
    if (!at.isAfter(now)) return null;
    if (at.isBefore(now.add(minScheduleLead))) {
      throw AdapterException(PublishError.validation(
          'Facebook can only schedule posts at least ${minScheduleLead.inMinutes} minutes ahead.'));
    }
    final video = _isVideoPost(v);
    if (at.isAfter(now.add(video ? maxScheduleVideo : maxScheduleFeed))) {
      throw AdapterException(PublishError.validation(
          'Facebook schedules ${video ? 'videos up to 6 months' : 'posts up to 30 days'} ahead.'));
    }
    return at;
  }

  /// `published=false` + `scheduled_publish_time` (UNIX seconds), accepted
  /// by /feed, /photos and /videos.
  static Map<String, String> _scheduleFields(DateTime at) => {
        'published': 'false',
        'scheduled_publish_time': '${at.toUtc().millisecondsSinceEpoch ~/ 1000}',
      };

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

  // ---------------------------------------------------------------------
  // server-side scheduling
  // ---------------------------------------------------------------------

  /// Deletes the scheduled post, photo or video [held] points at
  /// (`DELETE /{id}` with the Page token, Pages API posts guide). A post
  /// that no longer exists (HTTP 404, or Graph error 100/33 "Object ...
  /// does not exist") counts as removed.
  @override
  Future<void> cancelScheduled(
      PublishResult held, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.byokApi) {
      throw const AdapterException(PublishError.unsupported('This Facebook account is set up for hand-off only.'));
    }
    final id = (held.remoteId ?? '').trim();
    if (id.isEmpty) {
      throw const AdapterException(PublishError.platform(
          'NEFORUM did not record which Facebook post is scheduled; delete it in Meta Business Suite > Planner.'));
    }
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) {
      throw const AdapterException(PublishError.auth('No Facebook Page token stored; reconnect the account.'));
    }
    final NeforumResponse res;
    try {
      ctx.progress('Removing the post Facebook is holding');
      res = await ctx.http.delete(graphUri(id, withToken(const {}, tokens.accessToken, secrets[secAppSecret])),
          throwOnError: false);
    } on TimeoutException catch (e) {
      throw AdapterException(PublishError.network('Facebook did not answer in time', raw: '$e'));
    } on Exception catch (e) {
      throw AdapterException(PublishError.network('Could not reach Facebook: $e', raw: '$e'));
    }
    if (res.ok) {
      if (res.jsonMap['success'] == false) {
        throw AdapterException(PublishError.platform('Facebook did not delete the scheduled post', raw: res.body));
      }
      return;
    }
    if (res.statusCode == 404) return;
    final err = GraphError.parse(res.jsonMap);
    if (err != null && err.code == 100 && err.subcode == 33) return;
    throw AdapterException(mapGraphFailure(HttpFailure(res), context: 'Removing the scheduled post'));
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

/// What a publishing call created: the id to report (and to delete a held
/// post by) and its public address.
class _Posted {
  const _Posted(this.id, this.url);

  /// A `{page-id}_{post-id}` Page post id.
  factory _Posted.post(String postId) {
    final parts = postId.split('_');
    return _Posted(
      postId,
      parts.length == 2
          ? 'https://www.facebook.com/${parts[0]}/posts/${parts[1]}'
          : 'https://www.facebook.com/$postId',
    );
  }

  final String id;
  final String url;
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
