import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/art/art_api_common.dart';
import 'package:neforum_core/src/adapters/art/deviantart_adapter.dart';
import 'package:neforum_core/src/adapters/art/dribbble_adapter.dart';
import 'package:neforum_core/src/adapters/art/dribbble_api.dart';
import 'package:neforum_core/src/adapters/art/flickr_adapter.dart';
import 'package:neforum_core/src/adapters/art/flickr_api.dart';
import 'package:neforum_core/src/adapters/art/inkbunny_adapter.dart';
import 'package:neforum_core/src/adapters/art/pixelfed_adapter.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

/// A tiny router: `'GET /api/v1/instance'` -> responses (the last one
/// repeats). Records every request.
class _Server {
  _Server(this.routes);

  final Map<String, List<http.Response> Function(http.Request r)> routes;
  final List<http.Request> calls = [];
  final Map<String, int> _hits = {};

  Future<http.Response> handle(http.Request r) async {
    calls.add(r);
    final key = '${r.method} ${r.url.path}';
    final route = routes[key];
    if (route == null) return http.Response('{"error":"not_found"}', 404, headers: jsonHeaders);
    final responses = route(r);
    final n = _hits.update(key, (v) => v + 1, ifAbsent: () => 0);
    return responses[n < responses.length ? n : responses.length - 1];
  }

  List<String> get trail => calls.map((c) => '${c.method} ${c.url.path}').toList();

  http.Request call(String path) => calls.firstWhere((c) => c.url.path == path);
}

http.Response _json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {...jsonHeaders, ...headers});

List<http.Response> _one(Object body, [int status = 200]) => [_json(body, status)];

/// Every part of a multipart body in order, repeated names kept; files as
/// `<filename>`.
List<MapEntry<String, String>> _parts(http.Request r) {
  final boundary = RegExp(r'boundary=(.+)$').firstMatch(r.headers['content-type'] ?? '')?.group(1);
  if (boundary == null) return const [];
  final out = <MapEntry<String, String>>[];
  for (final part in utf8.decode(r.bodyBytes, allowMalformed: true).split('--$boundary')) {
    final name = RegExp(r'name="([^"]+)"').firstMatch(part)?.group(1);
    if (name == null) continue;
    final fileName = RegExp(r'filename="([^"]+)"').firstMatch(part)?.group(1);
    final idx = part.indexOf('\r\n\r\n');
    out.add(MapEntry(name, fileName != null ? '<$fileName>' : part.substring(idx + 4).replaceFirst(RegExp(r'\r\n$'), '')));
  }
  return out;
}

Map<String, String> _fields(http.Request r) => {for (final e in _parts(r)) e.key: e.value};
List<String> _all(http.Request r, String name) => [for (final e in _parts(r)) if (e.key == name) e.value];

Map<String, String> _form(http.Request r) => Uri.splitQueryString(r.body);

const _art = ArtworkDetails();
const _adult = ArtworkDetails(maturity: ArtworkMaturity.adult, aiGenerated: true);
const _mature = ArtworkDetails(maturity: ArtworkMaturity.mature, disallowAiTraining: false);

PostVariant _artwork({
  ArtworkDetails artwork = _art,
  List<MediaAttachment>? media,
  String text = 'A quiet harbour at dusk',
  String? title = 'Harbour',
  List<String> tags = const ['painting', 'harbour', 'dusk', 'oil'],
  Visibility visibility = Visibility.public,
  Map<String, dynamic> extra = const {},
}) =>
    PostVariant(
      text: text,
      title: title,
      tags: tags,
      media: media ?? [fakeImage()],
      artwork: artwork,
      visibility: visibility,
      extra: extra,
      sourcePostId: 'post-1',
    );

Iterable<String> _codes(List<ValidationIssue> issues) => issues.map((i) => i.code);

/// The tiers whose descriptor takes a video, so a video alone is the work:
/// the Dribbble uploader, Flickr and Inkbunny. DeviantArt and Dribbble's API
/// take images only; Pixelfed takes video only where the server does (see
/// the Pixelfed group).
const _videoWork = {
  ('dribbble', PlatformTier.handoff),
  ('flickr', PlatformTier.handoff),
  ('flickr', PlatformTier.byokApi),
  ('inkbunny', PlatformTier.openApi),
  ('inkbunny', PlatformTier.handoff),
};

void main() {
  group('the five API art platforms', () {
    final registry = builtinRegistry();
    const expected = {
      'deviantart': ({PlatformTier.byokApi, PlatformTier.handoff}, PlatformTier.byokApi),
      'dribbble': ({PlatformTier.handoff, PlatformTier.byokApi}, PlatformTier.handoff),
      'pixelfed': ({PlatformTier.openApi, PlatformTier.handoff}, PlatformTier.openApi),
      'flickr': ({PlatformTier.handoff, PlatformTier.byokApi}, PlatformTier.handoff),
      'inkbunny': ({PlatformTier.openApi, PlatformTier.handoff}, PlatformTier.openApi),
    };

    for (final MapEntry(key: id, value: (tiers, defaultTier)) in expected.entries) {
      test('$id: registered as an art site with its tiers, needing an image', () {
        final d = registry.byId(id)!.descriptor;
        expect(d.categories, {PlatformCategory.art});
        expect(d.isArtPlatform, isTrue);
        expect(d.tiers, tiers);
        expect(d.defaultTier, defaultTier);
        expect(d.media.requiresMedia, isTrue);
        expect(d.media.maxImages, greaterThan(0));
        expect(d.text.titleSupported, isTrue);
        expect(d.setupGuide, 'docs/platforms/$id.md');
      });

      for (final tier in tiers) {
        test('$id ($tier): refuses posts that are not artwork or carry no work', () {
          final adapter = registry.byId(id)!;
          final account = fakeAccount(id, tier: tier);
          final notArt = PostVariant(text: 'Hello', title: 'Hi', tags: const ['a', 'b', 'c', 'd'], media: [fakeImage()]);
          expect(_codes(adapter.validate(notArt, account)), contains('art.not_artwork'));
          final empty = adapter.validate(_artwork(media: const []), account);
          expect(_codes(empty), contains('art.media_required'));
          expect(_codes(empty), isNot(contains('media.required')));
          final videoOnly = adapter.validate(_artwork(media: [fakeVideo()]), account);
          if (_videoWork.contains((id, tier))) {
            expect(videoOnly.where((i) => i.isError), isEmpty, reason: 'a video alone is the work on $id $tier');
            expect(empty.firstWhere((i) => i.code == 'art.media_required').message, contains('image or video'));
          } else {
            expect(_codes(videoOnly), contains('art.media_required'));
            expect(empty.firstWhere((i) => i.code == 'art.media_required').message, endsWith('needs at least one image.'));
          }
          // A NEFORUM text card is never the work.
          final card = MediaAttachment(id: 'card', path: '/tmp/card.png', mimeType: 'image/png', sizeBytes: 64, width: 800, height: 600, generated: true);
          expect(_codes(adapter.validate(_artwork(media: [card]), account)), contains('art.media_required'));
          final fine = _artwork(media: [fakeImage(width: 800, height: 600)]);
          expect(adapter.validate(fine, account).where((i) => i.isError), isEmpty, reason: '$id $tier');
        });
      }

      test('$id: the hand-off plan opens the upload page with numbered steps', () {
        final plan = registry.byId(id)!.buildHandoff(_artwork())!;
        expect(plan.platformId, id);
        expect(plan.desktopUrl, startsWith('https://'));
        expect(plan.instructions, startsWith('1. '));
        expect(plan.shareFiles, hasLength(1));
      });
    }
  });

  group('MultipartBody', () {
    test('repeats a field name and carries files', () async {
      late http.Request seen;
      final ctx = testContext(handler: (r) async {
        seen = r;
        return http.Response('{}', 200, headers: jsonHeaders);
      });
      final body = MultipartBody(boundary: 'b0undary')
        ..field('tags[]', 'one')
        ..field('tags[]', 'two "quoted"')
        ..file('file', fakeJpegBytes, fileName: 'a.jpg', contentType: 'image/jpeg');
      await ctx.http.send('POST', Uri.parse('https://example.test/up'),
          headers: {'Content-Type': body.contentType}, bytes: body.bytes);
      expect(seen.headers['content-type'], 'multipart/form-data; boundary=b0undary');
      expect(_all(seen, 'tags[]'), ['one', 'two "quoted"']);
      expect(_fields(seen)['file'], '<a.jpg>');
      expect(utf8.decode(seen.bodyBytes, allowMalformed: true), endsWith('--b0undary--\r\n'));
    });

    test('artwork title: the post title, else the first line, cut to the limit', () {
      expect(artworkTitle(_artwork()), 'Harbour');
      expect(artworkTitle(_artwork(title: null, text: 'First line\nmore')), 'First line');
      expect(artworkTitle(_artwork(title: 'x' * 80), max: 50), hasLength(50));
    });
  });

  // ---------------------------------------------------------------------------
  group('DeviantArt', () {
    final adapter = DeviantArtAdapter();
    final apiAccount = fakeAccount('deviantart',
        tier: PlatformTier.byokApi, config: const {'clientId': 'cid', 'redirectUri': 'http://127.0.0.1:52771/callback'});
    const secrets = {'access_token': 'tok', 'refresh_token': 'ref', 'token_type': 'Bearer', 'expires_at': '2026-10-07T13:00:00.000Z'};

    test('the API posts one image per deviation; the website up to 10', () {
      expect(adapter.descriptorForAccount(apiAccount).media.maxImages, 1);
      expect(adapter.descriptorForAccount(fakeAccount('deviantart', tier: PlatformTier.handoff)).media.maxImages, 10);
      expect(adapter.descriptor.text.titleMax, 50);
      expect(adapter.rotatesRefreshTokensFor(apiAccount), isTrue);
    });

    /// DeviantArt's token endpoint grants the scopes the user approved, and
    /// whoami refuses a token without `basic` and `user` (403
    /// insufficient_scope), as deviantart.readme.io/reference/user_whoami
    /// documents.
    _Server scopedServer(FakeAuthBroker broker) {
      Set<String> granted() => (broker.lastAuthorizationUrl?.queryParameters['scope'] ?? '').split(' ').toSet();
      return _Server({
        'POST /oauth2/token': (_) => _one({
              'status': 'success',
              'access_token': 'tok',
              'token_type': 'Bearer',
              'expires_in': 3600,
              'refresh_token': 'ref',
              'scope': granted().join(' '),
            }),
        'GET /api/v1/oauth2/user/whoami': (_) => granted().containsAll(const ['basic', 'user'])
            ? _one({
                'userid': 'A1B2',
                'username': 'harbourpainter',
                'usericon': 'https://a.deviantart.net/avatars/h.png',
              })
            : _one({'error': 'insufficient_scope', 'error_description': 'Insufficient scope.', 'status': 'error'}, 403),
      });
    }

    test('connect: OAuth 2.0 with PKCE on the loopback address, then whoami', () async {
      final broker = FakeAuthBroker(code: 'the-code');
      final server = scopedServer(broker);
      final r = await adapter.connect(
          PlatformTier.byokApi, {'clientId': ' 12345 '}, testContext(handler: server.handle, broker: broker));

      final auth = broker.lastAuthorizationUrl!;
      expect(auth.toString(), startsWith('https://www.deviantart.com/oauth2/authorize'));
      expect(auth.queryParameters['client_id'], '12345');
      expect(auth.queryParameters['scope'], 'basic user stash publish');
      expect(auth.queryParameters['redirect_uri'], 'http://127.0.0.1:52771/callback');
      expect(auth.queryParameters['code_challenge_method'], 'S256');

      expect(server.trail, ['POST /oauth2/token', 'GET /api/v1/oauth2/user/whoami']);
      final token = _form(server.calls.first);
      expect(token['grant_type'], 'authorization_code');
      expect(token['code'], 'the-code');
      expect(token['client_id'], '12345');
      expect(token['code_verifier'], isNotEmpty);
      expect(token.containsKey('client_secret'), isFalse, reason: 'a Public app has no secret');
      expect(server.calls[1].headers['Authorization'], 'Bearer tok');

      expect(r.account.id, 'deviantart:A1B2');
      expect(r.account.handle, 'harbourpainter');
      expect(r.account.profileUrl, 'https://www.deviantart.com/harbourpainter');
      expect(r.account.config['clientId'], '12345');
      expect(r.secrets['access_token'], 'tok');
      expect(r.secrets['refresh_token'], 'ref');
      expect(r.secrets.containsKey('client_secret'), isFalse);
    });

    test('connect: the client_id is required and refused redirects say what to whitelist', () async {
      final ctx = testContext(handler: (_) async => _json({}), broker: FakeAuthBroker());
      await expectLater(adapter.connect(PlatformTier.byokApi, const {}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'clientId')));
      final refusing = FakeAuthBroker(extraParams: {'error': 'invalid_request', 'error_description': 'redirect_uri mismatch'});
      await expectLater(
          adapter.connect(PlatformTier.byokApi, {'clientId': 'c'}, testContext(handler: (_) async => _json({}), broker: refusing)),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('Whitelist'))));
    });

    test('publish: Sta.sh submit with the details, then publish with the rating and AI labels', () async {
      final server = _Server({
        'POST /api/v1/oauth2/stash/submit': (_) => _one({'status': 'success', 'itemid': 7788}),
        'POST /api/v1/oauth2/stash/publish': (_) => _one({
              'status': 'success',
              'url': 'https://www.deviantart.com/harbourpainter/art/Harbour-123',
              'deviationid': 'DEV-1',
            }),
      });
      final v = _artwork(
        artwork: _adult,
        title: 'Harbour at dusk',
        text: 'Line one & <two>\nLine three',
        tags: const ['oil-painting', 'harbour', 'dusk', 'oil'],
      );
      expect(_codes(adapter.validate(_artwork(title: 'x' * 51), apiAccount)), contains('title.too_long'));
      expect(_codes(adapter.validate(v, apiAccount)), contains('deviantart.tags'));
      final res = await adapter.publish(v, apiAccount, secrets, testContext(handler: server.handle));
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteId, 'DEV-1');
      expect(res.remoteUrl, 'https://www.deviantart.com/harbourpainter/art/Harbour-123');

      final submit = server.call('/api/v1/oauth2/stash/submit');
      expect(submit.headers['Authorization'], 'Bearer tok');
      expect(submit.headers['dA-minor-version'], '20240701');
      final f = _fields(submit);
      expect(f['title'], 'Harbour at dusk');
      expect(f['artist_comments'], 'Line one &amp; &lt;two&gt;<br />Line three');
      expect(_all(submit, 'tags[]'), ['oilpainting', 'harbour', 'dusk', 'oil']);
      expect(f['is_ai_generated'], 'true');
      expect(f['noai'], 'true');
      expect(f['file'], '<img1.jpg>');

      final publish = _form(server.call('/api/v1/oauth2/stash/publish'));
      expect(publish['itemid'], '7788');
      expect(publish['is_mature'], 'true');
      expect(publish['mature_level'], 'strict');
      expect(publish['is_ai_generated'], 'true');
    });

    test('the rating: general is not mature; mature is moderate', () {
      expect(DeviantArtAdapter.publishForm('1', _art), {'itemid': '1', 'is_mature': 'false', 'is_ai_generated': 'false', 'noai': 'true'});
      final mature = DeviantArtAdapter.publishForm('1', _mature);
      expect((mature['is_mature'], mature['mature_level'], mature['noai']), ('true', 'moderate', 'false'));
    });

    test('a failed publish says the image waits in Sta.sh; a refused token asks to reconnect', () async {
      final failing = _Server({
        'POST /api/v1/oauth2/stash/submit': (_) => _one({'status': 'success', 'itemid': 5}),
        'POST /api/v1/oauth2/stash/publish': (_) =>
            _one({'status': 'error', 'error': 'invalid_request', 'error_description': 'Policy', 'error_code': 0}, 400),
      });
      final res = await adapter.publish(_artwork(), apiAccount, secrets, testContext(handler: failing.handle));
      expect(res.error!.kind, PublishErrorKind.validation);
      expect(res.error!.message, allOf(contains('submission policy'), contains('Sta.sh (item 5)')));

      final refused = await adapter.publish(_artwork(), apiAccount, secrets, testContext(handler: (_) async {
        return _json({'error': 'invalid_token', 'error_description': 'Expired oAuth2 user token'}, 401);
      }));
      expect(refused.error!.kind, PublishErrorKind.auth);
    });

    test('publish refuses a post that is not artwork before any request', () async {
      final calls = <http.Request>[];
      final res = await adapter.publish(PostVariant(text: 'x', title: 't', media: [fakeImage()]), apiAccount, secrets,
          testContext(handler: (r) async {
        calls.add(r);
        return _json({});
      }));
      expect(res.error!.kind, PublishErrorKind.validation);
      expect(calls, isEmpty);
    });

    test('an expired token is renewed with the refresh token', () async {
      late http.Request seen;
      final fresh = await adapter.refreshSecrets(apiAccount, secrets, testContext(
        now: DateTime.utc(2026, 10, 7, 14),
        handler: (r) async {
          seen = r;
          return _json({'access_token': 'tok2', 'refresh_token': 'ref2', 'expires_in': 3600, 'token_type': 'Bearer'});
        },
      ));
      expect(_form(seen)['grant_type'], 'refresh_token');
      expect(_form(seen)['refresh_token'], 'ref');
      expect(_form(seen)['client_id'], 'cid');
      expect(fresh!['access_token'], 'tok2');
      expect(fresh['refresh_token'], 'ref2');
      expect(await adapter.refreshSecrets(apiAccount, secrets, testContext(handler: (_) async => _json({}))), isNull,
          reason: 'still valid at testNow');
    });

    test('hand-off: the Studio submit page, the app on phones, the rating as a step', () {
      final plan = adapter.buildHandoff(_artwork(artwork: _adult))!;
      expect(plan.desktopUrl, 'https://www.deviantart.com/studio?new=1');
      expect(plan.androidPackage, 'com.deviantart.android.damobile');
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.clipboardText, 'A quiet harbour at dusk');
      expect(plan.snippets.map((s) => s.label), ['Title', 'Tags']);
      expect(plan.instructions, allOf(contains('**Strict**'), contains('Created using AI tools'), contains('Submit')));
    });
  });

  // ---------------------------------------------------------------------------
  group('Dribbble', () {
    final adapter = DribbbleAdapter();
    final apiAccount = fakeAccount('dribbble', tier: PlatformTier.byokApi, config: const {'clientId': 'cid'});
    const secrets = {'access_token': 'tok', 'token_type': 'Bearer'};

    test('the API takes photos of exactly 800 x 600 or 400 x 300; the website any size', () {
      final fit = adapter.photoFit(apiAccount, _artwork())!;
      expect((fit.minAspect, fit.maxAspect, fit.maxBytes), (4 / 3, 4 / 3, 8 * 1024 * 1024));
      final big = fakeImage(width: 1200, height: 800);
      expect(fit.problemsOf(big), containsAll([FitProblem.tooWide, FitProblem.pixels]));
      expect(fit.problemsOf(fakeImage(width: 800, height: 600)), isEmpty);
      expect(fit.problemsOf(fakeImage(width: 400, height: 300)), isEmpty);
      expect(fit.fittedSize(big, PhotoFitMode.pad), (width: 800, height: 600));
      expect(fit.problemsOf(fit.standIn(big, PhotoFitMode.crop)), isEmpty);
      expect(fit.describe(fakeImage(width: 640, height: 480), PhotoFitMode.pad), 'resized to 800 x 600');

      final web = adapter.photoFit(fakeAccount('dribbble', tier: PlatformTier.handoff), _artwork())!;
      expect(web.exactSizes, isNull);
      expect(web.problemsOf(big), isEmpty);
      expect(adapter.descriptorForAccount(apiAccount).media.maxVideos, 0);
    });

    test('validate: no adult work, a note on AI, GIFs of the wrong size stop the API', () {
      final handoff = fakeAccount('dribbble', tier: PlatformTier.handoff);
      expect(_codes(adapter.validate(_artwork(artwork: _adult), handoff)), containsAll(['dribbble.adult', 'dribbble.ai']));
      expect(_codes(adapter.validate(_artwork(artwork: _mature), handoff)), contains('dribbble.mature'));
      final gif = fakeImage(mimeType: 'image/gif', width: 500, height: 500);
      expect(_codes(adapter.validate(_artwork(media: [gif]), apiAccount)), contains('dribbble.image_size'));
      expect(_codes(adapter.validate(_artwork(media: [gif]), handoff)), isNot(contains('dribbble.image_size')));
      final limited = fakeAccount('dribbble', tier: PlatformTier.byokApi, config: const {'canUploadShot': false});
      expect(_codes(adapter.validate(_artwork(media: [fakeImage(width: 800, height: 600)]), limited)),
          contains('dribbble.cannot_upload'));
    });

    test('connect: the client secret goes to the token request, no PKCE, and is not kept', () async {
      final server = _Server({
        'POST /oauth/token': (_) => _one({'access_token': 'tok', 'token_type': 'bearer', 'scope': 'public upload'}),
        'GET /v2/user': (_) => _one({
              'id': 42,
              'name': 'Harbour Studio',
              'login': 'harbour',
              'html_url': 'https://dribbble.com/harbour',
              'avatar_url': 'https://cdn.dribbble.com/a.png',
              'can_upload_shot': true,
            }),
      });
      final broker = FakeAuthBroker(code: 'c0de');
      final r = await adapter.connect(PlatformTier.byokApi, {'clientId': 'cid', 'clientSecret': 'csecret'},
          testContext(handler: server.handle, broker: broker));
      final auth = broker.lastAuthorizationUrl!;
      expect(auth.host, 'dribbble.com');
      expect(auth.queryParameters['scope'], 'public upload');
      expect(auth.queryParameters.containsKey('code_challenge'), isFalse);
      final token = _form(server.call('/oauth/token'));
      expect((token['client_id'], token['client_secret'], token['code']), ('cid', 'csecret', 'c0de'));
      expect(token.containsKey('code_verifier'), isFalse);
      expect(r.account.id, 'dribbble:42');
      expect(r.account.displayName, 'Harbour Studio');
      expect(r.account.config['canUploadShot'], isTrue);
      expect(r.secrets.values, isNot(contains('csecret')));
      await expectLater(adapter.connect(PlatformTier.byokApi, {'clientId': 'cid'}, testContext(handler: server.handle, broker: broker)),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'clientSecret')));
    });

    test('publish: one shot with title, description and at most 12 tags', () async {
      late http.Request seen;
      final ctx = testContext(handler: (r) async {
        seen = r;
        return http.Response('', 202, headers: {'location': 'https://api.dribbble.com/v2/shots/987654'});
      });
      final tags = [for (var i = 0; i < 15; i++) 'tag$i'];
      final res = await adapter.publish(_artwork(media: [fakeImage(width: 800, height: 600)], tags: tags), apiAccount, secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteId, '987654');
      expect(res.remoteUrl, 'https://dribbble.com/shots/987654');
      expect(seen.url.toString(), 'https://api.dribbble.com/v2/shots');
      expect(seen.headers['Authorization'], 'Bearer tok');
      expect(_fields(seen)['title'], 'Harbour');
      expect(_fields(seen)['description'], 'A quiet harbour at dusk');
      expect(_all(seen, 'tags[]'), hasLength(12));
      expect(_fields(seen)['image'], '<img1.jpg>');
      expect(DribbbleApi.shotIdFrom('https://dribbble.com/shots/123-harbour'), '123');
    });

    test('a 403 explains that the account may not upload yet', () async {
      final res = await adapter.publish(_artwork(media: [fakeImage(width: 800, height: 600)]), apiAccount, secrets,
          testContext(handler: (_) async => _json({'message': 'You are not allowed to upload shots'}, 403)));
      expect(res.error!.kind, PublishErrorKind.auth);
      expect(res.error!.message, contains('Designer'));
    });

    test('hand-off: the uploader, filled in by the browser extension, tags in Final Touches', () {
      final plan = adapter.buildHandoff(_artwork(tags: [for (var i = 0; i < 15; i++) 't$i']))!;
      expect(plan.desktopUrl, 'https://dribbble.com/uploads/new');
      expect(plan.composerUrl.toString(), 'https://dribbble.com/uploads/new');
      expect(plan.composerInstructions, isNotNull);
      expect(plan.preferred, HandoffMethod.manual, reason: 'no confirmed upload app');
      expect(plan.snippets.last.text.split(', '), hasLength(12));
      expect(plan.instructions, allOf(contains('Final Touches'), contains('**Publish**')));
    });

    test('hand-off: a video alone is the shot; the API takes images only', () {
      final video = _artwork(media: [fakeVideo(mimeType: 'video/quicktime')]);
      final handoff = fakeAccount('dribbble', tier: PlatformTier.handoff);
      expect(adapter.validate(video, handoff).where((i) => i.isError), isEmpty);
      expect(adapter.buildHandoff(video)!.instructions, contains('Add your video'));
      expect(_codes(adapter.validate(video, apiAccount)), contains('art.media_required'));
    });
  });

  // ---------------------------------------------------------------------------
  group('Pixelfed', () {
    final adapter = PixelfedAdapter(mediaPollInterval: Duration.zero, maxMediaPolls: 2, clock: () => testNow);
    const config = {
      'instance': 'https://pixelfed.example',
      'domain': 'pixelfed.example',
      'software': 'pixelfed',
      'maxCharacters': 2000,
      'maxMediaAttachments': 20,
      'supportedMimeTypes': ['image/jpeg', 'image/png', 'image/webp', 'video/mp4'],
    };
    final account = fakeAccount('pixelfed', config: config);
    const secrets = {'client_id': 'cid', 'client_secret': 'cs', 'access_token': 'tok', 'token_type': 'Bearer'};

    Map<String, dynamic> instance(String version) => {
          'uri': 'pixelfed.example',
          'title': 'Pixelfed Example',
          'version': version,
          'max_toot_chars': 2000,
          'configuration': {
            'statuses': {'max_characters': 2000, 'max_media_attachments': 20},
            'media_attachments': {
              'supported_mime_types': ['image/jpeg', 'image/png', 'image/webp', 'video/mp4'],
              'image_size_limit': 15360000,
            },
          },
        };

    test('server limits apply; the descriptor is Pixelfed\'s, not Mastodon\'s', () {
      final d = adapter.descriptorForAccount(account);
      expect(d.id, 'pixelfed');
      expect(d.name, 'Pixelfed');
      expect(d.text.maxLength, 2000);
      expect(d.text.supportsThreads, isFalse);
      expect(d.media.maxImages, 20);
      expect(d.media.maxVideos, 1);
      expect(d.media.imageMimeTypes, contains('image/webp'));
      expect(d.serverSideScheduling, isFalse);
      expect(adapter.descriptor.text.maxLength, 500, reason: 'Pixelfed\'s default');
      expect(adapter.descriptor.media.maxVideos, 0);
    });

    test('connect: registers NEFORUM on the Pixelfed server and signs in', () async {
      final server = _Server({
        'GET /api/v1/instance': (_) => _one(instance('3.5.3 (compatible; Pixelfed 0.12.4)')),
        'POST /api/v1/apps': (_) => _one({'client_id': 'cid', 'client_secret': 'cs'}),
        'POST /oauth/token': (_) => _one({'access_token': 'tok', 'token_type': 'Bearer'}),
        'GET /api/v1/accounts/verify_credentials': (_) =>
            _one({'id': '77', 'username': 'painter', 'display_name': 'Painter', 'url': 'https://pixelfed.example/painter'}),
      });
      final r = await adapter.connect(PlatformTier.openApi, {'instance': 'pixelfed.example'},
          testContext(handler: server.handle, broker: FakeAuthBroker()));
      expect(r.account.platformId, 'pixelfed');
      expect(r.account.handle, '@painter@pixelfed.example');
      expect(r.account.config['software'], 'pixelfed');
      expect(_form(server.call('/api/v1/apps'))['scopes'], 'read write');
      expect(r.secrets['access_token'], 'tok');
    });

    test('connect: a Mastodon server belongs under Mastodon', () async {
      final server = _Server({
        'GET /api/v1/instance': (_) => _one({'uri': 'mastodon.example', 'version': '4.5.0'}),
      });
      await expectLater(
          adapter.connect(PlatformTier.openApi, {'instance': 'mastodon.example'},
              testContext(handler: server.handle, broker: FakeAuthBroker())),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('Add it as a Mastodon account'))));
      expect(server.trail, isNot(contains('POST /api/v1/apps')));
    });

    test('publish: the title opens the caption and mature work is sensitive', () async {
      final server = _Server({
        'POST /api/v2/media': (_) => _one({'id': 'm1', 'url': 'https://pixelfed.example/m1.jpg'}),
        'POST /api/v1/statuses': (_) => _one({'id': 's1', 'url': 'https://pixelfed.example/p/painter/s1'}),
      });
      final res = await adapter.publish(_artwork(artwork: _mature, tags: const []), account, secrets,
          testContext(handler: server.handle));
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteUrl, 'https://pixelfed.example/p/painter/s1');
      final status = _form(server.call('/api/v1/statuses'));
      expect(status['status'], 'Harbour\n\nA quiet harbour at dusk');
      expect(status['sensitive'], 'true');
      expect(status['media_ids[]'], 'm1');
    });

    test('validate: artwork only, and the caption with its title must fit', () {
      final issues = adapter.validate(PostVariant(text: 'x', media: [fakeImage()]), account);
      expect(_codes(issues), contains('art.not_artwork'));
      final short = fakeAccount('pixelfed', config: {...config, 'maxCharacters': 30});
      expect(_codes(adapter.validate(_artwork(), short)), contains('text.too_long'));
      final handoff = fakeAccount('pixelfed', tier: PlatformTier.handoff, config: config);
      expect(_codes(adapter.validate(_artwork(), handoff)), isNot(contains('handoff.media')));
    });

    test('a video alone is the work on a server that takes video, never on one that does not', () async {
      final video = _artwork(media: [fakeVideo()]);
      expect(adapter.validate(video, account).where((i) => i.isError), isEmpty);
      final handoff = fakeAccount('pixelfed', tier: PlatformTier.handoff, config: config);
      expect(adapter.validate(video, handoff).where((i) => i.isError), isEmpty);
      expect(adapter.buildHandoff(video, account: handoff)!.instructions, contains('Add your video'));
      final imagesOnly = fakeAccount('pixelfed', config: {...config, 'supportedMimeTypes': ['image/jpeg', 'image/png']});
      expect(_codes(adapter.validate(video, imagesOnly)), contains('art.media_required'));

      final calls = <http.Request>[];
      final refused = await adapter.publish(video, imagesOnly, secrets, testContext(handler: (r) async {
        calls.add(r);
        return _json({});
      }));
      expect(refused.error!.kind, PublishErrorKind.validation);
      expect(calls, isEmpty, reason: 'refused before any request');
    });

    test('hand-off: the server\'s Create New Post page with the caption copied', () {
      final plan = adapter.buildHandoff(_artwork(artwork: _adult), account: fakeAccount('pixelfed', tier: PlatformTier.handoff, config: config))!;
      expect(plan.desktopUrl, 'https://pixelfed.example/i/compose');
      expect(plan.clipboardText, 'Harbour\n\nA quiet harbour at dusk');
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.instructions, contains('**Sensitive**'));
      expect(adapter.buildHandoff(_artwork())!.desktopUrl, 'https://pixelfed.org');
    });
  });

  // ---------------------------------------------------------------------------
  group('Flickr', () {
    final adapter = FlickrAdapter(nonce: () => 'n0nce');
    final apiAccount = fakeAccount('flickr', tier: PlatformTier.byokApi, config: const {'userNsid': '12345@N01'});
    final secrets = const OAuth1Credentials(consumerKey: 'ck', consumerSecret: 'cs', token: 't', tokenSecret: 'ts').toSecrets();

    test('requests are signed over every parameter, the OAuth ones included', () {
      final ctx = testContext(handler: (_) async => _json({}));
      final api = FlickrApi(ctx, consumerKey: 'ck', consumerSecret: 'cs', token: 't', tokenSecret: 'ts', nonce: () => 'n');
      final url = Uri.parse('https://up.flickr.com/services/upload/');
      final signed = api.signedParams('POST', url, {'title': 'Harbour'});
      expect(signed['oauth_timestamp'], '${testNow.millisecondsSinceEpoch ~/ 1000}');
      expect(signed['oauth_token'], 't');
      final unsigned = Map<String, String>.from(signed)..remove('oauth_signature');
      expect(signed['oauth_signature'], OAuth1.signature(OAuth1.baseString('POST', url, unsigned.entries), 'cs', 'ts'));
    });

    test('connect: request token, the authorization page, access token', () async {
      final server = _Server({
        'GET /services/oauth/request_token': (_) =>
            [http.Response('oauth_callback_confirmed=true&oauth_token=req-1&oauth_token_secret=req-secret', 200)],
        'GET /services/oauth/access_token': (_) => [
              http.Response(
                  'fullname=Harbour%20Painter&oauth_token=acc-1&oauth_token_secret=acc-secret&user_nsid=12345%40N01&username=harbour',
                  200)
            ],
      });
      final broker = FakeAuthBroker(extraParams: {'oauth_token': 'req-1', 'oauth_verifier': 'ver-1'});
      final r = await adapter.connect(
          PlatformTier.byokApi, {'apiKey': 'ck', 'apiSecret': 'cs'}, testContext(handler: server.handle, broker: broker));

      final request = server.call('/services/oauth/request_token').url.queryParameters;
      expect(request['oauth_callback'], 'http://127.0.0.1:52771/callback');
      expect(request['oauth_consumer_key'], 'ck');
      expect(request['oauth_signature'], isNotEmpty);
      expect(broker.lastAuthorizationUrl.toString(),
          'https://www.flickr.com/services/oauth/authorize?oauth_token=req-1&perms=write');
      final access = server.call('/services/oauth/access_token').url.queryParameters;
      expect((access['oauth_token'], access['oauth_verifier']), ('req-1', 'ver-1'));

      expect(r.account.id, 'flickr:12345@N01');
      expect(r.account.displayName, 'Harbour Painter');
      expect(r.account.handle, 'harbour');
      expect(r.account.profileUrl, 'https://www.flickr.com/photos/12345@N01/');
      final keys = OAuth1Credentials.fromSecrets(r.secrets)!;
      expect((keys.consumerKey, keys.token, keys.tokenSecret), ('ck', 'acc-1', 'acc-secret'));
    });

    test('connect: a refused key is explained', () async {
      final ctx = testContext(
          handler: (_) async => http.Response('oauth_problem=consumer_key_unknown', 401), broker: FakeAuthBroker());
      await expectLater(adapter.connect(PlatformTier.byokApi, {'apiKey': 'ck', 'apiSecret': 'cs'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('Key and Secret'))));
    });

    test('publish: every file as its own photo with the safety level and content type', () async {
      final uploads = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        uploads.add(r);
        return http.Response('<?xml version="1.0" encoding="utf-8" ?>\n<rsp stat="ok">\n<photoid>${1000 + uploads.length}</photoid>\n</rsp>', 200);
      });
      final v = _artwork(artwork: _adult, media: [fakeImage(), fakeImage(id: 'img2')], visibility: Visibility.unlisted);
      final res = await adapter.publish(v, apiAccount, secrets, ctx);
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteId, '1001');
      expect(res.remoteUrl, 'https://www.flickr.com/photos/12345@N01/1001/');
      expect(res.threadRemoteIds, ['1001', '1002']);
      expect(uploads, hasLength(2));
      final f = _fields(uploads.first);
      expect(uploads.first.url.toString(), 'https://up.flickr.com/services/upload/');
      expect((f['title'], f['description'], f['tags']), ('Harbour', 'A quiet harbour at dusk', 'painting harbour dusk oil'));
      expect((f['safety_level'], f['content_type'], f['is_public'], f['hidden']), ('3', '3', '1', '2'));
      expect((f['oauth_token'], f['oauth_consumer_key']), ('t', 'ck'));
      expect(f['oauth_signature'], isNotEmpty);
      expect(f['photo'], '<img1.jpg>');
    });

    test('the second file failing reports what is already on Flickr', () async {
      var n = 0;
      final ctx = testContext(handler: (r) async {
        n++;
        return n == 1
            ? http.Response('<rsp stat="ok"><photoid>1001</photoid></rsp>', 200)
            : http.Response('<rsp stat="fail"><err code="6" msg="User exceeded upload limit" /></rsp>', 200);
      });
      final res = await adapter.publish(_artwork(media: [fakeImage(), fakeImage(id: 'img2')]), apiAccount, secrets, ctx);
      expect(res.error!.kind, PublishErrorKind.quota);
      expect(res.error!.retryable, isFalse);
      expect(res.error!.message, allOf(contains('File 2 of 2'), contains('1001')));
    });

    test('upload errors map to sign-in, quota or validation problems', () {
      PublishErrorKind kind(int code) => FlickrApi.mapUploadError(FlickrException('x', code: code)).kind;
      expect(kind(99), PublishErrorKind.auth);
      expect(kind(98), PublishErrorKind.auth);
      expect(kind(6), PublishErrorKind.quota);
      expect(kind(5), PublishErrorKind.validation);
      expect(kind(105), PublishErrorKind.network);
      expect(FlickrAdapter.uploadFields(_artwork(extra: const {'flickrContentType': 'photo'}))['content_type'], '1');
      expect(FlickrAdapter.uploadFields(_artwork(visibility: Visibility.followers))['is_friend'], '1');
    });

    test('hand-off: the uploader with the app on phones and the safety level as a step', () {
      final plan = adapter.buildHandoff(_artwork(artwork: _mature))!;
      expect(plan.desktopUrl, 'https://www.flickr.com/photos/upload/');
      expect(plan.composerUrl.toString(), 'https://www.flickr.com/photos/upload/');
      expect(plan.androidPackage, 'com.yahoo.mobile.client.android.flickr');
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.snippets.last.text, 'painting harbour dusk oil');
      expect(plan.instructions, contains('**Moderate**'));
    });
  });

  // ---------------------------------------------------------------------------
  group('Inkbunny', () {
    final adapter = InkbunnyAdapter();
    final account = fakeAccount('inkbunny', config: const {'username': 'painter'});
    const secrets = {'sid': 'S1D'};

    test('connect: username and password in the body once; only the session is kept', () async {
      late http.Request seen;
      final r = await adapter.connect(PlatformTier.openApi, {'username': 'painter', 'password': 'hunter2'},
          testContext(handler: (req) async {
        seen = req;
        return _json({'sid': 'S1D', 'user_id': '4242', 'ratingsmask': '11111'});
      }));
      expect(seen.url.toString(), 'https://inkbunny.net/api_login.php');
      expect(seen.url.query, isEmpty);
      expect(_form(seen), {'username': 'painter', 'password': 'hunter2'});
      expect(r.secrets, {'sid': 'S1D'});
      expect(r.account.id, 'inkbunny:4242');
      expect(jsonEncode(r.account.toJson()), isNot(contains('hunter2')));
    });

    test('connect: a refused sign-in mentions API access', () async {
      final ctx = testContext(handler: (_) async => _json({'error_code': 0, 'error_message': 'Invalid login'}));
      await expectLater(adapter.connect(PlatformTier.openApi, {'username': 'p', 'password': 'x'}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('Enable API Access'))));
    });

    test('validate: at least four keywords; every rating is accepted', () {
      expect(_codes(adapter.validate(_artwork(tags: const ['a', 'b']), account)), contains('inkbunny.keywords'));
      expect(adapter.validate(_artwork(artwork: const ArtworkDetails(maturity: ArtworkMaturity.adult)), account).where((i) => i.isError),
          isEmpty);
    });

    test('publish: upload every file, then the details with the rating flags', () async {
      final server = _Server({
        'POST /api_upload.php': (_) => _one({'sid': 'S1D', 'submission_id': '9001'}),
        'POST /api_editsubmission.php': (_) => _one({'sid': 'S1D', 'submission_id': '9001'}),
      });
      final v = _artwork(artwork: _adult, media: [fakeImage(), fakeImage(id: 'img2')]);
      final res = await adapter.publish(v, account, secrets, testContext(handler: server.handle));
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteUrl, 'https://inkbunny.net/s/9001');
      final upload = server.call('/api_upload.php');
      expect(_fields(upload)['sid'], 'S1D');
      expect(_all(upload, 'uploadedfile[]'), ['<img1.jpg>', '<img2.jpg>']);
      final edit = _form(server.call('/api_editsubmission.php'));
      expect(edit['submission_id'], '9001');
      expect(edit['title'], 'Harbour');
      expect(edit['desc'], 'A quiet harbour at dusk');
      expect(edit['keywords'], 'painting,harbour,dusk,oil');
      expect(edit['visibility'], 'yes');
      expect(edit['tag[4]'], 'yes');
      expect(edit.containsKey('tag[2]'), isFalse);
    });

    test('publish: one MP4 video alone becomes the submission', () async {
      final server = _Server({
        'POST /api_upload.php': (_) => _one({'sid': 'S1D', 'submission_id': '9003'}),
        'POST /api_editsubmission.php': (_) => _one({'sid': 'S1D', 'submission_id': '9003'}),
      });
      final res = await adapter.publish(_artwork(media: [fakeVideo()]), account, secrets, testContext(handler: server.handle));
      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteUrl, 'https://inkbunny.net/s/9003');
      final upload = server.call('/api_upload.php');
      expect(_all(upload, 'uploadedfile[]'), ['<vid1.mp4>']);
      expect(utf8.decode(upload.bodyBytes, allowMalformed: true), contains('Content-Type: video/mp4'));
    });

    test('an ended session asks to reconnect; a failed edit names the hidden submission', () async {
      final ended = await adapter.publish(_artwork(), account, secrets,
          testContext(handler: (_) async => _json({'error_code': 2, 'error_message': 'Invalid Session ID'})));
      expect(ended.error!.kind, PublishErrorKind.auth);

      final half = _Server({
        'POST /api_upload.php': (_) => _one({'submission_id': '9002'}),
        'POST /api_editsubmission.php': (_) => _one({'error_code': 6, 'error_message': 'Hourly limit'}),
      });
      final res = await adapter.publish(_artwork(), account, secrets, testContext(handler: half.handle));
      expect(res.error!.kind, PublishErrorKind.quota);
      expect(res.error!.retryable, isFalse);
      expect(res.error!.message, contains('https://inkbunny.net/s/9002'));
    });

    test('mature work marks nudity; followers-only is friends only', () {
      final form = InkbunnyAdapter.editForm('s', '1', _artwork(artwork: _mature, visibility: Visibility.followers));
      expect((form['tag[2]'], form['friends_only'], form['visibility']), ('yes', 'yes', 'yes'));
      expect(InkbunnyAdapter.editForm('s', '1', _artwork(visibility: Visibility.private))['visibility'], 'no');
    });

    test('hand-off: the site with the ratings as a step', () {
      final plan = adapter.buildHandoff(_artwork(artwork: _adult))!;
      expect(plan.desktopUrl, 'https://inkbunny.net/');
      expect(plan.preferred, HandoffMethod.manual);
      expect(plan.instructions, contains('**Sexual Themes**'));
    });
  });
}
