/// Your marks from your response sheet: the page the board gives you once the
/// answer key is out (SSC, RRB and others use TCS iON's "digialm" sheets). It
/// marks the key's answer of every question (class "rightAns") and shows your
/// "Chosen Option", so the marks follow from the page alone. Read on the phone;
/// the sheet never leaves it. Pure (no I/O).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'exam_patterns.dart';
import 'practice.dart';

/// One section's count: right, wrong and not answered.
@immutable
class SheetSection {
  const SheetSection(this.name, {this.right = 0, this.wrong = 0, this.skipped = 0, this.plus = 1, this.minus = 0.25});

  final String name;
  final int right;
  final int wrong;
  final int skipped;
  final double plus;
  final double minus;

  int get total => right + wrong + skipped;
  double get marks => right * plus - wrong * minus;
  double get maxMarks => total * plus;

  SheetSection marked(double plus, double minus) =>
      SheetSection(name, right: right, wrong: wrong, skipped: skipped, plus: plus, minus: minus);

  SheetSection _add({int right = 0, int wrong = 0, int skipped = 0}) => SheetSection(name,
      right: this.right + right, wrong: this.wrong + wrong, skipped: this.skipped + skipped, plus: plus, minus: minus);

  Map<String, Object?> toJson() => {'n': name, 'r': right, 'w': wrong, 's': skipped, 'p': plus, 'm': minus};

  static SheetSection? fromJson(Object? j) {
    if (j is! Map<String, dynamic> || j['n'] is! String) return null;
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    return SheetSection(j['n'] as String,
        right: n('r'),
        wrong: n('w'),
        skipped: n('s'),
        plus: (j['p'] as num?)?.toDouble() ?? 1,
        minus: (j['m'] as num?)?.toDouble() ?? 0.25);
  }
}

/// Your score, as saved on the exam.
@immutable
class SheetScore {
  const SheetScore({required this.sections, required this.at});

  final List<SheetSection> sections;
  final DateTime at;

  int get right => sections.fold(0, (s, x) => s + x.right);
  int get wrong => sections.fold(0, (s, x) => s + x.wrong);
  int get skipped => sections.fold(0, (s, x) => s + x.skipped);
  int get total => sections.fold(0, (s, x) => s + x.total);
  double get marks => sections.fold(0.0, (s, x) => s + x.marks);
  double get maxMarks => sections.fold(0.0, (s, x) => s + x.maxMarks);

  /// "142.5 / 200"
  String get label => '${marksText(marks)} / ${marksText(maxMarks)}';

  SheetScore marked(List<(double, double)> marks) => SheetScore(
        sections: [for (final (i, s) in sections.indexed) s.marked(marks[i].$1, marks[i].$2)],
        at: at,
      );

  String encode() => jsonEncode({'at': at.toIso8601String(), 'sections': [for (final s in sections) s.toJson()]});

  static SheetScore? decode(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final sections = [for (final s in j['sections'] as List) if (SheetSection.fromJson(s) case final v?) v];
      final at = DateTime.tryParse(j['at'] as String? ?? '');
      return sections.isEmpty || at == null ? null : SheetScore(sections: sections, at: at);
    } catch (_) {
      return null;
    }
  }
}

final _panel = RegExp(r'''class\s*=\s*["']question-pnl["']''', caseSensitive: false);
final _sectionLabel = RegExp(r'''class\s*=\s*["']section-lbl["'][^>]*>(.*?)</div>''', caseSensitive: false, dotAll: true);
final _option = RegExp(r'''<td[^>]*class\s*=\s*["'](rightAns|wrngAns)["'][^>]*>(.*?)</td>''', caseSensitive: false, dotAll: true);
final _leadingNumber = RegExp(r'^\s*([1-9])\s*[.)]');
final _tags = RegExp(r'<[^>]+>');

String _clean(String html) =>
    html.replaceAll(_tags, ' ').replaceAll('&nbsp;', ' ').replaceAll('&amp;', '&').replaceAll(RegExp(r'\s+'), ' ').trim();

/// The value cell after a "Label :" cell in the sheet's side table.
String? _field(String chunk, String label) {
  final m = RegExp('${RegExp.escape(label)}\\s*:?\\s*</td>\\s*<td[^>]*>(.*?)</td>', caseSensitive: false, dotAll: true)
      .firstMatch(chunk);
  return m == null ? null : _clean(m.group(1)!);
}

/// The sections of a response sheet with what you got in each (marked +1 / −¼
/// until [SheetScore.marked]); null when the page isn't one.
SheetScore? parseResponseSheet(String html, {DateTime? at}) {
  final starts = [for (final m in _panel.allMatches(html)) m.start];
  if (starts.isEmpty) return null;
  final labels = [
    for (final m in _sectionLabel.allMatches(html)) (m.start, _clean(m.group(1)!)),
  ];
  final sections = <String, SheetSection>{};
  for (final (i, start) in starts.indexed) {
    final chunk = html.substring(start, i + 1 < starts.length ? starts[i + 1] : html.length);
    final options = _option.allMatches(chunk).toList();
    if (options.isEmpty) continue; // a typed-answer question: no options to mark
    int? key;
    for (final (j, o) in options.indexed) {
      if (o.group(1)!.toLowerCase() == 'rightans') {
        key = int.tryParse(_leadingNumber.firstMatch(_clean(o.group(2)!))?.group(1) ?? '') ?? j + 1;
        break;
      }
    }
    if (key == null) continue; // dropped from the key
    final status = (_field(chunk, 'Status') ?? '').toLowerCase();
    var chosenText = _field(chunk, 'Chosen Option') ?? '';
    // Some sheets give the chosen option's id: find which option has it.
    if (RegExp(r'^\d{5,}$').hasMatch(chosenText)) {
      for (var n = 1; n <= options.length; n++) {
        if (_field(chunk, 'Option $n ID') == chosenText) chosenText = '$n';
      }
    }
    final chosen = status.contains('not answered') || status.contains('not attempted') ? null : int.tryParse(chosenText);
    final name = labels.lastWhere((l) => l.$1 < start, orElse: () => (0, 'Questions')).$2;
    final s = sections[name] ?? SheetSection(name);
    sections[name] = chosen == null
        ? s._add(skipped: 1)
        : (chosen == key ? s._add(right: 1) : s._add(wrong: 1));
  }
  if (sections.isEmpty) return null;
  return SheetScore(sections: sections.values.toList(), at: at ?? DateTime.now());
}

/// Marks for each section: the exam's pattern when its sections line up with
/// the sheet's (same count, same number of questions), else [fallback] for all.
List<(double, double)> sheetMarks(SheetScore sheet, ExamPattern? pattern, (double, double) fallback) {
  final parts = pattern?.parts;
  if (parts != null &&
      parts.length == sheet.sections.length &&
      [for (final (i, p) in parts.indexed) p.count == sheet.sections[i].total].every((x) => x)) {
    return [for (final p in parts) (p.plus, p.minus)];
  }
  final first = parts?.first;
  final same = parts != null && parts.every((p) => p.plus == first!.plus && p.minus == first.minus);
  return List.filled(sheet.sections.length, same ? (first!.plus, first.minus) : fallback);
}

/// Common marking schemes to pick from.
const kSheetSchemes = [
  ('SSC', 2.0, 0.5),
  ('Banks', 1.0, 0.25),
  ('Railways', 1.0, 1 / 3),
  ('No minus', 1.0, 0.0),
];
