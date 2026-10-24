import 'package:flutter/foundation.dart';

/// Useful things you did, and what each is worth. Only actions that move your job
/// search forward earn XP; opening the app never does.
enum XpAction {
  appliedToJob(20, 'Applied to a job', perDay: 10),
  addedExam(15, 'Added an exam', perDay: 5),
  savedIds(10, 'Saved your IDs', perDay: 5),
  setExamDate(10, 'Updated an exam date', perDay: 5),
  checkedDashboard(5, 'Checked a dashboard', perDay: 5),
  completedProfile(25, 'Finished your profile', perDay: 1),
  practiced(10, 'Finished a practice test', perDay: 5),
  privateApplied(15, 'Applied to a company', perDay: 10),
  privateProgress(10, 'Moved an application forward', perDay: 10),
  privateOffer(50, 'Got an offer!', perDay: 3);

  const XpAction(this.points, this.label, {required this.perDay});
  final int points;
  final String label;

  /// More than this in one day earns nothing (no farming by tapping).
  final int perDay;
}

/// Level names, one per level; past the list, "Summiteer N".
const _levelNames = [
  'Aspirant', 'Applicant', 'Candidate', 'Contender', 'Achiever', 'Trailblazer', 'Topper', 'Summiteer', //
];

/// XP needed to *reach* [level] (level 1 = 0). Each step asks 50 more than the
/// last: 0, 100, 250, 450, 700… so early levels come fast.
int xpForLevel(int level) => level <= 1 ? 0 : 25 * (level - 1) * (level + 2);

int levelFor(int xp) {
  var level = 1;
  while (xpForLevel(level + 1) <= xp) {
    level++;
  }
  return level;
}

String levelName(int level) =>
    level <= _levelNames.length ? _levelNames[level - 1] : 'Summiteer ${level - _levelNames.length + 1}';

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

/// What one specific thing earned: [XpState.earned] keeps these by key so the same
/// job, exam or stage never pays twice, and an Undo can hand the points back.
@immutable
class XpEarned {
  const XpEarned(this.action, this.points, this.day);

  final XpAction action;
  final int points;
  final DateTime day;

  Map<String, Object?> toJson() => {'a': action.name, 'p': points, 'd': day.toIso8601String()};

  static XpEarned? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final action = XpAction.values.where((a) => a.name == j['a']).firstOrNull;
    final day = DateTime.tryParse(j['d'] as String? ?? '');
    if (action == null || day == null) return null;
    return XpEarned(action, (j['p'] as num?)?.toInt() ?? action.points, day);
  }
}

/// The key for one tracked exam: the feed job it came from, else its name (which
/// carries the stage, "SSC CGL 2026 · Tier-2"). Deleting and re-adding it gives the
/// same key, so it can't earn again.
String xpExamKey({String? jobPostId, required String examName}) =>
    jobPostId != null && jobPostId.isNotEmpty ? 'job:$jobPostId' : 'exam:${examName.trim().toLowerCase()}';

/// Daily keys ("checked this dashboard today").
String xpDayStamp(DateTime t) =>
    '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

/// Your XP, level and streak. Pure: [award] returns the new state and what happened.
@immutable
class XpState {
  const XpState({
    this.xp = 0,
    this.streak = 0,
    this.lastActiveDay,
    this.today = const {},
    this.todayDay,
    this.earned = const {},
    this.streakBefore,
    this.activeBefore,
    int? bestStreak,
  }) : _bestStreak = bestStreak;

  final int xp;

  /// Days in a row with something useful done. One missed day is forgiven.
  final int streak;
  final DateTime? lastActiveDay;

  /// Times each action earned XP on [todayDay] (for the daily caps).
  final Map<String, int> today;
  final DateTime? todayDay;

  /// Each specific thing that earned XP ("job:123", "ids:exam:ssc cgl 2026"…).
  final Map<String, XpEarned> earned;

  /// The streak before today's first award, so undoing today's only action
  /// also takes back today's streak day.
  final int? streakBefore;
  final DateTime? activeBefore;

  /// The longest streak so far (the profile shows it).
  int get bestStreak => (_bestStreak ?? 0) > streak ? _bestStreak! : streak;
  final int? _bestStreak;

  int get level => levelFor(xp);
  String get levelTitle => levelName(level);
  int get levelStart => xpForLevel(level);
  int get nextLevelAt => xpForLevel(level + 1);

  /// 0..1 through the current level.
  double get levelProgress => (xp - levelStart) / (nextLevelAt - levelStart);

  /// Something useful done today (the daily ring is full).
  bool doneToday(DateTime now) => lastActiveDay != null && _day(lastActiveDay!) == _day(now);

  /// The streak as it stands [now]: still alive after one missed day, gone after two.
  int streakOn(DateTime now) {
    final last = lastActiveDay;
    if (last == null) return 0;
    return _day(now).difference(_day(last)).inDays <= 2 ? streak : 0;
  }

  /// [key] names the specific thing (see [xpExamKey]): a key that already earned
  /// gets nothing, however often it is repeated.
  ({XpState state, int gained, bool levelUp, bool streakUp}) award(XpAction action, DateTime now, {String? key}) {
    final day = _day(now);
    if (key != null && earned.containsKey(key)) return (state: this, gained: 0, levelUp: false, streakUp: false);
    final counts = todayDay == day ? today : const <String, int>{};
    final used = counts[action.name] ?? 0;
    if (used >= action.perDay) return (state: this, gained: 0, levelUp: false, streakUp: false);

    final last = lastActiveDay == null ? null : _day(lastActiveDay!);
    final gap = last == null ? null : day.difference(last).inDays;
    final newStreak = switch (gap) {
      null => 1,
      0 => streak, // already counted today
      1 || 2 => streak + 1, // next day, or one day missed (forgiven)
      _ => 1, // two or more missed days: start again
    };
    final firstToday = last != day;
    final next = XpState(
      xp: xp + action.points,
      streak: newStreak,
      lastActiveDay: day,
      today: {...counts, action.name: used + 1},
      todayDay: day,
      earned: key == null
          ? earned
          : {
              // Yesterday's daily keys can go: they can't repeat anyway.
              for (final e in earned.entries)
                if (e.value.action != XpAction.checkedDashboard || !_day(e.value.day).isBefore(day)) e.key: e.value,
              key: XpEarned(action, action.points, day),
            },
      streakBefore: firstToday ? streak : streakBefore,
      activeBefore: firstToday ? lastActiveDay : activeBefore,
      bestStreak: newStreak > bestStreak ? newStreak : bestStreak,
    );
    return (state: next, gained: action.points, levelUp: next.level > level, streakUp: newStreak > streak);
  }

  /// Undo: what [key] earned comes off again (and today's streak day, if that was
  /// the only thing done today). A key that never earned changes nothing.
  ({XpState state, int lost}) revoke(String key, DateTime now) {
    final e = earned[key];
    if (e == null) return (state: this, lost: 0);
    final day = _day(now);
    final counts = todayDay == day ? {...today} : <String, int>{};
    final n = counts[e.action.name] ?? 0;
    if (_day(e.day) == day && n > 0) {
      if (n == 1) {
        counts.remove(e.action.name);
      } else {
        counts[e.action.name] = n - 1;
      }
    }
    final undoDay = counts.isEmpty && lastActiveDay != null && _day(lastActiveDay!) == day;
    final next = XpState(
      xp: xp - e.points < 0 ? 0 : xp - e.points,
      streak: undoDay ? (streakBefore ?? 0) : streak,
      lastActiveDay: undoDay ? activeBefore : lastActiveDay,
      today: counts,
      todayDay: todayDay,
      earned: {...earned}..remove(key),
      streakBefore: streakBefore,
      activeBefore: activeBefore,
      bestStreak: _bestStreak,
    );
    return (state: next, lost: e.points);
  }

  /// XP counted afresh from what is actually there (tracked exams, saved IDs,
  /// applications…). The streak stays as it is.
  XpState recount(Map<String, XpEarned> things) => XpState(
        xp: things.values.fold(0, (sum, e) => sum + e.points),
        streak: streak,
        lastActiveDay: lastActiveDay,
        today: today,
        todayDay: todayDay,
        earned: things,
        streakBefore: streakBefore,
        activeBefore: activeBefore,
        bestStreak: bestStreak,
      );

  Map<String, Object?> toJson() => {
        'xp': xp,
        'streak': streak,
        'last_active_day': lastActiveDay?.toIso8601String(),
        'today': today,
        'today_day': todayDay?.toIso8601String(),
        'earned': {for (final e in earned.entries) e.key: e.value.toJson()},
        'streak_before': streakBefore,
        'active_before': activeBefore?.toIso8601String(),
        'best_streak': bestStreak,
      };

  factory XpState.fromJson(Map<String, dynamic> j) => XpState(
        xp: (j['xp'] as num?)?.toInt() ?? 0,
        streak: (j['streak'] as num?)?.toInt() ?? 0,
        lastActiveDay: DateTime.tryParse(j['last_active_day'] as String? ?? ''),
        today: {for (final e in (j['today'] as Map<String, dynamic>? ?? const {}).entries) e.key: (e.value as num).toInt()},
        todayDay: DateTime.tryParse(j['today_day'] as String? ?? ''),
        earned: {
          for (final e in (j['earned'] as Map<String, dynamic>? ?? const {}).entries)
            if (XpEarned.fromJson(e.value) case final v?) e.key: v,
        },
        streakBefore: (j['streak_before'] as num?)?.toInt(),
        activeBefore: DateTime.tryParse(j['active_before'] as String? ?? ''),
        bestStreak: (j['best_streak'] as num?)?.toInt(),
      );
}
