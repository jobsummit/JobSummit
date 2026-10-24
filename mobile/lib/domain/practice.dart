/// Timed sectional tests, as in SSC, bank, RRB and other exams: the sections, a
/// question, a test's plan, its marks, and what your past tests say. Pure (no I/O).
///
/// Maths and reasoning questions are made on the phone (practice_maker.dart), so
/// their answers are right by construction. The other sections come from the
/// question bank the data pipeline builds (practice/<section>.json), where a
/// second AI model answers each question blind and only agreed ones are kept.
library;

import 'dart:math';

import 'package:flutter/foundation.dart';

enum PracticeSection {
  quant('Quantitative aptitude', 'Maths', 'SSC · banks · RRB · CDS', seconds: 45, fromBank: false),
  reasoning('Reasoning', 'Reasoning', 'SSC · banks · RRB', seconds: 36, fromBank: false),
  english('English', 'English', 'SSC · banks · CDS · NDA', seconds: 30),
  gs('General awareness', 'GK', 'SSC · RRB · UPSC · state PSCs', seconds: 24),
  science('General science', 'Science', 'RRB · SSC · state exams', seconds: 24),
  computer('Computer awareness', 'Computer', 'Banks · RRB · SSC', seconds: 24),
  banking('Banking & finance', 'Banking', 'IBPS · SBI · RBI', seconds: 24);

  const PracticeSection(this.title, this.short, this.usedIn, {required this.seconds, this.fromBank = true});

  final String title;
  final String short;

  /// The exams that ask it.
  final String usedIn;

  /// Time per question, about the real exams' pace.
  final int seconds;

  /// From the pipeline's question bank (needs the internet once); else made here.
  final bool fromBank;

  static PracticeSection? byName(String? name) => values.where((s) => s.name == name).firstOrNull;
}

/// The mini mock: a few questions from each of the four sections every exam has.
const kMockSections = [PracticeSection.quant, PracticeSection.reasoning, PracticeSection.english, PracticeSection.gs];
const kMockPerSection = 5;

/// Marks: one for a right answer, a quarter off for a wrong one (SSC and IBPS use
/// the same ratio), nothing for a skip.
const kWrongPenalty = 0.25;

@immutable
class PracticeQuestion {
  const PracticeQuestion({
    required this.id,
    required this.section,
    required this.topic,
    required this.text,
    required this.options,
    required this.answer,
    this.explanation = '',
  });

  final String id;
  final PracticeSection section;
  final String topic;
  final String text;
  final List<String> options;

  /// Index into [options].
  final int answer;
  final String explanation;

  bool get fromBank => section.fromBank;

  /// One question of a bank file: {"id", "t", "q", "o": [4], "a", "x"}. Null when
  /// anything is off (the phone never shows a question it can't mark).
  static PracticeQuestion? fromJson(PracticeSection section, Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final id = j['id'], text = j['q'], options = j['o'], answer = j['a'];
    if (id is! String || text is! String || text.trim().isEmpty || answer is! int) return null;
    if (options is! List || options.length != 4 || options.any((o) => o is! String || o.trim().isEmpty)) return null;
    final opts = [for (final o in options) (o as String).trim()];
    if (answer < 0 || answer > 3 || opts.toSet().length != 4) return null;
    return PracticeQuestion(
      id: id,
      section: section,
      topic: (j['t'] as String?)?.trim().isNotEmpty == true ? (j['t'] as String).trim() : section.short,
      text: text.trim(),
      options: opts,
      answer: answer,
      explanation: (j['x'] as String?)?.trim() ?? '',
    );
  }

  static final _fixedOrder = RegExp(r'\b(no error|of the above|of these|both|all of them|none)\b', caseSensitive: false);

  /// Options in a new order. Questions whose options point at each other ("No
  /// error", "All of the above") keep theirs.
  PracticeQuestion shuffled(Random r) {
    if (options.any(_fixedOrder.hasMatch)) return this;
    final order = [0, 1, 2, 3]..shuffle(r);
    return PracticeQuestion(
      id: id,
      section: section,
      topic: topic,
      text: text,
      options: [for (final i in order) options[i]],
      answer: order.indexOf(answer),
      explanation: explanation,
    );
  }
}

/// What a test will be: one section ([section]), or the mini mock (null).
@immutable
class PracticePlan {
  const PracticePlan.section(PracticeSection this.section, this.count);
  const PracticePlan.mock()
      : section = null,
        count = kMockPerSection * 4;

  final PracticeSection? section;
  final int count;

  bool get isMock => section == null;

  /// History key: the section's name, or "mock".
  String get kind => section?.name ?? 'mock';
  String get title => section?.title ?? 'Mini mock';

  /// Whole minutes, at each section's pace.
  Duration get time {
    final seconds = section == null
        ? kMockSections.fold(0, (sum, s) => sum + s.seconds * kMockPerSection)
        : section!.seconds * count;
    return Duration(minutes: (seconds / 60).ceil());
  }
}

/// A finished test, as kept in the history.
@immutable
class PracticeResult {
  const PracticeResult({
    required this.kind,
    required this.at,
    required this.total,
    required this.right,
    required this.wrong,
    required this.seconds,
    this.topics = const {},
  });

  /// [PracticePlan.kind].
  final String kind;
  final DateTime at;
  final int total;
  final int right;
  final int wrong;

  /// Time taken.
  final int seconds;

  /// Topic -> (right, asked), for weak spots.
  final Map<String, (int, int)> topics;

  int get skipped => total - right - wrong;
  int get answered => right + wrong;
  double get marks => right - wrong * kWrongPenalty;

  /// Marks out of the most there were (0..1; never below 0).
  double get share => total == 0 ? 0 : max(0, marks) / total;

  /// Right out of answered.
  double get accuracy => answered == 0 ? 0 : right / answered;

  /// Half the questions or more answered: counts for XP (submitting a blank test
  /// earns nothing).
  bool get counts => answered * 2 >= total;

  Map<String, Object?> toJson() => {
        'k': kind,
        'at': at.toIso8601String(),
        'n': total,
        'r': right,
        'w': wrong,
        's': seconds,
        't': {for (final e in topics.entries) e.key: [e.value.$1, e.value.$2]},
      };

  static PracticeResult? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final at = DateTime.tryParse(j['at'] as String? ?? '');
    final kind = j['k'];
    if (at == null || kind is! String) return null;
    int n(String key) => (j[key] as num?)?.toInt() ?? 0;
    final topics = <String, (int, int)>{};
    final t = j['t'];
    if (t is Map<String, dynamic>) {
      for (final e in t.entries) {
        final v = e.value;
        if (v is List && v.length == 2 && v[0] is num && v[1] is num) {
          topics[e.key] = ((v[0] as num).toInt(), (v[1] as num).toInt());
        }
      }
    }
    return PracticeResult(kind: kind, at: at, total: n('n'), right: n('r'), wrong: n('w'), seconds: n('s'), topics: topics);
  }
}

/// Marks [chosen] (an option index per question, null = skipped).
PracticeResult grade(PracticePlan plan, List<PracticeQuestion> questions, List<int?> chosen,
    {required DateTime at, required int seconds}) {
  var right = 0, wrong = 0;
  final topics = <String, (int, int)>{};
  for (final (i, q) in questions.indexed) {
    final c = i < chosen.length ? chosen[i] : null;
    final ok = c == q.answer;
    if (c != null) ok ? right++ : wrong++;
    final (r, n) = topics[q.topic] ?? (0, 0);
    topics[q.topic] = (r + (ok ? 1 : 0), n + 1);
  }
  return PracticeResult(
      kind: plan.kind, at: at, total: questions.length, right: right, wrong: wrong, seconds: seconds, topics: topics);
}

/// "7.75" / "8" / "−0.5"
String marksText(double marks) {
  final s = marks == marks.roundToDouble() ? marks.toStringAsFixed(0) : '$marks';
  return s.startsWith('-') ? '−${s.substring(1)}' : s;
}

/// What your tests of one kind add up to.
@immutable
class PracticeStats {
  const PracticeStats({required this.tests, this.best, this.last, this.weakTopic});

  final int tests;

  /// The best score's share of full marks.
  final double? best;
  final PracticeResult? last;

  /// The topic you get wrong most (over the recent tests, with enough asked).
  final String? weakTopic;
}

/// Stats for one [kind] from the history (newest last). The weak spot is read
/// from the last 10 tests, and needs 4 questions asked and under 60% right.
PracticeStats practiceStats(String kind, List<PracticeResult> history) {
  final mine = [for (final r in history) if (r.kind == kind) r];
  if (mine.isEmpty) return const PracticeStats(tests: 0);
  final tally = <String, (int, int)>{};
  for (final r in mine.skip(max(0, mine.length - 10))) {
    for (final e in r.topics.entries) {
      final (a, b) = tally[e.key] ?? (0, 0);
      tally[e.key] = (a + e.value.$1, b + e.value.$2);
    }
  }
  String? weak;
  var worst = 0.6;
  for (final e in tally.entries) {
    final (right, asked) = e.value;
    if (asked < 4) continue;
    final rate = right / asked;
    if (rate < worst) {
      worst = rate;
      weak = e.key;
    }
  }
  return PracticeStats(
    tests: mine.length,
    best: mine.map((r) => r.share).reduce(max),
    last: mine.last,
    weakTopic: weak,
  );
}

/// [n] bank questions: unseen ones first (topics taken in turn, so one test isn't
/// all synonyms), then the ones seen longest ago. [seen] is oldest first. Hidden
/// (reported) ones never come back.
List<PracticeQuestion> pickFromBank(
  List<PracticeQuestion> bank,
  int n, {
  required List<String> seen,
  required Set<String> hidden,
  required Random random,
}) {
  final usable = [for (final q in bank) if (!hidden.contains(q.id)) q];
  final seenAt = {for (final (i, id) in seen.indexed) id: i};
  final fresh = [for (final q in usable) if (!seenAt.containsKey(q.id)) q]..shuffle(random);
  final byTopic = <String, List<PracticeQuestion>>{};
  for (final q in fresh) {
    (byTopic[q.topic] ??= []).add(q);
  }
  final picked = <PracticeQuestion>[];
  final topics = byTopic.keys.toList()..shuffle(random);
  while (picked.length < n && byTopic.values.any((l) => l.isNotEmpty)) {
    for (final t in topics) {
      final list = byTopic[t]!;
      if (list.isNotEmpty && picked.length < n) picked.add(list.removeLast());
    }
  }
  if (picked.length < n) {
    final old = [for (final q in usable) if (seenAt.containsKey(q.id)) q]
      ..sort((a, b) => seenAt[a.id]!.compareTo(seenAt[b.id]!));
    picked.addAll(old.take(n - picked.length));
  }
  return [for (final q in picked) q.shuffled(random)];
}
