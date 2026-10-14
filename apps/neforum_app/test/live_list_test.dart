import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/state/providers.dart';

void main() {
  test('a failed read is retried instead of leaving the list empty for good', () async {
    var calls = 0;
    Future<List<String>> load() async {
      calls++;
      if (calls <= 2) throw Exception('file busy');
      return ['bluesky', 'mastodon'];
    }

    final changes = StreamController<void>.broadcast();
    addTearDown(changes.close);
    final first = await liveList(load, changes.stream, retry: const Duration(milliseconds: 10)).first;
    expect(first, ['bluesky', 'mastodon']);
    expect(calls, 3);
  });

  test('later changes still come through after a failed reload', () async {
    var calls = 0;
    Future<List<int>> load() async {
      calls++;
      if (calls == 2) throw Exception('file busy');
      return [calls];
    }

    final changes = StreamController<void>.broadcast();
    final seen = <List<int>>[];
    final sub = liveList(load, changes.stream, retry: const Duration(milliseconds: 10)).listen(seen.add);
    // Close the change feed first so the generator can finish, then cancel.
    addTearDown(() async {
      await changes.close();
      await sub.cancel();
    });
    await pumpEventQueue();
    changes.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(seen, [
      [1],
      [3],
    ]);
  });
}
