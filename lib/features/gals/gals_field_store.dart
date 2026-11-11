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

  Future<String> addChampion(
    String displayName, {
    String? groupName,
    String? sex,
    String? ageBand,
    String? location,
    DateTime? trainingAt,
  }) async {
    final name = displayName.trim();
    if (name.isEmpty || name.length > 80) {
      throw ArgumentError('Use a champion alias of 1–80 characters');
    }
    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    await db
        .into(db.galsChampions)
        .insert(
          GalsChampionsCompanion.insert(
            id: id,
            displayName: name,
            groupName: Value(_optional(groupName, 80)),
            sex: Value(_optionalChoice(sex)),
            ageBand: Value(_optional(ageBand, 80)),
            location: Value(_optional(location, 120)),
            trainingAt: Value(trainingAt?.toUtc().toIso8601String()),
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  String? _optional(String? value, int maxLength) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return null;
    if (text.length > maxLength) {
      throw ArgumentError('Text must be at most $maxLength characters');
    }
    return text;
  }

  String? _optionalChoice(String? value) {
    if (value == null || value == 'not_recorded') return null;
    if (!{'female', 'male', 'another'}.contains(value)) {
      throw ArgumentError('Choose a valid category');
    }
    return value;
  }

  Future<List<GalsChampion>> champions() => (db.select(
    db.galsChampions,
  )..orderBy([(t) => OrderingTerm.asc(t.displayName)])).get();

  Future<GalsLessonCompletion?> completion({
    required String championId,
    required GalsPack pack,
    required String lessonId,
  }) =>
      (db.select(db.galsLessonCompletions)..where(
            (t) =>
                t.championId.equals(championId) &
                t.packId.equals(pack.id) &
                t.contentVersion.equals(pack.version) &
                t.lessonId.equals(lessonId),
          ))
          .getSingleOrNull();

  /// Reuses the platform's local lesson + checked quiz pattern, but keeps
  /// community progress separate from school learner progress. The first
  /// completion is immutable so later sessions retain the original reflection.
  Future<void> completeLesson({
    required String championId,
    required GalsPack pack,
    required String lessonId,
    required Map<String, int> answers,
    required String reflection,
  }) async {
    final lesson = pack.lesson(lessonId);
    if (lesson == null ||
        lesson.toolId == null ||
        lesson.sessionPlanId == null) {
      throw ArgumentError('Choose a lesson with a tool and peer-session plan');
    }
    if (answers.length != lesson.quiz.length ||
        !lesson.quiz.every((q) => answers[q.id] == q.correct)) {
      throw ArgumentError('Check each practice question before completing');
    }
    final summary = reflection.trim();
    if (summary.isEmpty || summary.length > 600) {
      throw ArgumentError('Write a short reflection of 1–600 characters');
    }
    await db.transaction(() async {
      await _requireChampion(championId);
      await db
          .into(db.galsLessonCompletions)
          .insert(
            GalsLessonCompletionsCompanion.insert(
              championId: championId,
              packId: pack.id,
              contentVersion: pack.version,
              lessonId: lessonId,
              reflection: summary,
              completedAt: DateTime.now().toUtc().toIso8601String(),
            ),
            mode: InsertMode.insertOrIgnore,
          );
    });
  }

  Future<void> _requireChampion(String id) async {
    final champion = await (db.select(
      db.galsChampions,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (champion == null) throw ArgumentError('Champion not found');
  }

  /// Atomically records one event, its pack reference and one aggregate
  /// attendance category. These counts are *visits*, never unique people.
  Future<String> recordSharing({
    required String championId,
    required GalsPack pack,
    required String toolId,
    required String lessonId,
    required DateTime occurredAt,
    required String sex,
    required String ageBand,
    required String location,
    required int attendance,
    List<GalsAttendanceGroup> additionalGroups = const [],
  }) async {
    for (final group in additionalGroups) {
      group.validate();
    }
    if (pack.tool(toolId) == null || pack.lesson(lessonId)?.toolId != toolId) {
      throw ArgumentError('Unknown or mismatched lesson and tool');
    }
    if (!{'female', 'male', 'another', 'not_recorded'}.contains(sex) ||
        ageBand.trim().isEmpty ||
        ageBand.trim().length > 80 ||
        location.trim().isEmpty ||
        location.trim().length > 120 ||
        attendance < 1 ||
        attendance > 10000 ||
        occurredAt.isAfter(DateTime.now())) {
      throw ArgumentError(
        'Use a past or current date, category, age band, location and count of 1–10000',
      );
    }
    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction(() async {
      await _requireChampion(championId);
      if (await completion(
            championId: championId,
            pack: pack,
            lessonId: lessonId,
          ) ==
          null) {
        throw StateError('Complete this lesson version for the champion first');
      }
      await db
          .into(db.galsSharingSessions)
          .insert(
            GalsSharingSessionsCompanion.insert(
              id: id,
              championId: championId,
              lessonId: Value(lessonId),
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
      for (final group in additionalGroups) {
        await db
            .into(db.galsSessionAttendance)
            .insert(
              GalsSessionAttendanceCompanion.insert(
                id: _uuid.v4(),
                sessionId: id,
                sex: group.sex,
                ageBand: group.ageBand.trim(),
                location: location.trim(),
                count: group.count,
                createdAt: now,
              ),
            );
      }
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

  /// Saves a voluntary, short progress reflection. Blank prompts stay blank;
  /// the app must not pressure a champion to disclose a goal or drawing.
  Future<String> recordAchievementReview({
    required String championId,
    required GalsPack pack,
    required String toolId,
    required DateTime reviewedAt,
    String? goal,
    String? progress,
    String? enablingFactors,
    String? challenges,
    String? nextSteps,
  }) async {
    if (pack.tool(toolId) == null || reviewedAt.isAfter(DateTime.now())) {
      throw ArgumentError('Choose a current or past date and a bundled tool');
    }
    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction(() async {
      await _requireChampion(championId);
      await db
          .into(db.galsAchievementReviews)
          .insert(
            GalsAchievementReviewsCompanion.insert(
              id: id,
              championId: championId,
              packId: pack.id,
              contentVersion: pack.version,
              toolId: toolId,
              reviewedAt: reviewedAt.toUtc().toIso8601String(),
              goal: Value(_optional(goal, 600)),
              progress: Value(_optional(progress, 600)),
              enablingFactors: Value(_optional(enablingFactors, 600)),
              challenges: Value(_optional(challenges, 600)),
              nextSteps: Value(_optional(nextSteps, 600)),
              createdAt: now,
              updatedAt: now,
            ),
          );
    });
    return id;
  }

  Future<List<GalsAchievementReview>> achievementReviewsFor(
    String championId,
  ) =>
      (db.select(db.galsAchievementReviews)
            ..where((t) => t.championId.equals(championId))
            ..orderBy([(t) => OrderingTerm.desc(t.reviewedAt)]))
          .get();
}

class GalsAttendanceGroup {
  const GalsAttendanceGroup(this.sex, this.ageBand, this.count);
  final String sex;
  final String ageBand;
  final int count;

  void validate() {
    if (!{'female', 'male', 'another', 'not_recorded'}.contains(sex) ||
        ageBand.trim().isEmpty ||
        ageBand.trim().length > 80 ||
        count < 1 ||
        count > 10000) {
      throw ArgumentError('Use a category, age band and count of 1–10000');
    }
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
