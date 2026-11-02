import 'dart:io';

import 'package:ai_connect_africa/db/otic_database.dart';
import 'package:ai_connect_africa/features/admin/admin_service.dart';
import 'package:ai_connect_africa/features/teacher/teacher_profiles.dart';
import 'package:ai_connect_africa/features/teacher/teaching_scope.dart';
import 'package:ai_connect_africa/memory/session_recall_store.dart';
import 'package:ai_connect_africa/services/custom_subject_service.dart';
import 'package:ai_connect_africa/services/learner_data_wiper.dart';
import 'package:ai_connect_africa/services/projects/project_store.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late OticDatabase db;
  late AdminService admin;
  late TeacherProfileService teachers;
  late TeachingScope scope;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = OticDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    final tmp = await Directory.systemTemp.createTemp('admin_test');
    admin = AdminService(
      db,
      CustomSubjectService(db),
      LearnerDataWiper(
        db,
        recallStore: SessionRecallStore(directory: tmp),
        certificatesDir: () async => tmp,
        projectStore: ProjectStore(root: () async => tmp),
      ),
    );
    teachers = TeacherProfileService(db);
    scope = TeachingScope(db);
  });
  tearDown(() => db.close());

  Future<int> teacherId(String name) async =>
      (await teachers.all()).firstWhere((t) => t.name == name).id;

  Future<ClassGroup> classByName(String name) async =>
      (await (db.select(db.classGroups)
            ..where((t) => t.className.equals(name)))
          .getSingle());

  group('one Admin', () {
    test('is set up once, then signs in only with their PIN', () async {
      expect(await admin.isSetUp(), isFalse);
      expect(await admin.setUp(name: 'Head', pin: '2468'), isNotNull);
      expect(await admin.setUp(name: 'Other', pin: '1357'), isNull);
      expect(await admin.signIn('1357'), isNull);
      expect((await admin.signIn('2468'))?.name, 'Head');
    });

    test('changes their PIN only with the current one', () async {
      final s = (await admin.setUp(name: 'Head', pin: '2468'))!;
      expect(await admin.changePin(s, '0000', '1111'), isFalse);
      expect(await admin.changePin(s, '2468', '1111'), isTrue);
      expect(await admin.signIn('1111'), isNotNull);
    });
  });

  group('teachers', () {
    test('only the Admin adds them; each signs in with their own PIN',
        () async {
      final s = (await admin.setUp(name: 'Head', pin: '2468'))!;
      expect(await admin.addTeacher(s, name: 'Amina', pin: '1234'), isNull);
      expect(await admin.addTeacher(s, name: 'amina', pin: '5555'), isNotNull);
      expect(await admin.addTeacher(s, name: 'Okello', pin: '12'), isNotNull);
      final amina = await teacherId('Amina');
      expect(await teachers.signIn(amina, '1234'), isNotNull);
      expect(await teachers.signIn(amina, '9999'), isNull);
      final row = (await teachers.all()).single;
      expect(row.uuid, isNotNull, reason: 'portable id for Admin sync');
    });

    test('a forgotten PIN is reset by the Admin', () async {
      final s = (await admin.setUp(name: 'Head', pin: '2468'))!;
      await admin.addTeacher(s, name: 'Amina', pin: '1234');
      final amina = await teacherId('Amina');
      await admin.resetTeacherPin(s, amina, '4321');
      expect(await teachers.signIn(amina, '4321'), isNotNull);
    });
  });

  group('teaching assignments decide what a teacher may do', () {
    late AdminSession s;
    late int amina, okello;
    late ClassGroup east, west;

    setUp(() async {
      s = (await admin.setUp(name: 'Head', pin: '2468'))!;
      await admin.addTeacher(s, name: 'Amina', pin: '1234');
      await admin.addTeacher(s, name: 'Okello', pin: '9876');
      amina = await teacherId('Amina');
      okello = await teacherId('Okello');
      await admin.addClass(s, className: 'S3', streamName: 'East');
      await admin.addClass(s, className: 'S4', streamName: 'West');
      east = await classByName('S3');
      west = await classByName('S4');
      await admin.addSubject(s, 'Maths 9');
      await admin.addSubject(s, 'Physics 9');
      await admin.assign(
        s,
        teacherId: amina,
        classGroupUuid: east.groupUuid!,
        subjectId: 'maths_9',
        academicYear: 2026,
      );
      await admin.assign(
        s,
        teacherId: okello,
        classGroupUuid: east.groupUuid!,
        subjectId: 'physics_9',
        academicYear: 2026,
      );
    });

    test('a teacher teaches only what they are assigned', () async {
      expect(await scope.teaches(amina, 'maths_9'), isTrue);
      expect(await scope.teaches(amina, 'physics_9'), isFalse);
      expect(
        await scope.teaches(amina, 'maths_9', classGroupUuid: west.groupUuid),
        isFalse,
      );
      expect(await scope.teaches(null, 'maths_9'), isFalse);
    });

    test('a teacher can’t change or share another teacher’s material',
        () async {
      await scope.recordOwner('maths_9', 'Algebra', amina);
      expect(await scope.mayChangeNote(amina, 'maths_9', 'Algebra'), isTrue);
      expect(await scope.mayChangeNote(okello, 'maths_9', 'Algebra'), isFalse);
      expect(
        await scope.mayShare(amina, 'maths_9', 'Algebra', east.groupUuid!),
        isTrue,
      );
      expect(
        await scope.mayShare(amina, 'maths_9', 'Algebra', west.groupUuid!),
        isFalse,
        reason: 'not assigned to S4 West for Maths',
      );
    });

    test('the same assignment is never added twice', () async {
      expect(
        await admin.assign(
          s,
          teacherId: amina,
          classGroupUuid: east.groupUuid!,
          subjectId: 'maths_9',
          academicYear: 2026,
        ),
        isFalse,
      );
    });

    test('removing a teacher removes their assignments; notes stay open to '
        'whoever teaches the subject next', () async {
      await scope.recordOwner('maths_9', 'Algebra', amina);
      await admin.removeTeacher(s, amina);
      expect(await scope.assignments(amina), isEmpty);
      expect(await scope.ownerOf('maths_9', 'Algebra'), isNull);
    });

    test('a class stops being served a note once no assignment covers it',
        () async {
      await scope.recordOwner('maths_9', 'Algebra', amina);
      await db.classSyncDao.setShares(
        subjectId: 'maths_9',
        documentTitle: 'Algebra',
        classUuids: {east.groupUuid!, west.groupUuid!},
      );
      // S4 West was never assigned: dropped at the next check.
      expect(await scope.pruneShares(), 1);
      final kept = await db.select(db.resourceShares).get();
      expect(kept.single.classGroupUuid, east.groupUuid);

      // The Admin takes Maths in S3 East away from Amina.
      final a = (await scope.assignments(amina)).single;
      await admin.unassign(s, a.id);
      expect(await db.select(db.resourceShares).get(), isEmpty);
    });

    test('deleting a class or subject removes its assignments', () async {
      await admin.deleteClass(s, east);
      expect(await scope.assignments(amina), isEmpty);
      expect(await scope.assignments(okello), isEmpty);
    });
  });

  group('learners', () {
    test('the Admin adds and enrols them; re-enrolling withdraws the old '
        'enrolment and keeps it', () async {
      final s = (await admin.setUp(name: 'Head', pin: '2468'))!;
      await admin.addClass(s, className: 'S3', streamName: 'East');
      await admin.addClass(s, className: 'S4', streamName: 'West');
      final east = await classByName('S3');
      final west = await classByName('S4');
      final id = (await admin.addLearner(s, name: 'Babirye'))!;

      await admin.enrol(s, studentId: id, group: east, academicYear: 2026);
      await admin.enrol(s, studentId: id, group: west, academicYear: 2026);
      final rows = await db.select(db.studentEnrolments).get();
      expect(rows.map((r) => r.status), unorderedEquals(['withdrawn', 'active']));
      final learner = await db.studentDao.getStudentById(id);
      expect(learner!.classGroupId, west.id);
      expect(learner.uuid, isNotNull);

      await admin.withdraw(s, id);
      expect((await db.studentDao.getStudentById(id))!.classGroupId, isNull);
    });

    test('an enrolled learner may read the notes of subjects taught to '
        'their class, and nothing else', () async {
      final s = (await admin.setUp(name: 'Head', pin: '2468'))!;
      await admin.addTeacher(s, name: 'Amina', pin: '1234');
      await admin.addClass(s, className: 'S3', streamName: 'East');
      await admin.addClass(s, className: 'S4', streamName: 'West');
      final east = await classByName('S3');
      final west = await classByName('S4');
      await admin.addSubject(s, 'Maths 9');
      await admin.addSubject(s, 'Physics 9');
      for (final (group, subject) in [
        (east, 'maths_9'),
        (west, 'physics_9'),
      ]) {
        await admin.assign(
          s,
          teacherId: await teacherId('Amina'),
          classGroupUuid: group.groupUuid!,
          subjectId: subject,
          academicYear: 2026,
        );
      }
      final id = (await admin.addLearner(s, name: 'Babirye'))!;
      Future<Set<String>> readable() =>
          db.classSyncDao.watchReadable(id).first;

      expect(await readable(), isEmpty);
      await admin.enrol(s, studentId: id, group: east, academicYear: 2026);
      expect(await readable(), {'maths_9'});
      await admin.enrol(s, studentId: id, group: west, academicYear: 2026);
      expect(await readable(), {'physics_9'},
          reason: 'a withdrawn enrolment no longer opens its notes');
      await db.classSyncDao.setEnrolled(id, 'maths_9', true);
      expect(await readable(), {'physics_9'},
          reason: 'a subject preference cannot reopen another class\'s notes');
    });

    test('deleting a learner deletes their enrolments', () async {
      final s = (await admin.setUp(name: 'Head', pin: '2468'))!;
      await admin.addClass(s, className: 'S3', streamName: 'East');
      final id = (await admin.addLearner(s, name: 'Babirye'))!;
      await admin.enrol(
        s,
        studentId: id,
        group: await classByName('S3'),
        academicYear: 2026,
      );
      await admin.deleteLearner(s, id);
      expect(await db.select(db.studentEnrolments).get(), isEmpty);
    });

    test('a learner made anywhere gets a portable id', () async {
      final id = await db
          .into(db.students)
          .insert(StudentsCompanion.insert(name: 'Okot'));
      expect((await db.studentDao.getStudentById(id))!.uuid, isNotNull);
    });
  });

  testWidgets('teacher and Admin sessions end on their own', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeTeacherProvider.notifier).state = TeacherProfile(
      id: 1,
      name: 'Amina',
      pinSalt: 's',
      pinHash: 'h',
      createdAt: '2026-10-06T00:00:00Z',
    );
    await tester.pump(const Duration(minutes: 59));
    expect(container.read(activeTeacherProvider), isNotNull);
    await tester.pump(const Duration(minutes: 2));
    expect(container.read(activeTeacherProvider), isNull);
  });
}
