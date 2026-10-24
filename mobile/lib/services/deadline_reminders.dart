import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/feed_builder.dart';
import '../domain/relevance.dart';
import '../domain/urgency.dart';
import '../models/feed.dart';
import '../models/job_preferences.dart';
import '../models/tracked_application.dart';
import 'calendar_sync_service.dart';
import 'database_service.dart';
import 'jobs_repository.dart';
import 'notification_service.dart';
import 'profile_store.dart';

/// Jobs that fit you and close within this window go in the morning summary.
const kSummaryWindow = Duration(hours: 48);

/// The summary comes with the first check after this hour.
const kSummaryHour = 7;

/// The on/off switch (Settings → Alerts). On by default.
abstract final class LastDayAlerts {
  static const _key = 'alerts.lastDay';

  static Future<bool> enabled() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_key) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool on) async => (await SharedPreferences.getInstance()).setBool(_key, on);
}

/// Jobs you haven't applied to that close soon: one silent summary each morning
/// ("4 jobs close in the next 2 days"), which opens the Agenda. Applying, rejecting
/// or hiding a job takes it out of the next one.
///
/// Until 0.18 each such job had its own notification every 4 hours and a calendar
/// event: those are taken back on the first sync.
class DeadlineReminders {
  DeadlineReminders(this._db, {CalendarSyncService? calendar}) : _calendar = calendar ?? CalendarSyncService(_db);

  final DatabaseService _db;
  final CalendarSyncService _calendar;

  static const summaryKey = 'closing-summary';
  static const _dayKey = 'alerts.summary.day';

  static String _notificationKey(String jobPostId) => 'deadline-$jobPostId';

  /// [jobs]: the open jobs you'd see in the app (already filtered and undecided).
  /// Returns how many jobs close within [kSummaryWindow].
  Future<int> sync(List<FeedItem> jobs, {required DateTime now, bool? enabled, bool notify = true}) async {
    for (final row in await _db.listJobReminders()) {
      await _remove(row['job_post_id']! as String, row);
    }
    final on = enabled ?? await LastDayAlerts.enabled();
    final due = [
      if (on)
        for (final j in jobs)
          if (j.deadline.isAfter(now) && !j.deadline.isAfter(now.add(kSummaryWindow))) j,
    ]..sort((a, b) => a.deadline.compareTo(b.deadline));
    if (due.isEmpty) {
      await _safe(() => NotificationService.cancel(summaryKey), null);
      return 0;
    }
    final prefs = await SharedPreferences.getInstance();
    final today = '${now.year}-${now.month}-${now.day}';
    if (notify && now.hour >= kSummaryHour && prefs.getString(_dayKey) != today) {
      final (title, body) = summaryText(due, now);
      await _safe(
        () => NotificationService.show(
            key: summaryKey, title: title, body: body, url: 'app:agenda', kind: Alert.summary, now: now),
        null,
      );
      await prefs.setString(_dayKey, today);
    }
    return due.length;
  }

  /// "3 jobs close in the next 2 days" over the first few, soonest first.
  static (String, String) summaryText(List<FeedItem> due, DateTime now) {
    final n = due.length;
    final title = n == 1 ? '1 job closes in the next 2 days' : '$n jobs close in the next 2 days';
    final lines = [
      for (final j in due.take(4)) '${j.bestPost.postName} · ${countdownLabel(j.deadline, now)} left',
      if (n > 4) '+${n - 4} more',
    ];
    return (title, lines.join('\n'));
  }

  Future<void> _remove(String id, Map<String, Object?> row) async {
    final calendarId = row['calendar_id'] as String?;
    final eventId = row['event_id'] as String?;
    if (calendarId != null && eventId != null) {
      await _safe(() => _calendar.deleteEvent(calendarId, eventId), null);
    }
    await _safe(() => NotificationService.cancel(_notificationKey(id)), null);
    await _db.deleteJobReminder(id);
  }

  static Future<T> _safe<T>(Future<T> Function() f, T fallback) async {
    try {
      return await f();
    } catch (_) {
      return fallback; // no calendar / notifications on this phone: the rest still works
    }
  }
}

/// A form you started but haven't paid for: one reminder once it closes within
/// [window] ("the day before"). Paying, archiving or deleting it takes it back.
abstract final class FormReminders {
  static const window = Duration(hours: 30);
  static const _prefix = 'alerts.form.';

  static String _key(String appId) => 'form-$appId';

  /// Returns the ids reminded this time.
  static Future<List<String>> sync(Iterable<TrackedApplication> apps, {required DateTime now}) async {
    final prefs = await SharedPreferences.getInstance();
    final reminded = <String>[];
    final due = <String>{};
    for (final app in apps) {
      final deadline = app.deadline;
      if (app.archived || !app.feeUnpaid || deadline == null) continue;
      if (!deadline.isAfter(now) || deadline.isAfter(now.add(window))) continue;
      due.add(app.id);
      final stamp = '${deadline.millisecondsSinceEpoch}';
      if (prefs.getString('$_prefix${app.id}') == stamp) continue; // already reminded for this date
      try {
        await NotificationService.show(
          key: _key(app.id),
          title: '⏳ Finish your form: ${app.examName}',
          body: 'Fee not paid. Closes ${formatDue(deadline)}.',
          url: app.loginUrl,
          kind: Alert.form,
          now: now,
        );
      } catch (_) {}
      await prefs.setString('$_prefix${app.id}', stamp);
      reminded.add(app.id);
    }
    // Paid, archived or gone: take the reminder back.
    for (final k in prefs.getKeys().where((k) => k.startsWith(_prefix)).toList()) {
      final id = k.substring(_prefix.length);
      if (due.contains(id)) continue;
      await prefs.remove(k);
      try {
        await NotificationService.cancel(_key(id));
      } catch (_) {}
    }
    return reminded;
  }
}

/// The jobs the app would list right now, computed without the UI (background task):
/// profile + jobs.json + preferences + decisions, ranked the same way.
Future<List<FeedItem>> loadOpenJobs(DatabaseService db, {required DateTime now}) async {
  final profile = await ProfileStore.read();
  if (profile == null || !profile.isComplete) return const [];
  final repo = JobsRepository(db);
  try {
    final load = await repo.load();
    final apps = await db.listApplications();
    final tracked = {for (final a in apps) a.id};
    final decisions = <Decision>[];
    final decided = <String>{for (final a in apps) if (a.jobPostId != null) a.jobPostId!};
    for (final r in await db.listDecisions()) {
      decided.add(r['job_post_id']! as String);
      try {
        decisions.add(Decision(
          features: {for (final f in jsonDecode(r['features']! as String) as List<dynamic>) f.toString()},
          applied: r['decision'] == 'applied',
        ));
      } catch (_) {}
    }
    final snapshot = buildFeed(
      jobs: load.file,
      profile: profile,
      appliedPostIds: tracked,
      now: now,
      fetchedAt: load.fetchedAt,
    );
    final open = [
      for (final item in snapshot.items)
        if (!isDecidedJob(item, decided) && item.deadline.isAfter(now)) item,
    ];
    final prefs = await JobPreferencesStore.read();
    return [
      for (final r in rankJobs(open, prefs, Affinity.fromDecisions(decisions), myLevel: profile.qualificationTier))
        r.item,
    ];
  } finally {
    repo.close();
  }
}
