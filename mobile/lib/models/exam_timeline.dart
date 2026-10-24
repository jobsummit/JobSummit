import 'package:flutter/foundation.dart';

/// Mirrors backend `LifecycleTimelineOut`: the post-application milestones of one
/// notification, shared by everyone who applied. Every field may be missing.
@immutable
class ExamTimeline {
  const ExamTimeline({
    required this.jobPostId,
    this.applicationEnd,
    this.feeDeadline,
    this.editWindowStart,
    this.editWindowEnd,
    this.correctionUrl,
    this.admitCardRelease,
    this.admitCardUrl,
    this.examStart,
    this.examEnd,
    this.reportingTime,
    this.shiftDetails,
    this.examCitySlipUrl,
    this.answerKeyRelease,
    this.answerKeyUrl,
    this.objectionDeadline,
    this.questionPaperUrl,
    this.challengePortalUrl,
    this.resultDate,
    this.meritListUrl,
    this.scorecardUrl,
    this.cutoffMarks = const {},
  });

  final String jobPostId;
  final DateTime? applicationEnd;
  final DateTime? feeDeadline;
  final DateTime? editWindowStart;
  final DateTime? editWindowEnd;

  /// The correction notice the exam watcher found.
  final String? correctionUrl;
  final DateTime? admitCardRelease;
  final String? admitCardUrl;
  final DateTime? examStart;
  final DateTime? examEnd;
  final String? reportingTime;
  final String? shiftDetails;
  final String? examCitySlipUrl;
  final DateTime? answerKeyRelease;
  final String? answerKeyUrl;
  final DateTime? objectionDeadline;
  final String? questionPaperUrl;
  final String? challengePortalUrl;
  final DateTime? resultDate;
  final String? meritListUrl;
  final String? scorecardUrl;
  final Map<String, double> cutoffMarks;

  /// Date-only fields ("2026-12-14") become local calendar dates.
  static DateTime? _date(Object? v) {
    if (v is! String || v.isEmpty) return null;
    final d = DateTime.tryParse(v);
    if (d == null) return null;
    return v.length <= 10 ? DateTime(d.year, d.month, d.day) : d.toLocal();
  }

  static String? _url(Object? v) => v is String && v.isNotEmpty ? v : null;

  factory ExamTimeline.fromJson(Map<String, dynamic> j) => ExamTimeline(
        jobPostId: j['job_post_id'] as String,
        applicationEnd: _date(j['application_end']),
        feeDeadline: _date(j['fee_deadline']),
        editWindowStart: _date(j['edit_window_start']),
        editWindowEnd: _date(j['edit_window_end']),
        correctionUrl: _url(j['correction_url']),
        admitCardRelease: _date(j['admit_card_release']),
        admitCardUrl: _url(j['admit_card_url']),
        examStart: _date(j['exam_start']),
        examEnd: _date(j['exam_end']),
        reportingTime: j['reporting_time'] as String?,
        shiftDetails: j['shift_details'] as String?,
        examCitySlipUrl: _url(j['exam_city_slip_url']),
        answerKeyRelease: _date(j['answer_key_release']),
        answerKeyUrl: _url(j['answer_key_url']),
        objectionDeadline: _date(j['objection_deadline']),
        questionPaperUrl: _url(j['question_paper_url']),
        challengePortalUrl: _url(j['challenge_portal_url']),
        resultDate: _date(j['result_date']),
        meritListUrl: _url(j['merit_list_url']),
        scorecardUrl: _url(j['scorecard_url']),
        cutoffMarks: {
          for (final e in ((j['cutoff_marks'] as Map<String, dynamic>?) ?? const {}).entries)
            if (e.value is num) e.key: (e.value as num).toDouble(),
        },
      );
}
