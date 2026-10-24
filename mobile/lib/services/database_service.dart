import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/tracked_application.dart';
import '../models/vault_entry.dart';
import 'local_cipher.dart';

/// Reference to an event this app wrote into the Android calendar.
class CalendarEventRef {
  const CalendarEventRef({
    required this.appId,
    required this.kind,
    required this.calendarId,
    required this.eventId,
  });

  final String appId;
  final String kind; // 'deadline' | 'exam'
  final String calendarId;
  final String eventId;
}

/// Offline-first local store. All timestamps are UTC epoch milliseconds.
class DatabaseService {
  DatabaseService._(this._db, this._cipher);

  final Database _db;

  /// Encrypts Reg/Roll numbers and notes at rest (key in the Keystore-backed store).
  final Future<LocalCipher> Function() _cipher;

  static const _fileName = 'exam_tracker.db';
  static const _version = 8;

  /// [factory]/[path] are injectable so tests can use sqflite_common_ffi in memory.
  static Future<DatabaseService> open(
      {DatabaseFactory? factory, String? path, Future<LocalCipher> Function()? cipher}) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), _fileName);
    final db = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: _version,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
    return DatabaseService._(db, cipher ?? LocalCipher.shared);
  }

  static Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch()
      ..execute('''
        CREATE TABLE tracked_applications (
          id                 TEXT PRIMARY KEY,
          exam_name          TEXT NOT NULL,
          post_name          TEXT NOT NULL,
          organization       TEXT,
          status             TEXT NOT NULL
                             CHECK (status IN ('applied','admit_card_live','exam_scheduled')),
          deadline_timestamp INTEGER,
          exam_timestamp     INTEGER,
          admit_card_url     TEXT,
          portal_url         TEXT,
          apply_url          TEXT,
          category           TEXT,
          total_seats        INTEGER,
          ur_seats           INTEGER,
          quota_seats        INTEGER,
          archived           INTEGER NOT NULL DEFAULT 0,
          created_at         INTEGER NOT NULL,
          updated_at         INTEGER NOT NULL,
          job_post_id        TEXT,
          timeline_json      TEXT,
          server_id          TEXT,
          server_status      TEXT,
          updates_json       TEXT,
          tiers_json         TEXT,
          tier               INTEGER NOT NULL DEFAULT 0,
          fee_unpaid         INTEGER NOT NULL DEFAULT 0,
          fee_paid           INTEGER,
          my_score           TEXT
        )''')
      ..execute(
          'CREATE INDEX ix_apps_active ON tracked_applications (archived, exam_timestamp, deadline_timestamp)')
      ..execute('''
        CREATE TABLE credentials_vault (
          app_id          TEXT PRIMARY KEY
                          REFERENCES tracked_applications(id) ON DELETE CASCADE,
          registration_id TEXT,
          roll_number     TEXT,
          notes           TEXT,
          updated_at      INTEGER NOT NULL
        )''')
      ..execute('''
        CREATE TABLE calendar_event_refs (
          app_id                    TEXT NOT NULL
                                    REFERENCES tracked_applications(id) ON DELETE CASCADE,
          kind                      TEXT NOT NULL CHECK (kind IN ('deadline','exam')),
          calendar_id               TEXT NOT NULL,
          android_calendar_event_id TEXT NOT NULL,
          synced_at                 INTEGER NOT NULL,
          PRIMARY KEY (app_id, kind)
        )''')
      ..execute('''
        CREATE TABLE feed_cache (
          id         INTEGER PRIMARY KEY CHECK (id = 1),
          body       TEXT NOT NULL,
          fetched_at INTEGER NOT NULL
        )''');
    _createDecisions(batch);
    _createJobReminders(batch);
    await batch.commit(noResult: true);
  }

  /// v5: last-day reminders for jobs you haven't applied to: the calendar event and
  /// when the last notification went out.
  static void _createJobReminders(Batch batch) => batch.execute('''
        CREATE TABLE IF NOT EXISTS job_reminders (
          job_post_id TEXT PRIMARY KEY,
          calendar_id TEXT,
          event_id    TEXT,
          deadline    INTEGER NOT NULL,
          notified_at INTEGER
        )''');

  /// v4: "applied" / "not for me" per job, with the job's features for learning.
  static void _createDecisions(Batch batch) => batch.execute('''
        CREATE TABLE IF NOT EXISTS job_decisions (
          job_post_id  TEXT PRIMARY KEY,
          decision     TEXT NOT NULL CHECK (decision IN ('applied','rejected')),
          features     TEXT NOT NULL,
          title        TEXT NOT NULL,
          organization TEXT NOT NULL,
          deadline     INTEGER,
          decided_at   INTEGER NOT NULL
        )''');

  /// v2: notification id, cached 5-stage timeline and exam-watcher state.
  /// v3: the application page ("Apply online" link).
  /// v6: the exam's stages (Tier-1, Tier-2…) and which one this entry tracks.
  /// v7: "fee not paid yet", and the fee you paid.
  static Future<void> _onUpgrade(Database db, int from, int to) async {
    if (from < 2) {
      for (final column in ['job_post_id', 'timeline_json', 'server_id', 'server_status', 'updates_json']) {
        await db.execute('ALTER TABLE tracked_applications ADD COLUMN $column TEXT');
      }
    }
    if (from < 3) {
      await db.execute('ALTER TABLE tracked_applications ADD COLUMN apply_url TEXT');
    }
    if (from < 4) {
      final batch = db.batch();
      _createDecisions(batch);
      await batch.commit(noResult: true);
    }
    if (from < 5) {
      final batch = db.batch();
      _createJobReminders(batch);
      await batch.commit(noResult: true);
    }
    if (from < 6) {
      await db.execute('ALTER TABLE tracked_applications ADD COLUMN tiers_json TEXT');
      await db.execute('ALTER TABLE tracked_applications ADD COLUMN tier INTEGER NOT NULL DEFAULT 0');
    }
    if (from < 7) {
      await db.execute('ALTER TABLE tracked_applications ADD COLUMN fee_unpaid INTEGER NOT NULL DEFAULT 0');
      await db.execute('ALTER TABLE tracked_applications ADD COLUMN fee_paid INTEGER');
    }
    if (from < 8) {
      await db.execute('ALTER TABLE tracked_applications ADD COLUMN my_score TEXT');
    }
  }

  Future<void> close() => _db.close();

  // ---------------------------------------------------------------------------
  // Google Drive backup: raw rows out, merged rows back in
  // ---------------------------------------------------------------------------

  static const _appColumns = [
    'id',
    'exam_name',
    'post_name',
    'organization',
    'status',
    'deadline_timestamp',
    'exam_timestamp',
    'admit_card_url',
    'portal_url',
    'apply_url',
    'category',
    'total_seats',
    'ur_seats',
    'quota_seats',
    'archived',
    'created_at',
    'updated_at',
    'job_post_id',
    'timeline_json',
    'server_id',
    'server_status',
    'updates_json',
    'tiers_json',
    'tier',
    'fee_unpaid',
    'fee_paid',
    'my_score',
  ];
  static const _vaultColumns = ['app_id', 'registration_id', 'roll_number', 'notes', 'updated_at'];

  /// Vault columns stored encrypted.
  static const _secretColumns = ['registration_id', 'roll_number', 'notes'];

  Future<Map<String, Object?>> _sealRow(Map<String, Object?> row) async {
    final cipher = await _cipher();
    return {
      ...row,
      for (final k in _secretColumns)
        if (row.containsKey(k)) k: await cipher.encryptOrNull(row[k]),
    };
  }

  Future<Map<String, Object?>> _openRow(Map<String, Object?> row) async {
    final cipher = await _cipher();
    return {
      ...row,
      for (final k in _secretColumns)
        if (row.containsKey(k)) k: await cipher.decryptOrNull(row[k]),
    };
  }

  @visibleForTesting
  Future<List<Map<String, Object?>>> rawVaultRowsForTest() => _db.query('credentials_vault');

  @visibleForTesting
  Future<void> rawInsertVaultForTest(Map<String, Object?> row) => _db.insert('credentials_vault', row);

  /// Encrypts Reg/Roll numbers saved before they were encrypted (once, at start).
  /// Leaves `updated_at` alone, so the backup doesn't see a change.
  Future<int> encryptStoredIds() async {
    var count = 0;
    for (final row in await _db.query('credentials_vault')) {
      final plain = [for (final k in _secretColumns) row[k]]
          .whereType<String>()
          .any((v) => v.isNotEmpty && !LocalCipher.isEncrypted(v));
      if (!plain) continue;
      await _db.update('credentials_vault', Map.of(await _sealRow(Map.of(row)))..remove('app_id'),
          where: 'app_id = ?', whereArgs: [row['app_id']]);
      count++;
    }
    return count;
  }

  static Map<String, Object?> _only(Map<String, Object?> row, List<String> columns) => {
        for (final c in columns)
          if (row.containsKey(c)) c: row[c]
      };

  /// Every tracked application exactly as stored, plus `calendar_synced` (0/1).
  Future<List<Map<String, Object?>>> exportApplicationRows() async =>
      [for (final r in await _db.rawQuery('$_selectApps ORDER BY a.created_at')) Map.of(r)];

  /// Decrypted: the backup carries the numbers themselves.
  Future<List<Map<String, Object?>>> exportVaultRows() async =>
      [for (final r in await _db.query('credentials_vault')) await _openRow(Map.of(r))];

  /// Writes merged backup rows in one transaction: applications are updated in
  /// place or inserted (never REPLACE, which would cascade-delete their vault rows
  /// and calendar refs), vault rows replaced, and [removeIds] deleted.
  Future<void> importBackupRows({
    required Iterable<Map<String, Object?>> applications,
    required Iterable<Map<String, Object?>> vault,
    Iterable<String> removeIds = const [],
  }) async {
    final sealedVault = [for (final row in vault) await _sealRow(_only(row, _vaultColumns))];
    await _db.transaction((txn) async {
        for (final id in removeIds) {
          await txn.delete('tracked_applications', where: 'id = ?', whereArgs: [id]);
        }
        for (final row in applications) {
          final data = _only(row, _appColumns);
          final updated = await txn.update(
            'tracked_applications',
            Map.of(data)..remove('id'),
            where: 'id = ?',
            whereArgs: [data['id']],
          );
          if (updated == 0) await txn.insert('tracked_applications', data);
        }
        for (final row in sealedVault) {
          await txn.insert('credentials_vault', row, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      });
  }

  // ---------------------------------------------------------------------------
  // tracked_applications
  // ---------------------------------------------------------------------------

  static const _selectApps = '''
    SELECT a.*,
           EXISTS (SELECT 1 FROM calendar_event_refs r WHERE r.app_id = a.id) AS calendar_synced
    FROM tracked_applications a''';

  /// All applications (archived included, so the feed can hide them too),
  /// soonest focus date first, undated last.
  Future<List<TrackedApplication>> listApplications() async {
    final rows = await _db.rawQuery('''
      $_selectApps
      ORDER BY COALESCE(a.exam_timestamp, a.deadline_timestamp) IS NULL,
               COALESCE(a.exam_timestamp, a.deadline_timestamp),
               a.created_at''');
    return rows.map(TrackedApplication.fromRow).toList(growable: false);
  }

  Future<TrackedApplication?> getApplication(String id) async {
    final rows = await _db.rawQuery('$_selectApps WHERE a.id = ?', [id]);
    return rows.isEmpty ? null : TrackedApplication.fromRow(rows.first);
  }

  /// Insert-or-update without REPLACE (REPLACE deletes the row and would
  /// cascade-delete its vault entry and calendar refs).
  Future<void> upsertApplication(TrackedApplication app) async {
    final row = app.toRow();
    await _db.transaction((txn) async {
      final updated = await txn.update(
        'tracked_applications',
        Map.of(row)
          ..remove('id')
          ..remove('created_at'),
        where: 'id = ?',
        whereArgs: [app.id],
      );
      if (updated == 0) await txn.insert('tracked_applications', row);
    });
  }

  Future<void> updateStatus(String id, ApplicationStatus status, {DateTime? examAt, String? admitCardUrl}) =>
      _db.update(
        'tracked_applications',
        {
          'status': status.wire,
          if (examAt != null) 'exam_timestamp': examAt.toUtc().millisecondsSinceEpoch,
          if (admitCardUrl != null) 'admit_card_url': admitCardUrl,
          'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id],
      );

  /// "Fee not paid yet" on or off, and/or the fee paid ([clearFee]: forget it).
  Future<void> updateFee(String id, {bool? notPaid, int? paid, bool clearFee = false}) => _db.update(
        'tracked_applications',
        {
          if (notPaid != null) 'fee_unpaid': notPaid ? 1 : 0,
          if (paid != null || clearFee) 'fee_paid': clearFee ? null : paid,
          'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id],
      );

  /// Your marks from your response sheet ([score] null: forget them).
  Future<void> updateScore(String id, String? score) => _db.update(
        'tracked_applications',
        {'my_score': score, 'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [id],
      );

  /// Stores the server's timeline JSON on every application of that notification.
  Future<void> saveTimeline(String jobPostId, String json) => _db.update(
        'tracked_applications',
        {'timeline_json': json},
        where: 'job_post_id = ?',
        whereArgs: [jobPostId],
      );

  /// One application's timeline (dates re-read from its stored notices).
  Future<void> saveAppTimeline(String id, String json) =>
      _db.update('tracked_applications', {'timeline_json': json}, where: 'id = ?', whereArgs: [id]);

  /// What the exam watcher found for one application: status, notices, timeline.
  /// (`server_status` is a column name kept from the server era.)
  Future<void> saveWatcherState(
    String id, {
    required String status,
    required String updatesJson,
    String? timelineJson,
  }) =>
      _db.update(
        'tracked_applications',
        {
          'server_status': status,
          'updates_json': updatesJson,
          if (timelineJson != null) 'timeline_json': timelineJson,
        },
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> setArchived(String id, {required bool archived}) => _db.update(
        'tracked_applications',
        {'archived': archived ? 1 : 0, 'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [id],
      );

  /// The two links on the card: candidate login ([applyUrl]) and the board's
  /// website ([portalUrl], which the exam watcher reads). Empty clears one.
  Future<void> updateLinks(String id, {required String? applyUrl, required String? portalUrl}) => _db.update(
        'tracked_applications',
        {
          'apply_url': applyUrl,
          'portal_url': portalUrl,
          'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> deleteApplication(String id) =>
      _db.delete('tracked_applications', where: 'id = ?', whereArgs: [id]);

  // ---------------------------------------------------------------------------
  // credentials_vault
  // ---------------------------------------------------------------------------

  Future<VaultEntry?> getVault(String appId) async {
    final rows = await _db.query('credentials_vault', where: 'app_id = ?', whereArgs: [appId], limit: 1);
    return rows.isEmpty ? null : VaultEntry.fromRow(await _openRow(rows.first));
  }

  /// The vault row has no dependants, so REPLACE is safe here.
  /// Every saved Reg/Roll number ("Forgot PIN").
  Future<void> deleteAllVault() => _db.delete('credentials_vault');

  Future<void> upsertVault(VaultEntry entry) async => _db.insert(
        'credentials_vault',
        await _sealRow(entry.toRow(DateTime.now())),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  // ---------------------------------------------------------------------------
  // calendar_event_refs
  // ---------------------------------------------------------------------------

  Future<List<CalendarEventRef>> getEventRefs(String appId) async {
    final rows = await _db.query('calendar_event_refs', where: 'app_id = ?', whereArgs: [appId]);
    return [
      for (final r in rows)
        CalendarEventRef(
          appId: r['app_id']! as String,
          kind: r['kind']! as String,
          calendarId: r['calendar_id']! as String,
          eventId: r['android_calendar_event_id']! as String,
        ),
    ];
  }

  Future<void> upsertEventRef(CalendarEventRef ref) => _db.insert(
        'calendar_event_refs',
        {
          'app_id': ref.appId,
          'kind': ref.kind,
          'calendar_id': ref.calendarId,
          'android_calendar_event_id': ref.eventId,
          'synced_at': DateTime.now().toUtc().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> deleteEventRef(String appId, String kind) =>
      _db.delete('calendar_event_refs', where: 'app_id = ? AND kind = ?', whereArgs: [appId, kind]);

  // ---------------------------------------------------------------------------
  // feed_cache (single row: last good server response, for offline start-up)
  // ---------------------------------------------------------------------------

  Future<void> cacheFeed(String body, DateTime fetchedAt) => _db.insert(
        'feed_cache',
        {'id': 1, 'body': body, 'fetched_at': fetchedAt.toUtc().millisecondsSinceEpoch},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> clearFeedCache() => _db.delete('feed_cache');

  /// The server said "unchanged" (HTTP 304): the cached copy is current as of [at].
  Future<void> touchFeedCache(DateTime at) =>
      _db.update('feed_cache', {'fetched_at': at.toUtc().millisecondsSinceEpoch}, where: 'id = 1');

  Future<(String body, DateTime fetchedAt)?> readFeedCache() async {
    final rows = await _db.query('feed_cache', where: 'id = 1');
    if (rows.isEmpty) return null;
    return (
      rows.first['body']! as String,
      DateTime.fromMillisecondsSinceEpoch(rows.first['fetched_at']! as int, isUtc: true),
    );
  }

  // ---------------------------------------------------------------------------
  // job_decisions (swipe right = applied, left = not for me)
  // ---------------------------------------------------------------------------

  Future<void> saveDecision(Map<String, Object?> row) =>
      _db.insert('job_decisions', row, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> deleteDecision(String jobPostId) =>
      _db.delete('job_decisions', where: 'job_post_id = ?', whereArgs: [jobPostId]);

  /// Newest first.
  Future<List<Map<String, Object?>>> listDecisions() async =>
      [for (final r in await _db.query('job_decisions', orderBy: 'decided_at DESC')) Map.of(r)];

  /// Backup restore: the merged set replaces what's here.
  Future<void> replaceDecisions(Iterable<Map<String, Object?>> rows) => _db.transaction((txn) async {
        await txn.delete('job_decisions');
        for (final r in rows) {
          await txn.insert('job_decisions', r, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      });

  // ---------------------------------------------------------------------------
  // job_reminders (last-day alerts for jobs not applied to yet)
  // ---------------------------------------------------------------------------

  Future<List<Map<String, Object?>>> listJobReminders() async =>
      [for (final r in await _db.query('job_reminders')) Map.of(r)];

  Future<void> saveJobReminder(Map<String, Object?> row) =>
      _db.insert('job_reminders', row, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> deleteJobReminder(String jobPostId) =>
      _db.delete('job_reminders', where: 'job_post_id = ?', whereArgs: [jobPostId]);
}
