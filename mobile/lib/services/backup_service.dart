import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/backup_merge.dart';
import '../models/backup_snapshot.dart';
import '../models/job_preferences.dart';
import '../models/user_profile.dart';
import 'database_service.dart';
import 'drive_backup_client.dart';
import 'profile_store.dart';
import 'secret_store.dart';

/// Small bits of backup state kept in SharedPreferences.
abstract final class BackupPrefs {
  static const _deviceKey = 'backup.deviceId';
  static const _lastKey = 'backup.lastBackupAt';
  static const _dirtyKey = 'backup.dirty';
  static const _ownerKey = 'backup.dataOwner';
  static const _tombstonesKey = 'backup.tombstones';

  static Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  static Future<String> deviceId() async {
    final prefs = await _prefs;
    final existing = prefs.getString(_deviceKey);
    if (existing != null) return existing;
    final rnd = Random.secure();
    final id = List.generate(16, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    await prefs.setString(_deviceKey, id);
    return id;
  }

  static Future<DateTime?> lastBackupAt() async {
    final ms = (await _prefs).getInt(_lastKey);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<void> setLastBackupAt(DateTime at) async =>
      (await _prefs).setInt(_lastKey, at.millisecondsSinceEpoch);

  /// Something changed since the last backup (also set by the background watcher).
  static Future<bool> isDirty() async => (await _prefs).getBool(_dirtyKey) ?? false;
  static Future<void> setDirty(bool dirty) async => (await _prefs).setBool(_dirtyKey, dirty);

  /// The Google account whose backup this phone's data belongs to.
  static Future<String?> dataOwner() async => (await _prefs).getString(_ownerKey);
  static Future<void> setDataOwner(String email) async => (await _prefs).setString(_ownerKey, email);

  static Future<Map<String, DateTime>> tombstones() async {
    final raw = (await _prefs).getString(_tombstonesKey);
    if (raw == null) return {};
    try {
      return {
        for (final e in (jsonDecode(raw) as Map<String, dynamic>).entries)
          if (DateTime.tryParse('${e.value}') != null) e.key: DateTime.parse('${e.value}'),
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> setTombstones(Map<String, DateTime> t) async => (await _prefs).setString(
        _tombstonesKey,
        jsonEncode({for (final e in t.entries) e.key: e.value.toUtc().toIso8601String()}),
      );

  /// Remembers that an application was removed, so the backup removes it too.
  static Future<void> addTombstone(String appId, DateTime at) async {
    final t = await tombstones();
    t[appId] = at;
    await setTombstones(t);
  }

  /// "Start fresh": this phone's data is about to be replaced.
  static Future<void> clearLocalState() async {
    final prefs = await _prefs;
    await prefs.remove(_tombstonesKey);
    await prefs.remove(_lastKey);
  }
}

/// What a sync did, for the "Restored…" message and calendar follow-up.
@immutable
class BackupOutcome {
  const BackupOutcome({
    required this.restoredIds,
    required this.removedIds,
    required this.profileRestored,
    required this.calendarWanted,
    required this.hadBackup,
  });

  /// Applications that came from the backup (not on this phone before).
  final List<String> restoredIds;

  /// Applications removed because they were removed on another phone.
  final List<String> removedIds;
  final bool profileRestored;

  /// Restored applications that had calendar events on the other phone.
  final List<String> calendarWanted;
  final bool hadBackup;
}

/// Pull, merge and push the one backup file. Used from the foreground only
/// (Google tokens need the app open); the background just marks it dirty.
class BackupService {
  BackupService({required DatabaseService db, required SecretStore secrets, required DriveBackupClient drive})
      : _db = db,
        _secrets = secrets,
        _drive = drive;

  final DatabaseService _db;
  final SecretStore _secrets;
  final DriveBackupClient _drive;

  Future<BackupSnapshot> readLocal({DateTime? now}) async {
    final (profile, profileAt) = await ProfileStore.readStamped();
    final apps = {for (final r in await _db.exportApplicationRows()) r['id']! as String: r};
    final passwords = <String, String>{};
    for (final id in apps.keys) {
      final pw = await _secrets.readPassword(id);
      if (pw != null && pw.isNotEmpty) passwords[id] = pw;
    }
    return BackupSnapshot(
      savedAt: now ?? DateTime.now(),
      deviceId: await BackupPrefs.deviceId(),
      profile: profile?.toJson(),
      profileSavedAt: profileAt,
      applications: apps,
      vault: {for (final r in await _db.exportVaultRows()) r['app_id']! as String: r},
      passwords: passwords,
      tombstones: await BackupPrefs.tombstones(),
      decisions: {for (final r in await _db.listDecisions()) r['job_post_id']! as String: r},
      jobPreferences: switch (await JobPreferencesStore.read()) {
        final p when p.savedAt != null => p.toJson(),
        _ => null,
      },
      progress: await _readProgress(),
    );
  }

  static Future<Map<String, Object?>> _readProgress() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <String, Object?>{};
    for (final key in kProgressKeys) {
      final raw = prefs.getString(key);
      if (raw == null) continue;
      try {
        out[key] = jsonDecode(raw);
      } catch (_) {} // unreadable: left out, never spread to other phones
    }
    return out;
  }

  /// [replaceLocal]: "start fresh from this account's backup" — this phone's data
  /// is dropped first instead of merged.
  Future<BackupOutcome> sync({bool replaceLocal = false, DateTime? now}) async {
    final at = now ?? DateTime.now();
    final existing = await _drive.find();
    final remote = existing == null
        ? null
        : BackupSnapshot.fromJson(jsonDecode(await _drive.download(existing.id)) as Map<String, dynamic>);

    final actualLocal = await readLocal(now: at);
    final local = replaceLocal ? BackupSnapshot(savedAt: at, deviceId: actualLocal.deviceId) : actualLocal;
    final merged = remote == null
        ? BackupSnapshot(
            savedAt: at,
            deviceId: local.deviceId,
            profile: local.profile,
            profileSavedAt: local.profileSavedAt,
            applications: local.applications,
            vault: local.vault,
            passwords: local.passwords,
            tombstones: local.tombstones,
            decisions: local.decisions,
            jobPreferences: local.jobPreferences,
            progress: local.progress,
          )
        : mergeSnapshots(local, remote, now: at);

    final outcome = await _apply(merged, actualLocal, replaceLocal: replaceLocal, hadBackup: remote != null);
    await _drive.upload(jsonEncode(merged.toJson()), existingId: existing?.id);
    await BackupPrefs.setLastBackupAt(at);
    await BackupPrefs.setDirty(false);
    return outcome;
  }

  Future<BackupOutcome> _apply(
    BackupSnapshot merged,
    BackupSnapshot local, {
    required bool replaceLocal,
    required bool hadBackup,
  }) async {
    final removed = [
      for (final id in local.applications.keys)
        if (!merged.applications.containsKey(id)) id
    ];
    final restored = [
      for (final id in merged.applications.keys)
        if (!local.applications.containsKey(id)) id
    ];
    await _db.importBackupRows(
      applications: merged.applications.values,
      vault: merged.vault.values,
      removeIds: removed,
    );
    for (final id in removed) {
      await _secrets.deletePassword(id);
    }
    for (final e in merged.passwords.entries) {
      if (local.passwords[e.key] != e.value) await _secrets.writePassword(e.key, e.value);
    }

    var profileRestored = false;
    final profile = merged.profile;
    if (profile == null && merged.profileSavedAt != null) {
      // Reset on another phone (or here): keep it reset, with its date.
      if (local.profile != null || merged.profileSavedAt != local.profileSavedAt) {
        await ProfileStore.reset(at: merged.profileSavedAt);
      }
    } else if (replaceLocal && profile == null) {
      await ProfileStore.clear();
    }
    if (profile != null &&
        (replaceLocal || merged.profileSavedAt != local.profileSavedAt || local.profile == null)) {
      final restoredProfile = UserProfileData.fromJson(profile);
      await ProfileStore.write(restoredProfile, savedAt: merged.profileSavedAt);
      profileRestored =
          local.profile == null || replaceLocal || jsonEncode(profile) != jsonEncode(local.profile);
    }
    await BackupPrefs.setTombstones(merged.tombstones);
    await _db.replaceDecisions(merged.decisions.values);
    final prefs = merged.jobPreferences;
    if (prefs != null && jsonEncode(prefs) != jsonEncode(local.jobPreferences)) {
      await JobPreferencesStore.write(JobPreferences.fromJson(prefs));
    }
    final store = await SharedPreferences.getInstance();
    for (final e in merged.progress.entries) {
      final json = jsonEncode(e.value);
      if (json != jsonEncode(local.progress[e.key])) await store.setString(e.key, json);
    }

    return BackupOutcome(
      restoredIds: restored,
      removedIds: removed,
      profileRestored: profileRestored,
      calendarWanted: [
        for (final id in restored)
          if (merged.applications[id]?['calendar_synced'] == 1) id,
      ],
      hadBackup: hadBackup,
    );
  }

  void close() => _drive.close();
}
