import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/exam_catalog.dart';
import '../domain/exam_limits.dart';
import '../models/jobs_data.dart';
import 'account_providers.dart';
import 'providers.dart';

/// Attempts you've used, per exam (exam list id), as you set them.
class AttemptsNotifier extends AsyncNotifier<Map<String, int>> {
  static const _key = 'limits.attempts';

  @override
  Future<Map<String, int>> build() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return const {};
      return {for (final e in (jsonDecode(raw) as Map<String, dynamic>).entries) e.key: (e.value as num).toInt()};
    } catch (_) {
      return const {};
    }
  }

  Future<void> set(String examId, int used) async {
    final next = {...await future, examId: used};
    state = AsyncData(next);
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(next));
    } catch (_) {}
  }
}

final attemptsUsedProvider = AsyncNotifierProvider<AttemptsNotifier, Map<String, int>>(AttemptsNotifier.new);

/// Your limits for [exam] (null without a profile or a known rule), from the
/// newest notice in the job list when it has one.
final examLimitsProvider = Provider.family<ExamLimits?, CatalogExam>((ref, exam) {
  final profile = ref.watch(profileProvider).dataOrNull;
  if (profile == null) return null;
  final jobs = ref.watch(jobsLoadProvider).dataOrNull?.file.jobs ?? const <PublishedJob>[];
  return limitsFor(exam, profile, ref.watch(nowProvider), jobs: jobs);
});
