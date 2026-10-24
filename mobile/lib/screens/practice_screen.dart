import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/practice.dart';
import '../providers/practice_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';
import '../widgets/common.dart';
import 'practice_test_screen.dart';

/// Timed sectional tests: a mini mock of the four common sections, and each
/// section on its own (quick 10 or full 25), with your best score and weak spot.
class PracticeScreen extends ConsumerWidget {
  const PracticeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(practiceHistoryProvider).valueOrNull ?? const <PracticeResult>[];
    const mock = PracticePlan.mock();
    final mockStats = practiceStats(mock.kind, history);
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        const ScreenHeader(title: 'Practice', subtitle: 'Timed sectional tests'),
        const SizedBox(height: 16),
        AppCard(
          onTap: () => PracticeTestScreen.open(context, mock),
          child: Row(
            children: [
              _SectionIcon(icon: Icons.timer_rounded, color: AppPalette.periwinkle, big: true),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Mini mock', style: text.titleMedium),
                    Text('${mock.count} questions · ${mock.time.inMinutes} min · maths, reasoning, English, GK',
                        style: text.bodySmall),
                    const SizedBox(height: 4),
                    _StatsLine(mockStats),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: () => PracticeTestScreen.open(context, mock), child: const Text('Start')),
            ],
          ),
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
        const SizedBox(height: 4),
        const MutedNote('+1 for a right answer, −¼ for a wrong one. Maths and reasoning are new every time.'),
      ],
    );
  }
}

IconData sectionIcon(PracticeSection s) => switch (s) {
      PracticeSection.quant => Icons.calculate_rounded,
      PracticeSection.reasoning => Icons.psychology_rounded,
      PracticeSection.english => Icons.spellcheck_rounded,
      PracticeSection.gs => Icons.public_rounded,
      PracticeSection.science => Icons.science_rounded,
      PracticeSection.computer => Icons.computer_rounded,
      PracticeSection.banking => Icons.account_balance_rounded,
    };

Color sectionColor(PracticeSection s) => switch (s) {
      PracticeSection.quant || PracticeSection.computer => AppPalette.periwinkle,
      PracticeSection.reasoning => AppPalette.lavender,
      PracticeSection.english || PracticeSection.science => AppPalette.sage,
      PracticeSection.gs || PracticeSection.banking => AppPalette.honey,
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
