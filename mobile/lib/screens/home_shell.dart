import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/env.dart';
import '../domain/agenda.dart';
import '../domain/relevance.dart';
import '../domain/widget_summary.dart';
import '../models/tracked_application.dart';
import '../providers/account_providers.dart';
import '../providers/agenda_providers.dart';
import '../providers/backup_providers.dart';
import '../providers/jobs_providers.dart';
import '../providers/providers.dart';
import '../services/auth_service.dart';
import '../services/deadline_reminders.dart';
import '../services/notification_service.dart';
import '../services/home_widget.dart';
import '../services/share_intake.dart';
import '../theme/app_theme.dart';
import '../utils/system_actions.dart';
import '../widgets/app_icons.dart';
import '../widgets/motion.dart';
import '../widgets/samsung_sleep_tip.dart';
import '../widgets/shared_job_sheet.dart';
import '../widgets/summit_backdrop.dart';
import '../widgets/summit_trail.dart';
import '../widgets/welcome_sheet.dart';
import 'agenda_screen.dart';
import 'exam_journey_screen.dart';
import 'jobs_screen.dart';
import 'my_exams_screen.dart';
import 'profile_setup_screen.dart';
import 'today_screen.dart';

/// Four tabs: Today (overview or one next step), Jobs (everything that fits you),
/// My exams (lanes by stage), Agenda (what's coming, by date). The paper-cut
/// Summit behind them slides down as you go right: full on Today, gone on Agenda.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(homeTabProvider).clamp(0, SummitHeights.govtTabs.length - 1);
    final jobs = ref.watch(rankedJobsProvider).length;
    final active = ref.watch(activeAppsProvider);
    final needsAction = active.where((a) => a.displayStatus == TrackerStatus.admitCardLive).length;
    final now = ref.watch(nowProvider);
    final today = [for (final i in ref.watch(agendaProvider)) if (i.day == agendaDay(now)) i].length;
    return AccountGate(
      child: Scaffold(
        backgroundColor: AppPalette.background,
        body: Stack(
          children: [
            Positioned.fill(child: SummitBackdrop(height: SummitHeights.govtTabs[tab], orb: tab == 0)),
            SafeArea(
              bottom: false,
              child: TabSwitcher(
                index: tab,
                children: const [TodayScreen(), JobsScreen(), MyExamsScreen(), AgendaScreen()],
              ),
            ),
            // My exams: the Summit trail on the mountain, your exams climbing it.
            Positioned.fill(
              child: SummitTrail(
                show: tab == 2,
                height: SummitHeights.govtTabs[tab],
                climbers: [for (final a in active) (a, laneOf(a, now))],
                lane: ref.watch(examLaneProvider),
                onStop: ref.read(examLaneProvider.notifier).show,
                onClimber: (app) => ExamJourneyScreen.open(context, app),
              ),
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: ref.read(homeTabProvider.notifier).show,
          backgroundColor: AppPalette.surface,
          indicatorColor: AppPalette.periwinkle.withValues(alpha: 0.22),
          destinations: [
            const NavigationDestination(
              icon: DuoIcon(AppIcon.nextStep),
              selectedIcon: DuoIcon(AppIcon.nextStep),
              label: 'Today',
            ),
            NavigationDestination(
              icon: Badge(
                  isLabelVisible: jobs > 0,
                  label: Text('$jobs'),
                  child: const DuoIcon(AppIcon.experience)),
              selectedIcon: const DuoIcon(AppIcon.experience),
              label: 'Jobs',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: needsAction > 0,
                label: Text('$needsAction'),
                child: const DuoIcon(AppIcon.answerKey),
              ),
              selectedIcon: const DuoIcon(AppIcon.answerKey),
              label: 'My exams',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: today > 0,
                label: Text('$today'),
                child: const DuoIcon(AppIcon.examDay),
              ),
              selectedIcon: const DuoIcon(AppIcon.examDay),
              label: 'Agenda',
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Account actions (used by Settings and the start-up flow)
// -----------------------------------------------------------------------------

Future<void> signInWithGoogle(BuildContext context, WidgetRef ref) async {
  final container = ProviderScope.containerOf(context, listen: false);
  try {
    final message = await signInAndRestore(container);
    if (message != null && context.mounted) showCalmSnack(context, message);
  } on AuthException catch (e) {
    if (!e.cancelled && context.mounted) showCalmSnack(context, e.message);
  } catch (e) {
    // Say what it was, so it can be fixed.
    debugPrint('Sign-in failed: $e');
    if (context.mounted) {
      showErrorSnack(context, 'Couldn’t sign in right now (${GoogleAccountService.describe(e)}). Try again in a moment.');
    }
  }
}

Future<void> openProfileSheet(BuildContext context, WidgetRef ref) => showProfileSetupSheet(
      context,
      initial: ref.read(profileProvider).dataOrNull,
      suggestedName: ref.read(googleAccountProvider).dataOrNull?.name,
    );

/// The exam watcher runs every ~4 h in the background; battery optimisation
/// (aggressive on Samsung/Xiaomi) can postpone it for many hours. One system
/// dialog turns that off for this app only; Samsung also needs its sleep list.
Future<void> allowBackgroundChecks(BuildContext context) async {
  final samsung = await isSamsungPhone();
  try {
    if (await Permission.ignoreBatteryOptimizations.isGranted) {
      if (!context.mounted) return;
      if (samsung) {
        await showSamsungSleepTip(context);
      } else {
        showCalmSnack(context, 'Background checks are already allowed.');
      }
      return;
    }
    final status = await Permission.ignoreBatteryOptimizations.request();
    if (!context.mounted) return;
    if (samsung) {
      await showSamsungSleepTip(context);
      return;
    }
    showCalmSnack(
      context,
      status.isGranted
          ? 'Done. Exam updates will be checked every few hours.'
          : 'Not changed. Updates still arrive, just less often.',
    );
  } catch (_) {
    if (context.mounted) showCalmSnack(context, 'This phone doesn’t offer that setting.');
  }
}

/// Start-up, in order and never blocking the screen: the one-time welcome (sign
/// in to restore or start a backup), the profile sheet if it's missing,
/// notification permission, the Samsung tip, then the exam watcher and backup.
class AccountGate extends ConsumerStatefulWidget {
  const AccountGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AccountGate> createState() => _AccountGateState();
}

class _AccountGateState extends ConsumerState<AccountGate> {
  static const _welcomeKey = 'welcome.seen';

  bool _startupDone = false;
  bool _promptedThisSession = false;
  bool _askingAccountChoice = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual<AccountStatus>(accountStatusProvider, (_, status) {
      if (_startupDone && status == AccountStatus.needsProfile) _promptProfile();
    });
    ref.listenManual<BackupState>(backupControllerProvider, (_, backup) {
      final to = backup.accountSwitchTo;
      if (to != null && !_askingAccountChoice) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _askAccountChoice(to));
      }
    });
    ref.listenManual<List<RankedJob>>(rankedJobsProvider, (_, __) => _syncReminders());
    // The home-screen widget follows the Agenda (unchanged text isn't written again).
    ref.listenManual(agendaProvider, fireImmediately: true, (_, items) {
      unawaited(HomeWidget.write(widgetSummary(items, DateTime.now())).catchError((_) {}));
    });
    // Paid, or marked not paid: its form reminder follows.
    ref.listenManual(activeAppsProvider, (_, apps) {
      unawaited(FormReminders.sync(apps, now: DateTime.now()).catchError((_) => const <String>[]));
    });
    NotificationService.openInApp.addListener(_openFromNotification);
    ShareIntake.incoming.addListener(_openShared);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startup());
  }

  Timer? _reminderDebounce;

  @override
  void dispose() {
    _reminderDebounce?.cancel();
    NotificationService.openInApp.removeListener(_openFromNotification);
    ShareIntake.incoming.removeListener(_openShared);
    super.dispose();
  }

  /// A job shared from WhatsApp, Telegram or the browser: find it.
  void _openShared() {
    final shared = ShareIntake.incoming.value;
    if (shared == null || !mounted || !_startupDone) return;
    ShareIntake.incoming.value = null;
    showSharedJobSheet(context, shared);
  }

  /// The morning summary opens the Agenda (jobs by closing day).
  void _openFromNotification() {
    final place = NotificationService.openInApp.value;
    if (place == null || !mounted) return;
    NotificationService.openInApp.value = null;
    if (place == 'agenda') ref.read(homeTabProvider.notifier).show(3);
  }

  /// A swipe, a restore or a new job list: update last-day reminders shortly after.
  void _syncReminders() {
    _reminderDebounce?.cancel();
    _reminderDebounce = Timer(const Duration(seconds: 2), () async {
      if (!mounted || ref.read(feedProvider).dataOrNull == null) return;
      final jobs = [for (final r in ref.read(rankedJobsProvider)) r.item];
      try {
        await DeadlineReminders(ref.read(databaseProvider)).sync(jobs, now: DateTime.now());
      } catch (_) {}
    });
  }

  Future<void> _startup() async {
    await _welcomeOnce();
    if (!mounted) return;
    await ref.read(profileProvider.future);
    if (!mounted) return;
    _startupDone = true;
    if (ref.read(accountStatusProvider) == AccountStatus.needsProfile) _promptProfile();
    await _askNotificationsOnce();
    await _samsungTipOnce();
    unawaited(NotificationService.openLaunchLink()); // a notification tap opened the app
    unawaited(ShareIntake.init().then((_) => _openShared())); // a shared job opened the app
    unawaited(ref.read(trackedAppsProvider.notifier).checkForUpdates()); // throttled
    unawaited(ref.read(backupControllerProvider.notifier).syncIfDue());
  }

  Future<void> _welcomeOnce() async {
    if (!Env.canSignIn) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_welcomeKey) ?? false) return;
      await prefs.setBool(_welcomeKey, true);
      final user = await ref.read(googleAccountProvider.future);
      if (user != null || !mounted) return;
      await showWelcomeSheet(context);
    } catch (_) {
      // The welcome is a convenience: never let it block start-up.
    }
  }

  void _promptProfile() {
    if (_promptedThisSession || !mounted) return;
    _promptedThisSession = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) openProfileSheet(context, ref);
    });
  }

  /// Signed in with a different Google account than the one this phone's data
  /// was backed up to: merge, or replace this phone's data with that account's.
  Future<void> _askAccountChoice(String email) async {
    if (_askingAccountChoice || !mounted) return;
    _askingAccountChoice = true;
    final merge = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppPalette.surface,
        title: const Text('Different Google account'),
        content: Text('The exams on this phone were backed up with another Google account. '
            'What should happen now that you’re signed in as $email?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Start fresh from its backup'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Merge into this account'),
          ),
        ],
      ),
    );
    _askingAccountChoice = false;
    if (merge == null || !mounted) return;
    final outcome = await ref.read(backupControllerProvider.notifier).resolveAccountSwitch(merge: merge);
    if (outcome != null && mounted) showCalmSnack(context, restoreMessage(outcome));
  }

  /// Notifications from the exam watcher need this on Android 13+. Asked once.
  Future<void> _askNotificationsOnce() async {
    const key = 'perm.notificationsAsked';
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(key) ?? false) return;
      await prefs.setBool(key, true);
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
    } catch (_) {
      // Unsupported platform or plugin missing: notifications are optional.
    }
  }

  /// Once, as soon as there is an exam to watch: Samsung's app sleeping would
  /// otherwise pause the checks after a few days without opening the app.
  Future<void> _samsungTipOnce() async {
    const key = 'tip.samsungSleepShown';
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(key) ?? false) return;
      final tracked = await ref.read(trackedAppsProvider.future);
      if (tracked.isEmpty || !await isSamsungPhone() || !mounted) return;
      await prefs.setBool(key, true);
      if (mounted) await showSamsungSleepTip(context);
    } catch (_) {
      // A tip, not a requirement.
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
