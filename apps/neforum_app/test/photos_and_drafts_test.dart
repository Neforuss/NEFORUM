import 'dart:typed_data';

import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/media/photo_fitter.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/platform/clipboard_media.dart';
import 'package:neforum_app/state/captioned_photos.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/composer_draft.dart';
import 'package:neforum_app/state/fitted_photos.dart';
import 'package:neforum_app/state/settings.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

void main() {
  group('colour fill', () {
    test('a wide photo in a tall frame: its top colour above, its bottom colour below', () async {
      // Top half red, bottom half blue, 200 x 100.
      final photo = img.Image(width: 200, height: 100);
      for (final p in photo) {
        p
          ..r = p.y < 50 ? 220 : 10
          ..g = 10
          ..b = p.y < 50 ? 10 : 220;
      }
      final out = await fitPhoto(img.encodePng(photo), 'image/png', const PhotoFit(minAspect: 9 / 16, maxAspect: 9 / 16), PhotoFitMode.color);
      expect(out, isNotNull);
      expect(out!.width / out.height, closeTo(9 / 16, 0.01));
      final fitted = img.decodeImage(out.bytes)!;
      final top = fitted.getPixel(100, 3), bottom = fitted.getPixel(100, fitted.height - 3);
      expect(top.r, greaterThan(180), reason: 'red above');
      expect(top.b, lessThan(60));
      expect(bottom.b, greaterThan(180), reason: 'blue below');
      expect(bottom.r, lessThan(60));
      final middle = fitted.getPixel(100, fitted.height ~/ 2 - 20);
      expect(middle.r, greaterThan(180), reason: 'the photo itself is untouched in the middle');
    });

    test('edge colours pick the dominant colour of each side', () {
      final photo = img.Image(width: 100, height: 300);
      for (final p in photo) {
        p
          ..r = p.x < 50 ? 0 : 250
          ..g = p.x < 50 ? 200 : 250
          ..b = 0;
      }
      final e = edgeColours(photo, vertical: false);
      expect(e.start, 0x00C800, reason: 'left edge green');
      expect(e.end, 0xFAFA00, reason: 'right edge yellow');
    });

    test('describes itself', () {
      final m = MediaAttachment(id: 'a', path: '/a.png', mimeType: 'image/jpeg', sizeBytes: 1, width: 1000, height: 1000);
      expect(const PhotoFit(minAspect: 9 / 16, maxAspect: 9 / 16).describe(m, PhotoFitMode.color), 'given a colour fill to 9:16');
    });
  });

  group('fill the whole frame', () {
    final registry = builtinRegistry();
    ConnectedAccount account(String platform) =>
        ConnectedAccount(id: platform, platformId: platform, tier: PlatformTier.byokApi, displayName: platform, createdAt: DateTime(2026));

    test('TikTok photos are fitted to exactly 9:16 when on (the default), left as they are when off', () {
      final tiktok = registry.byId('tiktok')!;
      const v = PostVariant(text: 'x');
      final on = effectivePhotoFit(tiktok, account('tiktok'), v, const AppSettings())!;
      expect((on.minAspect, on.maxAspect), (9 / 16, 9 / 16));
      final off = effectivePhotoFit(tiktok, account('tiktok'), v, const AppSettings(fillFramePlatforms: []));
      expect(off?.minAspect, isNull);
    });

    test('Instagram: 4:5 in the feed, 9:16 for stories', () {
      final ig = registry.byId('instagram')!;
      final feed = effectivePhotoFit(ig, account('instagram'), const PostVariant(text: 'x'), const AppSettings())!;
      expect((feed.minAspect, feed.maxAspect), (4 / 5, 4 / 5));
      final story = effectivePhotoFit(ig, account('instagram'), const PostVariant(text: 'x', extra: {'storyMode': true}), const AppSettings())!;
      expect((story.minAspect, story.maxAspect), (9 / 16, 9 / 16));
    });

    test('other networks keep their own rules', () {
      expect(fullFrameAspect('x', const PostVariant(text: 'x')), isNull);
    });
  });

  group('text cards and captions', () {
    test('TikTok cards keep clear of TikTok\'s buttons; Instagram\'s 4:5 card does not need to', () {
      expect(textCardSafeArea('tiktok'), isNot(EdgeInsets.zero));
      expect(textCardSafeArea('tiktok').top, greaterThan(150));
      expect(textCardSafeArea('instagram'), EdgeInsets.zero);
      expect(textCardFileName(TextCardTheme.dark, safe: true), 'neforum-text-card-dark-safe.jpg');
      final old = MediaAttachment(id: 'c', path: '/c.jpg', mimeType: 'image/jpeg', sizeBytes: 1, fileName: 'neforum-text-card-dark.jpg', generated: true);
      expect(textCardSafeOf(old), isFalse, reason: 'cards made before are redrawn for TikTok');
    });

    test('each network\'s own font', () {
      expect(TextCardFont.platform.resolve('tiktok'), TextCardFont.tiktokSans);
      expect(TextCardFont.platform.resolve('instagram'), TextCardFont.instagramSans);
      expect(TextCardFont.platform.resolve('pinterest'), TextCardFont.original);
      expect(TextCardFont.arial.resolve('tiktok'), TextCardFont.arial);
      expect(TextCardFont.tiktokSans.variations, isNotEmpty);
    });

    test('caption on photo: only Instagram and TikTok, per post or from Settings', () {
      const settings = AppSettings(captionPhotoPlatforms: ['tiktok']);
      expect(captionOnPhotoFor('tiktok', settings, const {}), isTrue);
      expect(captionOnPhotoFor('tiktok', settings, const {'tiktok': false}), isFalse);
      expect(captionOnPhotoFor('instagram', settings, const {'instagram': true}), isTrue);
      expect(captionOnPhotoFor('x', settings, const {'x': true}), isFalse);
      expect(stableHash('hello'), stableHash('hello'));
      expect(stableHash('hello'), isNot(stableHash('hello!')));
      final copy = MediaAttachment(id: 'c', path: '/c.jpg', mimeType: 'image/jpeg', sizeBytes: 1, generated: true, derivedFrom: 'p', fitKey: 'caption|tiktok|p|1');
      expect(isCaptionedCopy(copy), isTrue);
      final fitted = MediaAttachment(id: 'f', path: '/f.jpg', mimeType: 'image/jpeg', sizeBytes: 1, generated: true, derivedFrom: 'p', fitKey: 'pad|0.5625');
      expect(isCaptionedCopy(fitted), isFalse);
    });
  });

  group('the post being written is kept', () {
    test('everything round-trips through the saved file', () {
      final photo = MediaAttachment(id: 'm1', path: '/data/media/m1.png', mimeType: 'image/png', sizeBytes: 10, width: 10, height: 10, fileName: 'a.png');
      final c = ComposerState(
        text: 'Hello world',
        title: 'Title',
        link: 'https://neforus.com',
        media: [photo],
        tags: const ['neforum'],
        selected: const {'acct-1', 'acct-2'},
        overrides: const {'acct-2': PostOverrides(text: 'Short')},
        scheduledAt: DateTime.utc(2026, 11, 1, 9),
        textCardTheme: TextCardTheme.light,
        textCardFont: TextCardFont.timesNewRoman,
        textCardBranded: const {'instagram': false},
        captionOnPhoto: const {'tiktok': true},
        differentiate: true,
      );
      final back = composerDraftFromJson(composerDraftToJson(c))!;
      expect(back.text, 'Hello world');
      expect(back.title, 'Title');
      expect(back.link, 'https://neforus.com');
      expect(back.media.single.path, '/data/media/m1.png');
      expect(back.tags, ['neforum']);
      expect(back.selected, {'acct-1', 'acct-2'});
      expect(back.overrides['acct-2']!.text, 'Short');
      expect(back.scheduledAt, DateTime.utc(2026, 11, 1, 9).toLocal());
      expect(back.textCardTheme, TextCardTheme.light);
      expect(back.textCardFont, TextCardFont.timesNewRoman);
      expect(back.textCardBranded, {'instagram': false});
      expect(back.captionOnPhoto, {'tiktok': true});
      expect(back.differentiate, isTrue);
      expect(back.editingPostId, isNull);
    });

    test('an empty composer clears it; an edit of a saved post is kept even when empty', () {
      expect(isComposerBlank(const ComposerState()), isTrue);
      expect(isComposerBlank(const ComposerState(selected: {'a'})), isTrue);
      expect(isComposerBlank(const ComposerState(text: 'x')), isFalse);
      expect(isComposerBlank(const ComposerState(editingPostId: 'p1')), isFalse);
      expect(composerDraftFromJson(const {}), isNull);
    });
  });

  test('a pasted Windows bitmap becomes an opaque PNG', () {
    // 2 x 1 pixels, 32-bit BI_RGB, rows bottom-up, BGRA with an unused (0) alpha.
    final dib = Uint8List(40 + 8);
    ByteData.sublistView(dib)
      ..setUint32(0, 40, Endian.little)
      ..setInt32(4, 2, Endian.little)
      ..setInt32(8, 1, Endian.little)
      ..setUint16(12, 1, Endian.little)
      ..setUint16(14, 32, Endian.little);
    dib.setAll(40, [0, 0, 255, 0, 255, 0, 0, 0]); // red, blue
    final png = ClipboardMedia.pngFromDib(dib);
    expect(png, isNotNull);
    final image = img.decodePng(png!)!;
    expect((image.width, image.height), (2, 1));
    final red = image.getPixel(0, 0), blue = image.getPixel(1, 0);
    expect((red.r, red.b, red.a), (255, 0, 255));
    expect((blue.r, blue.b, blue.a), (0, 255, 255));
  });
}
