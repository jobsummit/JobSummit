import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/insights_providers.dart';
import '../theme/app_theme.dart';

/// Asked once: share what helps job picks, or not. Says what goes and what never does.
Future<void> showInsightsSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => const _InsightsSheet(),
    );

class _InsightsSheet extends ConsumerWidget {
  const _InsightsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    Future<void> answer(bool yes) async {
      await ref.read(insightsConsentProvider.notifier).set(yes);
      if (context.mounted) Navigator.pop(context);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Help improve job picks?', style: text.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Share, without your name, which jobs people like you apply to, so everyone sees better jobs first.',
            style: text.bodyMedium,
          ),
          const SizedBox(height: 12),
          _Line(Icons.check_rounded, AppPalette.sage, 'Shared: your age range, category, degrees and subjects, '
              'job preferences, exams you track, and jobs you applied to or turned down.'),
          _Line(Icons.block_rounded, AppPalette.terracotta, 'Never: your name, email, date of birth, Google account, '
              'IDs, passwords, notes, photos or response sheets.'),
          _Line(Icons.delete_outline_rounded, AppPalette.textMuted, 'Change your mind or delete it any time in Settings › Jobs.'),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: OutlinedButton(onPressed: () => answer(false), child: const Text('No thanks'))),
              const SizedBox(width: 10),
              Expanded(child: FilledButton(onPressed: () => answer(true), child: const Text('Yes, share'))),
            ],
          ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.icon, this.color, this.text);

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
          ],
        ),
      );
}

/// Settings › Jobs: share or not, and delete what was shared.
class InsightsSettings extends ConsumerWidget {
  const InsightsSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(insightsConsentProvider).valueOrNull ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: on,
          onChanged: (v) => ref.read(insightsConsentProvider.notifier).set(v),
          title: const Text('Help improve job picks'),
          subtitle: const Text('Share, without your name, which jobs people like you choose'),
        ),
        TextButton(
          onPressed: () async {
            try {
              await ref.read(insightsConsentProvider.notifier).forget();
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Deleted. Nothing more is shared.')));
              }
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Couldn’t reach the server. Try again online.')));
              }
            }
          },
          child: const Text('Delete what I shared'),
        ),
      ],
    );
  }
}
