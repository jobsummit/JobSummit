/// On-device eligibility engine: a line-by-line port of
/// backend/app/services/eligibility.py (+ the "Others" search from streams.py).
///
/// Both implementations are checked against shared/eligibility_cases.json
/// (test/eligibility_parity_test.dart), so change them together: edit the
/// Python, run `python backend/scripts/make_parity_cases.py`, then make this match.
library;

import 'package:flutter/foundation.dart';

import '../models/jobs_data.dart';
import '../models/user_profile.dart';
import 'agenda.dart';

const kDefaultCategoryRelaxation = {'UR': 0, 'EWS': 0, 'OBC': 3, 'SC': 5, 'ST': 5};
const kDefaultPwbdRelaxation = 10;
const kDefaultExsmRelaxation = 3; // plus years of military service
const kMaxSuggestedExperienceGap = 1.0; // years
const _relaxPwbd = 'PWBD';
const _relaxExsm = 'EXSM';

enum MatchReason {
  directDegree('direct_degree', 'Direct Degree Match'),
  universalGraduate('universal_graduate', 'Universal Graduate Post'),
  universalPostGraduate('universal_post_graduate', 'Universal Post-Graduate Post'),
  schoolLevel('school_level', 'School-Level Post'),
  customQualification('custom_qualification', 'Custom Qualification Match');

  const MatchReason(this.wire, this.label);
  final String wire;
  final String label;
}

enum EligibilityKind { direct, suggested }

@immutable
class EligibilityResult {
  const EligibilityResult({
    required this.kind,
    required this.qualificationMatch,
    required this.matchReason,
    required this.eligibleViaRelaxation,
    required this.effectiveMaxAge,
    required this.relaxationYears,
    required this.categoryQuotaSeats,
    required this.urOpenSeats,
    required this.experienceGapYears,
    required this.reasons,
    this.ageYears,
  });

  /// null = not shown at all.
  final EligibilityKind? kind;
  final bool? qualificationMatch; // null = couldn't verify
  final MatchReason? matchReason;
  final bool eligibleViaRelaxation;
  final int? effectiveMaxAge;
  final int relaxationYears;
  final int categoryQuotaSeats;
  final int urOpenSeats;
  final double experienceGapYears;
  final int? ageYears;
  final List<String> reasons;

  bool get isEligible => kind == EligibilityKind.direct;
  int get totalReachableSeats => categoryQuotaSeats + urOpenSeats;
}

// --- Age ---------------------------------------------------------------------

/// Completed years on [asOn] ("should not exceed 25 years": 25y 11m counts as 25).
int ageInYearsOn(DateTime dob, DateTime asOn) {
  if (dob.isAfter(asOn)) throw ArgumentError('date of birth $dob is after cut-off $asOn');
  var years = asOn.year - dob.year;
  if (asOn.month < dob.month || (asOn.month == dob.month && asOn.day < dob.day)) years--;
  return years;
}

int totalRelaxationYears(UserProfileData p, Map<String, int> overrides) {
  final cat = p.category.wire;
  var years = overrides[cat] ?? kDefaultCategoryRelaxation[cat] ?? 0;
  if (cat == 'UR') years = 0; // never let a stray override relax the open category
  if (p.isPwbd) years += overrides[_relaxPwbd] ?? kDefaultPwbdRelaxation;
  if (p.isExServiceman) {
    years += overrides[_relaxExsm] ?? kDefaultExsmRelaxation;
    years += p.exServicemanServiceYears < 0 ? 0 : p.exServicemanServiceYears;
  }
  return years < 0 ? 0 : years;
}

// --- Qualification -----------------------------------------------------------------

int _rank(String? levelCode) => levelByCode(levelCode)?.rank ?? 0;
String _levelLabel(String code) => levelByCode(code)?.label ?? code;

/// The degree itself plus what it implies (M_TECH -> B_TECH).
Set<String> degreeCodesHeld(String degreeTitle) {
  final held = <String>{};
  String? code = degreeTitle;
  while (code != null && !held.contains(code)) {
    final d = degreeByCode(code);
    if (d == null) break;
    held.add(code);
    code = d.implies;
  }
  return held;
}

/// Every degree a profile holds, with what each implies.
Set<String> profileDegreesHeld(UserProfileData p) => {for (final d in p.allDegrees) ...degreeCodesHeld(d)};

String normaliseText(String raw) {
  var s = raw.toLowerCase().replaceAll('&', ' and ').replaceAll('.', '');
  s = s.replaceAll(RegExp('[^a-z0-9]+'), ' ');
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

const _stop = {'in', 'of', 'the', 'and', 'degree', 'course', 'with', 'from', 'a', 'an'};
const _generic = {'bachelor', 'bachelors', 'master', 'masters', 'diploma', 'graduate', 'graduation', 'post'};
final _splitAlternatives = RegExp(r'[/,;|]| or ', caseSensitive: false);

List<String> _contentWords(String text) => [
      for (final w in normaliseText(text).split(' '))
        if (w.isNotEmpty && !_stop.contains(w)) w
    ];

/// 'CA/CS' -> ['ca', 'cs']; 'B Des (Fashion)' -> ['b des fashion', 'bdes'].
List<String> customTerms(String customText) {
  final terms = <String>[];
  for (final part in customText.split(_splitAlternatives)) {
    final words = _contentWords(part);
    if (words.isEmpty) continue;
    terms.add(words.join(' '));
    if (words.length >= 2 && words[0].length <= 2) {
      terms.add(words[0] + words[1]); // "B.Des" is printed both "B.Des" and "B Des"
    } else if (words.length >= 2 && words[0].length >= 3 && !_generic.contains(words[0])) {
      terms.add(words[0]); // "BAMS Ayurveda" -> also "bams"
    }
  }
  final seen = <String>{};
  return [
    for (final t in terms)
      if (t.length >= 2 && !_generic.contains(t) && seen.add(t)) t,
  ];
}

/// Case-insensitive whole-word search of any alternative in any haystack.
bool customTextMatches(String customText, Iterable<String?> haystacks) {
  final terms = customTerms(customText);
  if (terms.isEmpty) return false;
  final texts = [
    for (final h in haystacks)
      if (h != null && h.isNotEmpty) _contentWords(h).join(' '),
  ];
  for (final term in terms) {
    final pattern = RegExp('\\b${RegExp.escape(term)}\\b');
    if (texts.any(pattern.hasMatch)) return true;
  }
  return false;
}

@immutable
class _Qual {
  const _Qual(this.match, this.reason, [this.note = '']);

  final bool? match;
  final MatchReason? reason;
  final String note;
}

_Qual _evaluateQualification(UserProfileData p, PublishedPost post) {
  final tier = _rank(p.qualificationTier);
  final allowed = post.allowedDegrees.toSet();
  final anyGrad = post.openToAnyGraduate;
  final anyPg = post.openToAnyPostGraduate;
  final need = post.minQualificationLevel; // published already merged with the flags
  final needRank = need == null ? null : _rank(need);
  final ug = _rank('UG');
  final pg = _rank('PG');

  if (needRank != null && tier < needRank) {
    return _Qual(
        false, null, 'Needs ${_levelLabel(need!)}; your highest is ${_levelLabel(p.qualificationTier)}.');
  }
  if (anyPg && tier >= pg) return const _Qual(true, MatchReason.universalPostGraduate);
  if (anyGrad && tier >= ug) return const _Qual(true, MatchReason.universalGraduate);
  if (profileDegreesHeld(p).intersection(allowed).isNotEmpty) {
    return const _Qual(true, MatchReason.directDegree);
  }
  // Only *plain* 10th/12th posts cascade ("10th + ITI" lists ITI, so it doesn't).
  if (allowed.isNotEmpty && allowed.every({'CLASS_10', 'CLASS_12'}.contains)) {
    if ((need == 'MATRIC' && tier > _rank('MATRIC')) || (need == 'INTERMEDIATE' && tier >= ug)) {
      return const _Qual(true, MatchReason.schoolLevel);
    }
  }
  final custom = p.customQualificationText;
  if (p.isOthers && custom != null && custom.isNotEmpty) {
    final haystacks = [post.rawEligibilityText ?? '', post.qualificationText ?? '', ...post.eligibleStreams];
    if (customTextMatches(custom, haystacks)) return const _Qual(true, MatchReason.customQualification);
    if (haystacks.any((h) => h.trim().isNotEmpty)) {
      return const _Qual(false, null, 'Your qualification isn’t mentioned in the eligibility.');
    }
  }
  if (allowed.isEmpty && !anyGrad && !anyPg && need == null) {
    return const _Qual(null, null, 'Qualification could not be auto-verified — check the notification.');
  }
  if (allowed.isEmpty && !anyGrad && !anyPg) {
    return _Qual(null, null, 'Needs ${_levelLabel(need!)} (degree not specified) — check the notification.');
  }
  return const _Qual(false, null, 'Your degree is not in the eligible list.');
}

String _g(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

String _d(DateTime d) => '${d.day.toString().padLeft(2, '0')} ${kShortMonths[d.month - 1]} ${d.year}';

// --- Main entry point -------------------------------------------------------------

/// Throws [ArgumentError] when the date of birth is after the post's cut-off
/// (corrupt data: the post is skipped).
EligibilityResult evaluateEligibility(UserProfileData p, PublishedPost post,
    {bool strictUrMigration = true}) {
  final reasons = <String>[];
  var ageOk = true;
  var viaRelaxation = false;
  int? effectiveMax;
  int? age;
  final relax = totalRelaxationYears(p, post.ageRelaxationOverrides);

  // 1. Age
  final asOn = post.ageAsOn;
  if (asOn == null) {
    reasons.add('Age cut-off date not found in notification — age not verified.');
  } else {
    age = ageInYearsOn(p.dateOfBirth, asOn);
    if (post.minAge != null && age < post.minAge!) {
      ageOk = false;
      reasons.add('Below minimum age ${post.minAge} on ${_d(asOn)}.');
    }
    final base = post.baseMaxAge;
    if (base != null) {
      effectiveMax = base + relax;
      if (age > effectiveMax) {
        ageOk = false;
        reasons.add('Age $age exceeds limit $effectiveMax (base $base + $relax relaxation).');
      } else if (age > base) {
        viaRelaxation = true;
        reasons.add('Eligible via $relax-year relaxation (age $age, limit $effectiveMax).');
      }
    }
  }

  // 2. Qualification
  final qual = _evaluateQualification(p, post);
  if (qual.note.isNotEmpty) reasons.add(qual.note);

  // 3. Experience
  final needExp = post.minExperienceYears;
  final haveExp = p.experienceYears;
  final rawGap = needExp - haveExp;
  final gap = rawGap <= 0 ? 0.0 : (rawGap * 100).roundToDouble() / 100;
  if (gap > 0) reasons.add('Needs ${_g(needExp)} yr experience; you have ${_g(haveExp)}.');

  // 4. Direct / suggested / hidden
  final hardFail = !ageOk || qual.match == false || gap > kMaxSuggestedExperienceGap;
  final kind = hardFail ? null : (gap > 0 ? EligibilityKind.suggested : EligibilityKind.direct);

  // 5. Seats
  var quota = 0;
  var urOpen = 0;
  final vac = post.vacancy;
  if (vac == null) {
    reasons.add('Vacancy break-up not available.');
  } else if (kind != null) {
    if (p.category == ReservationCategory.ur) {
      urOpen = vac.ur;
    } else {
      quota = vac.seatsFor(p.category.wire);
      if (strictUrMigration && viaRelaxation) {
        reasons.add('Age relaxation used: UR (open) seats not reachable.');
      } else {
        urOpen = vac.ur;
      }
    }
  }

  return EligibilityResult(
    kind: kind,
    qualificationMatch: qual.match,
    matchReason: qual.reason,
    eligibleViaRelaxation: kind != null && viaRelaxation,
    effectiveMaxAge: effectiveMax,
    relaxationYears: relax,
    categoryQuotaSeats: quota,
    urOpenSeats: urOpen,
    experienceGapYears: gap,
    ageYears: age,
    reasons: reasons,
  );
}
