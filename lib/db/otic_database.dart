import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

import '../ai_core/model/model_locations.dart';
import 'daos/app_builder_project_dao.dart';
import 'daos/assignment_dao.dart';
import 'daos/badge_dao.dart';
import 'daos/chat_session_dao.dart';
import 'daos/class_group_dao.dart';
import 'daos/class_sync_dao.dart';
import 'daos/co_teacher_dao.dart';
import 'daos/custom_subject_dao.dart';
import 'daos/path_dao.dart';
import 'daos/project_dao.dart';
import 'daos/session_dao.dart';
import 'daos/student_dao.dart';
import 'daos/sync_state_dao.dart';
import 'daos/topic_resource_dao.dart';
import 'daos/translation_cache_dao.dart';
import 'daos/website_dao.dart';
import 'tables/app_builder_projects_table.dart';
import 'tables/admin_tables.dart';
import 'tables/assignment_attempts_table.dart';
import 'tables/assignment_submissions_table.dart';
import 'tables/cloud_outbox_table.dart';
import 'tables/assignments_table.dart';
import 'tables/chat_sessions_table.dart';
import 'tables/sync_state_table.dart';
import 'tables/class_groups_table.dart';
import 'tables/co_teachers_table.dart';
import 'tables/co_teaching_classes_table.dart';
import 'tables/custom_subjects_table.dart';
import 'tables/earned_badges_table.dart';
import 'tables/failover_tables.dart';
import 'tables/learner_subjects_table.dart';
import 'tables/learning_paths_table.dart';
import 'tables/audit_log_table.dart';
import 'tables/cloud_link_table.dart';
import 'tables/learner_support_table.dart';
import 'tables/member_reports_table.dart';
import 'tables/quiz_results_table.dart';
import 'tables/device_tables.dart';
import 'tables/resource_shares_table.dart';
import 'tables/served_channels_table.dart';
import 'tables/sync_identity_table.dart';
import 'tables/teacher_profiles_table.dart';
import 'tables/session_summaries_table.dart';
import 'tables/student_projects_table.dart';
import 'tables/students_table.dart';
import 'tables/topic_resources_table.dart';
import 'tables/translation_cache_table.dart';
import 'tables/topic_progress_table.dart';
import 'tables/website_projects_table.dart';

part 'otic_database.g.dart';

@DriftDatabase(
  tables: [
    Students,
    SessionSummaries,
    TopicProgress,
    LearningPaths,
    EarnedBadges,
    StudentProjects,
    WebsiteProjects,
    TranslationCacheEntries,
    TopicResources,
    CustomSubjects,
    ChatSessions,
    ClassGroups,
    AppBuilderProjects,
    SyncState,
    Assignments,
    ResourceShares,
    SyncIdentity,
    ServedChannels,
    MemberReports,
    LearnerSubjects,
    ClassCoTeachers,
    CoTeachingClasses,
    FailoverStandbys,
    HostLedgers,
    QuizResults,
    TeacherProfiles,
    AdminIdentity,
    TeachingAssignments,
    StudentEnrolments,
    NoteOwners,
    AdminRecordsState,
    AssignmentSubmissions,
    AssignmentAttempts,
    CloudOutbox,
    ClassMembers,
    RevokedDevices,
    SchoolDevices,
    ChannelReceipts,
    RemovedSubjects,
    LearnerSupport,
    CloudLink,
    AuditLog,
    ClassTeacherAssignments,
    LearnerRegistrations,
    TeacherSubjects,
  ],
  daos: [
    StudentDao,
    SessionDao,
    PathDao,
    BadgeDao,
    ProjectDao,
    WebsiteDao,
    TranslationCacheDao,
    TopicResourceDao,
    CustomSubjectDao,
    ChatSessionDao,
    ClassGroupDao,
    AppBuilderProjectDao,
    SyncStateDao,
    AssignmentDao,
    ClassSyncDao,
    CoTeacherDao,
  ],
)
class OticDatabase extends _$OticDatabase {
  OticDatabase() : super(_openConnection());

  /// In-memory (or otherwise caller-supplied) database, for tests.
  ///
  /// The default constructor resolves an app storage directory and opens a
  /// file, neither of which exists under `flutter test`. Without this seam a
  /// DAO can only be exercised on a real device, which is how a table can ship
  /// with a query that never matches a row.
  OticDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 37;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      // Not a drift table (drift has no FTS5 table class), so createAll
      // does not know about it.
      await _createResourceSearchIndex();
      await _createUuidTriggers();
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(learningPaths);
      }
      // Steps 2–8 are guarded too (createTable is already IF NOT EXISTS):
      // a build from schema 7 or older that opens a newer database stamps
      // user_version back down to its own number, so the next current
      // build re-runs every step on a database that already has it all.
      if (from < 3) {
        for (final (col, add) in [
          ('streak_days', () => m.addColumn(students, students.streakDays)),
          (
            'last_streak_date',
            () => m.addColumn(students, students.lastStreakDate),
          ),
          ('total_points', () => m.addColumn(students, students.totalPoints)),
        ]) {
          if (!await _columnExists('students', col)) await add();
        }
        await m.createTable(earnedBadges);
        await m.createTable(studentProjects);
      }
      if (from < 4) {
        await m.createTable(websiteProjects);
      }
      if (from < 5) {
        await m.createTable(translationCacheEntries);
      }
      if (from < 6) {
        // Teacher-supplied notes/textbook chunks. Purely additive — the
        // hardcoded syllabi in assets/curriculum are untouched, and an
        // upgrade that stops here leaves the app behaving exactly as it
        // did on schema 5.
        await m.createTable(topicResources);
        // createTable does not carry the table's indexes, and a device
        // that upgraded would otherwise run every retrieval as a full
        // scan while a freshly installed one (onCreate → createAll) did
        // not — the same code, quietly slower on exactly the older,
        // weaker hardware this product targets.
        await _createIndexIfMissing(m, idxTopicResourcesLookup);
        await _createIndexIfMissing(m, idxTopicResourcesTitle);
      }
      if (from < 7) {
        // Teacher-created subjects. Also additive: with this table empty
        // the browse grid shows exactly the 16 bundled subjects.
        await m.createTable(customSubjects);
        await _createIndexIfMissing(m, idxCustomSubjectsSubjectId);
      }
      if (from < 8) {
        // One row per chat, indexing the recall files in otic_sessions/.
        // Additive: SessionSummaries still holds the per-turn rows that
        // topic progress and the teacher dashboard read, so an upgrade
        // that stops here loses nothing — the sidebar simply starts
        // empty and refills as new chats are had.
        await m.createTable(chatSessions);
        await _createIndexIfMissing(m, idxChatSessionsRecent);
      }
      // ── Schema 9 onward: idempotent from here down ─────────────────
      //
      // `m.createTable(x)` always stamps *today's* Dart definition of x,
      // not the shape x had when it was first added — so any step below
      // that both creates a table and later ALTERs a column onto it can
      // collide with itself on a device that jumps several versions in
      // one boot (`duplicate column name`), and a step that re-runs
      // after a previous upgrade attempt partially completed and then
      // crashed can collide on `table already exists`. Both are real,
      // not hypothetical: the second is exactly what happened on a real
      // device here — `onUpgrade` has no transaction wrapping these
      // statements, so the schema-9→10 step (create appBuilderProjects)
      // had already committed and `user_version` was still 9 when the
      // schema-11 step below (the `UNIQUE`-column bug, since fixed)
      // threw and aborted the rest of the upgrade. Every step from here
      // down checks the database itself — via [_tableExists]/
      // [_columnExists] — instead of trusting `from`/`to`, so re-running
      // an upgrade that previously got partway is always safe.
      if (from < 9) {
        // Classes/streams. Additive: every existing learner starts
        // unassigned (class_group_id NULL) and keeps all their progress.
        if (!await _tableExists('class_groups')) {
          await m.createTable(classGroups);
        }
        if (!await _columnExists('students', 'class_group_id')) {
          await m.addColumn(students, students.classGroupId);
        }
        // Full-text index over teacher material. Built from the rows
        // already in topic_resources, so notes uploaded before this
        // upgrade stay searchable. Re-running the rebuild is harmless
        // (it is idempotent by nature), so this whole block is safe to
        // repeat even though the CREATE TABLE/TRIGGERs inside it are
        // already `IF NOT EXISTS`.
        await _createResourceSearchIndex();
        await customStatement(
          "INSERT INTO topic_resources_fts(topic_resources_fts) "
          "VALUES('rebuild')",
        );
      }
      if (from < 10) {
        // App Builder generations, saved per student — the same gap
        // Website Builder already closed via WebsiteProjects. Purely
        // additive: nothing previously read or wrote this table.
        if (!await _tableExists('app_builder_projects')) {
          await m.createTable(appBuilderProjects);
        }
      }
      if (from < 11) {
        // Scoped class/stream/subject sync over the local network
        // (lib/collaboration/sync/). classGroups.id and topic_resources
        // rows already existed and are device-local; the new columns
        // give them a portable identity/scope/version without touching
        // anything that already reads or writes these tables.
        if (!await _columnExists('class_groups', 'group_uuid')) {
          // No inline UNIQUE — see the doc on ClassGroups.groupUuid for
          // why (`ALTER TABLE ... ADD COLUMN ... UNIQUE` is rejected by
          // SQLite outright). Uniqueness is [idxClassGroupsGroupUuid],
          // created below once every row has a real value.
          await m.addColumn(classGroups, classGroups.groupUuid);
        }
        if (!await _columnExists('topic_resources', 'class_group_uuid')) {
          await m.addColumn(topicResources, topicResources.classGroupUuid);
        }
        if (!await _columnExists('topic_resources', 'updated_at')) {
          await m.addColumn(topicResources, topicResources.updatedAt);
        }
        if (!await _tableExists('sync_state')) {
          await m.createTable(syncState);
        }
        await classGroupDao.backfillGroupUuids();
        // Never carried by createTable regardless of which branch ran
        // above (see the standing note on idxTopicResourcesLookup), and
        // `CREATE UNIQUE INDEX` has no bare `IF NOT EXISTS` guard on
        // [Migrator.create] — check sqlite's own index list instead.
        if (!await _indexExists('idx_class_groups_group_uuid')) {
          await m.create(idxClassGroupsGroupUuid);
        }
      }
      if (from < 12) {
        // Assignments + rolling year progress
        // (AcademicScoreTrackerRepository). Additive: no existing
        // points/progress path (badges, topic_progress) reads or
        // writes this table.
        if (!await _tableExists('assignments')) {
          await m.createTable(assignments);
          await m.create(idxAssignmentsStudentSubjectTerm);
        }
      }
      if (from < 13) {
        // "Keep this chat" — see ChatSessions.pinned. Every existing
        // chat defaults to unpinned, so this changes nothing about
        // which chats age out until a student actually pins one.
        if (!await _columnExists('chat_sessions', 'pinned')) {
          await m.addColumn(chatSessions, chatSessions.pinned);
        }
      }
      if (from < 14) {
        // Lifetime Practice/Apply counters behind the Achievements
        // badge progress bars — see BadgeService. Every existing
        // learner starts these at 0, which reads as a contradiction
        // next to an already-earned badge (Sharp Mind shown Completed
        // beside a "0/5 correct" bar) — schema 15 below backfills a
        // floor from the badges already on record.
        if (!await _columnExists('students', 'total_practice_attempted')) {
          await m.addColumn(students, students.totalPracticeAttempted);
        }
        if (!await _columnExists('students', 'total_practice_correct')) {
          await m.addColumn(students, students.totalPracticeCorrect);
        }
        if (!await _columnExists('students', 'total_scenarios_completed')) {
          await m.addColumn(students, students.totalScenariosCompleted);
        }
        if (!await _columnExists('students', 'total_lessons_completed')) {
          await m.addColumn(students, students.totalLessonsCompleted);
        }
      }
      if (from < 15) {
        // Same standing rule as `if (from < 9)` above: check the
        // database itself, don't trust `from`. A device could reach
        // this block already sitting at schema 14 but missing a column
        // the 14-step added later in development — repeating the
        // guards here means the UPDATEs below never hit "no such
        // column" regardless of exactly which shape of v14 a real
        // install upgraded from.
        if (!await _columnExists('students', 'total_practice_attempted')) {
          await m.addColumn(students, students.totalPracticeAttempted);
        }
        if (!await _columnExists('students', 'total_practice_correct')) {
          await m.addColumn(students, students.totalPracticeCorrect);
        }
        if (!await _columnExists('students', 'total_scenarios_completed')) {
          await m.addColumn(students, students.totalScenariosCompleted);
        }
        if (!await _columnExists('students', 'total_lessons_completed')) {
          await m.addColumn(students, students.totalLessonsCompleted);
        }

        // Backfill for the schema-14 counters above, for a learner who
        // earned practice_starter/sharp_mind/scenario_solver under the
        // old session-scored logic before those counters existed.
        // Floors only (MAX, never overwrites a higher real count), so
        // this is safe to re-run and never contradicts activity BadgeService
        // has already recorded since the schema-14 upgrade. Guarded on
        // the table existing — always true on a real device (created at
        // schema 3) — because a synthetic test fixture that jumps
        // straight to an early schema may not have created it yet.
        if (await _tableExists('earned_badges')) {
          await customStatement('''
                UPDATE students SET total_practice_attempted =
                  MAX(total_practice_attempted, 1)
                WHERE id IN (
                  SELECT student_id FROM earned_badges
                  WHERE badge_id = 'practice_starter'
                )
              ''');
          await customStatement('''
                UPDATE students SET
                  total_practice_correct = MAX(total_practice_correct, 5),
                  total_practice_attempted = MAX(total_practice_attempted, 5)
                WHERE id IN (
                  SELECT student_id FROM earned_badges
                  WHERE badge_id = 'sharp_mind'
                )
              ''');
          await customStatement('''
                UPDATE students SET total_scenarios_completed =
                  MAX(total_scenarios_completed, 5)
                WHERE id IN (
                  SELECT student_id FROM earned_badges
                  WHERE badge_id = 'scenario_solver'
                )
              ''');
        }
      }
      if (from < 16) {
        // Class sync restricted to one school / class / stream /
        // subject: class keys, pinned teacher keys, opt-in note shares,
        // the device's school + signing key, and a channel digest.
        // Additive — no share rows exist yet, so nothing is served until
        // a teacher shares a note, which is the intended starting point.
        for (final (col, add) in [
          ('school_id', () => m.addColumn(classGroups, classGroups.schoolId)),
          ('class_key', () => m.addColumn(classGroups, classGroups.classKey)),
          (
            'teacher_public_key',
            () => m.addColumn(classGroups, classGroups.teacherPublicKey),
          ),
          ('joined', () => m.addColumn(classGroups, classGroups.joined)),
        ]) {
          if (!await _columnExists('class_groups', col)) await add();
        }
        if (!await _columnExists('sync_state', 'channel_digest')) {
          await m.addColumn(syncState, syncState.channelDigest);
        }
        if (!await _columnExists('topic_resources', 'document_title')) {
          await m.addColumn(topicResources, topicResources.documentTitle);
        }
        if (!await _tableExists('resource_shares')) {
          await m.createTable(resourceShares);
        }
        if (!await _indexExists('idx_resource_shares_unique')) {
          await m.create(idxResourceSharesUnique);
        }
        if (!await _tableExists('sync_identity')) {
          await m.createTable(syncIdentity);
        }
      }
      if (from < 17) {
        // Class sync v3: classmates may pass the teacher's notes on, so
        // each channel carries the teacher's signed, monotonic version.
        // Additive — existing copies have no version yet and are simply
        // replaced on the next sync with the teacher.
        for (final (col, add) in [
          (
            'channel_version',
            () => m.addColumn(syncState, syncState.channelVersion),
          ),
          ('manifest_sig', () => m.addColumn(syncState, syncState.manifestSig)),
        ]) {
          if (!await _columnExists('sync_state', col)) await add();
        }
        if (!await _tableExists('served_channels')) {
          await m.createTable(servedChannels);
        }
        if (!await _indexExists('idx_served_channels_channel')) {
          await m.create(idxServedChannelsChannel);
        }
        // Students' devices report progress to the teacher when they sync.
        if (!await _tableExists('member_reports')) {
          await m.createTable(memberReports);
        }
        if (!await _indexExists('idx_member_reports_member')) {
          await m.create(idxMemberReportsMember);
        }
      }
      if (from < 18) {
        // One teacher device per school; the teacher's subjects reach
        // students; learners record the subjects they take.
        //
        // Historical note: "one teacher device per school" stopped being
        // the model at schema 19, which adds co-teachers delegated to
        // specific subjects. Read this comment as describing the starting
        // point this step upgraded a device to, not the current rule.
        if (!await _columnExists('sync_identity', 'device_role')) {
          await m.addColumn(syncIdentity, syncIdentity.deviceRole);
        }
        if (await _tableExists('custom_subjects') &&
            !await _columnExists('custom_subjects', 'class_group_uuid')) {
          await m.addColumn(customSubjects, customSubjects.classGroupUuid);
        }
        if (!await _tableExists('learner_subjects')) {
          await m.createTable(learnerSubjects);
        }
        if (!await _indexExists('idx_learner_subjects_unique')) {
          await m.create(idxLearnerSubjectsUnique);
        }
        await _backfillDeviceRole();
      }
      if (from < 19) {
        // Multiple teacher devices per school: a root teacher can delegate
        // a class's subjects to co-teacher devices, each serving from its
        // own device with its own signing key. Additive and back-compatible
        // — a class with no co-teachers has rosterVersion/rosterJson null
        // and every subject still resolves to root's own key, exactly as
        // before this schema step.
        if (!await _columnExists('class_groups', 'roster_version')) {
          await m.addColumn(classGroups, classGroups.rosterVersion);
        }
        if (!await _columnExists('class_groups', 'roster_json')) {
          await m.addColumn(classGroups, classGroups.rosterJson);
        }
        if (!await _columnExists('sync_state', 'manifest_signer')) {
          await m.addColumn(syncState, syncState.manifestSigner);
        }
        if (!await _columnExists('sync_state', 'signer_versions_json')) {
          await m.addColumn(syncState, syncState.signerVersionsJson);
        }
        if (!await _tableExists('class_co_teachers')) {
          await m.createTable(classCoTeachers);
        }
        if (!await _indexExists('idx_class_co_teachers_unique')) {
          await m.create(idxClassCoTeachersUnique);
        }
        if (!await _tableExists('co_teaching_classes')) {
          await m.createTable(coTeachingClasses);
        }
        if (!await _indexExists('idx_co_teaching_classes_uuid')) {
          await m.create(idxCoTeachingClassesUuid);
        }
      }
      if (from < 20) {
        // Host failover: a standby device can take over the root teacher's
        // identity. Additive — generation 0 and a null epoch behave exactly
        // as before.
        for (final (table, col, add) in [
          (
            'sync_identity',
            'host_generation',
            () => m.addColumn(syncIdentity, syncIdentity.hostGeneration),
          ),
          (
            'sync_identity',
            'failover_seal_key',
            () => m.addColumn(syncIdentity, syncIdentity.failoverSealKey),
          ),
          (
            'sync_identity',
            'failover_kdf_salt',
            () => m.addColumn(syncIdentity, syncIdentity.failoverKdfSalt),
          ),
          (
            'sync_identity',
            'failover_kdf_rounds',
            () => m.addColumn(syncIdentity, syncIdentity.failoverKdfRounds),
          ),
          (
            'class_groups',
            'host_epoch',
            () => m.addColumn(classGroups, classGroups.hostEpoch),
          ),
        ]) {
          if (!await _columnExists(table, col)) await add();
        }
        if (!await _tableExists('failover_standbys')) {
          await m.createTable(failoverStandbys);
        }
        if (!await _indexExists('idx_failover_standbys_key')) {
          await m.create(idxFailoverStandbysKey);
        }
        if (!await _tableExists('host_ledgers')) {
          await m.createTable(hostLedgers);
        }
      }
      if (from < 21) {
        // Learners' quiz scores per note topic, for Achievements.
        // Additive: nothing earlier reads or writes it.
        if (!await _tableExists('quiz_results')) {
          await m.createTable(quizResults);
        }
        if (!await _indexExists('idx_quiz_results_student')) {
          await m.create(idxQuizResultsStudent);
        }
      }
      if (from < 22) {
        // Teacher profiles, and who created each class, stream and subject.
        // Additive: the first profile created claims what has no owner.
        if (!await _tableExists('teacher_profiles')) {
          await m.createTable(teacherProfiles);
        }
        if (!await _columnExists('class_groups', 'owner_teacher_id')) {
          await m.addColumn(classGroups, classGroups.ownerTeacherId);
        }
        if (await _tableExists('custom_subjects') &&
            !await _columnExists('custom_subjects', 'owner_teacher_id')) {
          await m.addColumn(customSubjects, customSubjects.ownerTeacherId);
        }
        if (await _tableExists('co_teaching_classes') &&
            !await _columnExists('co_teaching_classes', 'owner_teacher_id')) {
          await m.addColumn(
            coTeachingClasses,
            coTeachingClasses.ownerTeacherId,
          );
        }
      }
      if (from < 23) {
        // Learners' own PINs. Additive: null means no PIN.
        if (!await _columnExists('students', 'pin_salt')) {
          await m.addColumn(students, students.pinSalt);
        }
        if (!await _columnExists('students', 'pin_hash')) {
          await m.addColumn(students, students.pinHash);
        }
      }
      if (from < 24) {
        // The Admin role: the school's records, teaching assignments,
        // enrolments, and who uploaded each note.
        for (final (name, create) in [
          ('admin_identity', () => m.createTable(adminIdentity)),
          ('teaching_assignments', () => m.createTable(teachingAssignments)),
          ('student_enrolments', () => m.createTable(studentEnrolments)),
          ('note_owners', () => m.createTable(noteOwners)),
        ]) {
          if (!await _tableExists(name)) await create();
        }
        if (!await _indexExists('idx_teaching_assignments_teacher')) {
          await m.create(idxTeachingAssignmentsTeacher);
        }
        if (!await _indexExists('idx_student_enrolments_student')) {
          await m.create(idxStudentEnrolmentsStudent);
        }
        if (!await _columnExists('teacher_profiles', 'uuid')) {
          await m.addColumn(teacherProfiles, teacherProfiles.uuid);
        }
        if (!await _columnExists('students', 'uuid')) {
          await m.addColumn(students, students.uuid);
        }
        await _adoptOwnershipAsAssignments();
        await _createUuidTriggers();
      }
      if (from < 25) {
        // Admin sync: the Admin's signing key and records version, and on
        // a receiving device whose records it holds.
        if (!await _columnExists('admin_identity', 'signing_seed')) {
          await m.addColumn(adminIdentity, adminIdentity.signingSeed);
        }
        if (!await _columnExists('admin_identity', 'records_version')) {
          await m.addColumn(adminIdentity, adminIdentity.recordsVersion);
        }
        if (!await _tableExists('admin_records_state')) {
          await m.createTable(adminRecordsState);
        }
      }
      if (from < 26) {
        // Class assignments: learners' answers and teachers' grades.
        if (!await _tableExists('assignment_submissions')) {
          await m.createTable(assignmentSubmissions);
        }
        if (!await _indexExists('idx_submissions_assignment')) {
          await m.create(idxSubmissionsAssignment);
        }
      }
      if (from < 27) {
        // Device registry and revocation: who holds each class, who is
        // refused, and the keys a revocation replaced.
        for (final (name, create) in [
          ('class_members', () => m.createTable(classMembers)),
          ('revoked_devices', () => m.createTable(revokedDevices)),
          ('school_devices', () => m.createTable(schoolDevices)),
        ]) {
          if (!await _tableExists(name)) await create();
        }
        if (!await _indexExists('idx_class_members_device')) {
          await m.create(idxClassMembersDevice);
        }
        if (!await _columnExists('sync_identity', 'box_seed')) {
          await m.addColumn(syncIdentity, syncIdentity.boxSeed);
        }
        if (!await _columnExists('class_groups', 'retired_keys_json')) {
          await m.addColumn(classGroups, classGroups.retiredKeysJson);
        }
      }
      if (from < 28) {
        // Durability: which note versions each member device holds.
        if (!await _tableExists('channel_receipts')) {
          await m.createTable(channelReceipts);
        }
      }
      if (from < 29) {
        // Durability: the last progress report the teacher confirmed.
        if (!await _columnExists('students', 'progress_sent_digest')) {
          await m.addColumn(students, students.progressSentDigest);
        }
      }
      if (from < 30) {
        // Built-in subjects the Admin removed.
        if (!await _tableExists('removed_subjects')) {
          await m.createTable(removedSubjects);
        }
      }
      if (from < 31) {
        // Quiz answers given after the tutor replied. Additive: older
        // rounds stay null (unknown).
        if (!await _columnExists('quiz_results', 'tutor_used')) {
          await m.addColumn(quizResults, quizResults.tutorUsed);
        }
      }
      if (from < 32) {
        // Timed assessments (start time, drafts) and the cloud plug-in's
        // outbox. Additive.
        if (await _tableExists('assignment_submissions') &&
            !await _columnExists('assignment_submissions', 'started_at')) {
          await m.addColumn(
            assignmentSubmissions,
            assignmentSubmissions.startedAt,
          );
        }
        for (final (name, create) in [
          ('assignment_attempts', () => m.createTable(assignmentAttempts)),
          ('cloud_outbox', () => m.createTable(cloudOutbox)),
        ]) {
          if (!await _tableExists(name)) await create();
        }
      }
      if (from < 33) {
        // "Tutor used" on assignment answers, and a teacher's extra help
        // for one learner. Additive.
        for (final (table, column, add) in [
          (
            'assignment_attempts',
            'tutor_at',
            () => m.addColumn(assignmentAttempts, assignmentAttempts.tutorAt),
          ),
          (
            'assignment_submissions',
            'tutor_used',
            () => m.addColumn(
              assignmentSubmissions,
              assignmentSubmissions.tutorUsed,
            ),
          ),
        ]) {
          if (await _tableExists(table) &&
              !await _columnExists(table, column)) {
            await add();
          }
        }
        if (!await _tableExists('learner_support')) {
          await m.createTable(learnerSupport);
        }
        if (!await _indexExists('idx_learner_support_member')) {
          await m.create(idxLearnerSupportMember);
        }
      }
      if (from < 34) {
        // The school cloud link and the device's signed audit log.
        for (final (name, create) in [
          ('cloud_link', () => m.createTable(cloudLink)),
          ('audit_log', () => m.createTable(auditLog)),
        ]) {
          if (!await _tableExists(name)) await create();
        }
      }
      if (from < 35) {
        // Class Teachers: their classes/streams, and the learners they
        // register.
        for (final (name, create) in [
          (
            'class_teacher_assignments',
            () => m.createTable(classTeacherAssignments),
          ),
          ('learner_registrations', () => m.createTable(learnerRegistrations)),
        ]) {
          if (!await _tableExists(name)) await create();
        }
        if (!await _indexExists('idx_class_teacher_teacher')) {
          await m.create(idxClassTeacherTeacher);
        }
      }
      if (from < 36) {
        // Subjects a teacher made for themselves in Lesson materials.
        if (!await _tableExists('teacher_subjects')) {
          await m.createTable(teacherSubjects);
        }
      }
      if (from < 37) {
        // The PIN in the clear, so the Admin can look it up. Additive;
        // teachers/Admin from before have it null until the PIN is reset.
        for (final (table, column, add) in [
          (
            'teacher_profiles',
            'pin_plain',
            () => m.addColumn(teacherProfiles, teacherProfiles.pinPlain),
          ),
          (
            'admin_identity',
            'pin_plain',
            () => m.addColumn(adminIdentity, adminIdentity.pinPlain),
          ),
        ]) {
          if (await _tableExists(table) &&
              !await _columnExists(table, column)) {
            await add();
          }
        }
      }
    },
  );

  /// Decides an existing device's role from what it already did, since the
  /// teacher section used to be open on every device:
  ///
  ///  1. It created a class and actually shared it (the class has a key) →
  ///     teacher — even if it also joined someone's class, because its
  ///     students' devices depend on it.
  ///  2. Otherwise, it joined a class through a teacher → student.
  ///  3. Otherwise, it created a class → teacher.
  ///  4. Otherwise it stays undecided until it does one or the other.
  ///
  /// Raw SQL: generated classes would expect today's columns mid-upgrade.
  Future<void> _backfillDeviceRole() async {
    if (!await _tableExists('sync_identity') ||
        !await _tableExists('class_groups')) {
      return;
    }
    Future<bool> any(String where) async =>
        (await customSelect(
          'SELECT 1 FROM class_groups WHERE $where LIMIT 1',
        ).getSingleOrNull()) !=
        null;
    final String? role;
    if (await any('joined = 0 AND group_uuid IS NOT NULL AND class_key IS NOT NULL')) {
      role = kRoleTeacher;
    } else if (await any('joined = 1')) {
      role = kRoleStudent;
    } else if (await any('joined = 0')) {
      role = kRoleTeacher;
    } else {
      role = null;
    }
    if (role == null) return;
    await customStatement(
      'UPDATE sync_identity SET device_role = ? WHERE device_role IS NULL',
      [role],
    );
  }

  /// Schema 24: portable ids for teachers and learners, and today's
  /// ownership turned into the Admin's records, so every teacher keeps
  /// exactly what they could change before:
  ///
  ///  * a class's creator teaches each subject they created in it;
  ///  * each learner's class becomes an active enrolment;
  ///  * each of this device's notes belongs to its subject's creator.
  ///
  /// Raw SQL: generated classes would expect today's columns mid-upgrade.
  Future<void> _adoptOwnershipAsAssignments() async {
    const id = "lower(hex(randomblob(16)))";
    final now = DateTime.now().toUtc();
    final at = now.toIso8601String();
    await customStatement('UPDATE teacher_profiles SET uuid = $id WHERE uuid IS NULL');
    await customStatement('UPDATE students SET uuid = $id WHERE uuid IS NULL');
    await customStatement(
      'INSERT INTO student_enrolments '
      '(uuid, student_id, class_group_uuid, academic_year, status, created_at) '
      "SELECT $id, s.id, c.group_uuid, ?, 'active', ? "
      'FROM students s JOIN class_groups c ON c.id = s.class_group_id '
      'WHERE c.joined = 0 AND c.group_uuid IS NOT NULL '
      // Re-run safe (see the note above `if (from < 9)`): a learner who
      // already has an enrolment keeps exactly that one.
      '  AND NOT EXISTS (SELECT 1 FROM student_enrolments e '
      '                  WHERE e.student_id = s.id)',
      [now.year, at],
    );
    // A database that never had teacher-made subjects has no ownership to
    // carry over.
    if (!await _tableExists('custom_subjects')) return;
    await customStatement(
      'INSERT INTO teaching_assignments '
      '(uuid, teacher_id, class_group_uuid, subject_id, academic_year, term, created_at) '
      'SELECT $id, c.owner_teacher_id, c.group_uuid, s.subject_id, ?, 0, ? '
      'FROM class_groups c JOIN custom_subjects s '
      '  ON s.owner_teacher_id = c.owner_teacher_id '
      'WHERE c.joined = 0 AND c.group_uuid IS NOT NULL '
      '  AND c.owner_teacher_id IS NOT NULL AND s.class_group_uuid IS NULL '
      '  AND NOT EXISTS (SELECT 1 FROM teaching_assignments a '
      '                  WHERE a.teacher_id = c.owner_teacher_id '
      '                    AND a.class_group_uuid = c.group_uuid '
      '                    AND a.subject_id = s.subject_id)',
      [now.year, at],
    );
    await customStatement(
      'INSERT OR IGNORE INTO note_owners (subject_id, document_title, teacher_id) '
      'SELECT DISTINCT t.subject_id, COALESCE(t.document_title, t.resource_title), '
      '       s.owner_teacher_id '
      'FROM topic_resources t JOIN custom_subjects s ON s.subject_id = t.subject_id '
      'WHERE t.class_group_uuid IS NULL AND s.owner_teacher_id IS NOT NULL',
    );
  }

  /// Gives every new learner and teacher a portable id, whichever code
  /// path inserts them.
  Future<void> _createUuidTriggers() async {
    for (final table in ['students', 'teacher_profiles']) {
      await customStatement(
        'CREATE TRIGGER IF NOT EXISTS ${table}_uuid AFTER INSERT ON $table '
        'WHEN NEW.uuid IS NULL BEGIN '
        '  UPDATE $table SET uuid = lower(hex(randomblob(16))) '
        '  WHERE id = NEW.id; '
        'END',
      );
    }
  }

  Future<bool> _tableExists(String name) async {
    final row = await customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable.withString(name)],
    ).getSingleOrNull();
    return row != null;
  }

  Future<void> _createIndexIfMissing(Migrator m, Index index) async {
    if (!await _indexExists(index.entityName)) await m.create(index);
  }

  Future<bool> _indexExists(String name) async {
    final row = await customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
      variables: [Variable.withString(name)],
    ).getSingleOrNull();
    return row != null;
  }

  /// Whether [table] already has a column named [column] — the only check
  /// that can never be wrong about a table's actual shape, unlike inferring
  /// it from the migration version number (see the standing note above
  /// `if (from < 9)`). `pragma_table_info` is a read-only table-valued
  /// function, safe to query even mid-migration.
  Future<bool> _columnExists(String table, String column) async {
    final row = await customSelect(
      'SELECT 1 FROM pragma_table_info(?) WHERE name = ?',
      variables: [Variable.withString(table), Variable.withString(column)],
    ).getSingleOrNull();
    return row != null;
  }

  /// FTS5 index over `topic_resources` (title + chunk text), kept in sync by
  /// triggers so no write path can forget to update it.
  ///
  /// External-content table: the text lives once, in `topic_resources`; the
  /// index holds only tokens, keyed by `rowid = topic_resources.id`. The
  /// porter tokenizer folds inflections ("chemicals" → "chemical",
  /// "evaporating" → "evaporation") — see `TopicResourceDao.searchChunks`
  /// for how derived forms it misses are caught with prefix terms.
  ///
  /// FTS5 comes from the SQLite build `sqlite3_flutter_libs` ships; no extra
  /// dependency.
  Future<void> _createResourceSearchIndex() async {
    await customStatement(
      "CREATE VIRTUAL TABLE IF NOT EXISTS topic_resources_fts USING fts5("
      "resource_title, content_chunk, "
      "content='topic_resources', content_rowid='id', "
      "tokenize='porter unicode61')",
    );
    await customStatement(
      'CREATE TRIGGER IF NOT EXISTS topic_resources_fts_ai '
      'AFTER INSERT ON topic_resources BEGIN '
      '  INSERT INTO topic_resources_fts(rowid, resource_title, content_chunk) '
      '  VALUES (new.id, new.resource_title, new.content_chunk); '
      'END',
    );
    await customStatement(
      'CREATE TRIGGER IF NOT EXISTS topic_resources_fts_ad '
      'AFTER DELETE ON topic_resources BEGIN '
      "  INSERT INTO topic_resources_fts(topic_resources_fts, rowid, "
      '    resource_title, content_chunk) '
      "  VALUES ('delete', old.id, old.resource_title, old.content_chunk); "
      'END',
    );
    await customStatement(
      'CREATE TRIGGER IF NOT EXISTS topic_resources_fts_au '
      'AFTER UPDATE ON topic_resources BEGIN '
      "  INSERT INTO topic_resources_fts(topic_resources_fts, rowid, "
      '    resource_title, content_chunk) '
      "  VALUES ('delete', old.id, old.resource_title, old.content_chunk); "
      '  INSERT INTO topic_resources_fts(rowid, resource_title, content_chunk) '
      '  VALUES (new.id, new.resource_title, new.content_chunk); '
      'END',
    );
  }

  static QueryExecutor _openConnection() {
    return LazyDatabase(() async {
      final dir = await resolveAppStorageDirectory();
      final file = File(p.join(dir.path, 'otic_student_db.sqlite'));
      return NativeDatabase.createInBackground(
        file,
        setup: (db) {
          // WAL lets a translation-cache lookup or a chat-session read run
          // while a session/badge write is still in flight, instead of
          // queuing behind SQLite's default rollback-journal lock — this is
          // a chat app that reads and writes on every turn. NORMAL sync is
          // the standard WAL pairing: still crash-safe (readers never see a
          // torn page), just not fsync-per-commit.
          db.execute('PRAGMA journal_mode=WAL;');
          db.execute('PRAGMA synchronous=NORMAL;');
          // A few MB of page cache for a database that stays under ~10 MB
          // on-device — cheap, and keeps hot tables (translation cache,
          // topic_resources_fts) resident instead of re-hitting disk.
          db.execute('PRAGMA cache_size=-8000;');
          db.execute('PRAGMA temp_store=MEMORY;');
        },
      );
    });
  }
}
