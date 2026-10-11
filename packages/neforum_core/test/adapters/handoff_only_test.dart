import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/handoff_only/google_business_adapter.dart';
import 'package:neforum_core/src/adapters/handoff_only/handoff_common.dart';
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
];

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

        test('connect spec: one optional label field, no browser, no redirects', () {
          expect(a.connectSpecs, hasLength(1));
          final spec = a.connectSpecs.single;
          expect(spec.tier, PlatformTier.handoff);
          expect(spec.usesBrowser, isFalse);
          expect(spec.loopbackRedirectOk, isFalse);
          expect(spec.customSchemeRedirectOk, isFalse);
          expect(spec.fixedRedirectUri, isNull);
          expect(spec.fields, hasLength(1));
          final f = spec.fields.single;
          expect(f.key, 'label');
          expect(f.kind, FieldKind.text);
          expect(f.required, isFalse);
          expect(f.secret, isFalse);
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

    test('hand-off opens substack.com/home with text on the clipboard', () {
      final plan = a.buildHandoff(const PostVariant(text: 'A note'))!;
      expect(plan.preferred, HandoffMethod.manual);
      expect(plan.webIntent, isNull);
      expect(plan.desktopUrl, 'https://substack.com/home');
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

  test('handoffFullText trims and joins', () {
    expect(handoffFullText(const PostVariant(text: '  hi  ')), 'hi');
    expect(handoffFullText(const PostVariant(text: 'a', threadParts: ['a', 'b', 'c'])), 'a\n\nb\n\nc');
  });
}
