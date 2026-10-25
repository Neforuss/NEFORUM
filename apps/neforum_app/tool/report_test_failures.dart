// Prints a GitHub Actions error annotation for every failed test in a
// `flutter test --file-reporter json:<file>` report, so the names and errors
// of failing tests show on the run's summary page.
//
//   dart run tool/report_test_failures.dart test-report.json

import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final file = File(args.isEmpty ? 'test-report.json' : args.first);
  if (!file.existsSync()) {
    stdout.writeln('::warning::No test report at ${file.path}');
    return;
  }
  final names = <int, String>{};
  final errors = <int, StringBuffer>{};
  final failed = <int>[];
  for (final line in file.readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    final Object? event;
    try {
      event = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (event is! Map) continue;
    switch (event['type']) {
      case 'testStart':
        final test = event['test'];
        if (test is Map && test['id'] is int) names[test['id'] as int] = '${test['name']}';
      case 'error':
        final id = event['testID'];
        if (id is int) (errors[id] ??= StringBuffer()).writeln('${event['error']}');
      case 'testDone':
        final id = event['testID'];
        if (id is int && event['result'] != 'success' && event['hidden'] != true) failed.add(id);
    }
  }
  for (final id in failed) {
    final message = (errors[id]?.toString() ?? 'failed').trim();
    final short = message.length > 900 ? '${message.substring(0, 900)}...' : message;
    stdout.writeln('::error title=${_escape(names[id] ?? 'test $id', property: true)}::${_escape(short)}');
  }
  stdout.writeln('${failed.length} failed test(s) reported');
}

/// Escapes a value for a workflow command (GitHub's rules for data and
/// properties).
String _escape(String value, {bool property = false}) {
  var out = value.replaceAll('%', '%25').replaceAll('\r', '%0D').replaceAll('\n', '%0A');
  if (property) out = out.replaceAll(':', '%3A').replaceAll(',', '%2C');
  return out;
}
