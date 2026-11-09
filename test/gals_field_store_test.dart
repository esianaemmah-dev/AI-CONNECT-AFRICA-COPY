import 'dart:io';

import 'package:ai_connect_africa/db/otic_database.dart';
import 'package:ai_connect_africa/features/gals/gals_field_store.dart';
import 'package:ai_connect_africa/features/gals/gals_pack.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundled draft tool is English, credited and contains no audio',
    () async {
      final pack = await GalsPack.load();
      expect(pack.id, 'gals-foundation');
      expect(pack.status, 'draft');
      expect(pack.tool('vision-road-journey')!.steps, isNotEmpty);
      expect(
        pack.tool('vision-road-journey')!.steps.every((s) => !s.hasAudio),
        isTrue,
      );
    },
  );

  test(
    'champion and pack-linked sharing survive closing and reopening offline',
    () async {
      final temp = await Directory.systemTemp.createTemp('gals_field_test_');
      final file = File('${temp.path}${Platform.pathSeparator}field.sqlite');
      final pack = await GalsPack.load();
      var db = OticDatabase.forTesting(
        DatabaseConnection(NativeDatabase(file)),
      );
      try {
        final store = GalsFieldStore(db);
        final championId = await store.addChampion('Amina Test'); // fictional
        final sessionId = await store.recordSharing(
          championId: championId,
          pack: pack,
          toolId: 'vision-road-journey',
          occurredAt: DateTime.utc(2026, 11, 4, 12),
          sex: 'female',
          ageBand: 'adult (test category)',
          location: 'Fictional village',
          attendance: 5,
        );
        await db.close();
        db = OticDatabase.forTesting(DatabaseConnection(NativeDatabase(file)));
        final reopened = GalsFieldStore(db);
        expect((await reopened.champions()).single.id, championId);
        final events = await reopened.sharingFor(championId);
        expect(events, hasLength(1));
        expect(events.single.session.id, sessionId);
        expect(events.single.sessionAttendances, 5);
        expect(events.single.attendance.single.location, 'Fictional village');
        expect(events.single.tools.single.packId, pack.id);
        expect(events.single.tools.single.contentVersion, pack.version);
        expect(events.single.tools.single.toolId, 'vision-road-journey');
        expect(await db.select(db.cloudOutbox).get(), isEmpty);
      } finally {
        await db.close();
        await temp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'rejects missing champion, unknown tool and invalid attendance without partial rows',
    () async {
      final db = OticDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      try {
        final store = GalsFieldStore(db);
        final pack = await GalsPack.load();
        final champion = await store.addChampion('Kato Example'); // fictional
        Future<void> save(String who, String tool, int count) => store
            .recordSharing(
              championId: who,
              pack: pack,
              toolId: tool,
              occurredAt: DateTime.utc(2026),
              sex: 'not_recorded',
              ageBand: 'unknown',
              location: 'Fictional village',
              attendance: count,
            )
            .then((_) {});
        await expectLater(
          save('absent', 'vision-road-journey', 3),
          throwsArgumentError,
        );
        await expectLater(
          save(champion, 'missing-tool', 3),
          throwsArgumentError,
        );
        await expectLater(
          save(champion, 'vision-road-journey', -1),
          throwsArgumentError,
        );
        expect(await store.sharingFor(champion), isEmpty);
        expect(await db.select(db.galsSessionTools).get(), isEmpty);
        expect(await db.select(db.galsSessionAttendance).get(), isEmpty);
      } finally {
        await db.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
