/// The mistake notebook: every question you got wrong comes back after 1, 3 and
/// 7 days, and leaves once you get it right the third time in a row. A wrong
/// answer on the way sends it back to the start. Pure (no I/O).
library;

import 'package:flutter/foundation.dart';

import 'practice.dart';

/// Days until the next go, by how many times in a row it was right since.
const kMistakeGaps = [1, 3, 7];

@immutable
class MistakeCard {
  const MistakeCard({required this.question, required this.step, required this.due, required this.misses});

  /// The question as it was asked (made ones can't be made again).
  final PracticeQuestion question;

  /// Right answers in a row since the last miss (0..2); a 3rd clears it.
  final int step;
  final DateTime due;

  /// Times got wrong in all.
  final int misses;

  bool dueOn(DateTime now) => !due.isAfter(now);

  Map<String, Object?> toJson() =>
      {'q': question.toJson(), 'step': step, 'due': due.toIso8601String(), 'm': misses};

  static MistakeCard? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final q = PracticeQuestion.fromStored(j['q']);
    final due = DateTime.tryParse(j['due'] as String? ?? '');
    if (q == null || due == null) return null;
    return MistakeCard(
        question: q, step: (j['step'] as num?)?.toInt() ?? 0, due: due, misses: (j['m'] as num?)?.toInt() ?? 1);
  }
}

DateTime _day(DateTime t, int plus) => DateTime(t.year, t.month, t.day + plus);

/// Questions identical in wording are the same mistake (a made question gets a
/// new id every time).
String mistakeKey(PracticeQuestion q) => q.fromBank ? q.id : '${q.section.name}:${q.text}';

/// The notebook after a test: wrong answers go in (or back to the start); in a
/// redo ([review]), right ones move on and the third leaves. Skipped questions
/// change nothing. Kept to [keep], the most recent mistakes.
List<MistakeCard> updateMistakes(
  List<MistakeCard> cards,
  List<PracticeQuestion> questions,
  List<int?> chosen, {
  required DateTime now,
  required bool review,
  int keep = 300,
}) {
  final byKey = {for (final c in cards) mistakeKey(c.question): c};
  for (final (i, q) in questions.indexed) {
    final c = i < chosen.length ? chosen[i] : null;
    if (c == null) continue;
    final key = mistakeKey(q);
    final card = byKey[key];
    if (c != q.answer) {
      byKey.remove(key); // re-added last: the newest mistake
      byKey[key] = MistakeCard(
        question: (card?.question ?? q).marked(1, kWrongPenalty),
        step: 0,
        due: _day(now, kMistakeGaps[0]),
        misses: (card?.misses ?? 0) + 1,
      );
    } else if (card != null && review) {
      final step = card.step + 1;
      if (step >= kMistakeGaps.length) {
        byKey.remove(key);
      } else {
        byKey[key] = MistakeCard(question: card.question, step: step, due: _day(now, kMistakeGaps[step]), misses: card.misses);
      }
    }
  }
  final all = byKey.values.toList();
  return all.length > keep ? all.sublist(all.length - keep) : all;
}

/// Due now, the longest-waiting first, at most [max].
List<MistakeCard> dueMistakes(List<MistakeCard> cards, DateTime now, {int max = 15}) {
  final due = [for (final c in cards) if (c.dueOn(now)) c]..sort((a, b) => a.due.compareTo(b.due));
  return due.take(max).toList();
}
