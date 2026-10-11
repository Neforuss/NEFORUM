import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/env.dart';

void main() {
  test('kAppVersion matches pubspec.yaml and the Windows installer', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*([0-9.]+)', multiLine: true).firstMatch(pubspec)!.group(1);
    expect(kAppVersion, version);
    final iss = File('installer/neforum.iss').readAsStringSync();
    expect(iss, contains('#define AppVersion "$kAppVersion"'));
  });
}
