// Every platform setup guide the app ships follows one layout: the title, a
// short intro, the numbered "Steps" sections, and only then the explanation
// sections (how it works, limits, troubleshooting, sources), which the guide
// sheet shows collapsed.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

/// Guides that a parallel 1.2.0 workstream rewrites into this layout. Remove
/// this set once those rewrites are merged.
const _guidesAwaitingRewrite = {
  'bitchute',
  'bluesky',
  'devto',
  'discord',
  'facebook',
  'ghost',
  'google_business',
  'hashnode',
  'instagram',
  'lemmy',
  'linkedin',
};

/// A `## ` heading that opens a numbered procedure.
bool _isStepsHeading(String heading) => heading == 'Steps' || heading.startsWith('Steps:');

/// Every way the guide departs from the layout; empty when it follows it.
List<String> layoutProblems(String markdown) {
  final lines = markdown.replaceAll('\r\n', '\n').split('\n');
  final problems = <String>[];
  if (!RegExp(r'^# \S.* setup guide$').hasMatch(lines.first)) {
    problems.add('the title is not "# <Name> setup guide": ${lines.first}');
  }
  final firstSection = lines.indexWhere((l) => l.startsWith('## '));
  final intro = lines.sublist(1, firstSection < 0 ? lines.length : firstSection).where((l) => l.trim().isNotEmpty);
  if (intro.isEmpty || intro.first.startsWith('#') || RegExp(r'^\d+\. ').hasMatch(intro.first)) {
    problems.add('no intro sentence under the title');
  }

  final headings = <String>[];
  final numbered = <String, bool>{};
  for (final line in lines) {
    if (line.startsWith('## ')) {
      headings.add(line.substring(3).trim());
      numbered[headings.last] = false;
    } else if (headings.isNotEmpty && line.startsWith('1. ')) {
      numbered[headings.last] = true;
    }
  }
  if (headings.isEmpty || headings.first != 'Steps') {
    problems.add('the first section is not "## Steps"');
  }
  var explanationSeen = false;
  for (final h in headings) {
    if (!_isStepsHeading(h)) {
      explanationSeen = true;
    } else {
      if (explanationSeen) problems.add('"## $h" comes after an explanation section');
      if (numbered[h] != true) problems.add('"## $h" has no numbered list');
    }
  }
  return problems;
}

void main() {
  test('the layout check accepts a guide in the layout and rejects one out of order', () {
    const good = '# Example setup guide\n\nThis connects Example.\n\n## Steps\n\n1. Do this.\n\n'
        '## Steps: hand-off\n\n1. Do that.\n\n## How it works\n\nText.\n\n## Sources\n\n- https://example.org\n';
    expect(layoutProblems(good), isEmpty);

    const late = '# Example setup guide\n\nThis connects Example.\n\n## Steps\n\n1. Do this.\n\n'
        '## Limits\n\nText.\n\n## Steps: hand-off\n\n1. Do that.\n';
    expect(layoutProblems(late), ['"## Steps: hand-off" comes after an explanation section']);

    const explanationFirst = '# Example\n\nThis connects Example.\n\n## Ways to connect\n\nText.\n';
    expect(layoutProblems(explanationFirst), hasLength(2));
  });

  test('every platform guide starts with its numbered steps', () {
    final problems = <String>[];
    for (final adapter in builtinRegistry().all) {
      if (_guidesAwaitingRewrite.contains(adapter.id)) continue;
      final guide = File('assets/docs/${adapter.id}.md');
      if (!guide.existsSync()) {
        problems.add('${adapter.id}: assets/docs/${adapter.id}.md is missing (run dart run tool/sync_docs.dart)');
        continue;
      }
      for (final p in layoutProblems(guide.readAsStringSync())) {
        problems.add('${adapter.id}: $p');
      }
    }
    expect(problems, isEmpty);
  });
}
