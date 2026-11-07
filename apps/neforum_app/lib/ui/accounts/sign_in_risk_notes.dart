import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../../state/account_connection.dart';
import '../../state/providers.dart';
import '../../state/sign_in_risks.dart';
import '../../state/sign_in_view.dart';
import '../../theme/tokens.dart';
import '../router.dart';

/// The risks of a saved post as of now.
List<SignInRisk> watchPostSignInRisks(WidgetRef ref, Post post) {
  ref.watch(signInMinuteProvider);
  return signInRisksOfPost(
    post,
    accounts: ref.watch(accountListProvider),
    statuses: ref.watch(signInStatusesProvider).value ?? const {},
    registry: ref.watch(registryProvider),
    now: ref.watch(signInClockProvider)(),
  );
}

/// Each network a post may miss, in words, with the way to fix it.
class SignInRiskNotes extends StatelessWidget {
  const SignInRiskNotes(this.risks, {super.key, this.showButton = true});
  final List<SignInRisk> risks;
  final bool showButton;

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    return Container(
      key: const ValueKey('sign-in-risks'),
      padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.sm, Space.sm),
      decoration: BoxDecoration(color: risks.any((r) => r.mayMiss) ? nf.warningSoft : nf.surfaceSunken, borderRadius: Radii.rSm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final r in risks)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.xs),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(r.mayMiss ? Icons.warning_amber_rounded : Icons.cloud_done_outlined, size: 16, color: r.mayMiss ? nf.warning : nf.textMuted),
              ),
              const SizedBox(width: Space.sm),
              Expanded(child: Text(r.text, style: context.text.bodySmall?.copyWith(color: nf.text))),
            ]),
          ),
        if (showButton)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => context.go(kSignInsPath),
              style: TextButton.styleFrom(foregroundColor: nf.text),
              child: const Text('Open sign-ins'),
            ),
          ),
      ]),
    );
  }
}

/// The composer's warning above its action bar. While typing on a phone the bar
/// gives its room back to the text; the question at Schedule still comes.
class ComposerSignInWarning extends ConsumerWidget {
  const ComposerSignInWarning({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final risks = ref.watch(composerSignInRisksProvider);
    if (risks.isEmpty) return const SizedBox.shrink();
    final nf = context.nf;
    final missing = risks.any((r) => r.mayMiss);
    return Material(
      key: const ValueKey('composer-sign-in-warning'),
      color: missing ? nf.warningSoft : nf.surfaceSunken,
      child: InkWell(
        onTap: () => context.go(kSignInsPath),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
          child: Row(children: [
            Icon(missing ? Icons.warning_amber_rounded : Icons.cloud_done_outlined, size: 16, color: missing ? nf.warning : nf.textMuted),
            const SizedBox(width: Space.sm),
            Expanded(
              child: Text(
                risks.length == 1 ? risks.single.text : '${risks.length} networks have a sign-in problem with this post. Tap to see them.',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: context.text.bodySmall?.copyWith(color: nf.text),
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: nf.textMuted),
          ]),
        ),
      ),
    );
  }
}

/// The question before a post is scheduled that may miss a network: nothing is
/// missed without the person having been told. True to go ahead.
Future<bool> confirmSignInRisks(BuildContext context, List<SignInRisk> risks) async {
  final missing = risks.where((r) => r.mayMiss).toList();
  if (missing.isEmpty) return true;
  final go = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(missing.length == 1 ? '${missing.single.network} may miss this post' : '${missing.length} networks may miss this post'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final r in missing) Padding(padding: const EdgeInsets.only(bottom: Space.sm), child: Text(r.text)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Go back')),
        FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Schedule anyway')),
      ],
    ),
  );
  return go ?? false;
}
