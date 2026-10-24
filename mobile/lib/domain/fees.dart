/// Application fees: what a job costs you, what you paid this year, and the fee
/// refunds some boards give for attending the exam. Pure (no I/O).
library;

import '../models/tracked_application.dart';
import '../models/user_profile.dart';

/// Your fee from a notification's table ({"UR": 500, "SC": 250}): the lowest of
/// your category's, PwBD's and ex-servicemen's when they apply to you, else the one
/// fee for all. Null when the table doesn't say (women's fees aren't known: the
/// profile doesn't ask).
int? feeFor(Map<String, int> fees, UserProfileData? profile) {
  if (fees.isEmpty) return null;
  final all = fees['ALL'];
  if (profile == null) return all;
  final yours = [
    fees[profile.category.wire],
    if (profile.isPwbd) fees['PWBD'],
    if (profile.isExServiceman) fees['EXSM'],
  ].whereType<int>();
  if (yours.isEmpty) return all;
  return yours.reduce((a, b) => a < b ? a : b);
}

/// "₹500"
String rupees(int amount) {
  final s = '$amount';
  if (s.length <= 3) return '₹$s';
  // Indian grouping: 1,23,456.
  final last3 = s.substring(s.length - 3);
  var rest = s.substring(0, s.length - 3);
  final groups = <String>[];
  while (rest.length > 2) {
    groups.insert(0, rest.substring(rest.length - 2));
    rest = rest.substring(0, rest.length - 2);
  }
  if (rest.isNotEmpty) groups.insert(0, rest);
  return '₹${groups.join(',')},$last3';
}

/// The table in one line, cheapest groups together: "UR/OBC/EWS ₹500 · SC/ST ₹250".
String feeTable(Map<String, int> fees) {
  if (fees.containsKey('ALL') && fees.length == 1) return '${rupees(fees['ALL']!)} for all';
  final byAmount = <int, List<String>>{};
  for (final e in fees.entries) {
    byAmount.putIfAbsent(e.value, () => []).add(_label[e.key] ?? e.key);
  }
  final amounts = byAmount.keys.toList()..sort((a, b) => b.compareTo(a));
  return [for (final a in amounts) '${byAmount[a]!.join('/')} ${a == 0 ? 'free' : rupees(a)}'].join(' · ');
}

const _label = {'PWBD': 'PwBD', 'WOMEN': 'Women', 'EXSM': 'Ex-SM', 'ALL': 'All'};

/// RRB's rule since 2019, for its notifications that don't print it in a way the
/// reader caught: most of the fee comes back once you sit the first CBT.
const kRrbRefund = 'RRB refunds most of the fee after you attend the first CBT '
    '(₹400 of ₹500, or all of ₹250), minus bank charges.';

/// The refund rule for this exam: the notification's own, else RRB's.
String? refundRule(TrackedApplication app) {
  final printed = app.timelineRaw?['fee_refund'];
  if (printed is String && printed.trim().isNotEmpty) return printed.trim();
  final org = '${app.organization ?? ''} ${app.examName}'.toLowerCase();
  final rrb = org.contains('railway recruitment') || RegExp(r'\brrbs?\b').hasMatch(org);
  final rrc = org.contains('railway recruitment cell') || RegExp(r'\brrc\b').hasMatch(org);
  return rrb && !rrc ? kRrbRefund : null;
}

/// Fees you said you paid, for exams applied to in [year].
({int total, int exams}) feesPaidIn(Iterable<TrackedApplication> apps, int year) {
  var total = 0, exams = 0;
  for (final a in apps) {
    final paid = a.feePaid;
    // Later tiers cost nothing new; a form not paid for isn't paid yet.
    if (paid == null || a.notPaid || a.createdAt.toLocal().year != year || a.tier > 0) continue;
    total += paid;
    exams++;
  }
  return (total: total, exams: exams);
}
