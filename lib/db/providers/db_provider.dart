import '../../features/admin/admin_service.dart';
import '../../features/teacher/teacher_profiles.dart';
import '../../core/policy/policy.dart';
import '../../collaboration/sync/class_enrolment.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../otic_database.dart';
import '../../memory/session_recall_store.dart';
import '../../services/academic_score_tracker_repository.dart';
import '../../services/learner_data_wiper.dart';
import '../../services/learning/tutor_use.dart';

// ── Database singleton ────────────────────────────────────────────────────────

final dbProvider = Provider<OticDatabase>((ref) {
  final db = OticDatabase();
  ref.onDispose(db.close);
  return db;
});

// ── Student ───────────────────────────────────────────────────────────────────

/// SharedPreferences key holding the id of the learner using the device now.
///
/// On a shared classroom device several learners have profiles, so "active"
/// has to be an explicit choice — written on onboarding and on every switch.
const kActiveStudentIdKey = 'active_student_id';

/// The learner currently using the device.
///
/// The saved [kActiveStudentIdKey] wins. Without one (installs from before
/// multi-learner support) or when it points at a deleted profile, falls back
/// to the most recently active profile — exactly the old behaviour.
Future<Student?> resolveActiveStudent(OticDatabase db) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getInt(kActiveStudentIdKey);
    if (id != null) {
      final chosen = await db.studentDao.getStudentById(id);
      if (chosen != null) return chosen;
    }
  } catch (e) {
    debugPrint('resolveActiveStudent: prefs unavailable: $e');
  }
  return db.studentDao.getActiveStudent();
}

/// The active student profile, or null if no profile created yet.
final activeStudentProvider = FutureProvider<Student?>((ref) {
  if (kIsWeb) return Future.value(null);
  final db = ref.watch(dbProvider);
  return resolveActiveStudent(db);
});

/// True if the device has an existing student profile.
final hasProfileProvider = FutureProvider<bool>((ref) async {
  if (kIsWeb) return false;
  final student = await ref.watch(activeStudentProvider.future);
  return student != null;
});

/// A fresh read of one student row, keyed by id.
///
/// [activeStudentProvider] is watched widely (chat, router, the app shell),
/// so invalidating it on every Practice answer or Apply scenario would
/// rebuild all of that just to move a counter. Achievements is the only
/// screen that needs those counters live, so BadgeService invalidates this
/// instead — autoDispose means it costs nothing once the screen closes.
final studentStatsProvider =
    FutureProvider.family.autoDispose<Student?, int>((ref, studentId) {
  final db = ref.watch(dbProvider);
  return db.studentDao.getStudentById(studentId);
});

// ── Session history ───────────────────────────────────────────────────────────

final recentSessionsProvider =
    FutureProvider.family((ref, int studentId) {
  final db = ref.watch(dbProvider);
  return db.sessionDao.getRecentSessions(studentId, limit: 20);
});

/// Per-session recall files, beside the student database.
final sessionRecallStoreProvider =
    Provider((ref) => SessionRecallStore());

/// Deletes a learner's own data (never app/teacher resources) — see
/// LearnerDataWiper's own doc for exactly what that covers. Teacher/Admin
/// only: the screens that read this are behind the teacher PIN gate.
final learnerDataWiperProvider = Provider((ref) => LearnerDataWiper(
      ref.watch(dbProvider),
      recallStore: ref.watch(sessionRecallStoreProvider),
    ));

/// One entry per saved chat, newest activity first.
///
/// Streamed straight from the index table so the sidebar updates as soon as a
/// turn is written, with no invalidation dance. The recall files are not
/// touched here — listing must stay cheap however many chats exist.
final chatSessionsProvider =
    StreamProvider.family((ref, int studentId) {
  final db = ref.watch(dbProvider);
  return db.chatSessionDao.watchRecentSessions(studentId);
});

final topicProgressProvider =
    FutureProvider.family((ref, int studentId) {
  final db = ref.watch(dbProvider);
  return db.sessionDao.getTopicProgress(studentId);
});

// ── Student notifier (create / update) ───────────────────────────────────────

class StudentNotifier extends AsyncNotifier<Student?> {
  @override
  Future<Student?> build() async {
    final db = ref.watch(dbProvider);
    return resolveActiveStudent(db);
  }

  Future<void> createProfile({
    required String name,
    int? age,
    String? grade,
    String language = 'en',
    List<String> interests = const [],
    String learningStyle = 'unknown',
  }) async {
    final db = ref.read(dbProvider);

    // Never add a second profile to a device that already has one. Badges,
    // points and streak hang off a student row, and getActiveStudent() returns
    // whichever was active last — so an insert here would leave everything the
    // student earned stranded on the old row, invisible and unreachable.
    // Onboarding can legitimately be reached with a profile already present
    // (the router falls back to it when the profile lookup is slow, and its
    // own `_existingStudentId` reads null while that lookup is still loading),
    // so the guard has to live here rather than only at the call site.
    final existing = await resolveActiveStudent(db);
    if (existing != null) {
      await updateProfile(
        id: existing.id,
        name: name,
        age: age,
        grade: grade,
        language: language,
        interests: interests,
        learningStyle: learningStyle,
      );
      return;
    }

    final id = await db.studentDao.createStudent(
      StudentsCompanion.insert(
        name: name,
        age: Value(age),
        grade: Value(grade),
        language: Value(language),
        interestsJson: Value(_toJson(interests)),
        learningStyle: Value(learningStyle),
        createdAt: Value(DateTime.now()),
        lastActiveAt: Value(DateTime.now()),
      ),
    );
    await _rememberActive(id);
    state = AsyncData(await db.studentDao.getStudentById(id));
    ref.invalidate(activeStudentProvider);
    ref.invalidate(hasProfileProvider);
  }

  /// Adds another learner to this device — for a teacher enrolling a class
  /// or a learner joining a shared device. Always inserts; unlike
  /// [createProfile] it is never re-entered by onboarding, so it has no
  /// "update the existing row instead" guard. Does not switch to the new
  /// learner (a teacher adding thirty learners must not be switched thirty
  /// times) — see `LearnerSwitcher.switchTo`.
  Future<int> addLearner({
    required String name,
    int? age,
    String? grade,
    String language = 'en',
    int? classGroupId,
  }) async {
    final db = ref.read(dbProvider);
    ClassGroup? group;
    final admin = ref.read(adminSessionProvider);
    final teacherId = ref.read(activeTeacherIdProvider);
    if (classGroupId != null) {
      group = await (db.select(db.classGroups)..where((t) => t.id.equals(classGroupId))).getSingleOrNull();
      if (group?.groupUuid == null || !await ref.read(policyProvider).can(
        admin != null ? AdminActor(admin) : TeacherActor(teacherId), RegisterLearner(group!.groupUuid!))) {
        throw StateError('A class teacher must approve this enrolment.');
      }
    }

    return db.transaction(() async {
    final id = await db.studentDao.createStudent(
      StudentsCompanion.insert(
        name: name.trim(),
        age: Value(age),
        grade: Value(grade),
        language: Value(language),
        classGroupId: const Value(null),
        createdAt: Value(DateTime.now()),
        // Oldest possible "last active": adding a learner must not make them
        // the fallback active profile on an install with no saved choice.
        lastActiveAt: Value(DateTime.fromMillisecondsSinceEpoch(0)),
      ),
    );
    if (group != null) {
      if (admin != null) {
        await ref.read(adminServiceProvider).enrol(admin, studentId: id, group: group, academicYear: DateTime.now().year);
      } else {
        final enrolments = ClassEnrolment(db);
        await enrolments.approve(learnerUuid: await enrolments.learnerUuid(id), name: name, group: group, teacherId: teacherId);
      }
    }
    return id;
    });
  }

  Future<void> _rememberActive(int id) async {
    ref.read(tutorLastReplyProvider.notifier).state = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(kActiveStudentIdKey, id);
    } catch (e) {
      debugPrint('Could not save active learner: $e');
    }
  }

  Future<void> touch(int id) async {
    final db = ref.read(dbProvider);
    await db.studentDao.touchStudent(id);
  }

  /// Updates the existing profile in place — unlike [createProfile], this
  /// never inserts a second row (which would leave two students competing
  /// for "active" and break [getActiveStudent]'s single-row assumption).
  /// Fields left null are left untouched in the DB (except [name], which is
  /// always required and always overwrites) — a caller updating just one
  /// field, e.g. only `language`, must not silently wipe the others.
  Future<void> updateProfile({
    required int id,
    required String name,
    int? age,
    String? grade,
    String? language,
    List<String>? interests,
    String? learningStyle,
  }) async {
    final db = ref.read(dbProvider);
    await db.studentDao.updateStudent(
      StudentsCompanion(
        id: Value(id),
        name: Value(name),
        age: age != null ? Value(age) : const Value.absent(),
        grade: grade != null ? Value(grade) : const Value.absent(),
        language: language != null ? Value(language) : const Value.absent(),
        interestsJson: interests != null ? Value(_toJson(interests)) : const Value.absent(),
        learningStyle: learningStyle != null ? Value(learningStyle) : const Value.absent(),
        lastActiveAt: Value(DateTime.now()),
      ),
    );
    state = AsyncData(await db.studentDao.getStudentById(id));
    ref.invalidate(activeStudentProvider);
  }

  String _toJson(List<String> list) =>
      '[${list.map((s) => '"$s"').join(',')}]';
}

final studentNotifierProvider =
    AsyncNotifierProvider<StudentNotifier, Student?>(StudentNotifier.new);

// ── Badges ────────────────────────────────────────────────────────────────────

final earnedBadgesProvider = FutureProvider.family((ref, int studentId) {
  final db = ref.watch(dbProvider);
  return db.badgeDao.getBadgesForStudent(studentId);
});

// ── Projects ──────────────────────────────────────────────────────────────────

final studentProjectsProvider = FutureProvider.family((ref, int studentId) {
  final db = ref.watch(dbProvider);
  return db.projectDao.getProjectsForStudent(studentId);
});

// ── Websites ──────────────────────────────────────────────────────────────────

final studentWebsitesProvider = FutureProvider.family((ref, int studentId) {
  final db = ref.watch(dbProvider);
  return db.websiteDao.getWebsitesForStudent(studentId);
});

// ── App Builder projects ─────────────────────────────────────────────────────

final studentAppBuilderProjectsProvider =
    FutureProvider.family((ref, int studentId) {
  final db = ref.watch(dbProvider);
  return db.appBuilderProjectDao.getProjectsForStudent(studentId);
});

// ── Academic score tracking (assignments, rolling year progress) ───────────

final academicScoreTrackerProvider =
    Provider<AcademicScoreTrackerRepository>((ref) {
  return AcademicScoreTrackerRepository(ref.watch(dbProvider));
});

final subjectYearProgressProvider = FutureProvider.family
    .autoDispose<Map<String, SubjectYearProgress>, int>((ref, studentId) {
  return ref.watch(academicScoreTrackerProvider).yearProgressBySubject(studentId);
});
