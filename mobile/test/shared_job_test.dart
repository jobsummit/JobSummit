import 'package:exam_tracker/domain/shared_job.dart';
import 'package:exam_tracker/models/feed.dart';
import 'package:exam_tracker/models/tracked_application.dart';
import 'package:flutter_test/flutter_test.dart';

FeedItem job(String id, String exam, String org, {String? applyUrl}) => FeedItem.fromJson({
      'job_post_id': id,
      'exam_name': exam,
      'organization': org,
      'apply_url': applyUrl,
      'application_deadline': '2026-11-20T18:29:00Z',
      'best_post': {'post_detail_id': 'p$id', 'post_name': exam},
    });

final jobs = [
  job('cgl', 'Combined Graduate Level Examination 2026', 'Staff Selection Commission'),
  job('ntpc-g', 'RRB NTPC Graduate Level (CEN 06/2026)', 'Railway Recruitment Boards'),
  job('ntpc-ug', 'RRB NTPC Under Graduate Level (CEN 07/2026)', 'Railway Recruitment Boards'),
  job('bihar', 'Bihar Police Constable 2026', 'Central Selection Board of Constable',
      applyUrl: 'https://csbc.bihar.gov.in/apply'),
];

List<String> found(String shared, {List<TrackedApplication> tracked = const [], String title = ''}) =>
    [for (final j in matchShared(SharedText.parse(shared), jobs: jobs, tracked: tracked, pageTitle: title).jobs) j.jobPostId];

void main() {
  test('a WhatsApp message finds its job', () {
    expect(found('🔥 SSC CGL 2026 Notification Out! 14582 posts. Apply: https://t.me/xyz'), ['cgl']);
    expect(found('Bihar Police Constable Recruitment 2026 – 21391 Posts, apply online now'), ['bihar']);
  });

  test('Graduate is not Undergraduate, and another state is not this one', () {
    expect(found('RRB NTPC Graduate Level CEN 06/2026 apply online'), ['ntpc-g']);
    expect(found('RRB NTPC 10+2 Undergraduate CEN 07/2026 form out'), ['ntpc-ug']);
    expect(found('UP Police Constable Recruitment 2026'), isEmpty);
  });

  test('another year is not this one', () {
    expect(found('SSC CGL 2025 Result declared'), isEmpty);
  });

  test('the job’s own link, or a bare link’s page title', () {
    expect(found('https://www.csbc.bihar.gov.in/apply/'), ['bihar']);
    final bare = SharedText.parse('https://www.freejobalert.com/articles/ssc-cgl-2026-1234');
    expect(bare.needsPageTitle, isTrue);
    expect(found('https://www.freejobalert.com/articles/x', title: 'SSC CGL 2026 Notification'), ['cgl']);
  });

  test('an exam you already track comes back as that, not as a new job', () {
    final mine = TrackedApplication.fromRow({
      'id': 'pcgl',
      'exam_name': 'Combined Graduate Level Examination 2026',
      'post_name': 'Assistant',
      'organization': 'Staff Selection Commission',
      'status': 'applied',
      'job_post_id': 'cgl',
      'created_at': 0,
      'updated_at': 0,
    });
    final m = matchShared(SharedText.parse('SSC CGL 2026 admit card'), jobs: jobs, tracked: [mine]);
    expect(m.tracked.single.id, 'pcgl');
    expect(m.jobs, isEmpty);
  });

  test('a name to start "Track it yourself" with', () {
    expect(SharedText.parse('NHM Bihar CHO Recruitment 2026\nLast date 30 Nov\nhttps://x.in').suggestedName,
        'NHM Bihar CHO Recruitment 2026');
  });
}
