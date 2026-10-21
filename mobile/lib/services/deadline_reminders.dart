import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/feed_builder.dart';
import '../domain/relevance.dart';
import '../domain/urgency.dart';
import '../models/feed.dart';
import '../models/job_preferences.dart';
import 'calendar_sync_service.dart';
import 'database_service.dart';
import 'jobs_repository.dart';
import 'notification_service.dart';
import 'profile_store.dart';

/// Jobs that fit you and close within this window get last-day reminders.
const kLastDayWindow = Duration(hours: 24);

/// A reminder notification at most this often per job (the background check runs ~every 15 min).
const kNagEvery = Duration(hours: 4);

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

/// Last-day reminders for jobs you haven't applied to: a notification every few
/// hours and a calendar event with a reminder every 4 hours. Applying, rejecting
/// or hiding the job removes both; restoring it brings them back on the next sync.
class DeadlineReminders {
  DeadlineReminders(this._db, {CalendarSyncService? calendar}) : _calendar = calendar ?? CalendarSyncService(_db);

  final DatabaseService _db;
  final CalendarSyncService _calendar;

  static String _notificationKey(String jobPostId) => 'deadline-$jobPostId';

  /// [jobs]: the open jobs you'd see in the app (already filtered and undecided).
  /// Returns how many jobs have a reminder now.
  Future<int> sync(List<FeedItem> jobs, {required DateTime now, bool? enabled, bool notify = true}) async {
    final on = enabled ?? await LastDayAlerts.enabled();
    final due = {
      if (on)
        for (final j in jobs)
          if (j.deadline.isAfter(now) && !j.deadline.isAfter(now.add(kLastDayWindow))) j.jobPostId: j,
    };
    final existing = {for (final r in await _db.listJobReminders()) r['job_post_id']! as String: r};

    // Applied, rejected, hidden, closed or switched off: take it all back.
    for (final MapEntry(key: id, value: row) in existing.entries) {
      if (due.containsKey(id)) continue;
      await _remove(id, row);
    }

    final calendarAllowed = due.isNotEmpty && await _safe(_calendar.hasPermission, false);
    for (final job in due.values) {
      final row = Map<String, Object?>.of(existing[job.jobPostId] ?? {'job_post_id': job.jobPostId});
      row['deadline'] = job.deadline.millisecondsSinceEpoch;

      final changedDeadline = existing[job.jobPostId]?['deadline'] != row['deadline'];
      if (calendarAllowed && (row['event_id'] == null || changedDeadline)) {
        final written = await _safe(
          () => _calendar.writeJobDeadline(
            title: '⏳ Apply: ${job.bestPost.postName} closes',
            description: [
              '${job.organization} · ${job.examName}',
              if (job.applicationUrl != null) 'Apply online: ${job.applicationUrl}',
              '\nAdded by JobSummit. Swipe the job left in the app to remove this.',
            ].join('\n'),
            deadline: job.deadline,
            now: now,
            calendarId: row['calendar_id'] as String?,
            eventId: row['event_id'] as String?,
          ),
          null,
        );
        if (written != null) {
          row['calendar_id'] = written.$1;
          row['event_id'] = written.$2;
        }
      }

      final last = row['notified_at'] as int?;
      if (notify && (last == null || now.millisecondsSinceEpoch - last >= kNagEvery.inMilliseconds - 1800000)) {
        await _safe(
          () => NotificationService.show(
            key: _notificationKey(job.jobPostId),
            title: '⏳ ${countdownLabel(job.deadline, now)} to apply: ${job.bestPost.postName}',
            body: '${job.organization} · closes ${formatDue(job.deadline)}. Tap to apply.',
            url: job.applicationUrl,
            deadline: true,
          ),
          null,
        );
        row['notified_at'] = now.millisecondsSinceEpoch;
      }
      await _db.saveJobReminder(row);
    }
    return due.length;
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
