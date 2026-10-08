import 'package:meta/meta.dart';

import '../model/account.dart';
import '../model/platform_descriptor.dart';

enum FieldKind { text, password, url, multiline, select, boolean, number }

/// One input the user fills in when connecting an account. The UI renders the
/// form from these; the CLI prompts for them.
@immutable
class ConnectField {
  const ConnectField({
    required this.key,
    required this.label,
    this.kind = FieldKind.text,
    this.required = true,
    this.help,
    this.placeholder,
    this.defaultValue,
    this.options,
    this.secret = false,
  });

  final String key;
  final String label;
  final FieldKind kind;
  final bool required;

  /// Markdown-ish help shown under the field.
  final String? help;
  final String? placeholder;
  final String? defaultValue;

  /// For [FieldKind.select].
  final List<String>? options;

  /// Stored in the secret store instead of the account config.
  final bool secret;
}

/// Describes the connect flow for one (platform, tier) pair.
@immutable
class ConnectSpec {
  const ConnectSpec({
    required this.tier,
    this.fields = const [],
    this.usesBrowser = false,
    this.intro = '',
    this.redirectNote,
    this.loopbackRedirectOk = true,
    this.customSchemeRedirectOk = true,
    this.fixedRedirectUri,
  });

  final PlatformTier tier;
  final List<ConnectField> fields;

  /// The adapter will call `AuthBroker.authorize` (OAuth / MiAuth / ...).
  final bool usesBrowser;

  /// Markdown shown above the form: what the user needs and where to get it.
  final String intro;

  /// Tells the user which redirect URI to register in their developer app.
  final String? redirectNote;

  /// Whether the platform accepts `http://127.0.0.1:PORT/...` redirects.
  final bool loopbackRedirectOk;

  /// Whether the platform accepts `neforum://callback`-style redirects.
  final bool customSchemeRedirectOk;

  /// Some platforms insist on an HTTPS redirect; adapters may then route the
  /// user through a page they control, or use a paste-code broker.
  final Uri? fixedRedirectUri;
}

/// What `PlatformAdapter.connect` returns: the account to store plus the
/// secrets to put in the [SecretStore] under `account.id`.
@immutable
class ConnectResult {
  const ConnectResult({required this.account, this.secrets = const {}});

  final ConnectedAccount account;
  final Map<String, String> secrets;
}

/// Raised by adapters when the user's input is unusable (bad URL, missing
/// token, platform refused the credentials). Message is shown verbatim.
class ConnectException implements Exception {
  const ConnectException(this.message, {this.field});
  final String message;
  final String? field;
  @override
  String toString() => message;
}
