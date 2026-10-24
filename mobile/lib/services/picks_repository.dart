import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/picks.dart';
import 'data_source.dart';

/// The job-picks model (picks.json): kept on the phone, asked again at most once
/// a day. Without it, jobs rank by your own choices alone.
class PicksRepository {
  PicksRepository({http.Client? client, List<String>? bases, Directory? dir})
      : _client = client ?? http.Client(),
        _bases = bases,
        _dir = dir;

  final http.Client _client;
  final List<String>? _bases;
  final Directory? _dir;

  static const _kChecked = 'picks.checked';
  static const _kEtag = 'picks.etag';

  Future<File> _file() async => File('${(_dir ?? await getApplicationSupportDirectory()).path}/picks.json');

  Future<Picks> load({DateTime? now}) async {
    final file = await _file();
    final prefs = await SharedPreferences.getInstance();
    final at = now ?? DateTime.now();
    Picks cached = Picks.empty;
    final saved = await file.exists();
    if (saved) {
      try {
        cached = Picks.fromJson(jsonDecode(await file.readAsString()));
      } catch (_) {}
    }
    final checked = DateTime.tryParse(prefs.getString(_kChecked) ?? '');
    if (checked != null && at.difference(checked) < const Duration(hours: 24) && saved) return cached;
    try {
      final tag = prefs.getString(_kEtag)?.split('\n');
      final got = await DataSource(_client, bases: _bases).get('picks.json',
          headers: (base) => {
                if (saved && tag != null && tag.length == 2 && tag[0] == base) 'If-None-Match': tag[1],
              });
      await prefs.setString(_kChecked, at.toIso8601String());
      if (got.response.statusCode == 304) return cached;
      final body = utf8.decode(got.response.bodyBytes);
      final fresh = Picks.fromJson(jsonDecode(body));
      await file.writeAsString(body, flush: true);
      final etag = got.response.headers['etag'];
      if (etag != null) await prefs.setString(_kEtag, '${got.base}\n$etag');
      return fresh;
    } catch (_) {
      return cached;
    }
  }
}
