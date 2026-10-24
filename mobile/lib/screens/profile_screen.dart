import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/fees.dart';
import '../domain/subjects.dart';
import '../models/tracked_application.dart';
import '../models/user_profile.dart';
import '../providers/account_providers.dart';
import '../providers/providers.dart';
import '../providers/xp_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';
import '../widgets/celebrate.dart';
import '../widgets/common.dart';
import '../widgets/summit_backdrop.dart';
import 'home_shell.dart';
import 'settings_screen.dart';

/// One badge: earned, or still to come (shown as a "?").
class ProfileBadge {
  const ProfileBadge(this.icon, this.name, this.how, {required this.earned, required this.color});

  final IconData icon;
  final String name;
  final String how;
  final bool earned;
  final Color color;
}

/// Your profile as a game card: level and XP, a few stats, badges, and what you
/// qualify as. Edit, reset, or open Settings from here.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ProfileScreen()));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final now = ref.watch(nowProvider);
    final xp = ref.watch(xpProvider);
    final profile = ref.watch(profileProvider).dataOrNull;
    final user = ref.watch(googleAccountProvider).dataOrNull;
    final apps = ref.watch(trackedAppsProvider).dataOrNull ?? const <TrackedApplication>[];
    final admitCards = apps.where((a) => a.displayStatus.index >= TrackerStatus.admitCardLive.index).length;
    final keys = xp.earned.keys;
    final badges = [
      ProfileBadge(Icons.flag_rounded, 'First step', 'Track your first exam',
          earned: apps.isNotEmpty || keys.any((k) => k.startsWith('job:') || k.startsWith('exam:')),
          color: AppPalette.periwinkle),
      ProfileBadge(Icons.local_fire_department_rounded, 'Week streak', 'Do something useful 7 days in a row',
          earned: xp.bestStreak >= 7, color: AppPalette.honey),
      ProfileBadge(Icons.key_rounded, 'Keeper', 'Save the IDs for an exam',
          earned: keys.any((k) => k.startsWith('ids:')), color: AppPalette.sage),
      ProfileBadge(Icons.badge_rounded, 'Admit card', 'Get an admit card',
          earned: admitCards > 0, color: AppPalette.lavender),
      ProfileBadge(Icons.workspace_premium_rounded, 'Contender', 'Reach level 4',
          earned: xp.level >= 4, color: AppPalette.periwinkle),
    ];
    final qualifies = profile == null
        ? const <String>[]
        : [
            profile.qualificationLabel,
            for (final c in subjectsFromProfile(profile).values) subjectSummary(c),
            profile.category.label,
            'Age ${ageOn(profile.dateOfBirth, now)}',
            if (profile.isPwbd) 'PwBD',
            if (profile.isExServiceman) 'Ex-serviceman',
          ];
    final muted = text.labelSmall?.copyWith(color: AppPalette.textMuted, fontWeight: FontWeight.w900, letterSpacing: 0.6);

    return Scaffold(
      backgroundColor: AppPalette.background,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        actions: [
          TextButton.icon(
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
            icon: const Icon(Icons.settings_rounded, size: 18),
            label: const Text('Settings'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        children: [
          const Positioned.fill(child: SummitBackdrop(height: SummitHeights.privateProfile, waves: false)),
          ListView(
            padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 96, 16, 40),
            children: [
              Center(
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(color: AppPalette.background, shape: BoxShape.circle),
                  child: user != null
                      ? AccountPhoto(user, radius: 44, style: text.headlineSmall)
                      : CircleAvatar(
                          radius: 44,
                          backgroundColor: AppPalette.periwinkle,
                          child: Text(
                            (profile?.displayName.trim().isNotEmpty ?? false) ? profile!.displayName.trim()[0].toUpperCase() : '?',
                            style: text.headlineSmall?.copyWith(color: AppPalette.onAccent),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 6),
              if (profile != null && profile.displayName.trim().isNotEmpty)
                Text(profile.displayName, textAlign: TextAlign.center, style: text.titleMedium),
              Text('Level ${xp.level} · ${xp.levelTitle}',
                  textAlign: TextAlign.center, style: text.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              Center(
                child: SizedBox(
                  width: 220,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      value: xp.levelProgress.clamp(0, 1),
                      minHeight: 10,
                      color: AppPalette.periwinkle,
                      backgroundColor: AppPalette.surfaceVariant,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: TextButton(
                  onPressed: () => showXpSheet(context),
                  child: Text('${xp.xp} / ${xp.nextLevelAt} XP · how XP works', style: text.labelMedium),
                ),
              ),
              const SizedBox(height: 10),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _Stat(value: '${apps.length}', label: apps.length == 1 ? 'exam' : 'exams', color: AppPalette.periwinkle)),
                    const SizedBox(width: 8),
                    Expanded(child: _Stat(value: '$admitCards', label: admitCards == 1 ? 'admit card' : 'admit cards', color: AppPalette.lavender)),
                    const SizedBox(width: 8),
                    Expanded(child: _Stat(value: '${xp.bestStreak}', label: 'best streak', color: AppPalette.honey)),
                  ],
                ),
              ),
              if (feesPaidIn(apps, DateTime.now().year) case (total: final total, exams: final exams) when exams > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    'Fees paid in ${DateTime.now().year}: ${rupees(total)} for $exams exam${exams == 1 ? '' : 's'}',
                    textAlign: TextAlign.center,
                    style: text.bodySmall,
                  ),
                ),
              const SizedBox(height: 20),
              Text('BADGES', style: muted),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [for (final b in badges) _BadgeTile(badge: b)],
              ),
              const SizedBox(height: 20),
              Text('YOU QUALIFY AS', style: muted),
              const SizedBox(height: 10),
              if (qualifies.isEmpty)
                const MutedNote('Finish your profile to see which jobs you qualify for.')
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final (i, q) in qualifies.indexed)
                      _Tag(q, [AppPalette.periwinkle, AppPalette.sage, AppPalette.honey, AppPalette.lavender][i % 4]),
                  ],
                ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () => openProfileSheet(context, ref),
                      icon: const Icon(Icons.edit_rounded, size: 18),
                      label: Text(profile == null ? 'Set up profile' : 'Edit profile'),
                    ),
                  ),
                  if (profile != null) ...[
                    const SizedBox(width: 8),
                    TextButton(onPressed: () => confirmResetProfile(context, ref), child: const Text('Reset')),
                  ],
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.color});

  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
      child: Column(
        children: [
          Text(value, style: text.headlineSmall?.copyWith(color: color, fontWeight: FontWeight.w900)),
          Text(label, textAlign: TextAlign.center, style: text.labelSmall),
        ],
      ),
    );
  }
}

class _BadgeTile extends StatelessWidget {
  const _BadgeTile({required this.badge});

  final ProfileBadge badge;

  @override
  Widget build(BuildContext context) {
    final b = badge;
    return Tooltip(
      message: b.earned ? '${b.name}: ${b.how}' : 'Still to come: ${b.how}',
      triggerMode: TooltipTriggerMode.tap,
      child: Container(
        width: 58,
        height: 58,
        decoration: BoxDecoration(
          color: b.earned ? b.color.withValues(alpha: AppPalette.current.isLight ? 0.14 : 0.2) : AppPalette.surface,
          borderRadius: BorderRadius.circular(18),
        ),
        child: b.earned
            ? Icon(b.icon, color: b.color, size: 28)
            : Center(
                child: Text('?',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(color: AppPalette.textMuted)),
              ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, this.color);

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: AppPalette.current.isLight ? 0.13 : 0.18),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w800)),
      );
}
