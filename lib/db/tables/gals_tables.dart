import 'package:drift/drift.dart';

/// GALS is community field work, separate from school students and teachers.
class GalsChampions extends Table {
  TextColumn get id => text()();
  TextColumn get displayName => text()();
  TextColumn get groupName => text().nullable()();
  TextColumn get sex => text().nullable()();
  TextColumn get ageBand => text().nullable()();
  TextColumn get location => text().nullable()();
  TextColumn get trainingAt => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  @override
  Set<Column> get primaryKey => {id};
}

class GalsSharingSessions extends Table {
  TextColumn get id => text()();
  TextColumn get championId => text()();
  // Null on records made before the complete learning journey shipped.
  TextColumn get lessonId => text().nullable()();
  TextColumn get occurredAt => text()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  @override
  Set<Column> get primaryKey => {id};
}

/// Completion is scoped to a community champion and an immutable pack version,
/// never to whichever school learner happens to be active on a shared device.
class GalsLessonCompletions extends Table {
  TextColumn get championId => text()();
  TextColumn get packId => text()();
  TextColumn get contentVersion => text()();
  TextColumn get lessonId => text()();
  TextColumn get reflection => text()();
  TextColumn get completedAt => text()();
  @override
  Set<Column> get primaryKey => {championId, packId, contentVersion, lessonId};
}

class GalsSessionTools extends Table {
  TextColumn get sessionId => text()();
  TextColumn get packId => text()();
  TextColumn get toolId => text()();
  TextColumn get contentVersion => text()();
  @override
  Set<Column> get primaryKey => {sessionId, packId, toolId, contentVersion};
}

/// Aggregate attendance, never a roster of identifiable peers.
class GalsSessionAttendance extends Table {
  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get sex => text()();
  TextColumn get ageBand => text()();
  TextColumn get location => text()();
  IntColumn get count => integer()();
  TextColumn get createdAt => text()();
  @override
  Set<Column> get primaryKey => {id};
}

/// A deliberately small reflection record. It never stores a drawing, photo,
/// voice note, relationship map or other evidence from a participant's paper.
class GalsAchievementReviews extends Table {
  TextColumn get id => text()();
  TextColumn get championId => text()();
  TextColumn get packId => text()();
  TextColumn get contentVersion => text()();
  TextColumn get toolId => text()();
  TextColumn get reviewedAt => text()();
  TextColumn get goal => text().nullable()();
  TextColumn get progress => text().nullable()();
  TextColumn get enablingFactors => text().nullable()();
  TextColumn get challenges => text().nullable()();
  TextColumn get nextSteps => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  @override
  Set<Column> get primaryKey => {id};
}
