// 1.4.3: clear selected state. Every chip, segment and option pill reads as
// on or off at a glance: on is a solid fill at least 3:1 off the surface
// with white text and a check mark, off is the surface with a visible
// border. Before, a selected chip was a 9% accent tint with the same border
// as an unselected one and no check ("Fill the whole frame", the text card
// signature and @handle chips read as either state).

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/selection_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_app/ui/settings/setting_row.dart';
import 'package:neforum_app/widgets/selection_marks.dart';
import 'package:neforum_app/widgets/surfaces.dart';

/// The accents to check: every preset and the user's own color at its
/// extremes.
final _accents = <(AccentChoice, int?)>[
  for (final a in AccentChoice.presets) (a, null),
  (AccentChoice.custom, 0xFFFFFFFF),
  (AccentChoice.custom, 0xFF000000),
  (AccentChoice.custom, 0xFFFFEE58),
  (AccentChoice.custom, 0xFF00FF00),
  (AccentChoice.custom, 0xFF0000FF),
  (AccentChoice.custom, 0xFF808080),
];

ThemeData _theme(Brightness b, AccentChoice a, int? custom, {bool highContrast = false}) =>
    buildTheme(b, a, customAccent: custom, highContrast: highContrast);

String _name(Brightness b, AccentChoice a, int? custom, bool highContrast) =>
    '$b ${a.name}${custom == null ? '' : ' #${custom.toRadixString(16)}'}${highContrast ? ' high contrast' : ''}';

/// The fill a chip paints, from its ink.
Color _chipFill(WidgetTester tester, Finder chip) =>
    (tester.widget<Ink>(find.descendant(of: chip, matching: find.byType(Ink)).first).decoration! as ShapeDecoration).color!;

/// The color its label is drawn in (the avatar can hold text too).
Color _labelColor(WidgetTester tester, Finder chip) {
  final w = tester.widget(chip);
  final label = w is FilterChip ? w.label : (w as ChoiceChip).label;
  final paragraph = find.descendant(of: find.descendant(of: chip, matching: find.byWidget(label)), matching: find.byType(RichText), matchRoot: true);
  return tester.renderObject<RenderParagraph>(paragraph.first).text.style!.color!;
}

class _MemoryStorage implements AppStorage {
  _MemoryStorage(Map<String, Object> settings) : _json = {'settings.json': settings};
  final Map<String, Object> _json;
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => _json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => _json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async => 'mem://$id.$extension';
  @override
  Future<Uint8List> readMedia(String path) async => Uint8List(0);
  @override
  Future<void> deleteMedia(String path) async {}
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) =>
      SizedBox(width: width, height: height, child: const ColoredBox(color: Color(0xFF888888)));
}

void main() {
  group('the theme', () {
    test('selected and unselected fills differ by 3:1 or more on every surface, in both themes, with any accent', () {
      for (final b in Brightness.values) {
        for (final highContrast in [false, true]) {
          for (final (a, custom) in _accents) {
            final t = _theme(b, a, custom, highContrast: highContrast);
            final c = t.extension<NfColors>()!;
            final name = _name(b, a, custom, highContrast);
            final chip = t.chipTheme;
            expect(chip.selectedColor, c.selectedFill, reason: name);
            expect(chip.backgroundColor, c.surface, reason: name);
            for (final surface in [c.bg, c.surface, c.surfaceRaised, c.surfaceSunken]) {
              expect(contrastRatio(c.selectedFill, surface), greaterThanOrEqualTo(3), reason: '$name on $surface');
            }
            expect(contrastRatio(chip.selectedColor!, chip.backgroundColor!), greaterThanOrEqualTo(3), reason: name);
            // What is drawn on them.
            expect(chip.showCheckmark, isTrue, reason: name);
            expect(contrastRatio(chip.checkmarkColor!, c.selectedFill), greaterThanOrEqualTo(4.5), reason: name);
            final label = chip.labelStyle!.color! as WidgetStateColor;
            expect(contrastRatio(label.resolve({WidgetState.selected}), c.selectedFill), greaterThanOrEqualTo(4.5), reason: name);
            expect(contrastRatio(label.resolve({}), c.surface), greaterThanOrEqualTo(4.5), reason: name);
            // Off still shows where the chip is.
            final side = chip.side! as WidgetStateBorderSide;
            expect(side.resolve({})!.color, c.borderStrong, reason: name);
            expect(side.resolve({WidgetState.selected})!.color, c.selectedFill, reason: name);

            final segment = t.segmentedButtonTheme.style!;
            final on = segment.backgroundColor!.resolve({WidgetState.selected})!, off = segment.backgroundColor!.resolve({})!;
            expect(contrastRatio(on, off), greaterThanOrEqualTo(3), reason: 'segments: $name');
            expect(contrastRatio(segment.foregroundColor!.resolve({WidgetState.selected})!, on), greaterThanOrEqualTo(4.5), reason: name);
            expect(contrastRatio(segment.foregroundColor!.resolve({})!, off), greaterThanOrEqualTo(4.5), reason: name);
          }
        }
      }
    });

    test('a fill that already stands out is the accent itself', () {
      final light = _theme(Brightness.light, AccentChoice.neforum, null).extension<NfColors>()!;
      expect(light.selectedFill, light.accentFill);
      // The brand purple is 2.1:1 on the dark sheets: lightened, not replaced.
      final dark = _theme(Brightness.dark, AccentChoice.neforum, null).extension<NfColors>()!;
      expect(contrastRatio(dark.accentFill, const Color(0xFF1D1729)), lessThan(3));
      expect(dark.selectedFill, isNot(dark.accentFill));
      expect(HSVColor.fromColor(dark.selectedFill).hue, closeTo(HSVColor.fromColor(dark.accentFill).hue, 2));
    });
  });

  group('chips on screen', () {
    for (final b in Brightness.values) {
      for (final (a, custom) in [_accents.first, _accents[2], (AccentChoice.custom, 0xFFFFEE58)]) {
        testWidgets('${_name(b, a, custom, false)}: on and off render differently, the check only on', (tester) async {
          final theme = _theme(b, a, custom);
          final c = theme.extension<NfColors>()!;
          await tester.pumpWidget(MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Wrap(children: [
                FilterChip(key: const Key('on'), label: const Text('Option'), selected: true, onSelected: (_) {}),
                FilterChip(key: const Key('off'), label: const Text('Option'), selected: false, onSelected: (_) {}),
                ChoiceChip(key: const Key('choice-on'), label: const Text('Chosen'), selected: true, onSelected: (_) {}),
                FilterChip(key: const Key('disabled-on'), label: const Text('Locked on'), selected: true, onSelected: null),
              ]),
            ),
          ));
          final on = find.byKey(const Key('on')), off = find.byKey(const Key('off'));
          expect(_chipFill(tester, on), c.selectedFill);
          expect(_chipFill(tester, off), c.surface);
          expect(contrastRatio(_chipFill(tester, on), _chipFill(tester, off)), greaterThanOrEqualTo(3));
          expect(_chipFill(tester, find.byKey(const Key('choice-on'))), c.selectedFill);
          expect(_chipFill(tester, find.byKey(const Key('disabled-on'))), c.selectedFill, reason: 'a disabled chip that is on still reads as on');
          expect(contrastRatio(_labelColor(tester, on), c.selectedFill), greaterThanOrEqualTo(4.5));
          expect(_labelColor(tester, off), c.text);
          // The check mark is painted only on the chips that are on.
          final check = paints..something((method, args) => method == #drawPath && (args[1] as Paint).color == c.onSelectedFill);
          expect(tester.renderObject(find.descendant(of: on, matching: find.byType(Material)).first), check);
          expect(tester.renderObject(find.descendant(of: off, matching: find.byType(Material)).first), isNot(check));
          // On is wider, with the same label: the check takes room before it.
          expect(tester.getSize(on).width, greaterThan(tester.getSize(off).width + 10));
        });
      }
    }
  });

  group('hand-made selectables', () {
    testWidgets('option pills: filled and checked when on, outlined when off, plain as an action', (tester) async {
      for (final b in Brightness.values) {
        final theme = _theme(b, AccentChoice.neforum, null);
        final c = theme.extension<NfColors>()!;
        await tester.pumpWidget(MaterialApp(
          // A new app per theme: no theme animation between the two.
          key: ValueKey(b),
          theme: theme,
          home: Scaffold(
            body: Wrap(children: [
              OptionPill(key: const Key('on'), selected: true, label: 'NEFORUM signature', leading: const Icon(Icons.verified_rounded), onTap: () {}),
              OptionPill(key: const Key('off'), selected: false, label: 'Show @handle', leading: const Icon(Icons.alternate_email_rounded), onTap: () {}),
              OptionPill(key: const Key('action'), label: 'Save image', leading: const Icon(Icons.download_rounded), onTap: () {}),
            ]),
          ),
        ));
        BoxDecoration box(String key) =>
            tester.widget<AnimatedContainer>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(AnimatedContainer))).decoration! as BoxDecoration;
        Finder check(String key) => find.descendant(of: find.byKey(Key(key)), matching: find.byKey(const Key('option-pill-check')));
        expect(box('on').color, c.selectedFill);
        expect(box('off').color, Colors.transparent);
        expect(box('action').color, Colors.transparent);
        expect(check('on'), findsOneWidget);
        expect(check('off'), findsNothing);
        expect(check('action'), findsNothing);
        // The leading icon takes the pill's color: readable on the fill.
        final icon = tester.widget<IconTheme>(find.ancestor(of: find.byIcon(Icons.verified_rounded), matching: find.byType(IconTheme)).first);
        expect(contrastRatio(icon.data.color!, c.selectedFill), greaterThanOrEqualTo(4.5));
        // Screen readers hear on and off.
        final handle = tester.ensureSemantics();
        expect(tester.getSemantics(find.descendant(of: find.byKey(const Key('on')), matching: find.byType(Semantics)).first),
            matchesSemantics(
                isButton: true,
                hasToggledState: true,
                isToggled: true,
                hasEnabledState: true,
                isEnabled: true,
                hasTapAction: true,
                hasFocusAction: true,
                isFocusable: true,
                label: 'NEFORUM signature',
                tooltip: 'NEFORUM signature'));
        handle.dispose();
      }
    });

    testWidgets('a selected card has a check in its corner and a stronger border', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: _theme(Brightness.light, AccentChoice.neforum, null),
        home: Scaffold(
          body: Column(children: [
            NfCard(key: const Key('on'), selected: true, onTap: () {}, child: const Text('Tomorrow morning')),
            NfCard(key: const Key('off'), onTap: () {}, child: const Text('Tonight')),
            NfCard(key: const Key('radio'), selected: true, selectionBadge: false, onTap: () {}, child: const Text('With its own mark')),
          ]),
        ),
      ));
      Finder badge(String key) => find.descendant(of: find.byKey(Key(key)), matching: find.byType(SelectionCheckBadge));
      expect(badge('on'), findsOneWidget);
      expect(badge('off'), findsNothing);
      expect(badge('radio'), findsNothing);
      double border(String key) =>
          (tester.widget<AnimatedContainer>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(AnimatedContainer)).first).decoration!
                  as BoxDecoration)
              .border!
              .top
              .width;
      expect(border('on'), 2);
      expect(border('off'), 1);
    });
  });

  group('in the app', () {
    Future<NfColors> pumpSettings(WidgetTester tester, Brightness brightness, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Fill the whole frame on for TikTok only; the signature off on Pinterest.
      final services = (await tester.runAsync(() => AppServices.create(
          demo: true,
          storage: _MemoryStorage({
            'themeMode': brightness.name,
            'fillFramePlatforms': ['tiktok'],
            'textCardPlainPlatforms': ['pinterest'],
          }))))!;
      await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)], child: const NeforumApp()));
      await tester.pump(const Duration(milliseconds: 300));
      ProviderScope.containerOf(tester.element(find.byType(MaterialApp))).read(routerProvider).go('/settings');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      return Theme.of(tester.element(find.byType(Scaffold).first)).extension<NfColors>()!;
    }

    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    }

    for (final b in Brightness.values) {
      testWidgets('${b.name}: every chip on the Settings page reads as on or off, with readable labels', (tester) async {
        final c = await pumpSettings(tester, b, const Size(1440, 2400));
        final chips = find.byWidgetPredicate((w) => w is FilterChip || w is ChoiceChip);
        expect(chips, findsWidgets);
        var on = 0, off = 0;
        for (final element in chips.evaluate()) {
          final widget = element.widget;
          final selected = widget is FilterChip ? widget.selected : (widget as ChoiceChip).selected;
          final enabled = widget is FilterChip ? widget.onSelected != null : (widget as ChoiceChip).onSelected != null;
          final chip = find.byWidget(widget);
          final fill = _chipFill(tester, chip);
          if (selected) {
            on++;
            expect(fill, c.selectedFill, reason: 'a chip that is on');
          } else {
            off++;
            expect(fill, enabled ? c.surface : c.surfaceSunken, reason: 'a chip that is off');
          }
          expect(contrastRatio(_labelColor(tester, chip), fill), greaterThanOrEqualTo(enabled ? 4.5 : 2), reason: 'its label');
        }
        expect(on, greaterThan(0));
        expect(off, greaterThan(0));

        // The chips named in the report: Fill the whole frame on TikTok only,
        // the signature off on Pinterest.
        Finder chipIn(String row, String network) => find.descendant(
              of: find.ancestor(of: find.text(row), matching: find.byType(SettingRow)).first,
              matching: find.widgetWithText(FilterChip, network),
            );
        expect(_chipFill(tester, chipIn('Fill the whole frame', 'TikTok')), c.selectedFill);
        expect(_chipFill(tester, chipIn('Fill the whole frame', 'Instagram')), c.surface);
        expect(_chipFill(tester, chipIn('NEFORUM signature', 'Pinterest')), isNot(c.selectedFill));
        expect(_chipFill(tester, chipIn('NEFORUM signature', 'TikTok')), c.selectedFill);
        await unmount(tester);
      });
    }

    testWidgets('the section chips of narrow pages: the one in view filled, its label readable', (tester) async {
      final c = await pumpSettings(tester, Brightness.light, const Size(390, 844));
      // At the top of the page, Appearance is the section in view.
      final current = find.widgetWithText(ChoiceChip, 'Appearance');
      expect(tester.widget<ChoiceChip>(current).selected, isTrue);
      expect(_chipFill(tester, current), c.selectedFill);
      expect(contrastRatio(_labelColor(tester, current), c.selectedFill), greaterThanOrEqualTo(4.5));
      await unmount(tester);
    });
  });
}
