/// The job-picks model the pipeline learns from everyone who shares
/// (picks.json): each job's career track, and per group of people (same degree,
/// same qualification level, everyone) a weight per job feature. Pure (no I/O).
library;

import 'package:flutter/foundation.dart';

import '../models/user_profile.dart';
import 'relevance.dart';

@immutable
class Picks {
  const Picks({this.cohorts = const {}, this.tracks = const {}});

  /// "deg:B_TECH" / "lvl:UG" / "all" -> feature -> weight.
  final Map<String, Map<String, double>> cohorts;

  /// Job id -> career track ("engineering", "clerical"...).
  final Map<String, String> tracks;

  static const empty = Picks();

  factory Picks.fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return empty;
    final cohorts = <String, Map<String, double>>{};
    final c = j['cohorts'];
    if (c is Map<String, dynamic>) {
      for (final e in c.entries) {
        final w = e.value;
        if (w is Map<String, dynamic>) {
          cohorts[e.key] = {for (final f in w.entries) if (f.value is num) f.key: (f.value as num).toDouble()};
        }
      }
    }
    final t = j['tracks'];
    return Picks(
      cohorts: cohorts,
      tracks: t is Map<String, dynamic> ? {for (final e in t.entries) if (e.value is String) e.key: e.value as String} : const {},
    );
  }

  /// What people like you lean towards: for each feature, the weight from your
  /// degree's group, else your level's, else everyone's.
  Affinity crowdFor(UserProfileData? profile) {
    if (cohorts.isEmpty) return Affinity.empty;
    final order = [
      if (profile != null) ...[for (final d in profile.allDegrees) 'deg:$d', 'lvl:${profile.qualificationTier}'],
      'all',
    ];
    final weights = <String, double>{};
    for (final key in order.reversed) {
      weights.addAll(cohorts[key] ?? const {}); // the more specific group wins
    }
    return Affinity.fromWeights(weights);
  }
}
