// The app as it ships, with one post ready to go to a server on the CI machine, and
// the tap made for it. tool/android_background_probe/run_probe.sh installs a profile
// build of this entry on an emulator, sends Home, removes the task, and asserts from
// the server's log that the post still finished. Nothing here checks anything: only
// the server's log counts. See .github/workflows/build.yml, job android-background.
//
// Not a _test.dart file: it runs without flutter_test, and the integration test loop
// in CI skips it.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_app/main.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/root.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

const String kProbePostId = 'probe-post';
const String kProbeAccountId = 'probe-mastodon';

/// A 1 x 1 PNG: the run's length comes from the server's processing wait, not the file.
final List<int> _kPixel = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAEAQH/7yMK/gAAAABJRU5ErkJggg==');

/// One Mastodon account on [server] and one post waiting for it. Test values only.
Future<void> seedBackgroundProbe(AppServices s, String server, {DateTime? now}) async {
  final at = now ?? DateTime.now();
  await s.accounts.upsert(ConnectedAccount(
    id: kProbeAccountId,
    platformId: 'mastodon',
    tier: PlatformTier.openApi,
    displayName: 'Probe',
    createdAt: at,
    config: {'instance': server, 'domain': Uri.parse(server).host, 'software': 'mastodon', 'maxCharacters': 500, 'maxMediaAttachments': 4},
  ));
  await s.secrets.write(kProbeAccountId, const {'client_id': 'probe', 'client_secret': 'probe', 'access_token': 'probe', 'token_type': 'Bearer'});
  final path = await s.storage.saveMedia('probe-pixel', 'png', Uint8List.fromList(_kPixel));
  await s.posts.upsert(Post(
    id: kProbePostId,
    text: 'Background posting probe',
    createdAt: at,
    updatedAt: at,
    status: PostStatus.draft,
    media: [MediaAttachment(id: 'probe-pixel', path: path, mimeType: 'image/png', sizeBytes: _kPixel.length, width: 1, height: 1, altText: 'One pixel', fileName: 'probe.png')],
    targets: const [PostTarget(accountId: kProbeAccountId)],
  ));
}

Future<void> main() async {
  const server = String.fromEnvironment('NEFORUM_PROBE_SERVER', defaultValue: 'http://127.0.0.1:8787');
  await runNeforum(const [], prepare: (s) => seedBackgroundProbe(s, server));
  // Every print goes to logcat under the "flutter" tag, in the profile build too.
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_tap()));
}

/// What the Post button does, once the app is on screen: Android only lets a visible
/// app begin.
Future<void> _tap() async {
  while (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  BuildContext? app;
  void find(Element e) {
    if (e.widget is NeforumApp) {
      app = e;
    } else {
      e.visitChildElements(find);
    }
  }

  while (app == null) {
    final root = WidgetsBinding.instance.rootElement;
    if (root != null) find(root);
    if (app == null) await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  debugPrint('PROBE tap');
  try {
    final done = await ProviderScope.containerOf(app!, listen: false).read(postActionsProvider).publishExisting(kProbePostId);
    debugPrint('PROBE finished status=${done.status.name} targets=${done.targets.map((t) => t.status.name).join(',')}');
  } on Object catch (e) {
    debugPrint('PROBE stopped ${e.runtimeType}');
  }
}
