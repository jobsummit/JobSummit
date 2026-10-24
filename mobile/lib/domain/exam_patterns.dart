/// Full mocks in the pattern of the exams people track: each exam's sections,
/// question counts, time and marking, as in their recent notices. A mock for
/// your exam shows on Practice and on the exam's page. Pure (no I/O).
///
/// Only first-stage computer tests (where the sections are these MCQs);
/// descriptive papers, typing and skill tests aren't practised here.
library;

import 'package:flutter/foundation.dart';

import '../models/tracked_application.dart';
import 'practice.dart';

const _q = PracticeSection.quant, _r = PracticeSection.reasoning, _e = PracticeSection.english;
const _g = PracticeSection.gs, _s = PracticeSection.science, _c = PracticeSection.computer;

@immutable
class ExamPattern {
  const ExamPattern(this.examId, this.name, this.parts, {required this.minutes, this.stage});

  /// The exam's id in the built-in list (exam_catalog.dart).
  final String examId;

  /// "SSC CGL Tier-1"
  final String name;

  /// The stage it is ("Tier-1"), when the exam has several.
  final String? stage;
  final List<PracticePart> parts;
  final int minutes;

  String get id => stage == null ? examId : '$examId-${stage!.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}';

  int get count => parts.fold(0, (sum, p) => sum + p.count);
  double get maxMarks => parts.fold(0.0, (sum, p) => sum + p.plus * p.count);

  /// "+2 · −½" when every section is marked the same, else null.
  String? get marking {
    final first = parts.first;
    return parts.every((p) => p.plus == first.plus && p.minus == first.minus)
        ? markingText(first.plus, first.minus)
        : null;
  }

  PracticePlan get plan => PracticePlan.pattern(id: id, title: '$name mock', parts: parts, minutes: minutes);
}

List<PracticePart> _each(List<(PracticeSection, int)> parts, double plus, double minus) =>
    [for (final (s, n) in parts) PracticePart(s, n, plus: plus, minus: minus)];

const _third = 1 / 3;

final kExamPatterns = <ExamPattern>[
  ExamPattern('ssc-cgl', 'SSC CGL Tier-1', _each([(_r, 25), (_g, 25), (_q, 25), (_e, 25)], 2, 0.5),
      minutes: 60, stage: 'Tier-1'),
  ExamPattern('ssc-chsl', 'SSC CHSL Tier-1', _each([(_e, 25), (_r, 25), (_q, 25), (_g, 25)], 2, 0.5),
      minutes: 60, stage: 'Tier-1'),
  ExamPattern(
    'ssc-mts',
    'SSC MTS',
    [
      // Session I has no negative marking; Session II takes 1 off a wrong answer.
      ..._each([(_q, 20), (_r, 20)], 3, 0),
      ..._each([(_g, 25), (_e, 25)], 3, 1),
    ],
    minutes: 90,
    stage: 'CBE',
  ),
  ExamPattern('ssc-gd', 'SSC GD Constable', _each([(_r, 20), (_g, 20), (_q, 20), (_e, 20)], 2, 0.25),
      minutes: 60, stage: 'CBE'),
  ExamPattern('ssc-cpo', 'SSC CPO Paper-1', _each([(_r, 50), (_g, 50), (_q, 50), (_e, 50)], 1, 0.25),
      minutes: 120, stage: 'Paper-1'),
  ExamPattern('delhi-police-constable', 'Delhi Police Constable',
      _each([(_g, 50), (_r, 25), (_q, 15), (_c, 10)], 1, 0.25), minutes: 90, stage: 'CBE'),
  ExamPattern('ibps-po', 'IBPS PO Prelims', _each([(_e, 30), (_q, 35), (_r, 35)], 1, 0.25), minutes: 60, stage: 'Prelims'),
  ExamPattern('ibps-clerk', 'IBPS Clerk Prelims', _each([(_e, 30), (_q, 35), (_r, 35)], 1, 0.25),
      minutes: 60, stage: 'Prelims'),
  ExamPattern('sbi-po', 'SBI PO Prelims', _each([(_e, 30), (_q, 35), (_r, 35)], 1, 0.25), minutes: 60, stage: 'Prelims'),
  ExamPattern('sbi-clerk', 'SBI Clerk Prelims', _each([(_e, 30), (_q, 35), (_r, 35)], 1, 0.25),
      minutes: 60, stage: 'Prelims'),
  ExamPattern('ibps-rrb-po', 'IBPS RRB PO Prelims', _each([(_r, 40), (_q, 40)], 1, 0.25), minutes: 45, stage: 'Prelims'),
  ExamPattern('ibps-rrb-clerk', 'IBPS RRB Clerk Prelims', _each([(_r, 40), (_q, 40)], 1, 0.25),
      minutes: 45, stage: 'Prelims'),
  ExamPattern('rbi-assistant', 'RBI Assistant Prelims', _each([(_e, 30), (_q, 35), (_r, 35)], 1, 0.25),
      minutes: 60, stage: 'Prelims'),
  ExamPattern('niacl-assistant', 'NIACL Assistant Prelims', _each([(_e, 30), (_r, 35), (_q, 35)], 1, 0.25),
      minutes: 60, stage: 'Prelims'),
  ExamPattern('rrb-ntpc-graduate', 'RRB NTPC CBT-1', _each([(_q, 30), (_r, 30), (_g, 40)], 1, _third),
      minutes: 90, stage: 'CBT-1'),
  ExamPattern('rrb-ntpc-ug', 'RRB NTPC (UG) CBT-1', _each([(_q, 30), (_r, 30), (_g, 40)], 1, _third),
      minutes: 90, stage: 'CBT-1'),
  ExamPattern('rrb-group-d', 'RRB Group D', _each([(_q, 25), (_r, 30), (_s, 25), (_g, 20)], 1, _third),
      minutes: 90, stage: 'CBT'),
  ExamPattern('rrb-alp', 'RRB ALP CBT-1', _each([(_q, 20), (_r, 25), (_s, 20), (_g, 10)], 1, _third),
      minutes: 60, stage: 'CBT-1'),
  ExamPattern('rrb-je', 'RRB JE CBT-1', _each([(_q, 30), (_r, 25), (_g, 15), (_s, 30)], 1, _third),
      minutes: 90, stage: 'CBT-1'),
  ExamPattern('rpf-constable', 'RPF Constable', _each([(_g, 50), (_q, 35), (_r, 35)], 1, _third),
      minutes: 90, stage: 'CBT'),
];

ExamPattern? patternById(String id) => kExamPatterns.where((p) => p.id == id).firstOrNull;

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// The mock for [app]: its exam's pattern, for the stage it tracks (an exam
/// tracked at a later stage, say Tier-2, has none).
ExamPattern? patternFor(TrackedApplication app) {
  final exam = app.catalogExam;
  if (exam == null) return null;
  final stage = app.tierName;
  for (final p in kExamPatterns) {
    if (p.examId != exam.id) continue;
    if (stage == null || p.stage == null || _norm(stage) == _norm(p.stage!)) return p;
  }
  return null;
}
