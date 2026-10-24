import 'package:device_calendar/device_calendar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import '../config/env.dart';
import '../models/tracked_application.dart';
import 'database_service.dart';

enum CalendarSyncError { permissionDenied, noWritableCalendar, nothingToSync, platformError }

sealed class CalendarSyncResult {
  const CalendarSyncResult();
}

final class CalendarSyncSuccess extends CalendarSyncResult {
  const CalendarSyncSuccess(this.eventsWritten);
  final int eventsWritten;
}

final class CalendarSyncFailure extends CalendarSyncResult {
  const CalendarSyncFailure(this.error, [this.message]);
  final CalendarSyncError error;
  final String? message;

  String get userMessage => switch (error) {
        CalendarSyncError.permissionDenied => 'Calendar permission is off. Allow it in Settings to sync.',
        CalendarSyncError.noWritableCalendar => 'No writable calendar found on this phone.',
        CalendarSyncError.nothingToSync => 'No upcoming deadline or exam date to add yet.',
        CalendarSyncError.platformError => 'Could not write to the calendar. Try again.',
      };
}

/// One calendar event we intend to write.
class _EventSpec {
  _EventSpec(
      {required this.kind,
      required this.title,
      required this.start,
      required this.end,
      required this.anchor});

  final String kind; // 'deadline' | 'exam'
  final String title;
  final DateTime start;
  final DateTime end;

  /// The moment the reminders count back from (deadline / exam start).
  final DateTime anchor;
}

/// Writes deadlines and exam dates into the device calendar (CalendarContract)
/// with three native reminders, and keeps the event IDs so re-syncing updates
/// the same events instead of duplicating them.
/// Settings › "Add my exams to the calendar". Off by default: the per-exam
/// Calendar button still works either way.
abstract final class CalendarAutoSync {
  static const _key = 'calendar.auto';

  static Future<bool> enabled() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_key) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setEnabled(bool on) async => (await SharedPreferences.getInstance()).setBool(_key, on);
}

class CalendarSyncService {
  CalendarSyncService(this._db, {DeviceCalendarPlugin? plugin, tz.Location? location})
      : _plugin = plugin ?? DeviceCalendarPlugin(),
        _location = location ?? tz.getLocation(Env.timeZone);

  final DatabaseService _db;
  final DeviceCalendarPlugin _plugin;
  final tz.Location _location;

  /// 7 days, 2 days and 3 hours before the anchor time.
  static const reminderOffsets = [Duration(days: 7), Duration(days: 2), Duration(hours: 3)];

  /// Deadline events are a 30-minute block ending at the closing time, so the
  /// calendar shows them *before* the deadline rather than after it.
  static const _deadlineBlock = Duration(minutes: 30);
  static const _examLength = Duration(hours: 3);

  Future<bool> ensurePermission() async {
    final has = await _plugin.hasPermissions();
    if (has.isSuccess && (has.data ?? false)) return true;
    final asked = await _plugin.requestPermissions();
    return asked.isSuccess && (asked.data ?? false);
  }

  /// Default writable calendar: the system default if writable, else a Google
  /// account calendar, else any writable one.
  Future<Calendar?> findDefaultWritableCalendar() async {
    final result = await _plugin.retrieveCalendars();
    final writable = [
      for (final c in result.data ?? const <Calendar>[])
        if (c.id != null && c.isReadOnly != true) c,
    ];
    if (writable.isEmpty) return null;
    for (final c in writable) {
      if (c.isDefault ?? false) return c;
    }
    for (final c in writable) {
      if (c.accountType == 'com.google') return c;
    }
    return writable.first;
  }

  Future<CalendarSyncResult> syncExamToCalendar(TrackedApplication app, {DateTime? now}) async {
    final specs = _specsFor(app, now ?? DateTime.now());
    if (specs.isEmpty) return const CalendarSyncFailure(CalendarSyncError.nothingToSync);

    try {
      if (!await ensurePermission()) {
        return const CalendarSyncFailure(CalendarSyncError.permissionDenied);
      }
      final existing = {for (final r in await _db.getEventRefs(app.id)) r.kind: r};
      Calendar? fallback;

      var written = 0;
      for (final spec in specs) {
        final prior = existing[spec.kind];
        String? calendarId = prior?.calendarId;
        if (calendarId == null) {
          fallback ??= await findDefaultWritableCalendar();
          calendarId = fallback?.id;
        }
        if (calendarId == null) {
          return const CalendarSyncFailure(CalendarSyncError.noWritableCalendar);
        }

        var eventId = await _write(calendarId, prior?.eventId, spec, app);
        // The user may have deleted our event by hand: recreate it.
        if (eventId == null && prior != null) {
          eventId = await _write(calendarId, null, spec, app);
        }
        if (eventId == null) {
          return const CalendarSyncFailure(CalendarSyncError.platformError);
        }
        await _db.upsertEventRef(
          CalendarEventRef(appId: app.id, kind: spec.kind, calendarId: calendarId, eventId: eventId),
        );
        written++;
      }
      return CalendarSyncSuccess(written);
    } on Exception catch (e) {
      return CalendarSyncFailure(CalendarSyncError.platformError, e.toString());
    }
  }

  /// Whether calendar access was already given (never asks: safe in the background).
  Future<bool> hasPermission() async {
    final has = await _plugin.hasPermissions();
    return has.isSuccess && (has.data ?? false);
  }

  /// Adds every active exam that isn't in the calendar yet; returns how many
  /// exams got events. Never asks for permission, so it's safe at start-up.
  Future<int> syncAll(Iterable<TrackedApplication> apps, {DateTime? now}) async {
    if (!await hasPermission()) return 0;
    var exams = 0;
    for (final app in apps) {
      if (app.archived || app.calendarSynced) continue;
      if (await syncExamToCalendar(app, now: now) is CalendarSyncSuccess) exams++;
    }
    return exams;
  }

  Future<void> deleteEvent(String calendarId, String eventId) async {
    await _plugin.deleteEvent(calendarId, eventId);
  }

  /// Removes every event this app wrote for [appId].
  Future<void> removeFromCalendar(String appId) async {
    for (final ref in await _db.getEventRefs(appId)) {
      await _plugin.deleteEvent(ref.calendarId, ref.eventId);
      await _db.deleteEventRef(appId, ref.kind);
    }
  }

  // ---------------------------------------------------------------------------

  List<_EventSpec> _specsFor(TrackedApplication app, DateTime now) {
    final specs = <_EventSpec>[];
    final deadline = app.deadline;
    if (deadline != null && deadline.isAfter(now)) {
      specs.add(_EventSpec(
        kind: 'deadline',
        title: '⏳ Apply: ${app.examName} closes',
        start: deadline.subtract(_deadlineBlock),
        end: deadline,
        anchor: deadline,
      ));
    }
    // The date the user entered, else the one the exam watcher found. Watcher dates
    // carry no time: assume a 9 AM reporting time until the admit card says otherwise.
    final announced = app.effectiveExamAt;
    final exam = announced == null || app.examAt != null
        ? announced
        : DateTime(announced.year, announced.month, announced.day, 9);
    if (exam != null && exam.isAfter(now)) {
      specs.add(_EventSpec(
        kind: 'exam',
        title: '📝 Exam: ${app.examName}',
        start: exam,
        end: exam.add(_examLength),
        anchor: exam,
      ));
    }
    return specs;
  }

  /// Reminder minutes are relative to event *start*; shift so they fire
  /// exactly 7d / 2d / 3h before the anchor.
  List<Reminder> _reminders(_EventSpec spec) {
    final lead = spec.anchor.difference(spec.start);
    return [
      for (final offset in reminderOffsets)
        if (offset >= lead) Reminder(minutes: (offset - lead).inMinutes),
    ];
  }

  String _description(TrackedApplication app) {
    final lines = <String>[
      app.postName,
      if (app.organization != null) app.organization!,
      if (app.actionUrl != null) '\nApply / log in: ${app.actionUrl}',
      '\nAdded by JobSummit',
    ];
    return lines.join('\n');
  }

  Future<String?> _write(String calendarId, String? eventId, _EventSpec spec, TrackedApplication app) async {
    final event = Event(
      calendarId,
      eventId: eventId,
      title: spec.title,
      description: _description(app),
      start: tz.TZDateTime.from(spec.start, _location),
      end: tz.TZDateTime.from(spec.end, _location),
      reminders: _reminders(spec),
    );
    final result = await _plugin.createOrUpdateEvent(event);
    if (result == null || !result.isSuccess) return null;
    final id = result.data;
    return (id == null || id.isEmpty) ? null : id;
  }
}
