import 'dart:io';

import 'package:neforum_core/neforum_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final adapters = builtinAdapters();
  final repoRoot = p.normalize(p.join(Directory.current.path, '..', '..'));

  test('every adapter has a unique id', () {
    final ids = adapters.map((a) => a.id).toList();
    expect(ids.toSet().length, ids.length, reason: 'duplicate ids in $ids');
    expect(builtinRegistry().all.length, adapters.length);
  });

  for (final a in adapters) {
    group(a.id, () {
      final d = a.descriptor;

      test('descriptor is complete', () {
        expect(d.name.trim(), isNotEmpty);
        expect(d.accountRequirements.trim(), isNotEmpty);
        expect(d.apiCostSummary.trim(), isNotEmpty);
        expect(d.tiers, contains(d.defaultTier));
        expect(d.setupGuide, isNotNull);
      });

      test('setup guide exists', () {
        final guide = File(p.join(repoRoot, d.setupGuide!));
        expect(guide.existsSync(), isTrue, reason: 'missing ${guide.path}');
      });

      test('a connect spec exists for every tier', () {
        final specTiers = a.connectSpecs.map((s) => s.tier).toSet();
        for (final t in d.tiers) {
          expect(specTiers, contains(t), reason: '${a.id} declares $t but has no ConnectSpec for it');
        }
      });

      test('quota rule ids are namespaced and unique', () {
        final ids = d.defaultQuotas.map((q) => q.id).toList();
        expect(ids.toSet().length, ids.length);
        for (final id in ids) {
          expect(id, startsWith('${a.id}.'));
        }
      });

      if (d.supportsTier(PlatformTier.handoff)) {
        test('builds a hand-off plan for a simple text post', () {
          final plan = a.buildHandoff(const PostVariant(text: 'Hello from NEFORUM https://example.org #test'));
          expect(plan, isNotNull);
          expect(plan!.platformId, a.id);
          expect(plan.instructions.trim(), isNotEmpty);
          // Either somewhere to go, or (for self-hosted sites whose address
          // lives in the account) at least the text on the clipboard.
          final destination = plan.webIntent != null || plan.androidPackage != null || plan.iosScheme != null || plan.desktopUrl != null;
          expect(destination || (plan.clipboardText ?? '').isNotEmpty, isTrue, reason: 'a hand-off needs somewhere to go');
        });
      }

      test('validation never throws for an empty or simple post', () {
        final account = ConnectedAccount(
          id: 'test',
          platformId: a.id,
          tier: d.defaultTier,
          displayName: 'Test',
          createdAt: DateTime.utc(2026),
        );
        expect(() => a.validate(const PostVariant(text: ''), account), returnsNormally);
        expect(() => a.validate(const PostVariant(text: 'Hello', title: 'Hi'), account), returnsNormally);
      });
    });
  }
}
