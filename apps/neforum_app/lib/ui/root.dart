import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../brand/neforum_logo.dart';
import '../media/caption_fonts.dart' show CaptionFont, MissingFontOffer, missingFontOffers;
import '../platform/desktop.dart';
import '../platform/env.dart';
import '../state/providers.dart';
import '../state/render_warnings.dart';
import '../state/services.dart';
import '../state/settings.dart';
import '../theme/app_theme.dart';
import '../theme/text_scale.dart';
import '../theme/tokens.dart';
import 'compose/font_download_sheet.dart';
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
              child: RenderWarningBanner(child: child ?? const SizedBox.shrink()),
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
///
/// 1.4: a font missing here that the font list has ([missingFontOffers]) comes
/// with a button that fetches it.
class RenderWarningBanner extends ConsumerStatefulWidget {
  const RenderWarningBanner({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<RenderWarningBanner> createState() => _RenderWarningBannerState();
}

class _RenderWarningBannerState extends ConsumerState<RenderWarningBanner> {
  late final StreamSubscription<String> _subscription;
  late final StreamSubscription<MissingFontOffer> _fontOffers;
  final List<String> _messages = [];

  /// 1.4: fonts missing here that the font list has, each with its button.
  final List<MissingFontOffer> _offers = [];

  @override
  void initState() {
    super.initState();
    _subscription = renderWarnings.listen(_show);
    _fontOffers = missingFontOffers.listen(_offer);
  }

  void _show(String message) {
    if (!_messages.contains(message)) _messages.add(message);
    _present();
  }

  void _offer(MissingFontOffer offer) {
    _offers.add(offer);
    _present();
  }

  void _present() {
    final messenger = mounted ? ScaffoldMessenger.maybeOf(context) : null;
    if (messenger == null) return;
    final offering = [for (final o in _offers) if (canOfferFontDownload(ref, o.font)) o];
    final lines = [
      ..._messages,
      for (final o in _offers)
        offering.contains(o)
            ? 'The font ${o.font.family} is not on this device, so ${o.usage} uses the default font.'
            : 'The font ${o.font.family} is not on this device, so ${o.usage} uses the default font. Install or import ${o.font.family} here to use it.',
    ];
    final seen = <String>{};
    messenger
      ..removeCurrentMaterialBanner()
      ..showMaterialBanner(MaterialBanner(
        leading: const Icon(Icons.warning_amber_rounded),
        content: Text(lines.join('\n')),
        actions: [
          for (final o in offering)
            if (seen.add(o.font.family))
              // Its own context: this one is under the Navigator, for the question.
              Builder(
                builder: (buttonContext) => TextButton(
                  key: Key('font-offer-${o.font.source!.id}'),
                  onPressed: () => _download(buttonContext, o.font),
                  child: Text(fontDownloadLabel(o.font)),
                ),
              ),
          TextButton(
            onPressed: () {
              _messages.clear();
              _offers.clear();
              messenger.hideCurrentMaterialBanner();
            },
            child: const Text('Dismiss'),
          ),
        ],
      ));
  }

  Future<void> _download(BuildContext buttonContext, CaptionFont font) async {
    final source = font.source;
    if (source == null) return;
    final done = await downloadFontWithPrompts(buttonContext, ref, id: source.id, family: font.family);
    if (done == null || !mounted) return;
    _offers.removeWhere((o) => o.font.source?.id == source.id);
    if (_messages.isEmpty && _offers.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.hideCurrentMaterialBanner();
    } else {
      _present();
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    _fontOffers.cancel();
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
