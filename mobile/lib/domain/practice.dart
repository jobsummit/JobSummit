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
  current('Current affairs', 'Current', 'Every exam’s GK section', seconds: 24),
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

/// The Daily 10: the same ten for everyone on a day.
const kDailyParts = [
  (PracticeSection.quant, 3),
  (PracticeSection.reasoning, 3),
  (PracticeSection.english, 2),
  (PracticeSection.gs, 2),
];

/// Marks: one for a right answer, a quarter off for a wrong one (SSC and IBPS use
/// the same ratio), nothing for a skip. Exam-pattern mocks use their exam's.
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
    this.week,
    this.source,
    this.plus = 1,
    this.minus = kWrongPenalty,
  });

  final String id;
  final PracticeSection section;
  final String topic;
  final String text;
  final List<String> options;

  /// Index into [options].
  final int answer;
  final String explanation;

  /// Current affairs: the week it's from (its Monday, "2026-10-19") and the press
  /// release it was written from.
  final String? week;
  final String? source;

  /// Marks for a right answer, and off for a wrong one.
  final double plus;
  final double minus;

  bool get fromBank => section.fromBank;

  /// One question of a bank file: {"id", "t", "q", "o": [4], "a", "x", "w"?, "src"?}.
  /// Null when anything is off (the phone never shows a question it can't mark).
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
      week: j['w'] as String?,
      source: j['src'] as String?,
    );
  }

  /// Kept on the phone (the mistake notebook), section included.
  Map<String, Object?> toJson() => {
        'id': id,
        's': section.name,
        't': topic,
        'q': text,
        'o': options,
        'a': answer,
        if (explanation.isNotEmpty) 'x': explanation,
        if (week != null) 'w': week,
        if (source != null) 'src': source,
      };

  static PracticeQuestion? fromStored(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final section = PracticeSection.byName(j['s'] as String?);
    return section == null ? null : fromJson(section, j);
  }

  PracticeQuestion _with({List<String>? options, int? answer, double? plus, double? minus}) => PracticeQuestion(
        id: id,
        section: section,
        topic: topic,
        text: text,
        options: options ?? this.options,
        answer: answer ?? this.answer,
        explanation: explanation,
        week: week,
        source: source,
        plus: plus ?? this.plus,
        minus: minus ?? this.minus,
      );

  PracticeQuestion marked(double plus, double minus) => _with(plus: plus, minus: minus);

  static final _fixedOrder = RegExp(r'\b(no error|of the above|of these|both|all of them|none)\b', caseSensitive: false);

  /// Options in a new order. Questions whose options point at each other ("No
  /// error", "All of the above") keep theirs.
  PracticeQuestion shuffled(Random r) {
    if (options.any(_fixedOrder.hasMatch)) return this;
    final order = [0, 1, 2, 3]..shuffle(r);
    return _with(options: [for (final i in order) options[i]], answer: order.indexOf(answer));
  }
}

/// One block of a test: [count] questions of [section], marked +[plus] / −[minus].
@immutable
class PracticePart {
  const PracticePart(this.section, this.count, {this.plus = 1, this.minus = kWrongPenalty});

  final PracticeSection section;
  final int count;
  final double plus;
  final double minus;
}

enum PlanKind { section, mock, daily, review, pattern }

/// What a test will be.
@immutable
class PracticePlan {
  const PracticePlan._(this.planKind, this.title, this.parts, {this.minutes, this.day, this.key});

  /// One section on its own.
  PracticePlan.section(PracticeSection section, int count)
      : this._(PlanKind.section, section.title, [PracticePart(section, count)]);

  /// The mini mock: [kMockPerSection] from each of [kMockSections].
  PracticePlan.mock()
      : this._(PlanKind.mock, 'Mini mock', [for (final s in kMockSections) PracticePart(s, kMockPerSection)]);

  /// The Daily 10 for [day] (its questions follow from the date).
  PracticePlan.daily(DateTime day)
      : this._(PlanKind.daily, 'Daily 10', [for (final (s, n) in kDailyParts) PracticePart(s, n)],
            day: DateTime(day.year, day.month, day.day));

  /// The mistake notebook: [count] questions due again.
  PracticePlan.review(int count) : this._(PlanKind.review, 'Mistakes to redo', [PracticePart(PracticeSection.quant, count)]);

  /// A full mock in an exam's pattern (exam_patterns.dart).
  const PracticePlan.pattern({required String id, required String title, required List<PracticePart> parts, required int minutes})
      : this._(PlanKind.pattern, title, parts, minutes: minutes, key: id);

  final PlanKind planKind;
  final String title;
  final List<PracticePart> parts;

  /// Fixed time (an exam's own); else each section's pace.
  final int? minutes;

  /// The Daily 10's day.
  final DateTime? day;
  final String? key;

  /// One section on its own, else null (several sections, or the notebook).
  PracticeSection? get section => planKind == PlanKind.section ? parts.single.section : null;

  /// Questions from several sections (each shows its section's name).
  bool get isMixed => planKind != PlanKind.section;

  int get count => parts.fold(0, (sum, p) => sum + p.count);

  /// History key: the section's name, "mock", "daily", "review" or "pattern:" and the pattern id.
  String get kind => switch (planKind) {
        PlanKind.section => parts.single.section.name,
        PlanKind.mock => 'mock',
        PlanKind.daily => 'daily',
        PlanKind.review => 'review',
        PlanKind.pattern => 'pattern:$key',
      };

  /// Whole minutes: the exam's own, else at each section's pace.
  Duration get time =>
      Duration(minutes: minutes ?? (parts.fold(0, (sum, p) => sum + p.section.seconds * p.count) / 60).ceil());
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
    double? marks,
    double? maxMarks,
  })  : _marks = marks,
        _max = maxMarks;

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

  final double? _marks;
  final double? _max;

  int get skipped => total - right - wrong;
  int get answered => right + wrong;

  /// Marks with the test's own scheme (+1 / −¼ unless an exam's).
  double get marks => _marks ?? right - wrong * kWrongPenalty;
  double get maxMarks => _max ?? total.toDouble();

  /// Marks out of the most there were (0..1; never below 0).
  double get share => maxMarks <= 0 ? 0 : max(0, marks) / maxMarks;

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
        if (_marks != null) 'mk': _marks,
        if (_max != null) 'mx': _max,
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
    return PracticeResult(
      kind: kind,
      at: at,
      total: n('n'),
      right: n('r'),
      wrong: n('w'),
      seconds: n('s'),
      topics: topics,
      marks: (j['mk'] as num?)?.toDouble(),
      maxMarks: (j['mx'] as num?)?.toDouble(),
    );
  }
}

/// Marks [chosen] (an option index per question, null = skipped), each question
/// with its own +/− marks.
PracticeResult grade(PracticePlan plan, List<PracticeQuestion> questions, List<int?> chosen,
    {required DateTime at, required int seconds}) {
  var right = 0, wrong = 0;
  var marks = 0.0, most = 0.0;
  final topics = <String, (int, int)>{};
  for (final (i, q) in questions.indexed) {
    final c = i < chosen.length ? chosen[i] : null;
    final ok = c == q.answer;
    most += q.plus;
    if (c != null) {
      if (ok) {
        right++;
        marks += q.plus;
      } else {
        wrong++;
        marks -= q.minus;
      }
    }
    final (r, n) = topics[q.topic] ?? (0, 0);
    topics[q.topic] = (r + (ok ? 1 : 0), n + 1);
  }
  return PracticeResult(
    kind: plan.kind,
    at: at,
    total: questions.length,
    right: right,
    wrong: wrong,
    seconds: seconds,
    topics: topics,
    marks: (marks * 100).round() / 100,
    maxMarks: most,
  );
}

/// "7.75" / "8" / "−0.5" (two decimals at most: −⅓ marks add up to 66.67).
String marksText(double marks) {
  final rounded = (marks * 100).round() / 100;
  final s = rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
  return s.startsWith('-') ? '−${s.substring(1)}' : s;
}

/// "+2 · −½", "+1 · −⅓"
String markingText(double plus, double minus) {
  String frac(double x) => switch (x) {
        0.25 => '¼',
        0.5 => '½',
        _ when (x - 1 / 3).abs() < 1e-6 => '⅓',
        _ => marksText(x),
      };
  return minus == 0 ? '+${marksText(plus)} · no minus' : '+${marksText(plus)} · −${frac(minus)}';
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

/// The first Daily 10 done on [now]'s day, if any.
PracticeResult? dailyDoneOn(DateTime now, List<PracticeResult> history) {
  for (final r in history) {
    if (r.kind == 'daily' && r.at.year == now.year && r.at.month == now.month && r.at.day == now.day) return r;
  }
  return null;
}

/// Days in a row (up to [now]) with a Daily 10 done; today not done yet doesn't
/// break it.
int dailyStreak(DateTime now, List<PracticeResult> history) {
  final days = {
    for (final r in history)
      if (r.kind == 'daily') DateTime(r.at.year, r.at.month, r.at.day),
  };
  var day = DateTime(now.year, now.month, now.day);
  if (!days.contains(day)) day = day.subtract(const Duration(days: 1));
  var n = 0;
  while (days.contains(day)) {
    n++;
    day = DateTime(day.year, day.month, day.day - 1);
  }
  return n;
}

/// The seed for [day]'s Daily 10: the same on every phone.
int dailySeed(DateTime day) => day.year * 10000 + day.month * 100 + day.day;

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

/// The Daily 10's bank questions: the same pick on every phone with the same
/// bank (sorted by id, then a seeded draw). Reported ones are left out.
List<PracticeQuestion> dailyFromBank(List<PracticeQuestion> bank, int n, int seed, {Set<String> hidden = const {}}) {
  final sorted = [for (final q in bank) if (!hidden.contains(q.id)) q]..sort((a, b) => a.id.compareTo(b.id));
  final r = Random(seed);
  sorted.shuffle(r);
  return [for (final q in sorted.take(n)) q.shuffled(r)];
}

/// Current affairs: the newest weeks first, so a test is mostly this week's news.
List<PracticeQuestion> newestWeeksFirst(List<PracticeQuestion> bank, {int weeks = 2}) {
  final all = {for (final q in bank) if (q.week != null) q.week!}.toList()..sort();
  final recent = all.reversed.take(weeks).toSet();
  final fresh = [for (final q in bank) if (recent.contains(q.week)) q];
  return fresh.length >= 10 ? fresh : bank;
}
