import 'package:exam_tracker/domain/agenda.dart';
import 'package:exam_tracker/domain/widget_summary.dart';
import 'package:flutter_test/flutter_test.dart';

AgendaItem item(AgendaKind kind, DateTime at, String title) =>
    AgendaItem(at: at, kind: kind, title: title, subtitle: '');

void main() {
  final now = DateTime(2026, 10, 24, 9); // a Saturday

  test('the next last day, the next exam and this week’s count, with dates written out', () {
    final s = widgetSummary([
      item(AgendaKind.deadline, DateTime(2026, 10, 24, 23, 59), 'SSC GD Constable'),
      item(AgendaKind.deadline, DateTime(2026, 10, 28, 18), 'IBPS Clerk'),
      item(AgendaKind.exam, DateTime(2026, 11, 12, 9), 'RRB NTPC Graduate'),
      item(AgendaKind.deadline, DateTime(2026, 11, 20, 18), 'UPSC CSE'),
    ], now);
    expect(s.deadline, 'SSC GD Constable · closes today');
    expect(s.exam, 'RRB NTPC Graduate · Thu 12 Nov');
    expect(s.week, '2 jobs close this week');
  });

  test('nothing coming: empty lines, and the Daily 10 waiting', () {
    final s = widgetSummary(const [], now);
    expect([s.deadline, s.exam, s.week].every((v) => v.isEmpty), isTrue);
    expect(s.daily, 'Daily 10 is ready');
  });
}
