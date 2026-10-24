import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/practice.dart';
import 'data_source.dart';

/// The pipeline's question bank, one file per section (practice/<section>.json),
/// kept on the phone so tests work offline. Asked again at most once a day, with
/// the ETag, so an unchanged file costs a few bytes.
class PracticeBank {
  PracticeBank({http.Client? client, List<String>? bases, Directory? dir})
      : _client = client ?? http.Client(),
        _bases = bases,
        _dir = dir;

  final http.Client _client;
  final List<String>? _bases;
  final Directory? _dir;

  static const refreshAfter = Duration(hours: 24);

  Future<File> _file(PracticeSection s) async {
    final dir = _dir ?? Directory('${(await getApplicationSupportDirectory()).path}/practice');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/${s.name}.json');
  }

  static List<PracticeQuestion> parse(PracticeSection s, String body) {
    final j = jsonDecode(body);
    final list = j is Map<String, dynamic> ? j['questions'] : null;
    if (list is! List) return const [];
    return [for (final q in list) if (PracticeQuestion.fromJson(s, q) case final v?) v];
  }

  /// The section's questions: the saved copy, refreshed when it's a day old (or
  /// missing). Offline, the saved copy; with none, an empty list.
  Future<List<PracticeQuestion>> load(PracticeSection s, {DateTime? now}) async {
    final file = await _file(s);
    final prefs = await SharedPreferences.getInstance();
    final checkedKey = 'practice.bank.${s.name}.checked', etagKey = 'practice.bank.${s.name}.etag';
    final saved = await file.exists() ? await file.readAsString() : null;
    final at = DateTime.now();
    final checked = DateTime.tryParse(prefs.getString(checkedKey) ?? '');
    final cached = saved == null ? const <PracticeQuestion>[] : _safeParse(s, saved);
    if (cached.isNotEmpty && checked != null && (now ?? at).difference(checked) < refreshAfter) return cached;
    try {
      final tag = cached.isEmpty ? null : prefs.getString(etagKey)?.split('\n');
      final got = await DataSource(_client, bases: _bases).get('practice/${s.name}.json',
          headers: (base) => {
                'Accept': 'application/json',
                if (tag != null && tag.length == 2 && tag[0] == base) 'If-None-Match': tag[1],
              });
      await prefs.setString(checkedKey, (now ?? at).toIso8601String());
      if (got.response.statusCode == 304) return cached;
      final body = utf8.decode(got.response.bodyBytes);
      final fresh = parse(s, body);
      if (fresh.isEmpty) return cached;
      await file.writeAsString(body, flush: true);
      final etag = got.response.headers['etag'];
      if (etag != null) {
        await prefs.setString(etagKey, '${got.base}\n$etag');
      } else {
        await prefs.remove(etagKey);
      }
      return fresh;
    } catch (_) {
      return cached; // offline, or the pipeline hasn't made this section yet
    }
  }

  static List<PracticeQuestion> _safeParse(PracticeSection s, String body) {
    try {
      return parse(s, body);
    } catch (_) {
      return const [];
    }
  }
}
