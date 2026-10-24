import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/relevance.dart';
import '../domain/xp.dart';
import '../domain/urgency.dart';
import '../models/feed.dart';
import '../models/job_preferences.dart';
import '../models/jobs_data.dart';
import '../models/tracked_application.dart';
import '../providers/jobs_providers.dart';
import '../providers/providers.dart';
import '../providers/xp_providers.dart';
import '../services/fx.dart';
import '../theme/app_theme.dart';
import '../utils/system_actions.dart';
import 'app_card.dart';
import 'app_icons.dart';
import 'application_tracker_sheet.dart';
import 'common.dart';
import 'motion.dart';
import 'pills.dart';

// -----------------------------------------------------------------------------
// Actions shared by Today and Jobs
// -----------------------------------------------------------------------------

/// Swipe right / "I applied": track it, remember it, then ask for the IDs.
/// [screenContext] must outlive the card (the card disappears from the list).
Future<bool> applyToJob(BuildContext screenContext, WidgetRef ref, FeedItem item) async {
  // Read up front: the card (and its ref) is gone by the time Undo is tapped.
  final notifier = ref.read(trackedAppsProvider.notifier);
  final decisions = ref.read(decisionsProvider.notifier);
  final xp = ref.read(xpProvider.notifier);
  final category = ref.read(feedProvider).dataOrNull?.category;
  try {
    final app = await notifier.markAppliedFromFeed(item, category: category);
    Fx.applied();
    if (screenContext.mounted) showAppliedCelebration(screenContext);
    if (!screenContext.mounted) return true;
    showCalmSnack(
      screenContext,
      'Marked as applied ✓ It’s in My exams.',
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () async {
          await notifier.untrack(app.id);
          await decisions.undo(item.jobPostId);
          // Not applied after all: its XP comes off (applying again earns it again).
          final key = xpExamKey(jobPostId: item.jobPostId, examName: item.examName);
          await xp.revoke(key);
          await xp.revoke('ids:$key');
        },
      ),
    );
    unawaited(() async {
      final creds = await showApplicationTrackerSheet(
        screenContext,
        title: 'Applied · ${app.postName}',
        onPaidChanged: (paid) =>
            notifier.setStatus(app.id, paid ? ApplicationStatus.applied : ApplicationStatus.started),
      );
      if (creds != null) await notifier.saveCredentials(app.id, creds);
    }());
    return true;
  } catch (_) {
    if (screenContext.mounted) showCalmSnack(screenContext, 'Could not save. Try again.');
    return false;
  }
}

/// Swipe left / "Not for me": hide it and learn from it, with Undo.
Future<bool> rejectJobWithUndo(BuildContext screenContext, WidgetRef ref, FeedItem item) async {
  Fx.dismiss();
  final decisions = ref.read(decisionsProvider.notifier);
  try {
    await decisions.record(item, applied: false);
  } catch (_) {
    if (screenContext.mounted) showCalmSnack(screenContext, 'Could not save. Try again.');
    return false;
  }
  if (screenContext.mounted) {
    showCalmSnack(
      screenContext,
      'Hidden. You’ll see fewer jobs like it.',
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => decisions.undo(item.jobPostId),
      ),
    );
  }
  return true;
}

// -----------------------------------------------------------------------------
// The card
// -----------------------------------------------------------------------------

/// Swipe right = applied, swipe left = not for me. Saves before the card animates away.
class SwipeableJob extends ConsumerWidget {
  const SwipeableJob(
      {super.key, required this.ranked, required this.screenContext, this.showSwipeHint = false});

  final RankedJob ranked;
  final BuildContext screenContext;
  final bool showSwipeHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ranked.item;
    final colors = context.urgencyColors;
    return Dismissible(
      key: ValueKey('job-${item.jobPostId}'),
      background: SwipeBackground(color: colors.safe, icon: AppIcon.eligible, label: 'Applied'),
      secondaryBackground: SwipeBackground(
        color: AppPalette.textMuted,
        icon: Icons.close_rounded,
        label: 'Not for me',
        alignEnd: true,
      ),
      confirmDismiss: (direction) => direction == DismissDirection.startToEnd
          ? applyToJob(screenContext, ref, item)
          : rejectJobWithUndo(screenContext, ref, item),
      child: SwipeNudge(
        enabled: showSwipeHint,
        child: JobCard(ranked: ranked, screenContext: screenContext, showSwipeHint: showSwipeHint),
      ),
    );
  }
}

class JobCard extends ConsumerStatefulWidget {
  const JobCard({super.key, required this.ranked, required this.screenContext, this.showSwipeHint = false});

  final RankedJob ranked;
  final BuildContext screenContext;
  final bool showSwipeHint;

  @override
  ConsumerState<JobCard> createState() => _JobCardState();
}

class _JobCardState extends ConsumerState<JobCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.ranked.item;
    final text = Theme.of(context).textTheme;
    final now = ref.watch(nowProvider);
    final category = ref.watch(feedProvider).dataOrNull?.category;
    final post = item.bestPost;
    final pay = item.monthlyPay;
    final jobCategory = JobCategory.fromWire(item.category);
    // Several posts you fit, one application (RRB NTPC, SSC CGL): the exam is the title.
    final several = item.posts.length > 1;

    return AppCard(
      accent: context.urgencyColors.of(item.urgency),
      onTap: () => setState(() => _open = !_open),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(several ? item.examName : post.postName, style: text.titleMedium)),
              const SizedBox(width: 8),
              CountdownPill(due: item.deadline, now: now),
            ],
          ),
          const SizedBox(height: 4),
          Text(several ? '${item.organization} · ${item.posts.length} posts' : '${item.organization} · ${item.examName}',
              style: text.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TonePill(label: jobCategory.label, color: categoryColor(jobCategory)),
              if (pay != null) TonePill(label: formatPay(pay), color: context.urgencyColors.safe),
              if (post.totalReachableSeats > 0) // 0 = the notice didn't say
                SeatPill(
                  total: post.totalReachableSeats,
                  ur: post.urOpenSeats,
                  quota: post.categoryQuotaSeats,
                  category: category,
                ),
              if (post.matchKind == MatchKind.suggested)
                TonePill(
                    label: suggestionBadge(post.suggestionReasons), color: context.urgencyColors.warning),
              if (post.eligibleViaRelaxation) const StatusPill(label: 'Via age relaxation'),
              for (final reason in widget.ranked.reasons) StatusPill(label: reason),
            ],
          ),
          Fold(child: _open ? JobDetails(item: item, category: category) : null),
          const SizedBox(height: 12),
          Row(
            children: [
              if (item.applicationUrl != null) ...[
                FilledButton.tonalIcon(
                  onPressed: () => openExternal(context, item.applicationUrl),
                  icon: const DuoIcon(AppIcon.applyOnline, size: 18),
                  label: const Text('Apply online'),
                ),
                const SizedBox(width: 4),
              ],
              TextButton.icon(
                onPressed: () => setState(() => _open = !_open),
                icon: Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
                label: Text(_open ? 'Less' : 'Details'),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Not for me',
                onPressed: () => rejectJobWithUndo(widget.screenContext, ref, item),
                icon: Icon(Icons.close_rounded, size: 20, color: AppPalette.textMuted),
              ),
              IconButton(
                tooltip: 'I applied',
                onPressed: () => applyToJob(widget.screenContext, ref, item),
                icon: DuoIcon(AppIcon.eligible, size: 22, color: context.urgencyColors.safe),
              ),
            ],
          ),
          if (widget.showSwipeHint) ...[
            const SizedBox(height: 2),
            Text('Swipe right when applied · left if it’s not for you', style: text.labelSmall),
          ],
        ],
      ),
    );
  }
}

Color categoryColor(JobCategory c) => switch (c) {
      JobCategory.railway || JobCategory.psu => AppPalette.periwinkle,
      JobCategory.bank || JobCategory.ssc => AppPalette.sage,
      JobCategory.upsc || JobCategory.research => AppPalette.lavender,
      JobCategory.defence || JobCategory.state => AppPalette.honey,
      _ => AppPalette.textMuted,
    };

String employmentTypeLabel(String? type) => switch (type) {
      'permanent' => 'Permanent',
      'contract' => 'Contract',
      'apprenticeship' => 'Apprenticeship',
      'fellowship' => 'Fellowship',
      'internship' => 'Internship',
      _ => 'Not stated',
    };

// -----------------------------------------------------------------------------
// Expanded details
// -----------------------------------------------------------------------------

/// Pay, seats, age, qualification and dates for the posts you qualify for.
class JobDetails extends StatelessWidget {
  const JobDetails({super.key, required this.item, this.category});

  final FeedItem item;
  final String? category;

  @override
  Widget build(BuildContext context) {
    final job = item.job;
    final posts = postsOf(item);
    final timeline = job?.timelineJson ?? const <String, dynamic>{};
    final feeBy = DateTime.tryParse(timeline['fee_deadline'] as String? ?? '');
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (job == null)
            const MutedNote('Pull down to refresh for the full details.')
          else ...[
            _Row('Job type', employmentTypeLabel(job.employmentType)),
            if (job.advertisementNo != null) _Row('Advt. no.', job.advertisementNo!),
            _Row(
              'Dates',
              [
                if (job.applicationStart != null) 'Opens ${formatDue(job.applicationStart!)}',
                'Last date ${formatDue(item.deadline)}',
                if (feeBy != null) 'Fee by ${_day(feeBy)}',
                if (job.examDate != null) 'Exam ${_day(job.examDate!)}',
              ].join('\n'),
            ),
          ],
          for (final post in posts) _PostDetails(post: post, category: category, showName: posts.length > 1),
        ],
      ),
    );
  }
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _day(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

class _PostDetails extends StatefulWidget {
  const _PostDetails({required this.post, required this.category, required this.showName});

  final PublishedPost post;
  final String? category;
  final bool showName;

  @override
  State<_PostDetails> createState() => _PostDetailsState();
}

class _PostDetailsState extends State<_PostDetails> {
  bool _fullText = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = widget.post;
    final v = p.vacancy;
    final cat = widget.category ?? 'UR';
    final relax = p.ageRelaxationOverrides[cat];
    final qualification = [
      if (p.qualificationText != null) p.qualificationText!,
      if (p.qualificationText == null && p.eligibleStreams.isNotEmpty) p.eligibleStreams.join(', '),
    ].join();
    final eligibility = p.rawEligibilityText;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppPalette.surfaceVariant.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showName) ...[
            Text(p.postName, style: text.titleSmall),
            const SizedBox(height: 6),
          ],
          _Row('Pay', p.payScale ?? (p.monthlyPayMin != null ? formatPay(p.monthlyPayMin!) : 'Not stated')),
          _Row(
              'Seats',
              v != null && v.total > 0
                  ? 'Total ${v.total} · UR ${v.ur} · SC ${v.sc} · ST ${v.st} · OBC ${v.obc} · EWS ${v.ews}'
                  : 'Not stated'),
          if (p.minAge != null || p.baseMaxAge != null)
            _Row(
              'Age',
              [
                '${p.minAge ?? '—'}–${p.baseMaxAge ?? '—'} years',
                if (p.ageAsOn != null) 'as on ${_day(p.ageAsOn!)}',
                if (relax != null && relax > 0) '(+$relax for $cat)',
              ].join(' '),
            ),
          if (qualification.isNotEmpty) _Row('Qualification', qualification),
          if (p.minExperienceYears > 0)
            _Row('Experience',
                '${p.minExperienceYears % 1 == 0 ? p.minExperienceYears.toInt() : p.minExperienceYears} years'),
          if (eligibility != null && eligibility.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Eligibility as printed', style: text.labelMedium?.copyWith(color: AppPalette.textMuted)),
            const SizedBox(height: 2),
            Text(eligibility,
                style: text.bodySmall,
                maxLines: _fullText ? null : 4,
                overflow: _fullText ? null : TextOverflow.ellipsis),
            if (eligibility.length > 220)
              TextButton(
                style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                onPressed: () => setState(() => _fullText = !_fullText),
                child: Text(_fullText ? 'Show less' : 'Show all'),
              ),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 96, child: Text(label, style: text.labelMedium?.copyWith(color: AppPalette.textMuted))),
          Expanded(child: Text(value, style: text.bodySmall?.copyWith(color: AppPalette.textPrimary))),
        ],
      ),
    );
  }
}
