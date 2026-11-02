import 'dart:io';

import 'package:ai_connect_africa/collaboration/admin/admin_records_share.dart';
import 'package:ai_connect_africa/collaboration/sync/class_enrolment.dart';
import 'package:ai_connect_africa/collaboration/sync/class_share_server.dart';
import 'package:ai_connect_africa/collaboration/sync/selective_sync_manager.dart';
import 'package:ai_connect_africa/core/policy/policy.dart';
import 'package:ai_connect_africa/db/otic_database.dart';
import 'package:ai_connect_africa/features/admin/admin_service.dart';
import 'package:ai_connect_africa/features/teacher/class_teacher_service.dart';
import 'package:ai_connect_africa/features/teacher/teacher_profiles.dart';
import 'package:ai_connect_africa/memory/session_recall_store.dart';
import 'package:ai_connect_africa/services/custom_subject_service.dart';
import 'package:ai_connect_africa/services/learner_data_wiper.dart';
import 'package:ai_connect_africa/services/projects/project_store.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

const _rounds = 1000;

/// Class Teachers: the Admin enrols them and gives them classes/streams;
/// they register learners into those only, on their own devices, and the
/// learners reach the Admin's device at the next Admin sync.
void main() {
  late OticDatabase adminDb;
  late AdminService admin;
  late AdminSession session;
  late ClassGroup east, west;
  final others = <OticDatabase>[];

  OticDatabase device() {
    final db = OticDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    others.add(db);
    return db;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    adminDb = device();
    final tmp = await Directory.systemTemp.createTemp('class_teacher');
    admin = AdminService(
      adminDb,
      CustomSubjectService(adminDb),
      LearnerDataWiper(
        adminDb,
        recallStore: SessionRecallStore(directory: tmp),
        certificatesDir: () async => tmp,
        projectStore: ProjectStore(root: () async => tmp),
      ),
    );
    session = (await admin.setUp(name: 'Head', pin: '2468'))!;
    await adminDb.classSyncDao.setSchoolName('Bright Future Academy');
    await admin.addClass(session, className: 'S1', streamName: 'East');
    await admin.addClass(session, className: 'S1', streamName: 'West');
    final classes = await adminDb.select(adminDb.classGroups).get();
    east = classes.firstWhere((c) => c.streamName == 'East');
    west = classes.firstWhere((c) => c.streamName == 'West');
  });

  tearDown(() async {
    for (final db in others) {
      await db.close();
    }
    others.clear();
  });

  Future<int> teacherId(OticDatabase db, String name) async =>
      (await TeacherProfileService(db,
      ).all()).firstWhere((t) => t.name == name).id;

  Policy policyOf(OticDatabase db) => Policy(db);

  test('the Admin enrols a Class Teacher with their classes/streams',
      () async {
    expect(
      await admin.addClassTeacher(
        session,
        name: 'Mr Okello',
        pin: '1234',
        classUuids: const {},
      ),
      isNotNull,
      reason: 'needs at least one class',
    );
    expect(
      await admin.addClassTeacher(
        session,
        name: 'Mr Okello',
        pin: '1234',
        classUuids: {east.groupUuid!},
      ),
      isNull,
    );
    final okello = await teacherId(adminDb, 'Mr Okello');
    expect(await TeacherProfileService(adminDb).signIn(okello, '1234'), isNotNull,
    );
    final policy = policyOf(adminDb);
    expect(
      await policy.can(TeacherActor(okello), RegisterLearner(east.groupUuid!)),
      isTrue,
    );
    expect(
      await policy.can(TeacherActor(okello), RegisterLearner(west.groupUuid!)),
      isFalse,
    );
    expect(
      await policy.can(AdminActor(session), RegisterLearner(west.groupUuid!)),
      isTrue,
    );
    expect(
      await policy.can(const GuestActor(), RegisterLearner(east.groupUuid!)),
      isFalse,
    );
    // Registering learners is all the role gives.
    expect(await policy.can(TeacherActor(okello), const UploadNote('maths')), isFalse,
    );

    await admin.setClassTeacherClasses(session, okello, {west.groupUuid!});
    expect(
      await policy.can(TeacherActor(okello), RegisterLearner(east.groupUuid!)),
      isFalse,
    );
    await admin.setClassTeacherClasses(session, okello, const {});
    expect(
      await policy.can(TeacherActor(okello), RegisterLearner(west.groupUuid!)),
      isFalse,
    );
  });

  group('over Admin sync', () {
    late AdminRecordsServer server;
    late int port;
    var accept = true;
    final asked = <Map<String, int>>[];

    setUp(() async {
      accept = true;
      asked.clear();
      await admin.addClassTeacher(
        session,
        name: 'Mr Okello',
        pin: '1234',
        classUuids: {east.groupUuid!},
      );
      server = AdminRecordsServer(
        adminDb,
        approvalTimeout: const Duration(seconds: 5),
        kdfRounds: _rounds,
      );
      port = await server.start();
      server.pending.listen((p) {
        for (final r in p) {
          asked.add(r.registrations);
          server.decide(r, accept: accept);
        }
      });
    });
    tearDown(() => server.stop());

    Future<String?> sync(OticDatabase target) => receiveAdminRecords(
      target,
      address: '127.0.0.1',
      port: port,
      typedCode: server.code!,
      deviceName: 'Okello phone',
      kdfRounds: _rounds,
    );

    Future<List<String>> adminLearners() async => [
      for (final s in await adminDb.select(adminDb.students).get()) s.name]
          ..sort();

    test(
      'an approved class join reaches the Admin and other devices with the same learner identity',
      () async {
        final phone = device();
        expect(await sync(phone), isNull);
        final okello = await teacherId(phone, 'Mr Okello');
        final group = (await ClassTeacherService(
          phone,
          policyOf(phone),
        ).classesOf(okello)).single;
        final learnerDevice = device();
        final studentId = await learnerDevice.studentDao.createStudent(
          StudentsCompanion.insert(name: 'Amina'),
        );
        final sharing = ClassShareServer(
          phone,
          teacherId: okello,
          joinRounds: _rounds,
        );
        final manager = SelectiveSyncManager(
          learnerDevice,
          joinRounds: _rounds,
        );
        final requests = <PendingJoin>[];
        final subscription = sharing.pendingJoinsStream.listen((pending) {
          for (final request in pending) {
            requests.add(request);
            sharing.decide(request.id, accept: true);
          }
        });
        try {
          final syncPort = await sharing.start(
            classUuids: {group.groupUuid!},
            port: 0,
          );
          final result = await manager.joinClass(
            teachers: [(address: '127.0.0.1', port: syncPort)],
            typedCode: (await sharing.openJoinCode(group))!,
            studentId: studentId,
          );
          expect(result.ok, isTrue, reason: result.error);
          expect(requests.single.name, 'Amina');
          expect(requests.single.classUuid, east.groupUuid);
        } finally {
          manager.dispose();
          await sharing.stop();
          await subscription.cancel();
        }
        final uuid = (await learnerDevice.select(learnerDevice.students).get())
            .single
            .uuid;
        final enrolled =
            (await phone.select(phone.studentEnrolments).get()).single;
        expect(await sync(phone), isNull);
        final onAdmin = (await adminDb.select(adminDb.students).get()).single;
        expect(onAdmin.uuid, uuid);
        expect(onAdmin.classGroupId, east.id);
        expect(
          (await adminDb.select(adminDb.studentEnrolments).get()).single.uuid,
          enrolled.uuid,
        );
        final other = device();
        expect(await sync(other), isNull);
        final learner = (await other.select(other.students).get()).single;
        expect(learner.uuid, uuid);
        final otherClass = await other.classGroupDao.findByUuid(
          east.groupUuid!,
        );
        expect(learner.classGroupId, otherClass!.id);
        expect(
          (await other.select(other.studentEnrolments).get()).single.uuid,
          enrolled.uuid,
        );
        expect(await sync(phone), isNull);
        expect(await adminLearners(), ['Amina']);
      },
    );

    test(
      'approval can enrol an existing school learner without duplicating their profile',
      () async {
        final id = (await admin.addLearner(session, name: 'Amina'))!;
        await admin.enrol(
          session,
          studentId: id,
          group: west,
          academicYear: 2026,
        );
        final phone = device();
        expect(await sync(phone), isNull);
        final okello = await teacherId(phone, 'Mr Okello');
        final here = (await phone.select(phone.students).get()).single;
        final group = (await ClassTeacherService(
          phone,
          policyOf(phone),
        ).classesOf(okello)).single;
        final approved = await ClassEnrolment(phone).approve(
          learnerUuid: here.uuid!,
          name: here.name,
          group: group,
          teacherId: okello,
        );
        expect(await sync(phone), isNull);
        final onAdmin = (await adminDb.select(adminDb.students).get()).single;
        expect(onAdmin.id, id);
        expect(onAdmin.classGroupId, east.id);
        final active = await (adminDb.select(
          adminDb.studentEnrolments,
        )..where((t) => t.status.equals('active'))).get();
        expect(active.single.uuid, approved.uuid);
        expect(await sync(phone), isNull);
        expect(await adminLearners(), ['Amina']);
        expect(
          await adminDb.select(adminDb.studentEnrolments).get(),
          hasLength(2),
        );
      },
    );

    test('learners registered on the Class Teacher’s device reach the Admin',
        () async {
      final phone = device();
      expect(await sync(phone), isNull);
      final okello = await teacherId(phone, 'Mr Okello');
      final service = ClassTeacherService(phone, policyOf(phone));
      final mine = await service.classesOf(okello);
      expect(mine.map((c) => c.streamName), ['East']);

      for (final name in ['Amina', 'Brian']) {
        expect(
          await service.register(teacherId: okello, name: name, group: mine.single,
            ),
          isNull,
        );
      }
      final westHere = (await phone.select(phone.classGroups).get())
          .firstWhere((c) => c.streamName == 'West');
      expect(
        await service.register(teacherId: okello, name: 'Cate', group: westHere,
          ),
        isNotNull,
        reason: 'not one of his classes',
      );
      final waiting = await service.watchRegistered(okello).first;
      expect(waiting.map((r) => r.withAdmin), [false, false]);

      expect(await sync(phone), isNull);
      expect(asked.last, {'Mr Okello': 2});
      expect(await adminLearners(), ['Amina', 'Brian']);
      final enrolled = await adminDb.select(adminDb.studentEnrolments).get();
      expect(enrolled.map((e) => e.classGroupUuid).toSet(), {east.groupUuid});
      final onAdmin = await (adminDb.select(
        adminDb.learnerRegistrations,
      )).get();
      expect(onAdmin.length, 2, reason: 'the Admin sees who registered whom');

      // Back on the phone: the records hold them, so they're with the Admin,
      // still in their class, and never doubled.
      final after = await service.watchRegistered(okello).first;
      expect(after.map((r) => r.withAdmin), [true, true]);
      final phoneLearners = await phone.select(phone.students).get();
      expect(phoneLearners.length, 2);
      final eastHere = (await phone.select(phone.classGroups).get())
          .firstWhere((c) => c.streamName == 'East');
      expect(phoneLearners.every((s) => s.classGroupId == eastHere.id), isTrue,
        );

      expect(await sync(phone), isNull);
      expect(await adminLearners(), ['Amina', 'Brian']);
    },
    );

    test('declined: nothing is taken and the registrations wait', () async {
      final phone = device();
      expect(await sync(phone), isNull);
      final okello = await teacherId(phone, 'Mr Okello');
      final service = ClassTeacherService(phone, policyOf(phone));
      final group = (await service.classesOf(okello)).single;
      await service.register(teacherId: okello, name: 'Amina', group: group);

      accept = false;
      expect(await sync(phone), isNotNull);
      expect(await adminLearners(), isEmpty);
      expect(
        (await service.watchRegistered(okello).first).single.withAdmin,
        isFalse,
      );
    });

    test('a registration into a class the Admin didn’t give is refused, '
        'and audited', () async {
      final phone = device();
      expect(await sync(phone), isNull);
      final okello = await teacherId(phone, 'Mr Okello');
      final service = ClassTeacherService(phone, policyOf(phone));
      final group = (await service.classesOf(okello)).single;
      await service.register(teacherId: okello, name: 'Amina', group: group);
      // The Admin takes East away before the phone syncs.
      await admin.setClassTeacherClasses(
        session,
        await teacherId(adminDb, 'Mr Okello'),
        {west.groupUuid!},
      );
      expect(await sync(phone), isNull);
      expect(await adminLearners(), isEmpty);
      final audit = await adminDb.select(adminDb.auditLog).get();
      expect(audit.map((a) => a.action), contains('refused.registration'));
      // Still waiting on the phone, in its class.
      final reg = (await service.watchRegistered(okello).first).single;
      expect(reg.withAdmin, isFalse);
      final enrolment = await phone.select(phone.studentEnrolments).get();
      expect(enrolment.map((e) => e.classGroupUuid), contains(east.groupUuid));
    });
  });

  test('a v34 database upgrades to v35', () async {
    final dir = await Directory.systemTemp.createTemp('otic_migration_35');
    addTearDown(() => dir.delete(recursive: true));
    final file = File(p.join(dir.path, 'test.sqlite'));
    final seed = OticDatabase.forTesting(NativeDatabase(file));
    await seed.into(seed.students).insert(StudentsCompanion.insert(name: 'A'));
    await seed.customStatement('DROP TABLE class_teacher_assignments');
    await seed.customStatement('DROP TABLE learner_registrations');
    await seed.customStatement('PRAGMA user_version = 34');
    await seed.close();
    for (var run = 0; run < 2; run++) {
      final up = OticDatabase.forTesting(NativeDatabase(file));
      expect((await up.select(up.students).get()).single.name, 'A');
      expect(await up.select(up.classTeacherAssignments).get(), isEmpty);
      expect(await up.select(up.learnerRegistrations).get(), isEmpty);
      await up.customStatement('PRAGMA user_version = 34');
      await up.close();
    }
  });
}
