import 'dart:io';

String deviceHostName() {
  try {
    return Platform.localHostname;
  } on Object {
    return '';
  }
}
