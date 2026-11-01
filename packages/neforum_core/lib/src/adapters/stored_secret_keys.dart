import 'art/inkbunny_adapter.dart';
import 'bluesky/bluesky_adapter.dart';
import 'facebook/facebook_adapter.dart';
import 'instagram/instagram_adapter.dart';
import 'nostr/nostr_adapter.dart';
import 'threads/threads_adapter.dart';
import 'tiktok/tiktok_api.dart';
import 'tumblr/tumblr_adapter.dart';
import 'x/x_adapter.dart';
import 'youtube/youtube_api.dart';

/// Names of secret-store entries that code outside the adapters reads (the
/// app's Accounts > Connection section, 1.3.5), defined as the adapters' own
/// constants. Renaming a constant in an adapter renames it here, and removing
/// one breaks the build, so the app never looks for a key under an old name.
///
/// Only names are shared, never values. Entries the OAuth helpers write
/// (`OAuthTokens`, `OAuth1Credentials`) already have public constants there.
abstract final class StoredSecretKeys {
  /// When the refresh token itself runs out (Google apps in "Testing",
  /// TikTok, Pinterest). The same name in all three adapters (tested).
  static const String refreshExpiresAt = YouTubeSecretKeys.refreshExpiresAt;

  /// When Threads last renewed its long-lived token.
  static const String tokenIssuedAt = ThreadsAdapter.secretIssuedAt;

  /// When Instagram last renewed its long-lived token.
  static const String refreshedAt = InstagramAdapter.keyRefreshedAt;

  /// When Facebook's user token (used to list Pages) runs out.
  static const String userTokenExpiresAt = FacebookAdapter.secUserTokenExpiresAt;

  /// Facebook's user token.
  static const String userAccessToken = FacebookAdapter.secUserToken;

  /// The user's id at TikTok, kept with its tokens.
  static const String openId = TikTokSecretKeys.openId;

  /// Bluesky's app password, which it signs in again with when its session
  /// ends. WordPress stores its application password under the same name.
  static const String appPassword = BlueskyAdapter.secretAppPassword;

  /// The app secret of the user's own Meta or Pinterest app (the same name
  /// in Threads, Facebook and Pinterest; tested).
  static const String appSecret = ThreadsAdapter.secretAppSecret;

  /// The client secret of the user's own app (X, LinkedIn, DeviantArt,
  /// YouTube, TikTok, Mastodon's registered app).
  static const String clientSecret = XAdapter.secretClientSecret;

  /// Tumblr's consumer secret (OAuth 2.0 sign-in).
  static const String consumerSecret = TumblrAdapter.secretConsumerSecret;

  /// A Nostr private key.
  static const String privateKey = NostrAdapter.secretPrivateKey;

  /// An Inkbunny session id.
  static const String sessionId = InkbunnyAdapter.secretSid;
}
