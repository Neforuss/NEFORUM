// Runs before every test file in test/ (flutter_test picks it up by name).

import 'dart:async';

import 'package:neforum_app/ui/shell/first_start_sync.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // 1.4.4: an empty real workspace asks whether to join a sync before
  // anything else. Tests that start the whole app for something else would
  // find it covering their screen; first_start_sync_test turns it back on.
  debugOfferSyncAtFirstStart = false;
  await testMain();
}
