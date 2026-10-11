import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/surfaces.dart';

/// Shown when a platform only allows HTTPS redirects: the browser opened,
/// the user signed in and landed on a page; they paste its address here.
Future<String?> showPasteCodeDialog(BuildContext context, {required Uri authorizationUrl, required Uri redirectUri}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _PasteDialog(authorizationUrl: authorizationUrl, redirectUri: redirectUri),
  );
}

class _PasteDialog extends StatefulWidget {
  const _PasteDialog({required this.authorizationUrl, required this.redirectUri});
  final Uri authorizationUrl;
  final Uri redirectUri;

  @override
  State<_PasteDialog> createState() => _PasteDialogState();
}

class _PasteDialogState extends State<_PasteDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) setState(() => _c.text = data!.text!.trim());
  }

  @override
  Widget build(BuildContext context) {
    final nf = context.nf;
    final valid = _c.text.trim().isNotEmpty;
    return AlertDialog(
      title: const Text('Finish signing in'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            'Your browser opened the sign-in page. After you approve, it lands on an address starting with:',
            style: context.text.bodyMedium?.copyWith(color: nf.textMuted),
          ),
          const SizedBox(height: Space.md),
          NfWell(child: SelectableText('${widget.redirectUri}', style: monoStyle(context, color: nf.text))),
          const SizedBox(height: Space.md),
          Text(
            'That page may say it cannot be reached. That is expected. Copy the whole address from the address bar and paste it below.',
            style: context.text.bodyMedium?.copyWith(color: nf.textMuted),
          ),
          const SizedBox(height: Space.lg),
          TextField(
            controller: _c,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            onChanged: (_) => setState(() {}),
            style: monoStyle(context, color: nf.text),
            decoration: InputDecoration(
              hintText: '${widget.redirectUri}?code=…',
              suffixIcon: IconButton(icon: const Icon(Icons.content_paste_rounded), tooltip: 'Paste', onPressed: _paste),
            ),
          ),
        ]),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(Space.xxl, 0, Space.xxl, Space.xl),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(foregroundColor: nf.textMuted),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: valid ? () => Navigator.pop(context, _c.text.trim()) : null, child: const Text('Continue')),
      ],
    );
  }
}
