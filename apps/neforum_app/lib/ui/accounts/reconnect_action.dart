import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/providers.dart';
import '../../widgets/layout.dart';
import '../router.dart';

// 1.4.3: one-tap Reconnect, on the account card, the sign-ins page and a
// refused post. The stored keys first, then the platform's own sign-in page
// with the app keys already saved ([AccountReconnector]); the connect form
// only when something has to be typed again.

/// The accounts with a Reconnect under way, so each button shows it and a
/// second tap does not open a second browser sign-in.
class ReconnectingNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  /// False when [accountId] is already reconnecting.
  bool start(String accountId) {
    if (state.contains(accountId)) return false;
    state = {...state, accountId};
    return true;
  }

  void finish(String accountId) {
    if (ref.mounted) state = {...state}..remove(accountId);
  }
}

final reconnectingProvider = NotifierProvider<ReconnectingNotifier, Set<String>>(ReconnectingNotifier.new);

/// The connect form for [account]'s platform and way of posting.
String reconnectFormLocation(ConnectedAccount account, {bool withTier = true}) => Uri(
      path: '${AppSection.accounts.path}/add',
      queryParameters: {'platform': account.platformId, if (withTier) 'tier': account.tier.name},
    ).toString();

/// What the toast says after a Reconnect of [network], with no key or token in
/// it: [ReconnectOutcome.message] is written by NEFORUM or quotes the
/// platform's refusal of the form's answers, never a stored key.
String reconnectWords(String network, ReconnectOutcome out) => switch (out.result) {
      ReconnectResult.renewed => '$network reconnected with the keys it already had.',
      ReconnectResult.reconnected => '$network reconnected.',
      ReconnectResult.needsForm => out.message == null ? 'Enter the $network keys again to reconnect it.' : '${out.message}',
      ReconnectResult.cancelled => 'Sign-in cancelled. Nothing changed.',
      ReconnectResult.otherAccount || ReconnectResult.unreachable || ReconnectResult.failed => out.message ?? 'Could not reconnect $network. Nothing changed.',
    };

/// Reconnects [account] with one tap and says how it went. True when its
/// sign-in works again. Opens the connect form when only the person can give
/// what is missing (new keys, a pasted token).
Future<bool> reconnectAccount(BuildContext context, WidgetRef ref, ConnectedAccount account) async {
  final s = ref.read(servicesProvider);
  final network = s.registry.descriptor(account.platformId)?.name ?? account.platformId;
  // The demo's accounts have no keys: its Reconnect shows the connect flow.
  if (s.demo) {
    context.go(reconnectFormLocation(account, withTier: false));
    return false;
  }
  final busy = ref.read(reconnectingProvider.notifier);
  if (!busy.start(account.id)) return false;
  final ReconnectOutcome out;
  try {
    out = await s.reconnector().reconnect(account.id, s.connectContext());
  } finally {
    busy.finish(account.id);
  }
  if (!context.mounted) return out.worked;
  final words = reconnectWords(network, out);
  switch (out.result) {
    case ReconnectResult.renewed || ReconnectResult.reconnected:
      showToast(context, words, icon: Icons.check_rounded);
    case ReconnectResult.needsForm:
      showToast(context, words, icon: Icons.edit_note_rounded);
      context.go(reconnectFormLocation(account));
    case ReconnectResult.cancelled:
      showToast(context, words, icon: Icons.info_outline_rounded);
    case ReconnectResult.unreachable:
      showToast(context, words, icon: Icons.cloud_off_rounded);
    case ReconnectResult.otherAccount || ReconnectResult.failed:
      showToast(
        context,
        words,
        icon: Icons.error_outline_rounded,
        actionLabel: 'Use the form',
        onAction: () {
          if (context.mounted) context.go(reconnectFormLocation(account));
        },
      );
  }
  return out.worked;
}
