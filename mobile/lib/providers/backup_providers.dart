import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../config/env.dart';
import '../services/backup_service.dart';
import '../services/drive_backup_client.dart';
import 'account_providers.dart';
import 'jobs_providers.dart';
import 'limits_providers.dart';
import 'practice_providers.dart';
import 'xp_providers.dart';
import 'providers.dart';

enum BackupPhase {
  unavailable, // this build has no Google sign-in
  signedOut,
  idle,
  syncing,
  needsPermission, // Drive access was revoked: one tap to allow again
  offline,
  error,
}

@immutable
class BackupState {
  const BackupState(this.phase, {this.lastBackupAt, this.message, this.accountSwitchTo});

  final BackupPhase phase;
  final DateTime? lastBackupAt;
  final String? message;

  /// Signed in with a different Google account than the one this phone's data
  /// was backed up to: the user picks "merge" or "start fresh" before any sync.
  final String? accountSwitchTo;

  BackupState copyWith(
          {BackupPhase? phase, DateTime? lastBackupAt, String? message, String? accountSwitchTo}) =>
      BackupState(
        phase ?? this.phase,
        lastBackupAt: lastBackupAt ?? this.lastBackupAt,
        message: message,
        accountSwitchTo: accountSwitchTo,
      );
}

/// Keeps the Drive backup current: 10 s after a change, on app start (at most
/// every 15 min), on pull-to-refresh and on "Back up now". A fresh install
/// restores everything on the first sync after signing in.
class BackupController extends Notifier<BackupState> {
  Timer? _debounce;

  static const _debounceDelay = Duration(seconds: 10);
  static const _minInterval = Duration(minutes: 15);

  @override
  BackupState build() {
    ref.onDispose(() => _debounce?.cancel());
    final user = ref.watch(googleAccountProvider).dataOrNull;
    final phase =
        !Env.canSignIn ? BackupPhase.unavailable : (user == null ? BackupPhase.signedOut : BackupPhase.idle);
    unawaited(Future.microtask(() async {
      final last = await BackupPrefs.lastBackupAt();
      if (last != null && state.lastBackupAt == null) state = state.copyWith(lastBackupAt: last);
    }));
    return BackupState(phase);
  }

  bool get _signedIn => ref.read(googleAccountProvider).dataOrNull != null;

  /// Something on the phone changed: back it up shortly (offline: on the next sync).
  void markDirty() {
    unawaited(BackupPrefs.setDirty(true));
    if (!_signedIn) return;
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () => unawaited(sync()));
  }

  /// App start / pull-to-refresh: sync when something changed or it's been a while.
  Future<void> syncIfDue() async {
    if (!_signedIn) return;
    final last = await BackupPrefs.lastBackupAt();
    final due = last == null || DateTime.now().difference(last) > _minInterval;
    if (due || await BackupPrefs.isDirty()) await sync();
  }

  /// One pull-merge-push round. Returns null when it couldn't run (signed out,
  /// offline, needs permission, waiting for the account choice).
  Future<BackupOutcome?> sync({bool replaceLocal = false, bool mergeIntoNewAccount = false}) async {
    if (state.phase == BackupPhase.syncing) return null;
    final user = ref.read(googleAccountProvider).dataOrNull;
    if (user == null) return null;

    final owner = await BackupPrefs.dataOwner();
    if (owner != null && owner != user.email && !replaceLocal && !mergeIntoNewAccount) {
      state = state.copyWith(phase: BackupPhase.idle, accountSwitchTo: user.email);
      return null;
    }

    _debounce?.cancel();
    state = state.copyWith(phase: BackupPhase.syncing);
    final service = ref.read(googleAccountServiceProvider);
    final backup = BackupService(
      db: ref.read(databaseProvider),
      secrets: ref.read(secretStoreProvider),
      drive: DriveBackupClient(authHeaders: service.driveHeaders, onRejectedToken: service.invalidate),
    );
    try {
      if (replaceLocal) await _clearLocalBeforeFreshStart();
      final outcome = await backup.sync(replaceLocal: replaceLocal);
      await BackupPrefs.setDataOwner(user.email);
      state = BackupState(BackupPhase.idle, lastBackupAt: DateTime.now());
      await _afterSync(outcome);
      return outcome;
    } on DrivePermissionRequired {
      state = state.copyWith(phase: BackupPhase.needsPermission);
    } on SocketException {
      state = state.copyWith(phase: BackupPhase.offline);
    } on TimeoutException {
      state = state.copyWith(phase: BackupPhase.offline);
    } on http.ClientException {
      state = state.copyWith(phase: BackupPhase.offline);
    } on FormatException catch (e) {
      state = state.copyWith(phase: BackupPhase.error, message: e.message);
    } catch (e) {
      state = state.copyWith(phase: BackupPhase.error, message: 'Backup failed. It will try again later.');
    } finally {
      backup.close();
    }
    return null;
  }

  /// "Allow Drive backup" after the permission was revoked.
  Future<void> allowDrive() async {
    await ref.read(googleAccountServiceProvider).authorizeDrive();
    await sync();
  }

  /// Answer to the "different Google account" question.
  Future<BackupOutcome?> resolveAccountSwitch({required bool merge}) =>
      merge ? sync(mergeIntoNewAccount: true) : sync(replaceLocal: true);

  Future<void> _clearLocalBeforeFreshStart() async {
    final calendar = ref.read(calendarSyncProvider);
    for (final app in await ref.read(databaseProvider).listApplications()) {
      try {
        await calendar.removeFromCalendar(app.id);
      } catch (_) {}
    }
    await BackupPrefs.clearLocalState();
  }

  /// Show what changed, and put calendar reminders back for restored exams.
  Future<void> _afterSync(BackupOutcome outcome) async {
    final calendar = ref.read(calendarSyncProvider);
    for (final id in outcome.removedIds) {
      try {
        await calendar.removeFromCalendar(id);
      } catch (_) {}
    }
    await ref.read(trackedAppsProvider.notifier).reload();
    if (outcome.profileRestored) ref.invalidate(profileProvider);
    ref
      ..invalidate(decisionsProvider)
      ..invalidate(jobPreferencesProvider)
      // Practice and XP may have come from another phone.
      ..invalidate(practiceHistoryProvider)
      ..invalidate(mistakesProvider)
      ..invalidate(attemptsUsedProvider)
      ..invalidate(xpProvider);
    final db = ref.read(databaseProvider);
    for (final id in outcome.calendarWanted) {
      final app = await db.getApplication(id);
      if (app == null) continue;
      try {
        await calendar.syncExamToCalendar(app); // asks for calendar permission once if needed
      } catch (_) {}
    }
    if (outcome.calendarWanted.isNotEmpty) await ref.read(trackedAppsProvider.notifier).reload();
  }
}

final backupControllerProvider = NotifierProvider<BackupController, BackupState>(BackupController.new);

/// "Backed up · 5 min ago", "Backing up…", … for the account menu.
String backupStatusLabel(BackupState s, DateTime now) => switch (s.phase) {
      BackupPhase.unavailable => 'Backup not set up in this build',
      BackupPhase.signedOut => 'Not backed up · sign in to keep a copy',
      BackupPhase.syncing => 'Backing up…',
      BackupPhase.needsPermission => 'Backup paused · Drive permission needed',
      BackupPhase.offline => 'Offline · will back up later',
      BackupPhase.error => s.message ?? 'Backup failed · will retry',
      BackupPhase.idle =>
        s.lastBackupAt == null ? 'Not backed up yet' : 'Backed up · ${_ago(s.lastBackupAt!, now)}',
    };

String _ago(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}
