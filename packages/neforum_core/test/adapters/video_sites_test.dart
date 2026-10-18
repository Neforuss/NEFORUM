import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/video_sites/bitchute_adapter.dart';
import 'package:neforum_core/src/adapters/video_sites/odysee_adapter.dart';
import 'package:neforum_core/src/adapters/video_sites/rumble_adapter.dart';
import 'package:neforum_core/src/adapters/video_sites/video_site_common.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

http.Response _rpc(Object? result) => http.Response(jsonEncode({'jsonrpc': '2.0', 'result': result}), 200, headers: jsonHeaders);

void main() {
  group('video sites', () {
    test('Rumble, Odysee and BitChute are registered; only Odysee posts automatically', () {
      final r = builtinRegistry();
      expect(r.byId('rumble')!.descriptor.tiers, {PlatformTier.handoff});
      expect(r.byId('bitchute')!.descriptor.tiers, {PlatformTier.handoff});
      expect(r.byId('odysee')!.descriptor.tiers, {PlatformTier.openApi, PlatformTier.handoff});
      for (final id in ['rumble', 'odysee', 'bitchute']) {
        final d = r.byId(id)!.descriptor;
        expect(d.media.requiresMedia, isTrue, reason: id);
        expect(d.media.maxVideos, 1, reason: id);
        expect(d.setupGuide, 'docs/platforms/$id.md');
      }
    });

    test('the title is the post title, else its first line, cut to the limit', () {
      expect(videoTitle(const PostVariant(text: 'body', title: 'My video'), max: 100), 'My video');
      expect(videoTitle(const PostVariant(text: 'First line\nmore'), max: 100), 'First line');
      expect(videoTitle(PostVariant(text: 'x' * 150), max: 100), hasLength(100));
    });

    test('Rumble hand-off: upload page, description on the clipboard, title and tags to copy', () {
      final plan = RumbleAdapter().buildHandoff(PostVariant(text: 'Watch this', title: 'Clip', tags: const ['news', 'live'], media: [fakeVideo()]))!;
      expect(plan.desktopUrl, 'https://rumble.com/upload.php');
      expect(plan.clipboardText, 'Watch this');
      expect(plan.snippets.map((s) => (s.label, s.text)), [('Title', 'Clip'), ('Tags', 'news, live')]);
      expect(plan.shareFiles, hasLength(1));
      expect(plan.instructions, startsWith('1. '));
    });

    test('BitChute keeps three search hashtags and says so', () {
      final adapter = BitChuteAdapter();
      final v = PostVariant(text: 'x', title: 't', tags: const ['a', 'b', 'c', 'd'], media: [fakeVideo()]);
      expect(adapter.buildHandoff(v)!.snippets.last.text, 'a, b, c');
      expect(adapter.validate(v, fakeAccount('bitchute', tier: PlatformTier.handoff)).map((i) => i.code), contains('bitchute.tags'));
    });

    test('Odysee claim names: letters, digits and dashes', () {
      expect(OdyseeAdapter.slugFor('My first video!'), 'my-first-video');
      expect(OdyseeAdapter.slugFor('Ça va? #1 / @x'), 'ça-va-1-x');
      expect(OdyseeAdapter.slugFor('!!!'), 'video');
    });

    test('Odysee connect checks the LBRY app and finds the channel', () async {
      final methods = <String>[];
      final ctx = testContext(handler: (r) async {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        methods.add(body['method'] as String);
        expect(r.url.toString(), 'http://localhost:5279');
        return switch (body['method']) {
          'status' => _rpc({'is_running': true}),
          'channel_list' => _rpc({
              'items': [
                {'name': '@other', 'claim_id': 'aaa'},
                {'name': '@MyChannel', 'claim_id': 'c1a1m'},
              ],
            }),
          _ => throw StateError('unexpected ${body['method']}'),
        };
      });
      final result = await OdyseeAdapter().connect(PlatformTier.openApi, {'channel': 'mychannel'}, ctx);
      expect(methods, ['status', 'channel_list']);
      expect(result.account.displayName, '@MyChannel');
      expect(result.account.config['channelId'], 'c1a1m');
      expect(result.account.config['bid'], '0.001');
      expect(result.secrets, isEmpty);
    });

    test('Odysee connect explains when the LBRY app is not running', () async {
      final ctx = testContext(handler: (r) async => throw http.ClientException('Connection refused'));
      await expectLater(OdyseeAdapter().connect(PlatformTier.openApi, const {}, ctx),
          throwsA(isA<ConnectException>().having((e) => e.message, 'message', contains('Open the LBRY desktop app'))));
    });

    test('Odysee publish hands the file path to the SDK and links the claim', () async {
      late Map<String, dynamic> params;
      final ctx = testContext(handler: (r) async {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        params = Map<String, dynamic>.from(body['params'] as Map);
        return _rpc({
          'outputs': [
            {'claim_id': 'abc123', 'name': params['name']},
          ],
        });
      });
      final account = fakeAccount('odysee', config: const {'daemon': 'http://localhost:5279', 'channelId': 'c1a1m', 'bid': '0.01'});
      final res = await OdyseeAdapter().publish(
          PostVariant(text: 'About it', title: 'My Video', tags: const ['#News'], media: [fakeVideo()]), account, const {}, ctx);
      expect(res.success, isTrue);
      expect(params['file_path'], '/tmp/vid1.mp4');
      expect(params['title'], 'My Video');
      expect(params['description'], 'About it');
      expect(params['channel_id'], 'c1a1m');
      expect(params['bid'], '0.01');
      expect(params['tags'], ['news']);
      expect(params['name'] as String, startsWith('my-video-'));
      expect(res.remoteUrl, 'https://odysee.com/${params['name']}:abc123');
    });

    test('Odysee publish: too little LBC is a clear configuration error', () async {
      final ctx = testContext(
          handler: (r) async =>
              http.Response(jsonEncode({'error': {'code': -32500, 'message': 'Not enough funds to cover this transaction.'}}), 200, headers: jsonHeaders));
      final res = await OdyseeAdapter().publish(PostVariant(text: 'x', title: 't', media: [fakeVideo()]),
          fakeAccount('odysee', config: const {'bid': '0.001'}), const {}, ctx);
      expect(res.success, isFalse);
      expect(res.error!.message, contains('too little LBC'));
    });
  });
}
