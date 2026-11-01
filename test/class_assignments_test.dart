import 'package:ai_connect_africa/db/otic_database.dart';
import 'package:ai_connect_africa/services/assignments/class_assignments.dart';
import 'package:ai_connect_africa/services/offline_storage_service.dart';
import 'package:ai_connect_africa/services/notes/note_quiz_store.dart';
import 'package:ai_connect_africa/curriculum/curriculum_models.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late OticDatabase db;
  late ClassAssignments assignments;
  late String classUuid;

  setUp(() async {
    db = OticDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    assignments = ClassAssignments(db);
    await db.classSyncDao.setSchoolName('School');
    final id = await db.classGroupDao.createClass(className: 'S3');
    classUuid = (await (db.select(
      db.classGroups,
    )..where((t) => t.id.equals(id))).getSingle()).groupUuid!;
  });
  tearDown(() => db.close());

  test(
    'note practice reuses checked questions once and keeps the PDF a note',
    () async {
      expect(
        await assignments.prepareNotePractice('maths', 'Fractions'),
        isNull,
      );
      await OfflineStorageService(db).insertTopicResource(
        subjectId: 'maths',
        topicKey: 'Fractions',
        resourceTitle: 'Fractions',
        content: 'A half is one of two equal parts.',
        documentTitle: 'Fractions',
      );
      expect(
        await assignments.prepareNotePractice('maths', 'Fractions'),
        isNull,
      );
      for (var i = 0; i < 10; i++) {
        await db.topicResourceDao.insertQuizRow(
          subjectId: 'maths',
          documentTitle: 'Fractions',
          termMarker: 0,
          content: NoteQuizStore.format(
            QuizQuestion(
              question: 'Question $i?',
              options: const ['One', 'Two', 'Three', 'Four'],
              correct: 0,
              explanation: 'One is correct.',
            ),
            1,
          ),
        );
      }
      final title = await assignments.prepareNotePractice('maths', 'Fractions');
      expect(
        await assignments.prepareNotePractice('maths', 'Fractions'),
        title,
      );
      final own = await assignments.own();
      expect(own, hasLength(1));
      expect(own.single.documentTitle, isNot('Fractions'));
      expect(own.single.maxPoints, 8);
      expect(own.single.instructions, contains('Question 0?'));
      expect(own.single.instructions, isNot(contains('Question 8?')));
      expect(own.single.instructions, isNot(contains('One is correct.')));
      expect(await db.select(db.resourceShares).get(), isEmpty);
    },
  );

  Future<ClassAssignment> make({bool shared = true}) async {
    final title = (await assignments.create(
      subjectId: 'maths',
      title: 'Fractions',
      instructions: 'Add 1/2 and 1/4.',
      maxPoints: 5,
    ))!;
    if (shared) {
      await db.classSyncDao.setShares(
        subjectId: 'maths',
        documentTitle: title,
        classUuids: {classUuid},
      );
    }
    return (await assignments.own()).firstWhere(
      (a) => a.documentTitle == title,
    );
  }

  SubmissionPayload answer(ClassAssignment a, String uuid, String text) =>
      SubmissionPayload(
        uuid: uuid,
        assignmentId: a.id,
        subjectId: 'maths',
        answer: text,
        createdAt: '2026-10-06T08:00:00Z',
      );

  test(
    'an answer to an assignment not shared with the class is refused',
    () async {
      final a = await make(shared: false);
      await assignments.receive(
        classUuid: classUuid,
        memberKey: 'dev/1',
        learnerName: 'Amina',
        submissions: [answer(a, 's1', '3/4')],
      );
      expect(await db.select(db.assignmentSubmissions).get(), isEmpty);
    },
  );

  test('a received answer is never changed, nor taken over by another '
      'learner', () async {
    final a = await make();
    Future<List<GradePayload>> send(String member, String text) =>
        assignments.receive(
          classUuid: classUuid,
          memberKey: member,
          learnerName: 'Amina',
          submissions: [answer(a, 's1', text)],
        );
    await send('dev/1', '3/4');
    await send('dev/1', 'changed');
    await assignments.grade('s1', 5, 'Right');
    expect(
      await send('dev/2', 'mine now'),
      isEmpty,
      reason: 'another learner gets no grade back',
    );
    final row = (await db.select(db.assignmentSubmissions).get()).single;
    expect(row.answer, '3/4');
    expect(row.memberKey, 'dev/1');
    final back = await send('dev/1', '3/4');
    expect(back.single.grade, 5);
    expect(back.single.version, 1);
  });

  test(
    'a learner device takes only newer grades, only for its own answers',
    () async {
      final a = await make();
      final me = await db
          .into(db.students)
          .insert(StudentsCompanion.insert(name: 'Amina'));
      await assignments.submit(
        student: (await db.studentDao.getStudentById(me))!,
        assignment: a,
        answer: '3/4',
        memberKey: 'local/$me',
      );
      final uuid =
          (await db.select(db.assignmentSubmissions).get()).single.uuid;
      expect(
        await assignments.applyGrades([
          GradePayload(uuid: uuid, grade: 4, version: 2, feedback: 'Close'),
        ]),
        1,
      );
      expect(
        await assignments.applyGrades([
          GradePayload(uuid: uuid, grade: 1, version: 1),
        ]),
        0,
        reason: 'an older grade never wins',
      );
      expect(
        await assignments.applyGrades([
          const GradePayload(uuid: 'not-mine', grade: 5, version: 9),
        ]),
        0,
      );
      final row = (await db.select(db.assignmentSubmissions).get()).single;
      expect(row.grade, 4);
      expect(row.answer, '3/4');
    },
  );

  test('submissions survive a round trip through JSON, clipped', () {
    final long = 'x' * (kMaxAnswerChars + 50);
    final p = SubmissionPayload.fromJson({
      'uuid': 'u',
      'assignment': 'a',
      'subject': 'maths',
      'answer': long,
      'created_at': '2026-10-06T08:00:00Z',
    })!;
    expect(p.answer.length, kMaxAnswerChars);
    expect(SubmissionPayload.fromJson({'uuid': 1}), isNull);
  });
}
