import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'env.dart';
import 'notifications.dart';

/// Whether this device lets NEFORUM show notifications, read from the OS.
enum NotificationAccess {
  /// Windows, Linux and the demo: there is nothing to ask for.
  notRequired,

  /// On.
  granted,

  /// iOS provisional: delivered quietly to Notification Center only.
  quiet,

  /// Off, and the OS has never shown its prompt.
  notAsked,

  /// Android: refused once, and the OS will still ask.
  canAskAgain,

  /// Android: asked before and the OS gives no rationale, which means either a
  /// dialog swiped away or two refusals. No public API tells them apart, so
  /// only trying the dialog can.
  askedUnclear,

  /// Off, and only the OS's settings can change it.
  blocked,
}

/// What the main button does for each [NotificationAccess].
enum NotificationAccessAction { none, explainThenAsk, tryAsk, openSettings }

NotificationAccessAction primaryActionFor(NotificationAccess access) => switch (access) {
      NotificationAccess.notRequired || NotificationAccess.granted => NotificationAccessAction.none,
      NotificationAccess.quiet || NotificationAccess.notAsked || NotificationAccess.canAskAgain => NotificationAccessAction.explainThenAsk,
      NotificationAccess.askedUnclear => NotificationAccessAction.tryAsk,
      NotificationAccess.blocked => NotificationAccessAction.openSettings,
    };

/// What the OS reports. Pure data, so the table in [notificationAccessFrom]
/// runs without a device.
@immutable
sealed class NotificationFacts {
  const NotificationFacts();
}

class AndroidNotificationFacts extends NotificationFacts {
  const AndroidNotificationFacts({required this.sdkInt, required this.enabled, required this.rationale, this.resultsChannelOff = false});
  final int sdkInt;

  /// NotificationManager.areNotificationsEnabled.
  final bool enabled;

  /// Activity.shouldShowRequestPermissionRationale(POST_NOTIFICATIONS).
  final bool rationale;

  /// App notifications are on but the user set `neforum.results` to none.
  final bool resultsChannelOff;
}

/// UNNotificationSettings.authorizationStatus on iOS and macOS.
class DarwinNotificationFacts extends NotificationFacts {
  const DarwinNotificationFacts(this.status);

  /// notDetermined, denied, authorized, provisional, ephemeral or unknown.
  final String status;
}

/// The OS asks nothing here (Windows, Linux, web), or could not be read.
class NoPromptFacts extends NotificationFacts {
  const NoPromptFacts({this.readFailed = false});
  final bool readFailed;
}

/// The state table. [askedBefore]: this device has shown the OS prompt.
NotificationAccess notificationAccessFrom(NotificationFacts facts, {required bool askedBefore}) => switch (facts) {
      NoPromptFacts() => NotificationAccess.notRequired,
      AndroidNotificationFacts(:final enabled) when enabled => NotificationAccess.granted,
      // Android 12 and lower has no prompt: off means the user turned it off.
      AndroidNotificationFacts(:final sdkInt) when sdkInt < 33 => NotificationAccess.blocked,
      AndroidNotificationFacts(:final rationale) when rationale => NotificationAccess.canAskAgain,
      AndroidNotificationFacts() => askedBefore ? NotificationAccess.askedUnclear : NotificationAccess.notAsked,
      DarwinNotificationFacts(:final status) => switch (status) {
          'notDetermined' => NotificationAccess.notAsked,
          'authorized' || 'ephemeral' => NotificationAccess.granted,
          'provisional' => NotificationAccess.quiet,
          // Denied, or a status newer than this build: never prompt on a guess.
          _ => NotificationAccess.blocked,
        },
    };

/// What the screens need to know, re-read whenever the app comes back.
@immutable
class NotificationAccessView {
  const NotificationAccessView({
    this.access = NotificationAccess.notRequired,
    this.loaded = false,
    this.resultsChannelOff = false,
    this.readFailed = false,
    this.lastUnseenAt,
  });

  final NotificationAccess access;

  /// False until the OS has answered the first time.
  final bool loaded;
  final bool resultsChannelOff;

  /// A phone that could not say: nothing is claimed and nothing prompts.
  final bool readFailed;

  /// When a post last finished with nobody watching.
  final DateTime? lastUnseenAt;

  bool get isOff =>
      access == NotificationAccess.quiet ||
      access == NotificationAccess.notAsked ||
      access == NotificationAccess.canAskAgain ||
      access == NotificationAccess.askedUnclear ||
      access == NotificationAccess.blocked;

  /// Off, or on with the results channel set to none.
  bool get needsAttention => isOff || resultsChannelOff;
}

/// D8: the explanation screen, once, on first launch of a real workspace, on
/// the OSes that ask.
bool shouldOfferFirstLaunchPrompt({required bool platformAsks, required bool demo, required NotificationAccess access, required DateTime? promptAt}) =>
    platformAsks && !demo && access == NotificationAccess.notAsked && promptAt == null;

/// D8: on the first Post or Schedule, one quiet line, no modal.
bool shouldShowQuietLine({required bool platformAsks, required bool demo, required NotificationAccess access, required DateTime? hintShownAt}) =>
    platformAsks && !demo && access == NotificationAccess.notAsked && hintShownAt == null;

/// D9: above every section while access is off. Closing hides it until a post
/// finishes unseen or, on iOS, a post is scheduled that needs the reminder
/// ([reminderNeededAt]: the newest such post's last change).
bool notificationBannerVisible(NotificationAccessView view, {required bool demo, required DateTime? closedAt, DateTime? reminderNeededAt}) {
  if (demo || !view.loaded || !view.needsAttention) return false;
  if (closedAt == null) return true;
  final unseen = view.lastUnseenAt;
  return (unseen != null && unseen.isAfter(closedAt)) || (reminderNeededAt != null && reminderNeededAt.isAfter(closedAt));
}

/// The banner's words.
({String text, bool urgent, String action}) notificationBannerText(NotificationAccessView view, {required bool remindersAtRisk}) {
  if (!view.isOff) {
    return (text: 'Publish results notifications are off in Android settings.', urgent: false, action: 'Open settings');
  }
  final action = primaryActionFor(view.access) == NotificationAccessAction.openSettings ? 'Open settings' : 'Turn on';
  if (remindersAtRisk) {
    return (text: 'Scheduled posts will not remind you. Turn on notifications.', urgent: true, action: action);
  }
  return (text: 'Notifications are off, so NEFORUM cannot tell you how a post went while you are away.', urgent: false, action: action);
}

/// The permanent row in Settings > Notifications, from the real state.
({String title, String description, String? action}) notificationRowText(NotificationAccessView view, {required String os, required bool isIOS}) {
  const lost = 'Scheduled posts will not remind you at their time.';
  final cost = isIOS ? lost : 'NEFORUM cannot tell you how a post went while you are away.';
  if (view.readFailed) {
    return (title: 'Notifications', description: 'NEFORUM could not read this setting from $os.', action: 'Open settings');
  }
  return switch (view.access) {
    NotificationAccess.notRequired => (title: 'Notifications', description: 'This computer shows them without asking. Hand-off networks always get a reminder when it is time to post.', action: null),
    NotificationAccess.granted when view.resultsChannelOff => (title: 'Publish results are off', description: 'Notifications are on, but the Publish results channel is off in $os settings.', action: 'Open settings'),
    NotificationAccess.granted => (title: 'Notifications are on', description: isIOS ? 'A notification at the scheduled time lets you publish with one tap.' : 'NEFORUM tells you how each post went.', action: 'Manage'),
    NotificationAccess.quiet => (title: 'Notifications are quiet', description: 'They go to Notification Center without a sound or a banner. $cost', action: 'Turn on'),
    NotificationAccess.notAsked || NotificationAccess.canAskAgain || NotificationAccess.askedUnclear => (title: 'Notifications are off', description: cost, action: 'Turn on'),
    NotificationAccess.blocked => (title: '$os is blocking notifications', description: cost, action: 'Open settings'),
  };
}

/// The OS, behind one seam so that tests answer for it.
abstract class NotificationAccessPlatform {
  /// Replaced by tests.
  static NotificationAccessPlatform instance = ChannelNotificationAccessPlatform();

  Future<NotificationFacts> read();

  /// Shows the OS prompt where the OS still will. True when access is on.
  Future<bool> request();

  /// NEFORUM's page in the OS's notification settings.
  Future<void> openSettings();

  /// Android: the Publish results channel's page. Elsewhere [openSettings].
  Future<void> openResultsChannelSettings();
}

/// `neforum/notification_access`: the two facts the notification plugin cannot
/// give. Android's rationale flag, and iOS's and macOS's raw status, since the
/// plugin's checkPermissions cannot tell notDetermined from denied.
class ChannelNotificationAccessPlatform implements NotificationAccessPlatform {
  static const _channel = MethodChannel('neforum/notification_access');

  @override
  Future<NotificationFacts> read() async {
    if (!(Env.isAndroid || Env.isIOS || Env.isMacOS)) return const NoPromptFacts();
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('read');
      if (m == null) return const NoPromptFacts(readFailed: true);
      if (Env.isAndroid) {
        return AndroidNotificationFacts(
          sdkInt: m['sdkInt'] as int? ?? 0,
          enabled: m['enabled'] as bool? ?? false,
          rationale: m['rationale'] as bool? ?? false,
          resultsChannelOff: m['resultsChannelOff'] as bool? ?? false,
        );
      }
      return DarwinNotificationFacts(m['status'] as String? ?? 'unknown');
    } on Object catch (e) {
      // No channel in this engine (a background task), or the OS said no.
      debugPrint('Could not read notification access: $e');
      return const NoPromptFacts(readFailed: true);
    }
  }

  @override
  Future<bool> request() => NotificationService.instance.requestPermission();

  @override
  Future<void> openSettings() => NotificationService.instance.openSystemSettings();

  @override
  Future<void> openResultsChannelSettings() async {
    if (!Env.isAndroid) return openSettings();
    try {
      await _channel.invokeMethod<void>('openResultsChannelSettings');
    } on Object catch (e) {
      debugPrint('Could not open the channel settings: $e');
      await openSettings();
    }
  }
}
