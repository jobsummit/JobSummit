import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:workmanager/workmanager.dart';

import '../domain/agenda.dart';
import '../domain/exam_watcher.dart';
import '../domain/widget_summary.dart';
import 'auto_update.dart';
import 'backup_service.dart';
import 'calendar_sync_service.dart';
import 'database_service.dart';
import 'deadline_reminders.dart';
import 'exam_watch_service.dart';
import 'home_widget.dart';
import 'notification_service.dart';
import 'update_service.dart';

const _taskName = 'exam-watch';
const _uniqueName = 'exam-watch-periodic';
const _lastRunKey = 'watch.lastRun';

/// Android's shortest interval; it may stretch it (Doze, battery saver). Each
/// check is small: notices.json only when it changed, board pages at most every
/// [kPageGap].
const kWatchInterval = Duration(minutes: 15);

/// How long a board's page that was just read is left alone.
const kPageGap = Duration(hours: 2);

/// One watcher pass: find new notices, notify, and move calendar events whose
/// exam date the watcher just learned or changed. Used by the background task
/// and by pull-to-refresh. Returns how many new notices were found. [pageGap]:
/// see [ExamWatchService.run] (pull-to-refresh passes a shorter one).
Future<int> runWatchAndNotify(DatabaseService db, {bool force = false, Duration pageGap = kPageGap}) async {
  final prefs = await SharedPreferences.getInstance();
  final now = DateTime.now();
  final last = DateTime.fromMillisecondsSinceEpoch(prefs.getInt(_lastRunKey) ?? 0);
  if (!force && now.difference(last) < const Duration(minutes: 10)) return 0; // just ran
  await prefs.setInt(_lastRunKey, now.millisecondsSinceEpoch);

  final watcher = ExamWatchService(db);
  try {
    final findings = await watcher.run(now: now, pageGap: pageGap);
    final calendar = CalendarSyncService(db);
    var count = 0;
    for (final f in findings) {
      for (final u in f.updates) {
        count++;
        final (title, body) = notificationText(u.milestone, f.after.examName, u.title);
        await NotificationService.show(
            key: '${f.after.id}-${u.milestone.wire}', title: title, body: body, url: u.open, now: now);
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
    // Jobs that fit you and close soon: the morning summary.
    try {
      final now = DateTime.now();
      final jobs = await loadOpenJobs(db, now: now);
      await DeadlineReminders(db).sync(jobs, now: now);
      // The home-screen widget: next last day, next exam.
      final agenda = buildAgenda(tracked: await db.listApplications(), jobs: jobs, now: now);
      await HomeWidget.write(widgetSummary(agenda, now));
    } catch (_) {}
    // Forms started but not paid: a reminder the day before they close.
    // ...and a form's correction window, the day it opens.
    try {
      final apps = await db.listApplications();
      await FormReminders.sync(apps, now: DateTime.now());
      await CorrectionAlerts.sync(apps, now: DateTime.now());
      await ClashAlerts.sync(apps, now: DateTime.now());
      await RefundAlerts.sync(apps, now: DateTime.now());
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

/// Registers the background check, every 15 minutes (idempotent; safe on every start).
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
