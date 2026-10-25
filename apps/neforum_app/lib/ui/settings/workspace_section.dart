
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/env.dart';
import '../../state/providers.dart';
import '../root.dart';
import 'setting_row.dart';

class WorkspaceSettingsSection extends ConsumerWidget {
  const WorkspaceSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final demo = ref.watch(isDemoProvider);
    return SettingsSection(title: 'Workspace', icon: Icons.science_outlined, children: [
      SettingSwitch(
        title: 'Demo workspace',
        description: Env.isWeb
            ? 'The web preview is always a demo. Install NEFORUM to post for real.'
            : 'Sample accounts and posts to explore NEFORUM. Nothing is really posted. Your real accounts come back when you turn it off.',
        value: demo,
        onChanged: Env.isWeb ? null : (v) => NeforumRoot.of(context).setDemo(v),
      ),
    ]);
  }
}
