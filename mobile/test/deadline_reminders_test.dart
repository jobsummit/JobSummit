import 'dart:io';

import 'package:exam_tracker/domain/feed_builder.dart';
import 'package:exam_tracker/models/feed.dart';
import 'package:exam_tracker/models/jobs_data.dart';
import 'package:exam_tracker/models/user_profile.dart';
import 'package:exam_tracker/services/calendar_sync_service.dart';
import 'package:exam_tracker/services/database_service.dart';
import 'package:exam_tracker/services/deadline_reminders.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tzdata;

final now = DateTime.utc(2026, 10, 14, 6);

/// Records what was taken out of the phone's calendar.
class FakeCalendar extends CalendarSyncService {
  FakeCalendar(super.db);

  final events = <String, DateTime>{}; // eventId -> deadline
  final deleted = <String>[];

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> deleteEvent(String calendarId, String eventId) async {
    deleted.add(eventId);
    events.remove(eventId);
  }
}

List<FeedItem> jobs(Map<String, Duration> closesIn) => buildFeed(
      jobs: JobsFile.fromJson({
        'schema': 1,
        'generated_at': now.toIso8601String(),
        'jobs': [
          for (final MapEntry(key: id, value: d) in closesIn.entries)
            {
              'id': id,
              'organization': 'Org $id',
              'exam_name': 'Exam $id',
              'application_deadline': now.add(d).toIso8601String(),
              'posts': [
                {
                  'id': 'p-$id',
                  'post_name': 'Officer $id',
                  'base_max_age': 32,
                  'age_as_on': '2026-10-01',
                  'min_qualification_level': 'UG',
                  'is_open_to_any_graduate': true,
                  'vacancy': {'ur': 10, 'sc': 3, 'st': 1, 'obc': 5, 'ews': 2, 'total': 21},
                }
              ],
            }
        ],
      }),
      profile: UserProfileData(
        displayName: 'Me',
        dateOfBirth: DateTime(2000, 1, 1),
        category: ReservationCategory.ur,
        qualificationTier: 'UG',
        degreeTitle: 'B_TECH',
      ),
      appliedPostIds: const {},
      now: now,
      fetchedAt: now,
    ).items;

void main() {
  late Directory dir;
  late DatabaseService db;

  setUpAll(() {
    sqfliteFfiInit();
    tzdata.initializeTimeZones();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('reminders');
    db = await DatabaseService.open(factory: databaseFactoryFfi, path: '${dir.path}/r.db');
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  Future<String?> summaryDay() async => (await SharedPreferences.getInstance()).getString('alerts.summary.day');

  test('jobs closing within 2 days go in one summary a day, after 7 AM', () async {
    final reminders = DeadlineReminders(db, calendar: FakeCalendar(db));
    final open = jobs({'soon': const Duration(hours: 23), 'next': const Duration(hours: 40), 'later': const Duration(days: 3)});

    final early = DateTime(2026, 10, 14, 6);
    expect(await reminders.sync(open, now: early), 2);
    expect(await summaryDay(), isNull, reason: 'before 7 AM: not yet');

    final morning = DateTime(2026, 10, 14, 7, 20);
    await reminders.sync(open, now: morning);
    expect(await summaryDay(), '2026-10-14');

    // Swiped left ("not for me"): no longer counted.
    expect(await reminders.sync([for (final j in open) if (j.jobPostId != 'soon') j], now: morning), 1);
  });

  test('the summary reads as a short list, soonest first', () {
    final open = jobs({'a': const Duration(hours: 5), 'b': const Duration(hours: 30)});
    final (title, body) = DeadlineReminders.summaryText(open, now);
    expect(title, '2 jobs close in the next 2 days');
    expect(body.split('\n'), hasLength(2));
    expect(body, startsWith('Officer a'));
  });

  test('the old per-job reminders and their calendar events are taken back', () async {
    final calendar = FakeCalendar(db);
    calendar.events['e0'] = now;
    await db.saveJobReminder({
      'job_post_id': 'soon',
      'deadline': now.millisecondsSinceEpoch,
      'calendar_id': 'cal',
      'event_id': 'e0',
      'notified_at': now.millisecondsSinceEpoch,
    });
    await DeadlineReminders(db, calendar: calendar).sync(jobs({'soon': const Duration(hours: 20)}), now: now);
    expect(calendar.deleted, ['e0']);
    expect(await db.listJobReminders(), isEmpty);
  });
}
