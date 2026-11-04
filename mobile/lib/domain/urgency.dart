/// Time-blindness helpers: turn timestamps into a band + a human countdown.
library;

import 'agenda.dart';

enum Urgency { safe, warning, urgent, info }

const urgentWindow = Duration(hours: 72);
const warningWindow = Duration(days: 14);

Urgency urgencyFor(DateTime? due, DateTime now) {
  if (due == null) return Urgency.info;
  final left = due.difference(now);
  if (left < urgentWindow) return Urgency.urgent;
  if (left <= warningWindow) return Urgency.warning;
  return Urgency.safe;
}

/// Maps the backend's `UrgencyBand` wire values.
Urgency urgencyFromWire(String? value) => switch (value) {
      'critical' => Urgency.urgent,
      'approaching' => Urgency.warning,
      'safe' => Urgency.safe,
      _ => Urgency.info,
    };

String _plural(int n, String unit) => '$n $unit${n == 1 ? '' : 's'}';

/// "45 mins left", "18 hrs left", "9 days left", "Passed".
String countdownLabel(DateTime due, DateTime now) {
  final left = due.difference(now);
  if (left.isNegative) return 'Passed';
  if (left.inMinutes < 60) return '${_plural(left.inMinutes, 'min')} left';
  if (left.inHours < 48) return '${_plural(left.inHours, 'hr')} left';
  return '${_plural(left.inDays, 'day')} left';
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "Tue 14 Oct, 5:00 PM" in device-local time. No intl dependency needed.
String formatDue(DateTime dt) {
  final l = dt.toLocal();
  final h12 = l.hour % 12 == 0 ? 12 : l.hour % 12;
  final mm = l.minute.toString().padLeft(2, '0');
  final ampm = l.hour < 12 ? 'AM' : 'PM';
  return '${_weekdays[l.weekday - 1]} ${l.day} ${kShortMonths[l.month - 1]}, $h12:$mm $ampm';
}
