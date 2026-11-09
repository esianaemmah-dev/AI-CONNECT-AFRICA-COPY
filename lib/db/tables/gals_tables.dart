import 'package:drift/drift.dart';

/// GALS is community field work, separate from school students and teachers.
class GalsChampions extends Table {
  TextColumn get id => text()();
  TextColumn get displayName => text()();
  TextColumn get sex => text().nullable()();
  TextColumn get ageBand => text().nullable()();
  TextColumn get location => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  @override
  Set<Column> get primaryKey => {id};
}

class GalsSharingSessions extends Table {
  TextColumn get id => text()();
  TextColumn get championId => text()();
  TextColumn get occurredAt => text()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  @override
  Set<Column> get primaryKey => {id};
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
