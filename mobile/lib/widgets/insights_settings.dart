import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/insights_providers.dart';

/// Settings › Jobs: share or not, and delete what was shared.
class InsightsSettings extends ConsumerWidget {
  const InsightsSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(insightsConsentProvider).valueOrNull ?? true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: on,
          onChanged: (v) => ref.read(insightsConsentProvider.notifier).set(v),
          title: const Text('Help improve job picks'),
          subtitle: const Text('Shares, without your name, which jobs people like you choose'),
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
