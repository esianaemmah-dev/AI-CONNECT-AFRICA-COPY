import 'dart:io';

import 'package:ai_connect_africa/core/policy/policy.dart';
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
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [Policy] must answer exactly as the checks it stands in front of.
void main() {
  late OticDatabase db;
  late AdminService admin;
  late AdminSession s;
  late int amina, okello, learner;
  late ClassGroup east, west;
  late Policy policy;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = OticDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    final tmp = await Directory.systemTemp.createTemp('policy_test');
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
    policy = Policy(db);

    s = (await admin.setUp(name: 'Head', pin: '2468'))!;
    await admin.addTeacher(s, name: 'Amina', pin: '1234');
    await admin.addTeacher(s, name: 'Okello', pin: '9876');
    final teachers = await TeacherProfileService(db).all();
    amina = teachers.firstWhere((t) => t.name == 'Amina').id;
    okello = teachers.firstWhere((t) => t.name == 'Okello').id;
    await admin.addClass(s, className: 'S3', streamName: 'East');
    await admin.addClass(s, className: 'S4', streamName: 'West');
    final classes = await db.select(db.classGroups).get();
    east = classes.firstWhere((c) => c.className == 'S3');
    west = classes.firstWhere((c) => c.className == 'S4');
    await admin.addSubject(s, 'Maths 9');
    await admin.addSubject(s, 'Physics 9');
    for (final (t, c, subj) in [
      (amina, east, 'maths_9'),
      (okello, east, 'physics_9'),
    ]) {
      await admin.assign(
        s,
        teacherId: t,
        classGroupUuid: c.groupUuid!,
        subjectId: subj,
        academicYear: 2026,
      );
    }
    learner = (await admin.addLearner(s, name: 'Babirye'))!;
    await admin.enrol(s, studentId: learner, group: east, academicYear: 2026);
    await TeachingScope(db).recordOwner('maths_9', 'Algebra', amina);
  });
  tearDown(() => db.close());

  test('teacher actions follow TeachingScope exactly', () async {
    final scope = TeachingScope(db);
    for (final teacher in [amina, okello, null]) {
      final actor = TeacherActor(teacher);
      for (final subject in ['maths_9', 'physics_9']) {
        expect(
          await policy.can(actor, UploadNote(subject)),
          await scope.mayUpload(teacher, subject),
        );
        expect(
          await policy.can(actor, ChangeNote(subject, 'Algebra')),
          await scope.mayChangeNote(teacher, subject, 'Algebra'),
        );
        for (final c in [east, west]) {
          expect(
            await policy.can(
              actor,
              ShareNote(subject, 'Algebra', c.groupUuid!),
            ),
            await scope.mayShare(teacher, subject, 'Algebra', c.groupUuid!),
          );
        }
      }
    }
    expect(
      await policy.can(TeacherActor(amina), const UploadNote('maths_9')),
      isTrue,
    );
    expect(
      await policy.can(
        TeacherActor(okello),
        const ChangeNote('maths_9', 'Algebra'),
      ),
      isFalse,
    );
  });

  test(
    'a subject a teacher made in Lesson materials is theirs to upload to, '
    'but sharing it into a class still needs an assignment',
    () async {
      final scope = TeachingScope(db);
      final made = await CustomSubjectService(db).create(name: 'Biology 9');
      final biology = made.subjectId!;
      expect(
        await policy.can(TeacherActor(okello), UploadNote(biology)),
        isFalse,
      );

      await scope.recordOwnSubject(okello, biology);
      await scope.recordOwner(biology, 'Cells', okello);
      expect(
        await policy.can(TeacherActor(okello), UploadNote(biology)),
        isTrue);
      expect(
        await policy.can(TeacherActor(okello), ChangeNote(biology, 'Cells')),
        isTrue,
      );
      // Only Okello's.
      expect(
        await policy.can(TeacherActor(amina), UploadNote(biology)),
        isFalse);
      expect(
        await policy.can(
          TeacherActor(okello),
          ShareNote(biology, 'Cells', east.groupUuid!),
        ),
        isFalse,
      );

      // Removing the teacher or the subject drops it.
      await admin.deleteSubject(s, biology);
      expect(await scope.ownsSubject(okello, biology), isFalse);
      final again = (await CustomSubjectService(db,
    ).create(name: 'Art 9'))
          .subjectId!;
      await scope.recordOwnSubject(okello, again);
      await admin.removeTeacher(s, okello);
      expect(await scope.ownsSubject(okello, again), isFalse);
    });

  test(
    'extra help goes only to classes the teacher teaches that subject',
    () async {
      final eastUuid = east.groupUuid!, westUuid = west.groupUuid!;
      expect(
        await policy.can(
          TeacherActor(amina),
          SupportLearner('maths_9', eastUuid),
        ),
        isTrue,
      );
      for (final (actor, subject, c) in [
        (TeacherActor(amina), 'maths_9', westUuid),
        (TeacherActor(amina), 'physics_9', eastUuid),
        (TeacherActor(okello), 'maths_9', eastUuid),
        (const TeacherActor(null), 'maths_9', eastUuid),
        (AdminActor(s), 'maths_9', eastUuid),
        (LearnerActor(learner), 'maths_9', eastUuid),
      ]) {
        expect(
          await policy.can(actor, SupportLearner(subject, c)),
          isFalse,
          reason: '$actor $subject $c',
        );
      }
    },
  );

  test(
    'only teachers change notes; only the Admin manages the school',
    () async {
      for (final actor in [
        AdminActor(s),
        LearnerActor(learner),
        const GuestActor(),
      ]) {
        expect(await policy.can(actor, const UploadNote('maths_9')), isFalse);
        expect(
          await policy.can(actor, const ChangeNote('maths_9', 'Algebra')),
          isFalse,
        );
      }
      expect(await policy.can(AdminActor(s), const ManageSchool()), isTrue);
      for (final actor in [
        TeacherActor(amina),
        LearnerActor(learner),
        const GuestActor(),
      ]) {
        expect(await policy.can(actor, const ManageSchool()), isFalse);
      }
    },
  );

  test(
    'only a teacher of the class, or the Admin, manages its devices',
    () async {
      final e = ManageClassDevices(east.groupUuid!);
      final w = ManageClassDevices(west.groupUuid!);
      expect(await policy.can(TeacherActor(amina), e), isTrue);
      expect(await policy.can(TeacherActor(amina), w), isFalse);
      expect(await policy.can(const TeacherActor(null), e), isFalse);
      expect(await policy.can(AdminActor(s), w), isTrue);
      expect(await policy.can(LearnerActor(learner), e), isFalse);
    },
  );

  test('a learner reads only the subjects taught to their class', () async {
    expect(await policy.readableSubjects(LearnerActor(learner)), {
      'maths_9',
      'physics_9',
    });
    expect(
      await policy.can(LearnerActor(learner), const ReadNotes('maths_9')),
      isTrue,
    );
    await admin.enrol(s, studentId: learner, group: west, academicYear: 2026);
    expect(
      await policy.can(LearnerActor(learner), const ReadNotes('maths_9')),
      isFalse,
    );
    expect(await policy.readableSubjects(const GuestActor()), isEmpty);
    expect(await policy.readableSubjects(const TeacherActor(null)), isNull);
  });

  test('learner access follows the class independently of Teachers PIN',
    () async {
      await admin.enrol(s, studentId: learner, group: west, academicYear: 2026);
    expect(await policy.readableSubjects(LearnerActor(learner)), isEmpty);
      expect(await policy.readableSubjects(const GuestActor()), isEmpty);
    },
  );

  test(
    'class materials are readable without subject registration and follow class changes live',
    () async {
      await db.topicResourceDao.insertChunk(
        subjectId: 'new_subject',
        topicKey: '~pdf',
        termMarker: 0,
        resourceTitle: 'New book',
        contentChunk: 'PDF marker',
        classGroupUuid: east.groupUuid,
      );
      await db.topicResourceDao.insertChunk(
        subjectId: 'other_class',
        topicKey: '~pdf',
        termMarker: 0,
        resourceTitle: 'Other book',
        contentChunk: 'PDF marker',
        classGroupUuid: west.groupUuid,
      );
      // Old subject choices cannot grant access to another class's notes.
      await db.classSyncDao.setEnrolled(learner, 'other_class', true);
      expect(
        await policy.can(LearnerActor(learner), const ReadNotes('new_subject')),
        isTrue,
      );
      expect(
        await policy.can(LearnerActor(learner), const ReadNotes('other_class')),
        isFalse,
      );
      final moved = policy
          .watchReadableSubjects(LearnerActor(learner))
          .firstWhere((subjects) => subjects?.contains('other_class') ?? false);
      await admin.enrol(s, studentId: learner, group: west, academicYear: 2026);
      expect(await moved, {'other_class'});
      expect(
        await policy.can(LearnerActor(learner), const ReadNotes('new_subject')),
        isFalse,
      );
    },
  );
  test('Admin recovery requires a one-use code and revokes existing sessions', () async {
    expect(await admin.recoverPin('5678'), isFalse);
    final code = await admin.createRecoveryCode(s);
    expect(await admin.recoverPin('5678', recoveryCode: 'wrong'), isFalse);
    expect(await admin.recoverPin('5678', recoveryCode: code), isTrue);
    expect(s.isValid, isFalse);
    expect(() => admin.addClass(s, className: 'Forbidden'), throwsStateError);
    final next = await admin.signIn('5678');
    expect(next, isNotNull);
    expect(await admin.recoverPin('9999', recoveryCode: code), isFalse);
    final row = (await db.select(db.adminIdentity).get()).single;
    expect(row.pinPlain, isNull);
    expect(row.recoveryHash, isNotNull, reason: 'recovery rotates at next authenticated sign-in');
    expect(row.recoveryHash, isNot(admin.pendingRecoveryCode));
  });

  test('revoked Admin sessions and reset teacher credentials lose service access', () async {
    final profiles = TeacherProfileService(db);
    expect(await profiles.signIn(amina, '1234'), isNotNull);
    expect(profiles.valid(amina), isTrue);
    expect(await admin.resetTeacherPin(s, amina, '4567'), isTrue);
    expect(profiles.valid(amina), isFalse);
    s.lease.revoked = true;
    expect(() => admin.addLearner(s, name: 'Blocked'), throwsStateError);
    expect(() => admin.createRecoveryCode(s), throwsStateError);
  });

}
