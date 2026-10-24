import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:self_update/self_update.dart';

import '../config/env.dart';
import '../domain/subjects.dart';
import '../domain/requirements.dart';
import '../models/job_preferences.dart';
import '../models/user_profile.dart';
import '../providers/account_providers.dart';
import '../providers/backup_providers.dart';
import '../providers/jobs_providers.dart';
import '../providers/pin_providers.dart';
import '../providers/providers.dart';
import '../providers/ui_providers.dart';
import '../providers/workspace_providers.dart';
import '../services/auth_service.dart';
import '../services/auto_update.dart';
import '../services/calendar_sync_service.dart';
import '../services/deadline_reminders.dart';
import '../services/fx.dart';
import '../services/notification_service.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../utils/system_actions.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import '../widgets/one_line.dart';
import '../widgets/pin_dialog.dart';
import '../widgets/review_sheet.dart';
import '../widgets/samsung_sleep_tip.dart';
import '../widgets/share_app.dart';
import '../widgets/update_dialog.dart';
import 'home_shell.dart';
import 'self_check_screen.dart';

enum SettingsTab {
  account('Account'),
  profile('Profile'),
  jobs('Jobs'),
  settings('Settings'),
  about('About');

  const SettingsTab(this.label);
  final String label;
}

String get kHomePage => Env.homePageUrl;
String get kPrivacyPolicy => '${Env.homePageUrl}privacy.html';
String get kIssues => '${Env.repoUrl}/issues';

/// Account & settings, one page per topic.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, this.initialTab = SettingsTab.account});

  final SettingsTab initialTab;

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: SettingsTab.values.length,
        initialIndex: initialTab.index,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Account & settings'),
            bottom: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              indicatorColor: AppPalette.periwinkle,
              labelColor: AppPalette.textPrimary,
              unselectedLabelColor: AppPalette.textMuted,
              dividerColor: AppPalette.outline,
              tabs: [for (final t in SettingsTab.values) Tab(text: t.label)],
            ),
          ),
          body: const TabBarView(
            children: [_AccountTab(), _ProfileTab(), _JobsTab(), _SettingsTab(), _AboutTab()],
          ),
        ),
      );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.note});

  final String title;
  final String? note;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppPalette.surface,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: AppPalette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.titleMedium),
          if (note != null) ...[
            const SizedBox(height: 4),
            Text(note!, style: text.bodySmall),
          ],
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Account
// -----------------------------------------------------------------------------

class _AccountTab extends ConsumerWidget {
  const _AccountTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(googleAccountProvider).dataOrNull;
    final backup = ref.watch(backupControllerProvider);
    final now = ref.watch(nowProvider);
    final text = Theme.of(context).textTheme;
    final backups = ref.read(backupControllerProvider.notifier);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Section(
          title: 'Google account',
          note: 'Backs up to your own Google Drive.',
          children: [
            if (!Env.canSignIn)
              const MutedNote('Backup isn’t set up in this build.')
            else if (user == null) ...[
              const MutedNote('Not signed in. Everything stays on this phone only.'),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => signInWithGoogle(context, ref),
                icon: const DuoIcon(AppIcon.login),
                label: const Text('Sign in with Google'),
              ),
            ] else ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: AccountPhoto(user, style: text.titleMedium),
                title: Text(user.name ?? user.email),
                subtitle: Text(user.email),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  DuoIcon(
                    backup.phase == BackupPhase.idle ? AppIcon.backupDone : AppIcon.backupSyncing,
                    size: 18,
                    color: AppPalette.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(backupStatusLabel(backup, now), style: text.bodySmall)),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (backup.phase == BackupPhase.needsPermission)
                    FilledButton(
                      onPressed: () async {
                        try {
                          await backups.allowDrive();
                        } on AuthException catch (e) {
                          if (!e.cancelled && context.mounted) showCalmSnack(context, e.message);
                        }
                      },
                      child: const Text('Allow Drive backup'),
                    )
                  else
                    FilledButton.tonal(
                      onPressed: () async {
                        final outcome = await backups.sync();
                        if (!context.mounted) return;
                        showCalmSnack(
                          context,
                          outcome != null
                              ? 'Backed up to your Google Drive.'
                              : backupStatusLabel(ref.read(backupControllerProvider), DateTime.now()),
                        );
                      },
                      child: const Text('Back up now'),
                    ),
                  OutlinedButton(
                    onPressed: () async {
                      await ref.read(googleAccountProvider.notifier).signOut();
                      if (context.mounted) {
                        showCalmSnack(context, 'Signed out. Your data stays on this phone.');
                      }
                    },
                    child: const Text('Sign out'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Profile
// -----------------------------------------------------------------------------

/// "Reset profile", after a confirmation (Settings › Profile and the profile page).
Future<void> confirmResetProfile(BuildContext context, WidgetRef ref) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      backgroundColor: AppPalette.surface,
      title: const Text('Reset your profile?'),
      content: const Text('Your name, date of birth, category, qualifications and experience are cleared, '
          'and the app asks for them again. Tracked exams, saved IDs and settings stay.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reset')),
      ],
    ),
  );
  if (ok != true) return;
  await ref.read(profileProvider.notifier).reset();
  if (context.mounted) showCalmSnack(context, 'Profile reset.');
}

class _ProfileTab extends ConsumerWidget {
  const _ProfileTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The Private workspace has its own profile, apart from this one.
    final privatePage = ref.watch(privateProfilePageProvider);
    if (privatePage != null && ref.watch(workspaceProvider).shown == Workspace.private) {
      return privatePage(context);
    }
    final profile = ref.watch(profileProvider).dataOrNull;
    final now = ref.watch(nowProvider);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Section(
          title: 'Your profile',
          children: [
            if (profile == null)
              const MutedNote('No profile yet.')
            else ...[
              _Fact('Name', profile.displayName),
              _Fact('Age', '${ageOn(profile.dateOfBirth, now)} years'),
              _Fact('Category', profile.category.label),
              _Fact('Qualification', profile.qualificationLabel),
              for (final c in subjectsFromProfile(profile).values)
                _Fact(subjectGroup(c.group)!.label, subjectSummary(c)),
              _Fact('Experience', experienceLabel(profile.experienceYears)),
              if (profile.isPwbd) const _Fact('PwBD', 'Yes'),
              if (profile.isExServiceman)
                _Fact('Ex-serviceman', '${profile.exServicemanServiceYears} years of service'),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => openProfileSheet(context, ref),
                  icon: const Icon(Icons.edit_rounded, size: 18),
                  label: Text(profile == null ? 'Set up profile' : 'Edit profile'),
                ),
                if (profile != null)
                  TextButton.icon(
                    onPressed: () => confirmResetProfile(context, ref),
                    icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    label: const Text('Reset profile'),
                  ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 120, child: Text(label, style: text.bodyMedium?.copyWith(color: AppPalette.textMuted))),
          Expanded(child: Text(value, style: text.bodyMedium)),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Jobs: what to show and in which order
// -----------------------------------------------------------------------------

const _typeLabels = {
  'permanent': 'Permanent',
  'contract': 'Contract',
  'apprenticeship': 'Apprenticeship',
  'fellowship': 'Fellowship',
  'internship': 'Internship',
};

class _JobsTab extends ConsumerWidget {
  const _JobsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(jobPreferencesProvider).dataOrNull ?? JobPreferences.defaults;
    final fromProfile = qualificationsFromProfile(ref.watch(profileProvider).dataOrNull);
    final decisions = ref.watch(decisionsProvider).dataOrNull ?? const <JobDecision>[];
    final applied = decisions.where((d) => d.applied).length;
    void save(JobPreferences p) => ref.read(jobPreferencesProvider.notifier).save(p);
    Set<T> toggle<T>(Set<T> set, T value) => set.contains(value) ? ({...set}..remove(value)) : {...set, value};

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (Env.privateJobsAvailable) const _PrivateJobsSwitch(),
        _Section(
          title: 'Show these first',
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in JobCategory.values)
                  FilterChip(
                    label: Text(c.label),
                    selected: prefs.preferred.contains(c),
                    onSelected: (_) => save(prefs.copyWith(
                      preferred: toggle(prefs.preferred, c),
                      hidden: {...prefs.hidden}..remove(c),
                    )),
                  ),
              ],
            ),
          ],
        ),
        _Section(
          title: 'Never show',
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in JobCategory.values)
                  FilterChip(
                    label: Text(c.label),
                    selected: prefs.hidden.contains(c),
                    selectedColor: AppPalette.terracotta.withValues(alpha: 0.2),
                    onSelected: (_) => save(prefs.copyWith(
                      hidden: toggle(prefs.hidden, c),
                      preferred: {...prefs.preferred}..remove(c),
                    )),
                  ),
              ],
            ),
          ],
        ),
        _Section(
          title: 'Filters',
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: prefs.hideBelowMyLevel,
              onChanged: (v) => save(prefs.copyWith(hideBelowMyLevel: v)),
              title: const Text('Hide jobs that only need 10th pass'),
              subtitle: const Text('For graduates: peon, chowkidar, gardener, MTS and similar posts.'),
            ),
            const SizedBox(height: 8),
            Text(
              prefs.minMonthlyPay == 0 ? 'Any pay' : 'At least ₹${prefs.minMonthlyPay ~/ 1000}k a month',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            Slider(
              value: prefs.minMonthlyPay.toDouble(),
              max: 100000,
              divisions: 20,
              label: prefs.minMonthlyPay == 0 ? 'Any' : '₹${prefs.minMonthlyPay ~/ 1000}k',
              onChanged: (v) => save(prefs.copyWith(minMonthlyPay: v.round())),
            ),
            const MutedNote('Jobs that don’t state their pay are always kept.'),
            const SizedBox(height: 12),
            Text('Hide these job types', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final MapEntry(key: type, value: label) in _typeLabels.entries)
                  FilterChip(
                    label: Text(label),
                    selected: prefs.hiddenTypes.contains(type),
                    onSelected: (_) => save(prefs.copyWith(hiddenTypes: toggle(prefs.hiddenTypes, type))),
                  ),
              ],
            ),
          ],
        ),
        _Section(
          title: 'Professional qualifications',
          note: 'Jobs needing one you don’t have are hidden.',
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in Profession.values)
                  FilterChip(
                    label: Text(p.label),
                    selected: prefs.qualifications.contains(p.key) || fromProfile.contains(p.key),
                    // From your profile: change the degree there instead.
                    onSelected: fromProfile.contains(p.key)
                        ? null
                        : (_) => save(prefs.copyWith(qualifications: toggle(prefs.qualifications, p.key))),
                  ),
              ],
            ),
          ],
        ),
        _Section(
          title: 'Languages you can work in',
          note: 'Jobs needing another language are hidden.',
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final lang in kIndianLanguages)
                  FilterChip(
                    label: Text(lang),
                    selected: prefs.languages.contains(lang),
                    onSelected: (_) => save(prefs.copyWith(languages: toggle(prefs.languages, lang))),
                  ),
              ],
            ),
          ],
        ),
        _Section(
          title: 'Learning from your choices',
          children: [
            Text('Learned from $applied applied and ${decisions.length - applied} not-for-me.',
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: decisions.isEmpty
                  ? null
                  : () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          backgroundColor: AppPalette.surface,
                          title: const Text('Start learning again?'),
                          content: const Text('Jobs you hid come back, and ranking forgets your history. '
                              'Your tracked exams are not touched.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reset')),
                          ],
                        ),
                      );
                      if (ok != true) return;
                      for (final d in decisions) {
                        await ref.read(decisionsProvider.notifier).undo(d.jobPostId);
                      }
                    },
              child: const Text('Reset'),
            ),
          ],
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Settings: look, sounds, alerts and the PIN lock on one page
// -----------------------------------------------------------------------------

class _SettingsTab extends ConsumerWidget {
  const _SettingsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Section(
          title: 'Appearance',
          children: [
            SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                    value: ThemeMode.system, icon: Icon(Icons.brightness_auto_rounded), label: OneLine('Phone')),
                ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_rounded), label: OneLine('Light')),
                ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_rounded), label: OneLine('Dark')),
              ],
              selected: {mode},
              onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).set(s.first),
            ),
          ],
        ),
        const _Section(
          title: 'Sounds & vibration',
          note: 'Sounds play only when your phone is on ring.',
          children: [_FxSwitches()],
        ),
        ..._alertSections(context),
        const _PinLockSection(),
      ],
    );
  }
}

class _FxSwitches extends StatefulWidget {
  const _FxSwitches();

  @override
  State<_FxSwitches> createState() => _FxSwitchesState();
}

class _FxSwitchesState extends State<_FxSwitches> {
  @override
  Widget build(BuildContext context) => Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: Fx.sound,
            onChanged: (on) async {
              await Fx.setSound(on);
              if (mounted) setState(() {});
            },
            title: const Text('Sounds'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: Fx.vibration,
            onChanged: (on) async {
              await Fx.setVibration(on);
              if (mounted) setState(() {});
            },
            title: const Text('Vibration'),
          ),
        ],
      );
}

List<Widget> _alertSections(BuildContext context) => [
      const _Section(
        title: 'Reminders',
        note: 'Your exams’ updates ring. Closing jobs come in one quiet morning summary.',
        children: [_LastDaySwitch(), _QuietNightsSwitch()],
      ),
      const _Section(
        title: 'Calendar',
        children: [_CalendarAutoSwitch()],
      ),
      _Section(
        title: 'Exam updates',
        note: 'Checks for admit cards, dates and results.',
        children: [
          FilledButton.tonal(
            onPressed: () => allowBackgroundChecks(context),
            child: const Text('Allow background checks'),
          ),
          const SizedBox(height: 8),
          FutureBuilder<bool>(
            future: isSamsungPhone(),
            builder: (context, snap) => snap.data == true
                ? TextButton(
                    onPressed: () => showSamsungSleepTip(context),
                    child: const Text('Samsung: keep the app awake'),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
      const _Section(
        title: 'Notifications',
        note: 'Turn them on in Android settings if you said no earlier.',
        children: [
          OutlinedButton(onPressed: openAppSettings, child: Text('Open app settings')),
        ],
      ),
    ];

// -----------------------------------------------------------------------------
// About
// -----------------------------------------------------------------------------

class _AboutTab extends ConsumerWidget {
  const _AboutTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Section(
          title: 'JobSummit',
          note: 'One clear next step. Less to keep in mind.',
          children: [
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snap) => Text(
                snap.hasData ? 'Version ${snap.data!.version}' : 'Version …',
                style: text.bodyMedium,
              ),
            ),
            const SizedBox(height: 12),
            if (Env.updatesEnabled)
              FilledButton.tonal(
                onPressed: () async {
                  final service = ref.read(updateServiceProvider);
                  try {
                    final check = await service.checkNow();
                    if (!context.mounted) return;
                    if (check == null) {
                      showCalmSnack(context, 'You have the latest version.');
                    } else {
                      await showUpdateDialog(context, service, check);
                    }
                  } on UpdateCheckFailed {
                    if (context.mounted) {
                      showErrorSnack(context, 'Couldn’t reach GitHub to check. Try again in a minute.');
                    }
                  }
                },
                child: const Text('Check for updates'),
              ),
            if (Env.updatesEnabled) ...[
              const SizedBox(height: 8),
              const _AutoUpdateSwitch(),
            ],
            const SizedBox(height: 8),
            const ShareAppButton(),
          ],
        ),
        _Section(
          title: 'Links',
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.home_outlined),
              title: const Text('Home page'),
              onTap: () => openExternal(context, kHomePage),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('Privacy policy'),
              onTap: () => openExternal(context, kPrivacyPolicy),
            ),
            // Test builds only: a tool for finding faults, not part of the app.
            if (kDebugMode)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.health_and_safety_outlined),
                title: const Text('Self-check'),
                subtitle: const Text('Test sign-in, saving, the job list and reminders'),
                onTap: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SelfCheckScreen())),
              ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.rate_review_outlined),
              title: const Text('Send a review'),
              subtitle: const Text('Tell us what to fix or add'),
              onTap: () => showReviewSheet(context),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('Report a problem'),
              onTap: () => openExternal(context, kIssues),
            ),
          ],
        ),
      ],
    );
  }
}

class _LastDaySwitch extends ConsumerStatefulWidget {
  const _LastDaySwitch();

  @override
  ConsumerState<_LastDaySwitch> createState() => _LastDaySwitchState();
}

class _LastDaySwitchState extends ConsumerState<_LastDaySwitch> {
  bool? _on;

  @override
  void initState() {
    super.initState();
    LastDayAlerts.enabled().then((v) {
      if (mounted) setState(() => _on = v);
    });
  }

  Future<void> _set(bool on) async {
    setState(() => _on = on);
    await LastDayAlerts.setEnabled(on);
    final jobs = [for (final r in ref.read(rankedJobsProvider)) r.item];
    await DeadlineReminders(ref.read(databaseProvider)).sync(jobs, now: DateTime.now(), enabled: on, notify: false);
    if (mounted) {
      showCalmSnack(context, on ? 'Morning summary is on.' : 'Morning summary is off.');
    }
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _on ?? true,
        onChanged: _on == null ? null : _set,
        title: const Text('Morning summary of closing jobs'),
      );
}

class _QuietNightsSwitch extends StatefulWidget {
  const _QuietNightsSwitch();

  @override
  State<_QuietNightsSwitch> createState() => _QuietNightsSwitchState();
}

class _QuietNightsSwitchState extends State<_QuietNightsSwitch> {
  bool? _on;

  @override
  void initState() {
    super.initState();
    QuietNights.enabled().then((v) {
      if (mounted) setState(() => _on = v);
    });
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _on ?? true,
        onChanged: _on == null
            ? null
            : (on) async {
                setState(() => _on = on);
                await QuietNights.setEnabled(on);
              },
        title: const Text('Quiet at night (10 PM – 7 AM)'),
      );
}

class _CalendarAutoSwitch extends ConsumerStatefulWidget {
  const _CalendarAutoSwitch();

  @override
  ConsumerState<_CalendarAutoSwitch> createState() => _CalendarAutoSwitchState();
}

class _CalendarAutoSwitchState extends ConsumerState<_CalendarAutoSwitch> {
  bool? _on;

  @override
  void initState() {
    super.initState();
    CalendarAutoSync.enabled().then((v) {
      if (mounted) setState(() => _on = v);
    });
  }

  Future<void> _set(bool on) async {
    setState(() => _on = on);
    final calendar = ref.read(calendarSyncProvider);
    if (on && !await calendar.ensurePermission()) {
      if (!mounted) return;
      setState(() => _on = false);
      showErrorSnack(context, 'Calendar access is off. Allow it in Settings → Apps → JobSummit → Permissions.');
      return;
    }
    await CalendarAutoSync.setEnabled(on);
    if (!on) {
      if (mounted) showCalmSnack(context, 'New exams won’t be added. Events already in your calendar stay.');
      return;
    }
    final apps = ref.read(trackedAppsProvider).dataOrNull ?? const [];
    final added = await calendar.syncAll(apps);
    await ref.read(trackedAppsProvider.notifier).reload();
    if (!mounted) return;
    Fx.done();
    showCalmSnack(
        context,
        added == 0
            ? 'On. Exams you track from now on go into your calendar.'
            : 'Added $added exam${added == 1 ? '' : 's'} to your calendar, with reminders.');
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _on ?? false,
        onChanged: _on == null ? null : _set,
        title: const Text('Add my exams to the calendar'),
      );
}

/// "Update automatically": on by default. The line under it says what will
/// actually happen on this phone.
class _AutoUpdateSwitch extends ConsumerStatefulWidget {
  const _AutoUpdateSwitch();

  @override
  ConsumerState<_AutoUpdateSwitch> createState() => _AutoUpdateSwitchState();
}

class _AutoUpdateSwitchState extends ConsumerState<_AutoUpdateSwitch> {
  bool? _on;
  SelfUpdateStatus? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final on = await AutoUpdater.isEnabled();
    SelfUpdateStatus? status;
    try {
      status = await AutoUpdater(ref.read(updateServiceProvider)).status();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _on = on;
      _status = status;
    });
  }

  String _explain(SelfUpdateStatus? s) {
    if (s == null) return 'New versions download on Wi-Fi.';
    if (!s.canInstall) return 'First allow it: Settings → Apps → JobSummit → Install unknown apps → Allow.';
    if (s.sdk < 31) return 'New versions download on Wi-Fi, then you tap “Update” once.';
    if (!s.selfInstalled) {
      return 'New versions download on Wi-Fi. The next one asks you once; after that they install by '
          'themselves while you’re not using the app.';
    }
    return 'New versions download on Wi-Fi and install by themselves while you’re not using the app.';
  }

  @override
  Widget build(BuildContext context) {
    final on = _on;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Update automatically'),
      subtitle: Text(on == false ? 'You’ll be asked when a new version is out.' : _explain(_status)),
      value: on ?? true,
      onChanged: on == null
          ? null
          : (value) async {
              await AutoUpdater.setEnabled(value);
              if (mounted) setState(() => _on = value);
            },
    );
  }
}

/// Optional 4-digit PIN in front of saved Reg/Roll numbers and passwords.
class _PinLockSection extends ConsumerWidget {
  const _PinLockSection();

  /// The same four digits twice; null if cancelled or they differ.
  static Future<String?> _newPin(BuildContext context) async {
    final first = await askForPin(context, title: 'Choose a 4-digit PIN', offerForgot: false);
    if (first is! PinTyped || !context.mounted) return null;
    final again = await askForPin(context, title: 'Enter it again', offerForgot: false);
    if (again is! PinTyped || !context.mounted) return null;
    if (again.pin != first.pin) {
      showCalmSnack(context, 'The PINs didn’t match. Try again.');
      return null;
    }
    return first.pin;
  }

  /// Asks for the current PIN; true when it was right.
  static Future<bool> _current(BuildContext context, WidgetRef ref, String why) async {
    final entry = await askForPin(context, title: 'Enter your PIN', message: why);
    if (entry == null || !context.mounted) return false;
    if (entry is PinForgot) {
      await confirmForgotPin(context, ref);
      return false;
    }
    final result = await ref.read(pinLockProvider.notifier).unlock((entry as PinTyped).pin);
    if (!context.mounted) return false;
    switch (result) {
      case PinOk():
        return true;
      case PinWrong(:final triesLeft):
        showCalmSnack(context, 'Wrong PIN. $triesLeft ${triesLeft == 1 ? 'try' : 'tries'} left.');
      case PinWait():
        showCalmSnack(context, 'Too many tries. Wait 30 seconds.');
    }
    return false;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pin = ref.watch(pinLockProvider).dataOrNull;
    final lock = ref.read(pinLockProvider.notifier);
    return _Section(
      title: 'PIN lock',
      note: 'Hides your IDs and passwords behind a PIN.',
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Lock saved IDs with a PIN'),
          value: pin?.enabled ?? false,
          onChanged: pin == null
              ? null
              : (on) async {
                  if (on) {
                    final newPin = await _newPin(context);
                    if (newPin == null) return;
                    await lock.enable(newPin);
                    if (context.mounted) showCalmSnack(context, 'PIN set. Your IDs are locked.');
                  } else if (await _current(context, ref, 'To turn the lock off.')) {
                    await ref.read(secretStoreProvider).clearPin();
                    ref.invalidate(pinLockProvider);
                    if (context.mounted) showCalmSnack(context, 'PIN lock is off.');
                  }
                },
        ),
        if (pin?.enabled ?? false)
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: () async {
                  if (!await _current(context, ref, 'Your current PIN first.') || !context.mounted) return;
                  final newPin = await _newPin(context);
                  if (newPin == null) return;
                  await lock.enable(newPin);
                  if (context.mounted) showCalmSnack(context, 'PIN changed.');
                },
                child: const Text('Change PIN'),
              ),
              TextButton(
                onPressed: () {
                  lock.lock();
                  showCalmSnack(context, 'Locked.');
                },
                child: const Text('Lock now'),
              ),
            ],
          ),
      ],
    );
  }
}

/// Settings › Jobs: switches the Private (corporate) jobs workspace on or off. Off,
/// the app is the Govt exam tracker only, exactly as before.
class _PrivateJobsSwitch extends ConsumerWidget {
  const _PrivateJobsSwitch();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ws = ref.watch(workspaceProvider);
    return _Section(
      title: 'Private jobs (beta)',
      note: 'A second workspace for company jobs.',
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Show the Govt | Private switch'),
          value: ws.privateEnabled,
          onChanged: (on) => ref.read(workspaceProvider.notifier).setPrivateEnabled(on),
        ),
      ],
    );
  }
}
