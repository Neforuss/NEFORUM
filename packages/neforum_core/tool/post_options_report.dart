// Prints, per network, every PostVariant.extra key its adapter reads and
// how the key is declared on its PlatformDescriptor.options: shown up front,
// under "More options", in a control of its own, set by NEFORUM itself, or
// NOT DECLARED (read in code but out of the user's reach).
//
//   dart run tool/post_options_report.dart            (from packages/neforum_core)
//   dart run tool/post_options_report.dart --markdown (a table for docs or a PR)
//
// test/post_options_declared_test.dart fails whenever the NOT DECLARED list
// is not empty.
import 'package:neforum_core/neforum_core.dart';

import '../test/support/extra_key_scan.dart';
import '../test/support/post_options_attribution.dart';

void main(List<String> args) {
  final markdown = args.contains('--markdown');
  final scan = ExtraKeyScan.run();
  final rows = postOptionRows(scan, builtinAdapters());
  if (markdown) {
    print('| Network | Key | Kind | Where | Scope | Tiers | Read at |');
    print('|---|---|---|---|---|---|---|');
  }
  for (final r in rows) {
    if (markdown) {
      print('| ${r.platform} | `${r.key}` | ${r.option?.kind.name ?? ''} | ${r.where} | ${r.option?.scope.name ?? ''} | '
          '${r.option == null || r.option!.tiers.isEmpty ? 'all' : r.option!.tiers.map((t) => t.name).join(', ')} | ${r.readAt.isEmpty ? 'app' : r.readAt.first} |');
    } else {
      print('${r.platform.padRight(14)} ${r.key.padRight(32)} ${r.where.padRight(14)} ${r.readAt.isEmpty ? '(read by the app)' : r.readAt.join(', ')}');
    }
  }
  if (scan.unresolved.isNotEmpty) {
    print('\nReads the scan could not name:');
    scan.unresolved.forEach(print);
  }
  final missing = rows.where((r) => r.option == null).length;
  print('\n${rows.length} keys, $missing not declared');
}
