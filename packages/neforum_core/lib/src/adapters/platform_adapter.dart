import '../handoff/handoff_plan.dart';
import '../model/account.dart';
import '../model/photo_fit.dart';
import '../model/platform_descriptor.dart';
import '../model/post_variant.dart';
import '../model/publish_result.dart';
import '../model/validation.dart';
import '../text/rules_validator.dart';
import 'adapter_context.dart';
import 'connect_spec.dart';

/// The contract every platform implements.
///
/// Adapters are stateless. Everything they need arrives as arguments: the
/// account (non-secret config), the secrets map, and an [AdapterContext] with
/// HTTP, an optional browser broker and an optional media host. They must
/// never store anything themselves; secrets they create are returned to the
/// caller.
abstract class PlatformAdapter {
  PlatformDescriptor get descriptor;

  String get id => descriptor.id;

  /// [descriptor] with this account's own limits applied (a Mastodon-API
  /// server's character limit and scheduling support, a Misskey instance's
  /// note length). Text is split and media trimmed with it, so it must be
  /// cheap and pure.
  PlatformDescriptor descriptorForAccount(ConnectedAccount account) => descriptor;

  /// One spec per supported tier. The UI shows the tiers as a choice.
  List<ConnectSpec> get connectSpecs;

  ConnectSpec specFor(PlatformTier tier) =>
      connectSpecs.firstWhere((s) => s.tier == tier, orElse: () => connectSpecs.first);

  /// Turns the user's form input into an account. Throws [ConnectException]
  /// on bad input and `AuthCancelled` when the user bails out of a browser
  /// flow.
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx);

  /// Called before publishing. Return refreshed secrets when the stored ones
  /// are (about to be) expired, or `null` when nothing changed. Throw
  /// `PublishError.auth` (wrapped in [AdapterException]) when the user must
  /// reconnect.
  Future<Map<String, String>?> refreshSecrets(
          ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async =>
      null;

  /// The photos this platform takes through [account] for [variant], as rules a photo can be
  /// changed to meet (shape, file type, size, pixels). The app makes a fitted
  /// copy of a photo that breaks them, for this platform only, instead of
  /// failing the post. Null: photos go as they are. Defaults to the
  /// descriptor's file types and size; override for more (Instagram's 4:5 to
  /// 1.91:1) or for tiers that take anything (a share sheet).
  PhotoFit? photoFit(ConnectedAccount account, PostVariant variant) {
    final d = descriptorForAccount(account);
    return PhotoFit.fromRules(d.media).copyWith(label: d.name);
  }

  /// Platform-specific validation on top of the generic rules check. Called
  /// by the composer live, so keep it synchronous and cheap.
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) =>
      RulesValidator.validate(variant, descriptor, tier: account.tier);

  /// Publishes through the API. Must not throw for platform/user errors —
  /// return `PublishResult.failure` instead; only programming errors may
  /// escape.
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx);

  /// Builds the hand-off plan for this platform, or `null` when the platform
  /// has no sensible hand-off route.
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) => null;

  /// The plan for an actual hand-off. Unlike [buildHandoff] it may do network
  /// work first, e.g. put photos on the user's media host so a share link can
  /// carry them. Defaults to [buildHandoff]. Must not throw for platform or
  /// network problems: fall back to the plain plan instead.
  Future<HandoffPlan?> prepareHandoff(PostVariant variant, ConnectedAccount account, AdapterContext ctx) async =>
      buildHandoff(variant, account: account);

  /// Removes a post the platform is holding for later, i.e. one that
  /// [publish] returned as [PublishResult.scheduled]. Completes normally when
  /// the held copy is gone, including when it no longer exists (404). Throws
  /// [AdapterException] when it could not be removed, so the caller never
  /// assumes a held copy is gone while it may still go out.
  ///
  /// Only adapters whose descriptor sets `serverSideScheduling` implement it.
  Future<void> cancelScheduled(
      PublishResult held, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    throw AdapterException(PublishError.unsupported('${descriptor.name} cannot cancel scheduled posts'));
  }

  /// Called when the account is removed, to revoke tokens where the platform
  /// supports it. Best effort; errors are logged, not surfaced.
  Future<void> disconnect(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {}
}

/// Wraps a [PublishError] so adapter helpers can `throw` and the adapter's
/// top-level `publish` can convert it into a failure result.
class AdapterException implements Exception {
  const AdapterException(this.error);
  final PublishError error;
  @override
  String toString() => error.toString();
}
