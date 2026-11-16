import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:uuid/uuid.dart';

import '../../auth/auth_broker.dart';
import '../../auth/oauth2_pkce.dart';
import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../model/account.dart';
import '../../model/media.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../../text/rules_validator.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'pinterest_api.dart';
import 'pinterest_descriptor.dart';

/// Pinterest: creates Pins on one of the user's boards through API v5 with
/// the user's own developer app (BYOK), or hands the Pin to Pinterest's app /
/// Pin builder.
///
/// Images are sent inline as base64, so no media host is needed. Videos go
/// through Pinterest's register / S3 upload / poll flow.
class PinterestAdapter extends PlatformAdapter {
  PinterestAdapter({
    this.videoPollInterval = const Duration(seconds: 5),
    this.videoPollAttempts = 60,
    this.refreshLeeway = const Duration(days: 3),
    this.renewAfter = const Duration(days: 7),
  });

  /// Delay between `GET /v5/media/{id}` status checks.
  final Duration videoPollInterval;

  /// Status checks before giving up (default: 5 minutes).
  final int videoPollAttempts;

  /// Refresh the 30-day access token this long before it expires. Every
  /// refresh also renews the 60-day continuous refresh token.
  final Duration refreshLeeway;

  /// A post also renews when the last renewal is older than this. Pinterest's
  /// 60 days run from the last renewal, not the last use, so with [refreshLeeway]
  /// alone a post on day 26 renewed nothing and a post on day 61 failed after
  /// only 35 quiet days.
  final Duration renewAfter;

  // Config keys (non-secret).
  static const cfgAppId = 'appId';
  static const cfgBoardId = 'boardId';
  static const cfgBoardName = 'boardName';
  static const cfgUsername = 'username';
  static const cfgAccountType = 'accountType';
  static const cfgAccessLevel = 'accessLevel';
  static const cfgRedirectUri = 'redirectUri';

  // Secret keys (besides OAuthTokens' own).
  static const secretAppSecret = 'app_secret';
  static const secretRefreshExpiresAt = 'refresh_expires_at';

  // PostVariant.extra keys.
  static const extraBoardId = 'pinterestBoardId';
  static const extraBoardSectionId = 'pinterestBoardSectionId';
  static const extraCoverImageUrl = 'pinterestCoverImageUrl';
  static const extraCoverKeyFrame = 'pinterestCoverKeyFrameSeconds';
  static const extraMediaUrl = 'pinterestMediaUrl';

  static const accessTrial = 'trial';
  static const accessStandard = 'standard';

  /// Which Pinterest host the account's token belongs to. Accounts saved
  /// before 1.4.4 have no value and are production.
  static const cfgEnvironment = 'environment';
  static const envProduction = 'production';
  static const envSandbox = 'sandbox';

  /// How the account signed in: absent for the browser (OAuth), [authSandboxToken]
  /// for a token pasted from the app page. `token` is one of the typed sign-in
  /// methods, so a reconnect asks for a new token instead of opening the browser.
  static const cfgAuthMethod = 'authMethod';
  static const authSandboxToken = 'token';

  /// The board a sandbox account creates when the person named none, or named
  /// one by id or address (production boards do not exist in the sandbox).
  static const sandboxBoardName = 'NEFORUM';

  /// The account's calls go to Pinterest's API Sandbox.
  static bool isSandbox(ConnectedAccount account) => account.configString(cfgEnvironment) == envSandbox;

  /// The account holds a sandbox token pasted from the app page (30 days, no
  /// renewal).
  static bool usesSandboxToken(ConnectedAccount account) => account.configString(cfgAuthMethod) == authSandboxToken;

  /// The account was connected as a Trial app (the default for an unknown level).
  static bool isTrial(ConnectedAccount account) => account.configString(cfgAccessLevel, accessTrial) == accessTrial;

  /// Saved as Trial before 1.4.4, so its token is a production one. Pinterest
  /// no longer lets a Trial app create Pins there (code 29), so a reconnect
  /// moves it to the sandbox.
  static bool movesToSandbox(ConnectedAccount account) =>
      account.tier == PlatformTier.byokApi && account.config[cfgAccessLevel] == accessTrial && account.config[cfgEnvironment] == null;

  @override
  SignInPolicy signInPolicyFor(ConnectedAccount account) => SignInPolicies.pinterestFor(account);

  /// The same board, and the loopback host the person registered, read back
  /// from the address the first sign-in used.
  @override
  Map<String, String> get reconnectFieldSources => const {'board': cfgBoardId};

  @override
  Map<String, String>? reconnectInput(ConnectedAccount account, Map<String, String> secrets, {Uri? redirect}) {
    final out = super.reconnectInput(account, secrets, redirect: redirect);
    if (out == null) return null;
    final host = Uri.tryParse(account.configString(cfgRedirectUri))?.host;
    if (host == 'localhost' || host == '127.0.0.1') out['redirectHost'] = host!;
    // A production board id means nothing in the sandbox: its name finds or
    // makes the sandbox board.
    final name = account.configString(cfgBoardName).trim();
    if (movesToSandbox(account) && name.isNotEmpty) out['board'] = name;
    return out;
  }

  /// A Trial account saved before 1.4.4 has a production token, which cannot
  /// create Pins. Renewing it would keep it there, so Reconnect goes on to the
  /// browser sign-in, which moves it to the sandbox.
  @override
  Future<Map<String, String>?> renewSignInNow(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (movesToSandbox(account)) throw const AdapterException(PublishError.auth(_moveToSandboxMessage));
    if (usesSandboxToken(account)) {
      throw const AdapterException(PublishError.auth(
          'A pasted Pinterest sandbox token cannot be renewed. Generate a new one on your app\'s page (Configure > '
          'Generate access token, Sandbox) and paste it when you reconnect Pinterest in Accounts.'));
    }
    return super.renewSignInNow(account, secrets, ctx);
  }

  @override
  PlatformDescriptor get descriptor => pinterestDescriptor;

  // ------------------------------------------------------------- connect

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.byokApi,
          usesBrowser: true,
          loopbackRedirectOk: true,
          customSchemeRedirectOk: false,
          redirectNote: 'Register exactly http://localhost:52771/callback under "Redirect URIs" (Pinterest accepts '
              'http only for localhost, and an https address never matches: NEFORUM listens on http). Pinterest '
              'does not document app links such as neforum://callback, so connect Pinterest from NEFORUM on a computer.',
          intro: _byokIntro,
          fields: [
            ConnectField(
              key: 'appId',
              label: 'App ID',
              help: 'developers.pinterest.com > **My apps** > your app > "App ID".',
              placeholder: '1234567',
            ),
            ConnectField(
              key: 'appSecret',
              label: 'App secret key (optional with a sandbox token)',
              kind: FieldKind.password,
              secret: true,
              required: false,
              help: 'Same page, "App secret key" (click **Show key**). Pinterest only shows it after it approved '
                  'Trial access. It stays on this device. Not needed when you paste a sandbox token below.',
            ),
            ConnectField(
              key: 'board',
              label: 'Board',
              required: false,
              placeholder: 'My recipes',
              help: 'Name (or id) of the board your Pins go to. Leave empty if you have only one board. With Trial '
                  'access NEFORUM makes this board in the sandbox if it is not there yet ("$sandboxBoardName" if you '
                  'leave it empty).',
            ),
            ConnectField(
              key: 'accessLevel',
              label: 'Access level of your app',
              kind: FieldKind.select,
              required: false,
              options: [accessTrial, accessStandard],
              defaultValue: accessTrial,
              help: 'As shown on your app card. **trial**: NEFORUM posts to Pinterest\'s API Sandbox, the only place '
                  'Pinterest lets Trial apps create Pins. Those are test Pins that only you can see. **standard**: '
                  'public Pins.',
            ),
            ConnectField(
              key: 'sandboxToken',
              label: 'Sandbox access token (optional)',
              kind: FieldKind.password,
              secret: true,
              required: false,
              help: 'Trial access, instead of the browser sign-in: on your app\'s page open **Configure**, find '
                  '**Generate access token**, choose **Sandbox**, click **Generate token** and paste it here the same '
                  'day. It lasts 30 days and cannot be renewed; NEFORUM warns you before it ends.',
            ),
            ConnectField(
              key: 'redirectHost',
              label: 'Redirect URI you registered',
              kind: FieldKind.select,
              required: false,
              options: ['localhost', '127.0.0.1'],
              defaultValue: 'localhost',
              help: '**localhost** = http://localhost:52771/callback, the one to register. Pinterest accepts http '
                  'only for localhost, so pick **127.0.0.1** only if your app already lists exactly '
                  'http://127.0.0.1:52771/callback. An https address never matches.',
            ),
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.handoff,
          intro: 'No setup needed. NEFORUM copies your description, opens Pinterest (app or website) with your image '
              'and link, and you pick the board and press **Save** yourself.',
          fields: [
            ConnectField(
              key: 'displayName',
              label: 'Name to show in NEFORUM',
              required: false,
              placeholder: 'My Pinterest',
            ),
          ],
        ),
      ];

  static const String _byokIntro = '''
**Create Pins on your boards automatically.** You need a Pinterest business account and your own (free) Pinterest developer app:

1. If your Pinterest account is personal, convert it for free: Pinterest **Settings > Account management > Convert to a business account**.
2. Go to <https://developers.pinterest.com/apps/> and click **Connect app**. Fill in the app name (e.g. "NEFORUM for <your name>"), a short description, a website and a privacy-policy link.
3. In **Redirect URIs** add exactly `http://localhost:52771/callback`. Use `http` (Pinterest accepts http only for localhost), not `https` and not `127.0.0.1`: Pinterest compares the address character for character. Do it now: Pinterest locks redirect URIs while it reviews the app.
4. Submit and wait until Pinterest approves **Trial access** (reviewed on business days; it can take a week or more). The app secret appears only after approval.
5. Copy the **App ID** and **App secret key** into the fields below, type the board to post to, keep Access level **trial**, click Connect and allow every permission in the browser (boards, Pins, account).

**Trial access means test Pins only.** Pinterest lets Trial apps create Pins only in its API Sandbox: those Pins are visible to you alone, on your own profile, and video Pins are not possible there. Instead of step 5's browser sign-in you can paste a sandbox token (app page > **Configure** > **Generate access token** > **Sandbox**); it lasts 30 days. For public Pins, click **Upgrade** on your app card and send Pinterest a screen recording of NEFORUM connecting and creating a Pin (Standard access review), then reconnect with Access level **standard**.''';

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier == PlatformTier.handoff) {
      final name = (input['displayName'] ?? '').trim();
      return ConnectResult(
        account: ConnectedAccount(
          id: 'pinterest:handoff:${const Uuid().v4()}',
          platformId: id,
          tier: PlatformTier.handoff,
          displayName: name.isEmpty ? 'Pinterest (hand-off)' : name,
          createdAt: ctx.now(),
        ),
      );
    }
    if (tier != PlatformTier.byokApi) {
      throw ConnectException('Pinterest does not support the ${tier.label} tier');
    }

    final appId = (input['appId'] ?? '').trim();
    final appSecret = (input['appSecret'] ?? '').trim();
    final boardInput = (input['board'] ?? '').trim();
    final sandboxToken = (input['sandboxToken'] ?? '').trim();
    final access = (input['accessLevel'] ?? '').trim().toLowerCase() == accessStandard ? accessStandard : accessTrial;
    if (appId.isEmpty) throw const ConnectException('Enter the App ID of your Pinterest app', field: 'appId');
    if (sandboxToken.isNotEmpty) return _connectWithSandboxToken(appId, appSecret, boardInput, access, sandboxToken, ctx);
    if (appSecret.isEmpty) {
      throw const ConnectException(
          'Enter the App secret key of your Pinterest app (it is shown once Pinterest approved Trial access), '
          'or paste a sandbox token',
          field: 'appSecret');
    }
    // Trial apps may create Pins only in the API Sandbox, and a token works
    // only on the host that made it: the code goes to the sandbox token
    // endpoint, and every later call to the sandbox.
    final sandbox = access == accessTrial;

    final AuthBroker broker;
    try {
      broker = ctx.requireBroker();
    } on StateError {
      throw const ConnectException('Connecting Pinterest needs a browser sign-in, which is not available here');
    }
    final redirect = _redirectFor(broker, specFor(PlatformTier.byokApi), input['redirectHost']);
    final client = _oauthClient(appId, appSecret, sandbox: sandbox, continuousRefresh: true);

    final OAuthTokens tokens;
    try {
      final request = client.buildAuthorizationUrl(redirectUri: redirect);
      final back = await broker.authorize(request.url, redirect);
      final code = client.extractCode(back, request);
      tokens = await client.exchangeCode(ctx.http, code: code, redirectUri: redirect, now: ctx.now());
    } on OAuthException catch (e) {
      throw ConnectException(oauthMessage(e, redirect));
    }

    final api = PinterestApi(ctx: ctx, accessToken: tokens.accessToken, sandbox: sandbox);
    final (user, board) = await _userAndBoard(api, boardInput, onUnauthorized: null);
    return ConnectResult(
      account: _account(user, board, ctx, {
        cfgAppId: appId,
        cfgAccessLevel: access,
        cfgEnvironment: sandbox ? envSandbox : envProduction,
        cfgRedirectUri: redirect.toString(),
      }),
      secrets: _secretsFrom(tokens, {secretAppSecret: appSecret}, ctx.now()),
    );
  }

  /// A sandbox token pasted from the app page's "Generate access token": no
  /// browser, no refresh token, 30 days from when it was made. NEFORUM counts
  /// them from now, marked as worked out, so the warnings come on time when
  /// the token is pasted the day it was made, as the help asks.
  Future<ConnectResult> _connectWithSandboxToken(
      String appId, String appSecret, String boardInput, String access, String token, AdapterContext ctx) async {
    final api = PinterestApi(ctx: ctx, accessToken: token, sandbox: true);
    final (user, board) = await _userAndBoard(api, boardInput,
        onUnauthorized: 'Pinterest did not accept this sandbox token. On your app\'s page open Configure > Generate '
            'access token, choose Sandbox, generate a new token and paste it. A production token does not work in '
            'the sandbox.');
    final now = ctx.now();
    return ConnectResult(
      account: _account(user, board, ctx, {
        cfgAppId: appId,
        cfgAccessLevel: access,
        cfgEnvironment: envSandbox,
        cfgAuthMethod: authSandboxToken,
      }),
      secrets: {
        OAuthTokens.keyAccessToken: token,
        OAuthTokens.keyTokenType: 'bearer',
        OAuthTokens.keyExpiresAt: now.add(PinterestApi.sandboxTokenLife).toUtc().toIso8601String(),
        SignInSecretKeys.expiresAtSource: SignInDateSource.computed.name,
        if (appSecret.isNotEmpty) secretAppSecret: appSecret,
      },
    );
  }

  /// Reads the signed-in user and picks (in the sandbox: finds or makes) the
  /// board. [onUnauthorized] replaces the message for a refused token.
  Future<(PinterestUser, PinterestBoard)> _userAndBoard(PinterestApi api, String boardInput,
      {required String? onUnauthorized}) async {
    final PinterestUser user;
    final List<PinterestBoard> boards;
    try {
      user = await api.userAccount();
      boards = await api.boards();
    } on HttpFailure catch (e) {
      if (onUnauthorized != null && e.statusCode == 401) throw ConnectException(onUnauthorized, field: 'sandboxToken');
      throw ConnectException('Signed in, but ${PinterestApi.mapFailure(e, context: 'Pinterest').message}');
    }
    if (user.username.isEmpty) throw const ConnectException('Pinterest did not return your username; try again');
    if (user.accountType != null && user.accountType != 'BUSINESS') {
      api.ctx.log.warn('Pinterest account ${user.username} is ${user.accountType}, not a business account');
    }
    return (user, api.sandbox ? await _sandboxBoard(api, boards, boardInput) : resolveBoard(boards, boardInput));
  }

  ConnectedAccount _account(PinterestUser user, PinterestBoard board, AdapterContext ctx, Map<String, Object?> config) =>
      ConnectedAccount(
        id: 'pinterest:${user.id ?? user.username}',
        platformId: id,
        tier: PlatformTier.byokApi,
        displayName: '${user.businessName?.trim().isNotEmpty == true ? user.businessName!.trim() : user.username} '
            '(${board.name})',
        handle: user.username,
        avatarUrl: user.profileImage,
        profileUrl: 'https://www.pinterest.com/${user.username}/',
        createdAt: ctx.now(),
        config: {
          ...config,
          cfgBoardId: board.id,
          cfgBoardName: board.name,
          cfgUsername: user.username,
          if (user.accountType != null) cfgAccountType: user.accountType,
        },
      );

  /// The sandbox board: one that matches [input], else a new one. Pinterest
  /// leaves production boards out of the sandbox's board list, so a first
  /// sandbox sign-in usually finds none.
  static Future<PinterestBoard> _sandboxBoard(PinterestApi api, List<PinterestBoard> boards, String input) async {
    if (input.isEmpty && boards.length > 1) return resolveBoard(boards, input); // asks which, listing them
    if (input.isEmpty && boards.length == 1) return boards.single;
    if (input.isNotEmpty) {
      final found = findBoard(boards, input);
      if (found != null) return found;
    }
    final name = sandboxBoardNameFor(input);
    try {
      return await api.createBoard(name, description: 'Test Pins from NEFORUM (Pinterest API Sandbox)');
    } on HttpFailure catch (e) {
      throw ConnectException(
          'Signed in, but Pinterest would not make the sandbox board "$name" (${PinterestApi.mapFailure(e, context: 'Pinterest').message})',
          field: 'board');
    }
  }

  /// The name for a new sandbox board: what the person typed, unless that was
  /// a production board's id or address, which name nothing in the sandbox.
  static String sandboxBoardNameFor(String input) {
    final t = input.trim();
    if (t.isEmpty || RegExp(r'^\d+$').hasMatch(t) || (Uri.tryParse(t)?.hasScheme ?? false)) return sandboxBoardName;
    return t;
  }

  /// Uses the broker's redirect, but swaps the loopback host to the one the
  /// user registered (Pinterest matches redirect URIs exactly and its own
  /// samples use `localhost`).
  static Uri _redirectFor(AuthBroker broker, ConnectSpec spec, String? host) {
    final r = broker.chooseRedirectUri(
      loopbackOk: spec.loopbackRedirectOk,
      customSchemeOk: spec.customSchemeRedirectOk,
      fixed: spec.fixedRedirectUri,
    );
    final loopback = r.scheme == 'http' && (r.host == '127.0.0.1' || r.host == 'localhost');
    if (!loopback) return r;
    return r.replace(host: (host ?? '').trim() == '127.0.0.1' ? '127.0.0.1' : 'localhost');
  }

  /// Picks the board matching [input] (id, name, or the last segment of a
  /// board URL). An empty input is fine when the user has exactly one board.
  static PinterestBoard resolveBoard(List<PinterestBoard> boards, String input) {
    if (boards.isEmpty) {
      throw const ConnectException('Your Pinterest account has no boards yet. Create one on pinterest.com, then connect again.',
          field: 'board');
    }
    final names = boards.take(10).map((b) => '"${b.name}"').join(', ');
    if (input.isEmpty) {
      if (boards.length == 1) return boards.single;
      throw ConnectException('Type the board to post to. Your boards: $names', field: 'board');
    }
    final found = findBoard(boards, input);
    if (found != null) return found;
    throw ConnectException('No board called "$input". Your boards: $names', field: 'board');
  }

  /// The board [input] names (id, name, or the last segment of a board URL),
  /// or null.
  static PinterestBoard? findBoard(List<PinterestBoard> boards, String input) {
    var wanted = input;
    final asUri = Uri.tryParse(input);
    if (asUri != null && asUri.hasScheme && asUri.pathSegments.where((s) => s.isNotEmpty).isNotEmpty) {
      wanted = Uri.decodeComponent(asUri.pathSegments.where((s) => s.isNotEmpty).last);
    }
    for (final b in boards) {
      if (b.id == wanted) return b;
    }
    final lower = wanted.toLowerCase();
    for (final b in boards) {
      if (b.name.toLowerCase() == lower) return b;
    }
    final slug = _slug(wanted);
    for (final b in boards) {
      if (_slug(b.name) == slug) return b;
    }
    return null;
  }

  /// Board URL slug: Pinterest drops apostrophes ("Mom's Recipes" ->
  /// `moms-recipes`) and joins the remaining words with dashes.
  static String _slug(String s) => s
      .toLowerCase()
      .replaceAll(RegExp('[\'’]'), '')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  /// [continuousRefresh] asks for a continuous (60-day, renewable) refresh
  /// token. It is only a code-exchange parameter.
  ///
  /// [sandbox]: the token endpoint on `api-sandbox.pinterest.com`, which makes
  /// and renews sandbox tokens. The consent page is the same for both.
  static OAuth2Client _oauthClient(String appId, String appSecret, {required bool sandbox, bool continuousRefresh = false}) => OAuth2Client(
        authorizationEndpoint: PinterestApi.authorizationEndpoint,
        tokenEndpoint: PinterestApi.tokenEndpointFor(sandbox: sandbox),
        clientId: appId,
        clientSecret: appSecret,
        scopes: PinterestApi.scopes,
        scopeSeparator: ',',
        // Pinterest documents no PKCE; the token call uses HTTP Basic
        // app_id:app_secret.
        usePkce: false,
        clientAuth: ClientAuth.basic,
        extraTokenParams: continuousRefresh ? const {'continuous_refresh': 'true'} : const {},
      );

  /// Stores the tokens plus the refresh-token expiry Pinterest reports.
  static Map<String, String> _secretsFrom(OAuthTokens t, Map<String, String> existing, DateTime now) {
    final out = t.toSecrets(existing);
    final at = t.raw['refresh_token_expires_at'];
    final inSecs = t.raw['refresh_token_expires_in'];
    DateTime? refreshExpiry;
    if (at is int) {
      refreshExpiry = DateTime.fromMillisecondsSinceEpoch(at * 1000, isUtc: true);
    } else if (inSecs is int) {
      refreshExpiry = now.add(Duration(seconds: inSecs));
    }
    if (refreshExpiry != null) {
      out[secretRefreshExpiresAt] = refreshExpiry.toUtc().toIso8601String();
      out[SignInSecretKeys.refreshExpiresSource] = SignInDateSource.serverReported.name;
    } else {
      // Pinterest's refresh response table omits the field (its example has
      // it). A date left over from before this renewal would refuse a token
      // that works, so the documented 60 days stand in, marked as worked out.
      out[secretRefreshExpiresAt] = now.add(SignInPolicies.pinterestRefreshLife).toUtc().toIso8601String();
      out[SignInSecretKeys.refreshExpiresSource] = SignInDateSource.computed.name;
    }
    return out;
  }

  /// What a refused sign-in means, in words the person can act on.
  static String oauthMessage(OAuthException e, Uri redirect) {
    final d = '${e.error ?? ''} ${e.description ?? ''}'.toLowerCase();
    if (d.contains('redirect')) {
      final https = redirect.replace(scheme: 'https');
      final localhost = redirect.replace(host: 'localhost');
      final fix = redirect.host == 'localhost'
          ? 'add $redirect there (Pinterest accepts http for localhost)'
          : 'add $localhost there (Pinterest accepts http only for localhost) and choose "localhost" below';
      return 'Pinterest says the redirect URI does not match the one registered in your app. NEFORUM sent exactly '
          '$redirect. Pinterest compares every character, so $https (https instead of http) does not match, nor '
          'does 127.0.0.1 in place of localhost. On developers.pinterest.com open your app > Configure > Redirect '
          'URIs, $fix, and try again.';
    }
    if (d.contains('scope')) {
      return 'Pinterest refused a permission. Connect again and allow every permission NEFORUM asks for.';
    }
    if (d.contains('client') || d.contains('unauthorized') || d.contains('401')) {
      return 'Pinterest did not accept the App ID / App secret key. Copy both again from developers.pinterest.com/apps.';
    }
    final detail = [e.error, e.description].whereType<String>().where((s) => s.isNotEmpty).join(': ');
    return 'Pinterest sign-in failed${detail.isEmpty ? '' : ' ($detail)'}';
  }

  // ------------------------------------------------------------- refresh

  @override
  Future<Map<String, String>?> refreshSecrets(
      ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.byokApi) return null;
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) throw const AdapterException(PublishError.auth(_reconnectMessage));
    final now = ctx.now();
    // A pasted sandbox token has nothing to renew it with: it works until its
    // 30 days are up, and then only a new one helps.
    if (usesSandboxToken(account)) {
      if (tokens.isExpired(now: now, leeway: Duration.zero)) throw const AdapterException(PublishError.auth(_sandboxTokenEndedMessage));
      return null;
    }
    final due = tokens.isExpired(now: now, leeway: refreshLeeway);
    if (!due && !_renewalIsOld(secrets, tokens, now)) return null;

    final refresh = tokens.refreshToken;
    final appSecret = secrets[secretAppSecret];
    final appId = account.configString(cfgAppId);
    final refreshExpiry = DateTime.tryParse(secrets[secretRefreshExpiresAt] ?? '');
    if (refresh == null || refresh.isEmpty || appSecret == null || appSecret.isEmpty || appId.isEmpty) {
      if (!due) return null;
      throw const AdapterException(PublishError.auth(_expiredMessage));
    }
    if (refreshExpiry != null && !now.isBefore(refreshExpiry)) {
      if (!due) return null;
      throw const AdapterException(PublishError.auth(_expiredMessage));
    }
    try {
      final fresh = await _oauthClient(appId, appSecret, sandbox: isSandbox(account)).refresh(ctx.http, refreshToken: refresh, now: now);
      return _secretsFrom(fresh, secrets, now);
    } on OAuthException catch (e) {
      // The access token still works: an early renewal never costs the post.
      if (!due) {
        ctx.log.warn('The early Pinterest renewal failed; the current token still works (${e.statusCode})');
        return null;
      }
      // Rejected grant -> reconnect; 429 -> quota; outages -> retry later.
      final err = e.toRefreshError('Pinterest');
      if (err.kind == PublishErrorKind.auth) {
        throw AdapterException(PublishError.auth(_expiredMessage, raw: e.toString(), statusCode: e.statusCode));
      }
      throw AdapterException(err);
    } on Exception catch (e) {
      if (due) rethrow;
      ctx.log.warn('The early Pinterest renewal failed; the current token still works (${e.runtimeType})');
      return null;
    }
  }

  /// When the last renewal happened: recorded since 1.4, else 30 days before
  /// the access token ends. Unknown counts as old.
  bool _renewalIsOld(Map<String, String> secrets, OAuthTokens tokens, DateTime now) {
    final last = DateTime.tryParse(secrets[SignInSecretKeys.lastRenewedAt] ?? '') ?? tokens.expiresAt?.subtract(const Duration(days: 30));
    return last == null || now.difference(last) > renewAfter;
  }

  static const String _expiredMessage =
      'Your Pinterest sign-in has expired (it lapses 60 days after its last renewal). Reconnect Pinterest in Accounts.';
  static const String _reconnectMessage = 'Pinterest is not signed in. Reconnect Pinterest in Accounts.';
  static const String _sandboxTokenEndedMessage =
      'Your Pinterest sandbox token has run out (they last 30 days). On developers.pinterest.com open your app > '
      'Configure > Generate access token, choose Sandbox, generate a new token and paste it when you reconnect '
      'Pinterest in Accounts.';
  static const String _moveToSandboxMessage =
      'Pinterest lets apps with Trial access create Pins only in its API Sandbox, and this account still signs in '
      'to production. Sign in again to move it to the sandbox. ${PinterestApi.sandboxPinsNote}';

  // ------------------------------------------------------------ validate

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = RulesValidator.validate(variant, descriptor, tier: account.tier);

    if (variant.isThread) {
      issues.add(const ValidationIssue.error(
          'thread.unsupported', 'Pinterest has no threads; shorten the description to 800 characters', field: 'text'));
    }

    if (account.tier == PlatformTier.byokApi) {
      final board = variant.extraAs<String>(extraBoardId) ?? account.configString(cfgBoardId);
      if (board.trim().isEmpty) {
        issues.add(const ValidationIssue.error(
            'pinterest.no_board', 'No Pinterest board chosen; reconnect Pinterest and pick a board', field: 'account'));
      }
      // PinCreate.board_id / board_section_id: pattern ^\d+$.
      for (final key in const [extraBoardId, extraBoardSectionId]) {
        final v = variant.extraAs<String>(key)?.trim() ?? '';
        if (v.isNotEmpty && !RegExp(r'^\d+$').hasMatch(v)) {
          issues.add(ValidationIssue.error('pinterest.bad_id', '$key must be a numeric Pinterest id, not "$v"',
              field: 'account'));
        }
      }
      if (isSandbox(account)) {
        issues.add(const ValidationIssue.warning('pinterest.trial_private',
            'This Pinterest account posts to Pinterest\'s API Sandbox (Trial access). ${PinterestApi.sandboxPinsNote}',
            field: 'account'));
        if (variant.media.any((m) => m.isVideo)) {
          issues.add(const ValidationIssue.error('pinterest.sandbox_video',
              'Pinterest\'s API Sandbox cannot make video Pins. Post a photo, or get Standard access for video Pins',
              field: 'media'));
        }
      } else if (isTrial(account)) {
        issues.add(const ValidationIssue.warning('pinterest.trial_private',
            'Your Pinterest app has Trial access, and Pinterest lets Trial apps create Pins only in its API Sandbox. '
            'If this Pin is refused, reconnect Pinterest to move the account there. ${PinterestApi.sandboxPinsNote}',
            field: 'account'));
      }
    } else if (account.tier == PlatformTier.handoff &&
        variant.text.characters.length > PinterestLimits.handoffDescriptionMax) {
      issues.add(const ValidationIssue.warning('pinterest.handoff_description',
          'Pinterest\'s website prefills only 500 characters of description; the full text is on the clipboard',
          field: 'text'));
    }

    final link = variant.link?.trim() ?? '';
    if (link.isNotEmpty) {
      final u = Uri.tryParse(link);
      if (u == null || !(u.isScheme('http') || u.isScheme('https')) || u.host.isEmpty) {
        issues.add(const ValidationIssue.error('link.invalid', 'The Pin link must be a web address (https://...)',
            field: 'link'));
      } else if (link.length > PinterestLimits.linkMax) {
        issues.add(const ValidationIssue.error('link.too_long', 'Pinterest links can be at most 2048 characters',
            field: 'link'));
      }
    }

    final images = variant.media.where((m) => m.isImage).toList();
    for (final m in variant.media) {
      if ((m.altText ?? '').length > PinterestLimits.altTextMax) {
        issues.add(ValidationIssue.error(
            'media.alt_too_long', 'Alt text of ${m.fileName ?? m.id} is longer than Pinterest\'s 500 characters',
            field: 'media'));
      }
      if (m.isVideo && m.durationMs != null && m.durationMs! < PinterestLimits.videoMinSeconds * 1000) {
        issues.add(const ValidationIssue.error(
            'media.video_too_short', 'Pinterest videos must be at least 4 seconds long', field: 'media'));
      }
    }
    if (images.length > 1 && images.any((m) => (m.altText ?? '').isNotEmpty)) {
      issues.add(const ValidationIssue.info('pinterest.carousel_alt',
          'Pinterest takes alt text only for single-image Pins; carousel alt text is not sent', field: 'media'));
    }
    if (variant.visibility == Visibility.private || variant.visibility == Visibility.followers) {
      issues.add(const ValidationIssue.warning('visibility.board',
          'Pinterest has no per-Pin visibility; anyone who can see the board will see this Pin', field: 'visibility'));
    }
    return issues;
  }

  // ------------------------------------------------------------- publish

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    try {
      return await _publish(variant, account, secrets, ctx);
    } on AdapterException catch (e) {
      return PublishResult.failure(e.error);
    } on HttpFailure catch (e) {
      return PublishResult.failure(PinterestApi.mapFailure(e, context: 'Posting to Pinterest', trialAccess: isTrial(account)));
    } on Error {
      rethrow; // programming errors only
    } on Object catch (e) {
      ctx.log.warn('Pinterest publish failed: $e');
      final text = e.toString();
      if (NeforumHttp.isTransportError(e)) {
        return PublishResult.failure(PublishError.network('Could not reach Pinterest (${NeforumHttp.transportMessage(e)})', raw: NeforumHttp.transportDetails(e)));
      }
      // dart:io is off limits here, so recognise file errors by name.
      if (text.startsWith('FileSystemException') || text.contains('PathNotFoundException')) {
        return PublishResult.failure(PublishError.configuration('A media file for this Pin is missing or unreadable. Re-attach it and try again.', raw: text));
      }
      return PublishResult.failure(PublishError.platform('Pinterest publish failed: $text', raw: text));
    }
  }

  Future<PublishResult> _publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier == PlatformTier.handoff) {
      return PublishResult.failure(
          const PublishError.unsupported('Hand-off Pinterest accounts are posted through the share sheet'));
    }
    if (variant.isThread) {
      return PublishResult.failure(
          const PublishError.validation('Pinterest has no threads; shorten the description to 800 characters'));
    }
    final tokens = OAuthTokens.fromSecrets(secrets);
    if (tokens == null) return PublishResult.failure(const PublishError.auth(_reconnectMessage));
    if (tokens.isExpired(now: ctx.now(), leeway: Duration.zero)) {
      return PublishResult.failure(PublishError.auth(usesSandboxToken(account) ? _sandboxTokenEndedMessage : _expiredMessage));
    }
    final boardId = (variant.extraAs<String>(extraBoardId) ?? account.configString(cfgBoardId)).trim();
    if (boardId.isEmpty) {
      return PublishResult.failure(
          const PublishError.configuration('No Pinterest board chosen; reconnect Pinterest and pick a board'));
    }

    final videos = variant.media.where((m) => m.isVideo).toList();
    final images = variant.media.where((m) => m.isImage).toList();
    if (videos.isEmpty && images.isEmpty) {
      return PublishResult.failure(const PublishError.validation('Every Pin needs an image or a video'));
    }
    if (videos.isNotEmpty && images.isNotEmpty) {
      return PublishResult.failure(const PublishError.validation('Pinterest cannot mix images and video in one Pin'));
    }
    if (videos.length > 1) {
      return PublishResult.failure(const PublishError.validation('A Pin can hold only one video'));
    }
    final sandbox = isSandbox(account);
    if (sandbox && videos.isNotEmpty) {
      // "You cannot create video Pins" (the sandbox page).
      return PublishResult.failure(const PublishError.validation(
          'Pinterest\'s API Sandbox (Trial access) cannot make video Pins. Post a photo, or get Standard access for video Pins.'));
    }
    if (images.length > PinterestLimits.maxImages) {
      return PublishResult.failure(PublishError.validation(
          '${images.length} images; a Pinterest carousel holds at most ${PinterestLimits.maxImages}'));
    }

    final api = PinterestApi(
      ctx: ctx,
      accessToken: tokens.accessToken,
      sandbox: sandbox,
      videoPollInterval: videoPollInterval,
      videoPollAttempts: videoPollAttempts,
    );

    final isVideo = videos.isNotEmpty;
    final Map<String, Object?> mediaSource;
    String? altText;
    if (isVideo) {
      mediaSource = await _videoSource(variant, videos.single, api);
    } else {
      final loaded = <(MediaAttachment, List<int>)>[];
      for (var i = 0; i < images.length; i++) {
        ctx.progress('Preparing image ${i + 1} of ${images.length}');
        loaded.add((images[i], await _readImage(images[i], ctx)));
      }
      if (loaded.length == 1) {
        mediaSource = PinterestApi.imageBase64Source(loaded.single.$1, loaded.single.$2);
        final alt = images.single.altText?.trim();
        if (alt != null && alt.isNotEmpty) altText = alt;
      } else {
        mediaSource = PinterestApi.multipleImageBase64Source(loaded);
      }
    }

    final title = variant.title?.trim();
    final description = variant.text.trim();
    final link = variant.link?.trim();
    final section = variant.extraAs<String>(extraBoardSectionId)?.trim();
    final body = <String, Object?>{
      'board_id': boardId,
      if (section != null && section.isNotEmpty) 'board_section_id': section,
      if (title != null && title.isNotEmpty) 'title': title,
      if (description.isNotEmpty) 'description': description,
      if (link != null && link.isNotEmpty) 'link': link,
      if (altText != null) 'alt_text': altText,
      'media_source': mediaSource,
    };

    // Inline images go up inside this one request.
    if (!isVideo) ctx.uploadingAll('Creating the Pin');
    final String pinId;
    try {
      pinId = await api.createPin(body, inlineImages: !isVideo);
    } on HttpFailure catch (e) {
      return PublishResult.failure(PinterestApi.mapFailure(e, context: 'Creating the Pin', videoPin: isVideo, trialAccess: isTrial(account)));
    }
    return PublishResult.ok(remoteId: pinId, remoteUrl: PinterestApi.pinUrl(pinId), publishedAt: ctx.now());
  }

  @override
  ProgressShape progressShape(PostVariant variant, ConnectedAccount account) =>
      ProgressShape.forVariant(variant, variant.media.any((m) => m.isVideo) ? ProgressFamily.waitNoNumber : ProgressFamily.direct, steps: 1);

  Future<Uint8List> _readImage(MediaAttachment m, AdapterContext ctx) async {
    PinterestApi.contentTypeOf(m); // throws for GIF/WebP before reading the file
    final bytes = await ctx.readMedia(m);
    if (bytes.length > PinterestLimits.imageMaxBytes) {
      throw AdapterException(PublishError.validation('${m.fileName ?? m.id} is larger than Pinterest\'s 20 MB limit'));
    }
    return bytes;
  }

  Future<Map<String, Object?>> _videoSource(PostVariant v, MediaAttachment video, PinterestApi api) async {
    final mediaId = await api.uploadVideo(video);
    final coverUrl = v.extraAs<String>(extraCoverImageUrl)?.trim();
    final keyFrame = v.extraAs<int>(extraCoverKeyFrame) ?? 1;
    return {
      'source_type': 'video_id',
      'media_id': mediaId,
      if (coverUrl != null && coverUrl.isNotEmpty)
        'cover_image_url': coverUrl
      else
        'cover_image_key_frame_time': keyFrame < 0 ? 0 : keyFrame,
    };
  }

  // ------------------------------------------------------------- hand-off

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final text = variant.text.trim();
    final title = variant.title?.trim() ?? '';
    final link = variant.link?.trim() ?? '';
    final mediaUrl = _publicMediaUrl(variant);
    final media = variant.media;

    final description = _truncate(text.isEmpty ? title : text, PinterestLimits.handoffDescriptionMax);
    final params = <String>[
      if (link.isNotEmpty) 'url=${Uri.encodeComponent(link)}',
      if (mediaUrl != null) 'media=${Uri.encodeComponent(mediaUrl)}',
      if (description.isNotEmpty) 'description=${Uri.encodeComponent(description)}',
    ];
    final webIntent = Uri.parse(
        'https://www.pinterest.com/pin/create/button/${params.isEmpty ? '' : '?${params.join('&')}'}');
    final clipboard = text.isEmpty ? title : text;
    final preferShare = media.isNotEmpty && mediaUrl == null;

    final instructions = preferShare
        ? '1. Your description is on the clipboard.\n'
            '2. In the share sheet pick **Pinterest**. On a computer NEFORUM opens the Pin creation tool: use '
            '**Save media to Downloads** and drag the image onto it.\n'
            '3. Paste the description${title.isEmpty ? '' : ', type the title'}${link.isEmpty ? '' : ' and add the link'}.\n'
            '4. Choose a board and tap **Save**.'
        : '1. Pinterest opens with your image${link.isEmpty ? '' : ', link'} and description filled in '
            '(sign in first if asked).\n'
            '2. ${title.isEmpty ? 'Check the description' : 'Add the title'}; the full description is also on the clipboard.\n'
            '3. Choose a board and click **Save**.';

    return HandoffPlan(
      platformId: id,
      instructions: instructions,
      webIntent: webIntent,
      clipboardText: clipboard,
      shareText: link.isNotEmpty ? link : clipboard,
      shareFiles: media,
      androidPackage: 'com.pinterest',
      iosScheme: 'pinterest://',
      // The old /pin-builder/ address now redirects here (checked 2026-10-12).
      desktopUrl: 'https://www.pinterest.com/pin-creation-tool/',
      preferred: preferShare ? HandoffMethod.shareSheet : HandoffMethod.webIntent,
      mediaNote: media.isEmpty
          ? null
          : mediaUrl == null
              ? 'Pinterest\'s website can only prefill an image that is already online. On a phone the image goes '
                  'through the share sheet; on a computer upload it yourself in the Pin creation tool. Pinterest treats '
                  'shared text as a link, so paste the description from the clipboard.'
              : 'Pinterest loads the image from its public web address; videos must be uploaded in the app or '
                  'the Pin creation tool.',
    );
  }

  /// A public image URL for the web route: set by the caller in
  /// `extra['pinterestMediaUrl']` (e.g. after uploading to a media host).
  static String? _publicMediaUrl(PostVariant v) {
    final u = (v.extraAs<String>(extraMediaUrl) ?? v.extraAs<String>('mediaUrl'))?.trim();
    if (u == null || u.isEmpty) return null;
    final parsed = Uri.tryParse(u);
    return parsed != null && (parsed.isScheme('https') || parsed.isScheme('http')) ? u : null;
  }

  static String _truncate(String s, int max) {
    final c = s.characters;
    if (c.length <= max) return s;
    return '${c.take(max - 1)}…';
  }
}
