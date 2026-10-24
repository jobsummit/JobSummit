import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/practice.dart';

/// Your practice on this phone: past tests, the bank questions you've seen (so
/// they don't come back soon), and the ones you reported (never shown again).
abstract final class PracticeStore {
  static const _kHistory = 'practice.history';
  static const _kHidden = 'practice.hidden';
  static String _kSeen(PracticeSection s) => 'practice.seen.${s.name}';

  static const keepTests = 200;
  static const keepSeen = 3000;

  static Future<List<PracticeResult>> history() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_kHistory);
      if (raw == null) return const [];
      return [for (final j in jsonDecode(raw) as List) if (PracticeResult.fromJson(j) case final r?) r];
    } catch (_) {
      return const [];
    }
  }

  /// Adds [result]; returns the history with it (newest last).
  static Future<List<PracticeResult>> add(PracticeResult result) async {
    final all = [...await history(), result];
    final kept = all.length > keepTests ? all.sublist(all.length - keepTests) : all;
    try {
      await (await SharedPreferences.getInstance()).setString(_kHistory, jsonEncode([for (final r in kept) r.toJson()]));
    } catch (_) {}
    return kept;
  }

  /// Oldest first.
  static Future<List<String>> seen(PracticeSection s) async {
    try {
      return (await SharedPreferences.getInstance()).getStringList(_kSeen(s)) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> markSeen(PracticeSection s, Iterable<String> ids) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final fresh = ids.toSet();
      final list = [...(prefs.getStringList(_kSeen(s)) ?? const <String>[]).where((id) => !fresh.contains(id)), ...fresh];
      await prefs.setStringList(_kSeen(s), list.length > keepSeen ? list.sublist(list.length - keepSeen) : list);
    } catch (_) {}
  }

  static Future<Set<String>> hidden() async {
    try {
      return ((await SharedPreferences.getInstance()).getStringList(_kHidden) ?? const <String>[]).toSet();
    } catch (_) {
      return const {};
    }
  }

  static Future<void> hide(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kHidden, {...prefs.getStringList(_kHidden) ?? const <String>[], id}.toList());
    } catch (_) {}
  }
}
