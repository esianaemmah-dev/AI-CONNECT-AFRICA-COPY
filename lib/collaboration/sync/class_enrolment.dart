import 'package:drift/drift.dart';

import '../../db/otic_database.dart';
import '../../features/teacher/teaching_scope.dart';
import 'sync_ids.dart';

/// A teacher's approval creates the same portable enrolment on both devices.
/// School-record sync can then carry it to the Admin and other devices.
class ClassEnrolment {
  ClassEnrolment(this.db);

  final OticDatabase db;

  Future<String> learnerUuid(int studentId) => db.transaction(() async {
    final student = await db.studentDao.getStudentById(studentId);
    if (student == null) throw StateError('Choose a learner first.');
    if (student.uuid != null) return student.uuid!;
    final uuid = newSyncId();
    await (db.update(db.students)..where((t) => t.id.equals(studentId))).write(
      StudentsCompanion(uuid: Value(uuid)),
    );
    return uuid;
  });

  Future<StudentEnrolment> enrol({
    required int studentId,
    required ClassGroup group,
    String? enrolmentUuid,
    int? academicYear,
  }) => db.transaction(() async {
    final year = academicYear ?? DateTime.now().year;
    final current =
        await (db.select(db.studentEnrolments)
              ..where((t) => t.studentId.equals(studentId))
              ..where((t) => t.classGroupUuid.equals(group.groupUuid!))
              ..where((t) => t.academicYear.equals(year))
              ..where((t) => t.status.equals('active')))
            .get();
    final uuid =
        enrolmentUuid ?? (current.isEmpty ? newSyncId() : current.first.uuid);
    final previous = await (db.select(
      db.studentEnrolments,
    )..where((t) => t.uuid.equals(uuid))).getSingleOrNull();
    if (previous != null &&
        (previous.studentId != studentId ||
            previous.classGroupUuid != group.groupUuid)) {
      throw StateError('This enrolment belongs to another learner or class.');
    }
    await (db.update(db.studentEnrolments)
          ..where((t) => t.studentId.equals(studentId))
          ..where((t) => t.status.equals('active'))
          ..where((t) => t.uuid.equals(uuid).not()))
        .write(const StudentEnrolmentsCompanion(status: Value('withdrawn')));
    if (previous == null) {
      await db
          .into(db.studentEnrolments)
          .insert(
            StudentEnrolmentsCompanion.insert(
              uuid: uuid,
              studentId: studentId,
              classGroupUuid: group.groupUuid!,
              academicYear: year,
              status: const Value('active'),
              createdAt: DateTime.now().toUtc().toIso8601String(),
            ),
          );
    } else {
      await (db.update(db.studentEnrolments)
            ..where((t) => t.id.equals(previous.id)))
          .write(const StudentEnrolmentsCompanion(status: Value('active')));
    }
    await db.classGroupDao.assignLearner(studentId, group.id);
    return (db.select(
      db.studentEnrolments,
    )..where((t) => t.uuid.equals(uuid))).getSingle();
  });

  /// Called only after the teacher accepts the join request. Match by UUID,
  /// never by name: two learners can have the same name.
  Future<StudentEnrolment> approve({
    required String learnerUuid,
    required String name,
    required ClassGroup group,
    int? teacherId,
  }) => db.transaction(() async {
    if (teacherId != null && !await mayEnrol(teacherId, group.groupUuid!)) {
      throw StateError('This teacher is not assigned to this class.');
    }
    final existing = await (db.select(
      db.students,
    )..where((t) => t.uuid.equals(learnerUuid))).getSingleOrNull();
    final id =
        existing?.id ??
        await db.studentDao.createStudent(
          StudentsCompanion.insert(name: name.trim(), uuid: Value(learnerUuid)),
        );
    final enrolment = await enrol(studentId: id, group: group);
    if (teacherId != null) {
      final registration = await (db.select(
        db.learnerRegistrations,
      )..where((t) => t.studentId.equals(id))).getSingleOrNull();
      if (registration?.enrolmentUuid != enrolment.uuid) {
        final values = LearnerRegistrationsCompanion.insert(
          studentId: id,
          teacherId: teacherId,
          classGroupUuid: group.groupUuid!,
          enrolmentUuid: enrolment.uuid,
          createdAt: enrolment.createdAt,
          sentAt: const Value(null),
        );
        await db
            .into(db.learnerRegistrations)
            .insert(
              values,
              onConflict: DoUpdate(
                (_) => values,
                target: [db.learnerRegistrations.studentId],
              ),
            );
      }
    }
    return enrolment;
  });

  Future<bool> mayEnrol(int teacherId, String classUuid) async {
    final scope = TeachingScope(db);
    return (await scope.classTeacherOf(teacherId)).contains(classUuid) ||
        (await scope.assignments(
          teacherId,
        )).any((a) => a.classGroupUuid == classUuid);
  }
}
