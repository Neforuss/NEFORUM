/// Thrown when the user closes the browser / cancels the sign-in.
class AuthCancelled implements Exception {
  const AuthCancelled([this.message = 'Sign-in was cancelled']);
  final String message;
  @override
  String toString() => message;
}

/// Bridges the gap between an adapter that needs "send the user to this URL
/// and give me the redirect they come back with" and the environment that can
/// actually do it (a loopback HTTP server on desktop/CLI, a custom URL scheme
/// on mobile, or a paste box when the platform only allows HTTPS redirects).
abstract class AuthBroker {
  /// Picks the redirect URI this environment can catch, honouring what the
  /// platform allows. Adapters must register exactly this URI with the
  /// platform, so implementations should return a STABLE value (fixed port).
  Uri chooseRedirectUri({
    bool loopbackOk = true,
    bool customSchemeOk = true,
    Uri? fixed,
  });

  /// Opens [authorizationUrl] for the user and completes with the full
  /// redirect URI (including `code`, `state`, or an error) once the platform
  /// sends the user back to [redirectUri].
  Future<Uri> authorize(
    Uri authorizationUrl,
    Uri redirectUri, {
    Duration timeout = const Duration(minutes: 5),
  });
}

/// For flows where the platform hands the user a code to copy (device code,
/// `urn:ietf:wg:oauth:2.0:oob`, Meta's HTTPS-only redirects when the user
/// pastes the final URL back). [askUser] shows the URL and returns whatever
/// the user pasted (a code or a full redirect URL).
class PasteCodeAuthBroker implements AuthBroker {
  PasteCodeAuthBroker({required this.askUser, Uri? redirectUri})
      : _redirect = redirectUri ?? Uri.parse('urn:ietf:wg:oauth:2.0:oob');

  final Future<String?> Function(Uri authorizationUrl, Uri redirectUri) askUser;
  final Uri _redirect;

  @override
  Uri chooseRedirectUri({bool loopbackOk = true, bool customSchemeOk = true, Uri? fixed}) =>
      fixed ?? _redirect;

  @override
  Future<Uri> authorize(Uri authorizationUrl, Uri redirectUri,
      {Duration timeout = const Duration(minutes: 5)}) async {
    final pasted = (await askUser(authorizationUrl, redirectUri))?.trim();
    if (pasted == null || pasted.isEmpty) throw const AuthCancelled();
    final asUri = Uri.tryParse(pasted);
    if (asUri != null && asUri.hasScheme && asUri.queryParameters.isNotEmpty) return asUri;
    // A bare code: synthesise a redirect so callers can treat both the same.
    return redirectUri.replace(queryParameters: {...redirectUri.queryParameters, 'code': pasted});
  }
}
