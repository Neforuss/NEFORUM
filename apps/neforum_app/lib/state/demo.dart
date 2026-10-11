import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../platform/media_library.dart';

/// Wraps a real adapter so the whole app can be explored without accounts:
/// descriptors, validation and hand-off plans are real; connecting and
/// publishing are simulated and never touch the network.
class DemoAdapter extends PlatformAdapter {
  DemoAdapter(this.inner);

  final PlatformAdapter inner;
  static int _counter = 0;

  @override
  PlatformDescriptor get descriptor => inner.descriptor;

  @override
  List<ConnectSpec> get connectSpecs => inner.connectSpecs;

  /// Real validation, minus complaints about the account's own setup (demo
  /// accounts have no keys or server details).
  @override
  List<ValidationIssue> validate(PostVariant variant, ConnectedAccount account) => inner
      .validate(variant, account)
      .where((i) => i.field != 'account' && !i.message.toLowerCase().contains('reconnect') && !i.code.contains('config'))
      .toList();

  @override
  HandoffPlan? buildHandoff(PostVariant variant, {ConnectedAccount? account}) => inner.buildHandoff(variant, account: account);

  @override
  Future<ConnectResult> connect(PlatformTier tier, Map<String, String> input, AdapterContext ctx) async {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    _counter++;
    final name = input.values.firstWhere((v) => v.trim().isNotEmpty && !v.startsWith('http'), orElse: () => 'Demo user $_counter');
    return ConnectResult(
      account: ConnectedAccount(
        id: 'demo-${descriptor.id}-${DateTime.now().microsecondsSinceEpoch}',
        platformId: descriptor.id,
        tier: tier,
        displayName: name.length > 28 ? name.substring(0, 28) : name,
        handle: '@demo$_counter',
        createdAt: DateTime.now(),
        config: const {'demo': true},
      ),
    );
  }

  @override
  Future<PublishResult> publish(PostVariant variant, ConnectedAccount account, Map<String, String> secrets, AdapterContext ctx) async {
    final steps = variant.media.length;
    for (var i = 0; i < steps; i++) {
      ctx.progress('Uploading ${i + 1} of $steps');
      await Future<void>.delayed(const Duration(milliseconds: 380));
    }
    ctx.progress(variant.isThread ? 'Posting ${variant.threadParts.length}-part thread' : 'Posting');
    await Future<void>.delayed(Duration(milliseconds: 500 + (descriptor.id.hashCode % 7) * 120));
    final id = 'demo${DateTime.now().millisecondsSinceEpoch}';
    return PublishResult.ok(
      remoteId: id,
      remoteUrl: descriptor.homepage,
      threadRemoteIds: variant.isThread ? [for (var i = 0; i < variant.threadParts.length; i++) '$id-$i'] : const [],
      publishedAt: DateTime.now(),
    );
  }
}

AdapterRegistry demoRegistry(AdapterRegistry real) => AdapterRegistry([for (final a in real.all) DemoAdapter(a)]);

/// A small generated "photo" (soft gradient with shapes) so the demo has
/// media without shipping sample pictures.
Uint8List _demoImage(int seed, {int w = 960, int h = 720}) {
  final palettes = [
    [(0xF7, 0xB2, 0x67), (0xD9, 0x5D, 0x39), (0x3B, 0x2F, 0x2F)],
    [(0x8E, 0xC5, 0xFC), (0xE0, 0xC3, 0xFC), (0x2D, 0x3A, 0x5C)],
    [(0xA8, 0xE6, 0xCF), (0x2E, 0x8B, 0x57), (0x1E, 0x2B, 0x24)],
  ];
  final p = palettes[seed % palettes.length];
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    final t = y / h;
    final r = (p[0].$1 + (p[1].$1 - p[0].$1) * t).round();
    final g = (p[0].$2 + (p[1].$2 - p[0].$2) * t).round();
    final b = (p[0].$3 + (p[1].$3 - p[0].$3) * t).round();
    img.drawLine(im, x1: 0, y1: y, x2: w - 1, y2: y, color: img.ColorRgb8(r, g, b));
  }
  final rnd = math.Random(seed * 7919);
  for (var i = 0; i < 5; i++) {
    final rad = 40 + rnd.nextInt(140);
    img.fillCircle(
      im,
      x: rnd.nextInt(w),
      y: (h * 0.35 + rnd.nextInt((h * 0.6).round())).round(),
      radius: rad,
      color: img.ColorRgba8(p[2].$1, p[2].$2, p[2].$3, 70 + rnd.nextInt(90)),
    );
  }
  img.fillRect(im, x1: 0, y1: (h * 0.82).round(), x2: w, y2: h, color: img.ColorRgba8(p[2].$1, p[2].$2, p[2].$3, 140));
  return img.encodeJpg(im, quality: 82);
}

/// Fills [accounts], [posts] and [quota] with a believable sample workspace.
Future<void> seedDemo({
  required AdapterRegistry registry,
  required AccountRepository accounts,
  required PostRepository posts,
  required QuotaRepository quota,
  MediaLibrary? media,
}) async {
  final now = DateTime.now();
  final made = <ConnectedAccount>[];
  final pics = <MediaAttachment>[];
  if (media != null) {
    const alts = [
      'A workbench at golden hour with tools hanging on a pegboard',
      'A split keyboard on a desk under soft blue light',
      'Plants on a sunny windowsill next to a soldering iron',
    ];
    for (var i = 0; i < 3; i++) {
      final m = await media.importBytes(_demoImage(i), fileName: 'demo-$i.jpg', mimeHint: 'image/jpeg');
      pics.add(m.copyWith(altText: alts[i]));
    }
  }

  Future<void> add(String platformId, PlatformTier preferred, String name, String handle) async {
    final d = registry.descriptor(platformId);
    if (d == null) return;
    final tier = d.supportsTier(preferred) ? preferred : d.defaultTier;
    final a = ConnectedAccount(
      id: 'demo-$platformId',
      platformId: platformId,
      tier: tier,
      displayName: name,
      handle: handle,
      createdAt: now.subtract(Duration(days: 30 - made.length)),
      config: const {'demo': true},
    );
    made.add(a);
    await accounts.upsert(a);
  }

  await add('mastodon', PlatformTier.openApi, 'Robin Okafor', '@robin@fosstodon.org');
  await add('bluesky', PlatformTier.openApi, 'Robin Okafor', '@robin.bsky.social');
  await add('x', PlatformTier.byokApi, 'Robin Okafor', '@robinmakes');
  await add('threads', PlatformTier.byokApi, 'Robin Okafor', '@robin.makes');
  await add('instagram', PlatformTier.handoff, 'robin.makes', '@robin.makes');
  await add('linkedin', PlatformTier.byokApi, 'Robin Okafor', 'Maker · Open source');
  await add('reddit', PlatformTier.openApi, 'u/robinmakes', 'r/selfhosted');
  await add('telegram', PlatformTier.openApi, 'Robin\'s Workshop', '@robinsworkshop');
  await add('tiktok', PlatformTier.handoff, 'robin.makes', '@robin.makes');
  await add('nostr', PlatformTier.openApi, 'Robin', 'npub1robin…k2x');

  String? id(String platform) => made.where((a) => a.platformId == platform).map((a) => a.id).firstOrNull;
  List<PostTarget> targets(List<String> platforms, {TargetStatus status = TargetStatus.pending, Map<String, TargetStatus> special = const {}}) => [
        for (final p in platforms)
          if (id(p) != null)
            PostTarget(
              accountId: id(p)!,
              status: special[p] ?? status,
              result: (special[p] ?? status) == TargetStatus.published
                  ? PublishResult.ok(remoteId: 'demo-$p', remoteUrl: registry.descriptor(p)?.homepage, publishedAt: now)
                  : (special[p] ?? status) == TargetStatus.failed
                      ? PublishResult.failure(const PublishError.quota('Monthly post cap reached (500/500)'))
                      : null,
            ),
      ];

  await posts.upsert(Post(
    id: 'demo-post-1',
    text: 'Shipped v2 of my mechanical keyboard firmware today. Per-key RGB is finally smooth at 1 kHz, and the whole thing is open source.\n\nChangelog and build guide in the repo.',
    link: 'https://example.org/firmware-v2',
    tags: const ['opensource', 'keyboards'],
    createdAt: now.subtract(const Duration(days: 2, hours: 3)),
    updatedAt: now.subtract(const Duration(days: 2, hours: 3)),
    status: PostStatus.published,
    targets: targets(['mastodon', 'bluesky', 'x', 'linkedin', 'reddit', 'nostr'], status: TargetStatus.published),
  ));

  await posts.upsert(Post(
    id: 'demo-post-2',
    text: 'Workshop tour: the new bench, the old lathe, and way too many clamps.',
    media: pics.take(2).toList(),
    createdAt: now.subtract(const Duration(hours: 20)),
    updatedAt: now.subtract(const Duration(hours: 19)),
    status: PostStatus.partial,
    targets: targets(
      ['mastodon', 'bluesky', 'threads', 'instagram', 'tiktok', 'x'],
      status: TargetStatus.published,
      special: {'instagram': TargetStatus.awaitingHandoff, 'tiktok': TargetStatus.awaitingHandoff, 'x': TargetStatus.failed},
    ),
  ));

  await posts.upsert(Post(
    id: 'demo-post-3',
    text: 'Live stream tomorrow at 18:00: building a split keyboard from scratch, start to finish. Bring questions!',
    tags: const ['live', 'diy'],
    media: pics.length > 1 ? [pics[1]] : const [],
    createdAt: now.subtract(const Duration(hours: 2)),
    updatedAt: now.subtract(const Duration(hours: 2)),
    scheduledAt: DateTime(now.year, now.month, now.day + 1, 9, 30),
    status: PostStatus.scheduled,
    targets: targets(['mastodon', 'bluesky', 'x', 'threads', 'telegram', 'instagram']),
  ));

  await posts.upsert(Post(
    id: 'demo-post-4',
    text: 'Weekly roundup #42: three community builds, one cursed PCB, and a soldering tip that changed my life.',
    createdAt: now.subtract(const Duration(hours: 1)),
    updatedAt: now.subtract(const Duration(hours: 1)),
    scheduledAt: DateTime(now.year, now.month, now.day + 3, 12, 0),
    status: PostStatus.scheduled,
    targets: targets(['mastodon', 'bluesky', 'linkedin', 'reddit']),
  ));

  await posts.upsert(Post(
    id: 'demo-post-5',
    text: 'Draft: thinking about switching the whole shop to solar. Anyone done this for a garage workshop?',
    createdAt: now.subtract(const Duration(minutes: 30)),
    updatedAt: now.subtract(const Duration(minutes: 30)),
    status: PostStatus.draft,
    targets: targets(['mastodon', 'bluesky']),
  ));

  // Quota usage so the meters have something to show.
  final xId = id('x');
  if (xId != null) {
    for (var i = 0; i < 37; i++) {
      await quota.record(QuotaEvent(accountId: xId, ruleId: 'x.posts_per_month', at: now.subtract(Duration(hours: i * 17))));
    }
  }
  final thId = id('threads');
  if (thId != null) {
    for (var i = 0; i < 12; i++) {
      await quota.record(QuotaEvent(accountId: thId, ruleId: 'threads.posts_per_day', at: now.subtract(Duration(minutes: i * 90))));
    }
  }
}
