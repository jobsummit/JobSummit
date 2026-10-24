import 'package:exam_tracker/domain/practice.dart';
import 'package:exam_tracker/screens/practice_test_screen.dart';
import 'package:exam_tracker/services/practice_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a maths test: answer, jump, submit, then marks and every answer', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: PracticeTestScreen(plan: PracticePlan.section(PracticeSection.quant, 10))),
    ));
    await tester.pumpAndSettle();
    expect(find.text('1 of 10'), findsOneWidget);
    expect(find.text('8:00'), findsNothing); // the clock has started: 7:59 or so
    expect(find.textContaining(RegExp(r'^7:5\d$')), findsOneWidget);

    await tester.tap(find.text('A'));
    await tester.pump();
    expect(find.text('Next'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pump();
    expect(find.text('2 of 10'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);

    await tester.tap(find.text('1/10'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Submit test'));
    await tester.pumpAndSettle();
    expect(find.text('9 questions not answered.'), findsOneWidget);
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();

    expect(find.text('Answers'), findsOneWidget);
    expect(find.text('skipped'), findsOneWidget);
    expect(find.text('Answer at least half the questions to earn XP.'), findsOneWidget);
    final history = await PracticeStore.history();
    expect(history.single.kind, 'quant');
    expect(history.single.total, 10);
    expect(history.single.answered, 1);
  });

  testWidgets('leaving a running test asks first', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => PracticeTestScreen.open(context, PracticePlan.section(PracticeSection.reasoning, 10)),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Leave this test?'), findsOneWidget);
    await tester.tap(find.text('Leave'));
    await tester.pumpAndSettle();
    expect(find.text('go'), findsOneWidget);
    expect(await PracticeStore.history(), isEmpty);
  });
}
