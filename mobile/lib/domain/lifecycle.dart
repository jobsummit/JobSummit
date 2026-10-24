import 'package:flutter/foundation.dart';

import '../models/exam_timeline.dart';
import '../models/tracked_application.dart';

/// Applied → Admit card → Exam → Answer key → Result.
enum LifecycleStage {
  applied('Applied'),
  admitCard('Admit card'),
  exam('Exam'),
  answerKey('Answer key'),
  result('Result');

  const LifecycleStage(this.label);
  final String label;
}

/// Colour of a milestone: completed sage, active terracotta, upcoming honey (date
/// known), locked grey (nothing announced yet).
enum StageState { completed, active, upcoming, locked }

@immutable
class StageAction {
  const StageAction(this.label, this.url, {this.primary = false});

  final String label;
  final String url;
  final bool primary;
}

@immutable
class StageView {
  const StageView({
    required this.stage,
    required this.state,
    this.date,
    this.dateEnd,
    this.details = const [],
    this.actions = const [],
  });

  final LifecycleStage stage;
  final StageState state;
  final DateTime? date;
  final DateTime? dateEnd; // multi-day exam windows
  final List<String> details;
  final List<StageAction> actions;
}

DateTime _endOfDay(DateTime d) => DateTime(d.year, d.month, d.day, 23, 59, 59);

bool _passed(DateTime? d, DateTime now) => d != null && now.isAfter(_endOfDay(d));

/// Pure: everything comes from the server timeline plus what the user recorded
/// on this phone (admit card link, exam date, status).
List<StageView> computeLifecycle(TrackedApplication app, ExamTimeline? t, DateTime now) {
  final admitUrl = t?.admitCardUrl ?? app.admitCardUrl;
  // A date the user entered ("Set exam date", "Exam is done") wins over the notice's.
  final examStart = app.examAt ?? t?.examStart;
  final examEnd = app.examAt ?? t?.examEnd ?? examStart;
  final resultOut = t?.meritListUrl != null || t?.scorecardUrl != null || _passed(t?.resultDate, now);

  // A later milestone implies the earlier ones are done.
  final done = <LifecycleStage, bool>{
    LifecycleStage.result: resultOut,
  };
  done[LifecycleStage.answerKey] = done[LifecycleStage.result]! ||
      _passed(t?.objectionDeadline, now) ||
      (t?.answerKeyUrl != null && t?.objectionDeadline == null && t?.challengePortalUrl == null);
  done[LifecycleStage.exam] =
      done[LifecycleStage.answerKey]! || t?.answerKeyUrl != null || _passed(examEnd, now);
  done[LifecycleStage.admitCard] = done[LifecycleStage.exam]!;
  done[LifecycleStage.applied] = !app.feeUnpaid; // tracked == applied, unless the fee isn't paid

  final firstOpen = LifecycleStage.values.firstWhere((s) => !done[s]!, orElse: () => LifecycleStage.result);
  final allDone = LifecycleStage.values.every((s) => done[s]!);

  StageState stateOf(LifecycleStage s, {required bool hasDate, bool hasAction = false}) {
    if (done[s]!) return StageState.completed;
    if (!allDone && s == firstOpen) return StageState.active;
    return (hasDate || hasAction) ? StageState.upcoming : StageState.locked;
  }

  String cutoffLine(Map<String, double> marks) =>
      'Cut-off: ${marks.entries.map((e) => '${e.key} ${e.value % 1 == 0 ? e.value.toInt() : e.value}').join(' · ')}';

  return [
    StageView(
      stage: LifecycleStage.applied,
      state: app.feeUnpaid ? StageState.active : StageState.completed,
      date: t?.applicationEnd ?? app.deadline,
      details: [
        if (t?.feeDeadline != null && !_passed(t!.feeDeadline, now)) 'Pay the fee by ${_d(t.feeDeadline!)}',
        if (t?.editWindowStart != null && t?.editWindowEnd != null && !_passed(t!.editWindowEnd, now))
          'Correction window ${_d(t.editWindowStart!)} – ${_d(t.editWindowEnd!)}',
      ],
      actions: [
        if (app.feeUnpaid && app.loginUrl != null)
          StageAction('Finish & pay', app.loginUrl!, primary: true)
        else if (app.applicationUrl != null)
          StageAction('Application login', app.applicationUrl!),
      ],
    ),
    StageView(
      stage: LifecycleStage.admitCard,
      state: stateOf(LifecycleStage.admitCard,
          hasDate: t?.admitCardRelease != null, hasAction: admitUrl != null),
      date: t?.admitCardRelease,
      details: [if (admitUrl == null && t?.admitCardRelease != null) 'Expected around this date'],
      actions: [if (admitUrl != null) StageAction('Download admit card', admitUrl, primary: true)],
    ),
    StageView(
      stage: LifecycleStage.exam,
      state: stateOf(LifecycleStage.exam, hasDate: examStart != null),
      date: examStart,
      dateEnd: examEnd != null && examStart != null && examEnd.isAfter(examStart) ? examEnd : null,
      details: [
        if (t?.reportingTime != null) 'Reporting time: ${t!.reportingTime}',
        if (t?.shiftDetails != null) t!.shiftDetails!,
      ],
      actions: [if (t?.examCitySlipUrl != null) StageAction('Exam city slip', t!.examCitySlipUrl!)],
    ),
    StageView(
      stage: LifecycleStage.answerKey,
      state: stateOf(LifecycleStage.answerKey,
          hasDate: t?.answerKeyRelease != null, hasAction: t?.answerKeyUrl != null),
      date: t?.answerKeyRelease,
      details: [
        if (t?.objectionDeadline != null && !_passed(t!.objectionDeadline, now))
          'Objections close ${_d(t.objectionDeadline!)}',
      ],
      actions: [
        if (t?.answerKeyUrl != null) StageAction('View answer key', t!.answerKeyUrl!, primary: true),
        if (t?.challengePortalUrl != null && !_passed(t!.objectionDeadline, now))
          StageAction('Raise objection', t.challengePortalUrl!),
        if (t?.questionPaperUrl != null) StageAction('Question paper', t!.questionPaperUrl!),
      ],
    ),
    StageView(
      stage: LifecycleStage.result,
      state: stateOf(LifecycleStage.result, hasDate: t?.resultDate != null, hasAction: resultOut),
      date: t?.resultDate,
      details: [if (t != null && t.cutoffMarks.isNotEmpty) cutoffLine(t.cutoffMarks)],
      actions: [
        if (t?.meritListUrl != null) StageAction('Check result', t!.meritListUrl!, primary: true),
        if (t?.scorecardUrl != null) StageAction('Scorecard', t!.scorecardUrl!),
      ],
    ),
  ];
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "14 Dec"
String _d(DateTime d) => '${d.day} ${_months[d.month - 1]}';

/// "14 Dec" or "14 – 18 Dec" / "28 Nov – 3 Dec".
String stageDateLabel(DateTime start, [DateTime? end]) {
  if (end == null) return _d(start);
  if (start.month == end.month) return '${start.day} – ${_d(end)}';
  return '${_d(start)} – ${_d(end)}';
}
