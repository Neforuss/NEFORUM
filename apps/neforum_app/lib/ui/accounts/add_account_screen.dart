import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/composer.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/account_avatar.dart';
import '../../widgets/badges.dart';
import '../../widgets/buttons.dart';
import '../../widgets/layout.dart';
import '../../widgets/surfaces.dart';
import '../compose/target_picker.dart';
import '../router.dart';
import 'connect_form.dart';
import 'platform_picker.dart';
import 'tier_picker.dart';

enum _Step { platform, tier, connect, done }

/// Platform › How to post › Connect.
class AddAccountScreen extends ConsumerStatefulWidget {
  const AddAccountScreen({super.key, this.initialPlatformId});
  final String? initialPlatformId;

  @override
  ConsumerState<AddAccountScreen> createState() => _AddAccountScreenState();
}

class _AddAccountScreenState extends ConsumerState<AddAccountScreen> {
  _Step _step = _Step.platform;
  String? _platform;
  PlatformTier? _tier;
  ConnectedAccount? _connected;
  bool _forward = true;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final id = widget.initialPlatformId;
    if (id != null && ref.read(registryProvider).byId(id) != null) _pickPlatform(id, animate: false);
  }

  void _go(_Step s, {bool forward = true}) {
    setState(() {
      _forward = forward;
      _step = s;
    });
    if (_scroll.hasClients) _scroll.animateTo(0, duration: Motion.medium, curve: Motion.standard);
  }

  void _pickPlatform(String id, {bool animate = true}) {
    final d = ref.read(registryProvider).descriptor(id)!;
    _platform = id;
    if (d.tiers.length == 1) {
      _tier = d.tiers.single;
      animate ? _go(_Step.connect) : _step = _Step.connect;
    } else {
      _tier = null;
      animate ? _go(_Step.tier) : _step = _Step.tier;
    }
  }

  void _back() {
    switch (_step) {
      case _Step.platform:
        context.go(AppSection.accounts.path);
      case _Step.tier:
        _go(_Step.platform, forward: false);
      case _Step.connect:
        final single = ref.read(registryProvider).descriptor(_platform!)!.tiers.length == 1;
        _go(single ? _Step.platform : _Step.tier, forward: false);
      case _Step.done:
        _go(_Step.platform, forward: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final d = _platform == null ? null : ref.watch(registryProvider).descriptor(_platform!);

    final Widget content = switch (_step) {
      _Step.platform => PlatformPicker(onPick: _pickPlatform),
      _Step.tier => TierPicker(
          descriptor: d!,
          onPick: (t) {
            _tier = t;
            _go(_Step.connect);
          },
        ),
      _Step.connect => ConnectForm(
          key: ValueKey('$_platform/$_tier'),
          platformId: _platform!,
          tier: _tier!,
          onConnected: (a) {
            _connected = a;
            _go(_Step.done);
          },
        ),
      _Step.done => _Success(
          account: _connected!,
          onAnother: () => _go(_Step.platform, forward: false),
          onAnotherHere: () => _pickPlatform(_connected!.platformId),
        ),
    };

    final title = switch (_step) {
      _Step.platform => 'Pick a platform',
      _Step.tier => 'How should NEFORUM post to ${d?.name}?',
      _Step.connect => '',
      _Step.done => '',
    };

    return PageBody(controller: _scroll, maxWidth: _step == _Step.platform ? 1100 : Breakpoints.readable, children: [
      Row(children: [
        IconButton(onPressed: _back, tooltip: 'Back', icon: const Icon(Icons.arrow_back_rounded)),
        const SizedBox(width: Space.sm),
        Expanded(child: _Stepper(step: _step)),
      ]),
      const SizedBox(height: Space.xl),
      if (title.isNotEmpty) ...[
        Text(title, style: context.isCompact ? context.text.headlineMedium : context.text.headlineLarge),
        if (_step == _Step.platform) ...[
          const SizedBox(height: Space.xs),
          Text('Every platform works: automatically through an API, or through hand-off when the API is closed to normal accounts.', style: context.text.bodyMedium?.copyWith(color: nf.textMuted)),
        ],
        const SizedBox(height: Space.xl),
      ],
      AnimatedSwitcher(
        duration: Motion.medium,
        switchInCurve: Motion.standard,
        switchOutCurve: Motion.standard,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween(begin: Offset(_forward ? 0.04 : -0.04, 0), end: Offset.zero).animate(anim),
            child: child,
          ),
        ),
        layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
        child: KeyedSubtree(key: ValueKey(_step), child: content),
      ),
    ]);
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.step});
  final _Step step;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    const labels = ['Platform', 'How to post', 'Connect'];
    final current = step.index.clamp(0, 2);
    return Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: Space.xs, children: [
      for (var i = 0; i < labels.length; i++) ...[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: Space.sm + 2, vertical: Space.xs),
          decoration: BoxDecoration(
            color: i == current && step != _Step.done ? nf.accentSoft : Colors.transparent,
            borderRadius: Radii.rPill,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (i < current || step == _Step.done)
              Icon(Icons.check_rounded, size: 14, color: nf.success)
            else
              Text('${i + 1}', style: context.text.labelSmall?.copyWith(color: i == current ? nf.accent : nf.textFaint)),
            const SizedBox(width: Space.xs + 2),
            Text(labels[i], style: context.text.labelMedium?.copyWith(color: i <= current ? nf.text : nf.textFaint)),
          ]),
        ),
        if (i < labels.length - 1) Icon(Icons.chevron_right_rounded, size: 16, color: nf.textFaint),
      ],
    ]);
  }
}

class _Success extends ConsumerWidget {
  const _Success({required this.account, required this.onAnother, required this.onAnotherHere});
  final ConnectedAccount account;

  /// Back to the platform gallery.
  final VoidCallback onAnother;

  /// Another account on the same platform.
  final VoidCallback onAnotherHere;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final d = ref.watch(registryProvider).descriptor(account.platformId);
    return NfCard(
      padding: const EdgeInsets.all(Space.x4),
      child: Column(children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.6, end: 1),
          duration: Motion.slow,
          curve: Motion.spring,
          builder: (context, v, child) => Transform.scale(scale: v, child: child),
          child: Stack(clipBehavior: Clip.none, children: [
            AccountAvatar(account, size: 84),
            Positioned(
              right: -6,
              top: -6,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(color: nf.success, shape: BoxShape.circle, border: Border.all(color: nf.surface, width: 3)),
                child: const Icon(Icons.check_rounded, size: 16, color: Colors.white),
              ),
            ),
          ]),
        ),
        const SizedBox(height: Space.xl),
        Text('${d?.name ?? 'Account'} is connected', textAlign: TextAlign.center, style: context.text.headlineMedium),
        const SizedBox(height: Space.xs),
        Text(account.handle ?? account.displayName, style: context.text.bodyMedium?.copyWith(color: nf.textFaint)),
        const SizedBox(height: Space.md),
        TierBadge(account.tier, dense: false),
        const SizedBox(height: Space.md),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Text(tierDescription(account.tier), textAlign: TextAlign.center, style: context.text.bodyMedium?.copyWith(color: nf.textMuted)),
        ),
        const SizedBox(height: Space.xxl),
        Wrap(alignment: WrapAlignment.center, spacing: Space.md, runSpacing: Space.md, children: [
          PrimaryAction(
            label: 'Write a post',
            icon: Icons.edit_rounded,
            onPressed: () {
              final c = ref.read(composerProvider);
              if (d?.isArtPlatform ?? false) {
                // Art sites only receive artwork.
                setArtworkMode(ref, on: true, accountId: account.id);
              } else if (!c.selected.contains(account.id)) {
                ref.read(composerProvider.notifier).toggleAccount(account.id);
              }
              context.go(AppSection.compose.path);
            },
          ),
          OutlinedButton.icon(onPressed: onAnother, icon: const Icon(Icons.add_rounded, size: 18), label: const Text('Add another')),
          TextButton.icon(
            onPressed: onAnotherHere,
            icon: const Icon(Icons.person_add_alt_outlined, size: 18),
            label: Text('Another ${d?.name ?? account.platformId} account'),
          ),
        ]),
      ]),
    );
  }
}
