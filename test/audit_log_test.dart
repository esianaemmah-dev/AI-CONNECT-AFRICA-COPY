import 'dart:io';

import 'package:ai_connect_africa/db/otic_database.dart';
import 'package:ai_connect_africa/features/admin/admin_service.dart';
import 'package:ai_connect_africa/memory/session_recall_store.dart';
import 'package:ai_connect_africa/services/audit/audit_log.dart';
import 'package:ai_connect_africa/services/custom_subject_service.dart';
import 'package:ai_connect_africa/services/learner_data_wiper.dart';
import 'package:ai_connect_africa/services/projects/project_store.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late OticDatabase db;
  late AuditLogService log;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = OticDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    log = AuditLogService(db);
  });
  tearDown(() => db.close());

  test('rows chain and verify; an edit, a deletion or an insert shows',
      () async {
    for (final a in ['one', 'two', 'three']) {
      await log.record('admin', 'test.$a', detail: a);
    }
    expect(await log.verify(), isNull);

    final rows = await db.select(db.auditLog).get();
    await (db.update(db.auditLog)..where((t) => t.id.equals(rows[1].id)))
        .write(const AuditLogCompanion(detail: Value('edited')));
    expect(await log.verify(), rows[1].id);

    await (db.update(db.auditLog)..where((t) => t.id.equals(rows[1].id)))
        .write(const AuditLogCompanion(detail: Value('two')));
    expect(await log.verify(), isNull);
    await (db.delete(db.auditLog)..where((t) => t.id.equals(rows[1].id))).go();
    expect(await log.verify(), rows[2].id, reason: 'the chain breaks');
  });

  test('a row signed by another key is caught', () async {
    await log.record('admin', 'test.one');
    final other = OticDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    addTearDown(other.close);
    await AuditLogService(other).record('admin', 'test.one');
    final forged = (await other.select(other.auditLog).get()).single;
    await db.delete(db.auditLog).go();
    await db.into(db.auditLog).insert(
      AuditLogCompanion.insert(
        at: forged.at,
        actor: forged.actor,
        action: forged.action,
        hash: forged.hash,
        sig: forged.sig,
      ),
    );
    expect(await log.verify(), isNotNull);
  });

  test('a v33 database upgrades to v34 with an empty log and no cloud link',
      () async {
    final dir = await Directory.systemTemp.createTemp('otic_migration_34');
    addTearDown(() => dir.delete(recursive: true));
    final file = File(p.join(dir.path, 'test.sqlite'));
    final seed = OticDatabase.forTesting(NativeDatabase(file));
    await seed.into(seed.students).insert(StudentsCompanion.insert(name: 'A'));
    await seed.customStatement('DROP TABLE audit_log');
    await seed.customStatement('DROP TABLE cloud_link');
    await seed.customStatement('PRAGMA user_version = 33');
    await seed.close();
    for (var run = 0; run < 2; run++) {
      final up = OticDatabase.forTesting(NativeDatabase(file));
      expect((await up.select(up.students).get()).single.name, 'A');
      expect(await up.select(up.auditLog).get(), isEmpty);
      expect(await up.select(up.cloudLink).get(), isEmpty);
      await up.customStatement('PRAGMA user_version = 33');
      await up.close();
    }
  });

  test('details are clipped', () async {
    await log.record('admin', 'test.long', detail: 'x' * 500);
    expect(
      (await db.select(db.auditLog).getSingle()).detail.length,
      kAuditDetailChars,
    );
  });

  test('the Admin’s changes are recorded, with no PIN in them', () async {
    final tmp = await Directory.systemTemp.createTemp('audit_admin');
    addTearDown(() => tmp.delete(recursive: true));
    final admin = AdminService(
      db,
      CustomSubjectService(db),
      LearnerDataWiper(
        db,
        recallStore: SessionRecallStore(directory: Directory(p.join(tmp.path, 'r'))),
        certificatesDir: () async => tmp,
        projectStore: ProjectStore(root: () async => tmp),
      ),
    );
    final s = (await admin.setUp(name: 'Head', pin: '2468'))!;
    expect(await admin.signIn('1111'), isNull);
    await admin.addTeacher(s, name: 'Okello', pin: '9876');
    final learner = (await admin.addLearner(s, name: 'Amina'))!;
    await admin.deleteLearner(s, learner);
    final rows = await db.select(db.auditLog).get();
    expect(rows.map((r) => r.action), [
      'admin.set_up',
      'refused.admin_pin',
      'teacher.added',
      'learner.added',
      'learner.deleted',
    ]);
    final text = rows.map((r) => '${r.detail} ${r.action}').join(' ');
    for (final secret in ['2468', '1111', '9876']) {
      expect(text, isNot(contains(secret)));
    }
    expect(text, isNot(contains('Amina')), reason: 'learners by id only');
    expect(await log.verify(), isNull);
  });
}
