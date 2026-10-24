import 'dart:io';

import 'package:exam_tracker/domain/exam_catalog.dart';
import 'package:exam_tracker/domain/exam_limits.dart';
import 'package:exam_tracker/domain/exam_patterns.dart';
import 'package:exam_tracker/domain/response_sheet.dart';
import 'package:exam_tracker/models/jobs_data.dart';
import 'package:exam_tracker/models/tracked_application.dart';
import 'package:exam_tracker/models/user_profile.dart';
import 'package:exam_tracker/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// One question of a TCS iON response sheet: [key] is the right option (1-4),
/// [chosen] yours ('--' = not answered).
String question(int n, int key, String chosen, {bool ids = false}) {
  final options = [
    for (var o = 1; o <= 4; o++)
      '<tr><td></td><td class="${o == key ? 'rightAns' : 'wrngAns'}">$o. <img src="opt$o.png"> Option $o</td></tr>',
  ].join();
  final status = chosen == '--' ? 'Not Answered' : 'Answered';
  final shown = ids && chosen != '--' ? '66300${chosen}12' : chosen;
  return '''
<div class="question-pnl"><table class="questionPnlTbl"><tbody><tr><td>
<table class="questionRowTbl"><tr><td class="bold">Q.$n</td><td>Question $n text</td></tr>$options</table>
</td><td><table class="menu-tbl">
<tr><td>Question ID :</td><td class="bold">66300$n</td></tr>
${ids ? [for (var o = 1; o <= 4; o++) '<tr><td>Option $o ID :</td><td class="bold">66300${o}12</td></tr>'].join() : ''}
<tr><td>Status :</td><td class="bold">$status</td></tr>
<tr><td>Chosen Option :</td><td class="bold">$shown</td></tr>
</table></td></tr></tbody></table></div>''';
}

String section(String name, String questions) =>
    '<div class="section-cntnr"><div class="section-lbl"><span class="bold">$name</span></div>$questions</div>';

UserProfileData me(ReservationCategory c, DateTime dob, {bool pwbd = false}) => UserProfileData(
      displayName: 'Me',
      dateOfBirth: dob,
      category: c,
      qualificationTier: 'UG',
      degreeTitle: 'B_TECH',
      isPwbd: pwbd,
    );

CatalogExam exam(String id) => examCatalog.firstWhere((e) => e.id == id);

void main() {
  group('response sheet', () {
    final page = '<html><body>${section('General Intelligence and Reasoning', [
          question(1, 2, '2'),
          question(2, 3, '1'),
          question(3, 4, '--'),
        ].join())}${section('English Comprehension', [question(4, 1, '1'), question(5, 2, '2')].join())}</body></html>';

    test('right, wrong and not answered, per section', () {
      final s = parseResponseSheet(page, at: DateTime(2026, 10, 24))!;
      expect([for (final x in s.sections) (x.name, x.right, x.wrong, x.skipped)], [
        ('General Intelligence and Reasoning', 1, 1, 1),
        ('English Comprehension', 2, 0, 0),
      ]);
      final ssc = s.marked(List.filled(2, (2.0, 0.5)));
      expect((ssc.marks, ssc.maxMarks, ssc.label), (5.5, 10.0, '5.5 / 10'));
    });

    test('a sheet that gives the chosen option’s id', () {
      final s = parseResponseSheet(section('Maths', question(1, 3, '3', ids: true) + question(2, 3, '4', ids: true)))!;
      expect((s.right, s.wrong), (1, 1));
    });

    test('not a response sheet', () {
      expect(parseResponseSheet('<html><p>Login</p></html>'), isNull);
    });

    test('the exam’s marks when its sections line up; a saved score survives', () {
      final cgl = patternById('ssc-cgl-tier-1')!;
      final s = parseResponseSheet(page)!;
      expect(sheetMarks(s, cgl, (1, 0.25)), [(2.0, 0.5), (2.0, 0.5)]); // same scheme throughout
      expect(sheetMarks(s, patternById('ssc-mts-cbe'), (1, 0.25)), [(1.0, 0.25), (1.0, 0.25)]);
      final back = SheetScore.decode(s.marked(sheetMarks(s, cgl, (1, 0.25))).encode())!;
      expect(back.label, '5.5 / 10');
    });

    test('the database keeps your score, also after an upgrade', () async {
      sqfliteFfiInit();
      final dir = await Directory.systemTemp.createTemp('score');
      final db = await DatabaseService.open(factory: databaseFactoryFfi, path: '${dir.path}/s.db');
      try {
        await db.upsertApplication(TrackedApplication(
          id: 'x',
          examName: 'SSC CGL 2026',
          postName: 'CGL',
          status: ApplicationStatus.applied,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ));
        final score = parseResponseSheet(page)!.marked(List.filled(2, (2.0, 0.5)));
        await db.updateScore('x', score.encode());
        expect((await db.getApplication('x'))!.myScore?.label, '5.5 / 10');
        await db.updateScore('x', null);
        expect((await db.getApplication('x'))!.myScore, isNull);
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    });
  });

  group('limits', () {
    final now = DateTime(2026, 10, 24);

    test('until which year, with your category’s relaxation', () {
      // Born 1 Sep 1997: on 1 Aug 2029 still 31, on 1 Aug 2030 32, 2031 33.
      final ur = limitsFor(exam('ssc-cgl'), me(ReservationCategory.ur, DateTime(1997, 9, 1)), now)!;
      expect((ur.maxAge, ur.lastYear, ur.fromNotice), (32, 2030, false));
      expect(ur.summary(now), 'Until 2030 · age limit 32 on 1 Aug for some posts');
      final obc = limitsFor(exam('ssc-cgl'), me(ReservationCategory.obc, DateTime(1997, 9, 1)), now)!;
      expect((obc.maxAge, obc.lastYear), (35, 2033));
      expect(obc.summary(now), 'Until 2033 · age limit 35 (32 + 3) on 1 Aug for some posts');
    });

    test('too young yet, and too old already', () {
      final young = limitsFor(exam('upsc-cse'), me(ReservationCategory.ur, DateTime(2008, 3, 1)), now)!;
      expect(young.firstYear, 2029); // 21 on 1 Aug 2029
      expect(young.summary(now), startsWith('From 2029 until 2040'));
      final old = limitsFor(exam('ssc-gd'), me(ReservationCategory.ur, DateTime(1990, 1, 1)), now)!;
      expect(old.lastYear, isNull);
      expect(old.summary(now), 'Over the age limit (23 on 1 Jan)');
    });

    test('the latest notice’s rule wins over the usual one', () {
      final job = PublishedJob.fromJson({
        'id': 'j',
        'organization': 'Staff Selection Commission',
        'exam_name': 'SSC Combined Graduate Level Examination 2026',
        'application_deadline': '2026-07-04T23:00:00Z',
        'posts': [
          {'id': 'a', 'post_name': 'Inspector', 'min_age': 18, 'base_max_age': 30, 'age_as_on': '2026-08-01'},
          {'id': 'b', 'post_name': 'Assistant', 'min_age': 20, 'base_max_age': 27, 'age_as_on': '2026-08-01'},
        ],
      });
      final l = limitsFor(exam('ssc-cgl'), me(ReservationCategory.ur, DateTime(1997, 9, 1)), now, jobs: [job])!;
      expect((l.fromNotice, l.rule.max, l.rule.min, l.rule.postWise, l.lastYear), (true, 30, 18, true, 2028));
    });

    test('attempts by category', () {
      final dob = DateTime(2000, 1, 1);
      expect(attemptsFor('upsc-cse', me(ReservationCategory.ur, dob)), 6);
      expect(attemptsFor('upsc-cse', me(ReservationCategory.obc, dob)), 9);
      expect(attemptsFor('upsc-cse', me(ReservationCategory.sc, dob)), isNull); // no limit
      expect(attemptsFor('upsc-cse', me(ReservationCategory.ur, dob, pwbd: true)), 9);
      expect(attemptsFor('sbi-po', me(ReservationCategory.ews, dob)), 4);
      expect(attemptsFor('ssc-cgl', me(ReservationCategory.ur, dob)), isNull);
    });
  });

  test('the usual rules name real exams', () {
    final ids = {for (final e in examCatalog) e.id};
    expect(ids.containsAll(kUsualAgeRules.keys), isTrue);
    expect(ids.containsAll(kAttemptRules.keys), isTrue);
    expect(ids.containsAll(kExamPatterns.map((p) => p.examId)), isTrue);
  });
}
