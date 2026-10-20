import 'dart:async';

import '../auth/oauth2_pkce.dart';
import '../http/neforum_http.dart';
import '../util/logger.dart';
import 'sync_backend.dart';

/// The only Google scope the direct Google Drive sync asks for: the files and
/// folders NEFORUM itself created, nothing else in the user's Drive.
const String googleDriveScope = 'https://www.googleapis.com/auth/drive.file';

/// Hands a sync backend a valid access token: renews it with the refresh
/// token when it is about to expire (or when the service refused it), and
/// saves the renewed sign-in through [save].
class OAuthTokenSource {
  OAuthTokenSource({
    required OAuth2Client client,
    required NeforumHttp http,
    required Map<String, String> secrets,
    required Future<void> Function(Map<String, String> secrets) save,
    Clock? clock,
    Logger? log,
  })  : _client = client,
        _http = http,
        _secrets = Map.of(secrets),
        _save = save,
        _now = clock ?? systemClock,
        _log = log ?? Logger('sync.oauth');

  /// Secret-map key of the OAuth client's secret, kept next to the tokens.
  static const keyClientSecret = 'client_secret';

  static final Uri _googleAuthorize = Uri.parse('https://accounts.google.com/o/oauth2/v2/auth');
  static final Uri _googleToken = Uri.parse('https://oauth2.googleapis.com/token');
  static const _leeway = Duration(minutes: 5);
  static const _signInAgain = 'The Google sign-in expired or was revoked: sign in again in Settings > Sync.';

  /// The OAuth client for the direct Google Drive sync: the user's own
  /// Google Cloud client of type "Desktop app" (installed-app flow: PKCE,
  /// client id and secret in the token request body).
  static OAuth2Client googleDriveClient({required String clientId, String? clientSecret}) => OAuth2Client(
        authorizationEndpoint: _googleAuthorize,
        tokenEndpoint: _googleToken,
        clientId: clientId.trim(),
        clientSecret: clientSecret == null || clientSecret.trim().isEmpty ? null : clientSecret.trim(),
        scopes: const [googleDriveScope],
        usePkce: true,
        clientAuth: ClientAuth.body,
        // Ask for a refresh token every time, also when signing in again.
        extraAuthorizationParams: const {'access_type': 'offline', 'prompt': 'consent'},
      );

  final OAuth2Client _client;
  final NeforumHttp _http;
  final Future<void> Function(Map<String, String>) _save;
  final Clock _now;
  final Logger _log;
  Map<String, String> _secrets;
  Future<String>? _refreshing;

  /// The secrets as they are now, renewed tokens included.
  Map<String, String> get secrets => Map.unmodifiable(_secrets);

  /// A valid access token. Renews it when it expires within five minutes or
  /// when [forceRefresh] is set (the service refused it); callers arriving
  /// while a renewal is under way share it. Throws [SyncBackendException]:
  /// temporary for an outage or a rate limit, not temporary when Google
  /// refused the sign-in.
  Future<String> accessToken({bool forceRefresh = false}) {
    final pending = _refreshing;
    if (pending != null) return pending;
    final tokens = OAuthTokens.fromSecrets(_secrets);
    if (!forceRefresh && tokens != null && !tokens.isExpired(now: _now(), leeway: _leeway)) return Future.value(tokens.accessToken);
    final run = _refresh();
    _refreshing = run;
    return run.whenComplete(() {
      if (identical(_refreshing, run)) _refreshing = null;
    });
  }

  Future<String> _refresh() async {
    final refreshToken = _secrets[OAuthTokens.keyRefreshToken];
    if (refreshToken == null || refreshToken.isEmpty) throw const SyncBackendException(_signInAgain);
    _log.info('Renewing the Google sign-in for sync');
    final OAuthTokens fresh;
    try {
      fresh = await _client.refresh(_http, refreshToken: refreshToken, now: _now());
    } on OAuthException catch (e) {
      final detail = e.description ?? e.error ?? e.message;
      if (e.statusCode == 429) {
        throw const SyncBackendException('Google is rate limiting sign-in renewals; NEFORUM tries again shortly.', temporary: true);
      }
      if (e.isGrantRejected) {
        _log.warn('Google refused to renew the sync sign-in: $e');
        throw const SyncBackendException(_signInAgain);
      }
      throw SyncBackendException('Could not renew the Google sign-in right now ($detail); NEFORUM tries again shortly.', temporary: true);
    } on Object catch (e) {
      if (NeforumHttp.isTransportError(e)) {
        throw SyncBackendException('Could not reach Google to renew the sign-in: $e', temporary: true);
      }
      rethrow;
    }
    // Google keeps the refresh token on renewal and usually sends none:
    // toSecrets keeps the stored one then.
    final merged = fresh.toSecrets(_secrets);
    if (fresh.expiresAt == null) merged.remove(OAuthTokens.keyExpiresAt);
    _secrets = merged;
    try {
      await _save(Map.of(merged));
    } on Object catch (e) {
      // The new token works for this run anyway; the next start renews again.
      _log.warn('Could not save the renewed Google sign-in: $e');
    }
    return fresh.accessToken;
  }
}
