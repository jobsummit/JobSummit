import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../domain/exam_catalog.dart';
import 'exam_timeline.dart';
import 'links.dart';

enum ApplicationStatus {
  applied('applied', 'Applied'),
  admitCardLive('admit_card_live', 'Admit card live'),
  examScheduled('exam_scheduled', 'Exam scheduled');

  const ApplicationStatus(this.wire, this.label);
  final String wire;
  final String label;

  static ApplicationStatus fromWire(String? value) =>
      values.firstWhere((s) => s.wire == value, orElse: () => ApplicationStatus.applied);
}

/// Exam-watcher progress (backend `ApplicationStatus` minus "discovered").
/// Local [ApplicationStatus] covers what the user sets by hand; this is what the
/// watcher found on the exam's notice boards. The card shows whichever is further.
enum TrackerStatus {
  applied('applied', 'Applied'),
  admitCardLive('admit_card_live', 'Admit Card Live'),
  examScheduled('exam_scheduled', 'Exam Scheduled'),
  answerKeyLive('answer_key_live', 'Answer Key Released'),
  resultDeclared('result_declared', 'Result Declared');

  const TrackerStatus(this.wire, this.label);
  final String wire;
  final String label;

  static TrackerStatus? fromWire(String? value) {
    for (final s in values) {
      if (s.wire == value) return s;
    }
    return null;
  }
}

/// One notice the exam watcher found (stored newest first in `updates_json`).
@immutable
class ExamUpdate {
  const ExamUpdate({
    required this.milestone,
    required this.title,
    required this.url,
    this.eventDate,
    this.detectedAt,
    this.source,
    this.link,
    this.publishedAt,
    this.examId,
  });

  final String milestone; // admit_card | exam_schedule | postponed | answer_key | result
  final String title;

  /// The notice's identity (an aggregator's page for it).
  final String url;

  /// The official link from that page (the admit card download, the answer key, the
  /// result), when the pipeline found one.
  final String? link;

  /// What a tap opens: the official link, else the notice's page.
  String get open => link ?? url;
  final DateTime? eventDate;
  final DateTime? detectedAt;
  final String? source; // official | aggregator

  /// When the job site posted it (notices.json), if known.
  final DateTime? publishedAt;

  /// The exam list id Mistral read it as (notices.json `about.exam`), if any.
  final String? examId;

  static DateTime? _day(Object? v) {
    final d = v is String ? DateTime.tryParse(v) : null;
    return d == null ? null : DateTime(d.year, d.month, d.day);
  }

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  factory ExamUpdate.fromJson(Map<String, dynamic> j) => ExamUpdate(
        milestone: j['milestone'] as String? ?? '',
        title: j['title'] as String? ?? '',
        url: j['url'] as String? ?? '',
        eventDate: _day(j['event_date']),
        detectedAt: j['detected_at'] is String ? DateTime.tryParse(j['detected_at'] as String) : null,
        source: j['source'] as String?,
        link: j['link'] as String?,
        publishedAt: j['published_at'] is String ? DateTime.tryParse(j['published_at'] as String) : null,
        examId: j['exam'] as String?,
      );

  Map<String, Object?> toJson() => {
        'milestone': milestone,
        'title': title,
        'url': url,
        'event_date': eventDate == null ? null : _iso(eventDate!),
        'detected_at': detectedAt?.toUtc().toIso8601String(),
        'source': source,
        if (link != null) 'link': link,
        if (publishedAt != null) 'published_at': publishedAt!.toUtc().toIso8601String(),
        if (examId != null) 'exam': examId,
      };
}

int? _ms(DateTime? d) => d?.toUtc().millisecondsSinceEpoch;
DateTime? _dt(Object? ms) => ms is int ? DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true) : null;

@immutable
class TrackedApplication {
  const TrackedApplication({
    required this.id,
    required this.examName,
    required this.postName,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.organization,
    this.deadline,
    this.examAt,
    this.admitCardUrl,
    this.portalUrl,
    this.applyUrl,
    this.category,
    this.totalSeats,
    this.urSeats,
    this.quotaSeats,
    this.archived = false,
    this.calendarSynced = false,
    this.jobPostId,
    this.timeline,
    this.timelineRaw,
    this.watcherStatus,
    this.updates = const [],
    this.tiers = const [],
    this.tier = 0,
  });

  /// Backend `post_detail_id` when tracked from the feed, so the feed can hide it.
  final String id;
  final String examName;
  final String postName;
  final String? organization;
  final ApplicationStatus status;
  final DateTime? deadline;
  final DateTime? examAt;
  final String? admitCardUrl;

  /// The organisation's website: the exam watcher checks it for notices.
  final String? portalUrl;

  /// The registration / application login page, when a job site linked it.
  final String? applyUrl;
  final String? category; // UR / SC / ST / OBC / EWS
  final int? totalSeats;
  final int? urSeats;
  final int? quotaSeats;
  final bool archived;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Derived (from calendar_event_refs), never written back.
  final bool calendarSynced;

  /// Backend `job_post_id` (the notification), used to refresh [timeline].
  final String? jobPostId;

  /// Post-application milestones from the server; null until first fetched.
  final ExamTimeline? timeline;

  /// The same timeline as stored JSON, so the exam watcher can add to it.
  final Map<String, dynamic>? timelineRaw;

  /// What the exam watcher found on notice boards; null until it finds something.
  final TrackerStatus? watcherStatus;

  /// Watcher notices, newest first.
  final List<ExamUpdate> updates;

  /// The exam's stages when it has several (Tier-1, Tier-2…), from the exam
  /// list when it was added; [tier] is the one this entry tracks. Each tier is
  /// tracked as its own entry, so the watcher and backup rules stay per round.
  final List<String> tiers;
  final int tier;

  /// The built-in exam this one is (stages, board website), when it is clear.
  CatalogExam? get catalogExam => matchCatalogExam('$examName $postName ${organization ?? ''}');

  /// Stages saved with the exam, else the ones the exam list knows.
  List<String> get effectiveTiers => tiers.isNotEmpty ? tiers : (catalogExam?.stages ?? const []);

  String? get tierName => tier < effectiveTiers.length && effectiveTiers.length > 1 ? effectiveTiers[tier] : null;

  String? get nextTierName => tier + 1 < effectiveTiers.length ? effectiveTiers[tier + 1] : null;

  /// The board's website and notice board. A job site's article (where the job
  /// was found) only when the exam list doesn't know the board's site.
  String? get officialUrl => isJobSite(portalUrl)
      ? preferredUrl(catalogExam?.officialUrl, portalUrl)
      : preferredUrl(portalUrl, catalogExam?.officialUrl);

  /// Candidate login: the application page, else the board's login, else its website.
  String? get loginUrl => preferredUrl(applyUrl, catalogExam?.loginUrl) ?? officialUrl;

  /// The further of what the user set and what the watcher found.
  TrackerStatus get displayStatus {
    final local = switch (status) {
      ApplicationStatus.applied => TrackerStatus.applied,
      ApplicationStatus.admitCardLive => TrackerStatus.admitCardLive,
      ApplicationStatus.examScheduled => TrackerStatus.examScheduled,
    };
    final found = watcherStatus;
    return found != null && found.index > local.index ? found : local;
  }

  /// Newest watcher notice of a kind ('admit_card', 'result', ...).
  ExamUpdate? latestUpdate(String milestone) {
    for (final u in updates) {
      if (u.milestone == milestone) return u;
    }
    return null;
  }

  /// Exam date the user entered, else the one the notification announced.
  DateTime? get effectiveExamAt => examAt ?? timeline?.examStart;

  /// Last day of the exam: a window's end ("12–19 October"), else its one day. A
  /// date the user entered wins over the notice's.
  DateTime? get examEnd => examAt ?? timeline?.examEnd ?? timeline?.examStart;

  /// The exam has happened (its last day is over).
  bool examOver(DateTime now) {
    final end = examEnd;
    return end != null && now.isAfter(DateTime(end.year, end.month, end.day, 23, 59, 59));
  }

  /// The date that matters *now*: the exam until it is over (its last day once a
  /// window has started), else an application deadline still ahead. Null once the
  /// exam is done: what comes next (answer key, result) has no fixed date.
  DateTime? focusDateAt(DateTime now) {
    final start = effectiveExamAt;
    if (start != null) {
      if (examOver(now)) return null;
      return now.isBefore(start) ? start : examEnd;
    }
    final due = deadline;
    return status == ApplicationStatus.applied && due != null && due.isAfter(now) ? due : null;
  }

  /// Where you log in to pay, correct the form or download the admit card: the
  /// application page, else the official website.
  String? get applicationUrl => preferredUrl(applyUrl, portalUrl);

  /// Best link for "application login" / "download admit card".
  String? get actionUrl => status == ApplicationStatus.admitCardLive
      ? (admitCardUrl ?? timeline?.admitCardUrl ?? applicationUrl)
      : applicationUrl;

  static List<ExamUpdate> _updates(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      return [
        for (final u in jsonDecode(raw) as List<dynamic>) ExamUpdate.fromJson(u as Map<String, dynamic>)
      ];
    } catch (_) {
      return const [];
    }
  }

  static Map<String, dynamic>? _timelineRaw(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null; // unreadable: rebuilt by the next watcher run
    }
  }

  static List<String> _tiers(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      return [for (final t in jsonDecode(raw) as List<dynamic>) '$t'];
    } catch (_) {
      return const [];
    }
  }

  static ExamTimeline? _timeline(Map<String, dynamic>? raw) {
    if (raw == null || raw['job_post_id'] is! String) return null;
    try {
      return ExamTimeline.fromJson(raw);
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> toRow() => {
        'id': id,
        'exam_name': examName,
        'post_name': postName,
        'organization': organization,
        'status': status.wire,
        'deadline_timestamp': _ms(deadline),
        'exam_timestamp': _ms(examAt),
        'admit_card_url': admitCardUrl,
        'portal_url': portalUrl,
        'apply_url': applyUrl,
        'category': category,
        'total_seats': totalSeats,
        'ur_seats': urSeats,
        'quota_seats': quotaSeats,
        'archived': archived ? 1 : 0,
        'created_at': _ms(createdAt),
        'updated_at': _ms(updatedAt),
        'job_post_id': jobPostId,
        'tiers_json': tiers.isEmpty ? null : jsonEncode(tiers),
        'tier': tier,
        // timeline/server state is written separately (DatabaseService.saveTimeline,
        // saveWatcherState) so a local edit never overwrites it with a stale copy.
      };

  factory TrackedApplication.fromRow(Map<String, Object?> r) => TrackedApplication(
        id: r['id']! as String,
        examName: r['exam_name']! as String,
        postName: r['post_name']! as String,
        organization: r['organization'] as String?,
        status: ApplicationStatus.fromWire(r['status'] as String?),
        deadline: _dt(r['deadline_timestamp']),
        examAt: _dt(r['exam_timestamp']),
        admitCardUrl: r['admit_card_url'] as String?,
        portalUrl: r['portal_url'] as String?,
        applyUrl: r['apply_url'] as String?,
        category: r['category'] as String?,
        totalSeats: r['total_seats'] as int?,
        urSeats: r['ur_seats'] as int?,
        quotaSeats: r['quota_seats'] as int?,
        archived: r['archived'] == 1,
        calendarSynced: r['calendar_synced'] == 1,
        createdAt: _dt(r['created_at'])!,
        updatedAt: _dt(r['updated_at'])!,
        jobPostId: r['job_post_id'] as String?,
        timeline: _timeline(_timelineRaw(r['timeline_json'])),
        timelineRaw: _timelineRaw(r['timeline_json']),
        // Column name kept from the server era; it now holds the phone watcher's status.
        watcherStatus: TrackerStatus.fromWire(r['server_status'] as String?),
        updates: _updates(r['updates_json']),
        tiers: _tiers(r['tiers_json']),
        tier: r['tier'] as int? ?? 0,
      );

  TrackedApplication copyWith({
    ApplicationStatus? status,
    DateTime? examAt,
    String? admitCardUrl,
    bool? archived,
    DateTime? updatedAt,
  }) =>
      TrackedApplication(
        id: id,
        examName: examName,
        postName: postName,
        organization: organization,
        status: status ?? this.status,
        deadline: deadline,
        examAt: examAt ?? this.examAt,
        admitCardUrl: admitCardUrl ?? this.admitCardUrl,
        portalUrl: portalUrl,
        applyUrl: applyUrl,
        category: category,
        totalSeats: totalSeats,
        urSeats: urSeats,
        quotaSeats: quotaSeats,
        archived: archived ?? this.archived,
        calendarSynced: calendarSynced,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        jobPostId: jobPostId,
        timeline: timeline,
        timelineRaw: timelineRaw,
        watcherStatus: watcherStatus,
        updates: updates,
        tiers: tiers,
        tier: tier,
      );
}
