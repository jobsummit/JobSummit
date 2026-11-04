/// Agenda: every dated thing in one list, by day: last days of jobs that fit you,
/// and the fee, correction, admit card, exam, answer key, objection and result
/// dates of the exams you track. Pure (no I/O).
library;

import 'package:flutter/foundation.dart';

import '../models/feed.dart';
import '../models/tracked_application.dart';

enum AgendaKind { deadline, fee, correction, admitCard, exam, answerKey, objection, result }

@immutable
class AgendaItem {
  const AgendaItem({
    required this.at,
    required this.kind,
    required this.title,
    required this.subtitle,
    this.app,
    this.job,
  });

  final DateTime at;
  final AgendaKind kind;
  final String title;
  final String subtitle;
  final TrackedApplication? app; // a tracked exam's date
  final FeedItem? job; // a job's last day

  DateTime get day => agendaDay(at);

  /// "Last day", "Exam", "Admit card"…: the pill on the row.
  String get tag => switch (kind) {
        AgendaKind.deadline => 'Last day',
        AgendaKind.fee => 'Fee',
        AgendaKind.correction => 'Corrections',
        AgendaKind.admitCard => 'Admit card',
        AgendaKind.exam => 'Exam',
        AgendaKind.answerKey => 'Answer key',
        AgendaKind.objection => 'Objections',
        AgendaKind.result => 'Result',
      };
}

DateTime agendaDay(DateTime t) => DateTime(t.year, t.month, t.day);

/// From the start of today up to [horizon] ahead, soonest first. An exam whose
/// window has started but not ended shows on today, so it isn't lost.
List<AgendaItem> buildAgenda({
  required Iterable<TrackedApplication> tracked,
  required Iterable<FeedItem> jobs,
  required DateTime now,
  Duration horizon = const Duration(days: 92),
}) {
  final today = agendaDay(now);
  final end = today.add(horizon);
  bool inRange(DateTime? t) => t != null && !agendaDay(t).isBefore(today) && t.isBefore(end);
  final items = <AgendaItem>[];

  for (final job in jobs) {
    if (!inRange(job.deadline)) continue;
    items.add(AgendaItem(
      at: job.deadline,
      kind: AgendaKind.deadline,
      title: job.bestPost.postName,
      subtitle: job.organization,
      job: job,
    ));
  }

  for (final app in tracked) {
    if (app.archived) continue;
    final name = app.examName;
    final t = app.timeline;
    void add(DateTime? at, AgendaKind kind, String subtitle) {
      if (inRange(at)) items.add(AgendaItem(at: at!, kind: kind, title: name, subtitle: subtitle, app: app));
    }

    add(t?.feeDeadline, AgendaKind.fee, 'Last day to pay the fee');
    add(t?.editWindowEnd, AgendaKind.correction, 'Correction window closes');
    if (app.displayStatus.index < TrackerStatus.admitCardLive.index) {
      add(t?.admitCardRelease, AgendaKind.admitCard, 'Admit card expected');
    }
    final start = app.effectiveExamAt;
    final finish = app.examEnd;
    if (start != null) {
      final windowOpen = start.isBefore(today) && finish != null && !agendaDay(finish).isBefore(today);
      final spread = finish != null && agendaDay(finish) != agendaDay(start);
      if (windowOpen) {
        items.add(AgendaItem(
          at: today,
          kind: AgendaKind.exam,
          title: name,
          subtitle: 'Exam window open until ${_dm(finish)}',
          app: app,
        ));
      } else {
        add(start, AgendaKind.exam, spread ? 'Exam window ${_dm(start)} – ${_dm(finish)}' : (app.tierName ?? 'Exam day'));
      }
    }
    add(t?.answerKeyRelease, AgendaKind.answerKey, 'Answer key expected');
    add(t?.objectionDeadline, AgendaKind.objection, 'Last day to challenge the answer key');
    add(t?.resultDate, AgendaKind.result, 'Result expected');
  }

  items.sort((a, b) => a.at.compareTo(b.at));
  return items;
}

/// Short month names, for dates written out ('Sat 31 Oct').
const kShortMonths = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _dm(DateTime d) => '${d.day} ${kShortMonths[d.month - 1]}';

/// The Week view's buckets: today, tomorrow, each other day of the next week
/// that has something, then "Later" for the rest.
@immutable
class AgendaBucket {
  const AgendaBucket(this.label, this.day, this.items);

  final String label;
  final DateTime? day; // null for "Later"
  final List<AgendaItem> items;
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

List<AgendaBucket> weekBuckets(List<AgendaItem> items, DateTime now) {
  final today = agendaDay(now);
  final weekEnd = today.add(const Duration(days: 7));
  final byDay = <DateTime, List<AgendaItem>>{};
  final later = <AgendaItem>[];
  for (final i in items) {
    if (i.day.isBefore(weekEnd)) {
      byDay.putIfAbsent(i.day, () => []).add(i);
    } else {
      later.add(i);
    }
  }
  String label(DateTime d) {
    final name = '${_weekdays[d.weekday - 1]} ${d.day}';
    if (d == today) return 'Today · $name';
    if (d == today.add(const Duration(days: 1))) return 'Tomorrow · $name';
    return name;
  }

  return [
    for (final d in byDay.keys.toList()..sort()) AgendaBucket(label(d), d, byDay[d]!),
    if (later.isNotEmpty) AgendaBucket('Later', null, later),
  ];
}
