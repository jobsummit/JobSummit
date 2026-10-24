import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/agenda.dart';
import '../domain/next_step.dart';
import '../domain/urgency.dart';
import '../models/tracked_application.dart';
import '../providers/account_providers.dart';
import '../providers/agenda_providers.dart';
import '../providers/backup_providers.dart';
import '../providers/jobs_providers.dart';
import '../providers/providers.dart';
import '../providers/today_providers.dart';
import '../providers/xp_providers.dart';
import '../theme/app_theme.dart';
import '../utils/system_actions.dart';
import '../widgets/app_card.dart';
import '../widgets/app_icons.dart';
import '../widgets/celebrate.dart';
import '../widgets/common.dart';
import '../widgets/hero_card.dart';
import '../widgets/job_card.dart';
import '../widgets/motion.dart';
import '../widgets/pill_toggle.dart';
import 'exam_journey_screen.dart';
import 'home_shell.dart';

/// Today: Overview (tiles: the next deadline, your level and streak, what's waiting,
/// this week) or Focus (one big next step and a short queue). It remembers which.
class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  static String greeting(DateTime now) => now.hour < 5
      ? 'Good evening'
      : now.hour < 12
          ? 'Good morning'
          : now.hour < 17
              ? 'Good afternoon'
              : 'Good evening';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(nowProvider);
    final snapshot = ref.watch(feedProvider).dataOrNull;
    final account = ref.watch(accountStatusProvider);
    final view = ref.watch(todayViewProvider);
    final subtitle = snapshot != null && snapshot.fromCache
        ? 'Offline · job list from ${formatDue(snapshot.fetchedAt)}'
        : formatDue(now).split(',').first;

    return RefreshIndicator(
      onRefresh: () => Future.wait<Object?>([
        ref.read(feedProvider.notifier).refresh(),
        ref.read(trackedAppsProvider.notifier).checkForUpdates(force: true),
        ref.read(backupControllerProvider.notifier).syncIfDue(),
      ]),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          padSliver(ScreenHeader(title: greeting(now), subtitle: subtitle, workspaceSwitch: true), top: 12),
          padSliver(
            Align(
              alignment: Alignment.centerLeft,
              child: PillToggle<TodayView>(
                options: const [(TodayView.overview, 'Overview'), (TodayView.focus, 'Focus')],
                selected: view,
                onChanged: ref.read(todayViewProvider.notifier).show,
              ),
            ),
            top: 10,
          ),
          // The mountain shows through here.
          padSliver(const SizedBox(height: 30)),
          if (account == AccountStatus.needsProfile)
            padSliver(
              PromptCard(
                icon: AppIcon.profile,
                title: 'One minute to finish your profile',
                body: 'Date of birth, category and degree are all we need to filter jobs and count your seats.',
                action: FilledButton(onPressed: () => openProfileSheet(context, ref), child: const Text('Finish profile')),
              ),
              top: 4,
            ),
          if (view == TodayView.focus)
            padSliver(const _Focus(), top: 4)
          else ...[
            padSliver(const _Bento(), top: 4),
            if (account != AccountStatus.needsProfile) ..._bestForYou(context, ref, snapshot != null),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
      ),
    );
  }

  List<Widget> _bestForYou(BuildContext context, WidgetRef ref, bool loaded) {
    final top = ref.watch(topMatchesProvider);
    final allJobs = ref.watch(rankedJobsProvider).length;
    return [
      padSliver(const SectionTitle('Best for you'), top: 24),
      if (!loaded)
        padSliver(
          ref.watch(feedProvider).hasError
              ? const MutedNote('Can’t reach the job list right now. Your exams still work offline.')
              : const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator())),
          top: 8,
        )
      else if (top.isEmpty)
        padSliver(const MutedNote('Nothing new that fits you. Nice and quiet.'), top: 8)
      else
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          sliver: SliverList.separated(
            itemCount: top.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (_, i) => SettleIn(
              id: top[i].item.jobPostId,
              index: i,
              child: SwipeableJob(ranked: top[i], screenContext: context, showSwipeHint: i == 0),
            ),
          ),
        ),
      if (allJobs > top.length)
        padSliver(
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => ref.read(homeTabProvider.notifier).show(1),
              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
              label: Text('See all $allJobs jobs'),
            ),
          ),
          top: 8,
        ),
    ];
  }
}

// -----------------------------------------------------------------------------
// Steps: what a step says and does
// -----------------------------------------------------------------------------

String _stepTitle(NextStep s) => s.feedItem?.bestPost.postName ?? s.application?.examName ?? s.title;

String _stepLine(NextStep s) => switch (s.kind) {
      NextStepKind.apply => '${s.feedItem?.organization ?? ''} · closes ${formatDue(s.due)}',
      NextStepKind.finishForm => 'Fee not paid · closes ${formatDue(s.due)}',
      NextStepKind.downloadAdmitCard => 'Admit card is out · exam ${formatDue(s.due)}',
      NextStepKind.attendExam => 'Exam ${formatDue(s.due)}',
      NextStepKind.prepareForExam => 'Exam ${formatDue(s.due)}',
    };

String _stepLabel(NextStep s) => switch (s.kind) {
      NextStepKind.apply => 'NEXT DEADLINE',
      NextStepKind.finishForm => 'FINISH YOUR FORM',
      NextStepKind.downloadAdmitCard => 'ADMIT CARD OUT',
      NextStepKind.attendExam || NextStepKind.prepareForExam => 'NEXT EXAM',
    };

/// Apply: the application form. A tracked exam: its journey page.
void _runStep(BuildContext context, NextStep s) {
  final app = s.application;
  if (app != null) {
    ExamJourneyScreen.open(context, app);
  } else {
    openExternal(context, s.actionUrl);
  }
}

/// A solid tile in the workspace colour, on its own darker edge.
class _AccentTile extends StatelessWidget {
  const _AccentTile({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadii.card);
    return Container(
      padding: const EdgeInsets.only(bottom: AppCard.depth),
      decoration: BoxDecoration(color: Color.lerp(AppPalette.periwinkle, Colors.black, 0.32), borderRadius: radius),
      child: Material(
        color: AppPalette.periwinkle,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 16), child: child),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Overview
// -----------------------------------------------------------------------------

class _Bento extends ConsumerWidget {
  const _Bento();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final now = ref.watch(nowProvider);
    final step = ref.watch(nextStepProvider);
    final xp = ref.watch(xpProvider);
    final streak = xp.streakOn(now);
    final jobs = ref.watch(rankedJobsProvider).length;
    final admitCards = ref.watch(activeAppsProvider).where((a) => a.displayStatus == TrackerStatus.admitCardLive);
    final tabs = ref.read(homeTabProvider.notifier);
    final muted = text.labelSmall?.copyWith(color: AppPalette.textMuted, fontWeight: FontWeight.w900, letterSpacing: 0.6);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (step == null)
          AppCard(
            child: Row(
              children: [
                DuoIcon(AppIcon.calmEmpty, size: 34, color: AppPalette.sage),
                const SizedBox(width: 14),
                Expanded(child: Text('All clear: nothing due soon. Have a look at new jobs below.', style: text.bodyMedium)),
              ],
            ),
          )
        else
          _AccentTile(
            onTap: () => _runStep(context, step),
            child: Row(
              children: [
                _DaysRing(due: step.due, now: now),
                const SizedBox(width: 14),
                Expanded(
                  child: DefaultTextStyle.merge(
                    style: TextStyle(color: AppPalette.onAccent),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_stepLabel(step),
                            style: text.labelSmall?.copyWith(color: AppPalette.onAccent, fontWeight: FontWeight.w900, letterSpacing: 0.6)),
                        const SizedBox(height: 2),
                        Text(_stepTitle(step),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleMedium?.copyWith(color: AppPalette.onAccent, fontWeight: FontWeight.w900)),
                        Text(_stepLine(step),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(color: AppPalette.onAccent, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: AppCard(
                  onTap: () => showXpSheet(context),
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('LEVEL ${xp.level}', style: muted),
                      const SizedBox(height: 4),
                      Text(xp.levelTitle, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: LinearProgressIndicator(
                          value: xp.levelProgress.clamp(0, 1),
                          minHeight: 8,
                          color: AppPalette.periwinkle,
                          backgroundColor: AppPalette.surfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text('${xp.xp} / ${xp.nextLevelAt} XP', style: text.labelSmall),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: AppCard(
                  onTap: () => showXpSheet(context),
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.local_fire_department_rounded, color: AppPalette.honey, size: 26),
                      const SizedBox(height: 4),
                      Text(streak == 1 ? '1 day' : '$streak days', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
                      Text(xp.doneToday(now) ? 'streak · done for today' : 'streak · keep it going', style: text.labelSmall),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _CountTile(
                  count: admitCards.length,
                  label: admitCards.length == 1 ? 'admit card out' : 'admit cards out',
                  detail: admitCards.isEmpty ? 'none waiting' : admitCards.map((a) => a.examName).take(2).join(', '),
                  color: AppPalette.lavender,
                  tinted: true,
                  onTap: () => tabs.show(2),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CountTile(
                  count: jobs,
                  label: jobs == 1 ? 'job fits you' : 'jobs fit you',
                  detail: 'open now',
                  color: AppPalette.sage,
                  onTap: () => tabs.show(1),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _WeekStrip(items: ref.watch(agendaProvider), now: now, onTap: () => tabs.show(3)),
      ],
    );
  }
}

class _DaysRing extends StatelessWidget {
  const _DaysRing({required this.due, required this.now});

  final DateTime due;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final left = due.difference(now);
    final days = left.inDays;
    final (value, unit) = days >= 1 ? ('$days', days == 1 ? 'day' : 'days') : ('${left.inHours.clamp(0, 23)}', 'hrs');
    return SizedBox.square(
      dimension: 60,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: (1 - left.inHours / (14 * 24)).clamp(0.05, 1),
              strokeWidth: 6,
              color: AppPalette.onAccent,
              backgroundColor: AppPalette.onAccent.withValues(alpha: 0.18),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(value, style: text.titleMedium?.copyWith(color: AppPalette.onAccent, fontWeight: FontWeight.w900, height: 1)),
              Text(unit, style: text.labelSmall?.copyWith(color: AppPalette.onAccent, height: 1.1)),
            ],
          ),
        ],
      ),
    );
  }
}

class _CountTile extends StatelessWidget {
  const _CountTile({
    required this.count,
    required this.label,
    required this.detail,
    required this.color,
    required this.onTap,
    this.tinted = false,
  });

  final int count;
  final String label;
  final String detail;
  final Color color;
  final VoidCallback onTap;
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$count', style: text.headlineSmall?.copyWith(color: color, fontWeight: FontWeight.w900)),
        Text(label, style: text.titleSmall?.copyWith(color: tinted ? color : null)),
        const SizedBox(height: 2),
        Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.labelSmall),
      ],
    );
    if (!tinted) return AppCard(onTap: onTap, padding: const EdgeInsets.all(14), child: body);
    // The one coloured tile: what needs you.
    final radius = BorderRadius.circular(AppRadii.card);
    final face = Color.alphaBlend(color.withValues(alpha: AppPalette.current.isLight ? 0.12 : 0.18), AppPalette.surface);
    return Container(
      padding: const EdgeInsets.only(bottom: AppCard.depth),
      decoration: BoxDecoration(color: AppPalette.cardBase, borderRadius: radius),
      child: Material(
        color: face,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Padding(padding: const EdgeInsets.all(14), child: body)),
      ),
    );
  }
}

/// The next seven days, with a ring on the days that have something.
class _WeekStrip extends StatelessWidget {
  const _WeekStrip({required this.items, required this.now, required this.onTap});

  final List<AgendaItem> items;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final today = agendaDay(now);
    final days = [for (var i = 0; i < 7; i++) today.add(Duration(days: i))];
    Color? mark(DateTime d) {
      final first = items.where((i) => i.day == d).firstOrNull;
      if (first == null) return null;
      return switch (first.kind) {
        AgendaKind.deadline => first.at.difference(now).inHours < 72 ? AppPalette.terracotta : AppPalette.honey,
        AgendaKind.exam => AppPalette.sage,
        _ => AppPalette.periwinkle,
      };
    }

    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 10),
            child: Text('THIS WEEK',
                style: text.labelSmall?.copyWith(color: AppPalette.textMuted, fontWeight: FontWeight.w900, letterSpacing: 0.6)),
          ),
          Row(
            children: [
              for (final d in days)
                Expanded(
                  child: Column(
                    children: [
                      Text(const ['M', 'T', 'W', 'T', 'F', 'S', 'S'][d.weekday - 1], style: text.labelSmall),
                      const SizedBox(height: 4),
                      Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: d == today ? AppPalette.periwinkle : null,
                          borderRadius: BorderRadius.circular(11),
                          border: d != today && mark(d) != null ? Border.all(color: mark(d)!, width: 2) : null,
                        ),
                        child: Text('${d.day}',
                            style: text.labelLarge?.copyWith(
                                fontSize: 13, color: d == today ? AppPalette.onAccent : AppPalette.textPrimary)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Focus
// -----------------------------------------------------------------------------

class _Focus extends ConsumerWidget {
  const _Focus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final now = ref.watch(nowProvider);
    final steps = ref.watch(focusStepsProvider);
    if (steps.isEmpty) return const CalmEmptyHero();
    final first = steps.first;
    final then = steps.skip(1).take(3).toList();
    final onAccent = AppPalette.onAccent;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AccentTile(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('DO THIS NEXT',
                  style: text.labelSmall?.copyWith(color: onAccent, fontWeight: FontWeight.w900, letterSpacing: 0.8)),
              const SizedBox(height: 6),
              Text(
                first.kind == NextStepKind.apply ? 'Apply to ${_stepTitle(first)}' : _stepTitle(first),
                style: text.titleLarge?.copyWith(color: onAccent, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 4),
              Text(_stepLine(first), style: text.bodyMedium?.copyWith(color: onAccent, fontWeight: FontWeight.w700)),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: onAccent, foregroundColor: AppPalette.periwinkle),
                      onPressed: () => _runStep(context, first),
                      child: Text(first.kind == NextStepKind.apply ? 'Start' : 'Open', maxLines: 1, softWrap: false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: onAccent),
                    onPressed: () => ref.read(focusSnoozeProvider.notifier).snooze(first.id, now),
                    child: const Text('Not now', maxLines: 1, softWrap: false),
                  ),
                ],
              ),
              if (first.kind == NextStepKind.apply && first.feedItem != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: onAccent, padding: EdgeInsets.zero),
                    onPressed: () => applyToJob(context, ref, first.feedItem!),
                    icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
                    label: const Text('I applied'),
                  ),
                ),
            ],
          ),
        ),
        if (then.isNotEmpty) ...[
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 8),
            child: Text('THEN',
                style: text.labelSmall?.copyWith(color: AppPalette.textMuted, fontWeight: FontWeight.w900, letterSpacing: 0.6)),
          ),
          for (final s in then) ...[
            AppCard(
              onTap: () => _runStep(context, s),
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Row(
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: context.urgencyColors.of(urgencyFor(s.due, now)), width: 2.5),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_stepTitle(s), style: text.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                        Text(_stepLine(s), style: text.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: AppPalette.textMuted),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ],
    );
  }
}
