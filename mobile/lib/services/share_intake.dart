import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

/// Jobs shared to JobSummit from other apps (Android's share menu; MainActivity).
abstract final class ShareIntake {
  static const _channel = MethodChannel('jobsummit/share');

  /// The newest shared text, until the home screen takes it.
  static final incoming = ValueNotifier<String?>(null);
  static bool _ready = false;

  /// Hears later shares, and takes the one that opened the app.
  static Future<void> init() async {
    if (_ready) return;
    _ready = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shared' && call.arguments is String) incoming.value = call.arguments as String;
    });
    try {
      final first = await _channel.invokeMethod<String>('take');
      if (first != null) incoming.value = first;
    } on MissingPluginException {
      // Tests and other platforms: nothing is shared.
    } on PlatformException {
      // Same.
    }
  }

  /// A shared bare link's page title ("SSC CGL 2026 Notification"), or ''.
  static Future<String> pageTitle(String url, {http.Client? client}) async {
    final own = client == null;
    final c = client ?? http.Client();
    try {
      final res = await c.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200 || res.bodyBytes.length > 3 * 1024 * 1024) return '';
      final doc = html.parse(res.body);
      final title = doc.querySelector('h1')?.text ?? doc.querySelector('title')?.text ?? '';
      return title.replaceAll(RegExp(r'\s+'), ' ').trim();
    } catch (_) {
      return ''; // offline or a page that won't load: the words alone decide
    } finally {
      if (own) c.close();
    }
  }
}
