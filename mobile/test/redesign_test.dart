import 'package:exam_tracker/domain/agenda.dart';
import 'package:exam_tracker/domain/next_step.dart';
import 'package:exam_tracker/domain/urgency.dart';
import 'package:exam_tracker/domain/xp.dart';
import 'package:exam_tracker/models/exam_timeline.dart';
import 'package:exam_tracker/models/feed.dart';
import 'package:exam_tracker/models/tracked_application.dart';
import 'package:exam_tracker/screens/my_exams_screen.dart';
import 'package:exam_tracker/services/auth_service.dart';
import 'package:exam_tracker/theme/app_theme.dart';
import 'package:exam_tracker/widgets/pill_toggle.dart';
import 'package:exam_tracker/widgets/summit_backdrop.dart';
import 'package:exam_tracker/widgets/summit_trail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime(2026, 10, 17, 10); // a Saturday morning

TrackedApplication exam(String id,
        {String? name,
        Map<String, dynamic> t = const {},
        TrackerStatus? watcher,
        bool archived = false,
        DateTime? examAt}) =>
    TrackedApplication(
      id: id,
      examName: name ?? 'Exam $id',
      postName: 'Post $id',
      status: ApplicationStatus.applied,
      examAt: examAt,
      archived: archived,
      watcherStatus: watcher,
      createdAt: DateTime(2026, 9),
      updatedAt: DateTime(2026, 9),
      timeline: ExamTimeline.fromJson({'job_post_id': id, ...t}),
    );

FeedItem job(String id, DateTime deadline) => FeedItem(
      jobPostId: id,
      organization: 'NEHU',
      examName: 'Recruitment',
      deadline: deadline,
      urgency: Urgency.info,
      nextStep: '',
      bestPost: FeedPost(
        postDetailId: id,
        postName: 'Project Technical Support-III',
        categoryQuotaSeats: 0,
        urOpenSeats: 3,
        totalReachableSeats: 3,
        eligibleViaRelaxation: false,
        notes: const [],
      ),
    );

void main() {
  group('Agenda', () {
    test('last days of jobs and the dates of tracked exams, soonest first', () {
      final items = buildAgenda(
        tracked: [
          exam('cgl', t: {'answer_key_release': '2026-11-06', 'result_date': '2026-12-20'}),
          exam('po', examAt: DateTime(2026, 10, 21, 9)),
          exam('old', examAt: DateTime(2026, 10, 25), archived: true),
        ],
        jobs: [job('nehu', DateTime(2026, 10, 19, 23, 59)), job('gone', DateTime(2026, 10, 10))],
        now: now,
      );
      expect([for (final i in items) (i.kind, i.title)], [
        (AgendaKind.deadline, 'Project Technical Support-III'),
        (AgendaKind.exam, 'Exam po'),
        (AgendaKind.answerKey, 'Exam cgl'),
        (AgendaKind.result, 'Exam cgl'),
      ]);
      expect(items.first.tag, 'Last day');
    });

    test('an exam window that has started stays on today until it ends', () {
      final items = buildAgenda(
        tracked: [exam('cgl', t: {'exam_start': '2026-09-30', 'exam_end': '2026-10-30'})],
        jobs: const [],
        now: now,
      );
      expect(items.single.day, agendaDay(now));
      expect(items.single.subtitle, 'Exam window open until 30 Oct');
    });

    test('the admit card date drops off once the card is out', () {
      final t = {'admit_card_release': '2026-10-20'};
      expect(buildAgenda(tracked: [exam('a', t: t)], jobs: const [], now: now).single.kind, AgendaKind.admitCard);
      expect(
        buildAgenda(tracked: [exam('a', t: t, watcher: TrackerStatus.admitCardLive)], jobs: const [], now: now),
        isEmpty,
      );
    });

    test('Week buckets: today, tomorrow, other days this week, then Later', () {
      final items = buildAgenda(
        tracked: [exam('po', examAt: DateTime(2026, 10, 21, 9)), exam('far', examAt: DateTime(2026, 11, 20))],
        jobs: [job('a', DateTime(2026, 10, 17, 18)), job('b', DateTime(2026, 10, 18, 12))],
        now: now,
      );
      final buckets = weekBuckets(items, now);
      expect([for (final b in buckets) b.label], ['Today · Sat 17', 'Tomorrow · Sun 18', 'Wed 21', 'Later']);
      expect(buckets.last.items.single.title, 'Exam far');
    });
  });

  test('lanes: each exam stands at its stage; finished ones under Result', () {
    expect(laneOf(exam('a'), now), 0); // applied, waiting for the admit card
    expect(laneOf(exam('b', watcher: TrackerStatus.admitCardLive), now), 1);
    expect(laneOf(exam('c', t: {'exam_start': '2026-09-30', 'exam_end': '2026-10-30'}), now), 1); // on now
    expect(laneOf(exam('w', t: {'exam_start': '2026-09-01', 'exam_end': '2026-09-10'}), now), 2); // written
    expect(laneOf(exam('k', watcher: TrackerStatus.answerKeyLive), now), 3);
    expect(laneOf(exam('d', watcher: TrackerStatus.resultDeclared), now), 4);
    expect(kLanes, hasLength(5));
  });

  test('Focus: every pending step, most urgent first, with stable ids', () {
    final steps = computeNextSteps(
      tracked: [exam('po', examAt: DateTime(2026, 10, 21, 9))],
      feed: [job('late', DateTime(2026, 10, 30)), job('soon', DateTime(2026, 10, 19))],
      now: now,
    );
    expect([for (final s in steps) s.id], ['apply:soon', 'prepareForExam:po', 'apply:late']);
    expect(computeNextStep(tracked: const [], feed: [job('soon', DateTime(2026, 10, 19))], now: now)?.id, 'apply:soon');
  });

  test('the best streak is remembered after the streak breaks', () {
    var s = const XpState();
    for (var d = 0; d < 3; d++) {
      s = s.award(XpAction.savedIds, now.add(Duration(days: d))).state;
    }
    expect((s.streak, s.bestStreak), (3, 3));
    s = s.award(XpAction.savedIds, now.add(const Duration(days: 9))).state; // broken: starts again
    expect((s.streak, s.bestStreak), (1, 3));
    expect(XpState.fromJson(s.toJson()).bestStreak, 3);
  });

  test('palettes: Dusk when dark, Sea Glass when light, each with its Private face', () {
    expect(Palette.of(Brightness.dark), Palette.duskGovt);
    expect(Palette.of(Brightness.dark, private: true).periwinkle, const Color(0xFFFFB547)); // saffron
    expect(Palette.of(Brightness.light).periwinkle, const Color(0xFF007190)); // Antwarp blue
    expect(Palette.of(Brightness.light, private: true), Palette.seaPrivate);
    expect(AppTheme.of(Brightness.dark, private: true).colorScheme.primary, Palette.duskPrivate.periwinkle);
    // Text on the main colour stays readable in every palette.
    for (final p in [Palette.duskGovt, Palette.duskPrivate, Palette.seaGovt, Palette.seaPrivate]) {
      final a = p.periwinkle.computeLuminance(), b = p.onAccent.computeLuminance();
      final contrast = (a > b ? a + 0.05 : b + 0.05) / (a > b ? b + 0.05 : a + 0.05);
      expect(contrast, greaterThan(4.5), reason: '$p');
    }
  });

  testWidgets('the mountain: full on Today, gone on Agenda, sliding in between', (tester) async {
    AppPalette.use(Brightness.dark);
    Future<void> show(double h) => tester.pumpWidget(MaterialApp(
          home: Scaffold(body: SizedBox(width: 360, height: 700, child: SummitBackdrop(height: h))),
        ));
    // How far down the screen the (sliding) scene reaches.
    double shown() => tester
        .getBottomLeft(find.descendant(of: find.byType(SummitBackdrop), matching: find.byType(CustomPaint)).first)
        .dy;

    await show(SummitHeights.today);
    expect(shown(), SummitHeights.full);
    await show(SummitHeights.agenda);
    await tester.pump(const Duration(milliseconds: 200));
    expect(shown(), inExclusiveRange(0, SummitHeights.full)); // on its way
    await tester.pumpAndSettle();
    expect(shown(), 0);
    expect(SummitHeights.govtTabs, [SummitHeights.today, SummitHeights.jobs, SummitHeights.exams, 0, 0]);
  });

  testWidgets('the pill switch selects and reports a new choice', (tester) async {
    AppPalette.use(Brightness.light);
    String? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PillToggle<String>(
          options: const [('a', 'Overview'), ('b', 'Focus')],
          selected: 'a',
          onChanged: (v) => picked = v,
        ),
      ),
    ));
    await tester.tap(find.text('Overview'));
    expect(picked, isNull); // already selected
    await tester.tap(find.text('Focus'));
    expect(picked, 'b');
  });

  group('Summit trail on My exams', () {
    test('every stop and the whole trail sit on the paper mountain', () {
      for (final s in SummitScene.stops) {
        expect(SummitScene.onMountain(s), isTrue, reason: 'stop $s');
      }
      for (final metric in SummitScene.trail().computeMetrics()) {
        for (var d = 0.0; d < metric.length; d += 2) {
          final p = metric.getTangentForOffset(d)!.position;
          expect(SummitScene.onMountain(p), isTrue, reason: 'trail at $p');
        }
      }
      expect(kTrailStops, kLanes); // the stops are the lanes
    });

    test('the summit and every stop are in view on My exams, on small and big phones', () {
      for (final (width, inset) in [(320.0, 24.0), (412.0, 40.0)]) {
        for (final s in SummitScene.stops) {
          final p = SummitScene.place(s, width: width, topInset: inset, visible: SummitHeights.exams);
          expect(p.dy, greaterThan(inset + 20), reason: 'stop $s under the status bar ($width)');
          expect(p.dy, lessThan(inset + SummitHeights.exams), reason: 'stop $s below the mountain ($width)');
          expect(p.dx, inInclusiveRange(0, width));
        }
      }
    });

    test('short badge names', () {
      expect(SummitTrail.shortName(exam('x', name: 'SSC CGL 2026')), 'SSC CGL');
      expect(SummitTrail.shortName(exam('x', name: 'IBPS PO XV')), 'IBPS PO');
      expect(SummitTrail.shortName(exam('x', name: 'RRB NTPC (Graduate) 2026')), 'RRB NTPC');
      expect(SummitTrail.shortName(exam('x', name: 'My custom exam')), 'MY');
    });

    testWidgets('one badge per stop: a single exam opens its journey, several open their lane', (tester) async {
      AppPalette.use(Brightness.dark);
      TrackedApplication? opened;
      int? lane;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 384,
            height: 700,
            child: SummitTrail(
              show: true,
              height: SummitHeights.exams,
              climbers: [
                (exam('a', name: 'SSC CGL 2026'), 0),
                (exam('b', name: 'RRB NTPC'), 0),
                (exam('c', name: 'UPSC CSE'), 1),
              ],
              lane: 0,
              onStop: (i) => lane = i,
              onClimber: (a) => opened = a,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('UPSC'));
      expect(opened?.id, 'c');
      await tester.tap(find.text('SSC CGL +1'));
      expect(lane, 0);
    });
  });

  test('a failed sign-in says what went wrong, briefly, and pauses updates meanwhile', () {
    expect(GoogleAccountService.describe(StateError('Cannot use ref\n after dispose')),
        'Bad state: Cannot use ref after dispose');
    final long = GoogleAccountService.describe(Exception('x' * 300));
    expect(long.length, lessThanOrEqualTo(111));
    expect(long, endsWith('…'));
    expect(GoogleAccountService.signingIn, isFalse);
  });
}
