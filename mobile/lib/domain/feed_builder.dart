/// Builds the feed on the phone from jobs.json + the local profile: a port of
/// backend/app/services/feed.py. Deadline order, direct matches and 💡
/// suggestions in separate lists.
library;

import '../models/feed.dart';
import '../models/jobs_data.dart';
import '../models/user_profile.dart';
import 'eligibility.dart';
import 'urgency.dart';

FeedPost _feedPost(PublishedPost post, EligibilityResult r) => FeedPost(
      postDetailId: post.id,
      postCode: post.postCode,
      postName: post.postName,
      categoryQuotaSeats: r.categoryQuotaSeats,
      urOpenSeats: r.urOpenSeats,
      totalReachableSeats: r.totalReachableSeats,
      eligibleViaRelaxation: r.eligibleViaRelaxation,
      notes: r.reasons,
      matchKind: r.kind == EligibilityKind.suggested ? MatchKind.suggested : MatchKind.direct,
      matchReasonLabel: r.matchReason?.label,
      suggestionReasons: r.kind == EligibilityKind.suggested ? const ['experience_gap'] : const [],
    );

FeedItem _feedItem(PublishedJob job, List<FeedPost> posts, MatchKind kind) {
  posts.sort((a, b) => b.totalReachableSeats.compareTo(a.totalReachableSeats));
  final best = posts.first;
  final deadline = job.applicationDeadline!;
  final verb = kind == MatchKind.direct ? 'Apply for' : 'Check if you fit';
  return FeedItem(
    jobPostId: job.id,
    organization: job.organization,
    examName: job.examName,
    portalUrl: job.portalUrl,
    applyUrl: job.applyUrl,
    deadline: deadline,
    urgency: urgencyFor(deadline, DateTime.now()),
    nextStep: '$verb ${best.postName} (${job.organization}) — closes ${formatDue(deadline)}',
    bestPost: best,
    matchKind: kind,
    timelineJson: job.timelineJson,
    job: job,
    posts: List.unmodifiable(posts),
  );
}

const _orgFiller = {'of', 'the', 'and', 'for', 'office', 'department', 'govt', 'government'};
final _advertFiller =
    RegExp(r'\b(?:advt|advertisement|notification|notice|no|number|ref|reference|dated|dt)\b\.?');

/// "CEN No. 06/2026" and "CEN 6/2026" -> "cen-6-2026"; null when too short to tell.
/// Same rules as the pipeline (publish.py advert_key).
String? advertKey(String? advert) {
  if (advert == null) return null;
  String part(String p) => RegExp(r'^\d+$').hasMatch(p) ? (int.tryParse(p)?.toString() ?? p) : p;
  final parts = [
    for (final m in RegExp(r'[a-z]+|\d+').allMatches(advert.toLowerCase().replaceAll(_advertFiller, ' ')))
      part(m[0]!),
  ];
  final key = parts.join('-');
  return key.replaceAll('-', '').length >= 3 ? key : null;
}

List<String> _orgWords(String org) => [for (final m in RegExp('[a-z0-9]+').allMatches(org.toLowerCase())) m[0]!];

Set<String> _initials(List<String> words) => {
      for (final a in [
        words.map((w) => w[0]).join(),
        words.where((w) => !_orgFiller.contains(w)).map((w) => w[0]).join(),
      ])
        if (a.length > 1) a,
    };

/// One board, named two ways ("Railway Recruitment Boards", "Railway Recruitment
/// Board (RRB)"): one name's words, bar an acronym of the other, all in the other's,
/// so two districts' collectors stay apart.
bool sameBoard(String a, String b) {
  final wa = _orgWords(a), wb = _orgWords(b);
  if (wa.isEmpty || wb.isEmpty) return false;
  Set<String> significant(List<String> words, List<String> other) {
    final acronyms = _initials(other);
    return {
      for (final w in words)
        if (w.length > 1 && !_orgFiller.contains(w) && !acronyms.contains(w))
          w.length > 3 && w.endsWith('s') ? w.substring(0, w.length - 1) : w,
    };
  }

  final sa = significant(wa, wb), sb = significant(wb, wa);
  return sa.difference(sb).isEmpty || sb.difference(sa).isEmpty;
}

Set<String> _postNames(PublishedJob j) =>
    {for (final p in j.posts) _orgWords(p.postName).join(' ')};

bool _samePosts(PublishedJob a, PublishedJob b) {
  final pa = _postNames(a), pb = _postNames(b);
  if (pa.isEmpty || pb.isEmpty) return true;
  final smaller = pa.length < pb.length ? pa.length : pb.length;
  return pa.intersection(pb).length * 2 >= smaller;
}

/// The same notice published twice (two job sites, or the official PDF and a job
/// site's page): one advertisement number, one closing day in India, one board,
/// overlapping posts. One copy is kept: the one you applied through, else the one
/// with the most posts. The pipeline merges most of these already (same rules).
List<PublishedJob> withoutDuplicates(List<PublishedJob> jobs, Set<String> appliedPostIds) {
  String? key(PublishedJob j) {
    final adv = advertKey(j.advertisementNo);
    final due = j.applicationDeadline;
    if (adv == null || due == null) return null;
    final ist = due.toUtc().add(const Duration(hours: 5, minutes: 30));
    return '$adv|${ist.year}-${ist.month}-${ist.day}';
  }

  int rank(PublishedJob j) =>
      (j.posts.any((p) => appliedPostIds.contains(p.id)) ? 1000 : 0) + j.posts.length;

  final kept = <PublishedJob>[];
  for (final job in jobs) {
    final k = key(job);
    final twin = k == null
        ? -1
        : kept.indexWhere((o) => key(o) == k && sameBoard(o.organization, job.organization) && _samePosts(o, job));
    if (twin < 0) {
      kept.add(job);
    } else if (rank(job) > rank(kept[twin])) {
      kept[twin] = job;
    }
  }
  return kept;
}

/// You applied to or turned down this job, or a copy of it the pipeline merged in.
bool isDecidedJob(FeedItem item, Set<String> jobIds) =>
    (item.job?.ids ?? [item.jobPostId]).any(jobIds.contains);

/// [appliedPostIds]: posts already tracked on this phone (never shown again).
FeedSnapshot buildFeed({
  required JobsFile jobs,
  required UserProfileData profile,
  required Set<String> appliedPostIds,
  required DateTime now,
  required DateTime fetchedAt,
  bool fromCache = false,
  bool strictUrMigration = true,
}) {
  final open = [
    for (final j in withoutDuplicates(jobs.jobs, appliedPostIds))
      if (j.applicationDeadline != null && j.applicationDeadline!.isAfter(now)) j,
  ]..sort((a, b) {
      final byDeadline = a.applicationDeadline!.compareTo(b.applicationDeadline!);
      return byDeadline != 0 ? byDeadline : a.id.compareTo(b.id);
    });

  final direct = <FeedItem>[];
  final suggested = <FeedItem>[];
  for (final job in open) {
    final directPosts = <FeedPost>[];
    final suggestedPosts = <FeedPost>[];
    for (final post in job.posts) {
      if (appliedPostIds.contains(post.id)) continue;
      final EligibilityResult r;
      try {
        r = evaluateEligibility(profile, post, strictUrMigration: strictUrMigration);
      } on ArgumentError {
        continue; // DOB after the cut-off: corrupt data, never eligible
      }
      switch (r.kind) {
        case EligibilityKind.direct:
          directPosts.add(_feedPost(post, r));
        case EligibilityKind.suggested:
          suggestedPosts.add(_feedPost(post, r));
        case null:
          break;
      }
    }
    // A job you directly qualify for is never also listed as a suggestion.
    if (directPosts.isNotEmpty) {
      direct.add(_feedItem(job, directPosts, MatchKind.direct));
    } else if (suggestedPosts.isNotEmpty) {
      suggested.add(_feedItem(job, suggestedPosts, MatchKind.suggested));
    }
  }

  // Everything you qualify for: the Jobs tab lists it all, ranked on the phone
  // (domain/relevance.dart); Today still shows only the top few.
  return FeedSnapshot(
    items: List.unmodifiable(direct),
    hiddenCount: 0,
    suggested: List.unmodifiable(suggested),
    suggestedHiddenCount: 0,
    category: profile.category.wire,
    fetchedAt: fetchedAt,
    fromCache: fromCache,
  );
}
