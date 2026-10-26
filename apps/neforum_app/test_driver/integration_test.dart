// Runs an integration test on a profile (AOT-compiled) build, the way NEFORUM
// ships; `flutter test integration_test` only builds debug (JIT), which never
// shows AOT compiler faults such as the one that crashed 1.2.1 on every save.
//
//   flutter drive --profile -d windows --driver=test_driver/integration_test.dart --target=integration_test/captions_test.dart

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
