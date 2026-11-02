import 'package:drift/drift.dart';

import 'students_table.dart';

/// Subjects registered automatically when a teacher shares class materials
/// and the learner joins or syncs. Reading access follows the current class;
/// these records also keep the learner's subject history.
@TableIndex(
  name: 'idx_learner_subjects_unique',
  columns: {#studentId, #subjectId},
  unique: true,
)
class LearnerSubjects extends Table {
  @override
  String get tableName => 'learner_subjects';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get studentId =>
      integer().references(Students, #id, onDelete: KeyAction.cascade)();
  TextColumn get subjectId => text()();

  /// ISO-8601 UTC.
  TextColumn get enrolledAt => text()();
}
