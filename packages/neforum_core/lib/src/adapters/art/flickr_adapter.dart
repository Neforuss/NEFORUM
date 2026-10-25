import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../auth/auth_broker.dart';
import '../../auth/oauth1.dart';
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
import 'flickr_api.dart';

/// Limits from Flickr's upload requirements (flickrhelp.com, read
/// 2026-10-25).
abstract final class FlickrLimits {
  static const int photoMaxBytes = 200 * 1024 * 1024;
  static const int videoMaxBytes = 1024 * 1024 * 1024;

  /// Files NEFORUM uploads for one post, each as its own Flickr photo.
  static const int filesPerPost = 10;
}

/// Static description of Flickr.
const PlatformDescriptor flickrDescriptor = PlatformDescriptor(
  id: 'flickr',
  name: 'Flickr',
  iconKey: 'flickr',
  homepage: 'https://www.flickr.com',
  tiers: {PlatformTier.handoff, PlatformTier.byokApi},
  defaultTier: PlatformTier.handoff,
  categories: {PlatformCategory.art},
  text: TextRules(
    titleSupported: true,
    titleRequired: true,
    hashtagsAsField: true,
    notes: 'Each photo has a title, a description and tags in their own fields. With several files, every one gets '
        'the same title, description and tags.',
  ),
  media: MediaRules(
    maxImages: FlickrLimits.filesPerPost,
    maxVideos: 1,
    requiresMedia: true,
    allowsMixedImageVideo: true,
    imageMaxBytes: FlickrLimits.photoMaxBytes,
    videoMaxBytes: FlickrLimits.videoMaxBytes,
    imageMimeTypes: {'image/jpeg', 'image/png', 'image/gif', 'image/tiff', 'image/bmp'},
    videoMimeTypes: {'video/mp4', 'video/quicktime'},
    notes: 'JPEG, PNG, non-animated GIF, TIFF or BMP up to 200 MB, video up to 1 GB. Every file becomes its own '
        'Flickr photo; NEFORUM takes up to 10 per post.',
  ),
  accountRequirements: 'Any Flickr account for the hand-off. Posting through the API needs your own Flickr API key, '
      'which only Flickr Pro members can request and Flickr reviews.',
  apiCostSummary: 'The API itself is free, but an API key needs a Flickr Pro membership. Free accounts keep at most '
      '1,000 photos and videos.',
  setupGuide: 'docs/platforms/flickr.md',
);

/// Flickr: hands photos to the web uploader, or uploads them with the user's
/// own API key and secret (OAuth 1.0a, `perms=write`, upload API).
///
/// Artwork is uploaded with the content type for art and illustration, and
/// its rating as Flickr's safety level.
class FlickrAdapter extends PlatformAdapter {
  FlickrAdapter({String Function()? nonce}) : _nonce = nonce;

  /// Replaces the random OAuth nonce in tests.
  final String Function()? _nonce;

  // Config keys (non-secret).
  static const cfgUserNsid = 'userNsid';
  static const cfgUsername = 'username';

  /// Per-post option: `photo`, `screenshot` or `art` (the default).
  static const extraContentType = 'flickrContentType';

  static const String uploadUrl = 'https://www.flickr.com/photos/upload/';

  @override
  PlatformDescriptor get descriptor => flickrDescriptor;

  // ------------------------------------------------------------- connect

  @override
  List<ConnectSpec> get connectSpecs => const [
        ConnectSpec(
          tier: PlatformTier.handoff,
          intro: 'No setup needed. NEFORUM opens Flickr\'s uploader, puts your description on the clipboard and lists '
              'the title and tags to copy; on a phone it shares your photos to the Flickr app. You set the safety '
              'level and press **Upload** yourself.',
          fields: [
            ConnectField(key: 'displayName', label: 'Name to show in NEFORUM', required: false, placeholder: 'My Flickr'),
          ],
        ),
        ConnectSpec(
          tier: PlatformTier.byokApi,
          usesBrowser: true,
          loopbackRedirectOk: true,
          customSchemeRedirectOk: false,
          redirectNote: 'NEFORUM tells Flickr to come back to http://127.0.0.1:52771/callback. If your app\'s '
              'authentication flow asks for a Callback URL, enter that address.',
          intro: _byokIntro,
          fields: [
            ConnectField(
              key: 'apiKey',
              label: 'Key',
              help: 'flickr.com/services/apps/by/me > your app > "Key".',
            ),
            ConnectField(
              key: 'apiSecret',
              label: 'Secret',
              kind: FieldKind.password,
              secret: true,
              help: 'Same page, "Secret". It stays on this device.',
            ),
          ],
        ),
      ];

  static const String _byokIntro = '''
**Upload photos automatically.** You need a Flickr Pro membership and your own Flickr API key (Flickr reviews each request):

1. Signed in to Flickr, open <https://www.flickr.com/services/apps/create/> and apply for a **non-commercial** key. Describe the use (for example "posting my own photos and art from my NEFORUM app").
2. When Flickr has issued it, copy the **Key** and **Secret** into the fields below and click Connect.
3. Flickr asks in the browser whether NEFORUM may upload to your account. Click **OK, I'll authorize it**.

NEFORUM asks for `write`: upload photos. The sign-in never expires.''';

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    if (tier == PlatformTier.handoff) {
      final name = (input['displayName'] ?? '').trim();
      return ConnectResult(
        account: ConnectedAccount(
          id: 'flickr:handoff:${const Uuid().v4()}',
          platformId: id,
          tier: PlatformTier.handoff,
          displayName: name.isEmpty ? 'Flickr (hand-off)' : name,
          createdAt: ctx.now(),
        ),
      );
    }
    if (tier != PlatformTier.byokApi) throw ConnectException('Flickr does not support the ${tier.label} tier');

    final key = (input['apiKey'] ?? '').trim();
    final secret = (input['apiSecret'] ?? '').trim();
    if (key.isEmpty) throw const ConnectException('Enter the Key of your Flickr app', field: 'apiKey');
    if (secret.isEmpty) throw const ConnectException('Enter the Secret of your Flickr app', field: 'apiSecret');

    final AuthBroker broker;
    try {
      broker = ctx.requireBroker();
    } on StateError {
      throw const ConnectException('Connecting Flickr needs a browser sign-in, which is not available here');
    }
    final spec = specFor(PlatformTier.byokApi);
    final callback = broker.chooseRedirectUri(
      loopbackOk: spec.loopbackRedirectOk,
      customSchemeOk: spec.customSchemeRedirectOk,
      fixed: spec.fixedRedirectUri,
    );

    final FlickrAccess access;
    try {
      final request = await FlickrApi(ctx, consumerKey: key, consumerSecret: secret, nonce: _nonce).requestToken(callback);
      final back = await broker.authorize(FlickrApi.authorizationUrl(request.token), callback);
      final q = back.queryParameters;
      if (q['oauth_token'] != null && q['oauth_token'] != request.token) {
        throw const ConnectException('Flickr sent back a different sign-in than NEFORUM asked for; try again');
      }
      // A pasted code arrives as `code` (see PasteCodeAuthBroker).
      final verifier = q['oauth_verifier'] ?? q['code'] ?? '';
      if (verifier.isEmpty) throw const ConnectException('You did not allow NEFORUM to upload to Flickr.');
      access = await FlickrApi(
        ctx,
        consumerKey: key,
        consumerSecret: secret,
        token: request.token,
        tokenSecret: request.secret,
        nonce: _nonce,
      ).accessToken(verifier);
    } on FlickrException catch (e) {
      throw ConnectException(_signInMessage(e));
    } on HttpFailure catch (e) {
      throw ConnectException('Flickr sign-in failed (HTTP ${e.statusCode}). Try again.');
    } on Exception catch (e) {
      if (!NeforumHttp.isTransportError(e)) rethrow;
      throw ConnectException('Could not reach Flickr ($e). Check your connection and try again.');
    }

    final name = access.fullName ?? access.username ?? access.userNsid;
    return ConnectResult(
      account: ConnectedAccount(
        id: 'flickr:${access.userNsid}',
        platformId: id,
        tier: PlatformTier.byokApi,
        displayName: name,
        handle: access.username,
        profileUrl: 'https://www.flickr.com/photos/${access.userNsid}/',
        createdAt: ctx.now(),
        config: {
          cfgUserNsid: access.userNsid,
          if (access.username != null) cfgUsername: access.username,
        },
      ),
      secrets: OAuth1Credentials(consumerKey: key, consumerSecret: secret, token: access.token, tokenSecret: access.secret)
          .toSecrets(),
    );
  }

  static String _signInMessage(FlickrException e) {
    final m = e.message.toLowerCase();
    if (m.contains('consumer_key') || m.contains('signature') || e.statusCode == 401) {
      return 'Flickr did not accept the Key and Secret (${e.message}). Copy both again from '
          'flickr.com/services/apps/by/me, and check that this device\'s date and time are right.';
    }
    return 'Flickr sign-in failed: ${e.message}.';
  }

  /// OAuth 1.0a tokens never expire and never change.
  @override
  Future<Map<String, String>?> refreshSecrets(
      ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier != PlatformTier.byokApi) return null;
    if (OAuth1Credentials.fromSecrets(secrets) == null) throw const AdapterException(PublishError.auth(_reconnectMessage));
    return null;
  }

  static const String _reconnectMessage = 'Flickr is not signed in. Reconnect Flickr in Accounts.';

  // ------------------------------------------------------------ validate

  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) {
    final issues = validateArtwork(variant, descriptor, tier: account.tier);
    final type = variant.extraAs<String>(extraContentType);
    if (type != null && !_contentTypes.containsKey(type)) {
      issues.add(ValidationIssue.error(
          'flickr.content_type', '$extraContentType must be photo, screenshot or art, not "$type"',
          field: 'account'));
    }
    return issues;
  }

  /// Flickr's `content_type` codes.
  static const Map<String, String> _contentTypes = {'photo': '1', 'screenshot': '2', 'art': '3'};

  // ------------------------------------------------------------- publish

  @override
  Future<PublishResult> publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    try {
      return await _publish(variant, account, secrets, ctx);
    } on AdapterException catch (e) {
      return PublishResult.failure(e.error);
    } on HttpFailure catch (e) {
      return PublishResult.failure(e.toPublishError(context: 'Uploading to Flickr'));
    } on Error {
      rethrow; // programming errors only
    } on Object catch (e) {
      final text = e.toString();
      if (NeforumHttp.isTransportError(e)) {
        return PublishResult.failure(PublishError.network('Could not reach Flickr ($text)', raw: text));
      }
      return PublishResult.failure(PublishError.platform('Flickr upload failed: $text', raw: text));
    }
  }

  Future<PublishResult> _publish(
      PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    if (account.tier == PlatformTier.handoff) {
      return PublishResult.failure(
          const PublishError.unsupported('This is a hand-off account; use the hand-off instead'));
    }
    final keys = OAuth1Credentials.fromSecrets(secrets);
    if (keys == null) return PublishResult.failure(const PublishError.auth(_reconnectMessage));
    final rejection = artworkRejection(validate(variant, account));
    if (rejection != null) return PublishResult.failure(rejection);
    final nsid = account.configString(cfgUserNsid);

    final api = FlickrApi(
      ctx,
      consumerKey: keys.consumerKey,
      consumerSecret: keys.consumerSecret,
      token: keys.token,
      tokenSecret: keys.tokenSecret,
      nonce: _nonce,
    );
    final fields = uploadFields(variant);
    final ids = <String>[];
    final files = variant.media;
    for (var i = 0; i < files.length; i++) {
      ctx.progress('Uploading ${files[i].isVideo ? 'video' : 'photo'} ${i + 1} of ${files.length}');
      try {
        final bytes = await _read(files[i], ctx);
        ids.add(await api.upload(files[i], bytes, fields));
      } on Exception catch (e) {
        final error = switch (e) {
          FlickrException() => FlickrApi.mapUploadError(e, context: 'Uploading to Flickr'),
          AdapterException() => e.error,
          HttpFailure() => e.toPublishError(context: 'Uploading to Flickr'),
          _ => NeforumHttp.isTransportError(e)
              ? PublishError.network('Could not reach Flickr ($e)', raw: '$e')
              : PublishError.platform('Flickr upload failed: $e', raw: '$e'),
        };
        if (ids.isEmpty) return PublishResult.failure(error);
        // Earlier files are on Flickr: a retry would upload them again.
        return PublishResult.failure(PublishError(
          kind: error.kind,
          message: 'File ${i + 1} of ${files.length} failed: ${error.message}. The files already uploaded '
              '(${ids.join(', ')}) stay on Flickr; upload the rest yourself.',
          statusCode: error.statusCode,
          raw: error.raw,
        ));
      }
    }
    return PublishResult.ok(
      remoteId: ids.first,
      remoteUrl: nsid.isEmpty ? null : FlickrApi.photoUrl(nsid, ids.first),
      threadRemoteIds: ids.length > 1 ? ids : const [],
      publishedAt: ctx.now(),
    );
  }

  /// The upload fields every file of [v] gets: title, description, tags, who
  /// may see it, its safety level (the rating) and its content type.
  static Map<String, String> uploadFields(PostVariant v) {
    final art = v.artwork ?? const ArtworkDetails();
    final title = artworkTitle(v);
    final description = artworkDescription(v);
    final tags = v.tags.map((t) => t.contains(' ') ? '"$t"' : t).join(' ');
    final (isPublic, isFriend, isFamily) = switch (v.visibility) {
      Visibility.public || Visibility.unlisted => ('1', '0', '0'),
      Visibility.followers => ('0', '1', '1'),
      Visibility.private => ('0', '0', '0'),
    };
    return {
      if (title.isNotEmpty) 'title': title,
      if (description.isNotEmpty) 'description': description,
      if (tags.isNotEmpty) 'tags': tags,
      'is_public': isPublic,
      'is_friend': isFriend,
      'is_family': isFamily,
      'safety_level': switch (art.maturity) {
        ArtworkMaturity.general => '1',
        ArtworkMaturity.mature => '2',
        ArtworkMaturity.adult => '3',
      },
      'content_type': _contentTypes[v.extraAs<String>(extraContentType)] ?? _contentTypes['art']!,
      // Unlisted: public, but kept out of Flickr's public search.
      'hidden': v.visibility == Visibility.unlisted ? '2' : '1',
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

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) {
    final art = variant.artwork;
    return artworkHandoff(
      variant,
      platformId: id,
      name: descriptor.name,
      uploadUrl: uploadUrl,
      hasApp: true,
      browserExtensionFills: true,
      androidPackage: 'com.yahoo.mobile.client.android.flickr',
      tagSeparator: ' ',
      ratingSteps: [
        if (art != null)
          'In the owner settings, set the content type to art or illustration and the safety level to '
              '**${switch (art.maturity) {
            ArtworkMaturity.general => 'Safe',
            ArtworkMaturity.mature => 'Moderate',
            ArtworkMaturity.adult => 'Restricted',
          }}**.',
      ],
      finishStep: 'Click **Upload**.',
    );
  }
}
