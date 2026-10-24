/// Your limits for an exam: until which year your age still lets you apply (with
/// your category's relaxation), and how many attempts you have left where the
/// exam counts them. Pure (no I/O).
///
/// The age rule comes from the exam's latest notice in the job list when there is
/// one (its highest post limit, its cut-off date, its relaxations); else from the
/// usual rule below, which the app says is "usually". Rules change: the notice
/// always decides.
library;

import 'package:flutter/foundation.dart';

import '../models/jobs_data.dart';
import '../models/user_profile.dart';
import 'eligibility.dart';
import 'exam_catalog.dart';

@immutable
class AgeRule {
  const AgeRule(this.min, this.max, this.month, this.day, {this.postWise = false, this.overrides = const {}});

  final int min;

  /// For the open (UR) category, before relaxation.
  final int max;

  /// The date the age is counted on, each year.
  final int month;
  final int day;

  /// The limit differs by post; [max] is the highest.
  final bool postWise;

  /// The notice's own relaxations ({"OBC": 3, "PWBD": 10}), when it printed them.
  final Map<String, int> overrides;
}

/// Attempts allowed by category ('UR', 'EWS', 'OBC', 'SC', 'ST'; 'PWBD' for
/// candidates with a disability in UR / EWS / OBC). A missing category: no limit.
typedef AttemptRule = Map<String, int>;

const _aug1 = (8, 1), _jan1 = (1, 1), _apr1 = (4, 1), _jul1 = (7, 1), _sep1 = (9, 1);

AgeRule _r(int min, int max, (int, int) on, {bool postWise = false}) =>
    AgeRule(min, max, on.$1, on.$2, postWise: postWise);

/// The usual rules for common exams (from their recent notices).
final kUsualAgeRules = <String, AgeRule>{
  'ssc-cgl': _r(18, 32, _aug1, postWise: true),
  'ssc-chsl': _r(18, 27, _jan1),
  'ssc-mts': _r(18, 27, _aug1, postWise: true),
  'ssc-gd': _r(18, 23, _jan1),
  'ssc-cpo': _r(20, 25, _aug1),
  'ssc-steno': _r(18, 30, _aug1, postWise: true),
  'ssc-jht': _r(18, 30, _aug1),
  'ssc-je': _r(18, 32, _aug1, postWise: true),
  'delhi-police-constable': _r(18, 25, _jul1),
  'upsc-cse': _r(21, 32, _aug1),
  'upsc-ese': _r(21, 30, _jan1),
  'upsc-capf': _r(20, 25, _aug1),
  'ibps-po': _r(20, 30, _aug1),
  'ibps-clerk': _r(20, 28, _aug1),
  'ibps-so': _r(20, 30, _aug1),
  'ibps-rrb-po': _r(18, 30, _sep1),
  'ibps-rrb-clerk': _r(18, 28, _sep1),
  'sbi-po': _r(21, 30, _apr1),
  'sbi-clerk': _r(20, 28, _apr1),
  'rbi-grade-b': _r(21, 30, _jul1),
  'rbi-assistant': _r(20, 28, _sep1),
  'nabard-grade-a': _r(21, 30, _jan1),
  'lic-aao': _r(21, 30, _aug1),
  'niacl-ao': _r(21, 30, _sep1),
  'niacl-assistant': _r(21, 30, _jan1),
  'rrb-ntpc-graduate': _r(18, 33, _jan1),
  'rrb-ntpc-ug': _r(18, 30, _jan1),
  'rrb-group-d': _r(18, 33, _jan1),
  'rrb-alp': _r(18, 30, _jan1),
  'rrb-je': _r(18, 33, _jan1),
  'rpf-constable': _r(18, 28, _jan1),
};

/// Exams that count attempts.
const kAttemptRules = <String, AttemptRule>{
  'upsc-cse': {'UR': 6, 'EWS': 6, 'OBC': 9, 'PWBD': 9},
  'sbi-po': {'UR': 4, 'EWS': 4, 'OBC': 7, 'PWBD': 7},
  'rbi-grade-b': {'UR': 6, 'EWS': 6},
};

/// The age rule from the newest notice of [exam] in the job list, else null:
/// the lowest minimum and highest maximum of its posts, on its cut-off date.
AgeRule? ageRuleFromJobs(CatalogExam exam, List<PublishedJob> jobs) {
  PublishedJob? latest;
  for (final j in jobs) {
    if (matchCatalogExam('${j.examName} ${j.organization}')?.id != exam.id) continue;
    if (!j.posts.any((p) => p.baseMaxAge != null && p.ageAsOn != null)) continue;
    final at = j.applicationDeadline ?? j.applicationStart;
    final best = latest?.applicationDeadline ?? latest?.applicationStart;
    if (latest == null || (at != null && (best == null || at.isAfter(best)))) latest = j;
  }
  if (latest == null) return null;
  final posts = [for (final p in latest.posts) if (p.baseMaxAge != null && p.ageAsOn != null) p];
  final maxes = {for (final p in posts) p.baseMaxAge!};
  final top = posts.reduce((a, b) => a.baseMaxAge! >= b.baseMaxAge! ? a : b);
  final mins = [for (final p in posts) if (p.minAge != null) p.minAge!];
  return AgeRule(
    mins.isEmpty ? 18 : mins.reduce((a, b) => a < b ? a : b),
    top.baseMaxAge!,
    top.ageAsOn!.month,
    top.ageAsOn!.day,
    postWise: maxes.length > 1,
    overrides: top.ageRelaxationOverrides,
  );
}

@immutable
class ExamLimits {
  const ExamLimits({
    required this.rule,
    required this.fromNotice,
    required this.maxAge,
    required this.relaxation,
    this.firstYear,
    this.lastYear,
    this.attempts,
  });

  final AgeRule rule;

  /// From the exam's latest notice (else the usual rule).
  final bool fromNotice;

  /// Your limit: the rule's maximum plus [relaxation].
  final int maxAge;
  final int relaxation;

  /// The first and last years whose cut-off date your age fits; null when none
  /// (too old already).
  final int? firstYear;
  final int? lastYear;

  /// Attempts allowed for you; null when the exam doesn't count them.
  final int? attempts;

  /// "Apply until 2029 · limit 35 (32 + 3 for OBC), counted on 1 Aug"
  String summary(DateTime now) {
    final on = '${rule.day} ${_months[rule.month - 1]}';
    final limit = relaxation > 0 ? '$maxAge (${rule.max} + $relaxation)' : '$maxAge';
    if (lastYear == null) return 'Over the age limit ($limit on $on)';
    final from = firstYear != null && firstYear! > now.year ? 'From $firstYear until $lastYear' : 'Until $lastYear';
    return '$from · age limit $limit on $on${rule.postWise ? ' for some posts' : ''}';
  }
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// Your limits for [exam], or null when no rule is known. [jobs]: the job list
/// (its newest notice of the exam wins over the usual rule).
ExamLimits? limitsFor(CatalogExam exam, UserProfileData profile, DateTime now, {List<PublishedJob> jobs = const []}) {
  final fromJobs = ageRuleFromJobs(exam, jobs);
  final rule = fromJobs ?? kUsualAgeRules[exam.id];
  if (rule == null) return null;
  final relax = totalRelaxationYears(profile, rule.overrides);
  final max = rule.max + relax;
  int? first, last;
  for (var y = now.year; y <= now.year + 45; y++) {
    final on = DateTime(y, rule.month, rule.day);
    if (!on.isAfter(profile.dateOfBirth)) continue;
    final age = ageInYearsOn(profile.dateOfBirth, on);
    if (age > max) break;
    if (age >= rule.min) {
      first ??= y;
      last = y;
    }
  }
  return ExamLimits(
    rule: rule,
    fromNotice: fromJobs != null,
    maxAge: max,
    relaxation: relax,
    firstYear: first,
    lastYear: last,
    attempts: attemptsFor(exam.id, profile),
  );
}

/// Attempts allowed for you at [examId], or null (not counted, or no limit for
/// your category).
int? attemptsFor(String examId, UserProfileData profile) {
  final rule = kAttemptRules[examId];
  if (rule == null) return null;
  final cat = profile.category.wire;
  if (profile.isPwbd && cat != 'SC' && cat != 'ST') return rule['PWBD'] ?? rule[cat];
  return rule[cat];
}
