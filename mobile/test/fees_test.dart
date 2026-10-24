import 'dart:convert';
import 'dart:io';

import 'package:exam_tracker/domain/fees.dart';
import 'package:exam_tracker/models/jobs_data.dart';
import 'package:exam_tracker/models/tracked_application.dart';
import 'package:exam_tracker/models/user_profile.dart';
import 'package:exam_tracker/services/database_service.dart';
import 'package:exam_tracker/services/deadline_reminders.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

UserProfileData me(ReservationCategory c, {bool pwbd = false}) => UserProfileData(
      displayName: 'Me',
      dateOfBirth: DateTime(2000, 1, 1),
      category: c,
      qualificationTier: 'UG',
      degreeTitle: 'B_TECH',
      isPwbd: pwbd,
    );

TrackedApplication app(String org, {String exam = 'RRB NTPC Graduate 2026', String? examEnd, int? fee, bool notPaid = false, Map<String, dynamic>? extra}) =>
    TrackedApplication.fromRow({
      'id': 'x',
      'exam_name': exam,
      'post_name': 'Clerk',
      'organization': org,
      'status': 'applied',
      'fee_paid': fee,
      'fee_unpaid': notPaid ? 1 : 0,
      'timeline_json': jsonEncode({'job_post_id': 'x', if (examEnd != null) 'exam_start': examEnd, ...?extra}),
      'created_at': DateTime(2026, 3, 1).millisecondsSinceEpoch,
      'updated_at': DateTime(2026, 3, 1).millisecondsSinceEpoch,
    });

void main() {
  const table = {'UR': 500, 'OBC': 500, 'SC': 250, 'ST': 250, 'PWBD': 0};

  test('your fee is your category’s, or less when PwBD applies', () {
    expect(feeFor(table, me(ReservationCategory.ur)), 500);
    expect(feeFor(table, me(ReservationCategory.sc)), 250);
    expect(feeFor(table, me(ReservationCategory.ur, pwbd: true)), 0);
    expect(feeFor({'ALL': 100}, me(ReservationCategory.ews)), 100);
    expect(feeFor({'UR': 100}, me(ReservationCategory.ews)), isNull, reason: 'EWS not printed: unknown');
  });

  test('the table in one line, and Indian grouping', () {
    expect(feeTable(table), 'UR/OBC ₹500 · SC/ST ₹250 · PwBD free');
    expect(rupees(123456), '₹1,23,456');
    expect(rupees(500), '₹500');
  });

  test('jobs.json fees are read', () {
    final j = PublishedJob.fromJson({'id': 'j', 'fees': {'UR': 500}, 'fee_refund': 'Rs 400 back'});
    expect(j.fees, {'UR': 500});
    expect(j.feeRefund, 'Rs 400 back');
  });

  test('RRB refunds, other boards do not; the printed rule wins', () {
    expect(refundRule(app('Railway Recruitment Boards')), kRrbRefund);
    expect(refundRule(app('Staff Selection Commission', exam: 'SSC CGL 2026')), isNull);
    expect(refundRule(app('Staff Selection Commission', exam: 'SSC CGL 2026', extra: {'fee_refund': '₹100 back'})), '₹100 back');
  });

  test('fees paid this year leave out forms not paid for', () {
    final paid = feesPaidIn([app('A', fee: 500), app('B', fee: 250, notPaid: true)], 2026);
    expect(paid.total, 500);
    expect(paid.exams, 1);
  });

  test('one refund reminder once the exam is over', () async {
    SharedPreferences.setMockInitialValues({});
    final a = app('Railway Recruitment Boards', examEnd: '2026-10-20');
    expect(await RefundAlerts.sync([a], now: DateTime(2026, 10, 19)), isEmpty);
    expect(await RefundAlerts.sync([a], now: DateTime(2026, 10, 22)), ['x']);
    expect(await RefundAlerts.sync([a], now: DateTime(2026, 10, 23)), isEmpty);
  });

  test('the database keeps "not paid" and the fee, also after an upgrade', () async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('fees');
    final db = await DatabaseService.open(factory: databaseFactoryFfi, path: '${dir.path}/f.db');
    try {
      await db.upsertApplication(app('Railway Recruitment Boards', fee: 500));
      await db.updateFee('x', notPaid: true);
      var saved = (await db.getApplication('x'))!;
      expect(saved.feeUnpaid, isTrue);
      expect(saved.feePaid, 500);
      await db.updateFee('x', notPaid: false, clearFee: true);
      saved = (await db.getApplication('x'))!;
      expect(saved.feeUnpaid, isFalse);
      expect(saved.feePaid, isNull);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
