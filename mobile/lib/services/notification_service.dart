import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// What a notification is about, which decides how loud it is.
enum Alert {
  /// One of your exams: admit card, exam date, answer key, result. Loud.
  exam,

  /// A form you started closes soon. Loud.
  form,

  /// The morning summary of jobs closing soon. Silent.
  summary,
}

/// Settings › Alerts › "Quiet at night": from 10 PM to 7 AM nothing rings; what
/// comes in arrives silently. On by default.
abstract final class QuietNights {
  static const _key = 'alerts.quietNights';
  static const startHour = 22;
  static const endHour = 7;

  static Future<bool> enabled() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_key) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool on) async => (await SharedPreferences.getInstance()).setBool(_key, on);

  static bool isNight(DateTime t) => t.hour >= startHour || t.hour < endHour;
}

/// Phone notifications for exam-watcher findings. Works in the background
/// isolate too (WorkManager), so no server push is needed.
abstract final class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  // A channel's sound is fixed once created, so the JobSummit ping came with new ids
  // (the old silent-default channels are deleted in init).
  static const _ping = RawResourceAndroidNotificationSound('fx_ping');
  static const _oldChannelIds = ['exam_updates', 'deadline_alerts'];

  static const _channel = AndroidNotificationChannel(
    'exam_updates_v2',
    'Exam updates',
    description: 'Admit cards, exam dates, answer keys and results for exams you track',
    importance: Importance.high,
    sound: _ping,
  );

  // Was "Last-day reminders" for every job closing; a channel keeps its id and sound,
  // only its name and description change.
  static const _formChannel = AndroidNotificationChannel(
    'deadline_alerts_v2',
    'Form reminders',
    description: 'A form you started closes soon',
    importance: Importance.high,
    sound: _ping,
  );

  static const _quietChannel = AndroidNotificationChannel(
    'quiet_v1',
    'Morning summary',
    description: 'Jobs closing soon, once a morning, and updates that came at night',
    importance: Importance.low,
    playSound: false,
    enableVibration: false,
  );

  static const _examGroup = 'jobsummit.exams';

  /// In-app places a notification can open ("agenda"); the home screen listens.
  static final openInApp = ValueNotifier<String?>(null);

  static Future<void> init() async {
    if (_ready) return;
    await _plugin.initialize(
      const InitializationSettings(android: AndroidInitializationSettings('@drawable/ic_stat_jobsummit')),
      onDidReceiveNotificationResponse: (r) => _open(r.payload),
    );
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    for (final id in _oldChannelIds) {
      await android?.deleteNotificationChannel(id);
    }
    await android?.createNotificationChannel(_channel);
    await android?.createNotificationChannel(_formChannel);
    await android?.createNotificationChannel(_quietChannel);
    _ready = true;
  }

  /// A notification tapped while the app was closed: open its link once the app is up.
  static Future<void> openLaunchLink() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp ?? false) await _open(details!.notificationResponse?.payload);
  }

  /// [key] keeps one notification per exam + milestone (a newer one replaces it).
  /// [url]: a web link, or `app:<place>` for a screen in the app.
  static Future<void> show({
    required String key,
    required String title,
    required String body,
    String? url,
    Alert kind = Alert.exam,
    DateTime? now,
  }) async {
    await init();
    final quiet = kind == Alert.summary || (QuietNights.isNight(now ?? DateTime.now()) && await QuietNights.enabled());
    final channel = channelFor(kind, quiet: quiet);
    final group = kind == Alert.exam ? _examGroup : null;
    await _plugin.show(_id(key), title, body, _details(channel, BigTextStyleInformation(body), group: group),
        payload: url);
    // Several exam updates stack under one line instead of filling the shade.
    if (group != null) {
      await _plugin.show(
        _id('$_examGroup-summary'),
        'Exam updates',
        'Updates for exams you track',
        _details(channel, const DefaultStyleInformation(false, false), group: group, summary: true),
      );
    }
  }

  @visibleForTesting
  static AndroidNotificationChannel channelFor(Alert kind, {required bool quiet}) => quiet
      ? _quietChannel
      : switch (kind) {
          Alert.exam => _channel,
          Alert.form => _formChannel,
          Alert.summary => _quietChannel,
        };

  static NotificationDetails _details(AndroidNotificationChannel channel, StyleInformation style,
          {String? group, bool summary = false}) =>
      NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: channel.importance,
          priority: channel.importance == Importance.high ? Priority.high : Priority.low,
          playSound: channel.playSound,
          sound: channel.sound,
          enableVibration: channel.enableVibration,
          styleInformation: style,
          groupKey: group,
          setAsGroupSummary: summary,
          groupAlertBehavior: GroupAlertBehavior.children,
        ),
      );

  static Future<void> cancel(String key) async {
    await init();
    await _plugin.cancel(_id(key));
  }

  static int _id(String key) => key.hashCode & 0x7fffffff;

  static Future<void> _open(String? url) async {
    if (url != null && url.startsWith('app:')) {
      openInApp.value = url.substring(4);
      return;
    }
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri != null && uri.hasScheme) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
