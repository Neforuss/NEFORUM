import '../model/account.dart';
import '../model/platform_descriptor.dart';
import '../model/sign_in_lifetime.dart';

/// Every platform's documented sign-in facts, in one reviewable place, read
/// from the vendor's own pages on 2026-11-06. Each adapter names its entry in
/// [PlatformAdapter.signInPolicyFor]. `docs/sign-in-lifetimes.md` is the same
/// table in words, and `sign_in_policy_table_test.dart` holds the two together.
///
/// A vendor page that says nothing about expiry is not evidence that a token
/// never expires: such a row is [SignInLimit.undocumented] and
/// [SignInPolicy.unverified], never [SignInLimit.none].
abstract final class SignInPolicies {
  /// About 6 months: how the vendors word it, as a day count.
  static const Duration _sixMonths = Duration(days: 183);

  /// When X stops accepting OAuth 1.0a (X's migration guide, read 2026-11-06).
  static final DateTime xKeysEnd = DateTime.utc(2027, 1, 31);

  /// How long DeviantArt's refresh token lasts: "3 months", counted short.
  static const Duration deviantArtRefreshLife = Duration(days: 90);

  /// How long Pinterest's refresh token lasts from its last renewal.
  static const Duration pinterestRefreshLife = Duration(days: 60);

  /// Pixelfed's default refresh token life (`OAUTH_REFRESH_DAYS`).
  static const Duration pixelfedRefreshLife = Duration(days: 400);

  static SignInPolicy _api(ConnectedAccount account, SignInPolicy policy) => account.tier == PlatformTier.handoff ? SignInPolicy.noConnection : policy;

  static bool _authMode(ConnectedAccount account, String mode) => account.config['authMode'] == mode;

  // ---- Big platforms ------------------------------------------------------

  static const SignInPolicy xOAuth2 = SignInPolicy(
    limit: SignInLimit.date,
    renewal: SignInRenewal.onUse,
    disuseWindow: _sixMonths,
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://docs.x.com/fundamentals/authentication/oauth-2-0/oauth-1-0a-token-exchange',
  );
  static final SignInPolicy xKeys = SignInPolicy(
    limit: SignInLimit.date,
    renewal: SignInRenewal.never,
    hardDeadline: xKeysEnd,
    earlyRevocationPossible: true,
    sourceUrl: 'https://docs.x.com/fundamentals/authentication/oauth-2-0/oauth-1-0a-token-exchange',
    note: 'X stops accepting these keys on that date. Reconnect by browser sign-in before then.',
  );

  /// Accounts from before the auth mode was stored are OAuth 2.0.
  static SignInPolicy x(ConnectedAccount account) => _api(account, _authMode(account, 'oauth1') ? xKeys : xOAuth2);

  static const SignInPolicy threads = SignInPolicy(
    limit: SignInLimit.date,
    renewal: SignInRenewal.onUse,
    tokenRenewsItself: true,
    disuseWindow: Duration(days: 60),
    earlyRevocationPossible: true,
    sourceUrl: 'https://developers.facebook.com/documentation/threads/get-started/long-lived-tokens',
  );
  static const SignInPolicy instagram = SignInPolicy(
    limit: SignInLimit.date,
    renewal: SignInRenewal.onUse,
    tokenRenewsItself: true,
    disuseWindow: Duration(days: 60),
    earlyRevocationPossible: true,
    sourceUrl: 'https://developers.facebook.com/documentation/instagram-platform/reference/refresh_access_token',
  );
  static const SignInPolicy facebook = SignInPolicy(
    limit: SignInLimit.none,
    renewal: SignInRenewal.notNeeded,
    earlyRevocationPossible: true,
    sourceUrl: 'https://developers.facebook.com/docs/facebook-login/guides/access-tokens/get-long-lived/',
    note: 'Meta can still end it: a password change, a removed app, or a Meta app left unused for 90 days.',
  );
  static const SignInPolicy linkedIn = SignInPolicy(
    limit: SignInLimit.date,
    renewal: SignInRenewal.never,
    earlyRevocationPossible: true,
    sourceUrl: 'https://learn.microsoft.com/en-us/linkedin/shared/authentication/authorization-code-flow',
    note: 'Reconnect before it ends to skip the consent screen.',
  );
  static const SignInPolicy reddit = SignInPolicy(
    limit: SignInLimit.undocumented,
    renewal: SignInRenewal.onUse,
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://github.com/reddit-archive/reddit/wiki/OAuth2',
  );
  static const SignInPolicy tumblrOAuth2 = SignInPolicy(
    limit: SignInLimit.date,
    renewal: SignInRenewal.onUse,
    disuseWindow: Duration(days: 42),
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://github.com/tumblr/docs/issues/134',
  );
  static const SignInPolicy tumblrKeys = SignInPolicy(
    limit: SignInLimit.undocumented,
    renewal: SignInRenewal.notNeeded,
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://raw.githubusercontent.com/tumblr/docs/master/api.md',
  );

  static SignInPolicy tumblr(ConnectedAccount account) => _api(account, _authMode(account, 'oauth1') ? tumblrKeys : tumblrOAuth2);

  // ---- Photo and video ----------------------------------------------------

  static const SignInPolicy tikTok = SignInPolicy(
    limit: SignInLimit.date,
    renewal: SignInRenewal.onUse,
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://developers.tiktok.com/docs/en/oauth-refresh-a-user-access-token',
    note: 'TikTok sets the date. Its documents give two different lengths.',
  );
  static const SignInPolicy pinterest = SignInPolicy(
    limit: SignInLimit.date,
    renewal: SignInRenewal.onUse,
    disuseWindow: pinterestRefreshLife,
    earlyRevocationPossible: true,
    sourceUrl: 'https://developers.pinterest.com/docs/getting-started/set-up-authentication-and-authorization/',
  );
  static const SignInPolicy youTube = SignInPolicy(
    limit: SignInLimit.date,
    renewal: SignInRenewal.onUse,
    disuseWindow: _sixMonths,
    earlyRevocationPossible: true,
    sourceUrl: 'https://developers.google.com/identity/protocols/oauth2',
    note: 'If your Google app is still in Testing, Google ends the sign-in every 7 days.',
  );

  // ---- Open networks ------------------------------------------------------

  static const SignInPolicy mastodonNoLimit = SignInPolicy(
    limit: SignInLimit.none,
    renewal: SignInRenewal.notNeeded,
    earlyRevocationPossible: true,
    sourceUrl: 'https://raw.githubusercontent.com/mastodon/mastodon/main/config/initializers/doorkeeper.rb',
  );
  static const SignInPolicy goToSocial = SignInPolicy(
    limit: SignInLimit.none,
    renewal: SignInRenewal.notNeeded,
    earlyRevocationPossible: true,
    sourceUrl: 'https://codeberg.org/superseriousbusiness/gotosocial/raw/branch/main/internal/oauth/server.go',
  );
  static const SignInPolicy pleroma = SignInPolicy(
    limit: SignInLimit.date,
    renewal: SignInRenewal.onUse,
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://docs.pleroma.social/backend/configuration/cheatsheet/',
    note: 'Your server sets how long.',
  );
  static const SignInPolicy akkoma = SignInPolicy(
    limit: SignInLimit.date,
    renewal: SignInRenewal.onUse,
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://docs.akkoma.dev/stable/configuration/cheatsheet/',
    note: 'Your server sets how long.',
  );
  static const SignInPolicy mitra = SignInPolicy(
    limit: SignInLimit.date,
    renewal: SignInRenewal.never,
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://codeberg.org/silverpill/mitra/raw/branch/main/CHANGELOG.md',
  );
  static const SignInPolicy mastodonOtherServer = SignInPolicy(
    limit: SignInLimit.undocumented,
    renewal: SignInRenewal.notNeeded,
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://raw.githubusercontent.com/friendica/friendica/develop/src/Module/OAuth/Token.php',
    note: 'Your server decides.',
  );

  /// By the server software the account recorded when it connected. A date the
  /// server sends always wins, so software not listed here is still handled.
  static SignInPolicy mastodon(ConnectedAccount account) => _api(account, switch ('${account.config['software'] ?? ''}'.toLowerCase()) {
        'mastodon' => mastodonNoLimit,
        'gotosocial' => goToSocial,
        'pleroma' => pleroma,
        'akkoma' => akkoma,
        'mitra' => mitra,
        _ => mastodonOtherServer,
      });

  static const SignInPolicy pixelfedPolicy = SignInPolicy(
    limit: SignInLimit.date,
    renewal: SignInRenewal.onUse,
    disuseWindow: pixelfedRefreshLife,
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://raw.githubusercontent.com/pixelfed/pixelfed/dev/config/instance.php',
    note: 'Your server can change these limits.',
  );
  static SignInPolicy pixelfed(ConnectedAccount account) => _api(account, pixelfedPolicy);

  static const SignInPolicy blueskyPolicy = SignInPolicy(
    limit: SignInLimit.date,
    renewal: SignInRenewal.credential,
    earlyRevocationPossible: true,
    sourceUrl: 'https://raw.githubusercontent.com/bluesky-social/atproto/main/packages/pds/src/account-manager/helpers/auth.ts',
  );
  static SignInPolicy bluesky(ConnectedAccount account) => _api(account, blueskyPolicy);

  static const SignInPolicy misskeyPolicy = SignInPolicy(
    limit: SignInLimit.none,
    renewal: SignInRenewal.notNeeded,
    earlyRevocationPossible: true,
    sourceUrl: 'https://raw.githubusercontent.com/misskey-dev/misskey/develop/packages/backend/src/models/AccessToken.ts',
  );
  static SignInPolicy misskey(ConnectedAccount account) => _api(account, misskeyPolicy);

  static const SignInPolicy nostrPolicy = SignInPolicy(
    limit: SignInLimit.none,
    renewal: SignInRenewal.notNeeded,
    sourceUrl: 'https://raw.githubusercontent.com/nostr-protocol/nips/master/01.md',
    note: 'A key does not expire.',
  );
  static SignInPolicy nostr(ConnectedAccount account) => _api(account, nostrPolicy);

  /// No limit on 0.19 and with `stay_logged_in` on 1.0; a JWT that does carry
  /// an `exp` is read as a server date and beats this.
  static const SignInPolicy lemmyPolicy = SignInPolicy(
    limit: SignInLimit.none,
    renewal: SignInRenewal.notNeeded,
    earlyRevocationPossible: true,
    sourceUrl: 'https://raw.githubusercontent.com/LemmyNet/lemmy/1.0.0-beta.3/crates/api/api_utils/src/claims.rs',
    note: 'Logging out or a new password ends it.',
  );
  static SignInPolicy lemmy(ConnectedAccount account) => _api(account, lemmyPolicy);

  static const SignInPolicy matrixPassword = SignInPolicy(
    limit: SignInLimit.undocumented,
    renewal: SignInRenewal.onUse,
    earlyRevocationPossible: true,
    sourceUrl: 'https://spec.matrix.org/latest/client-server-api/',
    note: 'Your homeserver decides.',
  );
  static const SignInPolicy matrixPasted = SignInPolicy(
    limit: SignInLimit.undocumented,
    renewal: SignInRenewal.never,
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://element-hq.github.io/matrix-authentication-service/reference/configuration.html',
    note: 'Your homeserver decides. A token copied from Element may end quickly.',
  );
  static SignInPolicy matrix(ConnectedAccount account) => _api(account, account.config['authMethod'] == 'token' ? matrixPasted : matrixPassword);

  // ---- Messaging ----------------------------------------------------------

  static const SignInPolicy telegramPolicy = SignInPolicy(
    limit: SignInLimit.undocumented,
    renewal: SignInRenewal.notNeeded,
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://core.telegram.org/bots/features',
  );
  static SignInPolicy telegram(ConnectedAccount account) => _api(account, telegramPolicy);

  static const SignInPolicy discordPolicy = SignInPolicy(
    limit: SignInLimit.undocumented,
    renewal: SignInRenewal.notNeeded,
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://docs.discord.com/developers/resources/webhook',
  );
  static SignInPolicy discord(ConnectedAccount account) => _api(account, discordPolicy);

  // ---- Blogs --------------------------------------------------------------

  static const SignInPolicy wordPressPolicy = SignInPolicy(
    limit: SignInLimit.none,
    renewal: SignInRenewal.notNeeded,
    earlyRevocationPossible: true,
    sourceUrl: 'https://developer.wordpress.org/rest-api/reference/application-passwords/',
  );
  static SignInPolicy wordPress(ConnectedAccount account) => _api(account, wordPressPolicy);

  static const SignInPolicy ghostPolicy = SignInPolicy(
    limit: SignInLimit.undocumented,
    renewal: SignInRenewal.notNeeded,
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://docs.ghost.org/admin-api',
  );
  static SignInPolicy ghost(ConnectedAccount account) => _api(account, ghostPolicy);

  static const SignInPolicy writeFreelySelfHosted = SignInPolicy(
    limit: SignInLimit.none,
    renewal: SignInRenewal.notNeeded,
    earlyRevocationPossible: true,
    sourceUrl: 'https://raw.githubusercontent.com/writefreely/writefreely/develop/database.go',
  );
  static const SignInPolicy writeAsHosted = SignInPolicy(
    limit: SignInLimit.undocumented,
    renewal: SignInRenewal.notNeeded,
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://developers.write.as/docs/api/',
  );
  static SignInPolicy writeFreely(ConnectedAccount account) {
    final host = Uri.tryParse('${account.config['instance'] ?? ''}')?.host.toLowerCase() ?? '';
    // Anonymous posts hold no credential at all.
    if (account.config['anonymous'] == true) return SignInPolicy.noConnection;
    return _api(account, host == 'write.as' ? writeAsHosted : writeFreelySelfHosted);
  }

  static const SignInPolicy micropubIndieAuth = SignInPolicy(
    limit: SignInLimit.undocumented,
    renewal: SignInRenewal.onUse,
    earlyRevocationPossible: true,
    sourceUrl: 'https://indieauth.spec.indieweb.org/',
    note: 'Your site decides.',
  );
  static const SignInPolicy microBlogToken = SignInPolicy(
    limit: SignInLimit.undocumented,
    renewal: SignInRenewal.notNeeded,
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://help.micro.blog/2018/api-authentication/',
  );
  static SignInPolicy micropub(ConnectedAccount account) => _api(account, account.config['authMethod'] == 'indieauth' ? micropubIndieAuth : microBlogToken);

  static const SignInPolicy devToPolicy = SignInPolicy(
    limit: SignInLimit.none,
    renewal: SignInRenewal.notNeeded,
    earlyRevocationPossible: true,
    sourceUrl: 'https://raw.githubusercontent.com/forem/forem/main/app/models/api_secret.rb',
  );
  static SignInPolicy devTo(ConnectedAccount account) => _api(account, devToPolicy);

  static const SignInPolicy hashnodePolicy = SignInPolicy(
    limit: SignInLimit.undocumented,
    renewal: SignInRenewal.notNeeded,
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://hashnode.com/blog/hashnode-gql-agent-skill',
  );
  static SignInPolicy hashnode(ConnectedAccount account) => _api(account, hashnodePolicy);

  // ---- Art ----------------------------------------------------------------

  static const SignInPolicy deviantArtPolicy = SignInPolicy(
    limit: SignInLimit.date,
    renewal: SignInRenewal.onUse,
    disuseWindow: deviantArtRefreshLife,
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://deviantart.readme.io/docs/authentication',
  );
  static SignInPolicy deviantArt(ConnectedAccount account) => _api(account, deviantArtPolicy);

  static const SignInPolicy dribbblePolicy = SignInPolicy(
    limit: SignInLimit.undocumented,
    renewal: SignInRenewal.notNeeded,
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://developer.dribbble.com/v2/oauth/',
  );
  static SignInPolicy dribbble(ConnectedAccount account) => _api(account, dribbblePolicy);

  static const SignInPolicy flickrPolicy = SignInPolicy(
    limit: SignInLimit.undocumented,
    renewal: SignInRenewal.notNeeded,
    earlyRevocationPossible: true,
    unverified: true,
    sourceUrl: 'https://www.flickr.com/services/api/auth.oauth.html',
  );
  static SignInPolicy flickr(ConnectedAccount account) => _api(account, flickrPolicy);

  static const SignInPolicy inkbunnyPolicy = SignInPolicy(
    limit: SignInLimit.idleUnknown,
    renewal: SignInRenewal.never,
    earlyRevocationPossible: true,
    sourceUrl: 'https://wiki.inkbunny.net/wiki/API',
    note: 'Inkbunny ends the session after several days without use. No date can be known.',
  );
  static SignInPolicy inkbunny(ConnectedAccount account) => _api(account, inkbunnyPolicy);

  // ---- API tiers with their own account shape -----------------------------

  static SignInPolicy threadsFor(ConnectedAccount account) => _api(account, threads);
  static SignInPolicy instagramFor(ConnectedAccount account) => _api(account, instagram);
  static SignInPolicy facebookFor(ConnectedAccount account) => _api(account, facebook);
  static SignInPolicy linkedInFor(ConnectedAccount account) => _api(account, linkedIn);
  static SignInPolicy redditFor(ConnectedAccount account) => _api(account, reddit);
  static SignInPolicy tikTokFor(ConnectedAccount account) => _api(account, tikTok);
  static SignInPolicy pinterestFor(ConnectedAccount account) => _api(account, pinterest);
  static SignInPolicy youTubeFor(ConnectedAccount account) => _api(account, youTube);
}
