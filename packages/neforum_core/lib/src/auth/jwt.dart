import 'dart:convert';

/// Reads the `exp` claim of a JWT without verifying it (we only need to know
/// when to refresh). Returns `null` when the token is not a readable JWT or
/// the claim is out of range for a date.
DateTime? jwtExpiry(String jwt) {
  final parts = jwt.split('.');
  if (parts.length < 2) return null;
  try {
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    if (payload is! Map) return null;
    final exp = payload['exp'];
    if (exp is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch((exp * 1000).round(), isUtc: true);
  } on FormatException {
    return null;
  } on RangeError {
    return null;
  } on ArgumentError {
    return null;
  }
}

/// [jwtExpiry] as the end of a sign-in: null when the token carries no `exp`,
/// or one that means "never". Lemmy 1.0 writes `DateTime::<Utc>::MAX_UTC` for
/// `stay_logged_in`, year 262142, and 100 years is further than any real date.
DateTime? jwtSignInEnd(String jwt, {required DateTime now}) {
  final end = jwtExpiry(jwt);
  return end == null || end.isAfter(now.add(const Duration(days: 36525))) ? null : end;
}
