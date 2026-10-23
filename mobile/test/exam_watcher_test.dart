import 'dart:convert';

import 'package:exam_tracker/domain/exam_watcher.dart';
import 'package:exam_tracker/models/tracked_application.dart';
import 'package:exam_tracker/services/database_service.dart';
import 'package:exam_tracker/services/exam_watch_service.dart';
import 'package:exam_tracker/services/page_links.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const ssc = 'Staff Selection Commission';
const cgl = 'Combined Graduate Level Examination 2026';

// Same notice board as backend/tests/test_exam_watcher.py.
const noticeBoard = '''
<nav><a href="/notices/menu-admit-card">Admit Card (menu)</a></nav>
<table>
 <tr><td>28/11/2026</td><td><a href="/notices/cgl26-admit.pdf">SSC CGL 2026 Tier-I Admit Card (Exam on 14.12.2026)</a></td></tr>
 <tr><td>27/11/2026</td><td><a href="/notices/chsl26-admit.pdf">SSC CHSL 2026 Admit Card</a></td></tr>
 <tr><td>20/11/2026</td><td><a href="/notices/cgl25-result.pdf">SSC CGL 2025 Final Result</a></td></tr>
 <tr><td>01/09/2026</td><td><a href="/notices/cgl26-notice.pdf">SSC CGL 2026 Notification</a></td></tr>
 <tr><td>25/11/2026</td><td><a href="/notices/cgl26-city.pdf">Combined Graduate Level Exam 2026: Exam City Intimation Slip</a></td></tr>
</table>
''';

void main() {
  group('pure detection (same cases as the Python watcher)', () {
    final cases = {
      'SSC CGL Tier-I Admit Card / Hall Ticket Download': Milestone.admitCard,
      'Call Letter for Document Verification': Milestone.admitCard,
      'Exam Date announced for CEN 03/2026': Milestone.examSchedule,
      'Exam City Intimation Slip': Milestone.examSchedule,
      'Tier-II exam postponed': Milestone.postponed,
      'Rescheduled Admit Card for Shift 2': Milestone.postponed,
      'Tentative Answer Key and Objection Tracker': Milestone.answerKey,
      'Uploading of Response Sheets': Milestone.answerKey,
      'Final Result with Category-wise Cut-off Marks': Milestone.result,
      'Merit List of selected candidates': Milestone.result,
      'Detailed Notification for recruitment': null,
    };
    cases.forEach((text, m) => test(text, () => expect(classifyMilestone(text), m)));

    test('event dates', () {
      expect(extractEventDate('Exam on 14.12.2026'), DateTime(2026, 12, 14));
      expect(extractEventDate('scheduled from 3rd March 2027'), DateTime(2027, 3, 3));
      expect(extractEventDate('Admit card released'), isNull);
    });

    test('alert matching, incl. acronyms and generic words', () {
      expect(
          alertMatchesExam('SSC CGL Admit Card 2026', 'Combined Graduate Level Examination 2026 (CGL)', ssc),
          isTrue);
      expect(
          alertMatchesExam('SSC CHSL Admit Card 2026', 'Combined Graduate Level Examination 2026 (CGL)', ssc),
          isFalse);
      expect(
          alertMatchesExam(
              'SSC CHSL Answer Key 2026', 'Combined Higher Secondary Level Examination 2026', ssc),
          isTrue);
      expect(
        alertMatchesExam('SSC Combined Graduate Level Tier-I Result',
            'Combined Higher Secondary Level Examination 2026', ssc),
        isFalse,
      );
      expect(
          alertMatchesExam(
              'RRB NTPC Admit Card 2026 Out', 'RRB NTPC Graduate Level 2026', 'Railway Recruitment Board'),
          isTrue);
      expect(
        alertMatchesExam('Railway RRB Section Controller Admit Card 2026', 'RRB NTPC Graduate Level 2026',
            'Railway Recruitment Board'),
        isFalse,
      );
      expect(namesThisExam('SSC CGL 2025 Result', 'SSC CGL 2026', ssc), isFalse);
    });

    test('exam-specific pages', () {
      expect(isExamSpecificPage('https://ssc.gov.in/'), isFalse);
      expect(isExamSpecificPage('https://ssc.gov.in/notices'), isFalse);
      expect(isExamSpecificPage('https://www.rrbcdg.gov.in/cen-03-2026'), isTrue);
    });

    test('status only moves forward', () {
      expect(advanceStatus(TrackerStatus.applied, [Milestone.admitCard]), TrackerStatus.admitCardLive);
      expect(advanceStatus(TrackerStatus.answerKeyLive, [Milestone.admitCard]), TrackerStatus.answerKeyLive);
      expect(advanceStatus(TrackerStatus.examScheduled, [Milestone.postponed]), TrackerStatus.examScheduled);
    });
  });

  test('page links: chrome skipped, row text kept as context', () {
    final links = extractPageLinks(noticeBoard, 'https://ssc.gov.in/');
    expect(links.any((l) => l.url.contains('menu-admit-card')), isFalse);
    final admit = links.firstWhere((l) => l.url.endsWith('cgl26-admit.pdf'));
    expect(admit.url, 'https://ssc.gov.in/notices/cgl26-admit.pdf');
    expect(admit.context, startsWith('28/11/2026'));
  });

  test('detection on a board page: only this exam, this year, with milestones', () {
    final found = detectUpdates(
      extractPageLinks(noticeBoard, 'https://ssc.gov.in/'),
      examName: cgl,
      organization: ssc,
      source: UpdateSource.official,
      examSpecificPage: false,
      boardsOwnPage: true, // ssc.gov.in: the board goes without saying
      knownUrls: const {},
    );
    expect([
      for (final u in found) (u.milestone, u.url.split('/').last)
    ], [
      (Milestone.admitCard, 'cgl26-admit.pdf'),
      (Milestone.examSchedule, 'cgl26-city.pdf'),
    ]);
    expect(found.first.eventDate, DateTime(2026, 12, 14));
  });

  group('ExamWatchService end to end', () {
    late DatabaseService db;
    final now = DateTime(2026, 12, 1, 10);

    setUpAll(sqfliteFfiInit);
    setUp(
        () async => db = await DatabaseService.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath));
    tearDown(() => db.close());

    MockClient fakeWeb({int portalStatus = 200}) => MockClient((req) async {
          if (req.url.path.endsWith('notices.json')) {
            return http.Response(
              jsonEncode({
                'schema': 1,
                'notices': [
                  {
                    'title': 'SSC CGL 2026 Answer Key Out',
                    'url': 'https://agg.example/cgl-2026-answer-key',
                    'milestone': 'answer_key'
                  },
                  {'title': 'IBPS PO Result', 'url': 'https://agg.example/ibps', 'milestone': 'result'},
                ],
              }),
              200,
            );
          }
          if (req.url.host == 'ssc.gov.in') {
            return http.Response(noticeBoard, portalStatus, headers: {'content-type': 'text/html'});
          }
          return http.Response('', 404);
        });

    Future<void> track() => db.upsertApplication(TrackedApplication(
          id: 'post-1',
          examName: cgl,
          postName: 'Inspector',
          organization: ssc,
          status: ApplicationStatus.applied,
          portalUrl: 'https://ssc.gov.in/',
          jobPostId: 'job-1',
          createdAt: now,
          updatedAt: now,
        ));

    test('finds notices, advances status, fills the timeline, and diffs on the next run', () async {
      await track();
      final watcher = ExamWatchService(db, client: fakeWeb());
      final findings = await watcher.run(now: now);
      expect(findings.single.updates.map((u) => (u.milestone, u.source)), [
        (Milestone.admitCard, UpdateSource.official),
        (Milestone.examSchedule, UpdateSource.official),
        (Milestone.answerKey, UpdateSource.aggregator),
      ]);
      final app = (await db.getApplication('post-1'))!;
      expect(app.watcherStatus, TrackerStatus.answerKeyLive);
      expect(app.displayStatus, TrackerStatus.answerKeyLive);
      expect(app.updates.length, 3);
      expect(app.timeline?.admitCardUrl, 'https://ssc.gov.in/notices/cgl26-admit.pdf');
      expect(app.timeline?.examCitySlipUrl, 'https://ssc.gov.in/notices/cgl26-city.pdf');
      expect(app.timeline?.examStart, DateTime(2026, 12, 14));
      expect(app.effectiveExamAt, DateTime(2026, 12, 14));

      expect(await watcher.run(now: now), isEmpty); // nothing new the second time
    });

    test('a blocked portal still gets job-site notices', () async {
      await track();
      final findings = await ExamWatchService(db, client: fakeWeb(portalStatus: 403)).run(now: now);
      expect(findings.single.updates.single.milestone, Milestone.answerKey);
    });

    test('every 15 minutes: notices.json only when changed, board pages every 2 hours', () async {
      SharedPreferences.setMockInitialValues({});
      await track();
      var pageReads = 0, noticeDownloads = 0;
      final web = MockClient((req) async {
        if (req.url.path.endsWith('notices.json')) {
          if (req.headers['If-None-Match'] == '"v1"') return http.Response('', 304);
          noticeDownloads++;
          return http.Response(jsonEncode({'schema': 1, 'notices': const []}), 200, headers: {'etag': '"v1"'});
        }
        pageReads++;
        return http.Response(noticeBoard, 200, headers: {'content-type': 'text/html'});
      });
      final watcher = ExamWatchService(db, client: web);
      const gap = Duration(hours: 2);
      await watcher.run(now: now, pageGap: gap);
      await watcher.run(now: now.add(const Duration(minutes: 15)), pageGap: gap);
      await watcher.run(now: now.add(const Duration(minutes: 30)), pageGap: gap);
      expect((pageReads, noticeDownloads), (1, 1)); // then "not modified", and the page left alone
      await watcher.run(now: now.add(const Duration(hours: 2, minutes: 1)), pageGap: gap);
      expect(pageReads, 2);
    });

    test('archived and finished exams are not watched', () async {
      await track();
      await db.setArchived('post-1', archived: true);
      expect(await ExamWatchService(db, client: fakeWeb()).run(now: now), isEmpty);
    });
  });
}
