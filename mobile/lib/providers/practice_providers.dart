import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/mistakes.dart';
import '../domain/practice.dart';
import '../domain/practice_maker.dart';
import '../services/practice_bank.dart';
import '../services/practice_store.dart';

final practiceBankProvider = Provider<PracticeBank>((ref) => PracticeBank());

/// Your past tests on this phone, newest last.
class PracticeHistoryNotifier extends AsyncNotifier<List<PracticeResult>> {
  @override
  Future<List<PracticeResult>> build() => PracticeStore.history();

  Future<void> add(PracticeResult result) async {
    state = AsyncData(await PracticeStore.add(result));
  }
}

final practiceHistoryProvider =
    AsyncNotifierProvider<PracticeHistoryNotifier, List<PracticeResult>>(PracticeHistoryNotifier.new);

/// The mistake notebook.
class MistakesNotifier extends AsyncNotifier<List<MistakeCard>> {
  @override
  Future<List<MistakeCard>> build() => PracticeStore.mistakes();

  /// After a test: wrong answers go in; in a redo, right ones move on.
  Future<void> record(List<PracticeQuestion> questions, List<int?> chosen, {required bool review}) async {
    final next = updateMistakes(await future, questions, chosen, now: DateTime.now(), review: review);
    await PracticeStore.saveMistakes(next);
    state = AsyncData(next);
  }
}

final mistakesProvider = AsyncNotifierProvider<MistakesNotifier, List<MistakeCard>>(MistakesNotifier.new);

/// The questions for [plan], each with its section's marks. Bank questions are
/// marked seen as the test starts, so starting again brings new ones. Fewer than
/// planned when the bank is short; the mini mock and the Daily 10 then fill up
/// with maths and reasoning.
Future<List<PracticeQuestion>> buildPracticeTest(
  PracticeBank bank,
  PracticePlan plan, {
  Random? random,
  List<MistakeCard> mistakes = const [],
  DateTime? now,
}) async {
  final r = random ?? Random();
  if (plan.planKind == PlanKind.review) {
    return [for (final c in dueMistakes(mistakes, now ?? DateTime.now(), max: plan.count)) c.question.shuffled(r)];
  }
  final hidden = await PracticeStore.hidden();
  final daily = plan.planKind == PlanKind.daily;
  final seed = daily ? dailySeed(plan.day!) : 0;

  Future<List<PracticeQuestion>> part(PracticeSection s, int n) async {
    if (!s.fromBank) return makeQuestions(s, n, daily ? Random(seed + s.index) : r);
    var questions = await bank.load(s);
    if (s == PracticeSection.current) questions = newestWeeksFirst(questions);
    if (daily) return dailyFromBank(questions, n, seed + s.index, hidden: hidden);
    final picked = pickFromBank(questions, n, seen: await PracticeStore.seen(s), hidden: hidden, random: r);
    await PracticeStore.markSeen(s, picked.map((q) => q.id));
    return picked;
  }

  final out = <PracticeQuestion>[];
  for (final p in plan.parts) {
    final got = await part(p.section, p.count);
    out.addAll([for (final q in got) q.marked(p.plus, p.minus)]);
    // A bank section not downloaded yet: its share goes to maths and reasoning.
    final short = p.count - got.length;
    if (short > 0 && (plan.planKind == PlanKind.mock || daily)) {
      final fill = daily ? Random(seed + 100 + p.section.index) : r;
      out.addAll(makeQuestions(PracticeSection.reasoning, (short + 1) ~/ 2, fill));
      out.addAll(makeQuestions(PracticeSection.quant, short ~/ 2, fill));
    }
  }
  return out;
}
