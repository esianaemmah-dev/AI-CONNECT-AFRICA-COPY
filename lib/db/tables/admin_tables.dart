import 'package:drift/drift.dart';

/// The school's one Admin, on the device where they sign in.
///
/// The Admin keeps the school's records: teachers, classes and streams,
/// subjects, teaching assignments, learners and their enrolments. Only the
/// Admin changes them; every device runs the same app, and the Admin syncs
/// the records from their device to another, one way. Single row (id 1).
@DataClassName('AdminIdentityRow')
class AdminIdentity extends Table {
  TextColumn get recoverySalt => text().nullable()();
  TextColumn get recoveryHash => text().nullable()();
  @override
  String get tableName => 'admin_identity';

  IntColumn get id => integer()();
  TextColumn get name => text()();

  /// Salted hash of the Admin's PIN, used to check sign-in.
  TextColumn get pinSalt => text()();
  TextColumn get pinHash => text()();

  /// The PIN in the clear, so a signed-in Admin can see and note it down.
  /// Null for an Admin set up before this was stored.
  TextColumn get pinPlain => text().nullable()();

  /// ISO-8601 UTC.
  TextColumn get createdAt => text()();

  /// The Admin's Ed25519 signing seed: every bundle of school records the
  /// Admin sends is signed with it. Minted on first send.
  TextColumn get signingSeed => text().nullable()();

  /// Version of the last bundle sent; each send goes one higher.
  IntColumn get recordsVersion => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// On a device that received the Admin's school records: whose they are
/// and which version, so only that Admin's newer records are ever taken.
/// Single row (id 1).
@DataClassName('AdminRecordsStateRow')
class AdminRecordsState extends Table {
  @override
  String get tableName => 'admin_records_state';

  IntColumn get id => integer()();

  /// The Admin key pinned by the first records this device took.
  TextColumn get adminPublicKey => text()();
  IntColumn get version => integer()();
  TextColumn get schoolId => text()();

  /// ISO-8601 UTC.
  TextColumn get receivedAt => text()();

  /// The Admin's details sealed under their passphrase, when sent so the
  /// Admin can take over here; cleared once they do.
  TextColumn get takeoverJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// A teacher assigned by the Admin to teach one subject to one
/// class/stream, in an academic year and term. What a teacher may change,
/// share and sync follows from these, never from who created what.
@DataClassName('TeachingAssignment')
@TableIndex(name: 'idx_teaching_assignments_teacher', columns: {#teacherId})
class TeachingAssignments extends Table {
  @override
  String get tableName => 'teaching_assignments';

  IntColumn get id => integer().autoIncrement()();

  /// Portable id, the same on every device the records reach.
  TextColumn get uuid => text().unique()();

  /// `teacher_profiles.id`.
  IntColumn get teacherId => integer()();

  /// `class_groups.group_uuid` — the class/stream.
  TextColumn get classGroupUuid => text()();
  TextColumn get subjectId => text()();
  IntColumn get academicYear => integer()();

  /// 1, 2 or 3; 0 for the whole year.
  IntColumn get term => integer().withDefault(const Constant(0))();

  /// ISO-8601 UTC.
  TextColumn get createdAt => text()();
}

/// A learner enrolled by the Admin in one class/stream for an academic
/// year. `students.class_group_id` mirrors the active one.
@DataClassName('StudentEnrolment')
@TableIndex(name: 'idx_student_enrolments_student', columns: {#studentId})
class StudentEnrolments extends Table {
  @override
  String get tableName => 'student_enrolments';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get uuid => text().unique()();

  /// `students.id`.
  IntColumn get studentId => integer()();
  TextColumn get classGroupUuid => text()();
  IntColumn get academicYear => integer()();

  /// 'active' or 'withdrawn'. A withdrawn enrolment is kept, never deleted.
  TextColumn get status => text().withDefault(const Constant('active'))();

  /// ISO-8601 UTC.
  TextColumn get createdAt => text()();
}

/// Which teacher uploaded each of this device's notes, so teachers who
/// share a subject can't change each other's materials. Keyed like
/// `resource_shares`: (subject, document title). Local only, never synced.
@DataClassName('NoteOwner')
class NoteOwners extends Table {
  @override
  String get tableName => 'note_owners';

  TextColumn get subjectId => text()();
  TextColumn get documentTitle => text()();

  /// `teacher_profiles.id`.
  IntColumn get teacherId => integer()();

  @override
  Set<Column> get primaryKey => {subjectId, documentTitle};
}

/// Subjects a teacher made for themselves in Lesson materials, so they can
/// upload notes before the Admin assigns them a class. They let the teacher
/// upload and change notes on this device only; sharing into a class still
/// needs a teaching assignment. Local only, never in the Admin's records,
/// so an Admin sync (which replaces assignments whole) leaves them alone.
@DataClassName('TeacherSubject')
class TeacherSubjects extends Table {
  @override
  String get tableName => 'teacher_subjects';

  /// `teacher_profiles.id`.
  IntColumn get teacherId => integer()();
  TextColumn get subjectId => text()();

  /// ISO-8601 UTC.
  TextColumn get createdAt => text()();

  @override
  Set<Column> get primaryKey => {teacherId, subjectId};
}

/// Built-in subjects the school's Admin removed. They stay in the app's
/// assets but are no longer shown, and their names are free for the
/// school's own subjects. Part of the Admin's records.
@DataClassName('RemovedSubject')
class RemovedSubjects extends Table {
  @override
  String get tableName => 'removed_subjects';

  TextColumn get subjectId => text()();

  /// ISO-8601 UTC.
  TextColumn get removedAt => text()();

  @override
  Set<Column> get primaryKey => {subjectId};
}

/// A Class Teacher's classes/streams (schema 35): the Admin enrols the
/// Class Teacher and picks which classes/streams they may register learners
/// into. Registering learners is all the role allows. Part of the Admin's
/// records; replaced whole on receipt.
@DataClassName('ClassTeacherAssignment')
@TableIndex(name: 'idx_class_teacher_teacher', columns: {#teacherId})
class ClassTeacherAssignments extends Table {
  @override
  String get tableName => 'class_teacher_assignments';

  IntColumn get id => integer().autoIncrement()();

  /// Portable id, the same on every device the records reach.
  TextColumn get uuid => text().unique()();

  /// `teacher_profiles.id`.
  IntColumn get teacherId => integer()();

  /// `class_groups.group_uuid` — the class/stream.
  TextColumn get classGroupUuid => text()();

  /// ISO-8601 UTC.
  TextColumn get createdAt => text()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {teacherId, classGroupUuid},
  ];
}

/// A learner a Class Teacher registered (schema 35). On the Class Teacher's
/// device it waits here until the Admin's device has taken it ([sentAt]);
/// on the Admin's device it records who registered whom.
@DataClassName('LearnerRegistration')
class LearnerRegistrations extends Table {
  @override
  String get tableName => 'learner_registrations';

  IntColumn get id => integer().autoIncrement()();

  /// `students.id`.
  IntColumn get studentId => integer()();

  /// `teacher_profiles.id`.
  IntColumn get teacherId => integer()();
  TextColumn get classGroupUuid => text()();

  /// The enrolment it created (`student_enrolments.uuid`).
  TextColumn get enrolmentUuid => text()();

  /// ISO-8601 UTC.
  TextColumn get createdAt => text()();

  /// ISO-8601 UTC: the Admin's device took it. Null until then (always set
  /// on the Admin's device).
  TextColumn get sentAt => text().nullable()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {studentId},
  ];
}
