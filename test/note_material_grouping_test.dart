import 'package:ai_connect_africa/curriculum/curriculum_models.dart';
import 'package:ai_connect_africa/db/otic_database.dart';
import 'package:ai_connect_africa/features/learn/subject_notes.dart';
import 'package:ai_connect_africa/services/notes/note_pdf_store.dart';
import 'package:ai_connect_africa/services/notes/note_quiz_store.dart';
import 'package:ai_connect_africa/services/offline_storage_service.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late OticDatabase db;
  setUp(
    () => db = OticDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    ),
  );
  tearDown(() => db.close());

  Future<void> legacy(
    String title, {
    String subject = 'biology',
    String? classUuid,
  }) async {
    await db.topicResourceDao.insertChunk(
      subjectId: subject,
      topicKey: 'cells',
      termMarker: 1,
      resourceTitle: title,
      contentChunk: 'Cells are the basic units of living things.',
      classGroupUuid: classUuid,
    );
  }

  Future<void> quizzes(String title, int count) async {
    for (var i = 0; i < count; i++) {
      await db.topicResourceDao.insertQuizRow(
        subjectId: 'biology',
        documentTitle: title,
        termMarker: 1,
        content: NoteQuizStore.format(
          QuizQuestion(
            question: 'Question $i?',
            options: const ['Cells', 'Air', 'Water', 'Soil'],
            correct: 0,
            explanation: 'Cells.',
          ),
          1,
        ),
      );
    }
  }

  test(
    'a processed PDF stays one material while every generated quiz is available',
    () async {
      final store = NotePdfStore(db);
      await store.recordOwn(
        subjectId: 'biology',
        documentTitle: 'Biology Book',
        sha: List.filled(64, 'a').join(),
        pages: 100,
        bytes: 1000,
      );
      final storage = OfflineStorageService(db);
      for (var i = 0; i < 30; i++) {
        await storage.insertTopicResource(
          subjectId: 'biology',
          topicKey: 'Section $i',
          resourceTitle: 'Biology Book — Section $i',
          documentTitle: 'Biology Book',
          content: List.filled(40, 'Cells contain genetic material. ').join(),
        );
      }
      await quizzes('Biology Book', 20);
      final materials = await storage.listResources(subjectId: 'biology');
      expect(materials, hasLength(1));
      expect(materials.single.resourceTitle, 'Biology Book');
      expect(materials.single.textCount, greaterThan(30));
      expect(materials.single.quizCount, 20);
      expect(await store.recorded(ownOnly: true), hasLength(1));
      expect(await NoteQuizStore(db).questions('biology'), hasLength(20));
    },
  );

  test(
    'older sections collapse into their original document in teacher and learner lists',
    () async {
      await legacy('Book — Cells');
      await legacy('Book — Plants — Light');
      await quizzes('Book', 3);
      await OfflineStorageService(db).insertTopicResource(
        subjectId: 'biology',
        topicKey: 'cells',
        resourceTitle: 'Book — Second Edition',
        documentTitle: 'Book — Second Edition',
        content: 'New material.',
      );
      final list = await db.topicResourceDao.listResources(
        subjectId: 'biology',
      );
      expect(list.map((r) => r.resourceTitle).toSet(), {
        'Book',
        'Book — Second Edition',
      });
      expect(list.singleWhere((r) => r.resourceTitle == 'Book').quizCount, 3);
      final notes = await buildSubjectNotes(
        await db.select(db.topicResources).get(),
        {},
        (_) async => false,
      );
      expect(notes.map((n) => n.title).toSet(), {
        'Book',
        'Book — Second Edition',
      });
      expect(
        notes.singleWhere((n) => n.title == 'Book').passages,
        hasLength(2),
      );
      expect(
        await db.topicResourceDao.ownNoteText(
          subjectId: 'biology',
          documentTitle: 'Book',
        ),
        hasLength(2),
      );
    },
  );

  test(
    'grouped legacy notes share once and unsharing removes earlier section shares',
    () async {
      await legacy('Book — Cells');
      await legacy('Book — Plants');
      await quizzes('Book', 3);
      final id = await db.classGroupDao.createClass(className: 'S3');
      final group = await (db.select(
        db.classGroups,
      )..where((t) => t.id.equals(id))).getSingle();
      final uuid = group.groupUuid!;
      await db.classSyncDao.setShares(
        subjectId: 'biology',
        documentTitle: 'Book — Cells',
        classUuids: {uuid},
      );
      await db.classSyncDao.setShares(
        subjectId: 'biology',
        documentTitle: 'Book',
        classUuids: {uuid},
      );
      expect(await db.classSyncDao.sharedChunks(uuid, 'biology'), hasLength(5));
      expect(await db.select(db.resourceShares).get(), hasLength(1));
      await db.classSyncDao.setShares(
        subjectId: 'biology',
        documentTitle: 'Book',
        classUuids: {},
      );
      expect(await db.classSyncDao.sharedChunks(uuid, 'biology'), isEmpty);
    },
  );

  test(
    'deleting a grouped note removes its sections and quizzes within its scope',
    () async {
      await legacy('100% Book — Cells');
      await legacy('100% Book — Plants');
      await quizzes('100% Book', 2);
      await legacy('100% Book — Cells', subject: 'chemistry');
      await legacy('100% Book — Cells', classUuid: 'another-class');
      await legacy('100X Book — Cells');
      expect(
        await db.topicResourceDao.deleteByTitle(
          '100% Book',
          subjectId: 'biology',
        ),
        4,
      );
      final left = await db.select(db.topicResources).get();
      expect(left, hasLength(3));
      expect(left.any((r) => r.classGroupUuid == 'another-class'), isTrue);
      expect(left.any((r) => r.subjectId == 'chemistry'), isTrue);
      expect(left.any((r) => r.resourceTitle == '100X Book — Cells'), isTrue);
    },
  );
}
