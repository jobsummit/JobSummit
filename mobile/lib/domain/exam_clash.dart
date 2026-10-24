/// Two of your exams on the same day, or a job you might apply to whose exam
/// would fall on one of yours. Pure (no I/O).
library;

import 'package:flutter/foundation.dart';

import '../models/exam_timeline.dart';
import '../models/feed.dart';
import '../models/tracked_application.dart';

/// [sure]: both are one-day exams on the same day. Otherwise at least one is a
/// window ("30 Sep – 30 Oct") and your own day is on the admit card: it may clash.
@immutable
class ExamClash {
  const ExamClash({required this.other, required this.day, required this.sure});

  /// The other exam's name.
  final String other;

  /// The first day both could be on.
  final DateTime day;
  final bool sure;

  /// "Same day as IBPS PO Mains · 12 Nov" / "May clash with SSC CGL · from 2 Oct".
  String get label => sure ? 'Same day as $other · ${_dm(day)}' : 'May clash with $other · from ${_dm(day)}';
}

typedef _Span = ({DateTime start, DateTime end});

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

_Span? _spanOf(DateTime? start, DateTime? end) {
  if (start == null) return null;
  final s = _day(start);
  final e = _day(end ?? start);
  return (start: s, end: e.isBefore(s) ? s : e);
}

_Span? _appSpan(TrackedApplication app, DateTime now) {
  if (app.archived || app.examOver(now)) return null;
  return _spanOf(app.effectiveExamAt, app.examEnd);
}

/// The exam dates a job's notification printed (its PDF), if any.
_Span? _jobSpan(FeedItem job) {
  final raw = job.timelineJson;
  if (raw == null) return null;
  try {
    final t = ExamTimeline.fromJson({...raw, 'job_post_id': job.jobPostId});
    return _spanOf(t.examStart, t.examEnd);
  } catch (_) {
    return null;
  }
}

ExamClash? _clash(_Span a, _Span b, String other) {
  final from = a.start.isAfter(b.start) ? a.start : b.start;
  final to = a.end.isBefore(b.end) ? a.end : b.end;
  if (from.isAfter(to)) return null;
  final sure = a.start == a.end && b.start == b.end;
  return ExamClash(other: other, day: from, sure: sure);
}

/// Each tracked exam's clashes with your other tracked exams, by app id.
Map<String, List<ExamClash>> examClashes(Iterable<TrackedApplication> apps, DateTime now) {
  final spans = [
    for (final a in apps)
      if (_appSpan(a, now) case final s?) (app: a, span: s),
  ];
  final out = <String, List<ExamClash>>{};
  for (var i = 0; i < spans.length; i++) {
    for (var j = i + 1; j < spans.length; j++) {
      final (a, b) = (spans[i], spans[j]);
      if (a.app.examName == b.app.examName) continue; // one exam tracked twice
      final ab = _clash(a.span, b.span, b.app.examName);
      if (ab == null) continue;
      out.putIfAbsent(a.app.id, () => []).add(ab);
      out.putIfAbsent(b.app.id, () => []).add(_clash(b.span, a.span, a.app.examName)!);
    }
  }
  return out;
}

/// Before you apply: would this job's exam fall on one of yours? The surest first.
ExamClash? jobClash(FeedItem job, Iterable<TrackedApplication> apps, DateTime now) {
  final mine = _jobSpan(job);
  if (mine == null) return null;
  ExamClash? best;
  for (final a in apps) {
    final theirs = _appSpan(a, now);
    if (theirs == null) continue;
    final c = _clash(mine, theirs, a.examName);
    if (c != null && (best == null || (c.sure && !best.sure))) best = c;
  }
  return best;
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _dm(DateTime d) => '${d.day} ${_months[d.month - 1]}';
