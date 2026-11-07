import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

void main() {
  final descriptors = builtinRegistry().descriptors;

  test('compactName is the shortName when there is one, otherwise the name', () {
    expect(builtinRegistry().descriptor('x')!.compactName, 'X');
    expect(builtinRegistry().descriptor('x')!.name, 'X (Twitter)');
    expect(builtinRegistry().descriptor('mastodon')!.shortName, isNull);
    expect(builtinRegistry().descriptor('mastodon')!.compactName, 'Mastodon');
  });

  test('long art site names have a short form, so one of them does not lower the column count', () {
    expect(builtinRegistry().descriptor('deviantart')!.compactName, 'Deviant');
    expect(builtinRegistry().descriptor('furaffinity')!.compactName, 'Fur Aff.');
    expect(builtinRegistry().descriptor('newgrounds')!.compactName, 'NG');
  });

  test('both DeviantArt descriptors, signed in and hand-off, say the same', () {
    final adapter = builtinAdapters().singleWhere((a) => a.id == 'deviantart');
    for (final tier in const [PlatformTier.byokApi, PlatformTier.handoff]) {
      final account = ConnectedAccount(id: 'a', platformId: 'deviantart', tier: tier, displayName: 'a', createdAt: DateTime.utc(2026));
      expect(adapter.descriptorForAccount(account).shortName, 'Deviant', reason: tier.name);
    }
  });

  test('compact names tell every network apart', () {
    final names = descriptors.map((d) => d.compactName).toList();
    expect(names.toSet().length, names.length, reason: 'two networks read the same in $names');
  });

  test('a short name is actually shorter', () {
    for (final d in descriptors.where((d) => d.shortName != null)) {
      expect(d.shortName!.length, lessThan(d.name.length), reason: d.id);
    }
  });

  // The phone's account grid keeps a name on at most two lines of about ten
  // characters. The real widths are checked in the app's
  // account_selection_grid_test.dart.
  test('no compact name is too long for a narrow cell', () {
    for (final d in descriptors) {
      final words = d.compactName.split(' ');
      expect(words.length, lessThanOrEqualTo(2), reason: d.compactName);
      for (final w in words) {
        expect(w.length, lessThanOrEqualTo(10), reason: d.compactName);
      }
    }
  });
}
