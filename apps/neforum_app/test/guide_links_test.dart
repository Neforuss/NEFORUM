// Links between the bundled guides: `../media-hosts.md` works on GitHub, and
// the app opens the same file from assets/docs.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/accounts/guide_sheet.dart';
import 'package:neforum_app/ui/accounts/markdown_style.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

void main() {
  test('relative .md links map to a bundled guide, everything else does not', () {
    expect(guideAssetForLink('../meta-privacy-policy.md'), 'meta-privacy-policy.md');
    expect(guideAssetForLink('platforms/bluesky.md'), 'bluesky.md');
    expect(guideAssetForLink('media-hosts.md#litterbox'), 'media-hosts.md');
    expect(guideAssetForLink('https://example.org/guide.md'), isNull);
    expect(guideAssetForLink('mailto:someone@example.org'), isNull);
    expect(guideAssetForLink('../LICENSE'), isNull);
    expect(guideAssetForLink('#data-deletion'), isNull);
    expect(guideAssetForLink(null), isNull);
  });

  test('every relative guide link points to a guide the app ships', () {
    final docs = Directory('assets/docs').listSync().whereType<File>().where((f) => f.path.endsWith('.md')).toList();
    final names = {for (final f in docs) f.uri.pathSegments.last};
    expect(names, contains('meta-privacy-policy.md'));
    final link = RegExp(r'\]\(([^)\s]+)\)');
    final broken = <String>[];
    for (final f in docs) {
      for (final m in link.allMatches(f.readAsStringSync())) {
        final asset = guideAssetForLink(m.group(1));
        if (asset != null && !names.contains(asset)) broken.add('${f.uri.pathSegments.last} -> ${m.group(1)}');
      }
    }
    expect(broken, isEmpty);
  });

  testWidgets('tapping a guide link opens that guide in the app', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [registryProvider.overrideWithValue(builtinRegistry())],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: const Scaffold(body: NfMarkdown('[Privacy policy help](../meta-privacy-policy.md)')),
      ),
    ));
    await tester.tap(find.textContaining('Privacy policy help', findRichText: true));
    await tester.pump();
    expect(find.byType(GuideSheet), findsOneWidget);
    expect(find.text('Guide'), findsOneWidget);
  });
}
