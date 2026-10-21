import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/eligibility.dart';
import '../domain/feed_builder.dart';
import '../domain/relevance.dart';
import '../domain/requirements.dart';
import '../domain/subjects.dart';
import '../models/feed.dart';
import '../models/job_preferences.dart';
import '../models/tracked_application.dart';
import '../services/backup_service.dart';
import 'account_providers.dart';
import 'backup_providers.dart';
import 'providers.dart';

// -----------------------------------------------------------------------------
// Preferences (Settings → Jobs)
// -----------------------------------------------------------------------------

class JobPreferencesNotifier extends AsyncNotifier<JobPreferences> {
  @override
  Future<JobPreferences> build() => JobPreferencesStore.read();

  Future<void> save(JobPreferences prefs) async {
    final stamped = prefs.copyWith(savedAt: DateTime.now().toUtc());
    await JobPreferencesStore.write(stamped);
    state = AsyncData(stamped);
    ref.read(backupControllerProvider.notifier).markDirty();
  }
}

final jobPreferencesProvider =
    AsyncNotifierProvider<JobPreferencesNotifier, JobPreferences>(JobPreferencesNotifier.new);

// -----------------------------------------------------------------------------
// Decisions: swipe right = applied, swipe left = not for me
// -----------------------------------------------------------------------------

@immutable
class JobDecision {
  const JobDecision({
    required this.jobPostId,
    required this.applied,
    required this.features,
    required this.title,
    required this.organization,
    required this.decidedAt,
    this.deadline,
  });

  final String jobPostId;
  final bool applied;
  final Set<String> features;
  final String title;
  final String organization;
  final DateTime? deadline;
  final DateTime decidedAt;

  factory JobDecision.of(FeedItem item, {required bool applied}) => JobDecision(
        jobPostId: item.jobPostId,
        applied: applied,
        features: jobFeatures(item),
        title: item.bestPost.postName,
        organization: item.organization,
        deadline: item.deadline,
        decidedAt: DateTime.now().toUtc(),
      );

  Map<String, Object?> toRow() => {
        'job_post_id': jobPostId,
        'decision': applied ? 'applied' : 'rejected',
        'features': jsonEncode(features.toList()),
        'title': title,
        'organization': organization,
        'deadline': deadline?.millisecondsSinceEpoch,
        'decided_at': decidedAt.millisecondsSinceEpoch,
      };

  factory JobDecision.fromRow(Map<String, Object?> r) => JobDecision(
        jobPostId: r['job_post_id']! as String,
        applied: r['decision'] == 'applied',
        features: {for (final f in jsonDecode(r['features']! as String) as List<dynamic>) f.toString()},
        title: r['title']! as String,
        organization: r['organization']! as String,
        deadline: r['deadline'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['deadline']! as int),
        decidedAt: DateTime.fromMillisecondsSinceEpoch(r['decided_at']! as int, isUtc: true),
      );
}

class DecisionsNotifier extends AsyncNotifier<List<JobDecision>> {
  @override
  Future<List<JobDecision>> build() async => [
        for (final r in await ref.read(databaseProvider).listDecisions())
          if (_tryParse(r) case final d?) d,
      ];

  static JobDecision? _tryParse(Map<String, Object?> r) {
    try {
      return JobDecision.fromRow(r);
    } catch (_) {
      return null;
    }
  }

  Future<void> record(FeedItem item, {required bool applied}) =>
      _save(JobDecision.of(item, applied: applied));

  Future<void> undo(String jobPostId) async {
    await ref.read(databaseProvider).deleteDecision(jobPostId);
    await BackupPrefs.addTombstone('decision:$jobPostId', DateTime.now()); // other phones forget it too
    await _reload();
  }

  Future<void> _save(JobDecision d) async {
    await ref.read(databaseProvider).saveDecision(d.toRow());
    await _reload();
  }

  Future<void> _reload() async {
    state = AsyncData(await build());
    ref.read(backupControllerProvider.notifier).markDirty();
  }
}

final decisionsProvider = AsyncNotifierProvider<DecisionsNotifier, List<JobDecision>>(DecisionsNotifier.new);

/// What your applications and rejections say you like.
final affinityProvider = Provider<Affinity>((ref) {
  final decisions = ref.watch(decisionsProvider).dataOrNull ?? const <JobDecision>[];
  return Affinity.fromDecisions(
      [for (final d in decisions) Decision(features: d.features, applied: d.applied)]);
});

// -----------------------------------------------------------------------------
// The job lists
// -----------------------------------------------------------------------------

/// Open jobs you qualify for that you haven't applied to or turned down (nor a
/// copy of them: one application covers all of a job's posts).
List<FeedItem> _undecided(Ref ref, List<FeedItem> items) {
  final tracked = ref.watch(trackedAppsProvider).dataOrNull ?? const <TrackedApplication>[];
  final trackedPostIds = {for (final a in tracked) a.id};
  final decided = {
    for (final a in tracked) if (a.jobPostId != null) a.jobPostId!,
    for (final d in ref.watch(decisionsProvider).dataOrNull ?? const <JobDecision>[]) d.jobPostId,
  };
  final now = ref.watch(nowProvider);
  return [
    for (final item in items)
      if (!trackedPostIds.contains(item.bestPost.postDetailId) &&
          !isDecidedJob(item, decided) &&
          item.deadline.isAfter(now))
        item,
  ];
}

final openJobsProvider =
    Provider<List<FeedItem>>((ref) => _undecided(ref, ref.watch(feedProvider).dataOrNull?.items ?? const []));

/// 💡 Near-misses (up to a year short on experience).
final nearMissJobsProvider = Provider<List<FeedItem>>(
    (ref) => _undecided(ref, ref.watch(feedProvider).dataOrNull?.suggested ?? const []));

String? _myLevel(Ref ref) => ref.watch(profileProvider).dataOrNull?.qualificationTier;

/// Your job preferences, with the professional qualifications your profile already
/// shows (a B.Ed or MBBS degree, "GNM" typed under Others) switched on.
final effectiveJobPreferencesProvider = Provider<JobPreferences>((ref) {
  final prefs = ref.watch(jobPreferencesProvider).dataOrNull ?? JobPreferences.defaults;
  final profile = ref.watch(profileProvider).dataOrNull;
  final fromProfile = qualificationsFromProfile(profile);
  return prefs.copyWith(
    qualifications: {...prefs.qualifications, ...fromProfile},
    subjects: subjectsFromProfile(profile),
    degreesHeld: profile == null ? const {} : profileDegreesHeld(profile),
  );
});

/// Ranked with your preferences and history (Jobs tab adds its own sort and filter).
final rankedJobsProvider = Provider<List<RankedJob>>((ref) => rankJobs(
      ref.watch(openJobsProvider),
      ref.watch(effectiveJobPreferencesProvider),
      ref.watch(affinityProvider),
      myLevel: _myLevel(ref),
    ));

final rankedNearMissProvider = Provider<List<RankedJob>>((ref) => rankJobs(
      ref.watch(nearMissJobsProvider),
      ref.watch(effectiveJobPreferencesProvider),
      ref.watch(affinityProvider),
      myLevel: _myLevel(ref),
    ));

/// Open jobs your preferences hide, each with why (listed so nothing feels lost).
final hiddenJobsProvider = Provider<List<(FeedItem, String)>>((ref) {
  final prefs = ref.watch(effectiveJobPreferencesProvider);
  final level = _myLevel(ref);
  return [
    for (final item in ref.watch(openJobsProvider))
      if (hiddenBecause(item, prefs, myLevel: level) case final reason?) (item, reason),
  ];
});

final hiddenJobCountProvider = Provider<int>((ref) => ref.watch(hiddenJobsProvider).length);

/// Today keeps it short: the best few, never a wall of cards.
const kTodayMatches = 3;

final topMatchesProvider = Provider<List<RankedJob>>(
    (ref) => ref.watch(rankedJobsProvider).take(kTodayMatches).toList(growable: false));

/// Jobs you swiped away, newest first, so they can be brought back.
final rejectedJobsProvider = Provider<List<JobDecision>>((ref) => [
      for (final d in ref.watch(decisionsProvider).dataOrNull ?? const <JobDecision>[])
        if (!d.applied) d,
    ]);

/// Which bottom tab is showing (Today, Jobs, My exams), so a chip on Today can jump.
class HomeTabNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void show(int index) => state = index;
}

final homeTabProvider = NotifierProvider<HomeTabNotifier, int>(HomeTabNotifier.new);

/// Opens the Jobs tab on one category (null = every category).
class JobsFilterNotifier extends Notifier<JobCategory?> {
  @override
  JobCategory? build() => null;

  void show(JobCategory? category) => state = category;
}

final jobsCategoryFilterProvider = NotifierProvider<JobsFilterNotifier, JobCategory?>(JobsFilterNotifier.new);

/// Swipe left on a job: hide it, remember why, and offer Undo.
Future<void> rejectJob(WidgetRef ref, FeedItem item) =>
    ref.read(decisionsProvider.notifier).record(item, applied: false);

/// Kept for the Undo of a swipe right as well.
Future<void> forgetDecision(WidgetRef ref, String jobPostId) =>
    ref.read(decisionsProvider.notifier).undo(jobPostId);
