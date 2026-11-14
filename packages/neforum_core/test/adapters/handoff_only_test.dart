import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/handoff_only/google_business_adapter.dart';
import 'package:neforum_core/src/adapters/handoff_only/handoff_common.dart';
import 'package:neforum_core/src/adapters/handoff_only/locals_adapter.dart';
import 'package:neforum_core/src/adapters/handoff_only/parler_adapter.dart';
import 'package:neforum_core/src/adapters/handoff_only/snapchat_adapter.dart';
import 'package:neforum_core/src/adapters/handoff_only/substack_adapter.dart';
import 'package:neforum_core/src/adapters/handoff_only/whatsapp_adapter.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

/// A context whose HTTP fails the test: hand-off adapters must never call out.
AdapterContext _noHttp(List<http.Request> calls) => testContext(handler: (req) async {
      calls.add(req);
      return http.Response('unexpected', 500);
    });

final List<HandoffOnlyAdapter> _all = [
  SnapchatAdapter(),
  WhatsAppAdapter(),
  GoogleBusinessAdapter(),
  SubstackAdapter(),
  ParlerAdapter(),
  LocalsAdapter(),
];

/// The optional fields a hand-off adapter asks for after the label.
const Map<String, List<String>> _extraFields = {
  'parler': ['premium'],
  'locals': ['community'],
};

ConnectedAccount _acct(String platformId) => fakeAccount(platformId, tier: PlatformTier.handoff);

Iterable<String> _codes(List<ValidationIssue> issues) => issues.map((i) => i.code);

void main() {
  group('common hand-off behaviour', () {
    for (final a in _all) {
      group(a.id, () {
        test('descriptor is hand-off only and points at its guide', () {
          final d = a.descriptor;
          expect(d.tiers, {PlatformTier.handoff});
          expect(d.defaultTier, PlatformTier.handoff);
          expect(d.setupGuide, 'docs/platforms/${a.id}.md');
          expect(d.text.supportsThreads, isFalse);
          expect(d.serverSideScheduling, isFalse);
          expect(d.defaultQuotas, isEmpty);
          expect(d.media.supportsAltText, isFalse);
          expect(d.media.requiresPublicMediaUrl, isFalse);
          expect(d.accountRequirements, isNotEmpty);
          expect(d.apiCostSummary, isNotEmpty);
        });

        test('connect spec: an optional label field (and its own optional fields), no browser, no redirects', () {
          expect(a.connectSpecs, hasLength(1));
          final spec = a.connectSpecs.single;
          expect(spec.tier, PlatformTier.handoff);
          expect(spec.usesBrowser, isFalse);
          expect(spec.loopbackRedirectOk, isFalse);
          expect(spec.customSchemeRedirectOk, isFalse);
          expect(spec.fixedRedirectUri, isNull);
          expect(spec.fields.map((f) => f.key), ['label', ...?_extraFields[a.id]]);
          final f = spec.fields.first;
          expect(f.kind, FieldKind.text);
          for (final field in spec.fields) {
            expect(field.required, isFalse, reason: field.key);
            expect(field.secret, isFalse, reason: field.key);
          }
          expect(spec.intro, contains('hand-off only'));
          expect(spec.intro.toLowerCase(), contains('api'));
        });

        test('connect() makes an account without HTTP or secrets', () async {
          final calls = <http.Request>[];
          final r = await a.connect(PlatformTier.handoff, {'label': '  My shop  '}, _noHttp(calls));
          expect(calls, isEmpty);
          expect(r.secrets, isEmpty);
          expect(r.account.platformId, a.id);
          expect(r.account.tier, PlatformTier.handoff);
          expect(r.account.displayName, 'My shop');
          expect(r.account.config, {'label': 'My shop'});
          expect(r.account.id, startsWith('${a.id}:handoff:'));
          expect(r.account.createdAt, testNow);
        });

        test('connect() without a label uses the default name', () async {
          final r = await a.connect(PlatformTier.handoff, const {}, _noHttp([]));
          expect(r.account.displayName, '${a.descriptor.name} (hand-off)');
          expect(r.account.config, isEmpty);
        });

        test('connect() rejects other tiers and over-long labels', () async {
          await expectLater(
              a.connect(PlatformTier.byokApi, const {}, _noHttp([])), throwsA(isA<ConnectException>()));
          await expectLater(
            a.connect(PlatformTier.handoff, {'label': 'x' * 81}, _noHttp([])),
            throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'label')),
          );
        });

        test('publish() returns unsupported without touching the network', () async {
          final calls = <http.Request>[];
          final r = await a.publish(
              const PostVariant(text: 'Hello'), _acct(a.id), const {}, _noHttp(calls));
          expect(calls, isEmpty);
          expect(r.isFailure, isTrue);
          expect(r.error!.kind, PublishErrorKind.unsupported);
          expect(r.error!.message, contains(a.descriptor.name));
        });

        test('refreshSecrets() has nothing to refresh', () async {
          expect(await a.refreshSecrets(_acct(a.id), const {}, _noHttp([])), isNull);
        });

        test('hand-off puts the full thread text on the clipboard', () {
          const v = PostVariant(text: 'Part one', threadParts: ['Part one', 'Part two']);
          final plan = a.buildHandoff(v)!;
          expect(plan.platformId, a.id);
          expect(plan.clipboardText, 'Part one\n\nPart two');
          expect(plan.instructions, startsWith('1. '));
          expect(plan.mediaNote, isNotNull);
        });
      });
    }
  });

  group('WhatsApp', () {
    final a = WhatsAppAdapter();

    test('descriptor limits', () {
      final d = a.descriptor;
      expect(d.id, 'whatsapp');
      expect(d.text.maxLength, isNull);
      expect(d.media.maxImages, 100);
      expect(d.media.maxVideos, 100);
      expect(d.media.allowsMixedImageVideo, isTrue);
      expect(d.personalAccountOk, isTrue);
    });

    test('text-only hand-off prefers the wa.me web intent', () {
      const text = 'Hello world & friends? #1 ünïcode 🎉\nline 2';
      final plan = a.buildHandoff(const PostVariant(text: text))!;
      expect(plan.preferred, HandoffMethod.webIntent);
      final uri = plan.webIntent!;
      expect(uri.scheme, 'https');
      expect(uri.host, 'wa.me');
      expect(uri.path, '/');
      expect(uri.queryParameters.keys, ['text']);
      expect(uri.queryParameters['text'], text);
      // Spaces are percent-encoded, never '+', so every client decodes them.
      expect(uri.toString(), startsWith('https://wa.me/?text=Hello%20world%20%26%20friends%3F%20%231'));
      expect(plan.clipboardText, text);
      expect(plan.shareText, text);
      expect(plan.androidPackage, 'com.whatsapp');
      expect(plan.iosScheme, 'whatsapp://');
      expect(plan.desktopUrl, 'https://web.whatsapp.com/');
      expect(plan.shareFiles, isEmpty);
    });

    test('media hand-off prefers the share sheet and still carries the text', () {
      final img = fakeImage();
      final plan = a.buildHandoff(PostVariant(text: 'Look', media: [img]))!;
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.shareFiles, [img]);
      expect(plan.shareText, 'Look');
      expect(plan.webIntent, isNotNull);
      expect(plan.instructions, contains('My status'));
    });

    test('media-only hand-off has no web intent', () {
      final plan = a.buildHandoff(PostVariant(text: '', media: [fakeImage()]))!;
      expect(plan.webIntent, isNull);
      expect(plan.clipboardText, isNull);
    });

    test('validate(): Status notes for long video and several items', () {
      final acct = _acct('whatsapp');
      expect(a.validate(const PostVariant(text: 'hi'), acct), isEmpty);
      final issues = a.validate(
          PostVariant(text: 'hi', media: [fakeImage(), fakeVideo(durationMs: 90000)]), acct);
      expect(_codes(issues), containsAll(['whatsapp.status_video_length', 'whatsapp.status_multiple']));
      expect(issues.hasErrors, isFalse);
    });
  });

  group('Snapchat', () {
    final a = SnapchatAdapter();

    test('descriptor limits match Creative Kit docs', () {
      final d = a.descriptor;
      expect(d.id, 'snapchat');
      expect(d.text.maxLength, 250);
      expect(d.text.counting, CountingRule.utf16);
      expect(d.media.requiresMedia, isTrue);
      expect(d.media.maxImages, 1);
      expect(d.media.maxVideos, 1);
      expect(d.media.imageMaxBytes, 300 * 1024 * 1024);
      expect(d.media.videoMaxBytes, 300 * 1024 * 1024);
      expect(d.media.videoMaxSeconds, 300);
      expect(d.media.imageMimeTypes, {'image/jpeg', 'image/png'});
      expect(d.media.videoMimeTypes, {'video/mp4', 'video/quicktime'});
    });

    test('validate(): needs media, one item, JPEG/PNG, length, vertical hint', () {
      final acct = _acct('snapchat');
      expect(_codes(a.validate(const PostVariant(text: 'hi'), acct)), contains('media.required'));
      expect(a.validate(PostVariant(text: 'hi', media: [fakeImage(width: 1080, height: 1920)]), acct), isEmpty);
      expect(_codes(a.validate(PostVariant(text: 'hi', media: [fakeImage(id: 'a'), fakeImage(id: 'b')]), acct)),
          contains('media.too_many_images'));
      expect(_codes(a.validate(PostVariant(text: 'hi', media: [fakeImage(mimeType: 'image/webp')]), acct)),
          contains('media.image_type'));
      expect(_codes(a.validate(PostVariant(text: 'x' * 251, media: [fakeImage()]), acct)), contains('text.too_long'));
      expect(_codes(a.validate(PostVariant(text: 'hi', media: [fakeVideo(durationMs: 301000)]), acct)),
          contains('media.video_too_long'));
      final wide = a.validate(PostVariant(text: 'hi', media: [fakeImage(width: 1920, height: 1080)]), acct);
      expect(_codes(wide), ['snapchat.aspect_ratio']);
      expect(wide.single.severity, IssueSeverity.info);
    });

    test('hand-off shares media to the Snapchat app with the caption on the clipboard', () {
      final vid = fakeVideo();
      final plan = a.buildHandoff(PostVariant(text: 'My caption', media: [vid]))!;
      expect(plan.preferred, HandoffMethod.shareSheet);
      expect(plan.webIntent, isNull);
      expect(plan.shareFiles, [vid]);
      expect(plan.shareText, isNull, reason: 'Snapchat ignores shared text');
      expect(plan.clipboardText, 'My caption');
      expect(plan.androidPackage, 'com.snapchat.android');
      expect(plan.iosScheme, 'snapchat://');
      expect(plan.desktopUrl, 'https://www.snapchat.com/web/');
      expect(plan.mediaNote, contains('Only the photo or video'));
    });

    test('hand-off without media is manual', () {
      final plan = a.buildHandoff(const PostVariant(text: 'Just text'))!;
      expect(plan.preferred, HandoffMethod.manual);
      expect(plan.instructions, contains('need a photo or video'));
    });
  });

  group('Google Business Profile', () {
    final a = GoogleBusinessAdapter();

    test('descriptor limits', () {
      final d = a.descriptor;
      expect(d.id, 'google_business');
      expect(d.text.maxLength, 1500);
      expect(d.personalAccountOk, isFalse);
      expect(d.supportsLinkField, isTrue);
      expect(d.media.maxImages, 1);
      expect(d.media.maxVideos, 1);
      expect(d.media.imageMaxBytes, 5 * 1024 * 1024);
      expect(d.media.videoMaxBytes, 75 * 1024 * 1024);
      expect(d.media.videoMaxSeconds, 30);
      expect(d.media.imageMimeTypes, {'image/jpeg', 'image/png'});
    });

    test('validate(): length, media and phone numbers', () {
      final acct = _acct('google_business');
      expect(a.validate(const PostVariant(text: 'Open late on Friday 2026-10-09!'), acct), isEmpty);
      expect(_codes(a.validate(PostVariant(text: 'x' * 1501), acct)), contains('text.too_long'));
      expect(_codes(a.validate(PostVariant(text: 'hi', media: [fakeVideo(durationMs: 31000)]), acct)),
          contains('media.video_too_long'));
      expect(_codes(a.validate(PostVariant(text: 'hi', media: [fakeImage(sizeBytes: 6 * 1024 * 1024)]), acct)),
          contains('media.image_too_large'));
      for (final t in ['Call us: +1 (555) 123-4567', 'Ring 020 7946 0958 today', 'Tel. 555.123.4567']) {
        expect(_codes(a.validate(PostVariant(text: t), acct)), contains('google_business.phone_in_text'), reason: t);
      }
      expect(GoogleBusinessAdapter.hasPhoneNumber('Prices from 1,500 to 2,000 EUR'), isFalse);
    });

    test('hand-off opens business.google.com with text on the clipboard and the link as a button', () {
      final img = fakeImage();
      final plan = a.buildHandoff(PostVariant(text: 'New menu!', link: 'https://example.org/menu', media: [img]))!;
      expect(plan.preferred, HandoffMethod.manual);
      expect(plan.webIntent, isNull);
      expect(plan.desktopUrl, 'https://business.google.com/');
      expect(plan.androidPackage, 'com.google.android.apps.maps');
      expect(plan.iosScheme, 'comgooglemaps://');
      expect(plan.clipboardText, 'New menu!');
      expect(plan.shareFiles, [img]);
      // Labels from support.google.com/business/answer/7390603.
      expect(plan.instructions, contains('**Posts** > **Add post**'));
      expect(plan.instructions, isNot(contains('Add update')));
      expect(plan.instructions, contains('Under **Button**, pick **Learn more** and enter https://example.org/menu'));
      expect(plan.instructions.split('\n'), hasLength(4));
      expect(plan.instructions, startsWith('1. '));
      expect(plan.instructions, contains('\n4. Select **Post**.'));
    });

    test('hand-off without link or media has three steps', () {
      final plan = a.buildHandoff(const PostVariant(text: 'Closed Monday'))!;
      expect(plan.instructions.split('\n'), hasLength(3));
      expect(plan.instructions, isNot(contains('**Button**')));
      expect(a.connectSpecs.single.intro, contains('**Posts** > **Add post**'));
    });
  });

  group('Substack Notes', () {
    final a = SubstackAdapter();

    test('descriptor limits', () {
      final d = a.descriptor;
      expect(d.id, 'substack');
      expect(d.name, 'Substack Notes');
      expect(d.text.maxLength, isNull);
      expect(d.media.maxImages, 6);
      expect(d.media.maxVideos, 1);
      expect(d.media.allowsMixedImageVideo, isFalse);
      expect(d.personalAccountOk, isTrue);
    });

    test('validate(): image count and GIF note', () {
      final acct = _acct('substack');
      final seven = [for (var i = 0; i < 7; i++) fakeImage(id: 'i$i')];
      expect(_codes(a.validate(PostVariant(text: 'hi', media: seven), acct)), contains('media.too_many_images'));
      expect(_codes(a.validate(PostVariant(text: 'hi', media: [fakeImage(mimeType: 'image/gif')]), acct)),
          ['substack.gif_web_only']);
      expect(_codes(a.validate(PostVariant(text: 'hi', media: [fakeImage(), fakeVideo()]), acct)),
          contains('media.mixed'));
    });

    test('hand-off opens Substack Notes with text on the clipboard', () {
      final plan = a.buildHandoff(const PostVariant(text: 'A note'))!;
      expect(plan.preferred, HandoffMethod.manual);
      expect(plan.webIntent, isNull);
      expect(plan.desktopUrl, 'https://substack.com/notes');
      expect(plan.instructions, contains('Ctrl+V'));
      expect(plan.androidPackage, 'com.substack.app');
      expect(plan.iosScheme, isNull);
      expect(plan.clipboardText, 'A note');
      expect(plan.instructions, contains("What's on your mind?"));
      expect(plan.instructions.split('\n'), hasLength(3));
    });

    test('hand-off with media adds an attach step', () {
      final plan = a.buildHandoff(PostVariant(text: 'Pics', media: [fakeImage()]))!;
      expect(plan.shareFiles, hasLength(1));
      expect(plan.instructions.split('\n'), hasLength(4));
    });
  });

  group('Parler', () {
    final a = ParlerAdapter();
    final free = _acct('parler');
    final premium = fakeAccount('parler', tier: PlatformTier.handoff, config: {'premium': true});

    test('descriptor: the limits read from the composer (2026-11-13)', () {
      final d = a.descriptor;
      expect((d.id, d.name, d.homepage), ('parler', 'Parler', 'https://parler.com/'));
      expect(d.text.maxLength, 300);
      expect(d.text.counting, CountingRule.codePoints);
      expect(d.text.supportsThreads, isFalse);
      expect(d.media.maxImages, 4);
      expect(d.media.maxVideos, 4);
      expect(d.media.allowsMixedImageVideo, isTrue);
      expect(d.media.imageMaxBytes, 20 * 1024 * 1024);
      expect(d.media.videoMaxBytes, 500 * 1024 * 1024);
      expect(d.media.videoMaxSeconds, 3600);
      // The composer's file input: accept="image/jpeg,image/png,image/gif,image/webp,video/mp4,video/quicktime,video/webm".
      expect(d.media.imageMimeTypes, {'image/jpeg', 'image/png', 'image/gif', 'image/webp'});
      expect(d.media.videoMimeTypes, {'video/mp4', 'video/quicktime', 'video/webm'});
      expect(d.media.audioAsVideo, isTrue);
      expect(d.personalAccountOk, isTrue);
    });

    test('Premium accounts get 2000 characters; the free limit stays 300', () {
      expect(a.descriptorForAccount(free).text.maxLength, 300);
      expect(a.descriptorForAccount(premium).text.maxLength, 2000);
      expect(a.descriptorForAccount(fakeAccount('parler', tier: PlatformTier.handoff, config: {'premium': 'true'})).text.maxLength, 2000,
          reason: 'a form value kept as text');
      expect(a.descriptorForAccount(fakeAccount('parler', tier: PlatformTier.handoff, config: {'premium': false})).text.maxLength, 300);
      final long = PostVariant(text: 'x' * 301);
      expect(_codes(a.validate(long, free)), contains('text.too_long'));
      expect(_codes(a.validate(long, premium)), isNot(contains('text.too_long')), reason: 'validate uses the account\'s limit');
      expect(_codes(a.validate(PostVariant(text: 'x' * 2001), premium)), contains('text.too_long'));
    });

    test('counts code points, as the composer does: an emoji is one, not two', () {
      // 299 letters and one emoji outside the BMP: 301 UTF-16 units, 300 code points.
      final text = '${'a' * 299}😀';
      expect(text.length, 301);
      expect(TextCounter.count(text, a.descriptor.text), 300);
      expect(_codes(a.validate(PostVariant(text: text), free)), isNot(contains('text.too_long')));
      expect(_codes(a.validate(PostVariant(text: '$text!'), free)), contains('text.too_long'));
      // A link counts at its full length (no fixed link weight).
      const link = 'https://example.org/a/rather/long/path/that/is/over/twenty/three';
      expect(TextCounter.count(link, a.descriptor.text), link.length);
    });

    test('connect(): Parler Premium is kept only when turned on', () async {
      final on = await a.connect(PlatformTier.handoff, {'label': 'Me', 'premium': 'true'}, _noHttp([]));
      expect(on.account.config, {'label': 'Me', 'premium': true});
      expect(ParlerAdapter.isPremium(on.account), isTrue);
      expect(a.descriptorForAccount(on.account).text.maxLength, 2000);
      final off = await a.connect(PlatformTier.handoff, {'label': 'Me', 'premium': 'false'}, _noHttp([]));
      expect(off.account.config, {'label': 'Me'});
      expect(ParlerAdapter.isPremium(off.account), isFalse);
      final premiumField = a.connectSpecs.single.fields.last;
      expect((premiumField.kind, premiumField.defaultValue), (FieldKind.boolean, 'false'));
    });

    test('validate(): 4 photos and videos together, and the composer\'s file types', () {
      expect(a.validate(PostVariant(text: 'hi', media: [for (var i = 0; i < 4; i++) fakeImage(id: 'i$i')]), free), isEmpty);
      final five = a.validate(PostVariant(text: 'hi', media: [for (var i = 0; i < 3; i++) fakeImage(id: 'i$i'), fakeVideo(id: 'v1'), fakeVideo(id: 'v2')]), free);
      expect(_codes(five), ['parler.too_many_attachments'], reason: 'neither kind alone is over 4');
      expect(five.single.severity, IssueSeverity.error);
      expect(a.validate(PostVariant(text: 'hi', media: [fakeImage(), fakeVideo()]), free), isEmpty, reason: 'photos and video mix');
      expect(_codes(a.validate(PostVariant(text: 'hi', media: [fakeImage(mimeType: 'image/heic')]), free)), contains('media.image_type'));
      expect(_codes(a.validate(PostVariant(text: 'hi', media: [fakeImage(sizeBytes: 21 * 1024 * 1024)]), free)), contains('media.image_too_large'));
      expect(_codes(a.validate(PostVariant(text: 'hi', media: [fakeVideo(sizeBytes: 501 * 1024 * 1024)]), free)), contains('media.video_too_large'));
      expect(_codes(a.validate(PostVariant(text: 'hi', media: [fakeVideo(durationMs: 3601000)]), free)), contains('media.video_too_long'));
      expect(a.validate(PostVariant(text: 'hi', media: [fakeVideo(mimeType: 'video/webm', durationMs: 3600000)]), free), isEmpty);
    });

    test('hand-off opens the web composer with the text on the clipboard', () {
      final plan = a.buildHandoff(const PostVariant(text: 'A post'))!;
      expect(plan.preferred, HandoffMethod.manual);
      expect(plan.webIntent, isNull);
      expect(plan.desktopUrl, 'https://app.parler.com/compose');
      expect(plan.androidPackage, isNull, reason: 'the Parler app\'s package is not known');
      expect(plan.clipboardText, 'A post');
      expect(plan.shareFiles, isEmpty);
      expect(plan.instructions.split('\n'), hasLength(3));
      expect(plan.instructions, contains('Ctrl+V'));
      expect(plan.instructions, endsWith('3. Click **Post**.'));
    });

    test('hand-off with media adds the Attach media step', () {
      final img = fakeImage();
      final plan = a.buildHandoff(PostVariant(text: 'Pics', media: [img]))!;
      expect(plan.shareFiles, [img]);
      expect(plan.instructions.split('\n'), hasLength(4));
      expect(plan.instructions, contains('**Attach media**'));
      expect(plan.mediaNote, contains('add the media yourself'));
      final mediaOnly = a.buildHandoff(PostVariant(text: '', media: [img]))!;
      expect(mediaOnly.clipboardText, isNull);
      expect(mediaOnly.instructions, isNot(contains('Ctrl+V')));
    });

    test('intro and guide say how Premium is set', () {
      expect(a.connectSpecs.single.intro, contains('**Parler Premium**'));
      expect(a.descriptor.text.notes, contains('2000'));
    });
  });

  group('Locals', () {
    final a = LocalsAdapter();
    final acct = _acct('locals');

    test('descriptor: the limits read from Locals\' composer', () {
      final d = a.descriptor;
      expect((d.id, d.name, d.homepage), ('locals', 'Locals', 'https://locals.com/'));
      expect(d.text.maxLength, 15000, reason: 'the composer\'s counter: 0/15,000');
      expect(d.text.counting, CountingRule.utf16);
      expect((d.text.titleSupported, d.text.titleRequired, d.text.titleMax), (true, false, 255), reason: 'input#post-craft-title, maxlength 255, optional');
      expect(d.media.maxImages, 10);
      expect(d.media.imageMaxBytes, 20 * 1024 * 1024);
      expect(d.media.maxVideos, 1);
      expect(d.media.allowsMixedImageVideo, isFalse);
      expect(d.media.audioWithOtherMedia, isFalse, reason: 'one kind of media per post');
      expect(d.media.imageMimeTypes, {'image/jpeg', 'image/png', 'image/gif', 'image/webp'});
      expect(d.media.videoMimeTypes, containsAll(['video/mp4', 'video/quicktime', 'video/webm', 'video/mpeg', 'video/x-ms-wmv', 'video/3gpp', 'video/x-msvideo', 'video/x-m4v']));
      expect(d.media.maxAudios, 1);
      expect(d.media.audioMimeTypes, {AudioMimeTypes.mp3, AudioMimeTypes.m4a, AudioMimeTypes.wav});
      expect(d.media.videoMaxBytes, isNull, reason: 'creators\' limits depend on their plan: a warning, not an error');
      expect(d.media.videoMaxSeconds, isNull);
      expect(d.media.notes, allOf(contains('some communities allow 5'), contains('PDF')));
    });

    test('parseCommunity takes the name, a locals.com link or the older name.locals.com', () {
      for (final input in [
        'mycommunity', 'MyCommunity', 'locals.com/mycommunity', 'https://locals.com/mycommunity/feed', 'https://www.locals.com/MyCommunity/post/123/hello?x=1', //
        'locals.com/mycommunity#top', 'mycommunity/feed', 'mycommunity.locals.com', 'https://mycommunity.locals.com/', 'https://mycommunity.locals.com/post/123/hello?x=1', //
        '  mycommunity.locals.com/feed  ',
      ]) {
        expect(LocalsAdapter.parseCommunity(input), 'mycommunity', reason: input);
      }
      expect(LocalsAdapter.parseCommunity('my-community-2'), 'my-community-2');
      expect(LocalsAdapter.parseCommunity('https://locals.com/my_community/feed'), 'my_community', reason: 'a path may hold an underscore');
      expect(LocalsAdapter.parseCommunity(''), isNull);
      expect(LocalsAdapter.parseCommunity(null), isNull);
      for (final bad in [
        'locals.com', 'www.locals.com', 'https://locals.com/', 'https://locals.com/_/feed', 'locals.com/legacy/profile', 'locals.com/feed', //
        'https://example.org/x', 'my community', '-bad', '_', 'www',
      ]) {
        expect(() => LocalsAdapter.parseCommunity(bad), throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'community')), reason: bad);
      }
    });

    test('connect(): the community becomes the account\'s page and, without a label, its name', () async {
      final r = await a.connect(PlatformTier.handoff, {'community': 'https://locals.com/mycommunity/feed'}, _noHttp([]));
      expect(r.account.config, {'community': 'mycommunity'});
      expect(r.account.displayName, 'locals.com/mycommunity');
      expect(r.account.profileUrl, 'https://locals.com/mycommunity/feed');
      final older = await a.connect(PlatformTier.handoff, {'community': 'mycommunity.locals.com'}, _noHttp([]));
      expect(older.account.config, {'community': 'mycommunity'});
      expect(older.account.profileUrl, 'https://locals.com/mycommunity/feed');
      final labelled = await a.connect(PlatformTier.handoff, {'label': 'Shop', 'community': 'mycommunity'}, _noHttp([]));
      expect(labelled.account.displayName, 'Shop');
      expect(labelled.account.config, {'label': 'Shop', 'community': 'mycommunity'});
      await expectLater(a.connect(PlatformTier.handoff, {'community': 'not a community'}, _noHttp([])),
          throwsA(isA<ConnectException>().having((e) => e.field, 'field', 'community')));
    });

    test('hand-off opens the community\'s feed (where the composer is), else the news feed, and the Locals app on Android', () async {
      final community = (await a.connect(PlatformTier.handoff, {'community': 'mycommunity'}, _noHttp([]))).account;
      final plan = a.buildHandoff(const PostVariant(text: 'Hello supporters'), account: community)!;
      expect(plan.preferred, HandoffMethod.manual);
      expect(plan.desktopUrl, 'https://locals.com/mycommunity/feed');
      expect(plan.androidPackage, 'com.locals.localsapp');
      expect(plan.clipboardText, 'Hello supporters');
      expect(plan.snippets, isEmpty);
      expect(plan.instructions, contains('**Regular Post**'));
      expect(plan.instructions.split('\n'), hasLength(3));
      expect(plan.instructions, endsWith('3. Click **Publish**.'));
      // An account connected before 1.4.3 keeps its community: the new address is built from it.
      final older = ConnectedAccount(id: 'l', platformId: 'locals', tier: PlatformTier.handoff, displayName: 'mycommunity.locals.com', createdAt: DateTime.utc(2026), config: const {'community': 'mycommunity'});
      expect(a.buildHandoff(const PostVariant(text: 'Hello supporters'), account: older)!.desktopUrl, 'https://locals.com/mycommunity/feed');
      final feed = a.buildHandoff(const PostVariant(text: 'Hello supporters'), account: acct)!;
      expect(feed.desktopUrl, 'https://locals.com/_/feed');
      expect(feed.instructions, startsWith('1. Your Locals news feed opens'));
      expect(feed.instructions, contains('open your community\'s feed'));
      expect(a.buildHandoff(const PostVariant(text: 'Hello supporters'))!.desktopUrl, 'https://locals.com/_/feed');
      final media = a.buildHandoff(PostVariant(text: 'Pics', media: [fakeImage()]), account: community)!;
      expect(media.instructions.split('\n'), hasLength(4));
      expect(media.instructions, contains('**Save media to Downloads**'));
      final titled = a.buildHandoff(const PostVariant(text: 'Hello supporters', title: 'News'), account: community)!;
      expect([for (final s in titled.snippets) (s.label, s.text)], [('Title', 'News')]);
      expect(titled.instructions.split('\n'), hasLength(4));
      expect(titled.instructions, contains('**Title**'));
      expect(titled.clipboardText, 'Hello supporters', reason: 'the title is not pasted into the post');
    });

    test('validate(): 10 photos, one video alone, the 10-character minimum and the members\' media limit', () {
      final ten = [for (var i = 0; i < 10; i++) fakeImage(id: 'i$i')];
      expect(_codes(a.validate(PostVariant(text: 'Ten photos here', media: ten), acct)), ['locals.photo_limit_varies']);
      expect(_codes(a.validate(PostVariant(text: 'Eleven photos', media: [...ten, fakeImage(id: 'x')]), acct)), contains('media.too_many_images'));
      expect(_codes(a.validate(PostVariant(text: 'Photo and video', media: [fakeImage(), fakeVideo()]), acct)), contains('media.mixed'));
      final short = a.validate(const PostVariant(text: 'Hi there'), acct);
      expect(_codes(short), ['locals.text_too_short']);
      expect(short.single.severity, IssueSeverity.warning);
      expect(a.validate(const PostVariant(text: 'Hi there!!'), acct), isEmpty, reason: 'exactly 10 characters');
      final long = a.validate(PostVariant(text: 'A long video for you', media: [fakeVideo(durationMs: 301000)]), acct);
      expect(_codes(long), ['locals.member_media_limit']);
      expect(long.single.severity, IssueSeverity.warning, reason: 'a creator may post it');
      expect(_codes(a.validate(PostVariant(text: 'A big video for you', media: [fakeVideo(sizeBytes: 200 * 1024 * 1024)]), acct)),
          ['locals.member_media_limit'], reason: '"below 200MBs"');
      expect(a.validate(PostVariant(text: 'A short video for you', media: [fakeVideo(durationMs: 300000)]), acct), isEmpty);
      const sound = MediaAttachment(id: 's', path: '/tmp/s.mp3', mimeType: 'audio/mpeg', sizeBytes: 4 * 1024 * 1024, durationMs: 420000);
      expect(_codes(a.validate(const PostVariant(text: 'A long track for you', media: [sound]), acct)), contains('locals.member_media_limit'));
      expect(_codes(a.validate(PostVariant(text: 'A track and a photo', media: [sound, fakeImage()]), acct)), contains('media.audio_mixed'), reason: 'one kind of media per post');
    });

    test('validate(): 15,000 characters, a 255-character title, 20 MB photos, and a warning above the 5 photos some communities allow', () {
      expect(a.validate(PostVariant(text: 'x' * 15000), acct), isEmpty);
      expect(_codes(a.validate(PostVariant(text: 'x' * 15001), acct)), contains('text.too_long'));
      expect(a.validate(PostVariant(text: 'Hello supporters', title: 't' * 255), acct), isEmpty);
      expect(_codes(a.validate(PostVariant(text: 'Hello supporters', title: 't' * 256), acct)), ['title.too_long']);
      expect(_codes(a.validate(PostVariant(text: 'A big photo', media: [fakeImage(sizeBytes: 20 * 1024 * 1024 + 1)]), acct)), contains('media.image_too_large'));
      final five = [for (var i = 0; i < 5; i++) fakeImage(id: 'i$i')];
      expect(a.validate(PostVariant(text: 'Five photos here', media: five), acct), isEmpty);
      final six = a.validate(PostVariant(text: 'Six photos here', media: [...five, fakeImage(id: 'x')]), acct);
      expect(_codes(six), ['locals.photo_limit_varies']);
      expect(six.single.severity, IssueSeverity.warning, reason: 'the account\'s community may take 10');
      final eleven = [for (var i = 0; i < 11; i++) fakeImage(id: 'i$i')];
      expect(_codes(a.validate(PostVariant(text: 'Eleven photos', media: eleven), acct)), isNot(contains('locals.photo_limit_varies')), reason: 'the error says it already');
    });
  });

  test('handoffFullText trims and joins', () {
    expect(handoffFullText(const PostVariant(text: '  hi  ')), 'hi');
    expect(handoffFullText(const PostVariant(text: 'a', threadParts: ['a', 'b', 'c'])), 'a\n\nb\n\nc');
  });
}
