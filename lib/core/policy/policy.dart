import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db/otic_database.dart';
import '../../db/providers/db_provider.dart';
import '../../features/admin/admin_service.dart';
import '../../features/teacher/teacher_profiles.dart';
import '../../features/teacher/teaching_scope.dart';

/// Who is acting. Built from the signed-in sessions, never from the screen
/// someone is on.
sealed class Actor {
  const Actor();
}

/// The Admin, holding a session only the Admin PIN yields.
final class AdminActor extends Actor {
  const AdminActor(this.session);
  final AdminSession session;
}

/// Someone past the Teachers PIN; [teacherId] is the signed-in teacher
/// profile, or null when nobody has signed in on Teachers yet.
final class TeacherActor extends Actor {
  const TeacherActor(this.teacherId);
  final int? teacherId;
}

/// The device's active learner.
final class LearnerActor extends Actor {
  const LearnerActor(this.studentId);
  final int studentId;
}

/// Nobody: no learner picked, no PIN entered.
final class GuestActor extends Actor {
  const GuestActor();
}

/// What is being asked for, and of what.
sealed class Request {
  const Request();
}

/// Read a subject's notes and open its PDFs.
final class ReadNotes extends Request {
  const ReadNotes(this.subjectId);
  final String subjectId;
}

/// Upload a new note to a subject.
final class UploadNote extends Request {
  const UploadNote(this.subjectId);
  final String subjectId;
}

/// Change, delete or grade the assignments of one uploaded note.
final class ChangeNote extends Request {
  const ChangeNote(this.subjectId, this.documentTitle);
  final String subjectId;
  final String documentTitle;
}

/// Share one note into a class/stream.
final class ShareNote extends Request {
  const ShareNote(this.subjectId, this.documentTitle, this.classGroupUuid);
  final String subjectId;
  final String documentTitle;
  final String classGroupUuid;
}

/// See and revoke the devices that joined one class/stream.
final class ManageClassDevices extends Request {
  const ManageClassDevices(this.classGroupUuid);
  final String classGroupUuid;
}

/// Send one learner of a class/stream extra help in a subject.
final class SupportLearner extends Request {
  const SupportLearner(this.subjectId, this.classGroupUuid);
  final String subjectId;
  final String classGroupUuid;
}

/// Register a new learner into one class/stream: the Admin, or a Class
/// Teacher the Admin gave that class/stream.
final class RegisterLearner extends Request {
  const RegisterLearner(this.classGroupUuid);
  final String classGroupUuid;
}

/// The school's records: teachers, classes, subjects, assignments,
/// learners and enrolments.
final class ManageSchool extends Request {
  const ManageSchool();
}

/// The one place that decides whether an actor may do something. It reads
/// the role from the [Actor] and the relationship (teaching assignments,
/// enrolments, note owners) from the database, so a screen never decides
/// on its own.
class Policy {
  Policy(this._db, {this.authenticated}) : _scope = TeachingScope(_db);
  final bool Function(Actor)? authenticated;

  final OticDatabase _db;
  final TeachingScope _scope;

  Future<bool> can(Actor actor, Request request) async {
    if (authenticated != null && !authenticated!(actor)) return false;
    return switch (request) {
      ReadNotes(:final subjectId) => switch (await readableSubjects(actor)) {
        null => true,
        final readable => readable.contains(subjectId),
      },
      UploadNote(:final subjectId) =>
        actor is TeacherActor &&
            await _scope.mayUpload(actor.teacherId, subjectId),
      ChangeNote(:final subjectId, :final documentTitle) =>
        actor is TeacherActor &&
            await _scope.mayChangeNote(
              actor.teacherId,
              subjectId,
              documentTitle,
            ),
      ShareNote(
        :final subjectId,
        :final documentTitle,
        :final classGroupUuid,
      ) =>
        actor is TeacherActor &&
            await _scope.mayShare(
              actor.teacherId,
              subjectId,
              documentTitle,
              classGroupUuid,
            ),
      ManageClassDevices(:final classGroupUuid) =>
        actor is AdminActor ||
            (actor is TeacherActor &&
                actor.teacherId != null &&
                (await _scope.assignments(
                  actor.teacherId!,
                )).any((a) => a.classGroupUuid == classGroupUuid)),
      SupportLearner(:final subjectId, :final classGroupUuid) =>
        actor is TeacherActor &&
            await _scope.teaches(
              actor.teacherId,
              subjectId,
              classGroupUuid: classGroupUuid,
            ),
      RegisterLearner(:final classGroupUuid) =>
        actor is AdminActor ||
            (actor is TeacherActor &&
                (await _scope.classTeacherOf(
                  actor.teacherId,
                )).contains(classGroupUuid)),
      ManageSchool() => actor is AdminActor,
    };
  }

  /// Subjects whose notes [actor] may read; null means every subject.
  Future<Set<String>?> readableSubjects(Actor actor) =>
      watchReadableSubjects(actor).first;

  /// [readableSubjects], live: a learner receives every subject taught or
  /// shared with their current class, without choosing subjects separately.
  Stream<Set<String>?> watchReadableSubjects(Actor actor) async* {
    if (authenticated != null && !authenticated!(actor)) {
      yield const {};
      return;
    }
    if (actor is TeacherActor || actor is AdminActor) {
      yield null;
      return;
    }
    if (actor is! LearnerActor) {
      yield const {};
      return;
    }
    yield* _db.classSyncDao.watchReadable(actor.studentId);
  }
}

final policyProvider = Provider<Policy>(
  (ref) => Policy(
    ref.watch(dbProvider),
    authenticated: (actor) => switch (actor) {
      TeacherActor(:final teacherId) =>
        teacherId != null &&
            ref.read(activeTeacherIdProvider) == teacherId &&
            ref.read(teacherProfileServiceProvider).valid(teacherId),
      AdminActor(:final session) =>
        identical(ref.read(adminSessionProvider), session) && session.isValid,
      _ => true,
    },
  ),
);

/// The actor for the notes a person at the device may read: past the
/// Teachers PIN is a teacher, otherwise the active learner.
final notesActorProvider = FutureProvider.autoDispose<Actor>((ref) async {
  if (ref.watch(activeTeacherProvider) != null) {
    return TeacherActor(ref.watch(activeTeacherIdProvider));
  }
  final me = await ref.watch(activeStudentProvider.future);
  return me == null ? const GuestActor() : LearnerActor(me.id);
});
