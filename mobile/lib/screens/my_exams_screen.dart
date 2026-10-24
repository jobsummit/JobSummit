import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/delivery_track.dart';
import '../domain/lifecycle.dart';
import '../models/tracked_application.dart';
import '../providers/providers.dart';
import '../services/fx.dart';
import '../theme/app_theme.dart';
import '../utils/system_actions.dart';
import '../widgets/add_exam_sheet.dart';
import '../widgets/app_card.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import '../widgets/dashboard_check_sheet.dart';
import '../widgets/motion.dart';
import '../widgets/one_line.dart';
import '../widgets/pills.dart';
import '../widgets/summit_backdrop.dart';
import 'exam_journey_screen.dart';

/// Where an exam belongs in the old three-way split: archived if put away,
/// "Results out" once its result stop is done, else tracked. (Lanes use [laneOf].)
enum ExamTab {
  tracked('Tracked'),
  resultsOut('Results out'),
  archived('Archived');

  const ExamTab(this.label);
  final String label;
}

ExamTab tabOf(TrackedApplication a, DateTime now) {
  if (a.archived) return ExamTab.archived;
  final resultStop = buildDeliveryTrack(a, now).stops[4];
  return resultStop.state == StageState.completed ? ExamTab.resultsOut : ExamTab.tracked;
}

/// The lanes, in order: the stage each exam is at.
const kLanes = ['Applied', 'Admit card', 'Exam', 'Answer key', 'Result'];
const _laneChips = ['Applied', 'Admit', 'Exam', 'Key', 'Result'];
const _laneEmpty = [
  'Applied and waiting for the admit card. Swipe a job right after you apply, or add an exam yourself.',
  'Admit card out: these exams are coming up (or on now).',
  'Exam written: waiting for the answer key.',
  'Answer key out: waiting for the result.',
  'Results out, or a next stage to track. Done with one? Swipe it left to archive it.',
];

/// The last stage an exam has reached: Applied (waiting for the admit card),
/// Admit card (exam coming), Exam (written), Answer key, Result (done, or a next
/// stage to track).
int laneOf(TrackedApplication app, DateTime now) {
  final track = buildDeliveryTrack(app, now);
  if (track.finished || track.offersNextTier) return 4;
  // A stage stays "active" both while it is awaited and once it is out: the
  // status says which.
  final status = app.displayStatus.index;
  return switch (track.activeIndex) {
    0 => 0,
    1 => status >= TrackerStatus.admitCardLive.index ? 1 : 0,
    2 => 1,
    3 => status >= TrackerStatus.answerKeyLive.index ? 3 : 2,
    _ => 3,
  };
}

/// Which lane My exams shows: the lane strip and the Summit trail's stops both set it.
class ExamLaneNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void show(int lane) => state = lane.clamp(0, kLanes.length - 1);
}

final examLaneProvider = NotifierProvider<ExamLaneNotifier, int>(ExamLaneNotifier.new);

/// Your exams on the Summit trail (drawn on the mountain above, by the shell) and
/// as lanes, one per stage: swipe sideways between stages, tap an exam for its
/// journey page, swipe one left to archive it.
class MyExamsScreen extends ConsumerStatefulWidget {
  const MyExamsScreen({super.key});

  @override
  ConsumerState<MyExamsScreen> createState() => _MyExamsScreenState();
}

class _MyExamsScreenState extends ConsumerState<MyExamsScreen> {
  final _pages = PageController(viewportFraction: 0.9);

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _turnTo(int lane) {
    if (!_pages.hasClients || _pages.page?.round() == lane) return;
    if (motionOff(context)) {
      _pages.jumpToPage(lane);
    } else {
      _pages.animateToPage(lane, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(trackedAppsProvider);
    final now = ref.watch(nowProvider);
    final apps = all.dataOrNull ?? const <TrackedApplication>[];
    final lanes = [for (var i = 0; i < kLanes.length; i++) <TrackedApplication>[]];
    var archived = 0;
    for (final a in apps) {
      if (a.archived) {
        archived++;
      } else {
        lanes[laneOf(a, now)].add(a);
      }
    }
    // Soonest date first; exams waiting on an answer key or result (no date) after.
    for (final list in lanes) {
      list.sort((a, b) =>
          (a.focusDateAt(now) ?? DateTime(9999)).compareTo(b.focusDateAt(now) ?? DateTime(9999)));
    }
    final active = apps.length - archived;
    final lane = ref.watch(examLaneProvider);
    // A stop tapped on the trail turns the lanes too.
    ref.listen(examLaneProvider, (_, next) => _turnTo(next));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The trail's mountain fills this space (the shell draws it, with the climbers).
        SizedBox(
          height: SummitHeights.exams + 6,
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: ScreenHeader(
                title: 'My exams',
                subtitle: active == 1 ? '1 exam you applied to' : '$active exams you applied to',
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            children: [
              for (var i = 0; i < kLanes.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                Expanded(
                  child: _LaneChip(
                    label: _laneChips[i],
                    count: lanes[i].length,
                    selected: i == lane,
                    onTap: () => ref.read(examLaneProvider.notifier).show(i),
                  ),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Row(
            children: [
              // Always there, so archived exams are easy to find again.
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => const _ArchivedExamsScreen())),
                icon: const DuoIcon(AppIcon.archive, size: 18),
                label: Text(archived == 0 ? 'Archived' : 'Archived $archived', maxLines: 1, softWrap: false),
              ),
              const Spacer(),
              const AddExamButton(),
            ],
          ),
        ),
        Expanded(
          child: all.hasError
              ? const Padding(padding: EdgeInsets.all(16), child: MutedNote('Could not read local data. Restart the app.'))
              : PageView.builder(
                  controller: _pages,
                  padEnds: false,
                  itemCount: kLanes.length,
                  onPageChanged: ref.read(examLaneProvider.notifier).show,
                  itemBuilder: (context, i) => _Lane(
                    index: i,
                    apps: lanes[i],
                    loading: all.isLoading,
                    now: now,
                  ),
                ),
        ),
      ],
    );
  }
}

class _LaneChip extends StatelessWidget {
  const _LaneChip({required this.label, required this.count, required this.selected, required this.onTap});

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium;
    return Semantics(
      button: true,
      selected: selected,
      label: '$label, $count',
      child: Material(
        color: selected ? AppPalette.periwinkle : AppPalette.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
            child: Center(
              child: OneLine(
                '$label $count',
                style: style?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: selected ? AppPalette.onAccent : AppPalette.textMuted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Lane extends ConsumerWidget {
  const _Lane({required this.index, required this.apps, required this.loading, required this.now});

  final int index;
  final List<TrackedApplication> apps;
  final bool loading;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) => RefreshIndicator(
        onRefresh: () => ref.read(trackedAppsProvider.notifier).checkForUpdates(force: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 6, 4, 90),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10, left: 2),
              child: Text(kLanes[index], style: Theme.of(context).textTheme.titleMedium),
            ),
            if (apps.isEmpty && !loading)
              MutedNote(_laneEmpty[index])
            else
              for (final app in apps) ...[
                Dismissible(
                  key: ValueKey('lane-${app.id}'),
                  direction: DismissDirection.endToStart,
                  background: const SizedBox.shrink(),
                  secondaryBackground: SwipeBackground(
                    color: AppPalette.textMuted,
                    icon: AppIcon.archive,
                    label: 'Archive',
                    alignEnd: true,
                  ),
                  onDismissed: (_) => setExamArchived(context, ref, app, archived: true),
                  child: ExamLaneCard(app: app, now: now),
                ),
                const SizedBox(height: 12),
              ],
          ],
        ),
      );
}

/// Archive or restore, with Undo.
void setExamArchived(BuildContext context, WidgetRef ref, TrackedApplication app, {required bool archived}) {
  final notifier = ref.read(trackedAppsProvider.notifier);
  Fx.dismiss();
  notifier.setArchived(app.id, archived: archived);
  showCalmSnack(
    context,
    archived ? 'Archived ${app.postName}' : 'Restored ${app.postName}',
    action: SnackBarAction(label: 'Undo', onPressed: () => notifier.setArchived(app.id, archived: !archived)),
  );
}

/// One exam in a lane: name, date, the track's one sentence and the main button.
/// Tap it for the Exam journey page.
class ExamLaneCard extends ConsumerWidget {
  const ExamLaneCard({super.key, required this.app, required this.now});

  final TrackedApplication app;
  final DateTime now;

  Future<void> _examDone(WidgetRef ref) {
    // The exam's own first day if it has passed, else yesterday: either way the
    // track moves on to the answer key.
    final today = DateTime.now();
    final start = app.effectiveExamAt;
    final when = start != null && start.isBefore(DateTime(today.year, today.month, today.day))
        ? start
        : DateTime(today.year, today.month, today.day - 1, 12);
    return ref.read(trackedAppsProvider.notifier).setStatus(app.id, ApplicationStatus.examScheduled, examAt: when);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final track = buildDeliveryTrack(app, now);
    final vault = ref.watch(vaultEntryProvider(app.id)).dataOrNull;
    final hasPassword = ref.watch(hasPasswordProvider(app.id)).dataOrNull ?? false;
    final hasIds = hasPassword || !(vault?.isEmpty ?? true);
    final focus = app.focusDateAt(now);
    final login = app.loginUrl;

    return AppCard(
      onTap: () => ExamJourneyScreen.open(context, app),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(app.postName, style: text.titleMedium)),
              if (focus != null && !app.examOver(now)) ...[
                const SizedBox(width: 8),
                CountdownPill(due: focus, now: now),
              ],
            ],
          ),
          if (app.examName != app.postName) Text(app.examName, style: text.bodySmall),
          if (app.tierName != null) Text(app.tierName!, style: text.bodySmall),
          const SizedBox(height: 8),
          Text(track.headline, style: text.bodyMedium, maxLines: 3, overflow: TextOverflow.ellipsis),
          if (app.myScore case final score?) ...[
            const SizedBox(height: 6),
            Text('Your score: ${score.label}',
                style: text.labelLarge?.copyWith(color: AppPalette.periwinkle, fontWeight: FontWeight.w800)),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              if (login != null)
                FilledButton.tonal(
                  onPressed: hasIds
                      ? () => showDashboardCheck(
                            context,
                            ref,
                            app,
                            onAdmitCardOut: () => ref
                                .read(trackedAppsProvider.notifier)
                                .setStatus(app.id, ApplicationStatus.admitCardLive),
                            onExamDone: () => _examDone(ref),
                          )
                      : () => openExternal(context, login),
                  child: Text(hasIds ? 'Check dashboard' : 'Login', maxLines: 1, softWrap: false),
                ),
              const Spacer(),
              Icon(Icons.chevron_right_rounded, color: AppPalette.textMuted),
            ],
          ),
        ],
      ),
    );
  }
}

class _ArchivedExamsScreen extends ConsumerWidget {
  const _ArchivedExamsScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(nowProvider);
    final apps = [
      for (final a in ref.watch(trackedAppsProvider).dataOrNull ?? const <TrackedApplication>[])
        if (a.archived) a,
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Archived')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (apps.isEmpty)
            const MutedNote('Nothing archived yet. Swipe an exam left in My exams to put it here.')
          else ...[
            const Padding(padding: EdgeInsets.only(bottom: 10), child: MutedNote('Swipe one left to bring it back.')),
            for (final app in apps) ...[
              Dismissible(
                key: ValueKey('archived-${app.id}'),
                direction: DismissDirection.endToStart,
                background: const SizedBox.shrink(),
                secondaryBackground: SwipeBackground(
                  color: AppPalette.textMuted,
                  icon: Icons.unarchive_rounded,
                  label: 'Restore',
                  alignEnd: true,
                ),
                onDismissed: (_) => setExamArchived(context, ref, app, archived: false),
                child: ExamLaneCard(app: app, now: now),
              ),
              const SizedBox(height: 12),
            ],
          ],
        ],
      ),
    );
  }
}
