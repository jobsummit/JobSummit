import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../theme/app_theme.dart';
import '../../utils/system_actions.dart';
import 'models.dart';
import 'private_profile_screen.dart';
import 'providers.dart';
import '../../domain/agenda.dart';


/// Settings › Profile in the Private workspace: its own profile, apart from the Govt one.
class PrivateProfilePage extends ConsumerWidget {
  const PrivateProfilePage({super.key});

  Future<void> _reset(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppPalette.surface,
        title: const Text('Reset private profile?'),
        content: const Text('Your headline, skills, roles, experience, cities and résumé are cleared. '
            'Your private applications and your Govt profile stay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(privateProfileProvider.notifier).reset();
    if (context.mounted) showCalmSnack(context, 'Private profile reset.');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final p = ref.watch(privateProfileProvider).dataOrNull ?? const PrivateProfile();
    String list(List<String> v, {String empty = 'None yet'}) => v.isEmpty ? empty : v.join(', ');
    final years = p.experienceYears == p.experienceYears.roundToDouble()
        ? '${p.experienceYears.toInt()}'
        : p.experienceYears.toStringAsFixed(1);
    final imported = p.linkedinImportedAt?.toLocal();

    Widget fact(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 110,
                child: Text(label, style: text.bodyMedium?.copyWith(color: AppPalette.textMuted)),
              ),
              Expanded(child: Text(value, style: text.bodyMedium)),
            ],
          ),
        );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Your private profile', style: text.titleMedium),
        const SizedBox(height: 2),
        Text('Separate from your Govt profile: only Private jobs use it.', style: text.bodySmall),
        const SizedBox(height: 14),
        fact('Headline', p.headline.isEmpty ? '—' : p.headline),
        fact('Experience', p.experienceYears == 0 ? 'Fresher' : '$years years'),
        fact('Roles', list(p.targetRoles)),
        fact('Skills', list(p.skills)),
        fact('Cities', list(p.cities, empty: 'Anywhere')),
        fact('Résumé', p.resumeName ?? 'Not added'),
        if (imported != null)
          fact('LinkedIn', 'Filled in ${imported.day} ${kShortMonths[imported.month - 1]} ${imported.year}'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute<void>(builder: (_) => const PrivateProfileScreen())),
              icon: const Icon(Icons.edit_rounded, size: 18),
              label: Text(p.isEmpty ? 'Set up private profile' : 'Edit private profile'),
            ),
            if (!p.isEmpty)
              TextButton.icon(
                onPressed: () => _reset(context, ref),
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: const Text('Reset private profile'),
              ),
          ],
        ),
      ],
    );
  }
}
