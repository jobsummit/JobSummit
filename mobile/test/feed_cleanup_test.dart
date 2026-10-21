import 'package:exam_tracker/domain/feed_builder.dart';
import 'package:exam_tracker/domain/relevance.dart';
import 'package:exam_tracker/models/job_preferences.dart';
import 'package:exam_tracker/models/jobs_data.dart';
import 'package:exam_tracker/models/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime.utc(2026, 10, 17, 6);

PublishedJob job(String id, String org, {String? adv, DateTime? due, List<PublishedPost>? posts}) => PublishedJob(
      id: id,
      organization: org,
      examName: 'Recruitment',
      advertisementNo: adv,
      applicationDeadline: due ?? DateTime.utc(2026, 10, 19, 11, 30),
      posts: posts ?? [PublishedPost(id: '$id-p', postName: 'Officer', allowedDegrees: const ['B_TECH'])],
    );

void main() {
  group('the same notice twice', () {
    test('one advert number, one closing day, overlapping board names: kept once', () {
      final a = job('a', 'Haryana Public Service Commission', adv: '25/2026');
      final b = job('b', 'Haryana Public Service Commission (HPSC)', adv: '25/2026', due: DateTime.utc(2026, 10, 19, 18, 29));
      expect(withoutDuplicates([a, b], const {}).map((j) => j.id), ['a']);
    });

    test('the one you applied through is the one kept', () {
      final a = job('a', 'Haryana Public Service Commission', adv: '25/2026');
      final b = job('b', 'Haryana Public Service Commission (HPSC)', adv: '25/2026');
      expect(withoutDuplicates([a, b], const {'b-p'}).map((j) => j.id), ['b']);
    });

    test('different boards, days or adverts stay apart', () {
      final a = job('a', 'Tehsildar Office Rajapur', adv: '01/2026');
      expect(withoutDuplicates([a, job('b', 'Collector Office Nashik', adv: '01/2026')], const {}), hasLength(2));
      expect(
          withoutDuplicates([a, job('c', 'Tehsildar Office Rajapur', adv: '01/2026', due: DateTime.utc(2026, 10, 25))],
              const {}),
          hasLength(2));
      expect(withoutDuplicates([job('d', 'IIT Indore'), job('e', 'IIT Indore')], const {}), hasLength(2),
          reason: 'no advert number: not enough to tell');
    });

    List<PublishedPost> posts(String id, List<String> names) => [
          for (final (i, n) in names.indexed) PublishedPost(id: '$id-$i', postName: n, allowedDegrees: const []),
        ];

    test('advert numbers written differently: RRB NTPC once', () {
      final due = DateTime.utc(2026, 11, 6, 18, 29);
      final a = job('a', 'Railway Recruitment Boards',
          adv: 'CEN No. 06/2026', due: due, posts: posts('a', ['Goods Train Manager', 'Senior Clerk cum Typist']));
      final b = job('b', 'Railway Recruitment Board (RRB)',
          adv: 'CEN 06/2026', due: due.add(const Duration(seconds: 59)), posts: posts('b', ['Senior Clerk Cum Typist']));
      expect(withoutDuplicates([a, b], const {}).map((j) => j.id), ['a']);
      expect(advertKey('Ref: GHB/ADM/1708 /2026'), advertKey('GHB/ADM/1708/2026'));
    });

    test('two districts sharing one order number stay apart', () {
      final a = job('a', 'District Collector Hyderabad', adv: '2000/Estt/RDDH/HYD/2026');
      final b = job('b', 'Office of the District Collector and Magistrate, Wanaparthy District',
          adv: 'No.2000/Estt/RDDH/HYD/2026');
      expect(withoutDuplicates([a, b], const {}), hasLength(2));
      expect(sameBoard('SSC', 'Staff Selection Commission'), isTrue);
    });
  });

  test('applying to one copy hides the copy the pipeline merged it into', () {
    final merged = PublishedJob.fromJson({
      'id': 'kept',
      'organization': 'Railway Recruitment Boards',
      'exam_name': 'RRB NTPC Graduate Recruitment 2026',
      'same_as': ['other'],
      'posts': const [],
    });
    expect(merged.ids, ['kept', 'other']);
  });

  test('a notice with no readable eligibility: shown lower, tagged', () {
    final profile = UserProfileData(
      displayName: 'Me',
      dateOfBirth: DateTime(2000),
      category: ReservationCategory.ur,
      qualificationTier: 'UG',
      degreeTitle: 'B_TECH',
    );
    List<RankedJob> rank(List<Map<String, dynamic>> posts) => rankJobs(
          buildFeed(
            jobs: JobsFile.fromJson({
              'schema': 1,
              'generated_at': now.toIso8601String(),
              'jobs': [
                {
                  'id': 'job',
                  'organization': 'Collector Office',
                  'exam_name': 'Kotwal',
                  'category': 'state',
                  'application_deadline': now.add(const Duration(days: 4)).toIso8601String(),
                  'posts': posts,
                }
              ],
            }),
            profile: profile,
            appliedPostIds: const {},
            now: now,
            fetchedAt: now,
          ).items,
          const JobPreferences(),
          Affinity.empty,
          myLevel: 'UG',
        );
    final unknown = rank([
      {'id': 'p', 'post_name': 'Mahsul Sevak (Kotwal)', 'vacancy': {'ur': 3, 'total': 3}},
    ]);
    expect(unknown.single.reasons, contains('Check eligibility'));
    final known = rank([
      {'id': 'p', 'post_name': 'Engineer', 'allowed_degrees': ['B_TECH'], 'vacancy': {'ur': 3, 'total': 3}},
    ]);
    expect(known.single.reasons, isNot(contains('Check eligibility')));
    expect(known.single.score, greaterThan(unknown.single.score));
  });
}
