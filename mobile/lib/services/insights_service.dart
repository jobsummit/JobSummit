import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/env.dart';

/// "Help improve job picks": your yes or no, this phone's random id, and the
/// once-a-day upload (only when something changed). Never sent without a yes.
class InsightsService {
  InsightsService({http.Client? client, String? url, String? key})
      : _client = client ?? http.Client(),
        _url = (url ?? Env.supabaseUrl).replaceFirst(RegExp(r'/+$'), ''),
        _key = key ?? Env.supabaseKey;

  final http.Client _client;
  final String _url;
  final String _key;

  static const _kConsent = 'insights.consent';
  static const _kId = 'insights.id';
  static const _kLast = 'insights.last';
  static const _kHash = 'insights.hash';

  static const every = Duration(hours: 24);

  /// null: not asked yet.
  static Future<bool?> consent() async => (await SharedPreferences.getInstance()).getBool(_kConsent);

  static Future<void> setConsent(bool yes) async => (await SharedPreferences.getInstance()).setBool(_kConsent, yes);

  /// A random id for this phone (made on the first share; a new one after "Delete").
  static Future<String> installId() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_kId);
    if (saved != null) return saved;
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80;
    final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    final id = '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
    await prefs.setString(_kId, id);
    return id;
  }

  static Future<bool> hasShared() async => (await SharedPreferences.getInstance()).getString(_kLast) != null;

  Map<String, String> get _headers => {'apikey': _key, 'Content-Type': 'application/json'};

  /// Sends [payload] when you said yes, it changed since the last time or a day
  /// has passed, and not within the hour. True when it was sent.
  Future<bool> maybeUpload(Map<String, Object?> payload, {DateTime? now}) async {
    if (await consent() != true) return false;
    final prefs = await SharedPreferences.getInstance();
    final at = now ?? DateTime.now();
    final last = DateTime.tryParse(prefs.getString(_kLast) ?? '');
    final body = jsonEncode({'payload': payload});
    final hash = '${body.length}:${body.hashCode}';
    if (last != null) {
      final since = at.difference(last);
      if (since < const Duration(hours: 1)) return false;
      if (since < every && prefs.getString(_kHash) == hash) return false;
    }
    try {
      final res = await _client
          .post(Uri.parse('$_url/rest/v1/rpc/ingest'), headers: _headers, body: body)
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) return false;
      final answer = jsonDecode(res.body);
      if (answer != 'ok' && answer != 'too soon') return false;
      await prefs.setString(_kLast, at.toIso8601String());
      await prefs.setString(_kHash, hash);
      return answer == 'ok';
    } catch (_) {
      return false; // offline: tomorrow
    }
  }

  /// "Delete my shared data": everything for this phone's id goes, sharing
  /// stops, and a later yes starts with a new id. Throws when the server
  /// couldn't be reached (nothing is changed then).
  Future<void> forget() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_kId);
    if (id != null) {
      final res = await _client
          .post(Uri.parse('$_url/rest/v1/rpc/forget'), headers: _headers, body: jsonEncode({'install_id': id}))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw http.ClientException('HTTP ${res.statusCode}');
    }
    await prefs.setBool(_kConsent, false);
    for (final k in [_kId, _kLast, _kHash]) {
      await prefs.remove(k);
    }
  }
}
