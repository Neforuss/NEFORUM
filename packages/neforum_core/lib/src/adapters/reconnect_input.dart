import '../model/account.dart';
import '../model/platform_descriptor.dart';
import 'connect_spec.dart';

// 1.4.3: the connect form's answers for a sign-in again through the browser,
// read back from what the first sign-in stored, so a revoked or ended OAuth
// sign-in comes back with one tap instead of the whole form.
//
// What it hands back is only what the person typed or chose the first time
// and what the platform needs to send them to its consent page: the server
// address, their own developer app's ID and secret, a board or blog name. It
// never holds a token or a password: a field whose name says token or
// password is left empty, so the adapter takes the browser route and the
// platform asks the person to consent again. A sign-in that was made by
// pasting keys (no browser) gives null: new keys are something only the
// person can bring.

/// Sign-in methods recorded in an account's config that used no browser:
/// pasted keys and tokens, OAuth 1.0a keys, a typed password. A reconnect of
/// those needs new keys typed in, so [browserReconnectInput] gives null.
const Set<String> kTypedSignInMethods = {'oauth1', 'pasted', 'dashboard', 'token', 'password'};

/// The config keys adapters record their sign-in method under.
const Set<String> kSignInMethodConfigKeys = {'authMode', 'authMethod', 'tokenSource', 'token_source'};

/// "client_id", "clientId" and "client-id" all read "clientid".
String _norm(String key) => key.replaceAll(RegExp('[_-]'), '').toLowerCase();

/// Whether the connect form asks for [f] again on every sign-in: a token or a
/// password. Those come from the sign-in itself, and a password for an OAuth
/// platform is never stored or replayed.
bool reconnectAsksAgain(ConnectField f) {
  final k = f.key.toLowerCase();
  return k.contains('token') || k.contains('password');
}

/// [value] as a form answer, or null when it is not one (a map, a list).
String? _asAnswer(Object? value) => switch (value) {
      final String s when s.trim().isNotEmpty => s.trim(),
      final bool b => b ? 'true' : 'false',
      final num n => '$n',
      _ => null,
    };

/// The value stored for a form field: in the account's config first, then in
/// its keys, under [source] when the adapter names one, else under the field's
/// own key written either way ("client_id" or "clientId").
String? _stored(String fieldKey, String? source, ConnectedAccount account, Map<String, String> secrets) {
  if (source != null) return _asAnswer(account.config[source]) ?? _asAnswer(secrets[source]);
  final want = _norm(fieldKey);
  for (final e in account.config.entries) {
    if (_norm(e.key) == want) {
      final v = _asAnswer(e.value);
      if (v != null) return v;
    }
  }
  for (final e in secrets.entries) {
    if (_norm(e.key) == want) {
      final v = _asAnswer(e.value);
      if (v != null) return v;
    }
  }
  return null;
}

/// Whether [value] is a redirect the person registered themselves (an https
/// page), as opposed to the address this device's sign-in listens on (a
/// loopback or `neforum://` address), which another device would not catch:
/// that one is left for the adapter to choose again.
bool _isOwnRedirect(String value) {
  final u = Uri.tryParse(value);
  if (u == null || u.scheme != 'https' || u.host.isEmpty) return false;
  return u.host != 'localhost' && u.host != '127.0.0.1';
}

/// The connect form's answers that sign [account] in again through the
/// browser with the keys it already has, or null when that cannot be done
/// without the person typing something (see the comment at the top).
///
/// [sources] maps a form field to the config or key name its value was
/// stored under, where that is not the field's own name (the adapter's
/// `reconnectFieldSources`).
Map<String, String>? browserReconnectInput(
  List<ConnectSpec> specs,
  ConnectedAccount account,
  Map<String, String> secrets, {
  Map<String, String> sources = const {},
}) {
  if (account.tier == PlatformTier.handoff) return null;
  ConnectSpec? spec;
  for (final s in specs) {
    if (s.tier == account.tier) {
      spec = s;
      break;
    }
  }
  if (spec == null || !spec.usesBrowser) return null;
  for (final k in kSignInMethodConfigKeys) {
    if (kTypedSignInMethods.contains(_asAnswer(account.config[k]))) return null;
  }
  final out = <String, String>{};
  for (final f in spec.fields) {
    if (reconnectAsksAgain(f)) continue;
    var v = _stored(f.key, sources[f.key], account, secrets);
    if (v != null && f.key.toLowerCase().contains('redirect') && !_isOwnRedirect(v)) v = null;
    if (v != null && f.kind == FieldKind.select && !(f.options?.contains(v) ?? false)) v = null;
    if (v != null) {
      out[f.key] = v;
    } else if (f.required && f.defaultValue == null) {
      return null;
    }
  }
  return out;
}
