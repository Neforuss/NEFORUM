import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/ui/accounts/reconnect_action.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

// 1.4.3: what one-tap Reconnect says and where it goes. The flow itself is
// AccountReconnector's, tested in core (account_reconnect_test.dart).

void main() {
  final account = ConnectedAccount(id: 'x-42', platformId: 'x', tier: PlatformTier.byokApi, displayName: 'Robin', handle: '@robin', createdAt: DateTime.utc(2026, 1, 1));

  test('every outcome reads in plain words, with no dash and no key', () {
    final words = {
      for (final r in ReconnectResult.values) r: reconnectWords('X', ReconnectOutcome(r)),
    };
    expect(words[ReconnectResult.renewed], 'X reconnected with the keys it already had.');
    expect(words[ReconnectResult.reconnected], 'X reconnected.');
    expect(words[ReconnectResult.needsForm], 'Enter the X keys again to reconnect it.');
    expect(words[ReconnectResult.cancelled], 'Sign-in cancelled. Nothing changed.');
    expect(words[ReconnectResult.failed], 'Could not reconnect X. Nothing changed.');
    for (final w in words.values) {
      expect(w, isNot(contains('—')));
      expect(w, isNot(contains('token')));
    }
    // The reconnector's own sentence wins where it has one.
    expect(reconnectWords('X', const ReconnectOutcome(ReconnectResult.otherAccount, message: 'You signed in to X as @sam.')), 'You signed in to X as @sam.');
    expect(reconnectWords('X', const ReconnectOutcome(ReconnectResult.needsForm, message: 'The client secret was rotated')), 'The client secret was rotated');
  });

  test('the form opens straight at the way the account posts', () {
    expect(reconnectFormLocation(account), '/accounts/add?platform=x&tier=byokApi');
    expect(reconnectFormLocation(account, withTier: false), '/accounts/add?platform=x');
  });

  test('a second tap while one Reconnect is under way opens nothing', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final busy = c.read(reconnectingProvider.notifier);
    expect(busy.start('x-42'), isTrue);
    expect(busy.start('x-42'), isFalse);
    expect(c.read(reconnectingProvider), {'x-42'});
    busy.finish('x-42');
    expect(c.read(reconnectingProvider), isEmpty);
    expect(busy.start('x-42'), isTrue);
  });
}
