import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'env.dart';

/// What a tapped notification asks the app to do.
sealed class NotificationIntent {
  const NotificationIntent();

  static NotificationIntent? parse(String? payload) {
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
    }
    return null;
  }
}

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

/// Local notifications on every platform NEFORUM runs on.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  final _intents = StreamController<NotificationIntent>.broadcast();
  bool _ready = false;

  /// Taps on notifications, already parsed.
  Stream<NotificationIntent> get intents => _intents.stream;

  /// The notification that launched the app, if any.
  NotificationIntent? launchIntent;

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
      ],
    );
    final settings = InitializationSettings(
      android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: darwin,
      macOS: darwin,
      linux: LinuxInitializationSettings(defaultActionName: 'Open NEFORUM'),
      windows: WindowsInitializationSettings(
        appName: 'NEFORUM',
        appUserModelId: 'org.neforum.NEFORUM',
        guid: '6f2b9c8e-4a51-4d7e-9b3c-1e0a7d5f2c94',
      ),
    );
    try {
      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: (r) {
          final intent = NotificationIntent.parse(r.payload);
          if (intent != null) _intents.add(intent);
        },
      );
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(_channelScheduled);
      await android?.createNotificationChannel(_channelResults);
      if (!kIsWeb) {
        final launch = await _plugin.getNotificationAppLaunchDetails();
        if (launch?.didNotificationLaunchApp ?? false) {
          launchIntent = NotificationIntent.parse(launch!.notificationResponse?.payload);
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
    return true;
  }

  NotificationDetails _details(AndroidNotificationChannel channel) => NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: channel.importance,
          priority: channel.importance == Importance.high ? Priority.high : Priority.defaultPriority,
          category: AndroidNotificationCategory.reminder,
        ),
        iOS: const DarwinNotificationDetails(categoryIdentifier: 'neforum.post'),
        macOS: const DarwinNotificationDetails(categoryIdentifier: 'neforum.post'),
      );

  /// Shows a notification now.
  Future<void> show({required String key, required String title, required String body, String? payload}) async {
    if (!_ready) return;
    try {
      await _plugin.show(id: _id(key), title: title, body: body, notificationDetails: _details(_channelResults), payload: payload);
    } on Object catch (e) {
      debugPrint('Notification failed: $e');
    }
  }

  /// Schedules a reminder at [when] (wall clock). Inexact on Android so no
  /// special alarm permission is needed; a minute late is fine for a reminder.
  Future<void> schedule({required String key, required DateTime when, required String title, required String body, required String payload}) async {
    if (!_ready || kIsWeb) return;
    if (!when.isAfter(DateTime.now())) {
      return show(key: key, title: title, body: body, payload: payload);
    }
    try {
      await _plugin.zonedSchedule(
        id: _id(key),
        title: title,
        body: body,
        scheduledDate: tz.TZDateTime.from(when, tz.local),
        notificationDetails: _details(_channelScheduled),
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
    if (!_ready) return;
    try {
      await _plugin.cancel(id: _id(key));
    } on Object {
      // Not every platform can cancel (unpackaged Windows builds).
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
