import 'package:flutter/foundation.dart';

import '../models/feed.dart';
import '../models/tracked_application.dart';
import 'urgency.dart';

enum NextStepKind { apply, finishForm, downloadAdmitCard, attendExam, prepareForExam }

@immutable
class NextStep {
  const NextStep({
    required this.kind,
    required this.title,
    required this.due,
    required this.urgency,
    this.actionUrl,
    this.application,
    this.feedItem,
  });

  final NextStepKind kind;
  final String title;
  final DateTime due;
  final Urgency urgency;
  final String? actionUrl;
  final TrackedApplication? application; // set for tracked-app steps
  final FeedItem? feedItem; // set for "apply" steps

  /// Stable across rebuilds: what "Not now" remembers.
  String get id => '${kind.name}:${feedItem?.jobPostId ?? application?.id ?? title}';

  /// Not applied yet: the application form. Applied: the same site's login, where
  /// fees, corrections and admit cards live.
  String get actionLabel => switch (kind) {
        NextStepKind.apply => 'Apply online',
        NextStepKind.finishForm => 'Finish & pay',
        NextStepKind.downloadAdmitCard => 'Download admit card',
        NextStepKind.attendExam || NextStepKind.prepareForExam => 'Application login',
      };
}

/// Picks the single most time-critical pending action across tracked
/// applications and unapplied feed items. Returns null when nothing is pending.
NextStep? computeNextStep({
  required Iterable<TrackedApplication> tracked,
  required Iterable<FeedItem> feed,
  required DateTime now,
}) =>
    computeNextSteps(tracked: tracked, feed: feed, now: now).firstOrNull;

/// Every pending action, most time-critical first (Today's Focus queue).
List<NextStep> computeNextSteps({
  required Iterable<TrackedApplication> tracked,
  required Iterable<FeedItem> feed,
  required DateTime now,
}) {
  final candidates = <NextStep>[];

  for (final app in tracked) {
    if (app.archived) continue;
    final due = app.deadline;
    if (app.feeUnpaid && due != null && due.isAfter(now)) {
      candidates.add(NextStep(
        kind: NextStepKind.finishForm,
        title: 'Finish your form: ${app.examName}',
        due: due,
        urgency: urgencyFor(due, now),
        actionUrl: app.loginUrl,
        application: app,
      ));
      continue;
    }
    final exam = app.examAt;
    if (exam == null || !exam.isAfter(now)) continue;

    final (kind, title) = switch (app.status) {
      ApplicationStatus.admitCardLive => (
          NextStepKind.downloadAdmitCard,
          'Download admit card for ${app.examName}'
        ),
      ApplicationStatus.examScheduled => (NextStepKind.attendExam, 'Exam: ${app.examName}'),
      ApplicationStatus.started || ApplicationStatus.applied => (NextStepKind.prepareForExam, 'Prepare for ${app.examName}'),
    };
    candidates.add(NextStep(
      kind: kind,
      title: title,
      due: exam,
      urgency: urgencyFor(exam, now),
      actionUrl: app.actionUrl,
      application: app,
    ));
  }

  for (final item in feed) {
    if (!item.deadline.isAfter(now)) continue;
    candidates.add(NextStep(
      kind: NextStepKind.apply,
      title: 'Apply for ${item.bestPost.postName} — ${item.organization}',
      due: item.deadline,
      urgency: urgencyFor(item.deadline, now),
      actionUrl: item.applicationUrl,
      feedItem: item,
    ));
  }

  // Earliest due wins; on a tie, act on what you already applied for first.
  candidates.sort((a, b) {
    final byDue = a.due.compareTo(b.due);
    return byDue != 0 ? byDue : _tiePriority(a.kind).compareTo(_tiePriority(b.kind));
  });
  return candidates;
}

int _tiePriority(NextStepKind k) => switch (k) {
      NextStepKind.finishForm => 0,
      NextStepKind.downloadAdmitCard => 0,
      NextStepKind.attendExam => 1,
      NextStepKind.apply => 2,
      NextStepKind.prepareForExam => 3,
    };
