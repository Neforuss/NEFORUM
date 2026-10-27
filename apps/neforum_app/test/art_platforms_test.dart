// The art platforms that post through an API: their brand marks and the
// exact image size Dribbble's API takes.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/brand/platform_brand.dart';
import 'package:neforum_app/media/photo_fitter.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

void main() {
  const artIds = ['deviantart', 'dribbble', 'pixelfed', 'flickr', 'inkbunny'];

  test('every API art platform is registered with its own brand mark and a bundled guide', () {
    final registry = builtinRegistry();
    for (final id in artIds) {
      expect(registry.byId(id)?.descriptor.isArtPlatform, isTrue, reason: id);
      final brand = platformBrands[id];
      expect(brand, isNotNull, reason: '$id falls back to a generated brand');
      expect(brand!.icon != null || (brand.monogram ?? '').isNotEmpty, isTrue, reason: id);
      expect(File('assets/docs/$id.md').existsSync(), isTrue, reason: 'run dart run tool/sync_docs.dart');
    }
    for (final id in ['deviantart', 'dribbble', 'pixelfed', 'flickr']) {
      expect(platformBrands[id]!.icon, isNotNull, reason: 'Font Awesome has a $id logo');
    }
  });

  test('every platform shows its own bundled icon, a 256 x 256 tile', () {
    for (final d in builtinRegistry().descriptors) {
      final asset = platformIconAsset(d.id);
      expect(asset, isNotNull, reason: '${d.id} has no icon in assets/platforms/');
      final file = File(asset!);
      expect(file.existsSync(), isTrue, reason: asset);
      final tile = img.decodePng(file.readAsBytesSync())!;
      expect((tile.width, tile.height), (256, 256), reason: asset);
    }
    expect(platformIconAsset('youtube_posts'), platformIconAsset('youtube'));
    expect(platformIconAsset('not-a-platform'), isNull, reason: 'an unknown platform keeps its generated mark');
  });

  test('Dribbble API photos are fitted to exactly 800 x 600, scaled up or down', () async {
    final adapter = builtinRegistry().require('dribbble');
    final account = ConnectedAccount(id: 'd', platformId: 'dribbble', tier: PlatformTier.byokApi, displayName: 'Me', createdAt: DateTime(2026, 10, 25));
    final fit = adapter.photoFit(account, const PostVariant(text: ''))!;

    final small = img.encodeJpg(img.Image(width: 640, height: 480)..clear(img.ColorRgb8(200, 80, 40)));
    final up = (await fitPhoto(small, 'image/jpeg', fit, PhotoFitMode.pad))!;
    expect((up.width, up.height, up.mimeType), (800, 600, 'image/jpeg'));

    final tall = img.encodePng(img.Image(width: 900, height: 1600)..clear(img.ColorRgb8(30, 90, 160)));
    final down = (await fitPhoto(tall, 'image/png', fit, PhotoFitMode.crop))!;
    expect((down.width, down.height, down.mimeType), (800, 600, 'image/png'));

    final exact = img.encodeJpg(img.Image(width: 400, height: 300));
    final kept = (await fitPhoto(exact, 'image/jpeg', fit, PhotoFitMode.pad))!;
    expect((kept.width, kept.height), (400, 300), reason: '400 x 300 is taken as it is');
  });
}
