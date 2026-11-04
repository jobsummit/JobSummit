import 'package:flutter/foundation.dart';

/// Version of the backup file. A phone refuses a backup written by a newer app
/// (it can't know what it would drop), instead of overwriting it.
const kBackupSchemaVersion = 1;

/// Saved settings that are progress, not settings: practice tests, the mistake
/// notebook, attempts you've used, XP. Backed up as they are stored.
const kProgressKeys = ['practice.history', 'practice.mistakes', 'limits.attempts', 'xp.state'];

/// Everything this phone holds for the user, as one JSON file in their Google
/// Drive's hidden app folder (`exam-tracker-backup.json`).
///
/// Application and vault entries are the SQLite rows as stored (snake_case
/// columns, UTC epoch-millisecond timestamps), so a restore writes them back unchanged.
@immutable
class BackupSnapshot {
  const BackupSnapshot({
    required this.savedAt,
    required this.deviceId,
    this.profile,
    this.profileSavedAt,
    this.applications = const {},
    this.vault = const {},
    this.passwords = const {},
    this.tombstones = const {},
    this.decisions = const {},
    this.jobPreferences,
    this.progress = const {},
  });

  final DateTime savedAt;

  /// The phone that wrote it (diagnostics only).
  final String deviceId;

  /// `UserProfileData.toJson()`.
  final Map<String, dynamic>? profile;
  final DateTime? profileSavedAt;

  /// Tracked application id -> `tracked_applications` row (+ `calendar_synced` 0/1).
  final Map<String, Map<String, Object?>> applications;

  /// Application id -> `credentials_vault` row (registration / roll number, notes).
  final Map<String, Map<String, Object?>> vault;

  /// Application id -> portal password. Protected by the Google account that owns
  /// the Drive folder (the user chose no extra PIN).
  final Map<String, String> passwords;

  /// Application id -> when it was removed, so a removal also reaches other phones.
  /// `decision:<job id>` marks an undone "applied" / "not for me".
  final Map<String, DateTime> tombstones;

  /// Job id -> `job_decisions` row (applied / not for me + the job's features).
  final Map<String, Map<String, Object?>> decisions;

  /// `JobPreferences.toJson()` (with its own `saved_at`), null if never set.
  final Map<String, dynamic>? jobPreferences;

  /// [kProgressKeys] -> their stored JSON, decoded.
  final Map<String, Object?> progress;

  bool get isEmpty => profile == null && applications.isEmpty;

  Map<String, Object?> toJson() => {
        'schema': kBackupSchemaVersion,
        'saved_at': savedAt.toUtc().toIso8601String(),
        'device_id': deviceId,
        'profile': profile,
        'profile_saved_at': profileSavedAt?.toUtc().toIso8601String(),
        'applications': applications.values.toList(),
        'vault': vault.values.toList(),
        'passwords': passwords,
        'tombstones': {for (final e in tombstones.entries) e.key: e.value.toUtc().toIso8601String()},
        'decisions': decisions.values.toList(),
        'job_preferences': jobPreferences,
        'progress': progress,
      };

  /// Throws [FormatException] for a backup from a newer app version.
  factory BackupSnapshot.fromJson(Map<String, dynamic> j) {
    final schema = (j['schema'] as num?)?.toInt() ?? 0;
    if (schema > kBackupSchemaVersion) {
      throw FormatException('This backup was made by a newer version of the app (schema $schema).');
    }
    Map<String, Map<String, Object?>> rows(Object? list, String key) => {
          for (final r in (list as List<dynamic>? ?? const []))
            if (r is Map<String, dynamic> && r[key] is String) r[key] as String: Map<String, Object?>.of(r),
        };
    return BackupSnapshot(
      savedAt: DateTime.tryParse(j['saved_at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      deviceId: j['device_id'] as String? ?? '',
      profile: j['profile'] as Map<String, dynamic>?,
      profileSavedAt: DateTime.tryParse(j['profile_saved_at'] as String? ?? ''),
      applications: rows(j['applications'], 'id'),
      vault: rows(j['vault'], 'app_id'),
      passwords: {
        for (final e in ((j['passwords'] as Map<String, dynamic>?) ?? const {}).entries)
          if (e.value is String) e.key: e.value as String,
      },
      tombstones: {
        for (final e in ((j['tombstones'] as Map<String, dynamic>?) ?? const {}).entries)
          if (DateTime.tryParse('${e.value}') != null) e.key: DateTime.parse('${e.value}'),
      },
      decisions: rows(j['decisions'], 'job_post_id'),
      jobPreferences: j['job_preferences'] as Map<String, dynamic>?,
      progress: {
        for (final e in ((j['progress'] as Map<String, dynamic>?) ?? const {}).entries)
          if (kProgressKeys.contains(e.key)) e.key: e.value,
      },
    );
  }
}
