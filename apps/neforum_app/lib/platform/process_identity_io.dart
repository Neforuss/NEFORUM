import 'dart:io';

import 'process_identity.dart' show processIdentityFrom;

String? publishProcessIdentity() {
  if (Platform.isIOS) return processIdentityFrom(pid, null);
  if (!Platform.isAndroid) return null;
  String? stat;
  try {
    stat = File('/proc/self/stat').readAsStringSync();
  } on Object {
    stat = null;
  }
  return processIdentityFrom(pid, stat);
}
