import 'package:flutter/material.dart';

import '../../platform/appimage_update.dart';
import '../../platform/update_check.dart';
import '../../theme/tokens.dart';

enum _Phase { confirm, running, failed, restarting, installed }

/// Update now, for an AppImage: asks first, then downloads the new AppImage
/// from GitHub, checks its SHA-256, replaces the old one and restarts
/// NEFORUM. On any failure it says why and offers the download page.
class AppImageUpdateDialog extends StatefulWidget {
  const AppImageUpdateDialog({super.key, required this.release, required this.updater, required this.openDownloadPage});

  final LatestRelease release;
  final AppImageSelfUpdate updater;

  /// The Download button's old job: the download page in the browser.
  final Future<void> Function() openDownloadPage;

  @override
  State<AppImageUpdateDialog> createState() => _AppImageUpdateDialogState();
}

class _AppImageUpdateDialogState extends State<AppImageUpdateDialog> {
  _Phase _phase = _Phase.confirm;
  AppImageUpdateProgress _progress = const AppImageUpdateProgress(AppImageUpdateStage.downloading);
  String _error = '';
  bool _cancelled = false;

  static String _megabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  static String _step(AppImageUpdateProgress p) {
    final f = p.fraction;
    return '${p.stage.name} ${f == null ? 'MB ${p.receivedBytes ~/ (1024 * 1024)}' : '% ${(f * 100).floor()}'}';
  }

  Future<void> _run() async {
    setState(() => _phase = _Phase.running);
    try {
      await widget.updater.install(widget.release, isCancelled: () => _cancelled, onProgress: (p) {
        // One repaint per whole percent (or megabyte, or stage), not per
        // network chunk.
        if (mounted && _step(p) != _step(_progress)) setState(() => _progress = p);
      });
    } on AppImageUpdateCancelled {
      if (mounted) Navigator.of(context).pop();
      return;
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _error = e.toString();
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _phase = _Phase.restarting);
    try {
      await widget.updater.restart();
    } on Object catch (e) {
      debugPrint('Restart after the AppImage update failed: $e');
      if (mounted) setState(() => _phase = _Phase.installed);
    }
  }

  String get _progressText {
    final p = _progress;
    return switch (p.stage) {
      AppImageUpdateStage.downloading when p.totalBytes != null => 'Downloading: ${_megabytes(p.receivedBytes)} of ${_megabytes(p.totalBytes!)} MB',
      AppImageUpdateStage.downloading => 'Downloading: ${_megabytes(p.receivedBytes)} MB',
      AppImageUpdateStage.verifying => 'Checking the download',
      AppImageUpdateStage.installing => 'Installing',
    };
  }

  @override
  Widget build(BuildContext context) {
    final version = widget.release.version;
    final muted = context.text.bodySmall?.copyWith(color: context.nf.textMuted);
    final (String title, Widget content, List<Widget> actions) = switch (_phase) {
      _Phase.confirm => (
          'Update to NEFORUM $version?',
          Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('NEFORUM downloads the new AppImage from GitHub, checks it against the SHA-256 in latest.json from neforus.com, '
                'replaces this file with it, then closes and opens again:'),
            const SizedBox(height: Space.sm),
            SelectableText(widget.updater.appImagePath, style: muted),
          ]),
          [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            FilledButton(onPressed: _run, child: const Text('Update')),
          ],
        ),
      _Phase.running => (
          'Updating to NEFORUM $version',
          Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            LinearProgressIndicator(value: _progress.stage == AppImageUpdateStage.downloading ? _progress.fraction : null),
            const SizedBox(height: Space.sm),
            Text(_progressText, style: muted),
          ]),
          [
            TextButton(
              onPressed: _progress.stage == AppImageUpdateStage.downloading && !_cancelled ? () => setState(() => _cancelled = true) : null,
              child: const Text('Cancel'),
            ),
          ],
        ),
      _Phase.failed => (
          'Could not update',
          Text('$_error\n\nThis NEFORUM is unchanged. The download page has the new version.'),
          [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                widget.openDownloadPage();
              },
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: const Text('Download'),
            ),
          ],
        ),
      _Phase.restarting => (
          'Restarting NEFORUM',
          Text('NEFORUM $version is installed. NEFORUM closes and opens again.'),
          const <Widget>[],
        ),
      _Phase.installed => (
          'NEFORUM $version is installed',
          const Text('NEFORUM could not open the new version by itself. Quit NEFORUM and open it again to use it.'),
          [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
        ),
    };
    return PopScope(
      canPop: _phase == _Phase.confirm || _phase == _Phase.failed || _phase == _Phase.installed,
      child: AlertDialog(
        icon: Icon(_phase == _Phase.failed ? Icons.error_outline_rounded : Icons.system_update_alt_rounded),
        title: Text(title),
        content: SingleChildScrollView(child: content),
        actions: actions,
      ),
    );
  }
}
