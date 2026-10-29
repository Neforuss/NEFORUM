import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../brand/neforum_logo.dart';
import '../platform/desktop.dart';
import '../platform/env.dart';
import '../state/providers.dart';
import '../state/render_warnings.dart';
import '../state/services.dart';
import '../state/settings.dart';
import '../theme/app_theme.dart';
import '../theme/text_scale.dart';
import '../theme/tokens.dart';
import 'router.dart';
import 'ui_zoom.dart';

/// Owns the [AppServices] instance and rebuilds the whole provider tree when
/// the user enters or leaves the demo workspace.
class NeforumRoot extends StatefulWidget {
  const NeforumRoot({super.key, required this.initial});
  final AppServices initial;

  static NeforumRootState of(BuildContext context) => context.findAncestorStateOfType<NeforumRootState>()!;

  @override
  State<NeforumRoot> createState() => NeforumRootState();
}

class NeforumRootState extends State<NeforumRoot> {
  late AppServices _services = widget.initial;
  bool _switching = false;

  bool get demo => _services.demo;

  Future<void> setDemo(bool demo) async {
    if (demo == _services.demo || _switching) return;
    setState(() => _switching = true);
    final old = _services;
    final next = await AppServices.create(demo: demo, storage: old.storage);
    await old.storage.writeJson('mode.json', {'demo': demo});
    // Hand the browser extension's port over to the new workspace.
    await old.browserBridge.stop();
    unawaited(next.startBrowserBridge());
    unawaited(next.startCloudSync());
    setState(() {
      _services = next;
      _switching = false;
    });
    old.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      key: ValueKey(_services),
      overrides: [servicesProvider.overrideWithValue(_services)],
      child: _switching ? const _SwitchingSplash() : const NeforumApp(),
    );
  }
}

class NeforumApp extends ConsumerWidget {
  const NeforumApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final router = ref.watch(routerProvider);
    ref.listen(settingsProvider.select((s) => s.minimizeToTray), (_, next) => DesktopIntegration.instance.setCloseToTray(next));
    ThemeData theme(Brightness brightness, {bool highContrast = false}) => buildTheme(
          brightness,
          settings.accent,
          customAccent: settings.customAccentColor,
          corners: settings.cornerStyle,
          chrome: settings.navigationChrome,
          density: settings.interfaceDensity,
          highContrast: highContrast,
        );
    // Above MaterialApp there is no MediaQuery yet: the platform's own flag.
    final reduceMotion = WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;
    return MaterialApp.router(
      title: 'NEFORUM',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      // The system's high contrast setting (MediaQuery.highContrast).
      highContrastTheme: theme(Brightness.light, highContrast: true),
      highContrastDarkTheme: theme(Brightness.dark, highContrast: true),
      themeMode: settings.themeMode,
      themeAnimationDuration: reduceMotion ? Duration.zero : Motion.medium,
      routerConfig: router,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('en')],
      builder: (context, child) {
        final current = Theme.of(context);
        return Theme(
          // The system asks for less motion: pages appear without a
          // transition. Always a Theme here, so turning it on or off keeps
          // the pages' state.
          data: context.reduceMotion ? withReducedMotion(current) : current,
          child: UiZoom(
            enabled: Env.isDesktop,
            zoom: settings.uiZoom,
            onChanged: (z) => ref.read(settingsProvider.notifier).update((x) => x.copyWith(uiZoom: z)),
            // Phones and tablets: the text size from Settings > Appearance.
            child: TextScale(
              scale: Env.isMobile ? settings.mobileTextScale : 1,
              child: _RenderWarningBanner(child: child ?? const SizedBox.shrink()),
            ),
          ),
        );
      },
    );
  }
}

/// Shows [renderWarnings] (a text card or a caption on a photo left out
/// because it took too long) in a banner over whatever screen is open, until
/// it is dismissed. A banner, not a toast: the "Saved" toast that follows a
/// save would replace a toast at once. Warnings that come while it is up are
/// added to it.
class _RenderWarningBanner extends StatefulWidget {
  const _RenderWarningBanner({required this.child});
  final Widget child;

  @override
  State<_RenderWarningBanner> createState() => _RenderWarningBannerState();
}

class _RenderWarningBannerState extends State<_RenderWarningBanner> {
  late final StreamSubscription<String> _subscription;
  final List<String> _messages = [];

  @override
  void initState() {
    super.initState();
    _subscription = renderWarnings.listen(_show);
  }

  void _show(String message) {
    final messenger = mounted ? ScaffoldMessenger.maybeOf(context) : null;
    if (messenger == null) return;
    if (!_messages.contains(message)) _messages.add(message);
    messenger
      ..removeCurrentMaterialBanner()
      ..showMaterialBanner(MaterialBanner(
        leading: const Icon(Icons.warning_amber_rounded),
        content: Text(_messages.join('\n')),
        actions: [
          TextButton(
            onPressed: () {
              _messages.clear();
              messenger.hideCurrentMaterialBanner();
            },
            child: const Text('Dismiss'),
          ),
        ],
      ));
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _SwitchingSplash extends StatelessWidget {
  const _SwitchingSplash();

  @override
  Widget build(BuildContext context) {
    // Keeps the current corner style while the workspace switches.
    final corners = Radii.square ? CornerStyle.square : CornerStyle.rounded;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light, AccentChoice.neforum, corners: corners),
      darkTheme: buildTheme(Brightness.dark, AccentChoice.neforum, corners: corners),
      home: const Scaffold(body: Center(child: NeforumMark(size: 72, animate: true))),
    );
  }
}
