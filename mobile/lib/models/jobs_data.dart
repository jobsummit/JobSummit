import 'package:flutter/foundation.dart';

/// Mirrors `jobs.json` from the data pipeline (backend/app/services/publish.py).
/// Unknown fields are ignored, so the pipeline can add fields without breaking
/// older app versions.
const kJobsSchemaVersion = 1;

DateTime? _dateTime(Object? v) => v is String && v.isNotEmpty ? DateTime.tryParse(v) : null;

/// Date-only values ("2026-10-01") as calendar dates, no time zone.
DateTime? _date(Object? v) {
  final d = _dateTime(v);
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

int? _int(Object? v) => (v as num?)?.toInt();

@immutable
class PublishedVacancy {
  const PublishedVacancy({
    required this.ur,
    required this.sc,
    required this.st,
    required this.obc,
    required this.ews,
    this.total = 0,
  });

  final int ur;
  final int sc;
  final int st;
  final int obc;
  final int ews;
  final int total;

  /// Seats of one category ("SC" -> sc). UR is the open pool.
  int seatsFor(String category) => switch (category) {
        'SC' => sc,
        'ST' => st,
        'OBC' => obc,
        'EWS' => ews,
        _ => ur,
      };

  factory PublishedVacancy.fromJson(Map<String, dynamic> j) => PublishedVacancy(
        ur: _int(j['ur']) ?? 0,
        sc: _int(j['sc']) ?? 0,
        st: _int(j['st']) ?? 0,
        obc: _int(j['obc']) ?? 0,
        ews: _int(j['ews']) ?? 0,
        total: _int(j['total']) ?? 0,
      );
}

/// One post of a notification, with its qualification rules already merged by
/// the pipeline (explicit fields + what the degree lines imply).
@immutable
class PublishedPost {
  const PublishedPost({
    required this.id,
    required this.postName,
    this.postCode,
    this.minAge,
    this.baseMaxAge,
    this.ageAsOn,
    this.eligibleStreams = const [],
    this.qualificationText,
    this.rawEligibilityText,
    this.allowedDegrees = const [],
    this.minQualificationLevel,
    this.openToAnyGraduate = false,
    this.openToAnyPostGraduate = false,
    this.minExperienceYears = 0,
    this.ageRelaxationOverrides = const {},
    this.vacancy,
    this.payScale,
    this.monthlyPayMin,
  });

  final String id;
  final String? postCode;
  final String postName;
  final int? minAge;
  final int? baseMaxAge;
  final DateTime? ageAsOn;
  final List<String> eligibleStreams;
  final String? qualificationText;
  final String? rawEligibilityText;
  final List<String> allowedDegrees;
  final String? minQualificationLevel;
  final bool openToAnyGraduate;
  final bool openToAnyPostGraduate;
  final double minExperienceYears;
  final Map<String, int> ageRelaxationOverrides;
  final PublishedVacancy? vacancy;

  /// As printed: "Level 6 (Rs 35,400-1,12,400)", "Rs 37,000 per month".
  final String? payScale;

  /// Entry monthly pay in rupees, when known.
  final int? monthlyPayMin;

  factory PublishedPost.fromJson(Map<String, dynamic> j) => PublishedPost(
        id: j['id'] as String,
        postCode: j['post_code'] as String?,
        postName: j['post_name'] as String? ?? 'Post',
        minAge: _int(j['min_age']),
        baseMaxAge: _int(j['base_max_age']),
        ageAsOn: _date(j['age_as_on']),
        eligibleStreams: [
          for (final s in (j['eligible_streams'] as List<dynamic>? ?? const [])) s.toString()
        ],
        qualificationText: j['qualification_text'] as String?,
        rawEligibilityText: j['raw_eligibility_text'] as String?,
        allowedDegrees: [for (final s in (j['allowed_degrees'] as List<dynamic>? ?? const [])) s.toString()],
        minQualificationLevel: j['min_qualification_level'] as String?,
        openToAnyGraduate: j['is_open_to_any_graduate'] as bool? ?? false,
        openToAnyPostGraduate: j['is_open_to_any_post_graduate'] as bool? ?? false,
        minExperienceYears: (j['min_experience_years'] as num?)?.toDouble() ?? 0,
        ageRelaxationOverrides: {
          for (final e in ((j['age_relaxation_overrides'] as Map<String, dynamic>?) ?? const {}).entries)
            if (e.value is num) e.key: (e.value as num).toInt(),
        },
        vacancy: j['vacancy'] is Map<String, dynamic>
            ? PublishedVacancy.fromJson(j['vacancy'] as Map<String, dynamic>)
            : null,
        payScale: j['pay_scale'] as String?,
        monthlyPayMin: _int(j['monthly_pay_min']),
      );
}

/// One recruitment notification.
@immutable
class PublishedJob {
  const PublishedJob({
    required this.id,
    required this.organization,
    required this.examName,
    required this.posts,
    this.advertisementNo,
    this.portalUrl,
    this.applyUrl,
    this.applicationStart,
    this.applicationDeadline,
    this.examDate,
    this.timelineJson,
    this.category = 'other',
    this.employmentType,
    this.sameAs = const [],
    this.fees = const {},
    this.feeRefund,
  });

  final String id;
  final String organization;
  final String examName;
  final String? advertisementNo;

  /// The organisation's website (the exam watcher checks it for notices).
  final String? portalUrl;

  /// The registration / application page itself, when a job site links it.
  final String? applyUrl;
  final DateTime? applicationStart;
  final DateTime? applicationDeadline;
  final DateTime? examDate;
  final List<PublishedPost> posts;

  /// railway, bank, ssc, upsc, psu, research, defence, state, teaching, medical, court, other.
  final String category;

  /// permanent, contract, apprenticeship, fellowship, internship (null: not stated).
  final String? employmentType;

  /// Raw 5-stage timeline, stored as-is when the user marks a post Applied.
  final Map<String, dynamic>? timelineJson;

  /// Other copies of this notice the pipeline merged into this one (their ids):
  /// applying to or turning down any of them counts for this job too.
  final List<String> sameAs;

  /// Fee in rupees per category ("UR", "SC", "PWBD", "ALL"...), as the notification printed it.
  final Map<String, int> fees;

  /// The refund rule, if printed ("Rs 400 refunded on appearing in CBT-1").
  final String? feeRefund;

  /// This job and the copies merged into it.
  Iterable<String> get ids => [id, ...sameAs];

  factory PublishedJob.fromJson(Map<String, dynamic> j) => PublishedJob(
        id: j['id'] as String,
        organization: j['organization'] as String? ?? '',
        examName: j['exam_name'] as String? ?? '',
        advertisementNo: j['advertisement_no'] as String?,
        portalUrl: j['portal_url'] as String?,
        applyUrl: j['apply_url'] as String?,
        applicationStart: _dateTime(j['application_start']),
        applicationDeadline: _dateTime(j['application_deadline']),
        examDate: _date(j['exam_date']),
        timelineJson: j['timeline'] as Map<String, dynamic>?,
        category: j['category'] as String? ?? 'other',
        employmentType: j['employment_type'] as String?,
        sameAs: [for (final id in (j['same_as'] as List<dynamic>? ?? const [])) '$id'],
        fees: {
          for (final e in ((j['fees'] as Map<String, dynamic>?) ?? const {}).entries)
            if (e.value is num) e.key: (e.value as num).toInt(),
        },
        feeRefund: j['fee_refund'] as String?,
        posts: [
          for (final p in (j['posts'] as List<dynamic>? ?? const []))
            PublishedPost.fromJson(p as Map<String, dynamic>),
        ],
      );
}

@immutable
class JobsFile {
  const JobsFile({required this.generatedAt, required this.jobs});

  final DateTime generatedAt;
  final List<PublishedJob> jobs;

  static final empty = JobsFile(generatedAt: DateTime(1970), jobs: const []);

  /// Throws [FormatException] for a file from a newer, incompatible pipeline.
  factory JobsFile.fromJson(Map<String, dynamic> j) {
    final schema = _int(j['schema']) ?? 0;
    if (schema > kJobsSchemaVersion) {
      throw FormatException(
          'jobs.json schema $schema is newer than this app ($kJobsSchemaVersion). Update the app.');
    }
    return JobsFile(
      generatedAt: _dateTime(j['generated_at']) ?? DateTime(1970),
      jobs: [
        for (final job in (j['jobs'] as List<dynamic>? ?? const []))
          PublishedJob.fromJson(job as Map<String, dynamic>)
      ],
    );
  }
}
