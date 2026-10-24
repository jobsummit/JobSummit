/// Ranks and filters the jobs you qualify for: your preferences first, then pay,
/// then what you've applied to and rejected before ("learning" = simple counts
/// of job features, kept on the phone). Pure functions, unit-tested.
library;

import 'dart:math' as math;

import '../models/feed.dart';
import '../models/job_preferences.dart';
import '../models/jobs_data.dart';
import 'qualification_taxonomy.dart';
import 'requirements.dart';

// -----------------------------------------------------------------------------
// Features: what a job "is", for learning from decisions
// -----------------------------------------------------------------------------

const _roleWords = {
  'officer',
  'clerk',
  'assistant',
  'engineer',
  'manager',
  'executive',
  'inspector',
  'trainee',
  'apprentice',
  'scientist',
  'fellow',
  'jrf',
  'srf',
  'teacher',
  'lecturer',
  'professor',
  'nurse',
  'doctor',
  'technician',
  'constable',
  'accountant',
  'auditor',
  'stenographer',
  'typist',
  'driver',
  'analyst',
  'consultant',
  'specialist',
  'supervisor',
  'operator',
  'pharmacist',
  'librarian',
  'translator',
  'programmer',
  'researcher',
  'attendant',
  'peon',
  'mts',
  'po',
  'je',
  'ae',
}; // dart format off

/// "Junior Research Fellow (JRF)" -> {jrf, fellow}. Lower-case, letters only.
Set<String> roleWords(String text) => {
      for (final w in text.toLowerCase().split(RegExp('[^a-z]+')))
        if (_roleWords.contains(w)) w,
    };

String _orgKey(String organization) => organization
    .toLowerCase()
    .replaceAll(RegExp('[^a-z ]'), ' ')
    .trim()
    .split(RegExp(' +'))
    .take(3)
    .join(' ');

String? _payBand(int? pay) => switch (pay) {
      null => null,
      < 25000 => 'under25k',
      < 40000 => '25to40k',
      < 60000 => '40to60k',
      _ => 'over60k',
    };

/// The features remembered when you apply to or reject a job.
Set<String> jobFeatures(FeedItem item) {
  final job = item.job;
  return {
    'cat:${item.category}',
    'org:${_orgKey(item.organization)}',
    for (final w in roleWords('${item.bestPost.postName} ${item.examName}')) 'role:$w',
    if (job?.employmentType != null) 'type:${job!.employmentType}',
    if (_payBand(item.monthlyPay) case final band?) 'pay:$band',
  };
}

/// One decision as stored on the phone.
class Decision {
  const Decision({required this.features, required this.applied});

  final Set<String> features;
  final bool applied; // false = rejected
}

/// Learned likes and dislikes: weight(feature) = ln((applied + 1) / (rejected + 1)).
class Affinity {
  Affinity._(this._weights);

  factory Affinity.fromDecisions(Iterable<Decision> decisions) {
    final applied = <String, int>{};
    final rejected = <String, int>{};
    for (final d in decisions) {
      for (final f in d.features) {
        final counts = d.applied ? applied : rejected;
        counts[f] = (counts[f] ?? 0) + 1;
      }
    }
    return Affinity._({
      for (final f in {...applied.keys, ...rejected.keys})
        f: math.log(((applied[f] ?? 0) + 1) / ((rejected[f] ?? 0) + 1)),
    });
  }

  static final empty = Affinity._(const {});

  /// Weights learned elsewhere (the job-picks model, picks.dart).
  factory Affinity.fromWeights(Map<String, double> weights) => Affinity._(Map.of(weights));

  final Map<String, double> _weights;

  bool get isEmpty => _weights.isEmpty;

  /// Summed and capped, so one strong habit can't drown everything else.
  double score(Set<String> features) =>
      features.fold<double>(0, (sum, f) => sum + (_weights[f] ?? 0)).clamp(-6.0, 6.0);

  /// The feature that pulls hardest towards this job, for "Like jobs you applied to".
  String? strongestLike(Set<String> features) {
    String? best;
    var top = 0.3;
    for (final f in features) {
      final w = _weights[f] ?? 0;
      if (w > top) (best, top) = (f, w);
    }
    return best;
  }
}

// -----------------------------------------------------------------------------
// Filters: jobs you'd never apply to
// -----------------------------------------------------------------------------

/// Why a job is hidden, in a few words for the hidden-jobs list, or null when it stays.
String? hiddenBecause(FeedItem item, JobPreferences prefs, {required String? myLevel}) {
  final category = JobCategory.fromWire(item.category);
  if (prefs.hidden.contains(category)) return 'You hid ${category.label}';
  final type = item.job?.employmentType;
  if (type != null && prefs.hiddenTypes.contains(type)) return 'You hid ${type.replaceAll('_', ' ')} jobs';
  final pay = item.monthlyPay;
  if (prefs.minMonthlyPay > 0 && pay != null && pay < prefs.minMonthlyPay) return 'Pay below your minimum';
  final language = demandedLanguage(item);
  if (language != null && !prefs.languages.contains(language)) return 'Needs $language';
  // What the qualification text adds: B.Ed / TET, "knowledge of Marathi"…
  final unmet = unmetRequirementForJob(item, prefs);
  if (unmet != null) return unmet;
  if (prefs.hideBelowMyLevel && isBelowLevel(item, myLevel)) return 'Needs only 10th pass or less';
  return null;
}

final _languagePatterns = {
  for (final lang in kIndianLanguages)
    if (lang != 'English' && lang != 'Hindi') lang: RegExp('\\b$lang\\b', caseSensitive: false),
};

/// A regional language the post itself is about: "Marathi Teacher", "TGT (Tamil)".
/// Hindi and English are known by default and set in Preferences like the rest.
String? demandedLanguage(FeedItem item) {
  final names = [
    for (final p in item.posts.isEmpty ? [item.bestPost] : item.posts) p.postName
  ];
  // Every post you qualify for names the same language: the job is about it.
  for (final MapEntry(key: lang, value: pattern) in _languagePatterns.entries) {
    if (names.every(pattern.hasMatch)) return lang;
  }
  for (final lang in const ['Hindi', 'English']) {
    final pattern = RegExp('\\b$lang (?:teacher|translator|typist|stenographer|lecturer|tgt|pgt|prt)\\b',
        caseSensitive: false);
    if (names.every(pattern.hasMatch)) return lang;
  }
  return null;
}

const _menialWords = {
  'peon',
  'chowkidar',
  'chowkidaar',
  'sweeper',
  'safai',
  'gardener',
  'mali',
  'cook',
  'watchman',
  'attendant',
  'helper',
  'cleaner',
  'washerman',
  'dhobi',
  'barber',
  'waterman',
  'bearer',
  'chaukidar',
}; // dart format off

int _rank(String? levelCode) {
  for (final l in kQualificationLevels) {
    if (l.code == levelCode) return l.rank;
  }
  return 0;
}

/// A graduate looking at a post that needs only 10th pass (or is plainly menial).
bool isBelowLevel(FeedItem item, String? myLevel) {
  final mine = _rank(myLevel);
  if (mine < _rank('UG')) return false;
  final post = item.bestPublishedPost;
  final needed = _rank(post?.minQualificationLevel);
  if (needed > 0 && needed <= _rank('MATRIC')) return true;
  final words = item.bestPost.postName.toLowerCase().split(RegExp('[^a-z]+'));
  return words.any(_menialWords.contains);
}

// -----------------------------------------------------------------------------
// Ranking
// -----------------------------------------------------------------------------

/// Without any preferences, the big national recruitments lead.
const _defaultCategoryWeight = {
  'railway': 1.5,
  'bank': 1.5,
  'ssc': 1.5,
  'upsc': 1.5,
  'psu': 1.5,
  'research': 0.5,
  'defence': 0.5,
}; // dart format off

const _typeWeight = {'permanent': 1.0, 'contract': -0.5, 'apprenticeship': -1.0, 'internship': -1.5};

class RankedJob {
  const RankedJob(this.item, this.score, this.reasons);

  final FeedItem item;
  final double score;

  /// Short chips: "Your pick: Banks", "₹35,400/month", "Like jobs you applied to".
  final List<String> reasons;
}

/// How much people like you count next to your own choices.
const kCrowdShare = 0.5;

/// [crowd]: what people with your degree lean towards (the job-picks model);
/// [track]: the job's career track from the same model.
RankedJob rankJob(FeedItem item, JobPreferences prefs, Affinity affinity,
    {Affinity? crowd, String? track}) {
  final reasons = <String>[];
  var score = 0.0;
  final category = JobCategory.fromWire(item.category);
  if (prefs.preferred.contains(category)) {
    score += 3;
    reasons.add('Your pick: ${category.label}');
  } else if (prefs.preferred.isEmpty) {
    score += _defaultCategoryWeight[category.wire] ?? 0;
  }
  final pay = item.monthlyPay;
  if (pay != null && pay > 0) {
    score += 1.5 * (math.log(pay / 18000) / math.ln2).clamp(-1.0, 3.0); // ₹18k = 0, ₹72k = +3
  }
  score += _typeWeight[item.job?.employmentType] ?? 0;
  score += 0.5 * math.log(item.bestPost.totalReachableSeats + 1) / math.ln10;
  if (!affinity.isEmpty) {
    final features = jobFeatures(item);
    score += affinity.score(features);
    if (affinity.strongestLike(features) != null) reasons.add('Like jobs you applied to');
  }
  if (crowd != null && !crowd.isEmpty) {
    final features = {...jobFeatures(item), if (track != null) 'track:$track'};
    score += kCrowdShare * crowd.score(features);
    if (crowd.strongestLike(features) != null && !reasons.contains('Like jobs you applied to')) {
      reasons.add('Popular with people like you');
    }
  }
  if (eligibilityUnknown(item)) {
    // Shown (you may well qualify), but below jobs that say who can apply.
    score -= 2;
    reasons.add('Check eligibility');
  } else if (subjectUnclear(item, prefs) case final noun?) {
    reasons.add('Check $noun');
  }
  return RankedJob(item, score, reasons);
}

/// Whether the notice couldn't be read for who may apply: no qualification, no
/// degrees, no level, for any of the job's posts you'd see.
bool eligibilityUnknown(FeedItem item) {
  final published = {for (final p in item.job?.posts ?? const <PublishedPost>[]) p.id: p};
  return (item.posts.isEmpty ? [item.bestPost] : item.posts).every((post) {
    final p = published[post.postDetailId];
    return p != null &&
        (p.qualificationText ?? '').trim().isEmpty &&
        (p.rawEligibilityText ?? '').trim().isEmpty &&
        p.allowedDegrees.isEmpty &&
        p.eligibleStreams.isEmpty &&
        p.minQualificationLevel == null &&
        !p.openToAnyGraduate &&
        !p.openToAnyPostGraduate;
  });
}

enum JobSort {
  bestMatch('Best match'),
  highestPay('Highest pay'),
  closingSoon('Closing soon');

  const JobSort(this.label);
  final String label;
}

/// Filter, score and sort. Ties fall back to the earlier deadline.
List<RankedJob> rankJobs(
  Iterable<FeedItem> items,
  JobPreferences prefs,
  Affinity affinity, {
  required String? myLevel,
  JobSort sort = JobSort.bestMatch,
  Affinity? crowd,
  Map<String, String> tracks = const {},
}) {
  final ranked = [
    for (final item in items.map((i) => keepPostsYouMeet(i, prefs)))
      if (hiddenBecause(item, prefs, myLevel: myLevel) == null)
        rankJob(item, prefs, affinity, crowd: crowd, track: tracks[item.jobPostId]),
  ];
  int byDeadline(RankedJob a, RankedJob b) => a.item.deadline.compareTo(b.item.deadline);
  ranked.sort(switch (sort) {
    JobSort.bestMatch => (a, b) {
        final s = b.score.compareTo(a.score);
        return s != 0 ? s : byDeadline(a, b);
      },
    JobSort.highestPay => (a, b) {
        final s = (b.item.monthlyPay ?? -1).compareTo(a.item.monthlyPay ?? -1);
        return s != 0 ? s : byDeadline(a, b);
      },
    JobSort.closingSoon => byDeadline,
  });
  return ranked;
}

/// "₹35,400/month" (Indian digit grouping).
String formatPay(int rupees) {
  final s = rupees.toString();
  if (s.length <= 3) return '₹$s/month';
  final last3 = s.substring(s.length - 3);
  var rest = s.substring(0, s.length - 3);
  final groups = <String>[];
  while (rest.length > 2) {
    groups.insert(0, rest.substring(rest.length - 2));
    rest = rest.substring(0, rest.length - 2);
  }
  if (rest.isNotEmpty) groups.insert(0, rest);
  return '₹${groups.join(',')},$last3/month';
}

/// The job's posts as published, for the details panel.
List<PublishedPost> postsOf(FeedItem item) {
  final ids = {
    for (final p in item.posts.isEmpty ? [item.bestPost] : item.posts) p.postDetailId
  };
  return [
    for (final p in item.job?.posts ?? const <PublishedPost>[])
      if (ids.contains(p.id)) p
  ];
}
