import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../db/otic_database.dart';
import '../../db/providers/db_provider.dart';
import 'gals_pack.dart';

/// Local-only field records. There is deliberately no cloud/outbox hook.
class GalsFieldStore {
  GalsFieldStore(this.db);

  final OticDatabase db;
  static const _uuid = Uuid();

  Future<String> addChampion(String displayName) async {
    final name = displayName.trim();
    if (name.isEmpty) throw ArgumentError('Champion name is required');
    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    await db
        .into(db.galsChampions)
        .insert(
          GalsChampionsCompanion.insert(
            id: id,
            displayName: name,
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  Future<List<GalsChampion>> champions() => (db.select(
    db.galsChampions,
  )..orderBy([(t) => OrderingTerm.asc(t.displayName)])).get();

  /// Atomically records one event, its pack reference and one aggregate
  /// attendance category. These counts are *visits*, never unique people.
  Future<String> recordSharing({
    required String championId,
    required GalsPack pack,
    required String toolId,
    required DateTime occurredAt,
    required String sex,
    required String ageBand,
    required String location,
    required int attendance,
  }) async {
    if (pack.tool(toolId) == null) throw ArgumentError('Unknown pack tool');
    if (!{'female', 'male', 'another', 'not_recorded'}.contains(sex) ||
        ageBand.trim().isEmpty ||
        location.trim().isEmpty ||
        attendance < 1) {
      throw ArgumentError(
        'Attendance needs a category, age band, location and positive count',
      );
    }
    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction(() async {
      final champion = await (db.select(
        db.galsChampions,
      )..where((t) => t.id.equals(championId))).getSingleOrNull();
      if (champion == null) throw ArgumentError('Champion not found');
      await db
          .into(db.galsSharingSessions)
          .insert(
            GalsSharingSessionsCompanion.insert(
              id: id,
              championId: championId,
              occurredAt: occurredAt.toUtc().toIso8601String(),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await db
          .into(db.galsSessionTools)
          .insert(
            GalsSessionToolsCompanion.insert(
              sessionId: id,
              packId: pack.id,
              toolId: toolId,
              contentVersion: pack.version,
            ),
          );
      await db
          .into(db.galsSessionAttendance)
          .insert(
            GalsSessionAttendanceCompanion.insert(
              id: _uuid.v4(),
              sessionId: id,
              sex: sex,
              ageBand: ageBand.trim(),
              location: location.trim(),
              count: attendance,
              createdAt: now,
            ),
          );
    });
    return id;
  }

  Future<List<GalsSharingRecord>> sharingFor(String championId) async {
    final sessions =
        await (db.select(db.galsSharingSessions)
              ..where((t) => t.championId.equals(championId))
              ..orderBy([(t) => OrderingTerm.desc(t.occurredAt)]))
            .get();
    final result = <GalsSharingRecord>[];
    for (final session in sessions) {
      final tools = await (db.select(
        db.galsSessionTools,
      )..where((t) => t.sessionId.equals(session.id))).get();
      final attendance = await (db.select(
        db.galsSessionAttendance,
      )..where((t) => t.sessionId.equals(session.id))).get();
      result.add(GalsSharingRecord(session, tools, attendance));
    }
    return result;
  }
}

class GalsSharingRecord {
  const GalsSharingRecord(this.session, this.tools, this.attendance);
  final GalsSharingSession session;
  final List<GalsSessionTool> tools;
  final List<GalsSessionAttendanceData> attendance;

  int get sessionAttendances =>
      attendance.fold(0, (total, group) => total + group.count);
}

final galsFieldStoreProvider = Provider(
  (ref) => GalsFieldStore(ref.watch(dbProvider)),
);
