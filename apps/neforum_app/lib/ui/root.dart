import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../brand/neforum_logo.dart';
import '../platform/desktop.dart';
import '../state/providers.dart';
import '../state/services.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'router.dart';

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
    return MaterialApp.router(
      title: 'NEFORUM',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light, settings.accent),
      darkTheme: buildTheme(Brightness.dark, settings.accent),
      themeMode: settings.themeMode,
      themeAnimationDuration: Motion.medium,
      routerConfig: router,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('en')],
    );
  }
}

class _SwitchingSplash extends StatelessWidget {
  const _SwitchingSplash();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light, AccentChoice.neforum),
      darkTheme: buildTheme(Brightness.dark, AccentChoice.neforum),
      home: const Scaffold(body: Center(child: NeforumMark(size: 72, animate: true))),
    );
  }
}
