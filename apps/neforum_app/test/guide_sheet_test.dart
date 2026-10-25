// The guide sheet: the numbered steps open, the explanation sections as
// panels that start closed, "Show all details", and links to headings.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/accounts/guide_sheet.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

const _guide = '''
# Example setup guide

Sets up Example. Afterwards NEFORUM posts there for you.

## Steps

1. Open the settings page.
2. Copy the key.

[Read the limits first](#limits)

## Steps: Hand-off without keys

1. Tap **Post** in the app.

## How it works

NEFORUM signs every request.

### Signing details

The token lasts five minutes.

## Limits

Up to 500 characters.

[Privacy policy guide](../meta-privacy-policy.md)

## Steps: a late procedure

1. Late step text.
''';

Widget _host(Widget child) => ProviderScope(
      overrides: [registryProvider.overrideWithValue(builtinRegistry())],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AccentChoice.neforum),
        home: Scaffold(body: child),
      ),
    );

Finder _text(String text) => find.textContaining(text, findRichText: true);

void main() {
  group('parseGuide', () {
    test('the introduction and the leading procedures are open, everything after is a panel', () {
      final sections = parseGuide(_guide);
      expect(sections.map((s) => s.title), [null, 'Steps', 'Steps: Hand-off without keys', 'How it works', 'Limits', 'Steps: a late procedure']);
      expect(sections.map((s) => s.open), [true, true, true, false, false, false]);
      expect(sections.first.body, startsWith('# Example setup guide'));
      expect(sections[1].markdown, startsWith('## Steps\n\n1. Open the settings page.'));
      expect(sections[3].body, isNot(contains('## How it works')));
    });

    test('anchors cover the section heading and every heading inside it', () {
      final sections = parseGuide(_guide);
      expect(sections.first.anchors, {'example-setup-guide'});
      expect(sections[2].anchors, {'steps-hand-off-without-keys'});
      expect(sections[3].anchors, {'how-it-works', 'signing-details'});
    });

    test('headings inside fenced code blocks are text', () {
      final sections = parseGuide('# Policy\n\nIntro.\n\n## Steps\n\n1. Copy this:\n\n   ```\n   ## What is collected\n   Nothing.\n   ```\n\n## Related\n\n- A link');
      expect(sections.map((s) => s.title), [null, 'Steps', 'Related']);
      expect(sections[1].body, contains('## What is collected'));
    });

    test('a guide without procedures shows its introduction and panels', () {
      final sections = parseGuide('# Topic\n\nIntro.\n\n## Background\n\nText.');
      expect(sections.map((s) => s.open), [true, false]);
      expect(isGuideProcedureHeading('Step by step'), isFalse);
      expect(isGuideProcedureHeading('Steps'), isTrue);
      expect(isGuideProcedureHeading('Steps: Automatic posting'), isTrue);
    });

    test('headings lose their markup in panel titles', () {
      final sections = parseGuide('# T\n\n## **Limits** of `api`\n\nText.\n\n## [Sources](https://example.org)\n\n- x');
      expect(sections[1].title, 'Limits of api');
      expect(sections[2].title, 'Sources');
    });
  });

  group('GuideBody', () {
    testWidgets('shows the steps and keeps explanation sections closed until tapped', (tester) async {
      await tester.pumpWidget(_host(const GuideBody(markdown: _guide)));
      expect(_text('Open the settings page.'), findsOneWidget);
      expect(_text('Tap '), findsOneWidget);
      expect(find.text('How it works'), findsOneWidget);
      expect(find.text('Limits'), findsOneWidget);
      expect(find.text('Steps: a late procedure'), findsOneWidget);
      expect(_text('NEFORUM signs every request.'), findsNothing);
      expect(_text('Late step text.'), findsNothing);

      await tester.tap(find.text('How it works'));
      await tester.pumpAndSettle();
      expect(_text('NEFORUM signs every request.'), findsOneWidget);
      expect(_text('Signing details'), findsOneWidget);
      expect(_text('Up to 500 characters.'), findsNothing);

      await tester.tap(find.text('How it works'));
      await tester.pumpAndSettle();
      expect(_text('NEFORUM signs every request.'), findsNothing);
    });

    testWidgets('Show all details opens every panel, Hide all details closes them', (tester) async {
      await tester.pumpWidget(_host(const GuideBody(markdown: _guide)));
      await tester.tap(find.text('Show all details'));
      await tester.pumpAndSettle();
      expect(_text('NEFORUM signs every request.'), findsOneWidget);
      expect(_text('Up to 500 characters.'), findsOneWidget);
      expect(_text('Late step text.'), findsOneWidget);
      expect(find.text('Hide all details'), findsOneWidget);

      await tester.tap(find.text('Hide all details'));
      await tester.pumpAndSettle();
      expect(_text('Up to 500 characters.'), findsNothing);
      expect(find.text('Show all details'), findsOneWidget);
    });

    testWidgets('a link to a heading opens the panel that holds it', (tester) async {
      await tester.pumpWidget(_host(const GuideBody(markdown: _guide)));
      expect(_text('Up to 500 characters.'), findsNothing);
      await tester.tap(_text('Read the limits first'));
      await tester.pumpAndSettle();
      expect(_text('Up to 500 characters.'), findsOneWidget);
    });

    testWidgets('opening at a section opens the panel with that heading', (tester) async {
      await tester.pumpWidget(_host(const GuideBody(markdown: _guide, section: 'signing-details')));
      await tester.pumpAndSettle();
      expect(_text('The token lasts five minutes.'), findsOneWidget);
      expect(_text('Up to 500 characters.'), findsNothing);
    });

    testWidgets('links to other guides inside a panel still open them', (tester) async {
      await tester.pumpWidget(_host(const GuideBody(markdown: _guide)));
      await tester.tap(find.text('Limits'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(_text('Privacy policy guide'));
      await tester.pumpAndSettle();
      await tester.tap(_text('Privacy policy guide'));
      await tester.pump();
      expect(find.byType(GuideSheet), findsOneWidget);
    });
  });

  testWidgets('a bundled platform guide opens with its steps and closed details', (tester) async {
    await tester.pumpWidget(_host(const GuideSheet(platformId: 'discord')));
    await tester.pumpAndSettle();
    // The sheet's header shows the title, so the guide's own # title is not repeated.
    expect(_text('Discord setup guide'), findsOneWidget);
    expect(_text('Copy Webhook URL'), findsOneWidget);
    expect(find.text('Show all details'), findsOneWidget);
    expect(find.text('Sources'), findsOneWidget);
    expect(_text('https://docs.discord.com/developers/topics/rate-limits'), findsNothing);
  });

  testWidgets('a link to another guide opens it at the heading it names', (tester) async {
    await tester.pumpWidget(_host(const GuideSheet(platformId: 'media-hosts', asset: 'media-hosts.md', section: 'fallback-host')));
    await tester.pumpAndSettle();
    expect(_text('NEFORUM uploads the file to the fallback instead'), findsOneWidget);
    expect(_text('Both are free services run by one volunteer'), findsNothing);
  });

  test('in every bundled guide the numbered procedures come before the explanations', () {
    final docs = Directory('assets/docs').listSync().whereType<File>().where((f) => f.path.endsWith('.md')).toList();
    expect(docs, isNotEmpty);
    final misplaced = <String>[];
    for (final f in docs) {
      final text = f.readAsStringSync();
      final name = f.uri.pathSegments.last;
      expect(text.trimLeft(), startsWith('# '), reason: '$name must start with its title');
      final sections = parseGuide(text);
      for (final s in sections) {
        if (s.title != null && isGuideProcedureHeading(s.title!) && !s.open) misplaced.add('$name: ${s.title}');
      }
      final procedures = sections.where((s) => s.title != null && isGuideProcedureHeading(s.title!));
      for (final s in procedures) {
        if (!RegExp(r'^\s*1\. ', multiLine: true).hasMatch(s.body)) misplaced.add('$name: ${s.title} has no numbered steps');
      }
    }
    expect(misplaced, isEmpty);
  });
}
