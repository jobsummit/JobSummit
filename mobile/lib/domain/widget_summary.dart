/// What the home-screen widget shows, from the Agenda: the next last day, the
/// next exam, and how many jobs close this week; and today's Daily 10. Dates are written out ("Sat 31
/// Oct"), never "in 2 days": the widget redraws only every half hour or so.
library;

import 'package:flutter/foundation.dart';

import 'agenda.dart';
import 'practice.dart';

@immutable
class WidgetSummary {
  const WidgetSummary({required this.deadline, required this.exam, required this.week, this.daily = ''});

  /// "SSC GD Constable · closes Sat 31 Oct", or "".
  final String deadline;

  /// "RRB NTPC Graduate · Thu 12 Nov", or "".
  final String exam;

  /// "3 jobs close this week", or "".
  final String week;

  /// "Daily 10 is ready" / "Daily 10 done · 8/10 · 3 days in a row".
  final String daily;

  Map<String, String> toJson() => {'deadline': deadline, 'exam': exam, 'week': week, 'daily': daily};
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _day(DateTime d, DateTime now) {
  final today = agendaDay(now);
  final day = agendaDay(d);
  if (day == today) return 'today';
  if (day == today.add(const Duration(days: 1))) return 'tomorrow';
  return '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';
}

WidgetSummary widgetSummary(List<AgendaItem> agenda, DateTime now, {List<PracticeResult> practice = const []}) {
  final deadlines = [for (final i in agenda) if (i.kind == AgendaKind.deadline && i.at.isAfter(now)) i];
  final exam = agenda.where((i) => i.kind == AgendaKind.exam).firstOrNull;
  final weekEnd = agendaDay(now).add(const Duration(days: 7));
  final thisWeek = deadlines.where((i) => i.at.isBefore(weekEnd)).length;
  final next = deadlines.firstOrNull;
  return WidgetSummary(
    deadline: next == null ? '' : '${next.title} · closes ${_day(next.at, now)}',
    exam: exam == null ? '' : '${exam.title} · ${_day(exam.at, now)}',
    week: thisWeek == 0 ? '' : '$thisWeek job${thisWeek == 1 ? '' : 's'} close this week',
    daily: _daily(now, practice),
  );
}

String _daily(DateTime now, List<PracticeResult> practice) {
  final done = dailyDoneOn(now, practice);
  final streak = dailyStreak(now, practice);
  final run = streak > 1 ? ' · $streak days in a row' : '';
  return done == null ? 'Daily 10 is ready$run' : 'Daily 10 done · ${done.right}/${done.total}$run';
}
