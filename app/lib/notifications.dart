import 'dart:io' show Platform;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

class Notifications {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const _channelId = 'pomodoro';
  static const _channelName = 'Pomodoro';
  static const _readingChannelId = 'reading_goal';
  static const _readingChannelName = 'Okuma hedefi';
  static const _readingReminderIds = [20, 21, 22];

  static Future<void> init() async {
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Europe/Istanbul'));

    // Windows/Linux'ta zamanlanmis bildirimler (zonedSchedule) desteklenmedigi
    // icin initialize yapma; initialize platforma ozel ayarlar ister ve
    // verilmezse exception firlatir.
    // macOS'ta ise plugin'in yerel (Darwin) uygulamasi VAR: initialize
    // edilmezse zonedSchedule, plugin'in UserDefaults'a initialize sirasinda
    // yazdigi sunum secenekleri sozlugunu zorla acar ve uygulama cokertir.
    if (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings();
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: android,
        iOS: darwin,
        macOS: darwin,
      ),
    );

    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidImpl?.requestNotificationsPermission();
  }

  static NotificationDetails _details() => const NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      _channelName,
      importance: Importance.max,
      priority: Priority.high,
      enableVibration: true,
      playSound: true,
    ),
    iOS: DarwinNotificationDetails(),
    macOS: DarwinNotificationDetails(),
  );

  static NotificationDetails _readingDetails() => const NotificationDetails(
    android: AndroidNotificationDetails(
      _readingChannelId,
      _readingChannelName,
      importance: Importance.max,
      priority: Priority.high,
      enableVibration: true,
      playSound: true,
    ),
    iOS: DarwinNotificationDetails(),
    macOS: DarwinNotificationDetails(),
  );

  static Future<void> scheduleAt(
    DateTime when,
    String title,
    String body,
  ) async {
    await _plugin.zonedSchedule(
      id: 1,
      title: title,
      body: body,
      scheduledDate: tz.TZDateTime.from(when, tz.local),
      notificationDetails: _details(),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }

  static Future<void> cancel() => _plugin.cancel(id: 1);

  static Future<void> scheduleReadingGoalReminders({
    required String docName,
    required int remainingPages,
  }) async {
    await cancelReadingGoalReminders();
    if (remainingPages <= 0) return;

    final now = tz.TZDateTime.now(tz.local);
    final slots = [
      tz.TZDateTime(tz.local, now.year, now.month, now.day, 9),
      tz.TZDateTime(tz.local, now.year, now.month, now.day, 13),
      tz.TZDateTime(tz.local, now.year, now.month, now.day, 21),
    ];
    final cleanDocName = docName.length > 34
        ? '${docName.substring(0, 34)}...'
        : docName;
    final body = '$cleanDocName: bugünkü hedeften $remainingPages sayfa kaldı.';

    for (var i = 0; i < slots.length; i++) {
      final scheduled = slots[i].isAfter(now)
          ? slots[i]
          : slots[i].add(const Duration(days: 1));
      await _plugin.zonedSchedule(
        id: _readingReminderIds[i],
        title: 'Okuma hedefi',
        body: body,
        scheduledDate: scheduled,
        notificationDetails: _readingDetails(),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    }
  }

  static Future<void> cancelReadingGoalReminders() async {
    for (final id in _readingReminderIds) {
      await _plugin.cancel(id: id);
    }
  }
}
