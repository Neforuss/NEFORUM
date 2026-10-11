import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../brand/platform_brand.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import 'markdown_style.dart';

/// Shows the bundled setup guide for [platformId] (`docs/platforms/<id>.md`).
Future<void> showGuideSheet(BuildContext context, String platformId, {String? asset}) {
  final sheet = GuideSheet(platformId: platformId, asset: asset);
  if (context.isCompact) {
    return showModalBottomSheet<void>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => FractionallySizedBox(heightFactor: 0.92, child: sheet));
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 780, maxHeight: 860), child: sheet),
    ),
  );
}

class GuideSheet extends ConsumerWidget {
  const GuideSheet({super.key, required this.platformId, this.asset});
  final String platformId;

  /// Override the asset name (e.g. 'media-hosts.md').
  final String? asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final d = ref.watch(registryProvider).descriptor(platformId);
    final name = d?.name ?? platformId;
    final file = asset ?? '$platformId.md';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.xl, Space.md, Space.md),
        child: Row(children: [
          if (asset == null) ...[PlatformTile(platformId, size: 36), const SizedBox(width: Space.md)],
          Expanded(child: Text(asset == null ? '$name setup guide' : 'Guide', style: context.text.headlineSmall)),
          IconButton(onPressed: () => Navigator.pop(context), tooltip: 'Close', icon: const Icon(Icons.close_rounded)),
        ]),
      ),
      Divider(height: 1, color: nf.border),
      Expanded(
        child: FutureBuilder<String>(
          future: rootBundle.loadString('assets/docs/$file'),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            if (snap.hasError || (snap.data ?? '').isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(Space.xxl),
                child: Text('The setup guide for $name is in docs/platforms/$file in the NEFORUM repository.', style: context.text.bodyMedium),
              );
            }
            return Scrollbar(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(Space.xxl, Space.lg, Space.xxl, Space.x4),
                child: NfMarkdown(snap.data!, selectable: true),
              ),
            );
          },
        ),
      ),
    ]);
  }
}
