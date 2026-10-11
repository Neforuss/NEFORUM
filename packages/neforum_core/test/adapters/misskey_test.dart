import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/misskey/misskey_adapter.dart';
import 'package:neforum_core/src/adapters/misskey/misskey_api.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

const _session = '0f6b8a3e-2f5b-4c2a-9d7e-1a2b3c4d5e6f';

http.Response _json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {...jsonHeaders, ...headers});

Map<String, dynamic> _meta({int maxLen = 3000}) => {
      'name': 'Misskey Test',
      'version': '2025.12.2',
      'maxNoteTextLength': maxLen,
      'maxFileSize': 262144000,
      'policies': {'maxFileSizeMb': 30, 'driveCapacityMb': 100, 'canPublicNote': true},
      'features': {'miauth': true},
    };

Map<String, dynamic> _me() => {
      'id': '9abc',
      'username': 'alice',
      'name': 'Alice',
      'avatarUrl': 'https://misskey.example/avatar.webp',
      'policies': {
        'maxFileSizeMb': 50,
        'canPublicNote': true,
        'uploadableFileTypes': ['image/*', 'video/*'],
      },
    };

ConnectedAccount _account({Map<String, dynamic> extra = const {}, PlatformTier tier = PlatformTier.openApi}) =>
    fakeAccount('misskey', tier: tier, config: {
      'instance': 'https://misskey.example',
      'host': 'misskey.example',
      'maxNoteTextLength': 3000,
      ...extra,
    });

const _secrets = {'access_token': 'TOKEN123'};

void main() {
  final adapter = MisskeyAdapter(newSessionId: () => _session);

  group('descriptor', () {
    test('limits match the research', () {
      final d = adapter.descriptor;
      expect(d.id, 'misskey');
      expect(d.tiers, {PlatformTier.openApi, PlatformTier.handoff});
      expect(d.defaultTier, PlatformTier.openApi);
      expect(d.text.maxLength, 3000);
      expect(d.text.supportsThreads, isTrue);
      expect(d.text.supportsContentWarning, isTrue);
      expect(d.text.titleSupported, isFalse);
      expect(d.media.maxImages, 16);
      expect(d.media.allowsMixedImageVideo, isTrue);
      expect(d.media.imageMaxBytes, 31457280);
      expect(d.media.supportsAltText, isTrue);
      expect(d.media.requiresPublicMediaUrl, isFalse);
      expect(d.defaultQuotas.single.id, 'misskey.notes_per_hour');
      expect(d.defaultQuotas.single.limit, 300);
      expect(d.defaultQuotas.single.window, const Duration(hours: 1));
      expect(d.personalAccountOk, isTrue);
      expect(d.setupGuide, 'docs/platforms/misskey.md');
      expect(d.serverSideScheduling, isFalse);
    });

    test('connect specs: token field is secret and optional', () {
      final spec = adapter.specFor(PlatformTier.openApi);
      expect(spec.usesBrowser, isTrue);
      final token = spec.fields.firstWhere((f) => f.key == 'token');
      expect(token.secret, isTrue);
      expect(token.required, isFalse);
      expect(spec.intro, contains('write:notes'));
      expect(adapter.specFor(PlatformTier.handoff).fields.map((f) => f.key), ['instance']);
    });

    test('descriptorFor applies instance limits', () {
      final d = adapter.descriptorFor(_account(extra: {'maxNoteTextLength': 100000, 'maxFileSizeMb': 1000, 'maxFileSize': 524288000}));
      expect(d.text.maxLength, 100000);
      expect(d.media.imageMaxBytes, 524288000);
    });
  });

  group('instance parsing', () {
    test('accepts hosts, URLs and handles', () {
      expect(parseMisskeyInstance('misskey.io').toString(), 'https://misskey.io');
      expect(parseMisskeyInstance(' https://Misskey.io/notes/abc ').toString(), 'https://misskey.io');
      expect(parseMisskeyInstance('@alice@transfem.social').toString(), 'https://transfem.social');
    });
    test('rejects junk', () {
      expect(() => parseMisskeyInstance(''), throwsA(isA<ConnectException>()));
      expect(() => parseMisskeyInstance('notahost'), throwsA(isA<ConnectException>()));
      expect(() => parseMisskeyInstance('http://misskey.io'), throwsA(isA<ConnectException>()));
    });
  });

  group('connect', () {
    test('token path: meta then i, stores config and secrets', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path == '/api/meta') return _json(_meta());
        if (r.url.path == '/api/i') return _json(_me());
        return _json({}, 404);
      });
      final res = await adapter.connect(PlatformTier.openApi, {'instance': 'misskey.example', 'token': ' TOKEN123 '}, ctx);

      expect(calls.map((c) => '${c.method} ${c.url}'), [
        'POST https://misskey.example/api/meta',
        'POST https://misskey.example/api/i',
      ]);
      expect(bodyOf(calls[0]), {'detail': true});
      expect(bodyOf(calls[1]), {'i': 'TOKEN123'});
      expect(res.secrets['access_token'], 'TOKEN123');
      final a = res.account;
      expect(a.id, 'misskey:9abc@misskey.example');
      expect(a.handle, '@alice@misskey.example');
      expect(a.displayName, 'Alice (misskey.example)');
      expect(a.profileUrl, 'https://misskey.example/@alice');
      expect(a.config['instance'], 'https://misskey.example');
      expect(a.config['maxNoteTextLength'], 3000);
      expect(a.config['maxFileSizeMb'], 50, reason: 'user policy from /api/i wins');
      expect(a.config['uploadableFileTypes'], ['image/*', 'video/*']);
      expect(a.config['authMethod'], 'token');
      expect(a.config['userId'], '9abc');
    });

    test('bad token -> ConnectException on the token field', () async {
      final ctx = testContext(handler: (r) async {
        if (r.url.path == '/api/meta') return _json(_meta());
        return _json({
          'error': {'message': 'Authentication failed.', 'code': 'AUTHENTICATION_FAILED', 'id': 'b0a7f5f8-dc2f-4171-b91f-de88ad238e14'}
        }, 401);
      });
      await expectLater(
        adapter.connect(PlatformTier.openApi, {'instance': 'misskey.example', 'token': 'nope'}, ctx),
        throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'token')),
      );
    });

    test('non-Misskey server -> ConnectException', () async {
      final ctx = testContext(handler: (r) async => http.Response('not found', 404));
      await expectLater(
        adapter.connect(PlatformTier.openApi, {'instance': 'mastodon.example', 'token': 'x'}, ctx),
        throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('Mastodon'))),
      );
    });

    test('MiAuth: opens /miauth/{uuid} and exchanges the session', () async {
      final calls = <http.Request>[];
      final broker = FakeAuthBroker(extraParams: {'session': _session});
      final ctx = testContext(
        broker: broker,
        handler: (r) async {
          calls.add(r);
          if (r.url.path == '/api/meta') return _json(_meta());
          if (r.url.path == '/api/miauth/$_session/check') {
            return _json({'ok': true, 'token': 'MIAUTHTOKEN', 'user': {'id': '9abc', 'username': 'alice'}});
          }
          if (r.url.path == '/api/i') return _json(_me());
          return _json({}, 404);
        },
      );
      final res = await adapter.connect(PlatformTier.openApi, {'instance': 'misskey.example'}, ctx);

      final auth = broker.lastAuthorizationUrl!;
      expect(auth.host, 'misskey.example');
      expect(auth.path, '/miauth/$_session');
      expect(auth.queryParameters['name'], 'NEFORUM');
      expect(auth.queryParameters['callback'], 'http://127.0.0.1:52771/callback');
      expect(auth.queryParameters['permission'], 'write:notes,write:drive,read:account');
      expect(calls.map((c) => '${c.method} ${c.url.path}'), [
        'POST /api/meta',
        'POST /api/miauth/$_session/check',
        'POST /api/i',
      ]);
      expect(bodyOf(calls[2]), {'i': 'MIAUTHTOKEN'});
      expect(res.secrets['access_token'], 'MIAUTHTOKEN');
      expect(res.account.config['authMethod'], 'miauth');
    });

    test('MiAuth not approved -> AuthCancelled', () async {
      final ctx = testContext(
        broker: FakeAuthBroker(),
        handler: (r) async {
          if (r.url.path == '/api/meta') return _json(_meta());
          return _json({'ok': false});
        },
      );
      await expectLater(
        adapter.connect(PlatformTier.openApi, {'instance': 'misskey.example'}, ctx),
        throwsA(isA<AuthCancelled>()),
      );
    });

    test('no token and no browser -> asks for a token', () async {
      final ctx = testContext(handler: (r) async => _json(_meta()));
      await expectLater(
        adapter.connect(PlatformTier.openApi, {'instance': 'misskey.example'}, ctx),
        throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'token')),
      );
    });

    test('hand-off tier only checks the instance', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json(_meta());
      });
      final res = await adapter.connect(PlatformTier.handoff, {'instance': 'misskey.example'}, ctx);
      expect(calls, hasLength(1));
      expect(res.secrets, isEmpty);
      expect(res.account.tier, PlatformTier.handoff);
      expect(res.account.config['instance'], 'https://misskey.example');
    });
  });

  group('validate', () {
    test('uses the instance note length', () {
      final long = 'a' * 5000;
      final small = adapter.validate(PostVariant(text: long), _account());
      expect(small.map((i) => i.code), contains('text.too_long'));
      final big = adapter.validate(PostVariant(text: long), _account(extra: {'maxNoteTextLength': 100000}));
      expect(big.map((i) => i.code), isNot(contains('text.too_long')));
    });

    test('cw, file count, file types, alt text', () {
      final v = PostVariant(
        text: 'hi',
        contentWarning: 'x' * 101,
        media: [
          for (var i = 0; i < 17; i++) fakeImage(id: 'i$i'),
          fakeImage(id: 'svg', mimeType: 'image/png', altText: 'y' * 600),
        ],
      );
      final codes = adapter.validate(v, _account(extra: {'uploadableFileTypes': ['image/jpeg']})).map((i) => i.code).toList();
      expect(codes, containsAll(['cw.too_long', 'media.too_many', 'media.type_not_allowed', 'media.alt_too_long']));
    });

    test('warns when the role cannot post publicly', () {
      final codes = adapter.validate(const PostVariant(text: 'hi'), _account(extra: {'canPublicNote': false})).map((i) => i.code);
      expect(codes, contains('visibility.public_not_allowed'));
    });

    test('a valid post has no errors', () {
      final issues = adapter.validate(PostVariant(text: 'hello', media: [fakeImage()]), _account());
      expect(issues.hasErrors, isFalse);
    });
  });

  group('publish', () {
    test('uploads media then creates the note', () async {
      final calls = <http.Request>[];
      var n = 0;
      final progress = <String>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path == '/api/drive/files/create') return _json({'id': 'file${++n}'});
        if (r.url.path == '/api/notes/create') return _json({'createdNote': {'id': 'note1'}});
        return _json({}, 404);
      }).copyWith(onProgress: progress.add);

      final v = PostVariant(
        text: 'Hello #neforum',
        contentWarning: 'spoilers',
        sensitive: true,
        visibility: Visibility.unlisted,
        media: [fakeImage(id: 'a', altText: 'first'), fakeImage(id: 'b', altText: null)],
        extra: const {'localOnly': true},
      );
      final res = await adapter.publish(v, _account(), _secrets, ctx);

      expect(res.success, isTrue, reason: '${res.error}');
      expect(res.remoteId, 'note1');
      expect(res.remoteUrl, 'https://misskey.example/notes/note1');
      expect(calls.map((c) => '${c.method} ${c.url}'), [
        'POST https://misskey.example/api/drive/files/create',
        'POST https://misskey.example/api/drive/files/create',
        'POST https://misskey.example/api/notes/create',
      ]);
      final up1 = multipartFieldsOf(calls[0]);
      expect(up1['i'], 'TOKEN123');
      expect(up1['file'], '<a.jpg>');
      expect(up1['name'], 'a.jpg');
      expect(up1['comment'], 'first');
      expect(up1['isSensitive'], 'true');
      final up2 = multipartFieldsOf(calls[1]);
      expect(up2.containsKey('comment'), isFalse);
      // Text fields must precede the file part for the server to see them.
      final raw = utf8.decode(calls[0].bodyBytes, allowMalformed: true);
      expect(raw.indexOf('name="i"'), lessThan(raw.indexOf('name="file"')));

      expect(bodyOf(calls[2]), {
        'i': 'TOKEN123',
        'text': 'Hello #neforum',
        'visibility': 'home',
        'cw': 'spoilers',
        'fileIds': ['file1', 'file2'],
        'localOnly': true,
      });
      expect(progress, containsAll(['Uploading image 1 of 2', 'Uploading image 2 of 2', 'Posting note']));
    });

    test('media-only note sends text: null', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path == '/api/drive/files/create') return _json({'id': 'f1'});
        return _json({'createdNote': {'id': 'n1'}});
      });
      final res = await adapter.publish(PostVariant(text: '  ', media: [fakeImage()]), _account(), _secrets, ctx);
      expect(res.success, isTrue);
      final body = bodyOf(calls.last);
      expect(body.containsKey('text'), isTrue);
      expect(body['text'], isNull);
      expect(body['visibility'], 'public');
    });

    test('thread: parts chained with replyId, media on the first part', () async {
      final calls = <http.Request>[];
      var n = 0;
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        if (r.url.path == '/api/drive/files/create') return _json({'id': 'f1'});
        return _json({'createdNote': {'id': 'n${++n}'}});
      });
      final v = PostVariant(text: 'one', threadParts: const ['one', 'two', 'three'], media: [fakeImage()]);
      final res = await adapter.publish(v, _account(), _secrets, ctx);

      expect(res.success, isTrue);
      expect(res.remoteId, 'n1');
      expect(res.threadRemoteIds, ['n1', 'n2', 'n3']);
      final notes = calls.where((c) => c.url.path == '/api/notes/create').map(bodyOf).toList();
      expect(notes, hasLength(3));
      expect(notes[0]['fileIds'], ['f1']);
      expect(notes[0].containsKey('replyId'), isFalse);
      expect(notes[1]['text'], 'two');
      expect(notes[1]['replyId'], 'n1');
      expect(notes[1].containsKey('fileIds'), isFalse);
      expect(notes[2]['replyId'], 'n2');
    });

    test('private maps to specified, extra visibleUserIds passed', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json({'createdNote': {'id': 'n1'}});
      });
      await adapter.publish(
          const PostVariant(text: 'psst', visibility: Visibility.private, extra: {'visibleUserIds': ['u1']}),
          _account(),
          _secrets,
          ctx);
      expect(bodyOf(calls.single)['visibility'], 'specified');
      expect(bodyOf(calls.single)['visibleUserIds'], ['u1']);
    });

    Future<PublishResult> failWith(http.Response response, {PostVariant? variant}) {
      final ctx = testContext(handler: (r) async => response);
      return adapter.publish(variant ?? const PostVariant(text: 'hi'), _account(), _secrets, ctx);
    }

    test('401 -> auth', () async {
      final r = await failWith(_json({
        'error': {'message': 'Authentication failed.', 'code': 'AUTHENTICATION_FAILED', 'id': 'b0a7f5f8-dc2f-4171-b91f-de88ad238e14'}
      }, 401));
      expect(r.success, isFalse);
      expect(r.error!.kind, PublishErrorKind.auth);
    });

    test('PERMISSION_DENIED (403) -> auth with a hint about permissions', () async {
      final r = await failWith(_json({
        'error': {'message': 'Your app does not have the necessary permissions.', 'code': 'PERMISSION_DENIED', 'kind': 'permission'}
      }, 403));
      expect(r.error!.kind, PublishErrorKind.auth);
      expect(r.error!.message, contains('write:notes'));
    });

    test('429 -> quota with retryAfter', () async {
      final r = await failWith(_json({
        'error': {'message': 'Rate limit exceeded.', 'code': 'RATE_LIMIT_EXCEEDED', 'id': 'd5826d14-3982-4d2e-8011-b9e9f02499ef'}
      }, 429, {'retry-after': '42'}));
      expect(r.error!.kind, PublishErrorKind.quota);
      expect(r.error!.retryAfter, const Duration(seconds: 42));
    });

    test('429 without header uses info.resetMs', () async {
      final reset = testNow.add(const Duration(seconds: 90)).millisecondsSinceEpoch;
      final r = await failWith(_json({
        'error': {'code': 'RATE_LIMIT_EXCEEDED', 'info': {'resetMs': reset}}
      }, 429));
      expect(r.error!.retryAfter, const Duration(seconds: 90));
    });

    test('prohibited words (400) -> validation, message kept', () async {
      final r = await failWith(_json({
        'error': {'message': 'Cannot post because it contains prohibited words.', 'code': 'CONTAINS_PROHIBITED_WORDS', 'kind': 'client'}
      }, 400));
      expect(r.error!.kind, PublishErrorKind.validation);
      expect(r.error!.message, contains('prohibited'));
    });

    test('413 with empty body on upload -> validation', () async {
      final r = await failWith(http.Response('', 413), variant: PostVariant(text: 'x', media: [fakeImage()]));
      expect(r.error!.kind, PublishErrorKind.validation);
      expect(r.error!.statusCode, 413);
    });

    test('NO_FREE_SPACE -> validation', () async {
      final r = await failWith(_json({
        'error': {'message': 'Cannot upload the file because you have no free space of drive.', 'code': 'NO_FREE_SPACE', 'kind': 'client'}
      }, 400), variant: PostVariant(text: 'x', media: [fakeImage()]));
      expect(r.error!.kind, PublishErrorKind.validation);
      expect(r.error!.message, contains('Drive'));
    });

    test('suspended -> platform, not auth', () async {
      final r = await failWith(_json({
        'error': {'message': 'Your account has been suspended.', 'code': 'YOUR_ACCOUNT_SUSPENDED', 'kind': 'permission'}
      }, 403));
      expect(r.error!.kind, PublishErrorKind.platform);
    });

    test('500 -> network', () async {
      final r = await failWith(_json({'error': {'message': 'Internal error occurred.', 'code': 'INTERNAL_ERROR', 'kind': 'server'}}, 500));
      expect(r.error!.kind, PublishErrorKind.network);
      expect(r.error!.retryable, isTrue);
    });

    test('missing token -> auth without a request', () async {
      final ctx = testContext(handler: (r) async => fail('no request expected'));
      final r = await adapter.publish(const PostVariant(text: 'hi'), _account(), const {}, ctx);
      expect(r.error!.kind, PublishErrorKind.auth);
    });

    test('tokens never expire: refreshSecrets returns null', () async {
      final ctx = testContext(handler: (r) async => fail('no request expected'));
      expect(await adapter.refreshSecrets(_account(), _secrets, ctx), isNull);
    });
  });

  group('hand-off', () {
    test('share URL on the user\'s instance', () {
      final plan = adapter.buildHandoff(
        const PostVariant(text: 'Hello & welcome', visibility: Visibility.followers),
        account: _account(tier: PlatformTier.handoff),
      )!;
      expect(plan.webIntent!.scheme, 'https');
      expect(plan.webIntent!.host, 'misskey.example');
      expect(plan.webIntent!.path, '/share');
      expect(plan.webIntent!.queryParameters, {'text': 'Hello & welcome', 'visibility': 'followers'});
      expect(plan.clipboardText, 'Hello & welcome');
      expect(plan.preferred, HandoffMethod.webIntent);
      expect(plan.instructions, startsWith('1.'));
    });

    test('without an account uses the Misskey Hub relay; media -> share sheet', () {
      final plan = adapter.buildHandoff(PostVariant(text: 'pic', media: [fakeImage()], contentWarning: 'cw'))!;
      expect(plan.webIntent.toString(), 'https://misskey-hub.net/share?text=pic');
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.shareFiles, hasLength(1));
      expect(plan.mediaNote, isNotNull);
      expect(plan.instructions, contains('content warning'));
    });

    test('thread: first part prefilled, all parts on the clipboard', () {
      final plan = adapter.buildHandoff(const PostVariant(text: 'a', threadParts: ['a', 'b']), account: _account())!;
      expect(plan.webIntent!.queryParameters['text'], 'a');
      expect(plan.clipboardText, 'a\n\nb');
    });
  });
}
