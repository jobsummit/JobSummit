import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/tracked_application.dart';
import 'lifecycle.dart';

/// One stop on the delivery-style track.
@immutable
class TrackStop {
  const TrackStop({
    required this.label,
    required this.state,
    this.date,
    this.dateEnd,
    this.details = const [],
    this.actions = const [],
    this.isNextTier = false,
  });

  final String label;
  final StageState state;
  final DateTime? date;
  final DateTime? dateEnd;
  final List<String> details;
  final List<StageAction> actions;

  /// The "Tier-2" stop: its action tracks the next tier in the app.
  final bool isNextTier;
}

/// Applied → Admit card → Exam → Answer key → Result (→ next tier), where the
/// runner stops, and the one line and one action for that stop.
@immutable
class DeliveryTrack {
  const DeliveryTrack({
    required this.stops,
    required this.activeIndex,
    required this.headline,
    required this.statusLabel,
    this.action,
  });

  final List<TrackStop> stops;

  /// The stop the runner halts at. All done (final result out) = the last stop.
  final int activeIndex;
  final String headline;

  /// Short status for the card's badge: "Admit card out", "Exam starts 12 Oct",
  /// "Answer key expected Nov", "Result out".
  final String statusLabel;

  /// Opens a link, or (isNextTier stop) tracks the next tier.
  final StageAction? action;

  bool get finished => stops.every((s) => s.state == StageState.completed);
  bool get offersNextTier => stops[activeIndex].isNextTier;
}

/// How far the exam watcher's findings go, as a stop index: an admit card
/// found = at the admit card stop, a result = past the result stop.
int _watcherReach(TrackerStatus s) => switch (s) {
      TrackerStatus.applied => 0,
      TrackerStatus.admitCardLive => 1,
      TrackerStatus.examScheduled => 2,
      TrackerStatus.answerKeyLive => 3,
      TrackerStatus.resultDeclared => 5,
    };

const _stopLabels = ['Applied', 'Admit card', 'Exam', 'Answer key', 'Result'];
const _watcherKinds = [null, 'admit_card', 'exam_schedule', 'answer_key', 'result'];
const _watcherActions = [null, 'Download admit card', 'Exam notice', 'View answer key', 'Check result'];

/// Pure: from the notification's timeline, what the user recorded and what the
/// exam watcher found.
DeliveryTrack buildDeliveryTrack(TrackedApplication app, DateTime now) {
  final stages = computeLifecycle(app, app.timeline, now);
  // Once the exam has started, the admit card stage is behind you.
  final examStart = app.effectiveExamAt;
  final examStarted = examStart != null && !now.isBefore(DateTime(examStart.year, examStart.month, examStart.day));
  final reach = math.max(_watcherReach(app.displayStatus), examStarted ? 2 : 0);

  final stops = <TrackStop>[];
  for (var i = 0; i < stages.length; i++) {
    final v = stages[i];
    final kind = _watcherKinds[i];
    final found = kind == null ? null : app.latestUpdate(kind);
    stops.add(TrackStop(
      label: _stopLabels[i],
      state: v.state == StageState.completed || i < reach ? StageState.completed : v.state,
      date: v.date,
      dateEnd: v.dateEnd,
      details: v.details,
      actions: [
        ...v.actions,
        if (found != null && !v.actions.any((a) => a.url == found.open))
          StageAction(_watcherActions[i]!, found.open, primary: v.actions.every((a) => !a.primary)),
      ],
    ));
  }

  final next = app.nextTierName;
  if (next != null) {
    stops.add(TrackStop(label: next, state: StageState.locked, isNextTier: true));
  }

  // The first stop not done is "now"; anything past it that was marked active
  // by the timeline alone (the watcher knows better) becomes upcoming.
  var active = stops.indexWhere((s) => s.state != StageState.completed);
  for (var i = 0; i < stops.length; i++) {
    final s = stops[i];
    final state = i == active
        ? StageState.active
        : s.state == StageState.active
            ? StageState.upcoming
            : s.state;
    if (state != s.state) stops[i] = _withState(s, state);
  }
  if (active == -1) active = stops.length - 1;

  return DeliveryTrack(
    stops: stops,
    activeIndex: active,
    headline: _headline(app, stops, active, now),
    statusLabel: _statusLabel(app, stops, active, now),
    action: _action(app, stops[active]),
  );
}

TrackStop _withState(TrackStop s, StageState state) => TrackStop(
      label: s.label,
      state: state,
      date: s.date,
      dateEnd: s.dateEnd,
      details: s.details,
      actions: s.actions,
      isNextTier: s.isNextTier,
    );

StageAction? _action(TrackedApplication app, TrackStop stop) {
  if (stop.isNextTier) return StageAction('Track ${stop.label}', '', primary: true);
  // While objections are open, raising one is the step with a deadline.
  for (final a in stop.actions) {
    if (a.label == 'Raise objection') return a;
  }
  for (final a in stop.actions) {
    if (a.primary) return a;
  }
  if (stop.actions.isNotEmpty) return stop.actions.first;
  final login = app.loginUrl;
  return login == null ? null : StageAction('Candidate login', login);
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

const _monthsLong = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// When the answer key is likely: the announced date, else about three weeks after
/// the exam's last day (how SSC, IBPS and RRB usually do it). Null without dates.
DateTime? _answerKeyExpected(TrackedApplication app, List<TrackStop> stops) =>
    stops[3].date ?? app.examEnd?.add(const Duration(days: 21));

String _statusLabel(TrackedApplication app, List<TrackStop> stops, int active, DateTime now) {
  final stop = stops[active];
  final hasLink = stop.actions.isNotEmpty;
  if (stop.isNextTier) return 'Result out · next: ${stop.label}';
  if (stop.state == StageState.completed) return 'Result out';
  switch (active) {
    case 1:
      return hasLink ? 'Admit card out' : 'Admit card awaited';
    case 2:
      final start = stop.date;
      if (start == null) return 'Exam date awaited';
      if (stop.dateEnd != null && !now.isBefore(start)) return 'Exam on, till ${stageDateLabel(stop.dateEnd!)}';
      return stop.dateEnd != null ? 'Exam starts ${stageDateLabel(start)}' : 'Exam on ${stageDateLabel(start)}';
    case 3:
      if (hasLink) return 'Answer key out';
      final expected = _answerKeyExpected(app, stops);
      return expected == null ? 'Answer key awaited' : 'Answer key expected ${_monthsLong[expected.month - 1].substring(0, 3)}';
    case 4:
      final date = stop.date;
      return date == null ? 'Result awaited' : 'Result expected ${_monthsLong[date.month - 1].substring(0, 3)}';
    default:
      final due = app.deadline;
      if (app.feeUnpaid) return due == null ? 'Not paid' : 'Not paid · closes ${stageDateLabel(due)}';
      return 'Applied';
  }
}

String _headline(TrackedApplication app, List<TrackStop> stops, int active, DateTime now) {
  final tier = app.tierName;
  final p = tier == null ? '' : '$tier ';
  final stop = stops[active];
  final date = stop.date;
  final when = date == null ? '' : stageDateLabel(date, stop.dateEnd);
  final hasLink = stop.actions.isNotEmpty;

  if (stop.isNextTier) return '${_cap('${p}result is out.')} Next up: ${stop.label}.';
  if (stop.state == StageState.completed) return _cap('${p}result is out.'); // final tier, all done

  switch (active) {
    case 1:
      if (hasLink) {
        final exam = stops[2].date;
        return _cap('${p}admit card is out. Download it before the exam'
            '${exam == null ? '' : ' on ${stageDateLabel(exam)}'}.');
      }
      return date != null
          ? _cap('${p}admit card expected around $when. We’ll tell you the moment it’s out.')
          : _cap('waiting for the ${p}admit card. We’ll tell you the moment it’s out.');
    case 2:
      if (date == null) return _cap('${p}exam date isn’t announced yet. We’ll add it as soon as it is.');
      final reporting = stop.details.where((d) => d.startsWith('Reporting time')).firstOrNull;
      return _cap('${p}exam on $when.${reporting == null ? '' : ' $reporting.'}'
          ' Carry your admit card and photo ID.');
    case 3:
      if (!hasLink) {
        if (date != null) return _cap('${p}exam is done. The answer key is expected around $when.');
        final expected = _answerKeyExpected(app, stops);
        return expected == null
            ? _cap('${p}exam is done. We’ll tell you when the answer key is out.')
            : _cap('${p}exam is done. Answer keys usually come about 3 weeks later, so expect it '
                'around ${_monthsLong[expected.month - 1]}.');
      }
      final objection = app.timeline?.objectionDeadline;
      return objection != null && !now.isAfter(DateTime(objection.year, objection.month, objection.day, 23, 59))
          ? _cap('${p}answer key is out. Objections close ${stageDateLabel(objection)}.')
          : _cap('${p}answer key is out. Check your answers against it.');
    case 4:
      return _cap('waiting for the ${p}result${date == null ? '' : ', expected around $when'}.');
    default:
      if (app.feeUnpaid) {
        final due = app.deadline;
        return 'Form started. Pay the fee${due == null ? '' : ' by ${stageDateLabel(due)}'} to finish applying.';
      }
      return 'Applied. We’re watching for the admit card, dates and results.';
  }
}
