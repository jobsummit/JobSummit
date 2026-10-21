import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/exam_watcher.dart';
import '../models/links.dart';
import '../models/tracked_application.dart';
import 'data_source.dart';
import 'database_service.dart';
import 'page_links.dart';

/// New notices found for one tracked exam in one run.
@immutable
class WatchFinding {
  const WatchFinding(this.before, this.after, this.updates);

  final TrackedApplication before;
  final TrackedApplication after;
  final List<DetectedUpdate> updates;
}

/// Phase 2 watcher, run on the phone (Indian internet, so official portals that
/// block GitHub's US servers still answer):
///   1. each tracked exam's own portal link, and
///   2. notices.json — admit card / answer key / result notices GitHub collected
///      from job sites — matched to each exam by name.
/// A notice URL is recorded once per exam, so only unseen ones count as new.
class ExamWatchService {
  ExamWatchService(this._db, {http.Client? client}) : _client = client ?? http.Client();

  final DatabaseService _db;
  final http.Client _client;

  static const _timeout = Duration(seconds: 20);
  static const _maxPageBytes = 4 * 1024 * 1024;
  static const _keepUpdates = 30;
  // Results can arrive more than a year after applying; after that, stop watching.
  static const _watchWindow = Duration(days: 548);
  static const _userAgent = 'Mozilla/5.0 (Linux; Android) JobSummit/0.8 (personal exam tracker)';

  /// [pageGap]: how long a board page that was just read is left alone (the
  /// background check runs every 15 minutes; the boards' pages change far less
  /// often). notices.json is checked every time: unchanged, it costs a "not modified".
  Future<List<WatchFinding>> run({DateTime? now, Duration pageGap = Duration.zero}) async {
    final at = now ?? DateTime.now();
    _prefs = await _loadPrefs();
    _pageGap = pageGap;
    _at = at;
    final findings = <WatchFinding>[];
    final apps = <TrackedApplication>[];
    for (var a in await _db.listApplications()) {
      if (a.archived || !a.createdAt.isAfter(at.subtract(_watchWindow))) continue;
      // Notices from another round of the exam come off first (a result found
      // that way may be all that stopped the watching).
      final fixed = withoutStrayUpdates(a);
      if (fixed != null) {
        await _db.saveWatcherState(
          a.id,
          status: fixed.status.wire,
          updatesJson: jsonEncode([for (final u in fixed.updates) u.toJson()]),
          timelineJson: jsonEncode(fixed.timeline),
        );
        final after = await _db.getApplication(a.id) ?? a;
        findings.add(WatchFinding(a, after, const []));
        a = after;
      }
      if (a.displayStatus != TrackerStatus.resultDeclared) apps.add(a);
    }
    if (apps.isEmpty) return findings;

    final notices = await _notices();
    final pages = <String, List<PageLink>?>{}; // one fetch per portal per run
    for (var app in apps) {
      // Notices already seen are not detected again: re-read their dates instead.
      if (app.updates.isNotEmpty) {
        final base = app.timelineRaw ?? <String, dynamic>{'job_post_id': app.jobPostId ?? app.id};
        final refreshed = refreshExamDates(base, app.updates, at);
        if (jsonEncode(refreshed) != jsonEncode(base)) {
          await _db.saveAppTimeline(app.id, jsonEncode(refreshed));
          app = await _db.getApplication(app.id) ?? app;
        }
      }
      final known = {for (final u in app.updates) canonicalUrl(u.url)};
      final detected = <DetectedUpdate>[];
      final round = ExamRound.of(app);
      // The board's site (a job site's article only when the board's isn't known),
      // and where the board posts call letters and results (IBPS, SBI, RBI, NABARD).
      final portal = app.officialUrl;
      final boardPages = <String, bool>{
        if (portal != null && portal.isNotEmpty) portal: isExamSpecificPage(portal),
        for (final url in app.catalogExam?.watchUrls ?? const <String>[]) url: false,
      };
      for (final MapEntry(key: url, value: specific) in boardPages.entries) {
        final links = pages.containsKey(url) ? pages[url] : (pages[url] = await _pageLinksIfDue(url));
        if (links == null) continue;
        detected.addAll(detectUpdates(
          links,
          examName: app.examName,
          organization: app.organization,
          source: UpdateSource.official,
          examSpecificPage: specific,
          boardsOwnPage: !isJobSite(url),
          knownUrls: {...known, for (final d in detected) d.url},
          now: at,
          stage: app.tierName,
          round: round,
        ));
      }
      detected.addAll(detectUpdates(
        notices,
        examName: app.examName,
        organization: app.organization,
        source: UpdateSource.aggregator,
        examSpecificPage: false,
        knownUrls: {...known, for (final d in detected) d.url},
        now: at,
        stage: app.tierName,
        round: round,
      ));
      if (detected.isEmpty) continue;
      final i = findings.indexWhere((f) => f.after.id == app.id);
      final finding = await _record(app, detected, at);
      if (i >= 0) {
        findings[i] = WatchFinding(findings[i].before, finding.after, finding.updates);
      } else {
        findings.add(finding);
      }
    }
    return findings;
  }

  Future<WatchFinding> _record(TrackedApplication app, List<DetectedUpdate> detected, DateTime at) async {
    final status =
        advanceStatus(app.watcherStatus ?? TrackerStatus.applied, detected.map((d) => d.milestone));
    final updates = [
      for (final d in detected)
        ExamUpdate(
          milestone: d.milestone.wire,
          title: d.title,
          url: d.url,
          link: d.link,
          eventDate: d.eventDate,
          detectedAt: at,
          source: d.source.name,
          publishedAt: d.publishedAt,
        ),
      ...app.updates,
    ].take(_keepUpdates).toList();
    var timeline = app.timelineRaw ?? <String, dynamic>{'job_post_id': app.jobPostId ?? app.id};
    for (final d in detected) {
      timeline = fillTimeline(timeline, d, at);
    }
    await _db.saveWatcherState(
      app.id,
      status: status.wire,
      updatesJson: jsonEncode([for (final u in updates) u.toJson()]),
      timelineJson: jsonEncode(timeline),
    );
    final after = await _db.getApplication(app.id) ?? app;
    return WatchFinding(app, after, detected);
  }

  SharedPreferences? _prefs;
  Duration _pageGap = Duration.zero;
  DateTime _at = DateTime.now();

  static const _noticesEtagKey = 'watch.notices.etag'; // "address\netag"
  static const _noticesBodyKey = 'watch.notices.body';
  static const _pageReadPrefix = 'watch.page.';

  static Future<SharedPreferences?> _loadPrefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null; // no storage (tests): read everything every time
    }
  }

  /// A board page, unless it was read less than [_pageGap] ago (its links were
  /// seen then). Kind to the boards' sites: one read per page per gap, shared by
  /// every exam on that board.
  Future<List<PageLink>?> _pageLinksIfDue(String url) async {
    final key = '$_pageReadPrefix$url';
    final last = _prefs?.getInt(key);
    if (last != null &&
        _at.difference(DateTime.fromMillisecondsSinceEpoch(last)) < _pageGap &&
        _pageGap > Duration.zero) {
      return null;
    }
    await _prefs?.setInt(key, _at.millisecondsSinceEpoch);
    return _pageLinks(url);
  }

  /// notices.json, downloaded again only when it changed (ETag).
  Future<String?> _noticesBody() async {
    final prefs = _prefs;
    final saved = prefs?.getString(_noticesEtagKey)?.split('\n');
    final cached = prefs?.getString(_noticesBodyKey);
    final got = await DataSource(_client).get('notices.json', headers: (base) => {
          if (cached != null && saved != null && saved.length == 2 && saved[0] == base) 'If-None-Match': saved[1],
        });
    final res = got.response;
    if (res.statusCode == 304) return cached;
    if (res.statusCode != 200) return null;
    final body = utf8.decode(res.bodyBytes);
    final etag = res.headers['etag'];
    try {
      if (etag != null) {
        await prefs?.setString(_noticesEtagKey, '${got.base}\n$etag');
        await prefs?.setString(_noticesBodyKey, body);
      } else {
        await prefs?.remove(_noticesEtagKey);
      }
    } catch (_) {}
    return body;
  }

  Future<List<PageLink>> _notices() async {
    try {
      final body = await _noticesBody();
      if (body == null) return const [];
      final data = jsonDecode(body) as Map<String, dynamic>;
      return [
        for (final n in (data['notices'] as List<dynamic>? ?? const []))
          if (n is Map<String, dynamic> && n['url'] is String)
            PageLink(
              url: n['url'] as String,
              title: n['title'] as String? ?? '',
              link: n['link'] as String?,
              publishedAt: n['published_at'] is String ? DateTime.tryParse(n['published_at'] as String) : null,
            ),
      ];
    } catch (_) {
      return const []; // offline or the pipeline hasn't run yet: portals still get checked
    }
  }

  /// null when the page can't be read this time (offline, blocked, not HTML).
  Future<List<PageLink>?> _pageLinks(String url) async {
    try {
      final uri = Uri.parse(url.contains('://') ? url : 'https://$url');
      final res = await _client
          .get(uri, headers: {'User-Agent': _userAgent, 'Accept': 'text/html,*/*'}).timeout(_timeout);
      if (res.statusCode != 200 || res.bodyBytes.length > _maxPageBytes) return null;
      final type = res.headers['content-type'] ?? '';
      if (type.contains('pdf')) return const [];
      return extractPageLinks(
          utf8.decode(res.bodyBytes, allowMalformed: true), res.request?.url.toString() ?? url);
    } catch (_) {
      return null;
    }
  }

  void close() => _client.close();
}
