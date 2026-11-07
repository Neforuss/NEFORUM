// Back and Forward on the real app: the sidebar and rail buttons, the keyboard
// (and that a text field keeps its own shortcuts), the add-account steps as
// pages, a demo switch starting a new history, phones left alone.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/accounts/add_account_screen.dart';
import 'package:neforum_app/ui/accounts/connect_form.dart';
import 'package:neforum_app/ui/compose/rich_text.dart';
import 'package:neforum_app/ui/root.dart' show NeforumApp;
import 'package:neforum_app/ui/router.dart';
import 'package:neforum_app/widgets/buttons.dart';
import 'package:neforum_core/neforum_core.dart' show PlatformTier;

class _MemoryStorage implements AppStorage {
  final Map<String, Object> _json = {};
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

Future<ProviderContainer> _start(WidgetTester tester, {Size size = const Size(1440, 900)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final services = await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage()));
  await tester.pumpWidget(ProviderScope(
    overrides: [servicesProvider.overrideWithValue(services!)],
    child: const NeforumApp(),
  ));
  await tester.pump(const Duration(milliseconds: 300));
  final c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
  return c;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

String _location(ProviderContainer c) => c.read(routerProvider).routerDelegate.currentConfiguration.uri.toString();

Future<void> _go(WidgetTester tester, ProviderContainer c, String location) async {
  c.read(routerProvider).go(location);
  await _settle(tester);
}

Future<void> _keys(WidgetTester tester, LogicalKeyboardKey modifier, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(modifier);
  await _settle(tester);
}

Finder get _editor => find.byWidgetPredicate((w) => w is TextField && w.controller is HighlightController).first;

Finder _chromeButton(String label) => find.byWidgetPredicate((w) => w is Semantics && w.properties.label == label && w.properties.button == true);

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
    }
    await loader.load();
  }

  await family('Inter', ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-Medium.ttf', 'assets/fonts/Inter-SemiBold.ttf', 'assets/fonts/Inter-Bold.ttf']);
  await family('Bricolage', ['assets/fonts/BricolageGrotesque-SemiBold.ttf', 'assets/fonts/BricolageGrotesque-Bold.ttf', 'assets/fonts/BricolageGrotesque-ExtraBold.ttf']);
  await family('JetBrainsMono', ['assets/fonts/JetBrainsMono-Regular.ttf']);
}

void main() {
  setUpAll(_loadFonts);

  group('buttons', () {
    for (final (name, size) in [('sidebar', const Size(1440, 900)), ('rail', const Size(900, 700))]) {
      testWidgets('on the $name: dimmed at the ends, and they walk', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
        final c = await _start(tester, size: size);
        SemanticsProperties props(String label) => tester.widget<Semantics>(_chromeButton(label)).properties;

        expect(props('Back').enabled, isFalse);
        expect(props('Forward').enabled, isFalse);
        await tester.tap(_chromeButton('Back'), warnIfMissed: false);
        await _settle(tester);
        expect(_location(c), '/compose');

        await _go(tester, c, '/queue');
        expect(props('Back').enabled, isTrue);
        await tester.tap(_chromeButton('Back'));
        await _settle(tester);
        expect(_location(c), '/compose');
        expect(props('Back').enabled, isFalse);
        expect(props('Forward').enabled, isTrue);

        await tester.tap(_chromeButton('Forward'));
        await _settle(tester);
        expect(_location(c), '/queue');
        expect(props('Forward').enabled, isFalse);
      });
    }

    testWidgets('a short window: the rail scrolls its sections, with no overflow', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = previous);
      final c = await _start(tester, size: const Size(760, 430));
      await _go(tester, c, '/queue');
      FlutterError.onError = previous;
      expect(errors, isEmpty);
      expect(_chromeButton('Back'), findsOneWidget);
    });

    testWidgets('the tooltip names the keys', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
      await _start(tester);
      expect(find.byTooltip('Back (Alt+Left)'), findsOneWidget);
      expect(find.byTooltip('Forward (Alt+Right)'), findsOneWidget);
    });

    testWidgets('a section tapped in the sidebar is a page', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
      final c = await _start(tester);
      await tester.tap(find.text('Queue').first);
      await _settle(tester);
      await tester.tap(find.text('Settings').first);
      await _settle(tester);
      expect(c.read(navHistoryProvider).entries, ['/compose', '/queue', '/settings']);
    });

    testWidgets('the post page\'s own arrow is Back, so Forward returns to the post', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
      final c = await _start(tester);
      await _go(tester, c, '/activity');
      await _go(tester, c, '/activity/post/demo-post-2');
      await tester.tap(find.widgetWithText(TextButton, 'Activity'));
      await _settle(tester);
      expect(_location(c), '/activity');
      expect(c.read(navHistoryProvider).canForward, isTrue);
      await _keys(tester, LogicalKeyboardKey.altLeft, LogicalKeyboardKey.arrowRight);
      expect(_location(c), '/activity/post/demo-post-2');
    });

    testWidgets('a deleted post\'s page keeps its message and its way out', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
      final c = await _start(tester);
      await _go(tester, c, '/activity/post/gone');
      expect(find.text('This post is no longer in NEFORUM'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Activity'));
      await _settle(tester);
      expect(_location(c), '/activity');
    });
  });

  group('keyboard', () {
    testWidgets('Alt+Left and Alt+Right on Windows and Linux', variant: const TargetPlatformVariant({TargetPlatform.windows, TargetPlatform.linux}), (tester) async {
      final c = await _start(tester);
      await _go(tester, c, '/queue');
      await _keys(tester, LogicalKeyboardKey.altLeft, LogicalKeyboardKey.arrowLeft);
      expect(_location(c), '/compose');
      await _keys(tester, LogicalKeyboardKey.altRight, LogicalKeyboardKey.arrowRight);
      expect(_location(c), '/queue');
    });

    testWidgets('Cmd+[ and Cmd+] on macOS, and Alt+Left does nothing there', variant: TargetPlatformVariant.only(TargetPlatform.macOS), (tester) async {
      final c = await _start(tester);
      await _go(tester, c, '/queue');
      await _keys(tester, LogicalKeyboardKey.altLeft, LogicalKeyboardKey.arrowLeft);
      expect(_location(c), '/queue');
      await _keys(tester, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.bracketLeft);
      expect(_location(c), '/compose');
      await _keys(tester, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.bracketRight);
      expect(_location(c), '/queue');
      expect(find.byTooltip('Back (⌘[)'), findsOneWidget);
    });

    testWidgets('a keyboard\'s own Back and Forward keys', variant: TargetPlatformVariant.only(TargetPlatform.linux), (tester) async {
      final c = await _start(tester);
      await _go(tester, c, '/queue');
      // flutter_test's key tables have no code for these keys.
      void press(PhysicalKeyboardKey physical, LogicalKeyboardKey logical) {
        HardwareKeyboard.instance.handleKeyEvent(KeyDownEvent(physicalKey: physical, logicalKey: logical, timeStamp: Duration.zero));
        HardwareKeyboard.instance.handleKeyEvent(KeyUpEvent(physicalKey: physical, logicalKey: logical, timeStamp: Duration.zero));
      }

      press(PhysicalKeyboardKey.browserBack, LogicalKeyboardKey.browserBack);
      await _settle(tester);
      expect(_location(c), '/compose');
      press(PhysicalKeyboardKey.browserForward, LogicalKeyboardKey.browserForward);
      await _settle(tester);
      expect(_location(c), '/queue');
    });

    testWidgets('holding Shift or Ctrl as well is another shortcut', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
      final c = await _start(tester);
      await _go(tester, c, '/queue');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await _keys(tester, LogicalKeyboardKey.altLeft, LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(_location(c), '/queue');
    });

    testWidgets('in a text field Alt+Left stays the field\'s: the page stays and the caret moves', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
      final c = await _start(tester);
      await _go(tester, c, '/queue');
      await _go(tester, c, '/compose');
      await tester.tap(_editor);
      await _settle(tester);
      await tester.enterText(_editor, 'hello world');
      await _settle(tester);
      final field = tester.widget<TextField>(_editor);
      field.controller!.selection = const TextSelection.collapsed(offset: 11);
      await tester.pump();

      await _keys(tester, LogicalKeyboardKey.altLeft, LogicalKeyboardKey.arrowLeft);

      expect(_location(c), '/compose', reason: 'the shortcut was not stolen from the text field');
      expect(field.controller!.selection.baseOffset, 0, reason: 'Alt+Left moved the caret to the line start, as Flutter does on Windows');
      expect(c.read(composerProvider).text, 'hello world');
    });

    testWidgets('out of the text field the same keys walk again', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
      final c = await _start(tester);
      await _go(tester, c, '/queue');
      await _go(tester, c, '/compose');
      await tester.tap(_editor);
      await _settle(tester);
      FocusManager.instance.primaryFocus!.unfocus();
      await _settle(tester);
      await _keys(tester, LogicalKeyboardKey.altLeft, LogicalKeyboardKey.arrowLeft);
      expect(_location(c), '/queue');
    });

    testWidgets('Alt+Left closes a dialog first, as the side button does', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
      final c = await _start(tester);
      await _go(tester, c, '/queue');
      showDialog<void>(context: rootNavigatorKey.currentContext!, builder: (_) => const AlertDialog(content: Text('open')));
      await _settle(tester);
      await _keys(tester, LogicalKeyboardKey.altLeft, LogicalKeyboardKey.arrowLeft);
      expect(find.text('open'), findsNothing);
      expect(_location(c), '/queue');
    });
  });

  group('add account steps are pages', () {
    testWidgets('a platform with choices: tier, connect, and back through them', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
      final c = await _start(tester);
      final d = c.read(registryProvider).descriptors.firstWhere((x) => x.tiers.length > 1);
      await _go(tester, c, '/accounts');
      await _go(tester, c, '/accounts/add');
      expect(find.text('Pick a platform'), findsOneWidget);
      await _go(tester, c, '/accounts/add?step=tier&platform=${d.id}');
      expect(find.text('How should NEFORUM post to ${d.name}?'), findsOneWidget);
      final tier = d.tiers.first;
      await _go(tester, c, '/accounts/add?step=connect&platform=${d.id}&tier=${tier.name}');
      expect(find.textContaining('How should NEFORUM'), findsNothing);

      // The side buttons: the platform step's search box has the keyboard.
      Future<void> side(int button) async {
        final g = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: button);
        await g.down(const Offset(900, 600));
        await g.up();
        await g.removePointer();
        await _settle(tester);
      }

      await side(kBackMouseButton);
      expect(find.text('How should NEFORUM post to ${d.name}?'), findsOneWidget);
      await side(kBackMouseButton);
      expect(find.text('Pick a platform'), findsOneWidget);
      await side(kBackMouseButton);
      expect(_location(c), '/accounts');
      await side(kForwardMouseButton);
      await side(kForwardMouseButton);
      expect(find.text('How should NEFORUM post to ${d.name}?'), findsOneWidget);
    });

    testWidgets('picking on screen moves the location, and the on-screen arrow is Back', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
      final c = await _start(tester);
      final d = c.read(registryProvider).descriptors.firstWhere((x) => x.tiers.length > 1);
      await _go(tester, c, '/accounts/add?platform=${d.id}');
      expect(find.text('How should NEFORUM post to ${d.name}?'), findsOneWidget, reason: 'platform alone starts at the first step it needs');
      await _go(tester, c, '/accounts/add');

      await tester.tap(find.descendant(of: find.byType(AddAccountScreen), matching: find.byTooltip('Back')));
      await _settle(tester);
      expect(find.text('How should NEFORUM post to ${d.name}?'), findsNothing);
      expect(_location(c), '/accounts');
    });

    testWidgets('nonsense in the location falls back, it never breaks the page', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
      final c = await _start(tester);
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = previous);
      final d = c.read(registryProvider).descriptors.firstWhere((x) => x.tiers.length > 1);
      for (final q in ['platform=nope', 'step=done', 'step=done&account=nope', 'step=connect', 'step=connect&platform=nope&tier=openApi', 'step=wat']) {
        await _go(tester, c, '/accounts/add?$q');
        expect(find.text('Pick a platform'), findsOneWidget, reason: q);
      }
      await _go(tester, c, '/accounts/add?step=connect&platform=${d.id}&tier=wat');
      expect(find.text('How should NEFORUM post to ${d.name}?'), findsOneWidget);
      FlutterError.onError = previous;
      expect(errors, isEmpty);
    });

    testWidgets('the done step stands in for the form it replaced', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
      final c = await _start(tester);
      final history = c.read(navHistoryProvider);
      final account = c.read(accountListProvider).first;
      await _go(tester, c, '/accounts');
      await _go(tester, c, '/accounts/add?platform=${account.platformId}');
      final d = c.read(registryProvider).descriptor(account.platformId)!;
      final tier = d.tiers.first;
      await _go(tester, c, '/accounts/add?step=connect&platform=${d.id}&tier=${tier.name}');
      final before = history.entries.length;

      // What _onConnected does.
      history.replaceNext();
      await _go(tester, c, '/accounts/add?step=done&account=${account.id}');
      expect(find.textContaining('is connected'), findsOneWidget);
      expect(history.entries.length, before, reason: 'done took the place of the form');

      await _keys(tester, LogicalKeyboardKey.altLeft, LogicalKeyboardKey.arrowLeft);
      expect(find.textContaining('is connected'), findsNothing);
      expect(_location(c), isNot(contains('step=connect')), reason: 'Back never returns to a form already sent');
    });

    Future<void> fillAndConnect(WidgetTester tester) async {
      final fields = find.descendant(of: find.byType(AddAccountScreen), matching: find.byType(TextFormField));
      for (var i = 0; i < fields.evaluate().length; i++) {
        await tester.enterText(fields.at(i), 'value$i');
      }
      await tester.pump();
      await tester.tap(find.descendant(of: find.byType(ConnectForm), matching: find.byType(PrimaryAction)));
      await tester.pump();
    }

    testWidgets('a real connect: the success page replaces the form in the history', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
      final c = await _start(tester);
      final history = c.read(navHistoryProvider);
      await _go(tester, c, '/accounts');
      await _go(tester, c, '/accounts/add');
      await _go(tester, c, '/accounts/add?step=tier&platform=bluesky');
      await _go(tester, c, '/accounts/add?step=connect&platform=bluesky&tier=openApi');
      final entries = history.entries.length;

      await fillAndConnect(tester);
      await tester.pump(const Duration(seconds: 1));
      await _settle(tester);

      expect(find.textContaining('is connected'), findsOneWidget);
      expect(_location(c), startsWith('/accounts/add?step=done&account='));
      expect(history.entries.length, entries);
      expect(history.entries.where((e) => e.contains('step=connect')), isEmpty);
      expect(history.entries.join(' '), isNot(contains('value')), reason: 'nothing typed reaches the history');

      final g = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kBackMouseButton);
      await g.down(const Offset(900, 600));
      await g.up();
      await g.removePointer();
      await _settle(tester);
      expect(_location(c), '/accounts/add?step=tier&platform=bluesky');
      expect(find.textContaining('is connected'), findsNothing);
    });

    testWidgets('connected while another section is open: no jump, the result waits', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
      final c = await _start(tester);
      await _go(tester, c, '/accounts/add?step=connect&platform=bluesky&tier=openApi');
      await fillAndConnect(tester);
      c.read(routerProvider).go('/queue');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await _settle(tester);
      expect(_location(c), '/queue', reason: 'the sign-in finishing never takes the user away');

      await _go(tester, c, '/accounts/add?step=connect&platform=bluesky&tier=openApi');
      expect(find.textContaining('is connected'), findsOneWidget);
    });

    testWidgets('no key or token can be in the location: only these names are read', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
      final c = await _start(tester);
      final d = c.read(registryProvider).descriptors.firstWhere((x) => x.tiers.contains(PlatformTier.byokApi));
      await _go(tester, c, '/accounts/add?step=connect&platform=${d.id}&tier=byokApi');
      final fields = find.descendant(of: find.byType(AddAccountScreen), matching: find.byType(TextField));
      if (fields.evaluate().isNotEmpty) {
        await tester.enterText(fields.first, 'typed-secret-value');
        await _settle(tester);
      }
      for (final entry in c.read(navHistoryProvider).entries) {
        expect(entry, isNot(contains('typed-secret-value')));
      }
      expect(Uri.parse(_location(c)).queryParameters.keys.toSet().difference({'step', 'platform', 'tier', 'account'}), isEmpty);
    });
  });

  testWidgets('a new workspace starts a new history', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
    // As NeforumRootState does: a ProviderScope keyed by the services.
    Widget workspace(AppServices services) => ProviderScope(
          key: ValueKey(services),
          overrides: [servicesProvider.overrideWithValue(services)],
          child: const NeforumApp(),
        );
    final first = await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage()));
    final second = await tester.runAsync(() => AppServices.create(demo: true, storage: _MemoryStorage()));
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(workspace(first!));
    await tester.pump(const Duration(milliseconds: 300));
    ProviderContainer container() => ProviderScope.containerOf(tester.element(find.byType(MaterialApp).first));
    final old = container().read(navHistoryProvider);
    container().read(routerProvider).go('/queue');
    await _settle(tester);
    expect(old.entries.length, 2);

    await tester.pumpWidget(workspace(second!));
    await tester.pump(const Duration(milliseconds: 300));
    final fresh = container().read(navHistoryProvider);
    expect(identical(fresh, old), isFalse);
    expect(fresh.entries, ['/compose']);
    expect(fresh.canBack, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  group('phones keep system Back', () {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      testWidgets('${platform.name}: side buttons and Alt+Left do nothing, no buttons on the tab bar', variant: TargetPlatformVariant.only(platform), (tester) async {
        final c = await _start(tester, size: const Size(360, 740));
        await _go(tester, c, '/queue');
        final g = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kBackMouseButton);
        await g.down(const Offset(180, 300));
        await g.up();
        await g.removePointer();
        await _settle(tester);
        expect(_location(c), '/queue');
        await _keys(tester, LogicalKeyboardKey.altLeft, LogicalKeyboardKey.arrowLeft);
        expect(_location(c), '/queue');
        expect(_chromeButton('Back'), findsNothing);
      });
    }
  });
}
