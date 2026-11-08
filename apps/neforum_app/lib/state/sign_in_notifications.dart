import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../platform/notifications.dart';
import 'sign_in_view.dart';

/// [SignInWarningSink] over the OS: every notification opens the sign-ins page,
/// and names the network, the handle and a date only.
class SignInNotificationSink implements SignInWarningSink {
  SignInNotificationSink({required this.accounts, required this.registry, Clock? clock}) : _now = clock ?? systemClock;

  final AccountRepository accounts;
  final AdapterRegistry registry;
  final Clock _now;

  Future<({String title, String body})> _text(SignInWarningNotice n) async {
    final a = await accounts.get(n.status.accountId);
    final network = a == null ? 'A network' : (registry.descriptor(a.platformId)?.name ?? a.displayName);
    return signInWarningText(n, network: network, handle: a?.handle, now: _now(), when: signInDay);
  }

  @override
  Future<void> show(SignInWarningNotice notice) async {
    final t = await _text(notice);
    await NotificationService.instance.show(key: notice.key, title: t.title, body: t.body, payload: kSignInsPayload, signIn: true);
  }

  @override
  Future<void> schedule(SignInWarningNotice notice) async {
    final t = await _text(notice);
    await NotificationService.instance.schedule(key: notice.key, when: notice.at, title: t.title, body: t.body, payload: kSignInsPayload, signIn: true);
  }

  @override
  Future<void> cancel(String key) => NotificationService.instance.cancel(key);

  @override
  Future<int> othersPending() => NotificationService.instance.pendingCount(exceptPayload: kSignInsPayload);
}

/// Says nothing: the demo workspace never raises a notification about a sign-in.
class SilentSignInSink implements SignInWarningSink {
  const SilentSignInSink();
  @override
  Future<void> show(SignInWarningNotice notice) async {}
  @override
  Future<void> schedule(SignInWarningNotice notice) async {}
  @override
  Future<void> cancel(String key) async {}
  @override
  Future<int> othersPending() async => 0;
}
