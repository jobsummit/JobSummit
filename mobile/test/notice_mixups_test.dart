import 'dart:convert';

import 'package:exam_tracker/domain/exam_watcher.dart';
import 'package:exam_tracker/models/tracked_application.dart';
import 'package:flutter_test/flutter_test.dart';

// Mix-ups reported on 24 Oct 2026, with exams added by hand (no form dates).
TrackedApplication manual(String exam, String org, List<String> tiers, {int tier = 0}) => TrackedApplication.fromRow({
      'id': exam,
      'exam_name': exam,
      'post_name': exam,
      'organization': org,
      'status': 'applied',
      'tiers_json': jsonEncode(tiers),
      'tier': tier,
      'created_at': DateTime.utc(2026, 10, 20).millisecondsSinceEpoch,
      'updated_at': DateTime.utc(2026, 10, 20).millisecondsSinceEpoch,
    });

const rrb = 'Railway Recruitment Boards';
const ibps = 'Institute of Banking Personnel Selection';
const ntpcStages = ['CBT-1', 'CBT-2', 'Skill test', 'Document verification', 'Medical'];

List<String> found(TrackedApplication app, List<String> titles) => [
      for (final u in detectUpdates(
        [for (final (i, t) in titles.indexed) PageLink(url: 'https://agg.example/$i', title: t)],
        examName: app.examName,
        organization: app.organization,
        source: UpdateSource.aggregator,
        examSpecificPage: false,
        knownUrls: const {},
        now: DateTime.utc(2026, 10, 24),
        stage: app.tierName,
        round: ExamRound.of(app),
      ))
        u.title,
    ];

void main() {
  final grad = manual('RRB NTPC (Graduate) 2026', rrb, ntpcStages);
  final ug = manual('RRB NTPC (Under graduate) 2026', rrb, ntpcStages);
  final oa = manual('IBPS CRP RRB XV Group B Office Assistant', ibps, ['Prelims', 'Mains']);

  test('a skill test (CBTST) is not CBT-1', () {
    expect(stageKey('RRB NTPC Graduate Level CBTST Admit Card 2026'), 'skill');
    expect(stageKey('Skill test'), 'skill');
    expect(stageKey('Document verification'), 'dv');
    expect(found(grad, ['RRB NTPC Graduate Level CBTST Admit Card 2026']), isEmpty);
    final atSkill = manual('RRB NTPC (Graduate) 2026', rrb, ntpcStages, tier: 2);
    expect(found(atSkill, ['RRB NTPC Graduate Level CBTST Admit Card 2026']), hasLength(1));
  });

  test('Graduate and Undergraduate are different exams', () {
    expect(found(ug, ['RRB NTPC Graduate Level CBTST Admit Card 2026']), isEmpty);
    expect(found(grad, ['RRB NTPC 10+2 UG CBT-I Answer Key 2026']), isEmpty);
    expect(found(ug, ['RRB NTPC 10+2 UG CBT-I Answer Key 2026']), hasLength(1));
  });

  test('another exam of the same board, or the same words, is not yours', () {
    expect(
      found(oa, [
        'IBPS CRP PO MT XVI Mains Admit Card 2026',
        'IBPS Clerk (CSA) 16th Pre Admit Card 2026',
        'UPSSSC Agriculture Technical Assistant Group-C Answer Key 2026 – Out',
        'Indian Airforce Group Y/ Medical Assistant Airmen Intake 02/2027 Answer Key',
      ]),
      isEmpty,
    );
    expect(found(grad, ['RRB Ministerial & Isolated Category Junior Translator (Hindi) CBT Result 2026']), isEmpty);
  });

  test('its own round still counts; another round does not', () {
    expect(found(oa, ['IBPS RRB XV Office Assistant Prelims Admit Card 2026']), hasLength(1));
    expect(found(oa, ['IBPS RRB XIV Office Assistant Prelims Result']), isEmpty);
    expect(roundNumerals('RRB NTPC CBT-II Answer Key'), isEmpty, reason: 'a stage, not a round');
  });
}
