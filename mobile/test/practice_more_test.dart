import 'dart:convert';
import 'dart:math';

import 'package:exam_tracker/domain/exam_patterns.dart';
import 'package:exam_tracker/domain/mistakes.dart';
import 'package:exam_tracker/domain/practice.dart';
import 'package:exam_tracker/domain/widget_summary.dart';
import 'package:exam_tracker/models/tracked_application.dart';
import 'package:exam_tracker/providers/practice_providers.dart';
import 'package:exam_tracker/services/practice_bank.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

PracticeQuestion q(String id, {PracticeSection section = PracticeSection.english, String? week}) => PracticeQuestion(
      id: id,
      section: section,
      topic: 'Idioms',
      text: 'Question $id',
      options: ['a$id', 'b$id', 'c$id', 'd$id'],
      answer: 1,
      week: week,
    );

/// A bank that is always [questions], whatever the section.
class FakeBank extends PracticeBank {
  FakeBank(this.questions);

  final List<PracticeQuestion> questions;

  @override
  Future<List<PracticeQuestion>> load(PracticeSection s, {DateTime? now}) async =>
      [for (final x in questions) PracticeQuestion.fromStored({...x.toJson(), 's': s.name})!];
}

TrackedApplication app(String exam, {List<String> tiers = const [], int tier = 0}) => TrackedApplication(
      id: exam,
      examName: exam,
      postName: '',
      status: ApplicationStatus.applied,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      tiers: tiers,
      tier: tier,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('mistake notebook', () {
    final now = DateTime(2026, 10, 24, 9);

    test('a wrong answer comes back tomorrow, then after 3 and 7 days, then leaves', () {
      final qs = [q('1'), q('2'), q('3')];
      var cards = updateMistakes(const [], qs, [0, 1, null], now: now, review: false);
      expect(cards.map((c) => c.question.id), ['1']); // right and skipped don't go in
      expect(cards.single.due, DateTime(2026, 10, 25));
      expect(dueMistakes(cards, now), isEmpty);
      expect(dueMistakes(cards, DateTime(2026, 10, 25, 8)).single.question.id, '1');

      var day = DateTime(2026, 10, 25, 8);
      for (final (gap, left) in [(3, 1), (7, 1), (0, 0)]) {
        cards = updateMistakes(cards, [q('1')], [1], now: day, review: true);
        expect(cards.length, left);
        if (left == 1) {
          expect(cards.single.due, DateTime(day.year, day.month, day.day + gap));
          day = cards.single.due;
        }
      }
    });

    test('wrong again: back to the start, and a right answer outside a redo moves nothing', () {
      var cards = updateMistakes(const [], [q('1')], [0], now: now, review: false);
      cards = updateMistakes(cards, [q('1')], [1], now: DateTime(2026, 10, 25), review: true); // step 1
      cards = updateMistakes(cards, [q('1')], [2], now: DateTime(2026, 10, 28), review: true);
      expect((cards.single.step, cards.single.misses, cards.single.due), (0, 2, DateTime(2026, 10, 29)));
      final same = updateMistakes(cards, [q('1')], [1], now: DateTime(2026, 10, 29), review: false);
      expect(same.single.step, 0);
    });

    test('made questions are matched by their words, and cards survive saving', () {
      const made = PracticeQuestion(
          id: 'gen-1', section: PracticeSection.quant, topic: 'Ages', text: 'How old?', options: ['1', '2', '3', '4'], answer: 2);
      const again = PracticeQuestion(
          id: 'gen-2', section: PracticeSection.quant, topic: 'Ages', text: 'How old?', options: ['1', '2', '3', '4'], answer: 2);
      var cards = updateMistakes(const [], [made], [0], now: now, review: false);
      cards = updateMistakes(cards, [again], [1], now: now, review: false);
      expect(cards.single.misses, 2);
      final back = MistakeCard.fromJson(jsonDecode(jsonEncode(cards.single.toJson())))!;
      expect((back.question.text, back.question.section, back.question.answer, back.misses), ('How old?', PracticeSection.quant, 2, 2));
    });

    test('a redo test brings the due cards', () async {
      final cards = updateMistakes(const [], [q('1'), q('2')], [0, 0], now: now, review: false);
      final test = await buildPracticeTest(FakeBank(const []), PracticePlan.review(15),
          mistakes: cards, now: DateTime(2026, 10, 26), random: Random(1));
      expect(test.map((x) => x.id).toSet(), {'1', '2'});
    });
  });

  group('Daily 10', () {
    test('the same ten on every phone for a day, new ones the next day', () async {
      final bank = FakeBank([for (var i = 0; i < 40; i++) q('$i')]);
      Future<List<String>> day(DateTime d, int seed) async => [
            for (final x in await buildPracticeTest(bank, PracticePlan.daily(d), random: Random(seed)))
              '${x.text} ${x.options.join('|')} ${x.answer}',
          ];
      final a = await day(DateTime(2026, 10, 24, 7), 1);
      final b = await day(DateTime(2026, 10, 24, 22), 99);
      expect(a.length, 10);
      expect(a, b);
      expect(await day(DateTime(2026, 10, 25), 1), isNot(a));
    });

    test('with no bank yet, still ten (maths and reasoning)', () async {
      final test = await buildPracticeTest(FakeBank(const []), PracticePlan.daily(DateTime(2026, 10, 24)));
      expect(test.length, 10);
      expect(test.every((x) => !x.fromBank), isTrue);
    });

    test('done today, the streak, and the widget line', () {
      PracticeResult r(DateTime at, int right) =>
          PracticeResult(kind: 'daily', at: at, total: 10, right: right, wrong: 0, seconds: 200);
      final history = [r(DateTime(2026, 10, 22, 8), 6), r(DateTime(2026, 10, 23, 8), 7)];
      final now = DateTime(2026, 10, 24, 9);
      expect(dailyDoneOn(now, history), isNull);
      expect(dailyStreak(now, history), 2); // today not done yet doesn't break it
      expect(widgetSummary(const [], now, practice: history).daily, 'Daily 10 is ready · 2 days in a row');
      final more = [...history, r(DateTime(2026, 10, 24, 8), 8)];
      expect(dailyStreak(now, more), 3);
      expect(widgetSummary(const [], now, practice: more).daily, 'Daily 10 done · 8/10 · 3 days in a row');
      expect(dailyStreak(DateTime(2026, 10, 26), more), 0);
    });
  });

  group('exam patterns', () {
    test('every pattern adds up and has a time', () {
      for (final p in kExamPatterns) {
        expect(p.count, greaterThan(0), reason: p.name);
        expect(p.minutes, greaterThan(0), reason: p.name);
        expect(patternById(p.id), same(p));
      }
      final cgl = patternById('ssc-cgl-tier-1')!;
      expect((cgl.count, cgl.maxMarks, cgl.minutes, cgl.marking), (100, 200.0, 60, '+2 · −½'));
      expect(patternById('rrb-group-d-cbt')!.marking, '+1 · −⅓');
      expect(patternById('ssc-mts-cbe')!.marking, isNull); // two sessions, two schemes
    });

    test('the mock for the stage you track, none for a later one', () {
      expect(patternFor(app('SSC CGL 2026', tiers: ['Tier-1', 'Tier-2']))?.name, 'SSC CGL Tier-1');
      expect(patternFor(app('SSC CGL 2026', tiers: ['Tier-1', 'Tier-2'], tier: 1)), isNull);
      expect(patternFor(app('IBPS PO 2026'))?.name, 'IBPS PO Prelims');
      expect(patternFor(app('UPSC Civil Services 2026')), isNull);
    });

    test('a mock is marked with its exam’s scheme', () async {
      final p = patternById('ssc-cgl-tier-1')!;
      final test = await buildPracticeTest(FakeBank([for (var i = 0; i < 60; i++) q('$i')]), p.plan, random: Random(3));
      expect(test.length, 100);
      final chosen = [for (final (i, x) in test.indexed) i < 10 ? x.answer : (i < 14 ? (x.answer + 1) % 4 : null)];
      final r = grade(p.plan, test, chosen, at: DateTime(2026), seconds: 100);
      expect((r.right, r.wrong, r.marks, r.maxMarks), (10, 4, 18.0, 200.0));
      expect(PracticeResult.fromJson(jsonDecode(jsonEncode(r.toJson())))!.marks, 18.0);
      expect(marksText(1 - 2 / 3), '0.33');
    });
  });

  test('current affairs: this fortnight’s news first', () {
    final bank = [
      for (var i = 0; i < 12; i++) q('new$i', section: PracticeSection.current, week: '2026-10-19'),
      for (var i = 0; i < 12; i++) q('old$i', section: PracticeSection.current, week: '2026-09-07'),
    ];
    expect(newestWeeksFirst(bank, weeks: 1).every((x) => x.week == '2026-10-19'), isTrue);
    expect(newestWeeksFirst(bank.sublist(8), weeks: 1).length, 16); // too few new ones: all
  });
}
