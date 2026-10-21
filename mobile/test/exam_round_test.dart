import 'dart:convert';

import 'package:exam_tracker/domain/backup_merge.dart';
import 'package:exam_tracker/domain/exam_watcher.dart';
import 'package:exam_tracker/models/backup_snapshot.dart';
import 'package:exam_tracker/models/tracked_application.dart';
import 'package:exam_tracker/services/page_links.dart';
import 'package:flutter_test/flutter_test.dart';

const rrb = 'Railway Recruitment Boards';
const ntpc = 'RRB NTPC Graduate Recruitment 2026';
const article =
    'https://www.freejobalert.com/articles/rrb-ntpc-graduate-recruitment-062026-notification-apply-online-3068511';

// A job site's article for the 2026 notification, with its "latest" sidebars.
const articlePage = '''
<article>
 <h1>RRB NTPC Graduate Recruitment 2026 – Apply Online for 3477 Posts</h1>
 <table><tr><td>Apply Online</td><td><a href="https://www.rrbapply.gov.in/">Click here</a></td></tr></table>
</article>
<aside>
 <ul>
  <li><a href="https://www.freejobalert.com/articles/ssc-cgl-tier-1-admit-card-2026-3069812">SSC CGL Admit Card 2026</a></li>
  <li><a href="https://www.freejobalert.com/articles/upsc-cds-2-result-2026-3074396">UPSC CDS 2 Result 2026</a></li>
  <li><a href="https://www.freejobalert.com/articles/rrb-technician-answer-key-2026-3073792">RRB Technician Answer Key 2026</a></li>
 </ul>
</aside>
''';

final created = DateTime.utc(2026, 10, 14);
final timeline = {
  'job_post_id': 'job-1',
  'application_start': '2026-10-07T18:30:00Z',
  'application_end': '2026-11-06T18:29:00Z',
  'fee_deadline': '2026-11-08',
};

Map<String, Object?> row({String? watcher, List<ExamUpdate> updates = const [], Map<String, dynamic>? tl}) => {
      'id': 'post-1',
      'exam_name': ntpc,
      'post_name': 'Goods Train Manager',
      'organization': rrb,
      'status': 'applied',
      'archived': 0,
      'portal_url': article,
      'apply_url': 'https://www.rrbapply.gov.in/',
      'job_post_id': 'job-1',
      'deadline_timestamp': DateTime.utc(2026, 11, 6, 18, 29).millisecondsSinceEpoch,
      'created_at': created.millisecondsSinceEpoch,
      'updated_at': created.millisecondsSinceEpoch,
      'server_status': watcher,
      'updates_json': jsonEncode([for (final u in updates) u.toJson()]),
      'timeline_json': jsonEncode(tl ?? timeline),
    };

ExamUpdate update(String milestone, String title, String url, DateTime seen, {String source = 'official'}) =>
    ExamUpdate(milestone: milestone, title: title, url: url, detectedAt: seen, source: source);

void main() {
  final app = TrackedApplication.fromRow(row());
  final round = ExamRound.of(app);

  group('which round a notice is about', () {
    final after = DateTime.utc(2026, 12, 20);

    test('the round comes from the name and the form dates', () {
      expect(round.years, {'2026'});
      expect(round.formCloses, DateTime.utc(2026, 11, 6, 18, 29));
    });

    test('other years and recruitments stay out; the next year may be this one', () {
      expect(round.admits('RRB NTPC Graduate CBT 1 Result 2025', Milestone.result, after), isFalse);
      expect(round.admits('RRB NTPC Graduate Result 2026 (CEN 05/2024)', Milestone.result, after), isFalse);
      expect(round.admits('RRB NTPC Graduate CBT 1 Admit Card 2027', Milestone.admitCard, after), isTrue);
      expect(round.admits('RRB NTPC Admit Card 2027 (CEN 06/2026)', Milestone.admitCard, after), isTrue);
      expect(round.admits('RRB NTPC Graduate CBT 1 Admit Card', Milestone.admitCard, after), isTrue);
    });

    test('nothing after the form counts while the form is still open', () {
      final open = DateTime.utc(2026, 10, 21);
      expect(round.admits('RRB NTPC Graduate CBT 1 Result', Milestone.result, open), isFalse);
      expect(round.admits('RRB NTPC Graduate CBT 1 Answer Key', Milestone.answerKey, open), isFalse);
      // An exam date can be announced before the form closes.
      expect(round.admits('RRB NTPC Graduate CBT 1 Exam Date 2027', Milestone.examSchedule, open), isTrue);
    });

    test('dates from long before the form opened are an older round', () {
      expect(
          round.admits('Answer key of RRB NTPC CBT held on 12.03.2026', Milestone.answerKey, after), isFalse);
    });

    test('an exam without a year in its name: its form dates still decide', () {
      final ibps = ExamRound.of(TrackedApplication.fromRow({...row(), 'exam_name': 'IBPS PO XVI'}));
      expect(ibps.years, {'2026'}); // the year its form opened
      expect(ibps.admits('IBPS PO Prelims Result 2025', Milestone.result, after), isFalse);
    });
  });

  group('a job site article as the official link', () {
    test('it is never "this exam\'s page": its sidebars name other exams', () {
      expect(isExamSpecificPage(article), isFalse);
      final found = detectUpdates(
        extractPageLinks(articlePage, article),
        examName: ntpc,
        organization: rrb,
        source: UpdateSource.official,
        examSpecificPage: isExamSpecificPage(article),
        knownUrls: const {},
        now: DateTime.utc(2026, 12, 20),
        round: round,
      );
      expect(found, isEmpty);
    });

    test('the board\'s site is watched instead, and shown as the official site', () {
      expect(app.officialUrl, 'https://www.rrbcdg.gov.in');
    });

    test('a notice that names the exam still counts once the form has closed', () {
      final found = detectUpdates(
        const [PageLink(url: 'https://agg.example/ntpc-admit', title: 'RRB NTPC Graduate CBT 1 Admit Card 2027')],
        examName: ntpc,
        organization: rrb,
        source: UpdateSource.aggregator,
        examSpecificPage: false,
        knownUrls: const {},
        now: DateTime.utc(2027, 2, 1),
        round: round,
      );
      expect(found.single.milestone, Milestone.admitCard);
    });

    test('posted while the form was open: not this round, even if seen later', () {
      final found = detectUpdates(
        [
          PageLink(
              url: 'https://agg.example/ntpc-result',
              title: 'RRB NTPC Graduate Final Result 2026',
              publishedAt: DateTime.utc(2026, 10, 15)),
        ],
        examName: ntpc,
        organization: rrb,
        source: UpdateSource.aggregator,
        examSpecificPage: false,
        knownUrls: const {},
        now: DateTime.utc(2026, 12, 1),
        round: round,
      );
      expect(found, isEmpty);
    });
  });

  group('cleaning up what an older watcher found', () {
    final seen = DateTime.utc(2026, 10, 16);
    final strays = [
      update('result', 'UPSC CDS 2 Result 2026', 'https://www.freejobalert.com/articles/upsc-cds-2-result-2026', seen),
      update('answer_key', 'RRB Technician Answer Key 2026',
          'https://www.freejobalert.com/articles/rrb-technician-answer-key-2026', seen),
      update('admit_card', 'SSC CGL Admit Card 2026',
          'https://www.freejobalert.com/articles/ssc-cgl-tier-1-admit-card-2026', seen),
    ];
    var polluted = <String, dynamic>{...timeline};
    for (final u in strays.reversed) {
      polluted = fillTimeline(
          polluted,
          DetectedUpdate(
              milestone: Milestone.fromWire(u.milestone)!,
              title: u.title,
              url: u.url,
              source: UpdateSource.official),
          seen);
    }

    test('strays come off, the status goes back, the form dates stay', () {
      final bad = TrackedApplication.fromRow(row(watcher: 'result_declared', updates: strays, tl: polluted));
      expect(bad.displayStatus, TrackerStatus.resultDeclared);
      final fixed = withoutStrayUpdates(bad)!;
      expect(fixed.updates, isEmpty);
      expect(fixed.status, TrackerStatus.applied);
      expect(fixed.timeline['merit_list_url'], isNull);
      expect(fixed.timeline['result_date'], isNull);
      expect(fixed.timeline['answer_key_url'], isNull);
      expect(fixed.timeline['admit_card_url'], isNull);
      expect(fixed.timeline['application_end'], '2026-11-06T18:29:00Z');
      expect(fixed.timeline['fee_deadline'], '2026-11-08');
    });

    test('a real notice is kept with what it set', () {
      final real = update('admit_card', 'RRB NTPC Graduate CBT 1 Admit Card 2027', 'https://agg.example/ntpc-admit',
          DateTime.utc(2027, 2, 1),
          source: 'aggregator');
      final fixed = withoutStrayUpdates(TrackedApplication.fromRow(
          row(watcher: 'result_declared', updates: [real, ...strays], tl: polluted)))!;
      expect(fixed.updates.single.url, real.url);
      expect(fixed.status, TrackerStatus.admitCardLive);
      expect(fixed.timeline['admit_card_url'], real.url);
    });

    test('nothing to clean: null', () {
      expect(withoutStrayUpdates(app), isNull);
    });

    test('a backup from before the clean-up does not bring them back', () {
      final now = DateTime.utc(2026, 10, 21);
      BackupSnapshot snap(Map<String, Object?> r) => BackupSnapshot(
            savedAt: now,
            deviceId: 'dev',
            profile: null,
            profileSavedAt: null,
            applications: {'post-1': r},
            vault: const {},
            passwords: const {},
            tombstones: const {},
          );
      final merged = mergeSnapshots(
        snap(row(watcher: 'applied')),
        snap(row(watcher: 'result_declared', updates: strays, tl: polluted)),
        now: now,
      );
      final restored = TrackedApplication.fromRow(merged.applications['post-1']!);
      expect(restored.displayStatus, TrackerStatus.applied);
      expect(restored.updates, isEmpty);
    });
  });
}
