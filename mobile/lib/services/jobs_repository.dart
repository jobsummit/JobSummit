import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/jobs_data.dart';
import 'data_source.dart';
import 'database_service.dart';

/// Result of a load: the jobs and whether they came from the offline cache.
class JobsLoad {
  const JobsLoad(this.file, {required this.fetchedAt, required this.fromCache});

  final JobsFile file;
  final DateTime fetchedAt;
  final bool fromCache;
}

/// Downloads jobs.json (from whichever of its two addresses answers), keeping the
/// last good copy in SQLite for offline start-up. Uses the ETag so an unchanged
/// file costs a few bytes, not the whole download.
class JobsRepository {
  JobsRepository(this._db, {http.Client? client, List<String>? bases})
      : _client = client ?? http.Client(),
        _bases = bases;

  final DatabaseService _db;
  final http.Client _client;
  final List<String>? _bases;

  /// Saved as `address\netag`: an ETag only means something to the server that sent it.
  static const _etagKey = 'jobs.etag';

  Future<JobsLoad?> cached() async {
    try {
      final cached = await _db.readFeedCache();
      if (cached == null) return null;
      return JobsLoad(
        JobsFile.fromJson(jsonDecode(cached.$1) as Map<String, dynamic>),
        fetchedAt: cached.$2,
        fromCache: true,
      );
    } catch (_) {
      return null; // unreadable or from an older app version: refetch
    }
  }

  /// Network first; falls back to the cache. Throws only when there is neither.
  Future<JobsLoad> load() async {
    final cache = await cached();
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = cache == null ? null : prefs.getString(_etagKey)?.split('\n');
      final got = await DataSource(_client, bases: _bases).get('jobs.json',
          headers: (base) => {
                'Accept': 'application/json',
                if (saved != null && saved.length == 2 && saved[0] == base) 'If-None-Match': saved[1],
              });
      final res = got.response;
      final now = DateTime.now();
      if (res.statusCode == 304 && cache != null) {
        await _db.touchFeedCache(now);
        return JobsLoad(cache.file, fetchedAt: now, fromCache: false);
      }
      if (res.statusCode != 200) {
        throw http.ClientException('jobs.json: HTTP ${res.statusCode}', Uri.parse(got.base));
      }
      final body = utf8.decode(res.bodyBytes);
      final file = JobsFile.fromJson(jsonDecode(body) as Map<String, dynamic>); // validate before caching
      // Right after a pipeline run one address can lag the other: never step back.
      if (cache != null && file.generatedAt.isBefore(cache.file.generatedAt)) {
        await _db.touchFeedCache(now);
        return JobsLoad(cache.file, fetchedAt: now, fromCache: false);
      }
      await _db.cacheFeed(body, now);
      final etag = res.headers['etag'];
      if (etag != null) {
        await prefs.setString(_etagKey, '${got.base}\n$etag');
      } else {
        await prefs.remove(_etagKey);
      }
      return JobsLoad(file, fetchedAt: now, fromCache: false);
    } catch (_) {
      if (cache != null) return cache;
      rethrow;
    }
  }

  void close() => _client.close();
}
