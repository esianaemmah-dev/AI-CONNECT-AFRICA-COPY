import 'dart:async';
import '../../services/auth/local_auth.dart';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db/otic_database.dart';
import '../../db/providers/db_provider.dart';
import '../../services/audit/audit_log.dart';
import 'teacher_pin.dart';

/// Teachers who sign in on this device, each with their own PIN.
///
/// The Admin adds teachers (`AdminService.addTeacher`); the Teachers PIN
/// ([TeacherPin]) opens the Teachers area, where each signs in. What a
/// teacher may do follows from the Admin's teaching assignments
/// (`TeachingScope`). Like the other PINs, this keeps people apart on a
/// shared device; it is not real security.
class TeacherProfileService {
  TeacherProfileService(this._db);

  final OticDatabase _db;
  static final _databaseLeases = Expando<Map<int, StaffLease>>();
  Map<int, StaffLease> get leases => _databaseLeases[_db] ??= {};
  bool valid(int id) => leases[id]?.valid ?? false;
  void signOut(int id) {
    leases.remove(id)?.revoked = true;
  }

  Stream<List<TeacherProfile>> watchAll() => (_db.select(
    _db.teacherProfiles,
  )..orderBy([(t) => OrderingTerm.asc(t.name)])).watch();

  Future<List<TeacherProfile>> all() => (_db.select(
    _db.teacherProfiles,
  )..orderBy([(t) => OrderingTerm.asc(t.name)])).get();

  /// The profile when [pin] is its PIN, else null.
  Future<TeacherProfile?> signIn(int teacherId, String pin) async {
    final row = await (_db.select(
      _db.teacherProfiles,
    )..where((t) => t.id.equals(teacherId))).getSingleOrNull();
    if (row == null) return null;
    if (!await LocalAuthThrottle().check(
      'teacher:$teacherId',
      () => pinMatches(row.pinSalt, pin, row.pinHash),
    )) {
      await AuditLogService(
        _db,
      ).record('device', 'refused.teacher_pin', detail: 'teacher:$teacherId');
      return null;
    }
    if (pinNeedsUpgrade(row.pinHash)) {
      await (_db.update(
        _db.teacherProfiles,
      )..where((t) => t.id.equals(teacherId))).write(
        TeacherProfilesCompanion(
          pinHash: Value(await hashPinStrong(row.pinSalt, pin)),
        ),
      );
    }
    leases[teacherId]?.revoked = true;
    leases[teacherId] = StaffLease();
    return row;
  }

  /// Changes [teacherId]'s PIN; false when [current] is wrong.
  Future<bool> changePin(int teacherId, String current, String next) async {
    if (!TeacherPin.isValidFormat(next)) return false;
    if (await signIn(teacherId, current) == null) return false;
    final salt = newPinSalt();
    await (_db.update(
      _db.teacherProfiles,
    )..where((t) => t.id.equals(teacherId))).write(
      TeacherProfilesCompanion(
        pinSalt: Value(salt),
        pinHash: Value(await hashPinStrong(salt, next)),
      ),
    );
    return true;
  }
}

final teacherProfileServiceProvider = Provider<TeacherProfileService>(
  (ref) => TeacherProfileService(ref.watch(dbProvider)),
);

final teacherProfilesProvider = StreamProvider<List<TeacherProfile>>((ref) {
  if (kIsWeb) return Stream.value(const []);
  return ref.watch(teacherProfileServiceProvider).watchAll();
});

/// How long a teacher or the Admin stays signed in.
const kSessionLife = Duration(minutes: 60);

/// The teacher signed in on this device, or null.
///
/// In memory only, so nobody is signed in after a restart. Cleared with
/// [teacherUnlockedProvider] whenever the device is handed to a learner,
/// and [kSessionLife] after signing in.
final activeTeacherProvider = StateProvider<TeacherProfile?>((ref) {
  Timer? expiry;
  ref.onDispose(() => expiry?.cancel());
  ref.listenSelf((previous, next) {
    if (previous != null && previous.id != next?.id) {
      ref.read(teacherProfileServiceProvider).signOut(previous.id);
    }
    expiry?.cancel();
    if (next != null) {
      expiry = Timer(kSessionLife, () => ref.controller.state = null);
    }
  });
  return null;
});

/// The signed-in teacher's id, or null.
final activeTeacherIdProvider = Provider<int?>(
  (ref) => ref.watch(activeTeacherProvider)?.id,
);
