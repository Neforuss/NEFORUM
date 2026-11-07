// Emoji at the cursor, in every field that takes them, through the real widgets.
// Each field: the pick replaces the selection, the caret lands right after it in
// UTF-16 units, the field's own onChanged runs, the focus stays in the field
// (TextFieldTapRegion), a composition in progress ends, and the sheet stays open.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/media/card_design.dart';
import 'package:neforum_app/media/card_templates.dart';
import 'package:neforum_app/media/emoji_text.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/theme/app_theme.dart';
import 'package:neforum_app/theme/tokens.dart';
import 'package:neforum_app/ui/compose/caption_editor_sheet.dart';
import 'package:neforum_app/ui/compose/card_designer_sheet.dart';
import 'package:neforum_app/ui/compose/customize_sheet.dart';
import 'package:neforum_app/ui/compose/differentiation_panel.dart';
import 'package:neforum_app/ui/compose/editor_card.dart';
import 'package:neforum_app/ui/compose/emoji_catalog.dart';
import 'package:neforum_app/ui/compose/emoji_insert.dart';
import 'package:neforum_app/ui/compose/media_tray.dart';
import 'package:neforum_app/ui/compose/poll_sheet.dart';
import 'package:neforum_app/ui/compose/track_details_sheet.dart';
import 'package:neforum_app/widgets/char_ring.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

const String grin = '\u{1F600}';
const String grinId = 'emoji-1F600';

ConnectedAccount _account(String platformId) => ConnectedAccount(
      id: 'acct-$platformId',
      platformId: platformId,
      tier: builtinRegistry().descriptor(platformId)!.defaultTier,
      displayName: platformId,
      createdAt: DateTime.utc(2026, 10, 1),
    );

class _Harness {
  late ProviderContainer container;
  late BuildContext context;
  final FocusNode mainFocus = FocusNode();
}

Future<AppStorage> _tempStorage() async {
  final dir = Directory.systemTemp.createTempSync('nf-emoji-');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // Still in use on Windows; the system cleans it up.
    }
  });
  final storage = await openAppStorage(overrideDir: dir.path);
  await storage.writeJson('settings.json', {'onboarded': true, 'updateCheck': 'off'});
  return storage;
}

/// The composer's real editors in a page, on real services.
Future<_Harness> _pump(WidgetTester t, {Size size = const Size(1400, 1100), List<String> networks = const ['mastodon', 'reddit']}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final storage = (await t.runAsync(_tempStorage))!;
  final s = (await t.runAsync(() => AppServices.create(demo: true, storage: storage)))!;
  final h = _Harness();
  addTearDown(h.mainFocus.dispose);
  final accounts = [for (final n in networks) _account(n)];
  await t.pumpWidget(ProviderScope(
    overrides: [
      servicesProvider.overrideWithValue(s),
      isDemoProvider.overrideWithValue(false),
      accountsProvider.overrideWith((ref) => Stream.value(accounts)),
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AccentChoice.neforum),
      home: Scaffold(
        body: Builder(builder: (context) {
          h.context = context;
          h.container = ProviderScope.containerOf(context);
          return SingleChildScrollView(
            child: Column(children: [
              EditorCard(focusNode: h.mainFocus),
              const ThreadPartEditors(),
              const DifferentiationPanel(),
            ]),
          );
        }),
      ),
    ),
  ));
  await t.pump(const Duration(milliseconds: 100));
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await t.pump(const Duration(milliseconds: 100));
  h.container.read(composerProvider.notifier).reset(keepTargets: false);
  await t.pump();
  return h;
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 80));
  }
}

/// Picks 😀 twice into [field] and checks everything the rubric names.
/// [committed] reads what the field's onChanged reached.
Future<void> _exercise(WidgetTester t, Finder field, {required String Function() committed}) async {
  expect(field, findsOneWidget);
  await t.ensureVisible(field);
  await t.pump();
  await t.tap(field);
  await t.pump();
  final widget = t.widget<TextField>(field);
  final controller = widget.controller!;
  final editable = find.descendant(of: field, matching: find.byType(EditableText));
  expect(t.widget<EditableText>(editable).focusNode.hasFocus, isTrue, reason: 'the tap focused it');

  controller.value = const TextEditingValue(
    text: 'hello world',
    selection: TextSelection(baseOffset: 6, extentOffset: 11),
    composing: TextRange(start: 6, end: 11),
  );
  // The field brings its caret into view; a scroll under way takes no taps.
  await _settle(t);

  final button = find.byKey(const Key('emoji-button')).last;
  await t.ensureVisible(button);
  await t.pump();
  await t.tap(button);
  await _settle(t);
  expect(find.byKey(const Key('emoji-panel')), findsOneWidget, reason: 'a panel, not a modal sheet, on a computer');
  expect(t.widget<EditableText>(editable).focusNode.hasFocus, isTrue, reason: 'opening keeps the cursor in the field');

  await t.tap(find.byKey(const ValueKey(grinId)));
  await _settle(t);
  expect(controller.text, 'hello $grin', reason: 'replaces the selection');
  expect(controller.selection, const TextSelection.collapsed(offset: 8), reason: 'caret after both UTF-16 units');
  expect(controller.value.composing, TextRange.empty, reason: 'a composition in progress ends');
  expect(committed(), contains('hello $grin'), reason: "the field's onChanged ran");
  expect(t.widget<EditableText>(editable).focusNode.hasFocus, isTrue, reason: 'the cursor stays in the field');
  expect(find.byKey(const Key('emoji-panel')), findsOneWidget, reason: 'stays open across picks');

  await t.tap(find.byKey(const ValueKey(grinId)));
  await _settle(t);
  expect(controller.text, 'hello $grin$grin');
  expect(controller.selection, const TextSelection.collapsed(offset: 10));
  expect(committed(), contains('hello $grin$grin'));

  await t.tap(find.byKey(const Key('emoji-close')));
  await _settle(t);
  expect(find.byKey(const Key('emoji-panel')), findsNothing);
  expect(t.widget<EditableText>(editable).focusNode.hasFocus, isTrue, reason: 'closing leaves the cursor in the field');
}

void _desktop(String description, WidgetTesterCallback body) => testWidgets(description, body, variant: TargetPlatformVariant.only(TargetPlatform.windows));

Finder _fieldLabelled(String label) => find.byWidgetPredicate((w) => w is TextField && (w.decoration?.labelText == label || w.decoration?.hintText == label));

void main() {
  setUp(() {
    EmojiSupport.debugReset();
    EmojiSupport.debugProbe = (_) => EmojiDraw.whole;
    debugResetEmojiDeviceSupport();
  });
  tearDown(() {
    EmojiSupport.debugReset();
    debugResetEmojiDeviceSupport();
  });

  group('valueWithInserted', () {
    test('replaces the selection, caret in UTF-16 units', () {
      final v = valueWithInserted(const TextEditingValue(text: 'hello world', selection: TextSelection(baseOffset: 6, extentOffset: 11)), grin);
      expect(v.text, 'hello $grin');
      expect(v.selection, const TextSelection.collapsed(offset: 8));
    });

    test('a backwards selection is the same selection', () {
      final v = valueWithInserted(const TextEditingValue(text: 'abcd', selection: TextSelection(baseOffset: 3, extentOffset: 1)), 'X');
      expect((v.text, v.selection.baseOffset), ('aXd', 2));
    });

    test('a long family moves the caret by its whole length', () {
      const family = '\u{1F468}‍\u{1F469}‍\u{1F467}‍\u{1F466}';
      final v = valueWithInserted(const TextEditingValue(text: 'ab', selection: TextSelection.collapsed(offset: 1)), family);
      expect(v.selection.baseOffset, 1 + family.length);
      expect(family.length, 11);
    });

    test('no selection: at the end', () {
      expect(valueWithInserted(const TextEditingValue(text: 'ab'), 'X').text, 'abX');
      expect(valueWithInserted(const TextEditingValue(text: 'ab', selection: TextSelection.collapsed(offset: -1)), 'X').text, 'abX');
    });

    test('a selection past the end is clamped', () {
      final v = valueWithInserted(const TextEditingValue(text: 'ab', selection: TextSelection.collapsed(offset: 9)), 'X');
      expect((v.text, v.selection.baseOffset), ('abX', 3));
    });

    test('a live composition ends', () {
      final v = valueWithInserted(const TextEditingValue(text: 'ni', selection: TextSelection.collapsed(offset: 2), composing: TextRange(start: 0, end: 2)), grin);
      expect(v.composing, TextRange.empty);
      expect(v.text, 'ni$grin');
    });

    test('insertAtCursor calls the field callback, which setting a value does not', () {
      final c = TextEditingController(text: 'a');
      addTearDown(c.dispose);
      final calls = <String>[];
      insertAtCursor(c, 'b', onChanged: calls.add);
      expect(calls, ['ab']);
    });
  });

  group('every field takes an emoji', () {
    _desktop('main post text', (t) async {
      final h = await _pump(t);
      final field = find.byWidgetPredicate((w) => w is TextField && w.focusNode == h.mainFocus);
      await _exercise(t, field, committed: () => h.container.read(composerProvider).text);
      await t.pumpWidget(const SizedBox.shrink());
    });

    _desktop('thread part', (t) async {
      final h = await _pump(t);
      h.container.read(composerProvider.notifier).addPart();
      await _settle(t);
      await _exercise(t, _fieldLabelled('Continue the thread'), committed: () => h.container.read(composerProvider).additionalParts.first);
      await t.pumpWidget(const SizedBox.shrink());
    });

    _desktop('title', (t) async {
      final h = await _pump(t);
      // Reddit requires a title, so its field is there.
      h.container.read(composerProvider.notifier).selectAccounts(['acct-reddit']);
      await _settle(t);
      await _exercise(t, find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Title')), committed: () => h.container.read(composerProvider).title ?? '');
      await t.pumpWidget(const SizedBox.shrink());
    });

    _desktop('content warning', (t) async {
      final h = await _pump(t);
      h.container.read(composerProvider.notifier).selectAccounts(['acct-mastodon']);
      await _settle(t);
      await t.tap(find.byTooltip('Content warning'));
      await _settle(t);
      await _exercise(t, find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Content warning')), committed: () => h.container.read(composerProvider).contentWarning ?? '');
      await t.pumpWidget(const SizedBox.shrink());
    });

    _desktop('per-network version', (t) async {
      final h = await _pump(t);
      final n = h.container.read(composerProvider.notifier);
      n.selectAccounts(['acct-mastodon']);
      n.setDifferentiate(true);
      await _settle(t);
      await _exercise(t, _fieldLabelled('The Mastodon version'), committed: () => h.container.read(composerProvider).overrides['acct-mastodon']?.text ?? '');
      await t.pumpWidget(const SizedBox.shrink());
    });

    group('customize sheet', () {
      Future<_Harness> open(WidgetTester t) async {
        final h = await _pump(t);
        h.container.read(composerProvider.notifier)
          ..selectAccounts(['acct-reddit'])
          ..setText('words');
        await _settle(t);
        showCustomizeSheet(h.context, h.container.read(composerPreviewsProvider).single);
        await _settle(t);
        return h;
      }

      String sheetSave(WidgetTester t, _Harness h, String Function(PostOverrides o) read) {
        return read(h.container.read(composerProvider).overrides['acct-reddit'] ?? const PostOverrides());
      }

      _desktop('text', (t) async {
        final h = await open(t);
        final field = _fieldLabelled('Text');
        final usedBefore = t.widget<CharRing>(find.byType(CharRing).last).used;
        await _exercise(t, field, committed: () => t.widget<TextField>(field).controller!.text);
        expect(t.widget<CharRing>(find.byType(CharRing).last).used, greaterThan(usedBefore), reason: 'onChanged ran: the ring moved');
        await t.tap(find.text('Save'));
        await _settle(t);
        expect(sheetSave(t, h, (o) => o.text ?? ''), 'hello $grin$grin');
        await t.pumpWidget(const SizedBox.shrink());
      });

      _desktop('title', (t) async {
        final h = await open(t);
        final field = _fieldLabelled('Title');
        await _exercise(t, field, committed: () => t.widget<TextField>(field).controller!.text);
        expect(find.text('10/300'), findsOneWidget, reason: 'onChanged ran: the counter moved');
        await t.tap(find.text('Save'));
        await _settle(t);
        expect(sheetSave(t, h, (o) => o.title ?? ''), 'hello $grin$grin');
        await t.pumpWidget(const SizedBox.shrink());
      });

      _desktop('content warning', (t) async {
        final h = await _pump(t, networks: const ['mastodon']);
        h.container.read(composerProvider.notifier).selectAccounts(['acct-mastodon']);
        await _settle(t);
        showCustomizeSheet(h.context, h.container.read(composerPreviewsProvider).single);
        await _settle(t);
        final field = _fieldLabelled('Content warning');
        await _exercise(t, field, committed: () => t.widget<TextField>(field).controller!.text);
        await t.tap(find.text('Save'));
        await _settle(t);
        expect(h.container.read(composerProvider).overrides['acct-mastodon']?.contentWarning, 'hello $grin$grin');
        await t.pumpWidget(const SizedBox.shrink());
      });
    });

    _desktop('words on a photo', (t) async {
      final h = await _pump(t);
      showCaptionEditorSheet(h.context, platformId: 'instagram');
      await _settle(t);
      await _exercise(t, find.byKey(const Key('caption-words')), committed: () => h.container.read(composerProvider).captionStyle?['text'] as String? ?? '');
      await t.pumpWidget(const SizedBox.shrink());
    });

    _desktop('card designer block words', (t) async {
      final h = await _pump(t);
      final template = cardTemplateById('neon')!.design(CardKind.text);
      final n = h.container.read(composerProvider.notifier);
      n.setTextCardDesign(template.copyWith(blocks: [...template.blocks, const CardTextBlock(role: CardBlockRole.custom, text: 'Your words', anchor: CardAnchor.bottomLeft, color: 0xFFFFFFFF)]));
      await _settle(t);
      showCardDesignerSheet(h.context, kind: CardKind.text);
      await _settle(t);
      await t.ensureVisible(find.byKey(const Key('card-designer-group-text')));
      await _settle(t);
      await t.tap(find.byKey(const Key('card-designer-group-text')));
      await _settle(t);
      final index = template.blocks.length;
      await t.tap(find.byKey(Key('card-block-$index')));
      await _settle(t);
      await _exercise(t, find.byKey(Key('card-block-text-$index')), committed: () {
        final d = CardDesign.tryParse(h.container.read(composerProvider).textCardDesign)!;
        return d.blocks[index].text;
      });
      await t.pumpWidget(const SizedBox.shrink());
    });

    group('poll', () {
      Future<(_Harness, Future<PostPoll?>)> open(WidgetTester t, {PostPoll? initial}) async {
        final h = await _pump(t);
        final result = showPollEditor(
          h.context,
          initial: initial,
          rules: const PollRules(maxOptions: 4, optionMaxLength: 65, quizzes: true, quizOptionMaxLength: 80, quizExplanationMaxLength: 500),
          networks: 'Telegram',
          imageCount: 0,
        );
        await _settle(t);
        return (h, result);
      }

      _desktop('answer', (t) async {
        final (_, result) = await open(t, initial: const PostPoll(options: ['one', 'two']));
        final field = _fieldLabelled('Answer 1');
        await _exercise(t, field, committed: () => t.widget<TextField>(field).controller!.text);
        expect(find.text('8/65'), findsOneWidget, reason: 'onChanged ran: the counter moved');
        await t.tap(find.text('Done'));
        await _settle(t);
        expect((await result)!.options.first, 'hello $grin$grin');
        await t.pumpWidget(const SizedBox.shrink());
      });

      _desktop('explanation', (t) async {
        final (_, result) = await open(t, initial: const PostPoll(options: ['one', 'two'], kind: PollKind.quiz, correctIndex: 0));
        final field = _fieldLabelled('Explanation (optional, shown after answering)');
        await _exercise(t, field, committed: () => t.widget<TextField>(field).controller!.text);
        await t.tap(find.text('Done'));
        await _settle(t);
        expect((await result)!.explanation, 'hello $grin$grin');
        await t.pumpWidget(const SizedBox.shrink());
      });

      _desktop('an emoji past the limit stops Done rather than cutting it', (t) async {
        final (_, _) = await open(t, initial: PostPoll(options: ['x' * 65, 'two']));
        final field = _fieldLabelled('Answer 1');
        await t.tap(field);
        await t.pump();
        await t.tap(find.byKey(const Key('emoji-button')).last);
        await _settle(t);
        await t.tap(find.byKey(const ValueKey(grinId)));
        await _settle(t);
        await t.tap(find.byKey(const Key('emoji-close')));
        await _settle(t);
        expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Done')).onPressed, isNull);
        await t.pumpWidget(const SizedBox.shrink());
      });
    });

    _desktop('alt text', (t) async {
      final h = await _pump(t);
      const photo = MediaAttachment(id: 'p', path: 'mem://p.jpg', mimeType: 'image/jpeg', sizeBytes: 9, width: 10, height: 10);
      final result = showAltTextDialog(h.context, photo);
      await _settle(t);
      final field = find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('e.g. A wooden'));
      await _exercise(t, field, committed: () => t.widget<TextField>(field).controller!.text);
      expect(find.text('8 / 1500'), findsOneWidget, reason: 'onChanged ran: the counter moved');
      await t.tap(find.text('Save'));
      await _settle(t);
      expect(await result, 'hello $grin$grin');
      await t.pumpWidget(const SizedBox.shrink());
    });

    group('track details', () {
      const track = MediaAttachment(id: 'snd', path: 'mem://snd.mp3', mimeType: AudioMimeTypes.mp3, sizeBytes: 9, fileName: 'track01.mp3', audioTags: AudioTags(title: 'Night Drive', comment: 'c', lyrics: 'l'));
      for (final (name, read) in <(String, String? Function(AudioTags))>[('title', (a) => a.title), ('comment', (a) => a.comment), ('lyrics', (a) => a.lyrics)]) {
        _desktop(name, (t) async {
          final h = await _pump(t);
          h.container.read(composerProvider.notifier).addMedia([track]);
          await _settle(t);
          showTrackDetailsEditor(h.context, mediaId: 'snd');
          await _settle(t);
          final field = find.byKey(ValueKey('track-$name'));
          await _exercise(t, field, committed: () => t.widget<TextField>(field).controller!.text);
          expect(find.textContaining('Edited'), findsWidgets, reason: 'onChanged ran');
          await t.tap(find.text('Save'));
          await _settle(t);
          expect(read(h.container.read(composerProvider).audioDetails['snd']!), 'hello $grin$grin');
          await t.pumpWidget(const SizedBox.shrink());
        });
      }

      _desktop('a number field is not one the sheet writes to', (t) async {
        final h = await _pump(t);
        h.container.read(composerProvider.notifier).addMedia([track]);
        await _settle(t);
        showTrackDetailsEditor(h.context, mediaId: 'snd');
        await _settle(t);
        for (final d in TrackDetail.values.where((d) => d.isNumber)) {
          expect(find.ancestor(of: find.byKey(ValueKey('track-${d.name}')), matching: find.byType(EmojiTargetField)), findsNothing, reason: d.name);
        }
        await t.pumpWidget(const SizedBox.shrink());
      });
    });
  });

  group('which field the button writes to', () {
    _desktop('no field focused yet: the main text, at the end', (t) async {
      final h = await _pump(t);
      h.container.read(composerProvider.notifier).setText('typed');
      await _settle(t);
      final main = t.widget<TextField>(find.byWidgetPredicate((w) => w is TextField && w.focusNode == h.mainFocus)).controller!;
      main.value = const TextEditingValue(text: 'typed');
      await t.tap(find.byKey(const Key('emoji-button')).last);
      await _settle(t);
      await t.tap(find.byKey(const ValueKey(grinId)));
      await _settle(t);
      expect(h.container.read(composerProvider).text, 'typed$grin');
      await t.pumpWidget(const SizedBox.shrink());
    });

    _desktop('a sheet writes to its own field, not to the post behind it', (t) async {
      final h = await _pump(t);
      h.container.read(composerProvider.notifier)
        ..selectAccounts(['acct-reddit'])
        ..setText('main');
      await _settle(t);
      showCustomizeSheet(h.context, h.container.read(composerPreviewsProvider).single);
      await _settle(t);
      await t.tap(find.byKey(const Key('emoji-button')).last);
      await _settle(t);
      await t.tap(find.byKey(const ValueKey(grinId)));
      await _settle(t);
      expect(h.container.read(composerProvider).text, 'main', reason: 'the post behind the sheet is untouched');
      final field = _fieldLabelled('Text');
      expect(t.widget<TextField>(field).controller!.text, contains(grin));
      await t.pumpWidget(const SizedBox.shrink());
    });

    _desktop('Escape and a tap outside close the panel', (t) async {
      final h = await _pump(t);
      expect(h.context.mounted, isTrue);
      await t.tap(find.byKey(const Key('emoji-button')).last);
      await _settle(t);
      expect(find.byKey(const Key('emoji-panel')), findsOneWidget);
      await t.tapAt(const Offset(1390, 1090));
      await _settle(t);
      expect(find.byKey(const Key('emoji-panel')), findsNothing);
      await t.tap(find.byKey(const Key('emoji-button')).last);
      await _settle(t);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(t);
      expect(find.byKey(const Key('emoji-panel')), findsNothing, reason: 'Escape');
      await t.tap(find.byKey(const Key('emoji-button')).last);
      await _settle(t);
      expect(find.byKey(const Key('emoji-panel')), findsOneWidget);
      await t.tap(find.byKey(const Key('emoji-button')).last);
      await _settle(t);
      expect(find.byKey(const Key('emoji-panel')), findsNothing, reason: 'the button closes it too');
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  group('on a phone', () {
    testWidgets('the button opens a sheet; picks go in; closing brings the cursor back', (t) async {
      final h = await _pump(t, size: const Size(360, 640));
      expect(defaultTargetPlatform, TargetPlatform.android);
      final field = find.byWidgetPredicate((w) => w is TextField && w.focusNode == h.mainFocus);
      await t.tap(field);
      await t.pump();
      await t.tap(find.byKey(const Key('emoji-button')).last);
      await _settle(t);
      expect(find.byKey(const Key('emoji-panel')), findsNothing, reason: 'not the floating panel');
      expect(find.byKey(const Key('emoji-search')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey(grinId)));
      await _settle(t);
      await t.tap(find.byKey(const ValueKey(grinId)));
      await _settle(t);
      expect(h.container.read(composerProvider).text, '$grin$grin');
      expect(find.byKey(const Key('emoji-search')), findsOneWidget, reason: 'stays open across picks');
      await t.tap(find.byKey(const Key('emoji-close')));
      await _settle(t);
      expect(find.byKey(const Key('emoji-search')), findsNothing);
      expect(h.mainFocus.hasFocus, isTrue);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });
}
