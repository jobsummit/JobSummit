import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/exam_patterns.dart';
import '../domain/mistakes.dart';
import '../domain/practice.dart';
import '../models/tracked_application.dart';
import '../providers/practice_providers.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';
import '../widgets/common.dart';
import 'practice_test_screen.dart';

/// Timed tests: today's Daily 10, the mistakes due again, a full mock in the
/// pattern of each exam you track, the mini mock, and each section on its own
/// (quick 10 or full 25), with your best score and weak spot.
class PracticeScreen extends ConsumerWidget {
  const PracticeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(practiceHistoryProvider).valueOrNull ?? const <PracticeResult>[];
    final mistakes = ref.watch(mistakesProvider).valueOrNull ?? const <MistakeCard>[];
    final now = ref.watch(nowProvider);
    final mock = PracticePlan.mock();
    final daily = PracticePlan.daily(now);
    final done = dailyDoneOn(now, history);
    final streak = dailyStreak(now, history);
    final due = dueMistakes(mistakes, now);
    final yours = <(ExamPattern, TrackedApplication)>[];
    for (final app in ref.watch(activeAppsProvider)) {
      final p = patternFor(app);
      if (p != null && !yours.any((y) => y.$1.id == p.id)) yours.add((p, app));
    }
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        const ScreenHeader(title: 'Practice', subtitle: 'Timed tests, as in the real exams'),
        const SizedBox(height: 16),
        _BigCard(
          icon: Icons.wb_sunny_rounded,
          color: AppPalette.honey,
          title: 'Daily 10',
          subtitle: done == null
              ? '${daily.time.inMinutes} min · the same 10 for everyone today'
              : 'Done: ${done.right}/${done.total} in ${(done.seconds / 60).ceil()} min',
          footer: streak > 0 ? '$streak day${streak == 1 ? '' : 's'} in a row' : null,
          action: done == null
              ? FilledButton(onPressed: () => PracticeTestScreen.open(context, daily), child: const Text('Start'))
              : IconButton.filledTonal(
                  tooltip: 'Share',
                  onPressed: () => SharePlus.instance.share(ShareParams(text: dailyShareText(done, now))),
                  icon: const Icon(Icons.share_rounded),
                ),
          onTap: () => PracticeTestScreen.open(context, daily),
        ),
        if (mistakes.isNotEmpty) ...[
          const SizedBox(height: 10),
          _BigCard(
            icon: Icons.replay_rounded,
            color: AppPalette.terracotta,
            title: 'Mistakes to redo',
            subtitle: due.isEmpty
                ? '${mistakes.length} in your notebook · next ${_when(mistakes, now)}'
                : '${due.length} due today · back after 1, 3 and 7 days',
            action: due.isEmpty
                ? null
                : FilledButton(
                    onPressed: () => PracticeTestScreen.open(context, PracticePlan.review(due.length)),
                    child: const Text('Redo'),
                  ),
            onTap: due.isEmpty ? null : () => PracticeTestScreen.open(context, PracticePlan.review(due.length)),
          ),
        ],
        if (yours.isNotEmpty) ...[
          const SizedBox(height: 20),
          const SectionTitle('For your exams'),
          const SizedBox(height: 10),
          for (final (pattern, app) in yours) ...[
            _PatternCard(pattern: pattern, app: app, history: history, now: now),
            const SizedBox(height: 10),
          ],
        ],
        const SizedBox(height: 10),
        _BigCard(
          icon: Icons.timer_rounded,
          color: AppPalette.periwinkle,
          title: 'Mini mock',
          subtitle: '${mock.count} questions · ${mock.time.inMinutes} min · maths, reasoning, English, GK',
          stats: practiceStats(mock.kind, history),
          action: FilledButton(onPressed: () => PracticeTestScreen.open(context, mock), child: const Text('Start')),
          onTap: () => PracticeTestScreen.open(context, mock),
        ),
        const SizedBox(height: 20),
        const SectionTitle('Sections'),
        const SizedBox(height: 10),
        for (final s in PracticeSection.values) ...[
          AppCard(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            onTap: () => showPracticeStart(context, s),
            child: Row(
              children: [
                _SectionIcon(icon: sectionIcon(s), color: sectionColor(s)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.title, style: text.titleSmall),
                      Text(s.usedIn, style: text.bodySmall),
                      const SizedBox(height: 2),
                      _StatsLine(practiceStats(s.name, history)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: AppPalette.textMuted),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _showAllPatterns(context),
            icon: const Icon(Icons.list_alt_rounded, size: 18),
            label: const Text('Mocks for other exams'),
          ),
        ),
        const MutedNote('+1 for a right answer, −¼ for a wrong one; exam mocks use their exam’s marks.'),
      ],
    );
  }
}

String _when(List<MistakeCard> cards, DateTime now) {
  final next = cards.map((c) => c.due).reduce((a, b) => a.isBefore(b) ? a : b);
  final days = DateTime(next.year, next.month, next.day).difference(DateTime(now.year, now.month, now.day)).inDays;
  return days <= 1 ? 'tomorrow' : 'in $days days';
}

class _BigCard extends StatelessWidget {
  const _BigCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    this.footer,
    this.stats,
    this.action,
    this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String? footer;
  final PracticeStats? stats;
  final Widget? action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AppCard(
      onTap: onTap,
      child: Row(
        children: [
          _SectionIcon(icon: icon, color: color, big: true),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleMedium),
                Text(subtitle, style: text.bodySmall),
                if (stats != null) ...[const SizedBox(height: 4), _StatsLine(stats!)],
                if (footer != null) ...[
                  const SizedBox(height: 4),
                  Text(footer!, style: text.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w800)),
                ],
              ],
            ),
          ),
          if (action != null) ...[const SizedBox(width: 8), action!],
        ],
      ),
    );
  }
}

class _PatternCard extends StatelessWidget {
  const _PatternCard({required this.pattern, required this.app, required this.history, required this.now});

  final ExamPattern pattern;
  final TrackedApplication? app;
  final List<PracticeResult> history;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final at = app?.effectiveExamAt;
    final days = at == null ? null : DateTime(at.year, at.month, at.day).difference(DateTime(now.year, now.month, now.day)).inDays;
    return _BigCard(
      icon: Icons.assignment_rounded,
      color: AppPalette.sage,
      title: '${pattern.name} mock',
      subtitle: [
        '${pattern.count} questions · ${pattern.minutes} min',
        if (pattern.marking != null) pattern.marking!,
        if (days != null && days >= 0) days == 0 ? 'exam today' : 'exam in $days day${days == 1 ? '' : 's'}',
      ].join(' · '),
      stats: practiceStats(pattern.plan.kind, history),
      action: FilledButton(onPressed: () => PracticeTestScreen.open(context, pattern.plan), child: const Text('Start')),
      onTap: () => PracticeTestScreen.open(context, pattern.plan),
    );
  }
}

Future<void> _showAllPatterns(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (c, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          children: [
            Text('Mocks in each exam’s pattern', style: Theme.of(c).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('Sections, questions, time and marks as in the exam.', style: Theme.of(c).textTheme.bodySmall),
            const SizedBox(height: 10),
            for (final p in kExamPatterns)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(p.name),
                subtitle: Text([
                  '${p.count} questions · ${p.minutes} min',
                  p.parts.map((x) => x.section.short).toSet().join(', '),
                ].join(' · ')),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  Navigator.pop(c);
                  PracticeTestScreen.open(context, p.plan);
                },
              ),
          ],
        ),
      ),
    );

IconData sectionIcon(PracticeSection s) => switch (s) {
      PracticeSection.quant => Icons.calculate_rounded,
      PracticeSection.reasoning => Icons.psychology_rounded,
      PracticeSection.english => Icons.spellcheck_rounded,
      PracticeSection.gs => Icons.public_rounded,
      PracticeSection.current => Icons.newspaper_rounded,
      PracticeSection.science => Icons.science_rounded,
      PracticeSection.computer => Icons.computer_rounded,
      PracticeSection.banking => Icons.account_balance_rounded,
    };

Color sectionColor(PracticeSection s) => switch (s) {
      PracticeSection.quant || PracticeSection.computer => AppPalette.periwinkle,
      PracticeSection.reasoning => AppPalette.lavender,
      PracticeSection.english || PracticeSection.science => AppPalette.sage,
      PracticeSection.gs || PracticeSection.banking => AppPalette.honey,
      PracticeSection.current => AppPalette.terracotta,
    };

class _SectionIcon extends StatelessWidget {
  const _SectionIcon({required this.icon, required this.color, this.big = false});

  final IconData icon;
  final Color color;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final c = color;
    final size = big ? 48.0 : 40.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.withValues(alpha: AppPalette.current.isLight ? 0.14 : 0.2),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(icon, color: c, size: big ? 26 : 22),
    );
  }
}

class _StatsLine extends StatelessWidget {
  const _StatsLine(this.stats);

  final PracticeStats stats;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    if (stats.tests == 0) return Text('Not tried yet', style: style?.copyWith(color: AppPalette.textMuted));
    return Text(
      [
        'Best ${(stats.best! * 100).round()}%',
        '${stats.tests} test${stats.tests == 1 ? '' : 's'}',
        if (stats.weakTopic != null) 'work on: ${stats.weakTopic}',
      ].join(' · '),
      style: style?.copyWith(fontWeight: FontWeight.w800),
    );
  }
}

/// Quick or full, and whether to see each answer straight away; then the test.
Future<void> showPracticeStart(BuildContext context, PracticeSection section) async {
  final choice = await showModalBottomSheet<(PracticePlan, bool)>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => _StartSheet(section: section),
  );
  if (choice != null && context.mounted) await PracticeTestScreen.open(context, choice.$1, instant: choice.$2);
}

class _StartSheet extends StatefulWidget {
  const _StartSheet({required this.section});

  final PracticeSection section;

  @override
  State<_StartSheet> createState() => _StartSheetState();
}

class _StartSheetState extends State<_StartSheet> {
  int _count = 10;
  bool _instant = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.section;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.title, style: text.titleLarge),
          Text(s.usedIn, style: text.bodySmall),
          const SizedBox(height: 16),
          Row(
            children: [
              for (final (n, label) in const [(10, 'Quick'), (25, 'Full')]) ...[
                Expanded(
                  child: _Choice(
                    title: label,
                    subtitle: '$n questions · ${PracticePlan.section(s, n).time.inMinutes} min',
                    selected: _count == n,
                    onTap: () => setState(() => _count = n),
                  ),
                ),
                if (n == 10) const SizedBox(width: 10),
              ],
            ],
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show each answer right away'),
            value: _instant,
            onChanged: (v) => setState(() => _instant = v),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.pop(context, (PracticePlan.section(s, _count), _instant)),
              child: const Text('Start'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({required this.title, required this.subtitle, required this.selected, required this.onTap});

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: selected ? AppPalette.periwinkle.withValues(alpha: 0.18) : AppPalette.surfaceVariant,
      borderRadius: BorderRadius.circular(AppRadii.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.control),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.control),
            border: Border.all(color: selected ? AppPalette.periwinkle : Colors.transparent, width: 2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: text.titleSmall),
              Text(subtitle, style: text.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
