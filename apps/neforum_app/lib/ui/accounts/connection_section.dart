import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/account_connection.dart';
import '../../state/cloud_sync.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/badges.dart';
import '../../widgets/layout.dart';
import '../activity/time_format.dart';

/// "24 Oct 2026, 14:05" on the user's 12- or 24-hour clock: how the
/// Connection section (and the setup it copies) writes a moment.
String connectionWhen(DateTime t, TimeFormatting f) => '${DateFormat('d MMM y').format(t.toLocal())}, ${f.clock(t)}';

/// [KeysTravel] on this device right now, from the sync settings and the
/// last sync run.
KeysTravel currentKeysTravel(WidgetRef ref) =>
    keysTravelFor(settingsSyncOn: ref.read(settingsProvider).syncOn, phase: ref.read(servicesProvider).cloudSync.status.value.phase);

/// 1.3.5: the Connection section at the foot of an account card. Closed it
/// is one row; one tap opens how the account is set up: how it posts, its
/// server or instance, the user's own app, where posts go, when the sign-in
/// runs out, which keys this device holds and whether sync carries them, and
/// when it was connected. Everything can be selected, and "Copy setup" puts
/// it on the clipboard to compare with another device. Key values are never
/// read into it: see [AccountConnection].
///
/// The keychain is read only while the section is open, so a page of closed
/// cards costs nothing, and each opening shows the current sign-in.
class AccountConnectionSection extends StatefulWidget {
  const AccountConnectionSection({super.key, required this.account, required this.network});
  final ConnectedAccount account;

  /// The platform's name, for the screen-reader label.
  final String network;

  /// Tests only: sections start open, so a page of cards can be checked
  /// open in one frame instead of one tap and layout per card. Reset it in
  /// a tearDown.
  @visibleForTesting
  static bool debugStartOpen = false;

  @override
  State<AccountConnectionSection> createState() => _AccountConnectionSectionState();
}

/// What a screen reader says for the section's header: which account's
/// connection it opens, since every card has one.
String connectionSemanticsLabel(ConnectedAccount account, String network) =>
    'Connection for ${account.handle ?? account.displayName} on $network';

class _AccountConnectionSectionState extends State<AccountConnectionSection> {
  bool _open = AccountConnectionSection.debugStartOpen;

  void _toggle() => setState(() => _open = !_open);

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // One node with the account in its label; the row's own "Connection"
      // text is folded into it.
      Semantics(
        container: true,
        button: true,
        expanded: _open,
        label: connectionSemanticsLabel(widget.account, widget.network),
        onTap: _toggle,
        excludeSemantics: true,
        child: InkWell(
          onTap: _toggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm + 2, Space.md, Space.sm + 2),
            child: Row(children: [
              Icon(Icons.cable_rounded, size: 18, color: nf.textMuted),
              const SizedBox(width: Space.sm),
              Expanded(child: Text('Connection', style: context.text.bodyMedium)),
              Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 22, color: nf.textMuted),
            ]),
          ),
        ),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: _open ? _ConnectionDetails(account: widget.account) : const SizedBox(width: double.infinity),
      ),
    ]);
  }
}

class _ConnectionDetails extends ConsumerWidget {
  const _ConnectionDetails({required this.account});
  final ConnectedAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nf = context.nf;
    final async = ref.watch(accountConnectionProvider(account.id));
    final settings = ref.watch(settingsProvider);
    final status = ref.watch(servicesProvider).cloudSync.status;
    final time = TimeFormatting.of(context, ref);
    String when(DateTime t) => connectionWhen(t, time);

    final Widget body;
    final c = async.value;
    if (c != null) {
      body = ValueListenableBuilder<CloudSyncStatus>(
        valueListenable: status,
        builder: (context, st, _) => _DetailsBody(
          account: account,
          connection: c,
          travel: keysTravelFor(settingsSyncOn: settings.syncOn, phase: st.phase),
          when: when,
          deviceLabel: ref.read(connectionDeviceLabelProvider),
        ),
      );
    } else if (async.hasError) {
      // Never the error itself: it could quote what the keychain returned.
      body = Text("Could not read this account's keys on this device.", style: context.text.bodySmall?.copyWith(color: nf.danger));
    } else {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: Space.sm),
        child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    return Padding(padding: const EdgeInsets.fromLTRB(Space.lg, Space.xxs, Space.lg, Space.md), child: body);
  }
}

class _DetailsBody extends StatelessWidget {
  const _DetailsBody({required this.account, required this.connection, required this.travel, required this.when, required this.deviceLabel});
  final ConnectedAccount account;
  final AccountConnection connection;
  final KeysTravel travel;

  /// Writes a moment on this device's clock, for the screen only: the copied
  /// text uses UTC dates the same on every device.
  final String Function(DateTime) when;
  final String deviceLabel;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final c = connection;
    final value = context.text.bodySmall?.copyWith(color: nf.text, height: 1.35);
    final sign = c.signIn;

    Future<void> copy() async {
      final text = '${connectionCopyHeader(deviceLabel, DateTime.now())}\n\n${connectionSetupText(account, c, travel: travel)}';
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) showToast(context, 'Setup copied, without keys or passwords', icon: Icons.check_rounded);
    }

    return _Panel(
      children: [
        // One selection area, so a server address or client ID can be
        // selected and copied on its own, or several rows at once.
        SelectionArea(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _Row(label: 'Network', child: Text(c.network, style: value)),
            _Row(label: 'How it posts', child: Text(c.method, style: value)),
            for (final d in c.details)
              _Row(label: d.label, child: Text(d.value, style: d.withheld ? value?.copyWith(color: nf.textMuted, fontStyle: FontStyle.italic) : value)),
            if (sign != null)
              _Row(
                label: 'Sign-in',
                child: Text(
                  signInText(sign, when),
                  style: value?.copyWith(color: sign.needsReconnecting ? nf.danger : (sign.endsSoon ? nf.warning : null)),
                ),
              ),
            _Row(label: 'Keys on this device', child: _Keys(connection: c, travel: travel, style: value)),
            _Row(label: 'Connected', last: true, child: Text(when(c.connectedAt), style: value)),
          ]),
        ),
        const SizedBox(height: Space.md),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: copy,
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('Copy setup'),
          ),
        ),
      ],
    );
  }
}

/// The open section's sunken panel.
class _Panel extends StatelessWidget {
  const _Panel({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(color: nf.surfaceSunken, borderRadius: Radii.rSm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}

/// A label above its value, 1Password style: long labels and long addresses
/// both wrap instead of pushing each other off a phone-wide card.
class _Row extends StatelessWidget {
  const _Row({required this.label, required this.child, this.last = false});
  final String label;
  final Widget child;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : Space.sm + 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: context.text.labelSmall?.copyWith(color: context.nf.textMuted, letterSpacing: 0.2)),
        const SizedBox(height: 2),
        child,
      ]),
    );
  }
}

/// Which keys are stored ("Access token: stored"), whether sync carries
/// them, and the X and Tumblr caveat when it does not.
class _Keys extends StatelessWidget {
  const _Keys({required this.connection, required this.travel, required this.style});
  final AccountConnection connection;
  final KeysTravel travel;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final c = connection;
    final muted = style?.copyWith(color: nf.textMuted);
    if (c.storedKeys.isEmpty) {
      return Text(noStoredKeysText(c), style: c.keysMissing ? style?.copyWith(color: nf.warning) : style);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final k in c.storedKeys)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.key_rounded, size: 13, color: nf.textFaint)),
            const SizedBox(width: Space.xs + 2),
            Expanded(child: Text('$k: stored', style: style)),
          ]),
        ),
      const SizedBox(height: Space.xs),
      Wrap(spacing: Space.sm, runSpacing: Space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
        StatusPill(
          keysTravelLabel(travel),
          tone: switch (travel) {
            KeysTravel.synced => Tone.success,
            KeysTravel.syncNotWorking => Tone.warning,
            KeysTravel.thisDeviceOnly => Tone.neutral,
          },
          icon: switch (travel) {
            KeysTravel.synced => Icons.sync_rounded,
            KeysTravel.syncNotWorking => Icons.sync_problem_rounded,
            KeysTravel.thisDeviceOnly => Icons.devices_other_rounded,
          },
          dense: true,
        ),
      ]),
      const SizedBox(height: Space.xs),
      Text(keysTravelExplanation(travel), style: muted),
      if (c.keysRotate && travel != KeysTravel.synced) ...[
        const SizedBox(height: Space.xs),
        Text(
          '${c.network} can stay connected on only one device without Sync: the first device to renew the sign-in ends the other\'s.',
          style: style?.copyWith(color: nf.warning),
        ),
      ],
    ]);
  }
}
