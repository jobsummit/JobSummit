/// A job someone shared to JobSummit (a WhatsApp or Telegram message, a link from
/// the browser): which of the jobs or exams the app already has it is. Pure (no I/O).
library;

import 'package:flutter/foundation.dart';

import '../models/feed.dart';
import '../models/tracked_application.dart';
import 'exam_catalog.dart';

/// What a share is: its first link, and the words around it.
@immutable
class SharedText {
  const SharedText({required this.words, this.url});

  factory SharedText.parse(String raw) {
    final url = _url.firstMatch(raw)?.group(0);
    final words = raw.replaceAll(_url, ' ').replaceAll(RegExp(r'[ \t]+'), ' ').trim();
    return SharedText(words: words, url: url?.replaceAll(RegExp(r'[).,;!]+$'), ''));
  }

  final String words;
  final String? url;

  /// Too few words to tell the exam: the page's own title should be read.
  bool get needsPageTitle => url != null && _significant(words).length < 2;

  /// A name to start "Track it yourself" with.
  String get suggestedName {
    final line = words.split(RegExp(r'[\n|•–—:]')).map((s) => s.trim()).firstWhere((s) => s.length >= 3, orElse: () => '');
    return line.length > 80 ? line.substring(0, 80) : line;
  }
}

final _url = RegExp(r'https?://\S+', caseSensitive: false);

@immutable
class ShareMatch {
  const ShareMatch({this.jobs = const [], this.tracked = const []});

  /// Jobs in your list (or hidden from it) that it is, best first.
  final List<FeedItem> jobs;

  /// Exams you already track that it is.
  final List<TrackedApplication> tracked;

  bool get isEmpty => jobs.isEmpty && tracked.isEmpty;
}

// Words every job message has: they say nothing about which job.
const _filler = {
  'notification', 'notifications', 'recruitment', 'recruitments', 'apply', 'online', 'offline', 'out', 'released',
  'form', 'forms', 'link', 'links', 'last', 'date', 'dates', 'vacancy', 'vacancies', 'post', 'posts', 'job', 'jobs',
  'the', 'for', 'of', 'and', 'in', 'to', 'at', 'on', 'now', 'new', 'latest', 'check', 'here', 'click', 'details',
  'eligibility', 'salary', 'age', 'limit', 'fee', 'application', 'www', 'http', 'https', 'com', 'org', 'gov',
  'nic', 'html', 'php', 'aspx', 'pdf', 'notice', 'advt', 'advertisement', 'no', 'total', 'official', 'website',
  'government', 'govt', 'sarkari', 'naukri', 'result', 'exam', 'examination', 'start', 'started', 'begin', 'open',
  'opens', 'closing', 'close', 'closes', 'till', 'upto', 'up', 'by', 'from', 'with', 'is', 'are', 'has', 'have',
};

final _year = RegExp(r'^(?:19|20)\d\d$');

Set<String> _significant(String text) => {
      for (final m in RegExp('[a-z0-9]+').allMatches(text.toLowerCase()))
        if (m[0]!.length > 1 && !_filler.contains(m[0])) m[0]!,
    };

/// "Staff Selection Commission" -> "ssc", so a message that says only "SSC" counts.
String? _initials(String org) {
  final words = [
    for (final w in RegExp('[A-Za-z]+').allMatches(org))
      if (!{'of', 'the', 'and', 'for'}.contains(w[0]!.toLowerCase())) w[0]!,
  ];
  return words.length >= 2 ? words.map((w) => w[0]).join().toLowerCase() : null;
}

/// How surely [shared] names this exam, 0..1.
@visibleForTesting
double shareScore(Set<String> shared, String examName, String organization) {
  final name = _significant('$examName $organization');
  final initials = _initials(organization);
  if (initials != null) name.add(initials);
  if (_otherYear(shared, name)) return 0;
  final words = name.where((w) => !_year.hasMatch(w)).toSet();
  if (words.isEmpty) return 0;
  final hits = words.intersection(shared).length;
  if (hits < 2) return 0;
  // The exam's own words matter more than the board's full name.
  final own = _significant(examName).where((w) => !_year.hasMatch(w)).toSet();
  final ownHits = own.intersection(shared).length;
  return own.isEmpty ? hits / words.length : 0.5 * hits / words.length + 0.5 * ownHits / own.length;
}

/// A message about 2025's exam isn't this year's.
bool _otherYear(Set<String> shared, Set<String> name) {
  final years = name.where(_year.hasMatch).toSet();
  final sharedYears = shared.where(_year.hasMatch).toSet();
  return years.isNotEmpty && sharedYears.isNotEmpty && years.intersection(sharedYears).isEmpty;
}

const _enough = 0.6;

/// Which of [jobs] and [tracked] the share is. [jobs]: your list and what is hidden
/// from it. The exam list's own reading decides when it knows the exam.
ShareMatch matchShared(
  SharedText share, {
  required Iterable<FeedItem> jobs,
  required Iterable<TrackedApplication> tracked,
  String pageTitle = '',
}) {
  final text = '${share.words} $pageTitle';
  final shared = _significant(text);
  final catalog = matchCatalogExam(text);
  final link = share.url == null ? null : _bareLink(share.url!);

  double scoreOf(String examName, String org, Iterable<String?> urls) {
    if (link != null && urls.any((u) => u != null && _bareLink(u) == link)) return 1;
    final theirs = matchCatalogExam('$examName $org');
    // The exam list tells NTPC Graduate from NTPC Undergraduate better than words do.
    if (catalog != null && theirs != null && catalog.id != theirs.id) return 0;
    if (_otherYear(shared, _significant(examName))) return 0;
    final s = shareScore(shared, examName, org);
    return catalog != null && theirs?.id == catalog.id ? (s > 0.8 ? s : 0.8) : s;
  }

  final scoredJobs = [
    for (final j in jobs)
      if (scoreOf(j.examName, j.organization, [j.applyUrl, j.portalUrl]) case final s when s >= _enough) (j, s),
  ]..sort((a, b) => b.$2.compareTo(a.$2));
  final scoredApps = [
    for (final a in tracked)
      if (!a.archived)
        if (scoreOf(a.examName, a.organization ?? '', [a.applyUrl, a.portalUrl]) case final s when s >= _enough) (a, s),
  ]..sort((a, b) => b.$2.compareTo(a.$2));

  final trackedIds = {for (final (a, _) in scoredApps) a.jobPostId};
  return ShareMatch(
    jobs: [
      for (final (j, _) in scoredJobs.take(3))
        if (!trackedIds.contains(j.jobPostId)) j,
    ],
    tracked: [for (final (a, _) in scoredApps.take(2)) a],
  );
}

/// host + path, without www, query or a trailing slash.
String _bareLink(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null) return url;
  final path = u.path.endsWith('/') ? u.path.substring(0, u.path.length - 1) : u.path;
  return '${u.host.replaceFirst(RegExp(r'^www\.'), '')}$path'.toLowerCase();
}
