import 'dart:convert';

import 'package:exam_tracker/domain/backup_merge.dart';
import 'package:exam_tracker/models/backup_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime.utc(2026, 10, 20, 12);
int ms(DateTime d) => d.millisecondsSinceEpoch;

Map<String, Object?> app(String id, DateTime updated,
        {String status = 'applied', String? watcher, String? updates, String? timeline, int calendar = 0}) =>
    {
      'id': id,
      'exam_name': 'Exam $id',
      'post_name': 'Post $id',
      'status': status,
      'archived': 0,
      'created_at': ms(DateTime.utc(2026, 10, 1)),
      'updated_at': ms(updated),
      'server_status': watcher,
      'updates_json': updates,
      'timeline_json': timeline,
      'calendar_synced': calendar,
    };

Map<String, Object?> vault(String id, DateTime updated, String roll) =>
    {'app_id': id, 'registration_id': null, 'roll_number': roll, 'notes': null, 'updated_at': ms(updated)};

BackupSnapshot snap({
  Map<String, dynamic>? profile,
  DateTime? profileAt,
  List<Map<String, Object?>> apps = const [],
  List<Map<String, Object?>> vaults = const [],
  Map<String, String> passwords = const {},
  Map<String, DateTime> tombstones = const {},
}) =>
    BackupSnapshot(
      savedAt: now,
      deviceId: 'dev',
      profile: profile,
      profileSavedAt: profileAt,
      applications: {for (final a in apps) a['id']! as String: a},
      vault: {for (final v in vaults) v['app_id']! as String: v},
      passwords: passwords,
      tombstones: tombstones,
    );

void main() {
  progressTests();
  final t1 = DateTime.utc(2026, 10, 10);
  final t2 = DateTime.utc(2026, 10, 12);
  final t3 = DateTime.utc(2026, 10, 14);

  test('fresh install: an empty phone gets everything from the backup', () {
    final remote = snap(
      profile: {'display_name': 'Me'},
      profileAt: t1,
      apps: [app('a', t1, calendar: 1)],
      vaults: [vault('a', t1, 'R-1')],
      passwords: {'a': 'secret'},
    );
    final m = mergeSnapshots(snap(), remote, now: now);
    expect(m.profile, {'display_name': 'Me'});
    expect(m.applications.keys, ['a']);
    expect(m.vault['a']?['roll_number'], 'R-1');
    expect(m.passwords, {'a': 'secret'});
    expect(m.applications['a']?['calendar_synced'], 1);
  });

  test('the more recently saved profile wins', () {
    final local = snap(profile: {'v': 'old'}, profileAt: t1);
    final remote = snap(profile: {'v': 'new'}, profileAt: t2);
    expect(mergeSnapshots(local, remote, now: now).profile, {'v': 'new'});
    expect(mergeSnapshots(remote, local, now: now).profile, {'v': 'new'});
  });

  test('a profile reset wins over an older profile, and loses to a newer one', () {
    final reset = snap(profileAt: t2); // no profile, but dated: reset on purpose
    final older = snap(profile: {'v': 'old'}, profileAt: t1);
    final newer = snap(profile: {'v': 'new'}, profileAt: t3);
    expect(mergeSnapshots(reset, older, now: now).profile, isNull);
    expect(mergeSnapshots(older, reset, now: now).profile, isNull);
    expect(mergeSnapshots(older, reset, now: now).profileSavedAt, t2);
    expect(mergeSnapshots(reset, newer, now: now).profile, {'v': 'new'});
    // A profile from before backups existed (undated) only fills a gap.
    expect(mergeSnapshots(reset, snap(profile: {'v': 'legacy'}), now: now).profile, isNull);
    expect(mergeSnapshots(snap(), snap(profile: {'v': 'legacy'}), now: now).profile, {'v': 'legacy'});
  });

  test('two phones: newest edit wins, watcher findings from both are kept', () {
    final local = snap(apps: [
      app('a', t3,
          status: 'exam_scheduled',
          watcher: 'admit_card_live',
          updates: jsonEncode([
            {'url': 'u1', 'title': 'Admit card', 'detected_at': '2026-10-11T00:00:00Z'},
          ]),
          timeline: jsonEncode({'job_post_id': 'j', 'admit_card_url': 'u1'})),
    ]);
    final remote = snap(apps: [
      app('a', t2,
          status: 'applied',
          watcher: 'answer_key_live',
          updates: jsonEncode([
            {'url': 'u2', 'title': 'Answer key', 'detected_at': '2026-10-13T00:00:00Z'},
            {'url': 'u1', 'title': 'Admit card', 'detected_at': '2026-10-11T00:00:00Z'},
          ]),
          timeline: jsonEncode({'job_post_id': 'j', 'answer_key_url': 'u2', 'admit_card_url': null})),
    ]);
    final a = mergeSnapshots(local, remote, now: now).applications['a']!;
    expect(a['status'], 'exam_scheduled'); // the local edit is newer
    expect(a['server_status'], 'answer_key_live'); // furthest watcher status
    final urls = [for (final u in jsonDecode(a['updates_json']! as String) as List<dynamic>) u['url']];
    expect(urls, ['u2', 'u1']); // union, newest first
    expect(jsonDecode(a['timeline_json']! as String),
        {'job_post_id': 'j', 'admit_card_url': 'u1', 'answer_key_url': 'u2'});
  });

  test('a removal on one phone reaches the other, unless it was edited afterwards', () {
    final local = snap(tombstones: {'a': t2, 'b': t2});
    final remote = snap(apps: [app('a', t1), app('b', t3)]);
    final m = mergeSnapshots(local, remote, now: now);
    expect(m.applications.keys, ['b']); // 'a' removed; 'b' was re-added later
    expect(m.tombstones.keys, containsAll(['a', 'b']));
  });

  test('old removals are forgotten after 180 days', () {
    final old = now.subtract(const Duration(days: 200));
    expect(mergeSnapshots(snap(tombstones: {'x': old}), snap(), now: now).tombstones, isEmpty);
  });

  test('vault and password follow the side whose vault changed last', () {
    final local = snap(apps: [app('a', t1)], vaults: [vault('a', t1, 'OLD')], passwords: {'a': 'old-pw'});
    final remote = snap(apps: [app('a', t1)], vaults: [vault('a', t2, 'NEW')], passwords: {'a': 'new-pw'});
    final m = mergeSnapshots(local, remote, now: now);
    expect(m.vault['a']?['roll_number'], 'NEW');
    expect(m.passwords['a'], 'new-pw');

    // A password known only on one side is never lost.
    final onlyLocal =
        mergeSnapshots(local, snap(apps: [app('a', t1)], vaults: [vault('a', t2, 'NEW')]), now: now);
    expect(onlyLocal.passwords['a'], 'old-pw');
  });

  test('backups from a newer app version are refused, not misread', () {
    expect(() => BackupSnapshot.fromJson({'schema': 99}), throwsFormatException);
    final round = BackupSnapshot.fromJson(jsonDecode(jsonEncode(snap(
      profile: {'display_name': 'Me'},
      profileAt: t1,
      apps: [app('a', t1)],
      passwords: {'a': 'pw'},
      tombstones: {'z': t2},
    ).toJson())) as Map<String, dynamic>);
    expect(round.applications['a']?['updated_at'], ms(t1));
    expect(round.passwords, {'a': 'pw'});
    expect(round.tombstones['z'], t2);
    expect(round.profileSavedAt, t1);
  });

  test('job decisions and preferences travel too; an undo on one phone wins over the older decision', () {
    Map<String, Object?> decision(String id, DateTime at, String kind) => {
          'job_post_id': id,
          'decision': kind,
          'features': '["cat:bank"]',
          'title': 'PO',
          'organization': 'SBI',
          'deadline': null,
          'decided_at': ms(at),
        };
    final local = BackupSnapshot(
      savedAt: now,
      deviceId: 'a',
      decisions: {'j1': decision('j1', t1, 'rejected')},
      tombstones: {'decision:j2': t3}, // undone here after the other phone decided
      jobPreferences: {
        'preferred': ['bank'],
        'saved_at': t1.toIso8601String()
      },
    );
    final remote = BackupSnapshot(
      savedAt: now,
      deviceId: 'b',
      decisions: {'j1': decision('j1', t2, 'applied'), 'j2': decision('j2', t2, 'rejected')},
      jobPreferences: {
        'preferred': ['psu'],
        'saved_at': t2.toIso8601String()
      },
    );
    final m = mergeSnapshots(local, remote, now: now);
    expect(m.decisions.keys, ['j1']);
    expect(m.decisions['j1']?['decision'], 'applied'); // the later decision
    expect(m.jobPreferences?['preferred'], ['psu']); // the later save
    final round = BackupSnapshot.fromJson(jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>);
    expect(round.decisions['j1']?['title'], 'PO');
    expect(round.jobPreferences?['preferred'], ['psu']);
  });
}

void progressTests() {
  test('practice and XP: nothing either phone had is lost', () {
    Map<String, Object?> test(String at, int right) => {'k': 'quant', 'at': at, 'n': 10, 'r': right, 'w': 0, 's': 60};
    Map<String, Object?> card(String id, String text, int misses) => {
          'q': {'id': id, 's': 'quant', 'q': text, 't': 'Ages', 'o': ['1', '2', '3', '4'], 'a': 0},
          'step': 0,
          'due': '2026-10-21T00:00:00.000',
          'm': misses,
        };
    final local = BackupSnapshot(savedAt: now, deviceId: 'a', progress: {
      'practice.history': [test('2026-10-02T09:00:00.000', 7)],
      'practice.mistakes': [card('gen-quant-0-1', 'How old?', 2)],
      'limits.attempts': {'upsc-cse': 2},
      'xp.state': {'xp': 120},
    });
    final remote = BackupSnapshot(savedAt: now, deviceId: 'b', progress: {
      'practice.history': [test('2026-10-01T09:00:00.000', 5), test('2026-10-02T09:00:00.000', 7)],
      'practice.mistakes': [card('gen-quant-3-9', 'How old?', 1), card('bank-1', 'Synonym?', 1)],
      'limits.attempts': {'upsc-cse': 3, 'sbi-po': 1},
      'xp.state': {'xp': 90},
    });
    final m = mergeSnapshots(local, remote, now: now).progress;
    expect([for (final t in m['practice.history']! as List) (t as Map)['at']],
        ['2026-10-01T09:00:00.000', '2026-10-02T09:00:00.000']);
    final cards = m['practice.mistakes']! as List;
    expect(cards, hasLength(2)); // the same made question once, this phone's copy
    expect(cards.any((c) => (c as Map)['m'] == 2), isTrue);
    expect(m['limits.attempts'], {'upsc-cse': 3, 'sbi-po': 1});
    expect(m['xp.state'], {'xp': 120});
    final back = BackupSnapshot.fromJson(jsonDecode(jsonEncode(BackupSnapshot(savedAt: now, deviceId: 'a', progress: m).toJson()))
        as Map<String, dynamic>);
    expect(back.progress['limits.attempts'], {'upsc-cse': 3, 'sbi-po': 1});
  });

  test('an older backup without progress keeps this phone’s', () {
    final local = BackupSnapshot(savedAt: now, deviceId: 'a', progress: {'xp.state': {'xp': 40}});
    final m = mergeSnapshots(local, BackupSnapshot(savedAt: now, deviceId: 'b'), now: now);
    expect(m.progress, {'xp.state': {'xp': 40}});
  });
}
