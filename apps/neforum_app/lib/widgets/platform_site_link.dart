import 'package:flutter/material.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;
import 'package:url_launcher/url_launcher.dart';

import '../theme/tokens.dart';

/// A platform's own site, as a small link (NEFORUM 1.4.2): someone without an
/// account there can open it and make one before adding it. The address is
/// [PlatformDescriptor.homepage], shown without `https://` and `www.`.
class PlatformSiteLink extends StatelessWidget {
  const PlatformSiteLink(this.descriptor, {super.key, this.lead});

  final PlatformDescriptor descriptor;

  /// Words before the address, such as "No account yet?".
  final String? lead;

  /// Opens [url] in the person's browser. Tests replace it.
  @visibleForTesting
  static Future<bool> Function(Uri url) open = (url) => launchUrl(url, mode: LaunchMode.externalApplication);

  /// The address as it reads in the link: `tumblr.com`, `newgrounds.com/art`.
  static String? labelOf(String? homepage) {
    if (homepage == null) return null;
    final u = Uri.tryParse(homepage);
    if (u == null || u.host.isEmpty) return null;
    final host = u.host.startsWith('www.') ? u.host.substring(4) : u.host;
    final path = u.path.endsWith('/') ? u.path.substring(0, u.path.length - 1) : u.path;
    return '$host$path';
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final homepage = descriptor.homepage;
    final label = labelOf(homepage);
    if (homepage == null || label == null) return const SizedBox.shrink();
    final style = context.text.labelSmall?.copyWith(color: nf.accent, fontWeight: FontWeight.w600);
    return Semantics(
      link: true,
      label: 'Open $label',
      excludeSemantics: true,
      child: Tooltip(
        message: 'Open $label in your browser, to make an account on ${descriptor.name}',
        child: InkWell(
          key: ValueKey('site-link-${descriptor.id}'),
          borderRadius: BorderRadius.circular(Radii.xs),
          onTap: () => open(Uri.parse(homepage)),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (lead != null) ...[
                Flexible(child: Text(lead!, style: context.text.labelSmall?.copyWith(color: nf.textFaint), overflow: TextOverflow.ellipsis)),
                const SizedBox(width: Space.xs),
              ],
              Icon(Icons.open_in_new_rounded, size: 13, color: nf.accent),
              const SizedBox(width: Space.xxs),
              Flexible(child: Text(label, style: style, overflow: TextOverflow.ellipsis)),
            ]),
          ),
        ),
      ),
    );
  }
}
