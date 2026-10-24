import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/relevance.dart';
import '../domain/shared_job.dart';
import '../models/feed.dart';
import '../providers/jobs_providers.dart';
import '../providers/providers.dart';
import '../screens/exam_journey_screen.dart';
import '../services/share_intake.dart';
import '../theme/app_theme.dart';
import 'add_exam_sheet.dart';
import 'common.dart';
import 'job_card.dart';

/// A job shared to JobSummit: the job in your list it is (swipe it as usual), the
/// exam you already track, or "Track it yourself" when the app doesn't have it.
Future<void> showSharedJobSheet(BuildContext context, String shared) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _SharedJobSheet(share: SharedText.parse(shared), screenContext: context),
    );

class _SharedJobSheet extends ConsumerStatefulWidget {
  const _SharedJobSheet({required this.share, required this.screenContext});

  final SharedText share;
  final BuildContext screenContext;

  @override
  ConsumerState<_SharedJobSheet> createState() => _SharedJobSheetState();
}

class _SharedJobSheetState extends ConsumerState<_SharedJobSheet> {
  String? _pageTitle;

  @override
  void initState() {
    super.initState();
    final url = widget.share.url;
    if (widget.share.needsPageTitle && url != null) {
      ShareIntake.pageTitle(url).then((t) {
        if (mounted) setState(() => _pageTitle = t);
      });
    } else {
      _pageTitle = '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final title = _pageTitle;
    if (title == null) {
      return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
    }
    final ranked = [...ref.watch(rankedJobsProvider), ...ref.watch(rankedNearMissProvider)];
    final hidden = {for (final (item, why) in ref.watch(hiddenJobsProvider)) item.jobPostId: (item, why)};
    final match = matchShared(
      widget.share,
      jobs: [for (final r in ranked) r.item, for (final (item, _) in hidden.values) item],
      tracked: ref.watch(activeAppsProvider),
      pageTitle: title,
    );
    final byId = {for (final r in ranked) r.item.jobPostId: r};
    final name = widget.share.suggestedName.isNotEmpty ? widget.share.suggestedName : title;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(match.isEmpty ? 'Not in the job list yet' : 'Found it', style: text.titleLarge),
          const SizedBox(height: 4),
          if (name.isNotEmpty) Text(name, style: text.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 14),
          for (final app in match.tracked)
            Card(
              child: ListTile(
                title: Text(app.examName),
                subtitle: const Text('You already track this'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  Navigator.of(context).pop();
                  ExamJourneyScreen.open(widget.screenContext, app);
                },
              ),
            ),
          for (final job in match.jobs) ...[
            if (byId[job.jobPostId] case final r?)
              SwipeableJob(ranked: r, screenContext: widget.screenContext)
            else if (hidden[job.jobPostId] case (final FeedItem item, final String why)) ...[
              SwipeableJob(ranked: RankedJob(item, 0, const []), screenContext: widget.screenContext),
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 4),
                child: Text('Hidden from your list: $why', style: text.bodySmall?.copyWith(color: AppPalette.honey)),
              ),
            ],
            const SizedBox(height: 10),
          ],
          if (match.isEmpty)
            const MutedNote('It may be new, or not fit your profile. You can still track it.'),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () {
              Navigator.of(context).pop();
              showAddExamSheet(widget.screenContext, name: name);
            },
            child: Text(match.isEmpty ? 'Track it yourself' : 'None of these: track it yourself'),
          ),
        ],
      ),
    );
  }
}
