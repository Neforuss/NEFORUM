import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../handoff/handoff_plan.dart';
import '../../http/neforum_http.dart';
import '../../model/account.dart';
import '../../model/artwork.dart';
import '../../model/media.dart';
import '../../model/platform_descriptor.dart';
import '../../model/post.dart' show Visibility;
import '../../model/post_variant.dart';
import '../../model/publish_result.dart';
import '../../model/validation.dart';
import '../adapter_context.dart';
import '../connect_spec.dart';
import '../platform_adapter.dart';
import 'art_api_common.dart';
import 'inkbunny_api.dart';

/// Limits NEFORUM applies to Inkbunny.
abstract final class InkbunnyLimits {
  /// Inkbunny asks for at least four keywords.
  static const int minKeywords = 4;

  /// Files NEFORUM puts in one submission.
  static const int filesPerSubmission = 20;
}

/// Static description of Inkbunny.
const PlatformDescriptor inkbunnyDescriptor = PlatformDescriptor(
  id: 'inkbunny',
  name: 'Inkbunny',
  iconKey: 'inkbunny',
  homepage: 'https://inkbunny.net',
  tiers: {PlatformTier.openApi, PlatformTier.handoff},
  defaultTier: PlatformTier.openApi,
  categories: {PlatformCategory.art},
  text: TextRules(
    titleSupported: true,
    titleRequired: true,
    hashtagsAsField: true,
    notes: 'A submission has a title, a description (BBCode) and keywords, each in its own field. Inkbunny asks for at '
        'least four keywords.',
  ),
  media: MediaRules(
    maxImages: InkbunnyLimits.filesPerSubmission,
    maxVideos: 1,
    requiresMedia: true,
    imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif'},
    videoMimeTypes: {'video/mp4'},
    notes: 'JPEG, PNG or GIF pictures (NEFORUM sends up to 20 in one submission), or an MP4 video. Inkbunny publishes no '
        'per-file limit.',
  ),
  accountRequirements: 'Any Inkbunny account with "Enable API Access" ticked in its account settings. NEFORUM signs in '
      'once and keeps only the session, never your password.',
  apiCostSummary: 'Free. Inkbunny limits how many submissions an account makes per hour.',
  setupGuide: 'docs/platforms/inkbunny.md',
);

/// Inkbunny, the furry art archive (adult work allowed with ratings): signs
/// in once with the username and password to get a session id, then uploads
/// with `api_upload.php` and fills in the submission with
/// `api_editsubmission.php`. The password is never stored.
class InkbunnyAdapter extends PlatformAdapter {
  // Config keys (non-secret).
  static const cfgUsername = 'username';
  static const cfgUserId = 'userId';

  // Secret keys.
  static const secretSid = 'sid';

  /// Per-post option: Inkbunny's submission type number; left as Inkbunny
  /// sets it when absent.
  static const extraType = 'inkbunnyType';

  /// Per-post option: true puts the submission in the user's scraps.
  static const extraScraps = 'inkbunnyScraps';

  @override
  PlatformDescriptor get descriptor => inkbunnyDescriptor;

  // ------------------------------------------------------------- connect

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.openApi,
          intro: '''
**No developer account needed.** Inkbunny's API works with your own username and password, once you allow it:

1. On inkbunny.net open your **Account Settings** and tick **Enable API Access**. Save. If you set an Allowed IP Range there, this device must be inside it.
2. Enter your username and password below and click Connect.

NEFORUM signs in once, keeps only the session it gets back (in this device's secure storage) and forgets the password.''',
          fields: [
            ConnectField(key: 'username', label: 'Username', placeholder: 'your Inkbunny username'),
            ConnectField(
              key: 'password',
              label: 'Password',
              kind: FieldKind.password,
              secret: true,
              help: 'Used once to sign in and never stored.',
            ),
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.handoff,
          intro: 'No setup needed. NEFORUM opens inkbunny.net, puts your description on the clipboard and lists the '
              'title and keywords to copy. You upload the files, set the ratings and submit yourself.',
          fields: [
            ConnectField(key: 'displayName', label: 'Name to show in NEFORUM', required: false, placeholder: 'My Inkbunny'),
          ],
        ),
      ];

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier == PlatformTier.handoff) {
      final name = (input['displayName'] ?? '').trim();
      return ConnectResult(
        account: ConnectedAccount(
          id: 'inkbunny:handoff:${const Uuid().v4()}',
          platformId: id,
          tier: PlatformTier.handoff,
          displayName: name.isEmpty ? 'Inkbunny (hand-off)' : name,
          createdAt: ctx.now(),
        ),
      );
    }
    if (tier != PlatformTier.openApi) throw ConnectException('Inkbunny does not support the ${tier.label} tier');

    final username = (input['username'] ?? '').trim();
    final password = input['password'] ?? '';
    if (username.isEmpty) throw const ConnectException('Enter your Inkbunny username', field: 'username');
    if (password.isEmpty) throw const ConnectException('Enter your Inkbunny password', field: 'password');

    final InkbunnySession session;
    try {
      session = await InkbunnyApi(ctx).login(username, password);
    } on InkbunnyException catch (e) {
      throw ConnectException('Inkbunny did not sign you in: ${e.message}. Check the username and password, and that '
          '"Enable API Access" is ticked in your Inkbunny account settings.');
    } on HttpFailure catch (e) {
      throw ConnectException('Inkbunny did not answer the sign-in (HTTP ${e.statusCode}). Try again.');
    } on Exception catch (e) {
      if (!NeforumHttp.isTransportError(e)) rethrow;
      throw ConnectException('Could not reach Inkbunny ($e). Check your connection and try again.');
    }

    return ConnectResult(
      account: ConnectedAccount(
        id: 'inkbunny:${session.userId ?? username.toLowerCase()}',
        platformId: id,
        tier: PlatformTier.openApi,
        displayName: username,
        handle: username,
        profileUrl: 'https://inkbunny.net/$username',
        createdAt: ctx.now(),
        config: {cfgUsername: username, if (session.userId != null) cfgUserId: session.userId},
      ),
      secrets: {secretSid: session.sid},
    );
  }

  /// The session id lasts until it is signed out; a missing one means
  /// reconnecting.
  @override
  Future<Map<String, String>?> refreshSecrets(
      ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.openApi) return null;
    if ((secrets[secretSid] ?? '').isEmpty) throw const AdapterException(PublishError.auth(_reconnectMessage));
    return null;
  }

  static const String _reconnectMessage = 'Inkbunny is not signed in. Reconnect Inkbunny in Accounts.';

  @override
  Future<void> disconnect(ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final sid = secrets[secretSid];
    if (sid == null || sid.isEmpty) return;
    try {
      await InkbunnyApi(ctx).logout(sid);
    } on Object catch (e) {
      ctx.log.warn('Signing out of Inkbunny failed', e);
    }
  }

  // ------------------------------------------------------------ validate

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = validateArtwork(variant, descriptor, tier: account.tier);
    final keywords = variant.tags.where((t) => t.trim().isNotEmpty).length;
    if (keywords < InkbunnyLimits.minKeywords) {
      issues.add(ValidationIssue.error(
        'inkbunny.keywords',
        'Inkbunny asks for at least ${InkbunnyLimits.minKeywords} keywords; add ${InkbunnyLimits.minKeywords - keywords} '
            'more tag${InkbunnyLimits.minKeywords - keywords == 1 ? '' : 's'}',
        field: 'tags',
      ));
    }
    if (variant.artwork?.aiGenerated ?? false) {
      issues.add(const ValidationIssue.info('inkbunny.ai',
          'Inkbunny has no field for work made with AI; say so in the description or the keywords', field: 'account'));
    }
    return issues;
  }

  // ------------------------------------------------------------- publish

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    try {
      return await _publish(variant, account, secrets, ctx);
    } on AdapterException catch (e) {
      return PublishResult.failure(e.error);
    } on InkbunnyException catch (e) {
      return PublishResult.failure(InkbunnyApi.mapError(e, context: 'Posting to Inkbunny'));
    } on HttpFailure catch (e) {
      return PublishResult.failure(e.toPublishError(context: 'Posting to Inkbunny'));
    } on Error {
      rethrow; // programming errors only
    } on Object catch (e) {
      final text = e.toString();
      if (NeforumHttp.isTransportError(e)) {
        return PublishResult.failure(PublishError.network('Could not reach Inkbunny ($text)', raw: text));
      }
      return PublishResult.failure(PublishError.platform('Inkbunny upload failed: $text', raw: text));
    }
  }

  Future<PublishResult> _publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier == PlatformTier.handoff) {
      return PublishResult.failure(
          const PublishError.unsupported('This is a hand-off account; use the hand-off instead'));
    }
    final sid = secrets[secretSid] ?? '';
    if (sid.isEmpty) return PublishResult.failure(const PublishError.auth(_reconnectMessage));
    final rejection = artworkRejection(validate(variant, account));
    if (rejection != null) return PublishResult.failure(rejection);

    final files = <(MediaAttachment, Uint8List)>[];
    for (var i = 0; i < variant.media.length; i++) {
      ctx.progress('Reading file ${i + 1} of ${variant.media.length}');
      files.add((variant.media[i], await _read(variant.media[i], ctx)));
    }
    final api = InkbunnyApi(ctx);
    ctx.progress('Uploading to Inkbunny');
    final submissionId = await api.upload(sid, files);

    ctx.progress('Filling in the submission');
    try {
      await api.edit(editForm(sid, submissionId, variant));
    } on Exception catch (e) {
      final err = switch (e) {
        InkbunnyException() => InkbunnyApi.mapError(e, context: 'Finishing the Inkbunny submission'),
        HttpFailure() => e.toPublishError(context: 'Finishing the Inkbunny submission'),
        _ => NeforumHttp.isTransportError(e)
            ? PublishError.network('Could not reach Inkbunny ($e)', raw: '$e')
            : PublishError.platform('Inkbunny upload failed: $e', raw: '$e'),
      };
      // The files are uploaded but the submission is not public yet; a retry
      // would upload them again.
      return PublishResult.failure(PublishError(
        kind: err.kind,
        message: '${err.message}. Your files are uploaded as submission $submissionId, which stays hidden: finish it '
            'on inkbunny.net (${InkbunnyApi.submissionUrl(submissionId)}).',
        statusCode: err.statusCode,
        raw: err.raw,
      ));
    }
    return PublishResult.ok(
      remoteId: submissionId,
      remoteUrl: InkbunnyApi.submissionUrl(submissionId),
      publishedAt: ctx.now(),
    );
  }

  /// The `api_editsubmission.php` form: title, description, keywords, who
  /// sees it, and the rating as Inkbunny's content flags (mature work marks
  /// nudity, `tag[2]`; adult work sexual themes, `tag[4]`).
  static Map<String, String> editForm(String sid, String submissionId, PostVariant v) {
    final art = v.artwork ?? const ArtworkDetails();
    final type = v.extraAs<String>(extraType)?.trim() ?? '';
    return {
      'sid': sid,
      'submission_id': submissionId,
      'title': artworkTitle(v),
      'desc': artworkDescription(v),
      'keywords': v.tags.where((t) => t.trim().isNotEmpty).join(','),
      if (type.isNotEmpty) 'type': type,
      'visibility': switch (v.visibility) {
        Visibility.public || Visibility.followers => 'yes',
        Visibility.unlisted => 'yes_nowatch',
        Visibility.private => 'no',
      },
      if (v.visibility == Visibility.followers) 'friends_only': 'yes',
      if (v.extraAs<bool>(extraScraps) ?? false) 'scraps': 'yes',
      if (art.maturity == ArtworkMaturity.mature) 'tag[2]': 'yes',
      if (art.maturity == ArtworkMaturity.adult) 'tag[4]': 'yes',
    };
  }

  static Future<Uint8List> _read(MediaAttachment m, AdapterContext ctx) async {
    try {
      return await ctx.readMedia(m);
    } on Exception catch (e) {
      throw AdapterException(PublishError.configuration('Could not read ${m.fileName ?? m.path}: $e'));
    }
  }

  // ------------------------------------------------------------- hand-off

  /// Inkbunny's upload wizard has no address NEFORUM could confirm, so the
  /// hand-off opens the site itself.
  static const String siteUrl = 'https://inkbunny.net/';

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final art = variant.artwork;
    return artworkHandoff(
      variant,
      platformId: id,
      name: descriptor.name,
      uploadUrl: siteUrl,
      openStep: 'inkbunny.net opens (sign in if asked). Start a new submission with the upload wizard.',
      ratingSteps: [
        if (art != null)
          switch (art.maturity) {
            ArtworkMaturity.general => 'Leave the content ratings unticked.',
            ArtworkMaturity.mature => 'Under the content ratings, tick **Nudity** (and anything else that applies).',
            ArtworkMaturity.adult => 'Under the content ratings, tick **Sexual Themes** (and anything else that applies).',
          },
      ],
      finishStep: 'Submit on Inkbunny.',
    );
  }
}
