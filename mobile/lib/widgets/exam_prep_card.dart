import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../domain/exam_patterns.dart';
import '../domain/practice.dart';
import '../domain/response_sheet.dart';
import '../models/tracked_application.dart';
import '../providers/limits_providers.dart';
import '../providers/practice_providers.dart';
import '../providers/providers.dart';
import '../screens/practice_test_screen.dart';
import '../services/fx.dart';
import '../theme/app_theme.dart';
import '../utils/system_actions.dart';
import 'app_card.dart';

/// On an exam's page: a mock in its pattern, your marks from your response
/// sheet, and your age / attempt limits. Shows only what applies.
class ExamPrepCard extends ConsumerWidget {
  const ExamPrepCard({super.key, required this.app, required this.now});

  final TrackedApplication app;
  final DateTime now;

  /// The response sheet comes with the answer key, after the exam.
  static bool sheetTime(TrackedApplication app, DateTime now) =>
      app.examOver(now) || app.displayStatus.index >= TrackerStatus.answerKeyLive.index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pattern = patternFor(app);
    final exam = app.catalogExam;
    final limits = exam == null ? null : ref.watch(examLimitsProvider(exam));
    final used = exam == null ? null : ref.watch(attemptsUsedProvider).valueOrNull?[exam.id];
    final score = app.myScore;
    final history = ref.watch(practiceHistoryProvider).valueOrNull ?? const <PracticeResult>[];
    final rows = <Widget>[
      if (pattern != null && !app.examOver(now))
        _Row(
          icon: Icons.assignment_rounded,
          color: AppPalette.sage,
          title: '${pattern.name} mock',
          subtitle: [
            '${pattern.count} questions · ${pattern.minutes} min',
            if (practiceStats(pattern.plan.kind, history).best case final best?) 'best ${(best * 100).round()}%',
          ].join(' · '),
          action: TextButton(onPressed: () => PracticeTestScreen.open(context, pattern.plan), child: const Text('Practise')),
        ),
      if (score != null)
        _Row(
          icon: Icons.fact_check_rounded,
          color: AppPalette.periwinkle,
          title: 'Your score: ${score.label}',
          subtitle: [for (final s in score.sections) '${_short(s.name)} ${marksText(s.marks)}'].join(' · '),
          action: TextButton(onPressed: () => showScoreSheet(context, app), child: const Text('Redo')),
        )
      else if (sheetTime(app, now))
        _Row(
          icon: Icons.fact_check_rounded,
          color: AppPalette.periwinkle,
          title: 'Your score',
          subtitle: 'From your response sheet, once the answer key is out',
          action: TextButton(onPressed: () => showScoreSheet(context, app), child: const Text('Score it')),
        ),
      if (limits != null)
        _Row(
          icon: Icons.hourglass_bottom_rounded,
          color: limits.lastYear == null || limits.lastYear! <= now.year + 1 ? AppPalette.terracotta : AppPalette.honey,
          title: 'Age: ${limits.summary(now)}',
          subtitle: limits.fromNotice ? 'From the latest notice' : 'The usual rule; each notice decides',
        ),
      if (limits?.attempts case final allowed?)
        _Row(
          icon: Icons.repeat_rounded,
          color: AppPalette.lavender,
          title: used == null ? 'Attempts: $allowed allowed' : 'Attempts: ${allowed - used < 0 ? 0 : allowed - used} of $allowed left',
          subtitle: used == null ? 'Set how many you’ve used' : '$used used so far',
          action: TextButton(
            onPressed: () async {
              final n = await _askAttempts(context, used ?? 0, allowed);
              if (n != null) await ref.read(attemptsUsedProvider.notifier).set(exam!.id, n);
            },
            child: Text(used == null ? 'Set' : 'Change'),
          ),
        ),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (i, r) in rows.indexed) ...[
              if (i > 0) Divider(height: 1, color: AppPalette.outline.withValues(alpha: 0.3)),
              r,
            ],
          ],
        ),
      ),
    );
  }
}

/// "General Intelligence and Reasoning" -> "Reasoning".
String _short(String name) {
  final n = name.toLowerCase();
  if (n.contains('reason') || n.contains('intelligence')) return 'Reasoning';
  if (n.contains('english')) return 'English';
  if (n.contains('quant') || n.contains('math') || n.contains('numer') || n.contains('arith')) return 'Maths';
  if (n.contains('awareness') || n.contains('general knowledge') || n.contains('gk')) return 'GK';
  if (n.contains('science')) return 'Science';
  if (n.contains('computer')) return 'Computer';
  return name.length > 18 ? '${name.substring(0, 17)}…' : name;
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.color, required this.title, required this.subtitle, this.action});

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleSmall),
                if (subtitle.isNotEmpty) Text(subtitle, style: text.bodySmall),
              ],
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

Future<int?> _askAttempts(BuildContext context, int used, int allowed) => showDialog<int>(
      context: context,
      builder: (c) {
        var n = used;
        return StatefulBuilder(
          builder: (c, set) => AlertDialog(
            backgroundColor: AppPalette.surface,
            title: const Text('Attempts used'),
            content: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(onPressed: n == 0 ? null : () => set(() => n--), icon: const Icon(Icons.remove_rounded)),
                Text('$n of $allowed', style: Theme.of(c).textTheme.titleLarge),
                IconButton(onPressed: n >= allowed ? null : () => set(() => n++), icon: const Icon(Icons.add_rounded)),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(c, n), child: const Text('Save')),
            ],
          ),
        );
      },
    );

/// Paste your response sheet's link (or open the saved page): marks per section
/// with the exam's marking, saved on the exam.
Future<void> showScoreSheet(BuildContext context, TrackedApplication app) => showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _ScoreSheet(app: app),
    );

class _ScoreSheet extends ConsumerStatefulWidget {
  const _ScoreSheet({required this.app});

  final TrackedApplication app;

  @override
  ConsumerState<_ScoreSheet> createState() => _ScoreSheetState();
}

class _ScoreSheetState extends ConsumerState<_ScoreSheet> {
  final _link = TextEditingController();
  SheetScore? _sheet;
  String? _error;
  bool _loading = false;

  /// -1: the exam's own marking; else an index into [kSheetSchemes].
  int _scheme = -1;

  ExamPattern? get _pattern => patternFor(widget.app);

  @override
  void initState() {
    super.initState();
    if (_pattern == null) _scheme = _guessScheme();
  }

  int _guessScheme() {
    final org = '${widget.app.examName} ${widget.app.organization ?? ''}'.toLowerCase();
    if (org.contains('rrb') || org.contains('railway') || org.contains('rpf')) return 2;
    if (org.contains('ibps') || org.contains('sbi') || org.contains('rbi') || org.contains('bank')) return 1;
    return 0;
  }

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _read(Future<String?> Function() load) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final html = await load();
      if (html == null) return;
      final sheet = parseResponseSheet(html);
      setState(() {
        _sheet = sheet;
        _error = sheet == null ? 'This doesn’t look like a response sheet. Open the sheet’s own page and try its link.' : null;
      });
    } catch (_) {
      setState(() => _error = 'Couldn’t open it. Check the link and your internet.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<String?> _fromLink() async {
    final url = Uri.tryParse(_link.text.trim());
    if (url == null || !url.hasScheme) throw const FormatException();
    final res = await http.get(url).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw http.ClientException('HTTP ${res.statusCode}');
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  }

  Future<String?> _fromFile() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['html', 'htm'], withData: true);
    final f = picked?.files.single;
    if (f == null) return null;
    final bytes = f.bytes ?? (f.path == null ? null : await File(f.path!).readAsBytes());
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  SheetScore? get _marked {
    final s = _sheet;
    if (s == null) return null;
    final fallback = _scheme < 0 ? (1.0, 0.25) : (kSheetSchemes[_scheme].$2, kSheetSchemes[_scheme].$3);
    return s.marked(_scheme < 0 ? sheetMarks(s, _pattern, fallback) : List.filled(s.sections.length, fallback));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final marked = _marked;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Score your response sheet', style: text.titleLarge),
            const SizedBox(height: 4),
            Text('Read on this phone only. Your marks are saved on ${widget.app.postName}.', style: text.bodySmall),
            const SizedBox(height: 14),
            TextField(
              controller: _link,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Response sheet link', hintText: 'https://ssc.digialm.com/…'),
              onSubmitted: (_) => _read(_fromLink),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton(onPressed: _loading ? null : () => _read(_fromLink), child: const Text('Read link')),
                const SizedBox(width: 10),
                OutlinedButton(onPressed: _loading ? null : () => _read(_fromFile), child: const Text('Open saved page')),
                if (_loading) ...[
                  const SizedBox(width: 12),
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: text.bodyMedium?.copyWith(color: AppPalette.terracotta)),
            ],
            if (marked != null) ...[
              const SizedBox(height: 18),
              Center(
                child: Text(marked.label,
                    style: text.displaySmall?.copyWith(fontWeight: FontWeight.w900, color: AppPalette.periwinkle)),
              ),
              Center(
                child: Text('${marked.right} right · ${marked.wrong} wrong · ${marked.skipped} not answered',
                    style: text.bodySmall),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (_pattern != null)
                    ChoiceChip(label: const Text('This exam’s'), selected: _scheme < 0, onSelected: (_) => setState(() => _scheme = -1)),
                  for (final (i, (name, plus, minus)) in kSheetSchemes.indexed)
                    ChoiceChip(
                      label: Text('$name ${markingText(plus, minus)}'),
                      selected: _scheme == i,
                      onSelected: (_) => setState(() => _scheme = i),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              for (final s in marked.sections)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(child: Text(s.name, style: text.bodyMedium)),
                      Text('${s.right}/${s.total} · ${marksText(s.marks)}', style: text.labelLarge),
                    ],
                  ),
                ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    await ref.read(trackedAppsProvider.notifier).setScore(widget.app.id, marked);
                    Fx.done();
                    if (context.mounted) {
                      Navigator.pop(context);
                      showCalmSnack(context, 'Saved: ${marked.label}');
                    }
                  },
                  child: const Text('Save my score'),
                ),
              ),
            ],
            if (widget.app.myScore != null && marked == null) ...[
              const SizedBox(height: 14),
              TextButton(
                onPressed: () async {
                  await ref.read(trackedAppsProvider.notifier).setScore(widget.app.id, null);
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('Remove my saved score'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
