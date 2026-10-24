import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/agenda.dart';
import '../providers/agenda_providers.dart';
import '../providers/jobs_providers.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';
import '../widgets/common.dart';
import '../widgets/job_card.dart';
import '../widgets/pill_toggle.dart';
import 'exam_journey_screen.dart';

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];
const _short = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// What's coming, by date: Week (one short list per day) or Month (a calendar;
/// tap a day to see what's on it).
class AgendaScreen extends ConsumerStatefulWidget {
  const AgendaScreen({super.key});

  @override
  ConsumerState<AgendaScreen> createState() => _AgendaScreenState();
}

class _AgendaScreenState extends ConsumerState<AgendaScreen> {
  DateTime? _month; // first day of the month shown
  DateTime? _selected;
  bool _showLater = false;

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(nowProvider);
    final today = agendaDay(now);
    final items = ref.watch(agendaProvider);
    final view = ref.watch(agendaViewProvider);
    final month = _month ?? DateTime(now.year, now.month);
    final selected = _selected ?? today;
    final weekEnd = today.add(const Duration(days: 6));
    final subtitle = view == AgendaView.week
        ? 'This week · ${today.day} ${_short[today.month - 1]} – ${weekEnd.day} ${_short[weekEnd.month - 1]}'
        : '${_monthNames[month.month - 1]} ${month.year}';

    return RefreshIndicator(
      onRefresh: () => Future.wait<Object?>([
        ref.read(feedProvider.notifier).refresh(),
        ref.read(trackedAppsProvider.notifier).checkForUpdates(force: true),
      ]),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          ScreenHeader(title: 'Agenda', subtitle: subtitle),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: PillToggle<AgendaView>(
              options: const [(AgendaView.week, 'Week'), (AgendaView.month, 'Month')],
              selected: view,
              onChanged: ref.read(agendaViewProvider.notifier).show,
            ),
          ),
          const SizedBox(height: 16),
          if (view == AgendaView.week)
            ..._week(context, items, now)
          else
            ..._monthView(context, items, now, month, selected),
        ],
      ),
    );
  }

  List<Widget> _week(BuildContext context, List<AgendaItem> items, DateTime now) {
    if (items.isEmpty) {
      return const [MutedNote('Nothing dated yet. Last days of your jobs and your exam dates show up here.')];
    }
    final buckets = weekBuckets(items, now);
    return [
      for (final b in buckets) ...[
        _BucketHeader(
          label: b.day == null ? 'Later · ${b.items.length}' : b.label,
          color: b.day == null ? AppPalette.textMuted : _colorFor(b.items.first, now),
          count: b.day == null ? null : b.items.length,
          trailing: b.day == null
              ? TextButton(
                  onPressed: () => setState(() => _showLater = !_showLater),
                  child: Text(_showLater ? 'Hide' : 'Show'),
                )
              : null,
        ),
        if (b.day != null || _showLater) _ItemsCard(items: b.items, now: now, showDate: b.day == null),
        const SizedBox(height: 14),
      ],
    ];
  }

  List<Widget> _monthView(
      BuildContext context, List<AgendaItem> items, DateTime now, DateTime month, DateTime selected) {
    final text = Theme.of(context).textTheme;
    final onDay = [for (final i in items) if (i.day == selected) i];
    return [
      AppCard(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 12),
        child: _MonthGrid(
          month: month,
          today: agendaDay(now),
          selected: selected,
          items: items,
          now: now,
          onPrevious: () => setState(() => _month = DateTime(month.year, month.month - 1)),
          onNext: () => setState(() => _month = DateTime(month.year, month.month + 1)),
          onSelect: (d) => setState(() => _selected = d),
        ),
      ),
      const SizedBox(height: 16),
      Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 8),
        child: Text('${_weekday(selected)} ${selected.day} ${_short[selected.month - 1]}'.toUpperCase(),
            style: text.labelMedium?.copyWith(color: AppPalette.textMuted, fontWeight: FontWeight.w900)),
      ),
      if (onDay.isEmpty) const MutedNote('Nothing on this day.') else _ItemsCard(items: onDay, now: now),
    ];
  }
}

String _weekday(DateTime d) => const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1];

/// The colour of a row's pill and of its day's dot.
Color _colorFor(AgendaItem i, DateTime now) => switch (i.kind) {
      AgendaKind.deadline => i.at.difference(now).inHours < 72
          ? AppPalette.terracotta
          : (i.at.difference(now).inDays < 14 ? AppPalette.honey : AppPalette.sage),
      AgendaKind.fee || AgendaKind.correction || AgendaKind.objection => AppPalette.honey,
      AgendaKind.admitCard || AgendaKind.result => AppPalette.periwinkle,
      AgendaKind.exam => AppPalette.sage,
      AgendaKind.answerKey => AppPalette.lavender,
    };

class _BucketHeader extends StatelessWidget {
  const _BucketHeader({required this.label, required this.color, this.count, this.trailing});

  final String label;
  final Color color;
  final int? count;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 2),
      child: Row(
        children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Flexible(child: Text(label, style: text.titleSmall?.copyWith(fontWeight: FontWeight.w900))),
          if (count != null && count! > 1) ...[
            const SizedBox(width: 6),
            Text('$count', style: text.labelMedium?.copyWith(color: AppPalette.textMuted)),
          ],
          if (trailing != null) ...[const Spacer(), trailing!],
        ],
      ),
    );
  }
}

/// A card with one row per dated thing.
class _ItemsCard extends StatelessWidget {
  const _ItemsCard({required this.items, required this.now, this.showDate = false});

  final List<AgendaItem> items;
  final DateTime now;
  final bool showDate;

  @override
  Widget build(BuildContext context) => AppCard(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            for (final (i, item) in items.indexed) ...[
              if (i > 0) Divider(height: 1, color: AppPalette.surfaceVariant),
              _AgendaRow(item: item, now: now, showDate: showDate),
            ],
          ],
        ),
      );
}

class _AgendaRow extends ConsumerWidget {
  const _AgendaRow({required this.item, required this.now, this.showDate = false});

  final AgendaItem item;
  final DateTime now;
  final bool showDate;

  void _open(BuildContext context, WidgetRef ref) {
    final app = item.app;
    if (app != null) {
      ExamJourneyScreen.open(context, app);
      return;
    }
    final job = item.job;
    final ranked = job == null
        ? null
        : ref.read(rankedJobsProvider).where((r) => r.item.jobPostId == job.jobPostId).firstOrNull;
    if (ranked == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: SwipeableJob(ranked: ranked, screenContext: context, showSwipeHint: false),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final color = _colorFor(item, now);
    final sub = showDate ? '${item.at.day} ${_short[item.at.month - 1]} · ${item.subtitle}' : item.subtitle;
    final clash = item.kind == AgendaKind.exam && item.app != null
        ? ref.watch(examClashesProvider)[item.app!.id]?.firstOrNull
        : null;
    return InkWell(
      onTap: () => _open(context, ref),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title, style: text.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(sub, style: text.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (clash != null)
                    Text('⚠️ ${clash.label}',
                        style: text.labelSmall?.copyWith(
                            color: clash.sure ? AppPalette.terracotta : AppPalette.honey, fontWeight: FontWeight.w800),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: AppPalette.current.isLight ? 0.13 : 0.18),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(item.tag,
                  maxLines: 1,
                  softWrap: false,
                  style: text.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w900)),
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.today,
    required this.selected,
    required this.items,
    required this.now,
    required this.onPrevious,
    required this.onNext,
    required this.onSelect,
  });

  final DateTime month;
  final DateTime today;
  final DateTime selected;
  final List<AgendaItem> items;
  final DateTime now;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final byDay = <DateTime, List<AgendaItem>>{};
    for (final i in items) {
      byDay.putIfAbsent(i.day, () => []).add(i);
    }
    final first = DateTime(month.year, month.month);
    final days = DateTime(month.year, month.month + 1, 0).day;
    final lead = first.weekday - 1; // Monday first
    final cells = <DateTime?>[
      for (var i = 0; i < lead; i++) null,
      for (var d = 1; d <= days; d++) DateTime(month.year, month.month, d),
    ];
    while (cells.length % 7 != 0) {
      cells.add(null);
    }

    return Column(
      children: [
        Row(
          children: [
            IconButton(tooltip: 'Previous month', onPressed: onPrevious, icon: const Icon(Icons.chevron_left_rounded)),
            Expanded(
              child: Text('${_monthNames[month.month - 1]} ${month.year}',
                  textAlign: TextAlign.center, style: text.titleSmall?.copyWith(fontWeight: FontWeight.w900)),
            ),
            IconButton(tooltip: 'Next month', onPressed: onNext, icon: const Icon(Icons.chevron_right_rounded)),
          ],
        ),
        Row(
          children: [
            for (final d in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
              Expanded(
                child: Center(child: Text(d, style: text.labelSmall?.copyWith(fontWeight: FontWeight.w800))),
              ),
          ],
        ),
        const SizedBox(height: 4),
        for (var w = 0; w < cells.length ~/ 7; w++)
          Row(
            children: [
              for (final day in cells.sublist(w * 7, w * 7 + 7))
                Expanded(
                  child: day == null
                      ? const SizedBox(height: 44)
                      : _DayCell(
                          day: day,
                          isToday: day == today,
                          isSelected: day == selected,
                          dots: [for (final i in (byDay[day] ?? const <AgendaItem>[]).take(3)) _colorFor(i, now)],
                          onTap: () => onSelect(day),
                        ),
                ),
            ],
          ),
      ],
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.isToday,
    required this.isSelected,
    required this.dots,
    required this.onTap,
  });

  final DateTime day;
  final bool isToday;
  final bool isSelected;
  final List<Color> dots;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: isSelected,
      label: '${day.day} ${_short[day.month - 1]}${dots.isEmpty ? '' : ', ${dots.length} things'}',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          height: 44,
          margin: const EdgeInsets.all(1),
          decoration: BoxDecoration(
            color: isToday ? AppPalette.periwinkle : null,
            borderRadius: BorderRadius.circular(12),
            border: isSelected && !isToday ? Border.all(color: AppPalette.periwinkle, width: 2) : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('${day.day}',
                  style: text.labelLarge?.copyWith(
                      fontSize: 14, color: isToday ? AppPalette.onAccent : AppPalette.textPrimary)),
              const SizedBox(height: 3),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final c in dots)
                    Container(
                      width: 5,
                      height: 5,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(color: isToday ? AppPalette.onAccent : c, shape: BoxShape.circle),
                    ),
                  if (dots.isEmpty) const SizedBox(height: 5),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
