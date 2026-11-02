// StoredSecretKeys: the secret-store names the app reads outside the adapters
// (Accounts > Connection). Each is defined as one adapter's constant; where
// several adapters write the same entry, they must agree, or the app would
// read one platform's entry and miss the others'.

import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/facebook/facebook_adapter.dart';
import 'package:neforum_core/src/adapters/pinterest/pinterest_adapter.dart';
import 'package:neforum_core/src/adapters/tiktok/tiktok_api.dart';
import 'package:neforum_core/src/adapters/youtube/youtube_api.dart';
import 'package:test/test.dart';

void main() {
  test('every adapter that stores when its refresh token ends uses the one shared name', () {
    expect(PinterestAdapter.secretRefreshExpiresAt, StoredSecretKeys.refreshExpiresAt);
    expect(TikTokSecretKeys.refreshExpiresAt, StoredSecretKeys.refreshExpiresAt);
    expect(YouTubeSecretKeys.refreshExpiresAt, StoredSecretKeys.refreshExpiresAt);
  });

  test('the app secret and client secret have one name across adapters', () {
    expect(PinterestAdapter.secretAppSecret, StoredSecretKeys.appSecret);
    expect(FacebookAdapter.secAppSecret, StoredSecretKeys.appSecret);
    expect(YouTubeSecretKeys.clientSecret, StoredSecretKeys.clientSecret);
    expect(TikTokSecretKeys.clientSecret, StoredSecretKeys.clientSecret);
  });

  test('no shared name collides with the OAuth helpers\' own entries', () {
    final helpers = {
      OAuthTokens.keyAccessToken,
      OAuthTokens.keyRefreshToken,
      OAuthTokens.keyExpiresAt,
      OAuthTokens.keyTokenType,
      OAuthTokens.keyScope,
      OAuth1Credentials.keyConsumerKey,
      OAuth1Credentials.keyConsumerSecret,
      OAuth1Credentials.keyToken,
      OAuth1Credentials.keyTokenSecret,
    };
    final shared = [
      StoredSecretKeys.refreshExpiresAt,
      StoredSecretKeys.tokenIssuedAt,
      StoredSecretKeys.refreshedAt,
      StoredSecretKeys.userTokenExpiresAt,
      StoredSecretKeys.userAccessToken,
      StoredSecretKeys.openId,
      StoredSecretKeys.appPassword,
      StoredSecretKeys.appSecret,
      StoredSecretKeys.clientSecret,
      StoredSecretKeys.consumerSecret,
      StoredSecretKeys.privateKey,
      StoredSecretKeys.sessionId,
    ];
    expect(shared.toSet(), hasLength(shared.length));
    expect(shared.where(helpers.contains), isEmpty);
  });
}
