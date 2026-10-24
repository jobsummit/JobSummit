import 'package:exam_tracker/domain/delivery_track.dart';
import 'package:exam_tracker/domain/lifecycle.dart';
import 'package:exam_tracker/domain/next_step.dart';
import 'package:exam_tracker/models/tracked_application.dart';
import 'package:exam_tracker/services/deadline_reminders.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final now = DateTime(2026, 10, 24, 10);

TrackedApplication app(ApplicationStatus status, {Duration closesIn = const Duration(hours: 20), String? watcher}) =>
    TrackedApplication.fromRow({
      'id': 'a1',
      'exam_name': 'SSC CGL 2026',
      'post_name': 'Assistant',
      'organization': 'Staff Selection Commission',
      'status': status.wire,
      'deadline_timestamp': now.add(closesIn).millisecondsSinceEpoch,
      'apply_url': 'https://ssc.gov.in/login',
      'server_status': watcher,
      'created_at': now.millisecondsSinceEpoch,
      'updated_at': now.millisecondsSinceEpoch,
    });

void main() {
  test('a started form sits at Applied with Finish & pay, and says it is not paid', () {
    final track = buildDeliveryTrack(app(ApplicationStatus.started), now);
    expect(track.activeIndex, 0);
    expect(track.stops.first.state, StageState.active);
    expect(track.action?.label, 'Finish & pay');
    expect(track.statusLabel, startsWith('Not paid · closes'));

    final paid = buildDeliveryTrack(app(ApplicationStatus.applied), now);
    expect(paid.stops.first.state, StageState.completed);
    expect(paid.statusLabel, isNot(contains('Not paid')));
  });

  test('an admit card found means it was paid after all', () {
    expect(app(ApplicationStatus.started, watcher: 'admit_card_live').feeUnpaid, isFalse);
  });

  test('finishing the form is the next step before its deadline', () {
    final steps = computeNextSteps(tracked: [app(ApplicationStatus.started)], feed: const [], now: now);
    expect(steps.single.kind, NextStepKind.finishForm);
    expect(steps.single.actionLabel, 'Finish & pay');
  });

  test('an old app version reads it as applied', () {
    expect(ApplicationStatus.fromWire('started'), ApplicationStatus.started);
    expect(ApplicationStatus.fromWire('something new'), ApplicationStatus.applied);
  });

  group('form reminder', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('once, the day before it closes', () async {
      expect(await FormReminders.sync([app(ApplicationStatus.started, closesIn: const Duration(days: 3))], now: now),
          isEmpty);
      final soon = app(ApplicationStatus.started);
      expect(await FormReminders.sync([soon], now: now), ['a1']);
      expect(await FormReminders.sync([soon], now: now.add(const Duration(hours: 2))), isEmpty);
    });

    test('paying takes it back, so marking it unpaid again reminds again', () async {
      await FormReminders.sync([app(ApplicationStatus.started)], now: now);
      expect(await FormReminders.sync([app(ApplicationStatus.applied)], now: now), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((k) => k.startsWith('alerts.form.')), isEmpty);
      expect(await FormReminders.sync([app(ApplicationStatus.started)], now: now), ['a1']);
    });
  });
}
