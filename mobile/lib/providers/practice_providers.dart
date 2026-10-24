import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// The questions for [plan]. Bank questions are marked seen as the test starts,
/// so starting again brings new ones. Fewer than planned when the bank is short
/// (the mock then fills up with maths and reasoning).
Future<List<PracticeQuestion>> buildPracticeTest(PracticeBank bank, PracticePlan plan, {Random? random}) async {
  final r = random ?? Random();
  Future<List<PracticeQuestion>> part(PracticeSection s, int n) async {
    if (!s.fromBank) return makeQuestions(s, n, r);
    final picked = pickFromBank(await bank.load(s), n,
        seen: await PracticeStore.seen(s), hidden: await PracticeStore.hidden(), random: r);
    await PracticeStore.markSeen(s, picked.map((q) => q.id));
    return picked;
  }

  final section = plan.section;
  if (section != null) return part(section, plan.count);
  final out = <PracticeQuestion>[];
  for (final s in kMockSections) {
    final got = await part(s, kMockPerSection);
    out.addAll(got);
    // A bank section not downloaded yet: its share goes to maths and reasoning.
    final short = kMockPerSection - got.length;
    if (short > 0) {
      out.addAll(makeQuestions(PracticeSection.reasoning, (short + 1) ~/ 2, r));
      out.addAll(makeQuestions(PracticeSection.quant, short ~/ 2, r));
    }
  }
  return out;
}
