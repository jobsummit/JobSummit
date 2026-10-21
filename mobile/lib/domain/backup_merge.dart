/// Merging this phone's data with the Drive backup (pure, no I/O).
///
/// Works for every case with one rule set: a fresh install (local empty = full
/// restore), a reinstall, and two phones in use (record by record, newest wins).
library;

import 'dart:convert';

import '../models/backup_snapshot.dart';
import '../models/tracked_application.dart';
import 'exam_watcher.dart';

const kBackupMaxUpdates = 30;
const kTombstoneTtl = Duration(days: 180);

int _ms(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);

BackupSnapshot mergeSnapshots(BackupSnapshot local, BackupSnapshot remote, {required DateTime now}) {
  // Profile: the most recently saved one. A reset is a save too (no profile, but a
  // date), so it wins over an older profile; an undated one (saved before backups
  // existed) only fills a gap.
  final localAt = local.profileSavedAt;
  final remoteAt = remote.profileSavedAt;
  final useRemoteProfile = switch ((localAt, remoteAt)) {
    (final l?, final r?) => r.isAfter(l),
    (null, _?) => true,
    (_?, null) => false,
    (null, null) => local.profile == null,
  };
  final profile = useRemoteProfile ? remote.profile : local.profile;
  final profileAt = useRemoteProfile ? remoteAt : localAt;

  // Removals: the later one per app, forgotten after a while.
  final tombstones = <String, DateTime>{};
  for (final side in [local.tombstones, remote.tombstones]) {
    side.forEach((id, at) {
      final known = tombstones[id];
      if (known == null || at.isAfter(known)) tombstones[id] = at;
    });
  }
  tombstones.removeWhere((_, at) => now.difference(at) > kTombstoneTtl);

  // Applications: newest edit is the base; watcher findings from both are kept.
  final applications = <String, Map<String, Object?>>{};
  for (final id in {...local.applications.keys, ...remote.applications.keys}) {
    final a = local.applications[id];
    final b = remote.applications[id];
    final row = a == null ? b! : (b == null ? a : _mergeApplication(a, b));
    final removedAt = tombstones[id];
    if (removedAt != null && _ms(row['updated_at']) <= removedAt.millisecondsSinceEpoch) continue;
    applications[id] = _withoutStrays(row);
  }

  // Vault + passwords: per application, the side whose vault entry changed last.
  final vault = <String, Map<String, Object?>>{};
  final passwords = <String, String>{};
  for (final id in applications.keys) {
    final va = local.vault[id];
    final vb = remote.vault[id];
    final remoteNewer = va == null || (vb != null && _ms(vb['updated_at']) > _ms(va['updated_at']));
    final v = remoteNewer ? vb : va;
    if (v != null) vault[id] = v;
    final preferred = remoteNewer ? remote.passwords[id] : local.passwords[id];
    final other = remoteNewer ? local.passwords[id] : remote.passwords[id];
    final pw = preferred ?? other;
    if (pw != null && pw.isNotEmpty) passwords[id] = pw;
  }

  // Decisions: the later one per job, unless it was undone afterwards.
  final decisions = <String, Map<String, Object?>>{};
  for (final id in {...local.decisions.keys, ...remote.decisions.keys}) {
    final a = local.decisions[id];
    final b = remote.decisions[id];
    final row = a == null ? b! : (b == null || _ms(a['decided_at']) >= _ms(b['decided_at']) ? a : b);
    final undoneAt = tombstones['decision:$id'];
    if (undoneAt != null && _ms(row['decided_at']) <= undoneAt.millisecondsSinceEpoch) continue;
    decisions[id] = row;
  }

  // Job preferences: the most recently saved.
  DateTime? savedAt(Map<String, dynamic>? p) => DateTime.tryParse('${p?['saved_at'] ?? ''}');
  final lp = local.jobPreferences;
  final rp = remote.jobPreferences;
  final remotePrefsNewer =
      lp == null || (rp != null && (savedAt(lp) == null || (savedAt(rp)?.isAfter(savedAt(lp)!) ?? false)));

  return BackupSnapshot(
    savedAt: now,
    deviceId: local.deviceId,
    profile: profile,
    profileSavedAt: profileAt,
    applications: applications,
    vault: vault,
    passwords: passwords,
    tombstones: tombstones,
    decisions: decisions,
    jobPreferences: remotePrefsNewer ? rp : lp,
  );
}

Map<String, Object?> _mergeApplication(Map<String, Object?> a, Map<String, Object?> b) {
  final aNewer = _ms(a['updated_at']) >= _ms(b['updated_at']);
  final newer = aNewer ? a : b;
  final older = aNewer ? b : a;
  return {
    ...newer,
    'updates_json': _mergeUpdates(a['updates_json'], b['updates_json']),
    'server_status': _furthestStatus(a['server_status'], b['server_status']),
    'timeline_json': _mergeTimeline(newer['timeline_json'], older['timeline_json']),
    'calendar_synced': (_ms(a['calendar_synced']) == 1 || _ms(b['calendar_synced']) == 1) ? 1 : 0,
  };
}

/// Notices from another round of the exam stay out, whichever copy still had them
/// (a phone with an older watcher, or a backup saved before they were taken off).
Map<String, Object?> _withoutStrays(Map<String, Object?> row) {
  try {
    final fixed = withoutStrayUpdates(TrackedApplication.fromRow(row));
    if (fixed == null) return row;
    return {
      ...row,
      'updates_json': jsonEncode([for (final u in fixed.updates) u.toJson()]),
      'server_status': fixed.status.wire,
      'timeline_json': jsonEncode(fixed.timeline),
    };
  } catch (_) {
    return row; // not a complete row: merged as it is
  }
}

List<Map<String, dynamic>> _decodeList(Object? raw) {
  if (raw is! String || raw.isEmpty) return const [];
  try {
    return [
      for (final e in jsonDecode(raw) as List<dynamic>)
        if (e is Map<String, dynamic>) e
    ];
  } catch (_) {
    return const [];
  }
}

Map<String, dynamic>? _decodeMap(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    return jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

/// Union by notice URL, newest first, capped.
String? _mergeUpdates(Object? a, Object? b) {
  final byUrl = <String, Map<String, dynamic>>{};
  for (final u in [..._decodeList(a), ..._decodeList(b)]) {
    final url = u['url'];
    if (url is String) byUrl.putIfAbsent(url, () => u);
  }
  if (byUrl.isEmpty) return null;
  final merged = byUrl.values.toList()
    ..sort((x, y) => '${y['detected_at'] ?? ''}'.compareTo('${x['detected_at'] ?? ''}'));
  return jsonEncode(merged.take(kBackupMaxUpdates).toList());
}

/// The further of two watcher statuses (they only ever move forward).
Object? _furthestStatus(Object? a, Object? b) {
  final sa = TrackerStatus.fromWire(a as String?);
  final sb = TrackerStatus.fromWire(b as String?);
  if (sa == null) return sb?.wire;
  if (sb == null) return sa.wire;
  return (sa.index >= sb.index ? sa : sb).wire;
}

/// Every milestone either copy knows; the newer copy wins where both know one.
String? _mergeTimeline(Object? newer, Object? older) {
  final n = _decodeMap(newer);
  final o = _decodeMap(older);
  if (n == null && o == null) return null;
  return jsonEncode({
    ...?o,
    for (final e in (n ?? const <String, dynamic>{}).entries)
      if (e.value != null) e.key: e.value,
  });
}
