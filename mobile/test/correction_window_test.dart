import 'dart:convert';

import 'package:exam_tracker/domain/delivery_track.dart';
import 'package:exam_tracker/domain/exam_watcher.dart';
import 'package:exam_tracker/models/tracked_application.dart';
import 'package:exam_tracker/services/deadline_reminders.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

TrackedApplication app(Map<String, dynamic> timeline) => TrackedApplication.fromRow({
      'id': 'cgl',
      'exam_name': 'SSC CGL 2026',
      'post_name': 'Assistant',
      'organization': 'Staff Selection Commission',
      'status': 'applied',
      'timeline_json': jsonEncode({'job_post_id': 'cgl', ...timeline}),
      'created_at': DateTime(2026, 10, 1).millisecondsSinceEpoch,
      'updated_at': DateTime(2026, 10, 1).millisecondsSinceEpoch,
    });

void main() {
  test('correction notices are their own kind, and other notices are not', () {
    for (final t in [
      'SSC CGL 2026 Application Correction Window Open',
      'Online Correction in Application Form for CGL 2026',
      'RRB NTPC Modification Window Link Active',
      'IBPS PO Edit Window 2026',
    ]) {
      expect(classifyMilestone(t), Milestone.correction, reason: t);
    }
    expect(classifyMilestone('SSC CGL Tier 1 Admit Card 2026'), Milestone.admitCard);
    expect(classifyMilestone('Answer Key Correction Notice'), isNot(Milestone.correction));
    expect(advanceStatus(TrackerStatus.applied, [Milestone.correction]), TrackerStatus.applied,
        reason: 'not a stage: the exam stays where it is');
  });

  test('a correction notice puts its window and link on the exam', () {
    final t = fillTimeline(
      {'job_post_id': 'cgl'},
      const DetectedUpdate(
        milestone: Milestone.correction,
        title: 'SSC CGL Correction Window 2026',
        url: 'https://ssc.gov.in/correction',
        source: UpdateSource.official,
      ),
      DateTime(2026, 10, 24),
    );
    expect(t['correction_url'], 'https://ssc.gov.in/correction');
    final track = buildDeliveryTrack(app(t), DateTime(2026, 10, 24));
    expect(track.stops.first.actions.map((a) => a.label), contains('Correction notice'));
  });

  group('alert', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    final window = {'edit_window_start': '2026-11-10', 'edit_window_end': '2026-11-12'};

    test('once, from the day the window opens, never before or after', () async {
      final a = app(window);
      expect(await CorrectionAlerts.sync([a], now: DateTime(2026, 11, 9, 10)), isEmpty);
      expect(await CorrectionAlerts.sync([a], now: DateTime(2026, 11, 10, 8)), ['cgl']);
      expect(await CorrectionAlerts.sync([a], now: DateTime(2026, 11, 11, 8)), isEmpty);
      SharedPreferences.setMockInitialValues({});
      expect(await CorrectionAlerts.sync([a], now: DateTime(2026, 11, 13, 8)), isEmpty);
    });
  });
}
