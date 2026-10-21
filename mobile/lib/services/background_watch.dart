import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:workmanager/workmanager.dart';

import '../domain/exam_watcher.dart';
import 'auto_update.dart';
import 'backup_service.dart';
import 'calendar_sync_service.dart';
import 'database_service.dart';
import 'deadline_reminders.dart';
import 'exam_watch_service.dart';
import 'notification_service.dart';
import 'update_service.dart';

const _taskName = 'exam-watch';
const _uniqueName = 'exam-watch-periodic';
const _lastRunKey = 'watch.lastRun';

/// Android may stretch this (Doze, battery saver); turning off battery
/// optimisation for the app keeps it close to every 4 hours.
const kWatchInterval = Duration(hours: 4);

/// One watcher pass: find new notices, notify, and move calendar events whose
/// exam date the watcher just learned or changed. Used by the background task
/// and by pull-to-refresh. Returns how many new notices were found.
Future<int> runWatchAndNotify(DatabaseService db, {bool force = false}) async {
  final prefs = await SharedPreferences.getInstance();
  final now = DateTime.now();
  final last = DateTime.fromMillisecondsSinceEpoch(prefs.getInt(_lastRunKey) ?? 0);
  if (!force && now.difference(last) < const Duration(minutes: 30)) return 0; // just ran
  await prefs.setInt(_lastRunKey, now.millisecondsSinceEpoch);

  final watcher = ExamWatchService(db);
  try {
    final findings = await watcher.run(now: now);
    final calendar = CalendarSyncService(db);
    var count = 0;
    for (final f in findings) {
      for (final u in f.updates) {
        count++;
        final (title, body) = notificationText(u.milestone, f.after.examName, u.title);
        await NotificationService.show(
            key: '${f.after.id}-${u.milestone.wire}', title: title, body: body, url: u.open);
      }
      if (f.after.calendarSynced && f.after.effectiveExamAt != f.before.effectiveExamAt) {
        try {
          await calendar.syncExamToCalendar(f.after);
        } catch (_) {}
      }
    }
    // New findings change the backup; it uploads next time the app is open
    // (Google sign-in tokens need the foreground).
    if (findings.isNotEmpty) await BackupPrefs.setDirty(true);
    return count;
  } finally {
    watcher.close();
  }
}

@pragma('vm:entry-point')
void watchCallbackDispatcher() {
  Workmanager().executeTask((task, _) async {
    tzdata.initializeTimeZones();
    // Same file the app uses; never closed here (the app may hold the same connection).
    final db = await DatabaseService.open();
    try {
      await runWatchAndNotify(db, force: true);
    } catch (_) {}
    // Jobs that fit you and close within a day: notify again, keep the calendar right.
    try {
      final now = DateTime.now();
      await DeadlineReminders(db).sync(await loadOpenJobs(db, now: now), now: now);
    } catch (_) {}
    // A new version: download it on Wi-Fi and, where Android allows, install it
    // without asking while the app isn't on screen.
    final updates = UpdateService();
    try {
      await AutoUpdater(updates).run();
    } catch (_) {
    } finally {
      updates.close();
    }
    return true;
  });
}

/// Registers the 4-hourly background check (idempotent; safe on every start).
Future<void> scheduleBackgroundWatch() async {
  await Workmanager().initialize(watchCallbackDispatcher);
  await Workmanager().registerPeriodicTask(
    _uniqueName,
    _taskName,
    frequency: kWatchInterval,
    initialDelay: const Duration(minutes: 20),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
  );
}
