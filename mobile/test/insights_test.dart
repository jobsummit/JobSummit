import 'dart:convert';

import 'package:exam_tracker/domain/insights.dart';
import 'package:exam_tracker/domain/picks.dart';
import 'package:exam_tracker/domain/relevance.dart';
import 'package:exam_tracker/models/job_preferences.dart';
import 'package:exam_tracker/models/tracked_application.dart';
import 'package:exam_tracker/models/user_profile.dart';
import 'package:exam_tracker/services/insights_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final profile = UserProfileData(
  displayName: 'Asha Verma',
  dateOfBirth: DateTime(2001, 5, 17),
  category: ReservationCategory.obc,
  qualificationTier: 'UG',
  degreeTitle: 'B_TECH',
  otherDegrees: const ['MBA'],
  experienceYears: 1.5,
  subjects: const [SubjectChoice(group: 'engineering', subjects: {'ece'}, custom: 'My own words')],
);

Map<String, Object?> payload({String id = 'id-1', List<SharedDecision> decisions = const []}) => insightsPayload(
      installId: id,
      appVersion: '0.21.0',
      profile: profile,
      preferences: JobPreferences.defaults,
      exams: [
        TrackedApplication(
          id: 'a',
          examName: 'SSC CGL 2026',
          postName: 'CGL',
          status: ApplicationStatus.applied,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          tiers: const ['Tier-1', 'Tier-2'],
        ),
      ],
      decisions: decisions,
      now: DateTime(2026, 10, 24),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('what is shared: bands and choices, never who you are', () {
    final p = payload(decisions: [
      (jobId: 'j1', applied: true, features: {'cat:ssc', 'role:officer'}, at: DateTime.utc(2026, 10, 1)),
    ]);
    final text = jsonEncode(p);
    expect(text, isNot(contains('Asha')));
    expect(text, isNot(contains('2001')));
    expect(text, isNot(contains('My own words')));
    final prof = p['profile']! as Map<String, Object?>;
    expect(prof['age_band'], '22-25');
    expect(prof['degrees'], ['B_TECH', 'MBA']);
    expect(prof['subjects'], ['engineering:ece']);
    expect(prof['experience_band'], '1-2');
    final exam = (p['exams']! as List).single as Map<String, Object?>;
    expect((exam['exam_id'], exam['exam_name'], exam['stage']), ('ssc-cgl', 'SSC CGL', 'Tier-1'));
    expect(((p['decisions']! as List).single as Map)['features'], containsAll(['cat:ssc', 'role:officer']));
  });

  group('sharing', () {
    late List<http.Request> sent;
    late InsightsService service;
    setUp(() {
      sent = [];
      service = InsightsService(
        url: 'https://x.supabase.co/',
        key: 'pub',
        client: MockClient((r) async {
          sent.add(r);
          return http.Response(jsonEncode('ok'), 200);
        }),
      );
    });

    test('on unless turned off; nothing once it is off', () async {
      expect(await InsightsService.consent(), isTrue);
      await InsightsService.setConsent(false);
      expect(await service.maybeUpload(payload()), isFalse);
      expect(sent, isEmpty);
    });

    test('sent, then not again unless it changed or a day passed', () async {
      await InsightsService.setConsent(true);
      final now = DateTime(2026, 10, 24, 9);
      expect(await service.maybeUpload(payload(), now: now), isTrue);
      expect(sent.single.url.toString(), 'https://x.supabase.co/rest/v1/rpc/ingest');
      expect(sent.single.headers['apikey'], 'pub');
      expect((jsonDecode(sent.single.body) as Map)['payload'], isA<Map<String, dynamic>>());
      expect(await service.maybeUpload(payload(), now: now.add(const Duration(hours: 3))), isFalse);
      final changed = payload(decisions: [(jobId: 'j9', applied: false, features: <String>{}, at: DateTime.utc(2026))]);
      expect(await service.maybeUpload(changed, now: now.add(const Duration(minutes: 20))), isFalse); // within the hour
      expect(await service.maybeUpload(changed, now: now.add(const Duration(hours: 2))), isTrue);
      expect(await service.maybeUpload(changed, now: now.add(const Duration(hours: 27))), isTrue);
      expect(sent.length, 3);
    });

    test('delete: the server forgets this id, sharing stops, a new id next time', () async {
      await InsightsService.setConsent(true);
      final id = await InsightsService.installId();
      expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(id), isTrue);
      await service.forget();
      expect(sent.single.url.path, '/rest/v1/rpc/forget');
      expect(jsonDecode(sent.single.body), {'install_id': id});
      expect(await InsightsService.consent(), isFalse);
      expect(await InsightsService.installId(), isNot(id));
    });
  });

  group('job-picks model', () {
    final picks = Picks.fromJson({
      'cohorts': {
        'all': {'cat:ssc': -0.5, 'cat:railway': 0.2},
        'lvl:UG': {'cat:ssc': 0.3},
        'deg:B_TECH': {'cat:railway': 1.2, 'track:engineering': 0.8},
      },
      'tracks': {'j1': 'engineering'},
    });

    test('your degree’s weights win over your level’s, then everyone’s', () {
      final crowd = picks.crowdFor(profile);
      expect(crowd.score({'cat:ssc'}), 0.3);
      expect(crowd.score({'cat:railway'}), 1.2);
      expect(crowd.score({'track:engineering'}), 0.8);
      expect(picks.crowdFor(null).score({'cat:ssc'}), -0.5);
      expect(Picks.fromJson('nonsense').crowdFor(profile).isEmpty, isTrue);
      expect(picks.tracks['j1'], 'engineering');
    });

    test('ranking: people like you count half as much as you', () {
      final mine = Affinity.fromWeights({'cat:railway': 1.0});
      final crowd = Affinity.fromWeights({'cat:railway': 1.0});
      expect(kCrowdShare, 0.5);
      expect(mine.score({'cat:railway'}) + kCrowdShare * crowd.score({'cat:railway'}), 1.5);
    });
  });
}
