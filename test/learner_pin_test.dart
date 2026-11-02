import 'package:ai_connect_africa/db/otic_database.dart';
import 'package:ai_connect_africa/features/learners/learner_pin.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late OticDatabase db;
  late LearnerPinService pins;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = OticDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    pins = LearnerPinService(db);
  });
  tearDown(() => db.close());

  Future<int> learner(String name) =>
      db.into(db.students).insert(StudentsCompanion.insert(name: name));

  test('a learner with no PIN is never asked for one', () async {
    final amina = await learner('Amina');
    expect(await pins.isSet(amina), isFalse);
    expect(await pins.verify(amina, ''), isTrue);
  });

  test('each learner’s PIN opens only their own profile', () async {
    final amina = await learner('Amina');
    final okello = await learner('Okello');
    await pins.set(amina, '2468');
    expect(await pins.isSet(amina), isTrue);
    expect(await pins.verify(amina, '2468'), isTrue);
    expect(await pins.verify(amina, '1357'), isFalse);
    expect(await pins.isSet(okello), isFalse);
  });

  test('only a hash is stored, and a teacher can clear it', () async {
    final amina = await learner('Amina');
    await pins.set(amina, '2468');
    final row = await (db.select(db.students)
          ..where((t) => t.id.equals(amina)))
        .getSingle();
    expect(row.pinHash, isNot(contains('2468')));
    await pins.clear(amina);
    expect(await pins.isSet(amina), isFalse);
  });

  test('a PIN is 4 to 8 digits', () async {
    final amina = await learner('Amina');
    expect(() => pins.set(amina, '12'), throwsArgumentError);
    expect(() => pins.set(amina, 'abcd'), throwsArgumentError);
  });
}
