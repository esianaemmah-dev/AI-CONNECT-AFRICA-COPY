import 'package:ai_connect_africa/db/otic_database.dart';
import 'package:ai_connect_africa/features/learners/learner_pin.dart';
import 'package:ai_connect_africa/features/teacher/teacher_pin.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('a new PIN hash is tagged PBKDF2 and only its PIN matches', () async {
    pinHashInIsolate = true;
    addTearDown(() => pinHashInIsolate = false);
    final sw = Stopwatch()..start();
    final hash = await hashPinStrong('salt', '2468');
    // ignore: avoid_print
    print('one PIN hash at $pinKdfRounds rounds: ${sw.elapsedMilliseconds} ms');
    expect(hash, startsWith('pbkdf2\$$pinKdfRounds\$'));
    expect(pinNeedsUpgrade(hash), isFalse);
    expect(await pinMatches('salt', '2468', hash), isTrue);
    expect(await pinMatches('salt', '2469', hash), isFalse);
    expect(await pinMatches('other', '2468', hash), isFalse);
  });

  test(
    'an old SHA-256 hash still verifies and is marked for upgrade',
    () async {
      final old = hashPin('salt', '2468');
      expect(pinNeedsUpgrade(old), isTrue);
      expect(await pinMatches('salt', '2468', old), isTrue);
      expect(await pinMatches('salt', '1111', old), isFalse);
      expect(await pinMatches('salt', '2468', 'pbkdf2\$x\$00'), isFalse);
    },
  );

  test(
    'a learner PIN in the old format is upgraded on the next right entry',
    () async {
      final db = OticDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      addTearDown(db.close);
      final id = await db
          .into(db.students)
          .insert(
            StudentsCompanion.insert(
              name: 'Babirye',
              pinSalt: const Value('s'),
              pinHash: Value(hashPin('s', '1357')),
            ),
          );
      final pins = LearnerPinService(db);
      expect(await pins.verify(id, '0000'), isFalse);
      expect(
        pinNeedsUpgrade((await db.studentDao.getStudentById(id))!.pinHash!),
        isTrue,
      );
      expect(await pins.verify(id, '1357'), isTrue);
      final stored = (await db.studentDao.getStudentById(id))!.pinHash!;
      expect(pinNeedsUpgrade(stored), isFalse);
      expect(await pins.verify(id, '1357'), isTrue);
    },
  );
}
