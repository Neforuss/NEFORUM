// Text cards for image-only platforms and platform-held schedules, driven
// through the demo workspace.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:neforum_app/media/photo_fitter.dart';
import 'package:neforum_app/media/text_card.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/fitted_photos.dart';
import 'package:neforum_app/state/text_cards.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/compose/preview_card.dart';
import 'package:neforum_app/ui/compose/rich_text.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_app/widgets/surfaces.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _MemoryStorage implements AppStorage {
  final Map<String, Object> _json = {};
  final Map<String, Uint8List> _media = {};
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => _json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => _json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async {
    final path = 'mem://$id.$extension';
    _media[path] = bytes;
    return path;
  }

  @override
  Future<Uint8List> readMedia(String path) async => _media[path]!;
  @override
  Future<void> deleteMedia(String path) async => _media.remove(path);
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) =>
      SizedBox(width: width, height: height, child: const ColoredBox(color: Color(0xFF777777)));
}

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
    }
    await loader.load();
  }

  await family('Inter', ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-Medium.ttf', 'assets/fonts/Inter-SemiBold.ttf', 'assets/fonts/Inter-Bold.ttf']);
  await family('Bricolage', ['assets/fonts/BricolageGrotesque-SemiBold.ttf', 'assets/fonts/BricolageGrotesque-Bold.ttf', 'assets/fonts/BricolageGrotesque-ExtraBold.ttf']);
}

void main() {
  setUpAll(_loadFonts);

  Future<(AppServices, ProviderContainer)> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage())))!;
    await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
    await tester.pump(const Duration(milliseconds: 300));
    return (services, ProviderScope.containerOf(tester.element(find.byType(MaterialApp))));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  testWidgets('text-only posts become a NEFORUM text card where an image is required', (tester) async {
    final (services, c) = await boot(tester);
    c.read(routerProvider).go('/compose');
    await settle(tester);
    final editor = find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController);
    await tester.enterText(editor, 'Open source keyboards, open bench, open evenings. Come build with us. #diy');
    final ig = c.read(accountListProvider).firstWhere((a) => a.platformId == 'instagram');
    final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon');
    c.read(composerProvider.notifier).selectAccounts([ig.id, masto.id]);
    await settle(tester);

    // Preview and checks see the card; Mastodon gets plain text.
    final previews = {for (final p in c.read(composerPreviewsProvider)) p.account.platformId: p};
    expect(previews['instagram']!.variant.media.single.generated, isTrue);
    expect(previews['instagram']!.issues.where((i) => i.code == 'media.required'), isEmpty);
    expect(previews['instagram']!.issues.any((i) => i.code == 'media.text_card'), isTrue);
    expect(previews['mastodon']!.variant.media, isEmpty);
    expect(c.read(composerReadinessProvider).blocked, 0);
    expect(find.byType(TextCardView), findsOneWidget);

    // Per-post style.
    await tester.ensureVisible(find.text(TextCardTheme.light.label).first);
    await tester.tap(find.text(TextCardTheme.light.label).first);
    await settle(tester);
    expect(c.read(composerProvider).textCardTheme, TextCardTheme.light);

    // Saving renders the real JPEG and gives it to Instagram only.
    final post = (await tester.runAsync(() => c.read(postActionsProvider).saveDraft()))!;
    final card = post.media.singleWhere((m) => m.generated);
    expect(card.mimeType, 'image/jpeg');
    expect(card.fileName, textCardFileName(TextCardTheme.light));
    expect(card.altText, startsWith('Open source keyboards'));
    expect(post.targetFor(ig.id)!.overrides.mediaIds, [card.id]);
    expect(post.targetFor(masto.id)!.overrides.mediaIds, isNull);
    final bytes = (await tester.runAsync(() => services.media.read(card)))!;
    final decoded = img.decodeJpg(bytes)!;
    expect((decoded.width, decoded.height), (1080, 1350));
    // White card: the corner below the top rule is white.
    final px = decoded.getPixel(1070, 600);
    expect(px.r, greaterThan(240));

    // Editing hides the card again and remembers the style.
    c.read(composerProvider.notifier).load(post);
    expect(c.read(composerProvider).media, isEmpty);
    expect(c.read(composerProvider).overrides[ig.id], isNull);
    expect(c.read(composerProvider).textCardTheme, TextCardTheme.light);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  test('fitting a photo: borders from its own colours, or cropped; a JPEG within the size', () async {
    // 300x400 (3:4): red left half, blue right half.
    final src = img.Image(width: 300, height: 400);
    img.fillRect(src, x1: 0, y1: 0, x2: 149, y2: 399, color: img.ColorRgb8(220, 20, 20));
    img.fillRect(src, x1: 150, y1: 0, x2: 299, y2: 399, color: img.ColorRgb8(20, 20, 220));
    final jpeg = img.encodeJpg(src, quality: 95);
    const instagram = PhotoFit(minAspect: 0.8, maxAspect: 1.91, mimeTypes: {'image/jpeg'}, maxBytes: 8 * 1024 * 1024);

    final padded = (await fitPhoto(jpeg, 'image/jpeg', instagram, PhotoFitMode.pad))!;
    expect((padded.width, padded.height, padded.mimeType), (320, 400, 'image/jpeg'));
    final p = img.decodeJpg(padded.bytes)!;
    expect(p.getPixel(3, 200).r, greaterThan(p.getPixel(3, 200).b), reason: 'the left border is a blur of the red side');
    expect(p.getPixel(316, 200).b, greaterThan(p.getPixel(316, 200).r), reason: 'the right border a blur of the blue side');
    expect(p.getPixel(60, 200).r, greaterThan(180), reason: 'the photo itself is untouched in the middle');

    final cropped = (await fitPhoto(jpeg, 'image/jpeg', instagram, PhotoFitMode.crop))!;
    expect((cropped.width, cropped.height), (300, 375));

    // A PNG becomes a JPEG; a size limit is met.
    final png = img.encodePng(img.Image(width: 900, height: 900)..clear(img.ColorRgb8(90, 140, 200)));
    final jpegOnly = (await fitPhoto(png, 'image/png', instagram, PhotoFitMode.pad))!;
    expect((jpegOnly.mimeType, jpegOnly.width, jpegOnly.height), ('image/jpeg', 900, 900));
    final noisy = img.Image(width: 800, height: 800);
    for (final px in noisy) {
      px.setRgb((px.x * 37 + px.y * 11) % 256, (px.x * 13) % 256, (px.y * 29) % 256);
    }
    final small = (await fitPhoto(img.encodePng(noisy), 'image/png', const PhotoFit(mimeTypes: {'image/jpeg'}, maxBytes: 40000), PhotoFitMode.pad))!;
    expect(small.bytes.length, lessThanOrEqualTo(40000));
    expect(await fitPhoto(Uint8List.fromList([1, 2, 3]), 'image/heic', instagram, PhotoFitMode.pad), isNull, reason: 'unreadable: left alone');
  });

  testWidgets('photos a network refuses get a fitted copy for that network only (Instagram 4:5 to 1.91:1)', (tester) async {
    final (services, c) = await boot(tester);
    // An Instagram account on the API (the demo one is a hand-off account).
    final ig = ConnectedAccount(id: 'ig-api', platformId: 'instagram', tier: PlatformTier.byokApi, displayName: 'neforus', createdAt: DateTime(2026, 10, 12));
    await tester.runAsync(() => services.accounts.upsert(ig));
    final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon');
    final art = (await tester.runAsync(() => services.media.importBytes(
          img.encodeJpg(img.Image(width: 300, height: 400)..clear(img.ColorRgb8(200, 160, 40))),
          fileName: 'art.jpg',
        )))!;
    expect((art.width, art.height), (300, 400));
    final now = DateTime(2026, 10, 12);
    var post = Post(
      id: 'p-fit',
      text: 'One of the many pieces of art I own',
      media: [art.copyWith(altText: 'A painting')],
      targets: [PostTarget(accountId: ig.id), PostTarget(accountId: masto.id)],
      createdAt: now,
      updatedAt: now,
    );
    var settings = c.read(settingsProvider);
    expect(settings.photoFit, PhotoFitMode.pad, reason: 'borders by default');

    post = (await tester.runAsync(() => attachFittedPhotos(services, post, settings)))!;
    final copy = post.media.singleWhere((m) => m.derivedFrom != null);
    expect((copy.width, copy.height, copy.mimeType, copy.generated, copy.derivedFrom), (320, 400, 'image/jpeg', true, art.id));
    expect(copy.altText, 'A painting');
    expect(copy.fileName, 'art (fitted).jpg');
    expect(post.targetFor(ig.id)!.overrides.mediaIds, [copy.id]);
    expect(post.targetFor(masto.id)!.overrides.mediaIds, isNull, reason: 'Mastodon takes the photo as it is');
    final variant = const VariantResolver().resolve(post, post.targetFor(ig.id)!, services.registry.byId('instagram')!.descriptor, account: ig);
    expect(services.registry.byId('instagram')!.validate(variant, ig).where((i) => i.code == 'instagram.aspect_ratio'), isEmpty);

    // Again: the same copy is kept.
    post = (await tester.runAsync(() => attachFittedPhotos(services, post, settings)))!;
    expect(post.media.where((m) => m.derivedFrom != null).single.id, copy.id);

    // Cropping instead: a new copy, the old one deleted.
    settings = settings.copyWith(photoFit: PhotoFitMode.crop);
    post = (await tester.runAsync(() => attachFittedPhotos(services, post, settings)))!;
    final cropped = post.media.singleWhere((m) => m.derivedFrom != null);
    expect((cropped.width, cropped.height), (300, 375));
    expect(await tester.runAsync(() async {
      try {
        await services.media.read(copy);
        return 'still there';
      } on Object {
        return 'deleted';
      }
    }), 'deleted');

    // Editing shows the original again.
    final shown = withoutTextCards(post);
    expect(shown.media.map((m) => m.id), [art.id]);
    expect(shown.targetFor(ig.id)!.overrides.mediaIds, isNull);

    // Off: no copies, and Instagram says why.
    post = (await tester.runAsync(() => attachFittedPhotos(services, post, settings.copyWith(photoFit: PhotoFitMode.off))))!;
    expect(post.media.map((m) => m.id), [art.id]);
    expect(post.targetFor(ig.id)!.overrides.mediaIds, isNull);

    // The composer: an info note instead of the error.
    c.read(composerProvider.notifier).load(post);
    c.read(composerProvider.notifier).selectAccounts([ig.id, masto.id]);
    await settle(tester);
    final previews = {for (final p in c.read(composerPreviewsProvider)) p.account.id: p};
    expect(previews[ig.id]!.issues.where((i) => i.code == 'instagram.aspect_ratio'), isEmpty);
    expect(previews[ig.id]!.issues.where((i) => i.code == 'media.photo_fit').single.message, 'art.jpg will be given borders to 4:5 for Instagram');
    expect(previews[masto.id]!.issues.where((i) => i.code == 'media.photo_fit'), isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a network can get only the second photo of an album, even a PNG Instagram\'s API would refuse as is', (tester) async {
    final (services, c) = await boot(tester);
    final ig = ConnectedAccount(id: 'ig-api', platformId: 'instagram', tier: PlatformTier.byokApi, displayName: 'neforus', createdAt: DateTime(2026, 10, 12));
    await tester.runAsync(() => services.accounts.upsert(ig));
    final masto = c.read(accountListProvider).firstWhere((a) => a.platformId == 'mastodon');
    Future<MediaAttachment> add(String name, List<int> bytes) async => (await tester.runAsync(() => services.media.importBytes(Uint8List.fromList(bytes), fileName: name)))!;
    final first = await add('first.jpg', img.encodeJpg(img.Image(width: 400, height: 500)..clear(img.ColorRgb8(30, 30, 30))));
    final second = await add('second.png', img.encodePng(img.Image(width: 500, height: 500)..clear(img.ColorRgb8(240, 200, 220))));
    final now = DateTime(2026, 10, 12);
    final post = Post(
      id: 'p-pick',
      text: 'I do want this vibe coded product to have perfect vibes',
      media: [first, second],
      targets: [PostTarget(accountId: ig.id, overrides: PostOverrides(mediaIds: [second.id])), PostTarget(accountId: masto.id)],
      createdAt: now,
      updatedAt: now,
    );
    c.read(composerProvider.notifier).load(post);
    await settle(tester);

    final previews = {for (final p in c.read(composerPreviewsProvider)) p.account.id: p};
    final igPreview = previews[ig.id]!;
    expect(igPreview.variant.media.single.derivedFrom, second.id, reason: 'the photo picked for Instagram, not a text card');
    expect(igPreview.issues.map((i) => i.code), isNot(contains('media.text_card')));
    expect(igPreview.issues.map((i) => i.code), isNot(contains('media.dropped')));
    // Instagram fills its 4:5 frame by default (Settings > Fill the whole frame).
    expect(igPreview.issues.where((i) => i.code == 'media.photo_fit').single.message,
        'second.png will be given borders to 4:5, made a JPEG for Instagram');
    expect(previews[masto.id]!.variant.media.map((m) => m.id), [first.id, second.id]);

    // Saved: Instagram gets a JPEG of the second photo; Mastodon both originals.
    final saved = (await tester.runAsync(() => c.read(postActionsProvider).saveDraft()))!;
    final copy = saved.media.singleWhere((m) => m.derivedFrom != null);
    expect((copy.derivedFrom, copy.mimeType), (second.id, 'image/jpeg'));
    expect(saved.targetFor(ig.id)!.overrides.mediaIds, [copy.id]);
    expect(saved.media.where((m) => m.isTextCard), isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('YouTube Posts: text and images go out by hand-off, separate from YouTube videos', (tester) async {
    final (services, c) = await boot(tester);
    c.read(routerProvider).go('/compose');
    await settle(tester);
    final yt = c.read(accountListProvider).firstWhere((a) => a.platformId == 'youtube_posts');
    final editor = find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController);
    await tester.enterText(editor, 'New video drops Friday. Which thumbnail should I use? #behindthescenes');
    c.read(composerProvider.notifier).selectAccounts([yt.id]);
    await settle(tester);

    final preview = c.read(composerPreviewsProvider).single;
    expect(preview.descriptor.name, 'YouTube Posts');
    expect(preview.issues.hasErrors, isFalse);
    expect(preview.variant.media, isEmpty, reason: 'no text card: posts can be text only');
    expect(preview.variant.text, contains('#behindthescenes'));
    expect(c.read(composerReadinessProvider).handoff, 1);
    expect(find.text('YouTube Posts'), findsWidgets);

    final post = (await tester.runAsync(() => c.read(postActionsProvider).saveDraft()))!;
    final plan = (await tester.runAsync(() => services.publisher().planHandoff(post, yt.id)))!;
    expect(plan.desktopUrl, 'https://www.youtube.com/');
    expect(plan.clipboardText, contains('Which thumbnail'));
    expect(plan.instructions, contains('Create post'));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('YouTube Posts polls: editor, previews and copyable answers in the hand-off', (tester) async {
    final (services, c) = await boot(tester);
    c.read(routerProvider).go('/compose');
    await settle(tester);
    final yt = c.read(accountListProvider).firstWhere((a) => a.platformId == 'youtube_posts');
    final x = c.read(accountListProvider).firstWhere((a) => a.platformId == 'x');
    final editor = find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController);
    await tester.enterText(editor, 'Which thumbnail for Friday?');
    c.read(composerProvider.notifier).selectAccounts([yt.id, x.id]);
    await settle(tester);

    // The toolbar offers polls because YouTube Posts takes them.
    await tester.tap(find.byTooltip('Poll or quiz for YouTube Posts'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Answer 1'), 'The red one');
    await tester.enterText(find.widgetWithText(TextField, 'Answer 2'), 'The blue one');
    await settle(tester);
    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(c.read(composerProvider).poll!.cleanOptions, ['The red one', 'The blue one']);
    expect(find.textContaining('Poll · 2 answers'), findsWidgets);

    final previews = {for (final p in c.read(composerPreviewsProvider)) p.account.platformId: p};
    expect(previews['youtube_posts']!.variant.poll, isNotNull);
    expect(previews['youtube_posts']!.issues.hasErrors, isFalse);
    expect(previews['x']!.variant.poll, isNull);
    expect(previews['x']!.issues.map((i) => i.code), contains('poll.unsupported'));
    expect(find.byType(PollPreview), findsOneWidget);

    final post = (await tester.runAsync(() => c.read(postActionsProvider).saveDraft()))!;
    expect(post.poll!.options, ['The red one', 'The blue one']);
    final plan = (await tester.runAsync(() => services.publisher().planHandoff(post, yt.id)))!;
    expect(plan.snippets.map((s) => s.text), ['The red one', 'The blue one']);
    expect(plan.clipboardText, 'Which thumbnail for Friday?');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('text cards: the NEFORUM signature is optional per network', (tester) async {
    final (services, c) = await boot(tester);
    c.read(routerProvider).go('/compose');
    await settle(tester);
    final ig = c.read(accountListProvider).firstWhere((a) => a.platformId == 'instagram');
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController), 'Plain words, plain card.');
    c.read(composerProvider.notifier).selectAccounts([ig.id]);
    await settle(tester);
    expect(textCardBrandedOf(c.read(composerPreviewsProvider).single.variant.media.single), isTrue);

    await tester.ensureVisible(find.text('NEFORUM signature').first);
    await tester.tap(find.text('NEFORUM signature').first);
    await settle(tester);
    expect(c.read(composerProvider).textCardBranded['instagram'], isFalse);
    expect(c.read(settingsProvider).textCardBranded('instagram'), isFalse, reason: 'remembered for Instagram');
    expect(c.read(settingsProvider).textCardBranded('tiktok'), isTrue, reason: 'other networks keep it');
    expect(textCardBrandedOf(c.read(composerPreviewsProvider).single.variant.media.single), isFalse);

    final post = (await tester.runAsync(() => c.read(postActionsProvider).saveDraft()))!;
    final card = post.media.singleWhere((m) => m.generated);
    expect(card.fileName, textCardFileName(TextCardTheme.dark, branded: false));
    final bytes = (await tester.runAsync(() => services.media.read(card)))!;
    expect(img.decodeJpg(bytes)!.width, 1080);
    // A plain card has no purple rule along the top.
    final top = img.decodeJpg(bytes)!.getPixel(540, 4);
    expect(top.b, lessThan(60));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('DIFFERENTIATION: a version per network, side by side', (tester) async {
    final (services, c) = await boot(tester);
    c.read(routerProvider).go('/compose');
    await settle(tester);
    final accounts = c.read(accountListProvider);
    String idOf(String platform) => accounts.firstWhere((a) => a.platformId == platform).id;
    await tester.enterText(
      find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController),
      'We rebuilt the firmware from scratch this spring. It took four months and two prototypes. Today it ships to everyone. '
      'Guide: https://example.org/kb\n\n#opensource #keyboards #diy',
    );
    c.read(composerProvider.notifier).selectAccounts([idOf('x'), idOf('linkedin'), idOf('instagram'), idOf('reddit')]);
    await settle(tester);

    await tester.ensureVisible(find.text('Differentiate'));
    await tester.tap(find.text('Differentiate'));
    await settle(tester);
    expect(find.text('A version for each network'), findsOneWidget);
    expect(find.text('Main post'), findsNWidgets(4));

    expect(find.text('Auto-differentiate'), findsNothing, reason: 'removed: versions are made by hand and with the one-tap changes');

    // One-tap changes per network.
    Finder versionCard(String name) => find.ancestor(
          of: find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'The $name version'),
          matching: find.byType(NfCard),
        ).first;
    final igCard = versionCard('Instagram');
    await tester.ensureVisible(igCard);
    await tester.tap(find.descendant(of: igCard, matching: find.text('"Link in bio"')));
    await settle(tester);
    final redditCard = versionCard('Reddit');
    await tester.ensureVisible(redditCard);
    await tester.tap(find.descendant(of: redditCard, matching: find.text('No hashtags')));
    await settle(tester);
    final linkedinCard = versionCard('LinkedIn');
    await tester.ensureVisible(linkedinCard);
    await tester.tap(find.descendant(of: linkedinCard, matching: find.text('Airy paragraphs')));
    await settle(tester);
    final o = c.read(composerProvider).overrides;
    expect(o[idOf('instagram')]!.text, contains('Link in bio.'));
    expect(o[idOf('reddit')]!.text, isNot(contains('#')));
    expect(o[idOf('linkedin')]!.text!.split('\n\n').length, greaterThan(3));
    final previews = {for (final p in c.read(composerPreviewsProvider)) p.account.platformId: p};
    expect(previews['instagram']!.variant.text, contains('Link in bio.'));

    // Edit one version by hand.
    final xField = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'The X (Twitter) version');
    await tester.ensureVisible(xField);
    await tester.enterText(xField, 'Firmware v2 is out. Open source, smooth RGB. #keyboards');
    await settle(tester);
    expect(c.read(composerProvider).overrides[idOf('x')]!.text, 'Firmware v2 is out. Open source, smooth RGB. #keyboards');

    // Saved versions come back when the post is edited again.
    final post = (await tester.runAsync(() => c.read(postActionsProvider).saveDraft()))!;
    expect(post.targetFor(idOf('x'))!.overrides.text, startsWith('Firmware v2'));
    c.read(composerProvider.notifier).load(post);
    await settle(tester);
    expect(c.read(composerProvider).differentiate, isTrue);
    expect(find.text('Own version'), findsNWidgets(4));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    services.dispose();
  });

  // Found on a real Windows window: with a schedule set, the composer's
  // action bar overflowed when the compose column was ~560 px wide.
  testWidgets('composer with a schedule fits at in-between window widths', (tester) async {
    final (services, c) = await boot(tester);
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      c.read(routerProvider).go('/compose');
      await settle(tester);
      final editor = find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController);
      await tester.enterText(editor, 'Checking the bar at many widths with a schedule set. #neforum');
      for (final scheduled in const [false, true]) {
        if (scheduled) c.read(composerProvider.notifier).setSchedule(DateTime(2026, 12, 24, 18, 45));
        for (final w in const [740.0, 900.0, 1000.0, 1180.0, 1230.0, 1280.0, 1366.0, 1440.0, 1600.0]) {
          tester.view.physicalSize = Size(w, 820);
          await settle(tester);
          expect(errors, isEmpty, reason: '${scheduled ? 'scheduled' : 'unscheduled'}, width $w: ${errors.map((e) => e.exceptionAsString()).join('\n')}');
        }
      }
    } finally {
      FlutterError.onError = previous;
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    services.dispose();
  });

  testWidgets('platform-held schedules are shown, taken back and handed over again', (tester) async {
    final (services, c) = await boot(tester);
    c.read(routerProvider).go('/activity/post/demo-post-3');
    await settle(tester);
    expect(find.textContaining('holds this post'), findsOneWidget);
    expect(find.text('Held by platform'), findsWidgets);

    final actions = c.read(postActionsProvider);
    final post = (await services.posts.get('demo-post-3'))!;
    final masto = post.targets.firstWhere((t) => t.isHeldByPlatform).accountId;

    // Moving it to drafts takes Mastodon's copy back.
    final draft = (await tester.runAsync(() => actions.unschedule(post)))!;
    expect(draft.status, PostStatus.draft);
    expect(draft.hasHeldTargets, isFalse);
    expect(draft.targetFor(masto)!.status, TargetStatus.pending);

    // Scheduling again hands it over again; platforms without server-side
    // scheduling stay on the device.
    final when = DateTime.now().add(const Duration(hours: 3));
    await tester.runAsync(() async {
      await actions.reschedule(draft, when);
      await actions.settle();
    });
    final again = (await services.posts.get('demo-post-3'))!;
    expect(again.targetFor(masto)!.status, TargetStatus.heldByPlatform);
    expect(again.targetFor(masto)!.result!.scheduledFor, when);
    final bluesky = c.read(accountListProvider).firstWhere((a) => a.platformId == 'bluesky');
    expect(again.targetFor(bluesky.id)!.status, TargetStatus.pending);
    expect(again.needsDeviceAtSchedule, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
