
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../brand/neforum_logo.dart';
import '../../platform/env.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../accounts/guide_sheet.dart';
import 'setting_row.dart';

class AboutSettingsSection extends StatelessWidget {
  const AboutSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    Future<void> open(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    return SettingsSection(title: 'About', icon: Icons.info_outline_rounded, children: [
      Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const NeforumWordmark(size: 40, showTagline: true),
          const SizedBox(height: Space.lg),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snap) => Text(
              'Version ${snap.data?.version ?? kAppVersion} · ${Env.platformName}',
              style: monoStyle(context, size: 12.5),
            ),
          ),
          const SizedBox(height: Space.sm),
          Text('Free and open-source software under the GNU General Public License v3.', style: context.text.bodyMedium?.copyWith(color: nf.textMuted)),
          const SizedBox(height: Space.lg),
          Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
            OutlinedButton.icon(onPressed: () => open('https://github.com/Neforuss/NEFORUM'), icon: const Icon(Icons.code_rounded, size: 18), label: const Text('Source code')),
            OutlinedButton.icon(onPressed: () => showGuideSheet(context, 'platforms', asset: 'platforms.md'), icon: const Icon(Icons.table_chart_outlined, size: 18), label: const Text('Platform guide')),
            OutlinedButton.icon(onPressed: () => open('https://github.com/Neforuss/NEFORUM/issues'), icon: const Icon(Icons.bug_report_outlined, size: 18), label: const Text('Report a problem')),
            OutlinedButton.icon(onPressed: () => open(kTermsUrl), icon: const Icon(Icons.gavel_rounded, size: 18), label: const Text('Terms of service')),
            OutlinedButton.icon(onPressed: () => open(kPrivacyUrl), icon: const Icon(Icons.privacy_tip_outlined, size: 18), label: const Text('Privacy policy')),
          ]),
          const SizedBox(height: Space.xl),
          Text('Credits', style: context.text.titleSmall),
          const SizedBox(height: Space.xs),
          Text(
            'Fonts: Inter, Bricolage Grotesque, JetBrains Mono and TikTok Sans (SIL Open Font License). Platform logos: Font Awesome Brands (CC BY 4.0); trademarks belong to their owners. Icons: Material Symbols (Apache 2.0).',
            style: context.text.bodySmall,
          ),
        ]),
      ),
    ]);
  }
}
