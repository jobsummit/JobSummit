import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/widget_summary.dart';

/// The home-screen widget (android SummitWidget) reads [key] from the app's
/// shared preferences. Works from the background task too; only the instant
/// redraw needs the app on screen (the widget also redraws every ~30 minutes).
abstract final class HomeWidget {
  static const key = 'widget.summary';
  static const _channel = MethodChannel('jobsummit/widget');

  static Future<void> write(WidgetSummary summary) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(summary.toJson());
    if (prefs.getString(key) == json) return;
    await prefs.setString(key, json);
    try {
      await _channel.invokeMethod<void>('refresh');
    } on MissingPluginException {
      // Background task or tests: the widget catches up on its own.
    } on PlatformException {
      // Same.
    }
  }
}
