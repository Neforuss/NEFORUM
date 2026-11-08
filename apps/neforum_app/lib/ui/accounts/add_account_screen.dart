import 'package:flutter/foundation.dart';
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

/// One step of the flow, as its location says.
typedef _Place = ({_Step step, String? platform, PlatformTier? tier, String? accountId});

/// Platform › How to post › Connect.
///
/// Each step is a page of its own, so Back and Forward walk them: the step,
/// platform and tier are in the location's [query], and nothing else. What was
/// typed stays in [ConnectForm], which is gone once its step is left. The
/// location never carries a key or a token.
class AddAccountScreen extends ConsumerStatefulWidget {
  const AddAccountScreen({super.key, this.query = const {}});

  /// `step`, `platform`, `tier`, `account`; `platform` alone starts at the
  /// first step that platform still needs.
  final Map<String, String> query;

  @override
  ConsumerState<AddAccountScreen> createState() => _AddAccountScreenState();
}

class _AddAccountScreenState extends ConsumerState<AddAccountScreen> {
  ConnectedAccount? _connected;

  /// Connected while this section was hidden: the result waits here, without
  /// taking the user away from the page they went to.
  bool _doneInPlace = false;

  bool _forward = true;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  _Place _placeOf(Map<String, String> query) {
    const _Place start = (step: _Step.platform, platform: null, tier: null, accountId: null);
    if (query['step'] == 'done') {
      final id = query['account'];
      final known = id != null && (_connected?.id == id || ref.read(accountByIdProvider(id)) != null);
      return known ? (step: _Step.done, platform: null, tier: null, accountId: id) : start;
    }
    final platform = query['platform'];
    final d = platform == null ? null : ref.read(registryProvider).descriptor(platform);
    if (d == null) return start;
    var tier = PlatformTier.values.asNameMap()[query['tier']];
    if (d.tiers.length == 1) tier = d.tiers.single;
    if (tier == null || !d.tiers.contains(tier)) return (step: _Step.tier, platform: platform, tier: null, accountId: null);
    return (step: _Step.connect, platform: platform, tier: tier, accountId: null);
  }

  @override
  void didUpdateWidget(AddAccountScreen old) {
    super.didUpdateWidget(old);
    final before = _placeOf(old.query).step;
    final now = _placeOf(widget.query).step;
    if (before == now && mapEquals(old.query, widget.query)) return;
    _doneInPlace = false;
    _forward = now.index >= before.index;
    if (_scroll.hasClients) _scroll.animateTo(0, duration: Motion.medium, curve: Motion.standard);
  }

  static String _location(Map<String, String> query) => Uri(path: '${AppSection.accounts.path}/add', queryParameters: query.isEmpty ? null : query).toString();

  String get _platformStep => _location(const {});

  String _firstStepOf(String platform) {
    final d = ref.read(registryProvider).descriptor(platform)!;
    return d.tiers.length == 1
        ? _location({'step': 'connect', 'platform': platform, 'tier': d.tiers.single.name})
        : _location({'step': 'tier', 'platform': platform});
  }

  void _onConnected(ConnectedAccount account) {
    if (!mounted) return;
    _connected = account;
    if (!TickerMode.getValuesNotifier(context).value.enabled) {
      setState(() => _doneInPlace = true);
      return;
    }
    // The form was sent: Back goes to the step before it, not to it.
    ref.read(navHistoryProvider).replaceNext();
    context.go(_location({'step': 'done', 'account': account.id}));
  }

  void _back(_Place place) {
    final history = ref.read(navHistoryProvider);
    switch (place.step) {
      case _Step.platform:
        history.stepBackTo(AppSection.accounts.path);
      case _Step.tier:
      case _Step.done:
        history.stepBackTo(_platformStep);
      case _Step.connect:
        final single = ref.read(registryProvider).descriptor(place.platform!)!.tiers.length == 1;
        history.stepBackTo(single ? _platformStep : _firstStepOf(place.platform!));
    }
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final place = _placeOf(widget.query);
    final step = _doneInPlace && place.step == _Step.connect ? _Step.done : place.step;
    final d = place.platform == null ? null : ref.watch(registryProvider).descriptor(place.platform!);
    final account = step != _Step.done ? null : (place.accountId == null ? null : ref.watch(accountByIdProvider(place.accountId!))) ?? _connected;

    final Widget content = switch (step) {
      _Step.platform => PlatformPicker(onPick: (id) => context.go(_firstStepOf(id))),
      _Step.tier => TierPicker(
          descriptor: d!,
          onPick: (t) => context.go(_location({'step': 'connect', 'platform': place.platform!, 'tier': t.name})),
        ),
      _Step.connect => ConnectForm(
          key: ValueKey('${place.platform}/${place.tier}'),
          platformId: place.platform!,
          tier: place.tier!,
          onConnected: _onConnected,
        ),
      _Step.done => _Success(
          account: account!,
          onAnother: () => context.go(_platformStep),
          onAnotherHere: () => context.go(_firstStepOf(account.platformId)),
        ),
    };

    final title = switch (step) {
      _Step.platform => 'Pick a platform',
      _Step.tier => 'How should NEFORUM post to ${d?.name}?',
      _Step.connect => '',
      _Step.done => '',
    };

    return PageBody(controller: _scroll, maxWidth: step == _Step.platform ? 1100 : Breakpoints.readable, children: [
      Row(children: [
        IconButton(onPressed: () => _back(place), tooltip: 'Back', icon: const Icon(Icons.arrow_back_rounded)),
        const SizedBox(width: Space.sm),
        Expanded(child: _Stepper(step: step)),
      ]),
      const SizedBox(height: Space.xl),
      if (title.isNotEmpty) ...[
        Text(title, style: context.isCompact ? context.text.headlineMedium : context.text.headlineLarge),
        if (step == _Step.platform) ...[
          const SizedBox(height: Space.xs),
          Text('Every platform works: automatically through an API, or through hand-off when the API is closed to normal accounts.', style: context.text.bodyMedium?.copyWith(color: nf.textMuted)),
        ],
        const SizedBox(height: Space.xl),
      ],
      AnimatedSwitcher(
        duration: context.motion(Motion.medium),
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
        child: KeyedSubtree(key: ValueKey(step), child: content),
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
                decoration: BoxDecoration(color: nf.success, shape: Radii.circleShape, border: Border.all(color: nf.surface, width: 3)),
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
