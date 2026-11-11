import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_connect_africa/curriculum/lesson_progress.dart';
import 'package:ai_connect_africa/db/otic_database.dart';
import 'package:ai_connect_africa/db/providers/db_provider.dart';
import 'package:ai_connect_africa/memory/session_recall_store.dart';
import 'package:ai_connect_africa/services/learner_data_wiper.dart';
import 'package:ai_connect_africa/services/projects/project_store.dart';

/// A wiper that deletes the wrong things — too much or too little — fails
/// silently: nothing throws, the app just quietly leaks another learner's
/// data or a teacher's uploaded notes vanish with a "reset". These tests
/// exist to make both directions loud.
void main() {
  late OticDatabase db;
  late LearnerDataWiper wiper;
  late Directory certsDir;
  late ProjectStore projects;

  setUp(() async {
    db = OticDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    SharedPreferences.setMockInitialValues({});
    certsDir = await Directory.systemTemp.createTemp('wiper_test_certs');
    final projectsDir = await Directory.systemTemp.createTemp(
      'wiper_test_projects',
    );
    projects = ProjectStore(root: () async => projectsDir);
    wiper = LearnerDataWiper(
      db,
      recallStore: SessionRecallStore(
        directory: await Directory.systemTemp.createTemp('wiper_test'),
      ),
      certificatesDir: () async => certsDir,
      projectStore: projects,
    );
  });

  tearDown(() async => db.close());

  /// Every student-scoped table, seeded with one row for [studentId].
  Future<void> seedStudentRows(int studentId) async {
    await db
        .into(db.sessionSummaries)
        .insert(
          SessionSummariesCompanion.insert(
            studentId: studentId,
            topic: 'Algebra',
            summary: 'Covered linear equations.',
          ),
        );
    await db
        .into(db.topicProgress)
        .insert(
          TopicProgressCompanion.insert(studentId: studentId, topic: 'Algebra'),
        );
    await db
        .into(db.learningPaths)
        .insert(
          LearningPathsCompanion.insert(
            studentId: studentId,
            topic: 'Algebra',
            title: 'Algebra path',
            description: 'desc',
          ),
        );
    await db
        .into(db.earnedBadges)
        .insert(
          EarnedBadgesCompanion.insert(
            studentId: studentId,
            badgeId: 'first_lesson',
            badgeName: 'First Step',
          ),
        );
    await db
        .into(db.studentProjects)
        .insert(
          StudentProjectsCompanion.insert(
            studentId: studentId,
            title: 'My essay',
            topic: 'Algebra',
            projectType: 'essay',
          ),
        );
    await db
        .into(db.websiteProjects)
        .insert(
          WebsiteProjectsCompanion.insert(
            studentId: studentId,
            title: 'My site',
          ),
        );
    await db
        .into(db.appBuilderProjects)
        .insert(
          AppBuilderProjectsCompanion.insert(
            studentId: studentId,
            title: 'My app',
            appTypeId: 'todo',
            appTypeName: 'Todo',
            htmlContent: '<html></html>',
          ),
        );
    await db
        .into(db.assignments)
        .insert(
          AssignmentsCompanion.insert(
            studentId: studentId,
            subjectId: 'algebra',
            termMarker: 1,
            title: 'Homework',
            assignedAt: '2026-01-01T00:00:00Z',
          ),
        );
    await db
        .into(db.chatSessions)
        .insert(
          ChatSessionsCompanion.insert(
            id: 'session-$studentId',
            studentId: studentId,
            title: 'A chat',
          ),
        );
  }

  /// Row counts, per scoped table, for one student — every table this
  /// wiper is supposed to touch, in the same order as [seedStudentRows].
  Future<Map<String, int>> countsFor(int studentId) async {
    return {
      'session_summaries': (await (db.select(
        db.sessionSummaries,
      )..where((t) => t.studentId.equals(studentId))).get()).length,
      'topic_progress': (await (db.select(
        db.topicProgress,
      )..where((t) => t.studentId.equals(studentId))).get()).length,
      'learning_paths': (await (db.select(
        db.learningPaths,
      )..where((t) => t.studentId.equals(studentId))).get()).length,
      'earned_badges': (await (db.select(
        db.earnedBadges,
      )..where((t) => t.studentId.equals(studentId))).get()).length,
      'student_projects': (await (db.select(
        db.studentProjects,
      )..where((t) => t.studentId.equals(studentId))).get()).length,
      'website_projects': (await (db.select(
        db.websiteProjects,
      )..where((t) => t.studentId.equals(studentId))).get()).length,
      'app_builder_projects': (await (db.select(
        db.appBuilderProjects,
      )..where((t) => t.studentId.equals(studentId))).get()).length,
      'assignments': (await (db.select(
        db.assignments,
      )..where((t) => t.studentId.equals(studentId))).get()).length,
      'chat_sessions': (await (db.select(
        db.chatSessions,
      )..where((t) => t.studentId.equals(studentId))).get()).length,
    };
  }

  /// Seeds one row in every table that must survive a wipe untouched.
  Future<void> seedResourceRows() async {
    await db
        .into(db.topicResources)
        .insert(
          TopicResourcesCompanion.insert(
            subjectId: 'chemistry',
            topicKey: 'acids',
            resourceTitle: 'Acid notes',
            contentChunk: 'Acids donate protons.',
            createdAt: '2026-01-01T00:00:00Z',
          ),
        );
    await db
        .into(db.customSubjects)
        .insert(
          CustomSubjectsCompanion.insert(
            subjectId: 'my_subject',
            name: 'My Subject',
            createdAt: '2026-01-01T00:00:00Z',
          ),
        );
    await db
        .into(db.classGroups)
        .insert(ClassGroupsCompanion.insert(className: 'S2'));
    await db
        .into(db.translationCacheEntries)
        .insert(
          TranslationCacheEntriesCompanion.insert(
            cacheKey: 'k1',
            langCode: 'sw',
            direction: 'to_en',
            modelTag: 'm1',
            sourceText: 'jambo',
            translatedText: 'hello',
          ),
        );
    await db
        .into(db.syncState)
        .insert(
          SyncStateCompanion.insert(
            classGroupUuid: 'uuid-1',
            subjectId: 'chemistry',
            lastSyncedAt: '2026-01-01T00:00:00Z',
          ),
        );
  }

  Future<void> expectResourceRowsIntact() async {
    expect((await db.select(db.topicResources).get()).length, 1);
    expect((await db.select(db.customSubjects).get()).length, 1);
    expect((await db.select(db.classGroups).get()).length, 1);
    expect((await db.select(db.translationCacheEntries).get()).length, 1);
    expect(
      (await db.select(db.syncState).get()).length,
      1,
      reason:
          'wiping sync_state while keeping topic_resources would make '
          'the next sync needlessly re-pull everything',
    );
  }

  test('wipeStudent deletes only that student across every scoped table, '
      'leaves another student and every resource table untouched', () async {
    final aId = await db.studentDao.createStudent(
      StudentsCompanion.insert(name: 'Amina'),
    );
    final bId = await db.studentDao.createStudent(
      StudentsCompanion.insert(name: 'Brian'),
    );
    await seedStudentRows(aId);
    await seedStudentRows(bId);
    await seedResourceRows();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('active_student_id', aId);
    await prefs.setString('student_name', 'Amina');
    await prefs.setBool('lesson_done_s${aId}_chemistry_0_0', true);
    await prefs.setBool('lesson_done_s${bId}_chemistry_0_0', true);
    await prefs.setBool('lesson_done_chemistry_0_0', true); // legacy shared key
    await prefs.setString('pdf_hl_s${aId}_doc', '[]');
    await prefs.setString('pdf_hl_s${bId}_doc', '[]');

    await wiper.wipeStudent(aId);

    expect(await db.studentDao.getStudentById(aId), isNull);
    expect(
      await db.studentDao.getStudentById(bId),
      isNotNull,
      reason: 'a shared-device wipe must never touch another learner',
    );

    final aCounts = await countsFor(aId);
    final bCounts = await countsFor(bId);
    for (final table in aCounts.keys) {
      expect(
        aCounts[table],
        0,
        reason: '$table still has a row for the wiped student',
      );
      expect(bCounts[table], 1, reason: "$table lost the other student's row");
    }

    await expectResourceRowsIntact();

    expect(prefs.getInt('active_student_id'), isNull);
    expect(prefs.getBool('lesson_done_s${aId}_chemistry_0_0'), isNull);
    expect(
      prefs.getBool('lesson_done_s${bId}_chemistry_0_0'),
      isTrue,
      reason: "another learner's own scoped checkmark must survive",
    );
    expect(prefs.getString('pdf_hl_s${aId}_doc'), isNull);
    expect(
      prefs.getString('pdf_hl_s${bId}_doc'),
      isNotNull,
      reason: "another learner's PDF highlights must survive",
    );
    expect(
      prefs.getBool('lesson_done_chemistry_0_0'),
      isTrue,
      reason:
          'the legacy shared key is not attributable to one learner, '
          'so a single-student wipe must leave it alone',
    );
    expect(
      prefs.getString('student_name'),
      'Brian',
      reason:
          "the router's onboarding-done flag stays set to a "
          "surviving learner, but must not keep naming the deleted one — "
          "that would itself be the deleted learner's data surviving "
          'their own wipe',
    );
  });

  test('wipeStudent deletes only that learner\'s project folders', () async {
    final amina = await db.studentDao.createStudent(
      StudentsCompanion.insert(name: 'Amina'),
    );
    final brian = await db.studentDao.createStudent(
      StudentsCompanion.insert(name: 'Brian'),
    );
    for (final (id, name) in [(amina, 'Amina'), (brian, 'Brian')]) {
      await projects.save(
        studentId: id,
        studentName: name,
        kind: ProjectKind.website,
        title: '$name site',
        files: {'frontend/index.html': '<h1>$name</h1>'},
      );
    }

    await wiper.wipeStudent(amina);

    expect(await projects.list(amina), isEmpty);
    expect((await projects.list(brian)).single.title, 'Brian site');
  });

  test(
    'a stale active_student_id (e.g. from a learner deleted before this '
    'wiper existed) does not clear student_name while a learner remains',
    () async {
      final aId = await db.studentDao.createStudent(
        StudentsCompanion.insert(name: 'Amina'),
      );
      final bId = await db.studentDao.createStudent(
        StudentsCompanion.insert(name: 'Brian'),
      );
      final prefs = await SharedPreferences.getInstance();
      // Points at neither learner being wiped nor a real row — the shape a
      // pre-existing device could actually be in.
      await prefs.setInt('active_student_id', 9999);
      await prefs.setString('student_name', 'Amina');

      await wiper.wipeStudent(aId);

      expect(
        prefs.getString('student_name'),
        'Brian',
        reason:
            'Brian still exists — the flag must not read as "no one '
            'active" just because the saved id is stale, and must not '
            "keep naming Amina, the learner this call just deleted",
      );
      expect(await db.studentDao.getStudentById(bId), isNotNull);
    },
  );

  test('wipeStudent on the last remaining learner clears the onboarding '
      'flag too, not just the row', () async {
    final aId = await db.studentDao.createStudent(
      StudentsCompanion.insert(name: 'Amina'),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('student_name', 'Amina');

    await wiper.wipeStudent(aId);

    expect(
      prefs.getString('student_name'),
      isNull,
      reason:
          'no learner remains, so the router must not read this as '
          '"onboarding already done"',
    );
  });

  test('wipeAll clears every learner and every scoped table, but leaves '
      'every resource table and its sync state untouched', () async {
    final aId = await db.studentDao.createStudent(
      StudentsCompanion.insert(name: 'Amina'),
    );
    final bId = await db.studentDao.createStudent(
      StudentsCompanion.insert(name: 'Brian'),
    );
    await seedStudentRows(aId);
    await seedStudentRows(bId);
    await seedResourceRows();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('active_student_id', aId);
    await prefs.setString('student_name', 'Amina');
    await prefs.setBool('lesson_done_s${aId}_chemistry_0_0', true);
    await prefs.setBool('lesson_done_chemistry_0_0', true);
    await prefs.setString('pdf_hl_s${aId}_doc', '[]');

    await wiper.wipeAll();

    expect(await db.studentDao.getAllStudents(), isEmpty);
    final aCounts = await countsFor(aId);
    final bCounts = await countsFor(bId);
    for (final table in aCounts.keys) {
      expect(aCounts[table], 0, reason: '$table not empty after wipeAll');
      expect(bCounts[table], 0, reason: '$table not empty after wipeAll');
    }

    await expectResourceRowsIntact();

    expect(prefs.getInt('active_student_id'), isNull);
    expect(
      prefs.getString('student_name'),
      isNull,
      reason:
          "the router's onboarding-done flag must not survive a "
          'wipeAll, or /onboarding bounces straight back to home with '
          'zero students',
    );
    expect(prefs.getBool('lesson_done_s${aId}_chemistry_0_0'), isNull);
    expect(
      prefs.getBool('lesson_done_chemistry_0_0'),
      isNull,
      reason: 'no student remains for the legacy shared key to apply to',
    );
    expect(prefs.getString('pdf_hl_s${aId}_doc'), isNull);
  });

  test('onboarding after wipeAll inserts a fresh profile instead of editing '
      'a stranded one', () async {
    final aId = await db.studentDao.createStudent(
      StudentsCompanion.insert(name: 'Amina'),
    );
    await seedStudentRows(aId);
    await wiper.wipeAll();

    // createProfile's own "update instead of insert" guard reads
    // resolveActiveStudent(db) — this proves that, with the wipe having
    // cleared both the students table and the active_student_id pref it
    // falls back to, the guard sees nothing and takes the insert path
    // rather than silently reviving/editing the wiped row.
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await container
        .read(studentNotifierProvider.notifier)
        .createProfile(name: 'Chidi');

    final all = await db.studentDao.getAllStudents();
    expect(all, hasLength(1));
    expect(all.single.name, 'Chidi');
  });

  test('a curriculum-browser lesson checkmark cleared by wipeAll reports '
      'first-time-complete again, not "already done"', () async {
    final aId = await db.studentDao.createStudent(
      StudentsCompanion.insert(name: 'Amina'),
    );
    final firstMark = await LessonProgress().markCompleteFor(
      aId,
      'chemistry',
      0,
      0,
    );
    expect(firstMark, isTrue);
    final repeatMark = await LessonProgress().markCompleteFor(
      aId,
      'chemistry',
      0,
      0,
    );
    expect(repeatMark, isFalse, reason: 'sanity check: already marked');

    await wiper.wipeAll();

    final afterWipe = await LessonProgress().markCompleteFor(
      aId,
      'chemistry',
      0,
      0,
    );
    expect(
      afterWipe,
      isTrue,
      reason:
          'wipeAll must clear the lesson_done_s<id>_… key, or a '
          'badge/counter that reads it stays wrongly silent for the id '
          'if it is ever reused',
    );
  });

  test('every table in the schema is classified as either wiped or kept — '
      'a newly-added table must be sorted into one on purpose', () async {
    const kept = {
      // Community champions are independent of school learner profiles.
      'gals_champions',
      'gals_sharing_sessions',
      'gals_session_tools',
      'gals_session_attendance',
      'gals_lesson_completions',
      'gals_achievement_reviews',
      'topic_resources',
      'custom_subjects',
      // Built-in subjects the Admin removed: the school's, not a learner's.
      'removed_subjects',
      'class_groups',
      'translation_cache_entries',
      'sync_state',
      // Class sync: which notes go to which class, and this device's
      // school + signing key — device resources, not any learner's data.
      'resource_shares',
      'sync_identity',
      // Teacher device: channel versions it signed, and progress reports
      // from other devices' learners — no row belongs to a local learner.
      // Deleting the class clears both (ClassGroupDao.deleteClass).
      'served_channels',
      'member_reports',
      // Co-teachers: root's allocations, and a co-teacher device's own
      // record of classes it serves — device/class data, not a learner's.
      'class_co_teachers',
      'co_teaching_classes',
      // Host failover: paired standbys (host) and the sealed host ledger
      // (standby) — the school's teacher identity, not a learner's.
      'failover_standbys',
      'host_ledgers',
      // Teachers who sign in on this device — not learners.
      'teacher_profiles',
      // The Admin's records and who uploaded each note — school data, not
      // any learner's.
      'admin_identity',
      'admin_records_state',
      'teaching_assignments',
      'note_owners',
      // Subjects a teacher made for themselves — a teacher's, not a
      // learner's.
      'teacher_subjects',
      // Devices: who holds each class, who the school revoked, and which
      // devices took the Admin's records — devices, not learners.
      'class_members',
      'revoked_devices',
      'school_devices',
      // Which note versions member devices hold — class data.
      'channel_receipts',
      // The cloud plug-in's outbox names records only (kind + uuid); a
      // wiped learner's records are gone, so their entries are dropped
      // unsent.
      'cloud_outbox',
      // The device's link to its school cloud.
      'cloud_link',
      // The device's audit log names learners by id only, and must outlive
      // a deletion it records.
      'audit_log',
      // The Admin's record of which classes each Class Teacher registers
      // into — school records, not one learner's.
      'class_teacher_assignments',
    };
    final actual = db.allTables.map((t) => t.actualTableName).toSet();
    final classified = LearnerDataWiper.wipedTableNames.union(kept);
    expect(
      actual.difference(classified),
      isEmpty,
      reason:
          'a table exists that this test has not classified as wiped '
          'or kept — decide which it is before shipping',
    );
    expect(
      LearnerDataWiper.wipedTableNames.intersection(kept),
      isEmpty,
      reason: 'a table cannot be both wiped and kept',
    );
  });

  group('certificate PDFs', () {
    test('wipeStudent deletes only the matching learner\'s certificates, '
        "even when another learner's name shares its prefix", () async {
      final johnId = await db.studentDao.createStudent(
        StudentsCompanion.insert(name: 'John'),
      );
      await db.studentDao.createStudent(
        StudentsCompanion.insert(name: 'John Paul'),
      );
      final johnCert = File('${certsDir.path}/John_Math_1.pdf')
        ..writeAsStringSync('x');
      final johnPaulCert = File('${certsDir.path}/John_Paul_Math_2.pdf')
        ..writeAsStringSync('x');

      await wiper.wipeStudent(johnId);

      expect(
        await johnCert.exists(),
        isFalse,
        reason: "John's own certificate must be deleted",
      );
      expect(
        await johnPaulCert.exists(),
        isTrue,
        reason:
            "John's shorter name must not delete John Paul's "
            'certificate just because it shares the prefix',
      );
    });

    test('wipeStudent leaves both files alone when two learners sanitize '
        'to the exact same name', () async {
      final firstId = await db.studentDao.createStudent(
        StudentsCompanion.insert(name: 'Amina'),
      );
      await db.studentDao.createStudent(
        StudentsCompanion.insert(name: 'Amina'),
      );
      final cert = File('${certsDir.path}/Amina_Math_1.pdf')
        ..writeAsStringSync('x');

      await wiper.wipeStudent(firstId);

      expect(
        await cert.exists(),
        isTrue,
        reason:
            'the file cannot be attributed to either Amina, so it '
            'must be left for a wipeAll instead of guessed at',
      );
    });

    test('wipeAll deletes every certificate PDF, including one left behind '
        'by a deletion made before this wiper existed', () async {
      await db.studentDao.createStudent(
        StudentsCompanion.insert(name: 'Amina'),
      );
      final ownedCert = File('${certsDir.path}/Amina_Math_1.pdf')
        ..writeAsStringSync('x');
      // No matching student row at all — simulates the old Admin delete,
      // which never touched this folder.
      final orphanCert = File('${certsDir.path}/Deleted_Student_Bio_9.pdf')
        ..writeAsStringSync('x');

      await wiper.wipeAll();

      expect(await ownedCert.exists(), isFalse);
      expect(await orphanCert.exists(), isFalse);
    });
  });
}
