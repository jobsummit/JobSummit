/// "Help improve job picks": what this phone shares when you say yes, built
/// from what's on it. No name, email, date of birth or Google account data; your
/// age as a band; no saved IDs, passwords, notes, response sheets or photos.
/// Pure (no I/O).
library;

import '../models/job_preferences.dart';
import '../models/tracked_application.dart';
import '../models/user_profile.dart';

/// One job you applied to or turned down.
typedef SharedDecision = ({String jobId, bool applied, Set<String> features, DateTime at});

/// Bands around the common age limits (18, 21, 25, 27, 30, 32, 35...).
String ageBand(int age) => switch (age) {
      < 18 => 'under 18',
      <= 21 => '18-21',
      <= 25 => '22-25',
      <= 28 => '26-28',
      <= 32 => '29-32',
      <= 36 => '33-36',
      <= 40 => '37-40',
      _ => '41+',
    };

String experienceBand(double years) => switch (years) {
      < 1 => '0',
      < 3 => '1-2',
      < 6 => '3-5',
      _ => '6+',
    };

Map<String, Object?> insightsPayload({
  required String installId,
  required String appVersion,
  required UserProfileData profile,
  required JobPreferences preferences,
  required List<TrackedApplication> exams,
  required List<SharedDecision> decisions,
  required DateTime now,
}) =>
    {
      'install_id': installId,
      'app_version': appVersion,
      'profile': {
        'age_band': ageBand(ageOn(profile.dateOfBirth, now)),
        'category': profile.category.wire,
        'pwbd': profile.isPwbd,
        'ex_serviceman': profile.isExServiceman,
        'qual_level': profile.qualificationTier,
        'degrees': profile.allDegrees,
        // The subjects you picked from the lists; anything typed by hand stays here.
        'subjects': [
          for (final c in profile.subjects)
            for (final s in c.subjects) '${c.group}:$s',
        ],
        'experience_band': experienceBand(profile.experienceYears),
      },
      'preferences': {
        'show_first': [for (final c in preferences.preferred) c.wire],
        'hidden_groups': [for (final c in preferences.hidden) c.wire],
        'hidden_types': preferences.hiddenTypes.toList(),
        'min_pay': preferences.minMonthlyPay,
        'languages': preferences.languages.toList(),
      },
      'exams': [
        for (final a in exams)
          {
            'exam_id': a.catalogExam?.id,
            // The exam list's name when it's a known exam; what you typed otherwise.
            'exam_name': a.catalogExam?.name ?? a.examName,
            'stage': a.tierName,
            'status': a.displayStatus.wire,
            'from_feed': a.jobPostId != null,
          },
      ],
      'decisions': [
        for (final d in decisions)
          {'job_id': d.jobId, 'applied': d.applied, 'features': d.features.toList(), 'at': d.at.toUtc().toIso8601String()},
      ],
    };
