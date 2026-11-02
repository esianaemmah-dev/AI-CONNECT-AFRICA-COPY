import 'package:ai_connect_africa/db/otic_database.dart';
import 'package:ai_connect_africa/db/providers/db_provider.dart';
import 'package:ai_connect_africa/features/assignments/assignments_screens.dart';
import 'package:ai_connect_africa/services/assignments/class_assignments.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late OticDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = OticDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
  });
  tearDown(() => db.close());

  Widget app(Widget child) => ProviderScope(
    overrides: [dbProvider.overrideWithValue(db)],
    child: MaterialApp(home: child),
  );

  testWidgets('the assessment shows its countdown, and Submit hands it in',
      (tester) async {
    late Student amina;
    late ClassAssignment a;
    late AssignmentAttempt attempt;
    await tester.runAsync(() async {
      final id = await db.studentDao.createStudent(
        StudentsCompanion.insert(name: 'Amina'),
      );
      amina = (await db.studentDao.getStudentById(id))!;
      final service = ClassAssignments(db);
      await service.create(
        subjectId: 'biology',
        title: 'Cells',
        instructions: 'Q1. Name two organelles.',
        maxPoints: 10,
        kind: AssignmentKind.homework,
        minutes: 45,
      );
      a = (await service.own()).single;
      attempt = (await service.start(amina.id, a))!;
    });

    await tester.pumpWidget(
      app(AssessmentScreen(student: amina, assignment: a, attempt: attempt)),
    );
    await tester.pump();
    expect(find.text('Q1. Name two organelles.'), findsOneWidget);
    expect(find.textContaining('min'), findsWidgets);

    await tester.enterText(find.byType(TextField), 'Nucleus, ribosome');
    await tester.runAsync(() async {
      await tester.tap(find.text('Submit'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();

    final subs = await tester.runAsync(
      () => db.select(db.assignmentSubmissions).get(),
    );
    expect(subs!.single.answer, 'Nucleus, ribosome');
    expect(subs.single.startedAt, isNotNull);
    await tester.pumpWidget(const SizedBox());
    // Let cancelled Drift streams finish their zero-delay cleanup timers.
    await tester.pump(Duration.zero);
  });

  testWidgets('New assignment shows type, times, limit and PDF', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => showNewAssignmentDialog(context, ref, 'bio'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Type'), findsOneWidget);
    expect(find.textContaining('Opens'), findsOneWidget);
    expect(find.textContaining('Closes'), findsOneWidget);
    expect(find.text('Time limit (min)'), findsOneWidget);
    expect(find.text('Attach PDF'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Time limit (min)'), '0');
    await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Cells');
    await tester.tap(find.text('Create'));
    await tester.pump();
    expect(find.textContaining('Time limit: 1'), findsOneWidget);
  });
}
