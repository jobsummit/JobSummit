

import '../domain/exam_watcher.dart';
import '../domain/feed_builder.dart';
import '../domain/next_step.dart';
import '../domain/tracked_duplicates.dart';
import '../domain/xp.dart';
import '../models/feed.dart';
import '../models/jobs_data.dart';
import '../models/tracked_application.dart';
import '../models/vault_entry.dart';
import '../services/background_watch.dart';
import '../services/backup_service.dart';
import '../services/calendar_sync_service.dart';
import '../services/database_service.dart';
import '../services/jobs_repository.dart';
import '../services/secret_store.dart';
import '../services/update_service.dart';
import 'account_providers.dart';
import 'backup_providers.dart';
import 'dart:async';
import 'dart:convert';
import 'jobs_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'xp_providers.dart';

// -----------------------------------------------------------------------------
// Infrastructure
// -----------------------------------------------------------------------------

/// Opened in main() before runApp and injected via ProviderScope.overrides.
final databaseProvider = Provider<DatabaseService>(
  (ref) => throw UnimplementedError('databaseProvider must be overridden in main()'),
);

final secretStoreProvider = Provider<SecretStore>((ref) => SecretStore());

final updateServiceProvider = Provider<UpdateService>((ref) {
  final service = UpdateService();
  ref.onDispose(service.close);
  return service;
});

final calendarSyncProvider =
    Provider<CalendarSyncService>((ref) => CalendarSyncService(ref.watch(databaseProvider)));

/// Ticks once a minute so countdowns stay honest without per-widget timers.
class NowNotifier extends Notifier<DateTime> {
  @override
  DateTime build() {
    final timer = Timer.periodic(const Duration(minutes: 1), (_) => state = DateTime.now());
    ref.onDispose(timer.cancel);
    return DateTime.now();
  }
}

final nowProvider = NotifierProvider<NowNotifier, DateTime>(NowNotifier.new);

extension AsyncValueData<T> on AsyncValue<T> {
  /// Current data, including stale data kept during a reload; null otherwise.
  /// (Works the same on Riverpod 2.x and 3.x.)
  T? get dataOrNull => hasValue ? requireValue : null;
}

// -----------------------------------------------------------------------------
// Tracked applications (offline source of truth)
// -----------------------------------------------------------------------------

class TrackedAppsNotifier extends AsyncNotifier<List<TrackedApplication>> {
  DatabaseService get _db => ref.read(databaseProvider);
  SecretStore get _secrets => ref.read(secretStoreProvider);

  /// Every change below ends with this: the Drive backup follows ~10 s later.
  void _changed() => ref.read(backupControllerProvider.notifier).markDirty();

  @override
  Future<List<TrackedApplication>> build() async {
    final apps = await _db.listApplications();
    unawaited(_addToCalendar(apps)); // exams restored from a backup, or added before the switch
    return apps;
  }

  /// With "Add my exams to the calendar" on, exams not in the calendar yet get
  /// their deadline and exam date events.
  Future<void> _addToCalendar(Iterable<TrackedApplication> apps) async {
    try {
      if (!await CalendarAutoSync.enabled()) return;
      if (await ref.read(calendarSyncProvider).syncAll(apps) > 0) await reload();
    } catch (_) {
      // No calendar or permission taken away: the exam is tracked all the same.
    }
  }

  Future<void> reload() async => state = AsyncData(await _db.listApplications());

  /// Swipe-right: record the application immediately, credentials come later.
  Future<TrackedApplication> markAppliedFromFeed(FeedItem item, {String? category}) async {
    final now = DateTime.now();
    final post = item.bestPost;
    final app = TrackedApplication(
      id: post.postDetailId,
      examName: item.examName,
      postName: post.postName,
      organization: item.organization,
      status: ApplicationStatus.applied,
      deadline: item.deadline,
      portalUrl: item.portalUrl,
      applyUrl: item.applyUrl,
      category: category,
      totalSeats: post.totalReachableSeats,
      urSeats: post.urOpenSeats,
      quotaSeats: post.categoryQuotaSeats,
      createdAt: now,
      updatedAt: now,
      jobPostId: item.jobPostId,
    );
    await _db.upsertApplication(app);
    await ref.read(decisionsProvider.notifier).record(item, applied: true); // learns what you like
    unawaited(ref
        .read(xpProvider.notifier)
        .award(XpAction.appliedToJob, key: xpExamKey(jobPostId: item.jobPostId, examName: item.examName)));
    final timeline = item.timelineJson;
    // With the advert number: the exam watcher tells this recruitment from others.
    final advert = item.job?.advertisementNo;
    if (timeline != null) {
      await _db.saveTimeline(
          item.jobPostId, jsonEncode({...timeline, if (advert != null) 'advertisement_no': advert}));
    }
    await reload();
    _changed();
    unawaited(_addToCalendar([app]));
    return app;
  }

  /// Track an exam applied to outside the feed. The phone's exam watcher follows
  /// [portalUrl] (the board's website, if given) and the job-site notices that
  /// name the exam. [applyUrl] is the candidate login; [tiers] its stages.
  Future<TrackedApplication> addManual({
    required String examName,
    String? portalUrl,
    String? applyUrl,
    String? organization,
    List<String> tiers = const [],
    int tier = 0,
  }) async {
    final now = DateTime.now();
    final app = TrackedApplication(
      id: 'local-${now.microsecondsSinceEpoch}',
      examName: examName,
      postName: examName,
      organization: organization,
      status: ApplicationStatus.applied,
      portalUrl: portalUrl,
      applyUrl: applyUrl,
      tiers: tiers,
      tier: tier,
      createdAt: now,
      updatedAt: now,
    );
    await _db.upsertApplication(app);
    await reload();
    _changed();
    unawaited(ref.read(xpProvider.notifier).award(XpAction.addedExam, key: xpExamKey(examName: examName)));
    unawaited(checkForUpdates(force: true)); // its admit card may already be out
    unawaited(_addToCalendar([app]));
    return app;
  }

  /// The card's two links. Empty strings clear a link.
  Future<void> setLinks(String id, {required String loginUrl, required String officialUrl}) async {
    String? orNull(String s) => s.trim().isEmpty ? null : s.trim();
    await _db.updateLinks(id, applyUrl: orNull(loginUrl), portalUrl: orNull(officialUrl));
    await reload();
    _changed();
  }

  /// "Track Tier-2": the next tier becomes its own entry with the same links,
  /// registration number and password (the same login carries over), and the
  /// finished tier moves to the archive.
  Future<TrackedApplication?> trackNextTier(TrackedApplication app) async {
    final next = app.nextTierName;
    if (next == null) return null;
    final current = app.tierName;
    final base = current != null && app.examName.endsWith(' · $current')
        ? app.examName.substring(0, app.examName.length - ' · $current'.length)
        : app.examName;
    final added = await addManual(
      examName: '$base · $next',
      portalUrl: app.officialUrl,
      applyUrl: app.loginUrl,
      organization: app.organization,
      tiers: app.effectiveTiers,
      tier: app.tier + 1,
    );
    final vault = await _db.getVault(app.id);
    final password = await _secrets.readPassword(app.id);
    if (vault?.registrationId != null || password != null) {
      await saveCredentials(
          added.id, CredentialsInput(registrationId: vault?.registrationId ?? '', password: password ?? ''),
          earnXp: false); // copied over, not typed in
    }
    await setArchived(app.id, archived: true);
    return added;
  }

  /// Runs the exam watcher now (pull-to-refresh, app start). Throttled to once per
  /// 30 minutes unless [force]d; the background task runs it every ~4 hours.
  Future<int> checkForUpdates({bool force = false}) async {
    try {
      final found = await runWatchAndNotify(_db, force: force);
      await reload(); // also notices taken off as not about this round
      final combined = await combineDuplicates();
      if (found > 0 && combined == 0) _changed();
      return found;
    } catch (_) {
      return 0; // offline: the next run catches up
    }
  }

  /// One application tracked twice (the same notice from two job sites, each copy
  /// marked applied; two posts of one job) becomes one entry: the one with your
  /// IDs, else the copy the Jobs list shows, else the first. It gets what only the
  /// other had (IDs, password, exam date, notices); the other is removed, here and
  /// in the backup. Returns how many were removed.
  Future<int> combineDuplicates() async {
    final apps = state.dataOrNull ?? await _db.listApplications();
    if (apps.length < 2) return 0;
    final withIds = <String>{};
    for (final a in apps) {
      final vault = await _db.getVault(a.id);
      if ((vault != null && !vault.isEmpty) || await _secrets.readPassword(a.id) != null) withIds.add(a.id);
    }
    final jobs = ref.read(jobsLoadProvider).dataOrNull?.file.jobs ?? const <PublishedJob>[];
    var removed = 0;
    for (final [keep, ...others] in duplicateGroups(apps, jobs: jobs, withIds: withIds)) {
      for (final other in others) {
        await _absorb(keep.id, other);
        await untrack(other.id);
        removed++;
      }
    }
    return removed;
  }

  /// Copies onto [keepId] what only [other] has.
  Future<void> _absorb(String keepId, TrackedApplication other) async {
    final keep = await _db.getApplication(keepId);
    if (keep == null) return;
    final vault = await _db.getVault(keepId);
    final otherVault = await _db.getVault(other.id);
    if ((vault == null || vault.isEmpty) && otherVault != null && !otherVault.isEmpty) {
      await _db.upsertVault(VaultEntry(
          appId: keepId,
          registrationId: otherVault.registrationId,
          rollNumber: otherVault.rollNumber,
          notes: otherVault.notes));
    }
    final otherPassword = await _secrets.readPassword(other.id);
    if (otherPassword != null && await _secrets.readPassword(keepId) == null) {
      await _secrets.writePassword(keepId, otherPassword);
    }
    final status = other.status.index > keep.status.index ? other.status : keep.status;
    await _db.updateStatus(keepId, status,
        examAt: keep.examAt ?? other.examAt, admitCardUrl: keep.admitCardUrl ?? other.admitCardUrl);
    // Notices from both (strays from another round taken off again).
    final urls = {for (final u in keep.updates) u.url};
    final updates = [...keep.updates, for (final u in other.updates) if (!urls.contains(u.url)) u]
      ..sort((a, b) => (b.detectedAt ?? DateTime(0)).compareTo(a.detectedAt ?? DateTime(0)));
    final timeline = <String, dynamic>{
      ...?other.timelineRaw,
      for (final e in (keep.timelineRaw ?? const <String, dynamic>{}).entries)
        if (e.value != null) e.key: e.value,
    };
    if (timeline.isNotEmpty) timeline['job_post_id'] = keep.jobPostId ?? keep.id;
    final merged = [for (final u in updates.take(30)) u];
    await _db.saveWatcherState(
      keepId,
      status: advanceStatus(TrackerStatus.applied, [
        for (final u in merged)
          if (Milestone.fromWire(u.milestone) case final m?) m,
      ]).wire,
      updatesJson: jsonEncode([for (final u in merged) u.toJson()]),
      timelineJson: timeline.isEmpty ? null : jsonEncode(timeline),
    );
    final saved = await _db.getApplication(keepId);
    final fixed = saved == null ? null : withoutStrayUpdates(saved);
    if (fixed != null) {
      await _db.saveWatcherState(
        keepId,
        status: fixed.status.wire,
        updatesJson: jsonEncode([for (final u in fixed.updates) u.toJson()]),
        timelineJson: jsonEncode(fixed.timeline),
      );
    }
  }

  /// Delete, and the Undo for swipe-right: forget the exam entirely, with its
  /// calendar events, saved IDs and password, here and in the backup. A job
  /// that is still open returns to the feed.
  Future<void> untrack(String id) async {
    try {
      await ref.read(calendarSyncProvider).removeFromCalendar(id);
    } catch (_) {
      // Calendar permission revoked etc. — still untrack locally.
    }
    await _db.deleteApplication(id);
    await _secrets.deletePassword(id);
    await BackupPrefs.addTombstone(id, DateTime.now()); // so the backup forgets it too
    await reload();
    _changed();
  }

  /// The XP key for one of your tracked exams (by its id).
  String _xpKey(String appId) {
    final app = state.dataOrNull?.where((a) => a.id == appId).firstOrNull;
    return app == null ? 'app:$appId' : xpExamKey(jobPostId: app.jobPostId, examName: app.examName);
  }

  Future<void> saveCredentials(String appId, CredentialsInput input, {bool earnXp = true}) async {
    await _db.upsertVault(input.toEntry(appId));
    if (input.password.isNotEmpty) await _secrets.writePassword(appId, input.password);
    ref
      ..invalidate(vaultEntryProvider(appId))
      ..invalidate(hasPasswordProvider(appId));
    _changed();
    final entry = input.toEntry(appId);
    if (earnXp && (!entry.isEmpty || input.password.isNotEmpty)) {
      unawaited(ref.read(xpProvider.notifier).award(XpAction.savedIds, key: 'ids:${_xpKey(appId)}'));
    }
  }

  Future<void> setStatus(String id, ApplicationStatus status,
      {DateTime? examAt, String? admitCardUrl}) async {
    await _db.updateStatus(id, status, examAt: examAt, admitCardUrl: admitCardUrl);
    await reload();
    _changed();
    if (examAt != null) {
      unawaited(ref.read(xpProvider.notifier).award(XpAction.setExamDate, key: 'date:${_xpKey(id)}'));
    }
  }

  /// Optimistic so the Dismissible leaves the tree in the same frame.
  Future<void> setArchived(String id, {required bool archived}) async {
    final current = state.dataOrNull;
    if (current != null) {
      state = AsyncData([
        for (final a in current) a.id == id ? a.copyWith(archived: archived) : a,
      ]);
    }
    await _db.setArchived(id, archived: archived);
    await reload();
    _changed();
  }
}

final trackedAppsProvider =
    AsyncNotifierProvider<TrackedAppsNotifier, List<TrackedApplication>>(TrackedAppsNotifier.new);

final activeAppsProvider = Provider<List<TrackedApplication>>((ref) {
  final all = ref.watch(trackedAppsProvider).dataOrNull ?? const [];
  return [
    for (final a in all)
      if (!a.archived) a
  ];
});

final vaultEntryProvider = FutureProvider.autoDispose
    .family<VaultEntry?, String>((ref, appId) => ref.watch(databaseProvider).getVault(appId));

/// Only whether a password exists; the value itself is read on tap.
final hasPasswordProvider = FutureProvider.autoDispose
    .family<bool, String>((ref, appId) => ref.watch(secretStoreProvider).hasPassword(appId));

// -----------------------------------------------------------------------------
// Feed (online, with last-good cache for offline start-up)
// -----------------------------------------------------------------------------

final jobsRepositoryProvider = Provider<JobsRepository>((ref) {
  final repo = JobsRepository(ref.watch(databaseProvider));
  ref.onDispose(repo.close);
  return repo;
});

/// jobs.json from the data pipeline. Starts from the offline copy when there is
/// one (instant start-up), then refreshes from the network in the background.
class JobsLoadNotifier extends AsyncNotifier<JobsLoad?> {
  JobsRepository get _repo => ref.read(jobsRepositoryProvider);

  @override
  Future<JobsLoad?> build() async {
    final cached = await _repo.cached();
    if (cached != null) {
      unawaited(Future.microtask(refresh));
      return cached;
    }
    return _repo.load();
  }

  Future<void> refresh() async {
    final next = await AsyncValue.guard(_repo.load);
    // Keep showing the last good list when a refresh fails.
    if (next.hasValue || !state.hasValue) state = next;
  }
}

final jobsLoadProvider = AsyncNotifierProvider<JobsLoadNotifier, JobsLoad?>(JobsLoadNotifier.new);

/// The personalised feed, computed on this phone from jobs.json + the profile.
class FeedNotifier extends AsyncNotifier<FeedSnapshot> {
  @override
  Future<FeedSnapshot> build() async {
    final profile = await ref.watch(profileProvider.future);
    if (profile == null || !profile.isComplete) return FeedSnapshot.empty;
    final load = await ref.watch(jobsLoadProvider.future);
    if (load == null) return FeedSnapshot.empty;
    final tracked = ref.read(trackedAppsProvider).dataOrNull ?? const <TrackedApplication>[];
    return buildFeed(
      jobs: load.file,
      profile: profile,
      appliedPostIds: {for (final a in tracked) a.id},
      now: DateTime.now(),
      fetchedAt: load.fetchedAt,
      fromCache: load.fromCache,
    );
  }

  /// Pull-to-refresh: fetch jobs.json again (the feed rebuilds from it).
  Future<void> refresh() => ref.read(jobsLoadProvider.notifier).refresh();
}

final feedProvider = AsyncNotifierProvider<FeedNotifier, FeedSnapshot>(FeedNotifier.new);

// -----------------------------------------------------------------------------
// One Next Step
// -----------------------------------------------------------------------------

/// The most urgent of what you track and the best few jobs for you.
final nextStepProvider = Provider<NextStep?>((ref) => computeNextStep(
      tracked: ref.watch(activeAppsProvider),
      feed: [for (final r in ref.watch(rankedJobsProvider).take(5)) r.item],
      now: ref.watch(nowProvider),
    ));
