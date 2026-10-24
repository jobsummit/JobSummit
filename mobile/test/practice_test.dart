import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:exam_tracker/domain/practice.dart';
import 'package:exam_tracker/domain/practice_maker.dart';
import 'package:exam_tracker/services/practice_bank.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

PracticeQuestion bankQ(String id, String topic, {List<String>? options}) => PracticeQuestion(
      id: id,
      section: PracticeSection.english,
      topic: topic,
      text: 'Question $id',
      options: options ?? ['a$id', 'b$id', 'c$id', 'd$id'],
      answer: 1,
    );

/// Every made question of [topic] over many seeds (tries that don't come out whole are skipped).
List<PracticeQuestion> many(PracticeSection s, String topic, {int seeds = 400}) => [
      for (var seed = 0; seed < seeds; seed++)
        if (makeOne(s, topic, Random(seed)) case final q?) q,
    ];

String key(PracticeQuestion q) => q.options[q.answer];

int num(String s) => int.parse(s.replaceAll(RegExp(r'[^0-9]'), ''));

void main() {
  group('made questions', () {
    for (final s in [PracticeSection.quant, PracticeSection.reasoning]) {
      for (final topic in madeTopics(s)) {
        test('${s.short} · $topic: four different options, one key, an explanation', () {
          final qs = many(s, topic);
          expect(qs.length, greaterThan(60), reason: 'enough tries should come out whole');
          for (final q in qs) {
            expect(q.options.toSet().length, 4, reason: q.text);
            expect(q.answer, inInclusiveRange(0, 3));
            expect(q.text.trim(), isNotEmpty);
            expect(q.explanation.trim(), isNotEmpty, reason: q.text);
            expect(q.options.every((o) => o.trim().isNotEmpty && !o.contains('NaN') && !o.contains('Infinity')), isTrue,
                reason: '${q.text} ${q.options}');
            final zero = RegExp(r'^₹?0(%|°| |$)|^−');
            if (!zero.hasMatch(key(q))) expect(q.options.where(zero.hasMatch), isEmpty, reason: '${q.options}');
          }
        });
      }
    }

    test('a whole test: as many as asked, no repeats, topics in turn', () {
      final qs = makeQuestions(PracticeSection.quant, 25, Random(7));
      expect(qs.length, 25);
      expect(qs.map((q) => q.text).toSet().length, 25);
      expect(qs.map((q) => q.topic).toSet().length, madeTopics(PracticeSection.quant).length);
    });

    // The keys, worked out again here from the question's own words.
    test('percent of a number', () {
      for (final q in many(PracticeSection.quant, 'Percentage')) {
        final m = RegExp(r'What is (\d+)% of ([\d,]+)\?').firstMatch(q.text);
        if (m == null) continue;
        expect(num(key(q)), int.parse(m[1]!) * num(m[2]!) ~/ 100, reason: q.text);
      }
    });

    test('simple interest', () {
      for (final q in many(PracticeSection.quant, 'Simple interest')) {
        final m = RegExp(r'on ₹([\d,]+) at (\d+)% a year for (\d+) years').firstMatch(q.text)!;
        expect(num(key(q)), num(m[1]!) * int.parse(m[2]!) * int.parse(m[3]!) ~/ 100, reason: q.text);
      }
    });

    test('compound interest, two years', () {
      for (final q in many(PracticeSection.quant, 'Compound interest')) {
        final m = RegExp(r'on ₹([\d,]+) at (\d+)%').firstMatch(q.text)!;
        final p = num(m[1]!), r = int.parse(m[2]!);
        expect(num(key(q)), closeTo(p * pow(1 + r / 100, 2) - p, 0.001), reason: q.text);
      }
    });

    test('time and work', () {
      for (final q in many(PracticeSection.quant, 'Time & work')) {
        final m = RegExp(r'in (\d+) days and B in (\d+) days').firstMatch(q.text)!;
        final a = int.parse(m[1]!), b = int.parse(m[2]!);
        expect(1 / a + 1 / b, closeTo(1 / num(key(q)), 1e-9), reason: q.text);
      }
    });

    test('ranking in a row', () {
      for (final q in many(PracticeSection.reasoning, 'Ranking')) {
        final both = RegExp(r'(\d+)\w\w from the left and (\d+)\w\w from the right').firstMatch(q.text);
        if (both != null) {
          expect(num(key(q)), int.parse(both[1]!) + int.parse(both[2]!) - 1, reason: q.text);
        } else {
          final m = RegExp(r'row of (\d+) people, \w+ is (\d+)\w\w from the left').firstMatch(q.text)!;
          expect(num(key(q)), int.parse(m[1]!) - int.parse(m[2]!) + 1, reason: q.text);
        }
      }
    });

    test('clock hands', () {
      for (final q in many(PracticeSection.reasoning, 'Clocks')) {
        final m = RegExp(r'at (\d+):(\d\d)\?').firstMatch(q.text)!;
        final h = int.parse(m[1]!), min = int.parse(m[2]!);
        final hour = (h % 12) * 30 + min * 0.5, minute = min * 6.0;
        var angle = (hour - minute).abs();
        if (angle > 180) angle = 360 - angle;
        expect(double.parse(key(q).replaceAll('°', '')), closeTo(angle, 0.01), reason: q.text);
      }
    });

    test('calendar', () {
      const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', //
        'October', 'November', 'December'];
      const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
      for (final q in many(PracticeSection.reasoning, 'Calendar')) {
        final m = RegExp(r'If (\d+) (\w+) is a (\w+), what day of the week is (\d+) (\w+) of').firstMatch(q.text)!;
        // 2025 isn't a leap year, and neither month is February: any such year works.
        final from = DateTime(2025, months.indexOf(m[2]!) + 1, int.parse(m[1]!));
        final to = DateTime(2025, months.indexOf(m[5]!) + 1, int.parse(m[4]!));
        expect(to.isAfter(from), isTrue, reason: q.text);
        final shift = to.difference(from).inDays % 7;
        expect(key(q), days[(days.indexOf(m[3]!) + shift) % 7], reason: q.text);
      }
    });

    test('directions: walked again step by step', () {
      const dirs = {'North': (0, 1), 'East': (1, 0), 'South': (0, -1), 'West': (-1, 0)};
      const order = ['North', 'East', 'South', 'West'];
      for (final q in many(PracticeSection.reasoning, 'Directions')) {
        var h = order.indexOf(RegExp(r'walks \d+ km (\w+)').firstMatch(q.text)![1]!);
        var x = 0, y = 0;
        final first = RegExp(r'walks (\d+) km \w+').firstMatch(q.text)!;
        x += dirs[order[h]]!.$1 * int.parse(first[1]!);
        y += dirs[order[h]]!.$2 * int.parse(first[1]!);
        for (final t in RegExp(r'turns (right|left) and walks (\d+) km').allMatches(q.text)) {
          h = (h + (t[1] == 'right' ? 1 : 3)) % 4;
          x += dirs[order[h]]!.$1 * int.parse(t[2]!);
          y += dirs[order[h]]!.$2 * int.parse(t[2]!);
        }
        final where = [if (y > 0) 'North', if (y < 0) 'South', if (x > 0) 'East', if (x < 0) 'West'].join('-');
        expect(key(q), '${sqrt(x * x + y * y).round()} km $where', reason: q.text);
      }
    });

    test('coding: the same letter shift (or mirror) as the example', () {
      for (final q in many(PracticeSection.reasoning, 'Coding-decoding')) {
        final m = RegExp(r'code, (\w+) is written as (\w+)\. How is (\w+) written').firstMatch(q.text)!;
        final (w1, c1, w2) = (m[1]!, m[2]!, m[3]!);
        final mirror = String.fromCharCodes(w1.codeUnits.map((c) => 155 - c)) == c1;
        final k = (c1.codeUnitAt(0) - w1.codeUnitAt(0)) % 26;
        final expected = String.fromCharCodes(
            w2.codeUnits.map((c) => mirror ? 155 - c : 65 + (c - 65 + k) % 26));
        expect(key(q), expected, reason: q.text);
      }
    });

    test('symbols swapped, then × and ÷ before + and −', () {
      for (final q in many(PracticeSection.reasoning, 'Symbols & operations')) {
        final meaning = {
          for (final m in RegExp(r'‘(.)’ means ‘(.)’').allMatches(q.text)) m[1]!: m[2]!,
        };
        final expr = RegExp(r'what is (.*)\?').firstMatch(q.text)![1]!.split(' ');
        final tokens = [for (final t in expr) meaning[t] ?? t];
        // × and ÷ left to right, then + and −.
        final nums = <double>[double.parse(tokens[0])];
        final signs = <String>[];
        for (var i = 1; i < tokens.length; i += 2) {
          final n = double.parse(tokens[i + 1]);
          switch (tokens[i]) {
            case '×':
              nums.last *= n;
            case '÷':
              nums.last /= n;
            default:
              signs.add(tokens[i]);
              nums.add(n);
          }
        }
        var total = nums[0];
        for (var i = 0; i < signs.length; i++) {
          total += signs[i] == '+' ? nums[i + 1] : -nums[i + 1];
        }
        expect(num(key(q)), total, reason: q.text);
      }
    });

    test('dictionary order', () {
      for (final q in many(PracticeSection.reasoning, 'Dictionary order')) {
        final m = RegExp(r'comes (\d+)\w\w in dictionary order\? (.*)$').firstMatch(q.text)!;
        final words = m[2]!.split(', ')..sort();
        expect(key(q), words[int.parse(m[1]!) - 1]);
      }
    });

    test('number series: the shown terms follow the explained rule', () {
      for (final q in many(PracticeSection.reasoning, 'Number series')) {
        final terms = RegExp(r'next\? (.*), \?').firstMatch(q.text)![1]!.split(', ').map(num).toList();
        if (q.explanation.startsWith('Each term adds')) {
          final d = terms[1] - terms[0];
          expect(num(key(q)), terms.last + d, reason: q.text);
        }
        if (q.explanation.contains('times the one before')) {
          expect(num(key(q)), terms.last * (terms[1] ~/ terms[0]), reason: q.text);
        }
      }
    });
  });

  group('marks', () {
    test('+1 right, −¼ wrong, 0 skipped', () {
      final qs = [for (var i = 0; i < 4; i++) bankQ('$i', i < 2 ? 'Idioms' : 'Synonyms')];
      final r = grade(const PracticePlan.section(PracticeSection.english, 4), qs, [1, 0, null, 1],
          at: DateTime(2026, 10, 24), seconds: 90);
      expect((r.right, r.wrong, r.skipped), (2, 1, 1));
      expect(r.marks, 1.75);
      expect(marksText(r.marks), '1.75');
      expect(r.topics, {'Idioms': (1, 2), 'Synonyms': (1, 2)});
      expect(r.counts, isTrue);
      expect(marksText(-0.5), '−0.5');
    });

    test('a test with under half answered earns no XP', () {
      final qs = [for (var i = 0; i < 10; i++) bankQ('$i', 'Idioms')];
      final r = grade(const PracticePlan.section(PracticeSection.english, 10), qs, [1, 1, 1, 1, ...List.filled(6, null)],
          at: DateTime(2026), seconds: 10);
      expect(r.counts, isFalse);
    });

    test('times follow each section’s pace, in whole minutes', () {
      expect(const PracticePlan.section(PracticeSection.quant, 10).time.inMinutes, 8);
      expect(const PracticePlan.section(PracticeSection.gs, 25).time.inMinutes, 10);
      expect(const PracticePlan.mock().count, 20);
      expect(const PracticePlan.mock().time.inMinutes, 12);
    });

    test('a result survives saving', () {
      final r = PracticeResult(
          kind: 'quant', at: DateTime(2026, 10, 24, 9), total: 10, right: 6, wrong: 2, seconds: 300,
          topics: const {'Ages': (1, 2)});
      final back = PracticeResult.fromJson(jsonDecode(jsonEncode(r.toJson())))!;
      expect((back.kind, back.at, back.total, back.right, back.wrong, back.seconds),
          (r.kind, r.at, r.total, r.right, r.wrong, r.seconds));
      expect(back.topics, r.topics);
    });

    test('best score and the topic to work on', () {
      PracticeResult res(int right, Map<String, (int, int)> topics) => PracticeResult(
          kind: 'quant', at: DateTime(2026), total: 10, right: right, wrong: 10 - right, seconds: 1, topics: topics);
      final stats = practiceStats('quant', [
        res(6, {'Ages': (1, 3), 'Ratio': (3, 3)}),
        res(8, {'Ages': (1, 2), 'Ratio': (2, 2)}),
        PracticeResult(kind: 'english', at: DateTime(2026), total: 10, right: 10, wrong: 0, seconds: 1),
      ]);
      expect(stats.tests, 2);
      expect(stats.best, closeTo((8 - 2 * 0.25) / 10, 1e-9));
      expect(stats.weakTopic, 'Ages');
      expect(practiceStats('gs', const []).tests, 0);
    });
  });

  group('bank questions', () {
    test('a bad entry is dropped, never shown', () {
      final ok = {'id': 'x1', 't': 'Idioms', 'q': 'Pick one', 'o': ['a', 'b', 'c', 'd'], 'a': 2, 'x': 'Because.'};
      expect(PracticeQuestion.fromJson(PracticeSection.english, ok)?.answer, 2);
      for (final bad in [
        {...ok, 'a': 4},
        {...ok, 'o': ['a', 'b', 'c']},
        {...ok, 'o': ['a', 'a', 'c', 'd']},
        {...ok, 'q': ' '},
        {...ok, 'a': '2'},
      ]) {
        expect(PracticeQuestion.fromJson(PracticeSection.english, bad), isNull, reason: '$bad');
      }
    });

    test('shuffling keeps the key; "No error" questions keep their order', () {
      final q = bankQ('1', 'Synonyms');
      for (var seed = 0; seed < 20; seed++) {
        final s = q.shuffled(Random(seed));
        expect(s.options[s.answer], q.options[q.answer]);
      }
      final fixed = bankQ('2', 'Spot the error', options: ['He go', 'to school', 'every day', 'No error']);
      expect(fixed.shuffled(Random(3)).options, fixed.options);
    });

    test('unseen first, topics in turn, reported never, then the oldest seen', () {
      final bank = [
        for (var i = 0; i < 6; i++) bankQ('s$i', 'Synonyms'),
        for (var i = 0; i < 2; i++) bankQ('i$i', 'Idioms'),
      ];
      final picked = pickFromBank(bank, 4, seen: const ['s0', 's1', 's2'], hidden: {'s3'}, random: Random(1));
      final ids = picked.map((q) => q.id).toSet();
      expect(ids, containsAll(['i0', 'i1'])); // both idioms: topics take turns
      expect(ids, isNot(contains('s3')));
      expect(ids.intersection({'s0', 's1', 's2'}), isEmpty);

      final more = pickFromBank(bank, 7, seen: const ['s0', 's1', 's2'], hidden: {'s3'}, random: Random(1));
      expect(more.map((q) => q.id).toSet(), {'s4', 's5', 'i0', 'i1', 's0', 's1', 's2'});
      final again = pickFromBank(bank, 6, seen: const ['s2', 's0', 's1'], hidden: {'s3'}, random: Random(1));
      expect(again.map((q) => q.id), containsAll(['s2', 's0'])); // the two seen longest ago
      expect(again.map((q) => q.id), isNot(contains('s1')));
    });
  });

  group('bank download', () {
    late Directory dir;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dir = await Directory.systemTemp.createTemp('practice_bank_test');
    });
    tearDown(() => dir.delete(recursive: true));

    String file(int n) => jsonEncode({
          'section': 'english',
          'questions': [
            for (var i = 0; i < n; i++) {'id': 'q$i', 't': 'Idioms', 'q': 'Q$i', 'o': ['a', 'b', 'c', 'd'], 'a': 0},
          ],
        });

    test('downloads once, then the saved copy for a day; offline still works', () async {
      var calls = 0;
      var online = true;
      final client = MockClient((req) async {
        calls++;
        if (!online) throw const SocketException('offline');
        expect(req.url.toString(), 'https://data.example/practice/english.json');
        return http.Response(file(3), 200, headers: {'etag': '"v1"'});
      });
      final bank = PracticeBank(client: client, bases: const ['https://data.example'], dir: dir);
      final now = DateTime(2026, 10, 24, 9);
      expect((await bank.load(PracticeSection.english, now: now)).length, 3);
      expect((await bank.load(PracticeSection.english, now: now.add(const Duration(hours: 5)))).length, 3);
      expect(calls, 1);
      online = false;
      expect((await bank.load(PracticeSection.english, now: now.add(const Duration(days: 2)))).length, 3);
      expect(calls, 2);
    });

    test('unchanged (304) keeps the saved copy; nothing yet and offline is empty', () async {
      final client = MockClient((req) async => req.headers['If-None-Match'] == '"v1"'
          ? http.Response('', 304)
          : http.Response(file(2), 200, headers: {'etag': '"v1"'}));
      final bank = PracticeBank(client: client, bases: const ['https://data.example'], dir: dir);
      final now = DateTime(2026, 10, 24);
      expect((await bank.load(PracticeSection.english, now: now)).length, 2);
      expect((await bank.load(PracticeSection.english, now: now.add(const Duration(days: 1)))).length, 2);

      final offline = PracticeBank(
          client: MockClient((_) async => throw const SocketException('offline')),
          bases: const ['https://data.example'],
          dir: dir);
      expect(await offline.load(PracticeSection.gs, now: now), isEmpty);
    });
  });
}
