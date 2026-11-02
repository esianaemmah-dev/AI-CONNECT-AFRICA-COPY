import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_connect_africa/db/otic_database.dart';
import 'package:ai_connect_africa/db/providers/db_provider.dart';
import 'package:ai_connect_africa/features/learn/class_learning_panel.dart';
import 'package:ai_connect_africa/features/notes/my_notes_screen.dart';
import 'package:ai_connect_africa/services/notes/note_pdf_store.dart';
import 'package:ai_connect_africa/collaboration/sync/learner_sync_controller.dart';

void main() {
  testWidgets('class overview follows the learner and keeps new-material status separate', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = OticDatabase.forTesting(NativeDatabase.memory());
    late Student amina, brian;
    await tester.runAsync(() async {
      final a = await db.studentDao.createStudent(StudentsCompanion.insert(name: 'Amina'));
      final b = await db.studentDao.createStudent(StudentsCompanion.insert(name: 'Brian'));
      amina = (await db.studentDao.getStudentById(a))!;
      brian = (await db.studentDao.getStudentById(b))!;
    });
    var active = amina;
    final sha = 'a' * 64;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pdf_seen_${amina.id}:$sha', true);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      activeStudentProvider.overrideWith((ref) async => active),
      learnerSyncProvider.overrideWith((ref) => LearnerSyncController(ref)),
      myNotesProvider.overrideWith((ref) async => [MyNotesSubject('chemistry', 'Chemistry', [
        (NotePdf(sha256: sha, pages: 3, bytes: 32, subjectId: 'chemistry', documentTitle: 'Acids'), true),
      ])]),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: const MaterialApp(home: Scaffold(body: ClassLearningPanel()))));
    await tester.pumpAndSettle();
    expect(find.text('Amina · My class'), findsOneWidget);
    expect(find.text('Continue reading'), findsOneWidget);
    expect(find.textContaining('New from your teacher'), findsNothing);
    active = brian;
    container.invalidate(activeStudentProvider);
    await tester.pumpAndSettle();
    expect(find.text('Brian · My class'), findsOneWidget);
    expect(find.text('New from your teacher: 1 materials'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.runAsync(db.close);
  });
}
