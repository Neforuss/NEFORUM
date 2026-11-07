import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'desktop.dart';
import 'env.dart';

/// What a tapped notification asks the app to do.
sealed class NotificationIntent {
  const NotificationIntent();

  /// [actionId]: the button pressed on the notification, if any. A button
  /// comes with its notification's payload, so one payload answers both.
  static NotificationIntent? parse(String? payload, {String? actionId}) {
    if (payload == null || payload.isEmpty) return null;
    // Account ids may themselves contain ':' (e.g. "bluesky:did:plc:…"), so
    // only the first two separators are structural.
    final parts = payload.split(':');
    switch (parts.first) {
      case 'post' when parts.length >= 2:
        return OpenPostIntent(parts[1]);
      case 'handoff' when parts.length >= 3:
        return RunHandoffIntent(parts[1], parts.sublist(2).join(':'));
      case 'publish' when parts.length >= 2:
        return PublishDueIntent(parts[1]);
      case kSignInsPayload:
        return const OpenSignInsIntent();
      case 'retry' when parts.length >= 3:
        return actionId == kRetryAction ? RetryTargetIntent(parts[1], parts.sublist(2).join(':')) : OpenPostIntent(parts[1]);
      case 'posted' when parts.length >= 3:
        if (actionId == kOpenLinkAction) {
          final link = _decodeLink(parts[2]);
          return link == null ? null : OpenLinkIntent(link);
        }
        // An empty post id: the post was deleted right after it went out.
        return parts[1].isEmpty ? null : OpenPostIntent(parts[1]);
    }
    return null;
  }

  /// Only web addresses: a payload must never open anything else.
  static Uri? _decodeLink(String encoded) {
    try {
      final uri = Uri.tryParse(utf8.decode(base64Url.decode(encoded)));
      return uri != null && (uri.scheme == 'https' || uri.scheme == 'http') && uri.hasAuthority ? uri : null;
    } on FormatException {
      return null;
    }
  }
}

/// Payload of a sign-in warning.
const String kSignInsPayload = 'signins';

/// A sign-in warning: opens the sign-ins page.
class OpenSignInsIntent extends NotificationIntent {
  const OpenSignInsIntent();
}

/// The payload of a posted network's notification: a tap opens the post (when
/// it was kept), its Open button goes to the post on the network.
String postedPayload({required String? postId, required String link}) => 'posted:${postId ?? ''}:${base64Url.encode(utf8.encode(link))}';

class OpenPostIntent extends NotificationIntent {
  const OpenPostIntent(this.postId);
  final String postId;
}

class RunHandoffIntent extends NotificationIntent {
  const RunHandoffIntent(this.postId, this.accountId);
  final String postId;
  final String accountId;
}

/// iOS: "your scheduled post is due — tap to publish".
class PublishDueIntent extends NotificationIntent {
  const PublishDueIntent(this.postId);
  final String postId;
}

/// "Retry" on a network that failed: posts to that network again.
class RetryTargetIntent extends NotificationIntent {
  const RetryTargetIntent(this.postId, this.accountId);
  final String postId;
  final String accountId;
}

/// "Open" on a network that has the post: the post on that network.
class OpenLinkIntent extends NotificationIntent {
  const OpenLinkIntent(this.link);
  final Uri link;
}

/// Action id of the "Publish now" button on due-post reminders.
const String kPublishAction = 'publish';

/// Action id of "Retry" on a failed network's notification.
const String kRetryAction = 'retry';

/// Action id of "Open" on a posted network's notification.
const String kOpenLinkAction = 'open_link';

/// The button on a result notification.
enum ResultNoticeAction { none, retry, openLink }

/// One notification of a post's result (see publishResultNotices).
@immutable
class ResultNotice {
  const ResultNotice({
    required this.key,
    required this.title,
    required this.body,
    required this.payload,
    this.groupKey,
    this.threadId,
    this.isSummary = false,
    this.alerts = true,
    this.lines = const [],
    this.action = ResultNoticeAction.none,
  });

  final String key;
  final String title;
  final String body;
  final String? payload;

  /// Android's group, null for a notification on its own.
  final String? groupKey;

  /// iOS's and macOS's thread.
  final String? threadId;
  final bool isSummary;

  /// False for a group's children: only the summary makes a sound.
  final bool alerts;

  /// A summary's one line per network.
  final List<String> lines;
  final ResultNoticeAction action;
}

/// Windows and Linux have no groups, and a toast per network would bury the
/// screen: the summary alone, with each network's line as its body.
List<ResultNotice> collapseResultNotices(List<ResultNotice> notices) {
  final summary = notices.where((n) => n.isSummary).firstOrNull;
  if (summary == null) return notices;
  return [
    ResultNotice(key: summary.key, title: summary.title, body: summary.lines.join('\n'), payload: summary.payload),
  ];
}

/// The NEFORUM mark as Android's notification (status bar) icon, made by
/// tool/generate_icons.dart and kept from resource shrinking by res/raw/keep.xml.
const String kAndroidNotificationIcon = '@drawable/ic_stat_neforum';

/// Shows one notification now: [NotificationService.show], or a test's stand-in.
typedef ShowNotification = Future<void> Function({required String key, required String title, required String body, String? payload});

/// Set by main.dart: runs when a notification action is used while the app
/// is not running (iOS background action). Must be a top-level function.
typedef BackgroundNotificationHandler = void Function(NotificationResponse response);

/// Local notifications on every platform NEFORUM runs on.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  final _intents = StreamController<NotificationIntent>.broadcast();
  bool _ready = false;

  /// Taps on notifications, already parsed.
  Stream<NotificationIntent> get intents => _intents.stream;

  /// Opens [postId], as a tap on a notification of this plugin would. The native
  /// progress notification comes through here.
  void openPost(String postId) => _intents.add(OpenPostIntent(postId));

  /// The notification that launched the app, if any.
  NotificationIntent? launchIntent;

  /// Top-level handler for actions used while NEFORUM is not running.
  BackgroundNotificationHandler? backgroundHandler;

  static const _channelScheduled = AndroidNotificationChannel(
    'neforum.scheduled',
    'Scheduled posts',
    description: 'Reminders for posts that need you to tap Post',
    importance: Importance.high,
  );
  static const _channelResults = AndroidNotificationChannel(
    'neforum.results',
    'Publish results',
    description: 'When a post goes out, or fails',
    importance: Importance.defaultImportance,
  );
  static const _channelSignIns = AndroidNotificationChannel(
    'neforum.signins',
    'Sign-ins',
    description: 'When a sign-in is about to end and needs you',
    importance: Importance.defaultImportance,
  );

  Future<void> init() async {
    if (_ready) return;
    try {
      tzdata.initializeTimeZones();
      if (!kIsWeb) {
        final info = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(info.identifier));
      }
    } on Object {
      // Unknown zone name: fall back to UTC; times are stored in UTC anyway.
    }

    final darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: [
        DarwinNotificationCategory('neforum.post', actions: [
          DarwinNotificationAction.plain('open', 'Open', options: {DarwinNotificationActionOption.foreground}),
        ]),
        // Due-post reminder: "Publish now" runs in the background, without
        // opening the app.
        DarwinNotificationCategory('neforum.due', actions: [
          DarwinNotificationAction.plain(kPublishAction, 'Publish now'),
          DarwinNotificationAction.plain('open', 'Open NEFORUM', options: {DarwinNotificationActionOption.foreground}),
        ]),
        DarwinNotificationCategory(_categoryPosted, actions: [
          DarwinNotificationAction.plain(kOpenLinkAction, 'Open', options: {DarwinNotificationActionOption.foreground}),
        ]),
        DarwinNotificationCategory(_categoryFailed, actions: [
          DarwinNotificationAction.plain(kRetryAction, 'Retry', options: {DarwinNotificationActionOption.foreground}),
        ]),
      ],
    );
    // Apple platforms show the app icon (AppIcon in the asset catalog) on
    // notifications by themselves; Android, Windows and Linux need to be told.
    final settings = InitializationSettings(
      android: const AndroidInitializationSettings(kAndroidNotificationIcon),
      iOS: darwin,
      macOS: darwin,
      linux: LinuxInitializationSettings(defaultActionName: 'Open NEFORUM', defaultIcon: AssetsLinuxIcon('assets/brand/notify_icon.png')),
      windows: WindowsInitializationSettings(
        appName: 'NEFORUM',
        appUserModelId: 'org.neforum.NEFORUM',
        guid: '6f2b9c8e-4a51-4d7e-9b3c-1e0a7d5f2c94',
        // Registered as the app's notification icon (IconUri); without it
        // Windows shows a blank square.
        iconPath: DesktopIntegration.instance.notificationIconPath,
      ),
    );
    try {
      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: (r) {
          final intent = NotificationIntent.parse(r.payload, actionId: r.actionId);
          if (intent != null) _intents.add(intent);
        },
        onDidReceiveBackgroundNotificationResponse: backgroundHandler,
      );
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(_channelScheduled);
      await android?.createNotificationChannel(_channelResults);
      await android?.createNotificationChannel(_channelSignIns);
      if (!kIsWeb) {
        final launch = await _plugin.getNotificationAppLaunchDetails();
        if (launch?.didNotificationLaunchApp ?? false) {
          launchIntent = NotificationIntent.parse(launch!.notificationResponse?.payload, actionId: launch.notificationResponse?.actionId);
        }
      }
      _ready = true;
    } on Object catch (e) {
      debugPrint('Notifications unavailable: $e');
    }
  }

  /// Asks for permission where the OS requires it (Android 13+, iOS, macOS).
  Future<bool> requestPermission() async {
    if (!_ready) return false;
    try {
      if (Env.isAndroid) {
        final a = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        return await a?.requestNotificationsPermission() ?? false;
      }
      if (Env.isIOS) {
        final i = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
        return await i?.requestPermissions(alert: true, badge: true, sound: true) ?? false;
      }
      if (Env.isMacOS) {
        final m = _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
        return await m?.requestPermissions(alert: true, badge: true, sound: true) ?? false;
      }
    } on Object catch (e) {
      // A request already on screen, or no Activity to show it on.
      debugPrint('Could not ask for notifications: $e');
      return false;
    }
    return true;
  }

  /// NEFORUM's page in the OS's notification settings.
  Future<void> openSystemSettings() async {
    if (!_ready) return;
    try {
      if (Env.isAndroid) {
        await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.openAppNotificationSettings();
      } else if (Env.isIOS) {
        await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.openAppNotificationSettings();
      } else if (Env.isMacOS) {
        await _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()?.openAppNotificationSettings();
      }
    } on Object catch (e) {
      debugPrint('Could not open the notification settings: $e');
    }
  }

  static const _categoryPosted = 'neforum.result.posted';
  static const _categoryFailed = 'neforum.result.failed';

  /// How [n] is shown. Android's lock screen conceals it (the plugin has no
  /// public version to give, so that is Android's own "Contents hidden"), and
  /// only a group's summary makes a sound.
  @visibleForTesting
  static NotificationDetails resultDetails(ResultNotice n) {
    final darwin = DarwinNotificationDetails(
      categoryIdentifier: switch (n.action) {
        ResultNoticeAction.openLink => _categoryPosted,
        ResultNoticeAction.retry => _categoryFailed,
        ResultNoticeAction.none => 'neforum.post',
      },
      threadIdentifier: n.threadId,
      presentSound: n.alerts ? null : false,
    );
    return NotificationDetails(
      android: AndroidNotificationDetails(
        _channelResults.id,
        _channelResults.name,
        channelDescription: _channelResults.description,
        importance: _channelResults.importance,
        priority: Priority.defaultPriority,
        category: AndroidNotificationCategory.status,
        icon: kAndroidNotificationIcon,
        color: const Color(0xFF7D00FF),
        groupKey: n.groupKey,
        setAsGroupSummary: n.isSummary,
        groupAlertBehavior: n.groupKey == null ? GroupAlertBehavior.all : GroupAlertBehavior.summary,
        styleInformation: n.isSummary ? InboxStyleInformation(n.lines, contentTitle: n.title) : null,
        visibility: NotificationVisibility.private,
        actions: switch (n.action) {
          ResultNoticeAction.openLink => const [AndroidNotificationAction(kOpenLinkAction, 'Open', showsUserInterface: true)],
          ResultNoticeAction.retry => const [AndroidNotificationAction(kRetryAction, 'Retry', showsUserInterface: true)],
          ResultNoticeAction.none => null,
        },
      ),
      iOS: darwin,
      macOS: darwin,
    );
  }

  /// Shows a post's result: the children first, so that the summary comes
  /// last and is what sounds.
  Future<void> showResults(List<ResultNotice> notices) async {
    final shown = Env.isWindows || Env.isLinux ? collapseResultNotices(notices) : notices;
    for (final n in shown) {
      debugShownResults?.add(n);
      if (!_ready) continue;
      try {
        await _plugin.show(id: _id(n.key), title: n.title, body: n.body, notificationDetails: resultDetails(n), payload: n.payload);
      } on Object catch (e) {
        debugPrint('Notification failed: $e');
      }
    }
  }

  /// Tests: what was shown and cancelled, with or without a real plugin.
  @visibleForTesting
  List<ResultNotice>? debugShownResults;
  @visibleForTesting
  List<String>? debugCancelledKeys;

  NotificationDetails _details(AndroidNotificationChannel channel, {String category = 'neforum.post'}) => NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: channel.importance,
          priority: channel.importance == Importance.high ? Priority.high : Priority.defaultPriority,
          category: AndroidNotificationCategory.reminder,
          icon: kAndroidNotificationIcon,
          color: const Color(0xFF7D00FF),
        ),
        iOS: DarwinNotificationDetails(categoryIdentifier: category, interruptionLevel: category == 'neforum.due' ? InterruptionLevel.timeSensitive : null),
        macOS: DarwinNotificationDetails(categoryIdentifier: category),
      );

  /// Shows a notification now.
  Future<void> show({required String key, required String title, required String body, String? payload, bool signIn = false}) async {
    if (!_ready) return;
    try {
      await _plugin.show(id: _id(key), title: title, body: body, notificationDetails: _details(signIn ? _channelSignIns : _channelResults), payload: payload);
    } on Object catch (e) {
      debugPrint('Notification failed: $e');
    }
  }

  /// Schedules a reminder at [when] (wall clock). Inexact on Android so no
  /// special alarm permission is needed; a minute late is fine for a reminder.
  /// With [publishAction] the reminder carries a "Publish now" button
  /// (iOS), which publishes without opening the app.
  Future<void> schedule({required String key, required DateTime when, required String title, required String body, required String payload, bool publishAction = false, bool signIn = false}) async {
    if (!_ready || kIsWeb) return;
    if (!when.isAfter(DateTime.now())) {
      return show(key: key, title: title, body: body, payload: payload, signIn: signIn);
    }
    try {
      await _plugin.zonedSchedule(
        id: _id(key),
        title: title,
        body: body,
        scheduledDate: tz.TZDateTime.from(when, tz.local),
        notificationDetails: _details(signIn ? _channelSignIns : _channelScheduled, category: publishAction ? 'neforum.due' : 'neforum.post'),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: payload,
      );
    } on Object catch (e) {
      // Windows only supports scheduling from packaged (MSIX) builds; the
      // in-process scheduler covers it, so a failed reminder is harmless.
      debugPrint('Could not schedule notification: $e');
    }
  }

  Future<void> cancel(String key) async {
    debugCancelledKeys?.add(key);
    if (!_ready) return;
    try {
      await _plugin.cancel(id: _id(key));
    } on Object {
      // Not every platform can cancel (unpackaged Windows builds).
    }
  }

  /// How many notifications wait in the OS, leaving out those with
  /// [exceptPayload]. 0 where the OS will not say (unpackaged Windows builds).
  Future<int> pendingCount({String? exceptPayload}) async {
    if (!_ready) return 0;
    try {
      final pending = await _plugin.pendingNotificationRequests();
      return pending.where((p) => exceptPayload == null || p.payload != exceptPayload).length;
    } on Object {
      return 0;
    }
  }

  /// Keys of every notification NEFORUM shows about one post: the due-time
  /// reminder, the result summary and hand-off request, and for each of
  /// [accountIds] that network's result and hand-off.
  static List<String> postKeys(String postId, {Iterable<String> accountIds = const []}) => [
        'due:$postId',
        'result:$postId',
        'handoff:$postId',
        for (final id in accountIds) ...['result:$postId:$id', 'handoff:$postId:$id'],
      ];

  /// Removes the post's reminders and delivered notifications (they quote
  /// its text) when the post is deleted. Anything still on screen for an
  /// account no longer on the post goes too, found by its payload.
  Future<void> cancelPostNotifications(String postId, {Iterable<String> accountIds = const []}) async {
    for (final key in postKeys(postId, accountIds: accountIds)) {
      await cancel(key);
    }
    if (!_ready) return;
    try {
      for (final active in await _plugin.getActiveNotifications()) {
        final id = active.id;
        if (id != null && payloadNamesPost(active.payload, postId)) await _plugin.cancel(id: id);
      }
    } on Object {
      // Not every platform can list them (unpackaged Windows builds).
    }
  }

  /// Whether a notification with [payload] is about post [postId].
  @visibleForTesting
  static bool payloadNamesPost(String? payload, String postId) {
    final parts = (payload ?? '').split(':');
    return parts.length >= 2 && const {'post', 'handoff', 'publish', 'retry', 'posted'}.contains(parts.first) && parts[1] == postId;
  }

  /// Before a new run: what the last run said about [accountIds] is out of
  /// date, whichever way this one ends.
  Future<void> cancelResults(String postId, Iterable<String> accountIds) async {
    await cancel('result:$postId');
    for (final id in accountIds) {
      await cancel('result:$postId:$id');
    }
  }

  /// Stable 31-bit id from a string key.
  static int _id(String key) {
    var h = 0x811C9DC5;
    for (final c in key.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0x7FFFFFFF;
    }
    return h;
  }
}
