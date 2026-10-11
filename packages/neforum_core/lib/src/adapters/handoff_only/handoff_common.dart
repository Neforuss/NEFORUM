import 'package:uuid/uuid.dart';

import '../../model/account.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';

/// Base class for platforms that NEFORUM can only reach by hand-off
/// (Snapchat, WhatsApp, Google Business Profile, Substack Notes).
///
/// These platforms have no posting API a personal account can use, so the
/// only tier is [PlatformTier.handoff]. Connecting needs nothing but an
/// optional label, nothing secret is ever stored, and [publish] always
/// returns an `unsupported` failure: the publishing service executes the
/// adapter's `buildHandoff()` plan instead.
abstract class HandoffOnlyAdapter extends PlatformAdapter {
  /// Markdown for the connect screen: why there is no API and what the
  /// hand-off does instead.
  String get connectIntro;

  /// Account name used when the user leaves the label empty.
  String get defaultDisplayName => '${descriptor.name} (hand-off)';

  /// Help text under the label field.
  String get labelHelp =>
      'Optional. A name for this account in NEFORUM, e.g. your username. NEFORUM never signs in to '
      '${descriptor.name}; you post from its own app or website.';

  /// Longest label accepted.
  static const int maxLabelLength = 80;

  @override
  List<ConnectSpec> get connectSpecs => [
        ConnectSpec(
          tier: PlatformTier.handoff,
          intro: connectIntro,
          loopbackRedirectOk: false,
          customSchemeRedirectOk: false,
          fields: [
            ConnectField(
              key: 'label',
              label: 'Label',
              required: false,
              help: labelHelp,
              placeholder: defaultDisplayName,
            ),
          ],
        ),
      ];

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier != PlatformTier.handoff) {
      throw ConnectException('${descriptor.name} only supports the "${PlatformTier.handoff.label}" tier in NEFORUM');
    }
    final label = (input['label'] ?? '').trim();
    if (label.length > maxLabelLength) {
      throw const ConnectException('Please keep the label under $maxLabelLength characters', field: 'label');
    }
    return ConnectResult(
      account: ConnectedAccount(
        id: '$id:handoff:${const Uuid().v4()}',
        platformId: id,
        tier: PlatformTier.handoff,
        displayName: label.isEmpty ? defaultDisplayName : label,
        createdAt: ctx.now(),
        config: {if (label.isNotEmpty) 'label': label},
      ),
    );
  }

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    ctx.log.warn('publish() called for hand-off-only platform $id; returning unsupported');
    return PublishResult.failure(PublishError.unsupported(
      '${descriptor.name} has no posting API that NEFORUM can use. Use the hand-off instead: '
      'NEFORUM copies your text and opens ${descriptor.name} so you can post it yourself.',
    ));
  }
}

/// The whole post as one string: thread parts are joined with blank lines,
/// because none of the hand-off-only platforms can take a reply chain.
String handoffFullText(PostVariant variant) =>
    (variant.isThread ? variant.threadParts.join('\n\n') : variant.text).trim();

/// `null` for empty strings, so plans do not carry empty clipboard text.
String? nonEmptyOrNull(String s) => s.isEmpty ? null : s;
