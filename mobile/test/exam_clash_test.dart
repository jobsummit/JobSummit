import 'dart:convert';

import 'package:exam_tracker/domain/exam_clash.dart';
import 'package:exam_tracker/models/feed.dart';
import 'package:exam_tracker/models/tracked_application.dart';
import 'package:exam_tracker/services/deadline_reminders.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final now = DateTime(2026, 10, 24);

TrackedApplication exam(String id, String start, [String? end]) => TrackedApplication.fromRow({
      'id': id,
      'exam_name': 'Exam $id',
      'post_name': 'Post $id',
      'status': 'applied',
      'timeline_json': jsonEncode({'job_post_id': id, 'exam_start': start, if (end != null) 'exam_end': end}),
      'created_at': now.millisecondsSinceEpoch,
      'updated_at': now.millisecondsSinceEpoch,
    });

void main() {
  test('two one-day exams on the same day clash for sure', () {
    final c = examClashes([exam('a', '2026-11-12'), exam('b', '2026-11-12'), exam('c', '2026-11-13')], now);
    expect(c.keys, unorderedEquals(['a', 'b']));
    expect(c['a']!.single.sure, isTrue);
    expect(c['a']!.single.label, 'Same day as Exam b · 12 Nov');
  });

  test('an exam window over another exam only may clash', () {
    final c = examClashes([exam('cgl', '2026-11-01', '2026-11-30'), exam('po', '2026-11-12')], now);
    expect(c['po']!.single.sure, isFalse);
    expect(c['po']!.single.label, 'May clash with Exam cgl · from 12 Nov');
  });

  test('exams already over, or archived, are left out', () {
    expect(examClashes([exam('a', '2026-10-01'), exam('b', '2026-10-01')], now), isEmpty);
  });

  test('a job whose notification prints an exam date on one of yours', () {
    final job = FeedItem.fromJson({
      'job_post_id': 'j',
      'exam_name': 'New exam',
      'organization': 'Board',
      'application_deadline': '2026-10-30T18:29:00Z',
      'timeline': {'exam_start': '2026-11-12'},
      'best_post': {'post_detail_id': 'p', 'post_name': 'Officer'},
    });
    expect(jobClash(job, [exam('a', '2026-11-12')], now)?.sure, isTrue);
    expect(jobClash(job, [exam('a', '2026-11-20')], now), isNull);
  });

  test('one alert per clash', () async {
    SharedPreferences.setMockInitialValues({});
    final apps = [exam('a', '2026-11-12'), exam('b', '2026-11-12')];
    expect(await ClashAlerts.sync(apps, now: now), ['a|b']);
    expect(await ClashAlerts.sync(apps, now: now), isEmpty);
  });
}
