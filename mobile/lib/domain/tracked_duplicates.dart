/// One application tracked twice: the same notice from two job sites (each copy
/// marked applied), or two posts of one job. Pure, no I/O.
library;

import '../models/jobs_data.dart';
import '../models/tracked_application.dart';
import 'feed_builder.dart' show advertKey, sameBoard;

String _istDay(DateTime d) {
  final ist = d.toUtc().add(const Duration(hours: 5, minutes: 30));
  return '${ist.year}-${ist.month}-${ist.day}';
}

String _name(String s) => s.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), ' ').trim();

/// [a] and [b] are one application. Only entries tracked from the Jobs list: two
/// exams added by hand with the same name can be different recruitments.
bool sameApplication(TrackedApplication a, TrackedApplication b, {List<PublishedJob> jobs = const []}) {
  final ja = a.jobPostId, jb = b.jobPostId;
  if (ja == null || jb == null || a.archived || b.archived || a.tier != b.tier) return false;
  if (ja == jb) return true; // two posts of one job
  // Copies the pipeline merged into one job.
  for (final job in jobs) {
    final ids = job.ids.toSet();
    if (ids.contains(ja) && ids.contains(jb)) return true;
  }
  // Otherwise: one closing day, one board, one exam and post, and no two
  // different advert numbers (SBI has several Specialist Cadre adverts at once).
  final da = a.deadline, db = b.deadline;
  if (da == null || db == null || _istDay(da) != _istDay(db)) return false;
  if (!sameBoard(a.organization ?? '', b.organization ?? '')) return false;
  final adA = advertKey(a.timelineRaw?['advertisement_no'] as String?);
  final adB = advertKey(b.timelineRaw?['advertisement_no'] as String?);
  if (adA != null && adB != null && adA != adB) return false;
  if (_name(a.postName) != _name(b.postName)) return false;
  final ca = a.catalogExam, cb = b.catalogExam;
  return (ca != null && ca.id == cb?.id) || _name(a.examName) == _name(b.examName);
}

/// Groups of entries that are one application, each with the one to keep first:
/// the one with your saved IDs ([withIds]), else the copy the Jobs list still
/// shows ([jobs]), else the one tracked first.
List<List<TrackedApplication>> duplicateGroups(
  List<TrackedApplication> apps, {
  List<PublishedJob> jobs = const [],
  Set<String> withIds = const {},
}) {
  final groups = <List<TrackedApplication>>[];
  for (final app in apps) {
    final group = groups.where((g) => g.any((o) => sameApplication(o, app, jobs: jobs))).firstOrNull;
    if (group == null) {
      groups.add([app]);
    } else {
      group.add(app);
    }
  }
  final listed = {for (final j in jobs) j.id};
  int rank(TrackedApplication a) =>
      (withIds.contains(a.id) ? 2 : 0) + (listed.contains(a.jobPostId) ? 1 : 0);
  return [
    for (final g in groups)
      if (g.length > 1)
        g
          ..sort((x, y) {
            final byRank = rank(y).compareTo(rank(x));
            return byRank != 0 ? byRank : x.createdAt.compareTo(y.createdAt);
          }),
  ];
}
