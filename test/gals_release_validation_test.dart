import 'dart:convert';
import 'dart:io';

import 'package:ai_connect_africa/db/otic_database.dart';
import 'package:ai_connect_africa/features/gals/gals_field_store.dart';
import 'package:ai_connect_africa/features/gals/gals_pack.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('schema 40 upgrade preserves existing champion records', () async {
    final dir = await Directory.systemTemp.createTemp('gals_migration_');
    final file = File('${dir.path}/old.sqlite');
    var db = OticDatabase.forTesting(DatabaseConnection(NativeDatabase(file)));
    try {
      final id = await GalsFieldStore(db).addChampion('Legacy Example');
      await db.customStatement('DROP TABLE gals_achievement_reviews');
      await db.customStatement('ALTER TABLE gals_champions DROP COLUMN group_name');
      await db.customStatement('ALTER TABLE gals_champions DROP COLUMN training_at');
      await db.customStatement('PRAGMA user_version = 40');
      await db.close();
      db = OticDatabase.forTesting(DatabaseConnection(NativeDatabase(file)));
      final champion = (await GalsFieldStore(db).champions()).single;
      expect(champion.id, id);
      expect(champion.displayName, 'Legacy Example');
      expect(champion.groupName, isNull);
      expect(await db.select(db.galsAchievementReviews).get(), isEmpty);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('catalog retains historic versions and all five draft tools', () async {
    final catalog = await GalsPackCatalog.load();
    expect(catalog.find('gals-foundation', '1.0.0-draft.1'), isNotNull);
    expect(catalog.find('gals-foundation', '1.0.0-draft.2'), isNotNull);
    for (final id in [
      'vision-road-journey',
      'gender-balance-tree',
      'empowerment-leadership-map',
      'challenge-action-tree',
      'achievement-road-journey',
    ]) {
      final tool = catalog.active.tool(id)!;
      expect(tool.steps, isNotEmpty);
      expect(tool.purpose, isNotEmpty);
      expect(tool.preparation, isNotEmpty);
      expect(tool.facilitatorPrompts, isNotEmpty);
    }
    final json =
        jsonDecode(
              await rootBundle.loadString(
                'assets/gals/packs/gals-foundation-v3.json',
              ),
            )
            as Map<String, dynamic>;
    json['lessons'][1]['toolId'] = 'missing-tool';
    expect(() => GalsPack.fromJson(json), throwsFormatException);
  });

  test(
    'completion is version-scoped, checked, and never overwritten',
    () async {
      final db = OticDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      addTearDown(db.close);
      final store = GalsFieldStore(db);
      final catalog = await GalsPackCatalog.load();
      final pack = catalog.active;
      final id = await store.addChampion('Example Champion');
      final lesson = pack.lesson('vision-road-journey-lesson')!;
      Future<void> complete(Map<String, int> answers, String reflection) =>
          store.completeLesson(
            championId: id,
            pack: pack,
            lessonId: lesson.id,
            answers: answers,
            reflection: reflection,
          );
      await expectLater(complete({}, 'Test'), throwsArgumentError);
      final answers = {for (final q in lesson.quiz) q.id: q.correct};
      await complete(answers, 'First reflection');
      await complete(answers, 'Replacement');
      await store.recordSharing(
        championId: id,
        pack: pack,
        toolId: lesson.toolId!,
        lessonId: lesson.id,
        occurredAt: DateTime.utc(2026),
        sex: 'female',
        ageBand: 'adult',
        location: 'Fictional place',
        attendance: 3,
        additionalGroups: const [GalsAttendanceGroup('male', 'adult', 2)],
      );
      final sessions = await store.sharingFor(id);
      expect(sessions, hasLength(1));
      expect(sessions.single.attendance, hasLength(2));
      expect(sessions.single.sessionAttendances, 5);
      expect(
        (await store.completion(
          championId: id,
          pack: pack,
          lessonId: lesson.id,
        ))!.reflection,
        'First reflection',
      );
      expect(
        await store.completion(
          championId: id,
          pack: catalog.find(pack.id, '1.0.0-draft.2')!,
          lessonId: lesson.id,
        ),
        isNull,
      );
      expect(await db.select(db.cloudOutbox).get(), isEmpty);
    },
  );

  test(
    'optional review and champion details survive reopening without disclosure',
    () async {
      final dir = await Directory.systemTemp.createTemp('gals_review_');
      final file = File('${dir.path}/records.sqlite');
      var db = OticDatabase.forTesting(
        DatabaseConnection(NativeDatabase(file)),
      );
      try {
        final store = GalsFieldStore(db);
        final pack = await GalsPack.load();
        final id = await store.addChampion(
          'Fictional Champion',
          groupName: 'Example group',
          trainingAt: DateTime.utc(2026, 1, 1),
        );
        final review = await store.recordAchievementReview(
          championId: id,
          pack: pack,
          toolId: 'achievement-road-journey',
          reviewedAt: DateTime.utc(2026, 1, 2),
        );
        await db.close();
        db = OticDatabase.forTesting(DatabaseConnection(NativeDatabase(file)));
        final reopened = GalsFieldStore(db);
        expect((await reopened.champions()).single.groupName, 'Example group');
        final saved = (await reopened.achievementReviewsFor(id)).single;
        expect(saved.id, review);
        expect(saved.goal, isNull);
        expect(saved.progress, isNull);
        expect(saved.challenges, isNull);
        expect(await db.select(db.cloudOutbox).get(), isEmpty);
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
