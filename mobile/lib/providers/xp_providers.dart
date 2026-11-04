import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/xp.dart';
import '../models/user_profile.dart';
import '../services/database_service.dart';
import '../services/profile_store.dart';
import 'backup_providers.dart';
import 'providers.dart';

/// What just happened, for the "+20 XP" pop and the level-up moment.
@immutable
class XpAward {
  const XpAward({
    required this.action,
    required this.gained,
    required this.levelUp,
    required this.level,
    required this.streakUp,
    required this.streak,
    required this.at,
  });

  final XpAction action;
  final int gained;
  final bool levelUp;
  final int level;
  final bool streakUp;
  final int streak;
  final DateTime at;
}

class XpNotifier extends Notifier<XpState> {
  static const _key = 'xp.state';

  @override
  XpState build() {
    _load();
    return const XpState();
  }

  static const _kRecounted = 'xp.recounted.v1';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) state = XpState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      // Once: XP counted afresh from what's really there (older versions paid
      // again for apply → undo → apply).
      if (prefs.getBool(_kRecounted) != true) {
        final things = await countXpFromData(ref.read(databaseProvider), await ProfileStore.read());
        final extras = ref.read(xpRecountExtrasProvider);
        if (extras != null) things.addAll(await extras());
        state = state.recount(things);
        await _save();
        await prefs.setBool(_kRecounted, true);
      }
    } catch (_) {
      // Unreadable, or no database (tests): keep what there is.
    }
  }

  Future<void> _save() async {
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(state.toJson()));
    } catch (_) {}
    try {
      ref.read(backupControllerProvider.notifier).markDirty();
    } catch (_) {} // no backup in tests
  }

  /// Gives the points for [action] (nothing past its daily cap, nothing for a [key]
  /// that already earned) and announces it.
  Future<XpAward?> award(XpAction action, {String? key}) async {
    final now = DateTime.now();
    final r = state.award(action, now, key: key);
    if (r.gained == 0) return null;
    state = r.state;
    await _save();
    final award = XpAward(
      action: action,
      gained: r.gained,
      levelUp: r.levelUp,
      level: r.state.level,
      streakUp: r.streakUp,
      streak: r.state.streak,
      at: now,
    );
    ref.read(lastXpAwardProvider.notifier).state = award;
    return award;
  }

  /// Undo: the points [key] earned come off again.
  Future<void> revoke(String key) async {
    final r = state.revoke(key, DateTime.now());
    if (r.lost == 0) return;
    state = r.state;
    await _save();
  }
}

final xpProvider = NotifierProvider<XpNotifier, XpState>(XpNotifier.new);

/// More to count in a recount, from optional modules (the Private workspace hands
/// its own over through main.dart).
final xpRecountExtrasProvider = Provider<Future<Map<String, XpEarned>> Function()?>((ref) => null);

/// What has earned XP, read from what is on the phone now: each tracked exam (a
/// feed job you applied to, or one you added yourself), saved IDs, a date you set,
/// and a finished profile. Dashboard checks leave nothing to count.
Future<Map<String, XpEarned>> countXpFromData(DatabaseService db, UserProfileData? profile) async {
  final things = <String, XpEarned>{};
  for (final a in await db.listApplications()) {
    final key = xpExamKey(jobPostId: a.jobPostId, examName: a.examName);
    final fromFeed = key.startsWith('job:');
    final action = fromFeed ? XpAction.appliedToJob : XpAction.addedExam;
    things[key] = XpEarned(action, action.points, a.createdAt);
    final vault = await db.getVault(a.id);
    if (vault != null && !vault.isEmpty) {
      things['ids:$key'] = XpEarned(XpAction.savedIds, XpAction.savedIds.points, a.createdAt);
    }
    if (a.examAt != null) {
      things['date:$key'] = XpEarned(XpAction.setExamDate, XpAction.setExamDate.points, a.updatedAt);
    }
  }
  if (profile?.isComplete == true) {
    things['profile'] = XpEarned(XpAction.completedProfile, XpAction.completedProfile.points, DateTime.now());
  }
  return things;
}

/// The latest award: the app shell listens and celebrates it.
final lastXpAwardProvider = StateProvider<XpAward?>((ref) => null);
