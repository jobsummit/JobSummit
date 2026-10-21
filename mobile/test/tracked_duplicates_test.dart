import 'dart:convert';

import 'package:exam_tracker/domain/tracked_duplicates.dart';
import 'package:exam_tracker/models/jobs_data.dart';
import 'package:exam_tracker/models/tracked_application.dart';
import 'package:flutter_test/flutter_test.dart';

TrackedApplication app(
  String id, {
  required String job,
  String exam = 'RRB NTPC Graduate Recruitment 2026',
  String post = 'Goods Train Manager',
  String org = 'Railway Recruitment Boards',
  DateTime? due,
  int day = 14,
  String? advert,
  int tier = 0,
  bool archived = false,
}) =>
    TrackedApplication.fromRow({
      'id': id,
      'exam_name': exam,
      'post_name': post,
      'organization': org,
      'status': 'applied',
      'archived': archived ? 1 : 0,
      'job_post_id': job,
      'tier': tier,
      'deadline_timestamp': (due ?? DateTime.utc(2026, 11, 6, 18, 29)).millisecondsSinceEpoch,
      'created_at': DateTime.utc(2026, 10, day).millisecondsSinceEpoch,
      'updated_at': DateTime.utc(2026, 10, day).millisecondsSinceEpoch,
      'timeline_json': advert == null ? null : jsonEncode({'job_post_id': job, 'advertisement_no': advert}),
    });

void main() {
  // The two RRB NTPC copies, each marked applied.
  final fromSite = app('p1', job: 'job-a', day: 14);
  final fromPdf = app('p2',
      job: 'job-b',
      exam: 'RRB NTPC Graduate Level Recruitment 2026',
      org: 'Railway Recruitment Board (RRB)',
      due: DateTime.utc(2026, 11, 6, 18, 29, 59),
      day: 15);

  test('two copies of one notice are one application', () {
    final [group] = duplicateGroups([fromSite, fromPdf]);
    expect(group.map((a) => a.id), ['p1', 'p2']); // the first tracked is kept
  });

  test('the one with your IDs is kept, else the copy the Jobs list shows', () {
    expect(duplicateGroups([fromSite, fromPdf], withIds: {'p2'}).single.first.id, 'p2');
    final listed = PublishedJob.fromJson({'id': 'job-b', 'organization': 'RRB', 'exam_name': 'x', 'posts': const []});
    expect(duplicateGroups([fromSite, fromPdf], jobs: [listed]).single.first.id, 'p2');
  });

  test('copies the pipeline merged count even with other names', () {
    final other = app('p3', job: 'job-c', exam: 'Something else', due: DateTime.utc(2026, 12, 1));
    final merged = PublishedJob.fromJson(
        {'id': 'job-a', 'organization': 'RRB', 'exam_name': 'x', 'same_as': ['job-c'], 'posts': const []});
    expect(duplicateGroups([fromSite, other]), isEmpty);
    expect(duplicateGroups([fromSite, other], jobs: [merged]).single, hasLength(2));
  });

  test('different recruitments stay apart', () {
    const sbi = 'State Bank of India';
    final due = DateTime.utc(2026, 11, 9, 18, 29);
    final sco1 = app('s1', job: 'j1', exam: 'SBI SO 2026', org: sbi, post: 'Manager (Risk)', due: due, advert: 'CRPD/SCO/2026-27/30');
    final sco2 = app('s2', job: 'j2', exam: 'SBI SO 2026', org: sbi, post: 'Manager (Risk)', due: due, advert: 'CRPD/SCO/2026-27/31');
    final sco3 = app('s3', job: 'j3', exam: 'SBI SO 2026', org: sbi, post: 'Deputy Manager (IT)', due: due);
    expect(duplicateGroups([sco1, sco2, sco3]), isEmpty);
    expect(duplicateGroups([fromSite, app('p4', job: 'job-b', tier: 1)]), isEmpty, reason: 'another stage');
    expect(duplicateGroups([fromSite, app('p5', job: 'job-b', archived: true)]), isEmpty);
    final manual = TrackedApplication.fromRow({
      'id': 'local-1',
      'exam_name': 'RRB NTPC Graduate Recruitment 2026',
      'post_name': 'Goods Train Manager',
      'status': 'applied',
      'created_at': 0,
      'updated_at': 0,
    });
    expect(duplicateGroups([fromSite, manual]), isEmpty, reason: 'added by hand: never combined');
  });

  test('two posts of one job are one application', () {
    final [group] = duplicateGroups([fromSite, app('p6', job: 'job-a', post: 'Senior Clerk cum Typist')]);
    expect(group, hasLength(2));
  });
}
