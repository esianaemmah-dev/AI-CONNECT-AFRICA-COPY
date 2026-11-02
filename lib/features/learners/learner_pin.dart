import 'package:drift/drift.dart';
import '../../services/auth/local_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db/otic_database.dart';
import '../../db/providers/db_provider.dart';
import '../teacher/teacher_pin.dart';
import '../teacher/teacher_pin_screen.dart';

/// A learner's own PIN, asked before a shared device is switched to them.
///
/// Like the teacher PINs it keeps people apart on a shared device; it is not
/// real security. Only a salted hash is stored. A teacher can clear a
/// forgotten one from Teachers.
class LearnerPinService {
  LearnerPinService(this._db);

  final OticDatabase _db;

  Future<Student?> _row(int studentId) => (_db.select(
    _db.students,
  )..where((t) => t.id.equals(studentId))).getSingleOrNull();

  Future<bool> isSet(int studentId) async =>
      (await _row(studentId))?.pinHash != null;

  /// True when [pin] is right, or when the learner has no PIN.
  Future<bool> verify(int studentId, String pin) async {
    final row = await _row(studentId);
    if (row == null) return false;
    final hash = row.pinHash, salt = row.pinSalt;
    if (hash == null || salt == null) return true;
    if (!await LocalAuthThrottle().check('learner:$studentId', () => pinMatches(salt, pin, hash))) return false;
    if (pinNeedsUpgrade(hash)) {
      await (_db.update(
        _db.students,
      )..where((t) => t.id.equals(studentId))).write(
        StudentsCompanion(pinHash: Value(await hashPinStrong(salt, pin))),
      );
    }
    return true;
  }

  Future<void> set(int studentId, String pin) async {
    if (!TeacherPin.isValidFormat(pin)) {
      throw ArgumentError('A PIN is 4 to 8 digits.');
    }
    final salt = newPinSalt();
    final hash = await hashPinStrong(salt, pin);
    await (_db.update(_db.students)..where((t) => t.id.equals(studentId)))
        .write(StudentsCompanion(pinSalt: Value(salt), pinHash: Value(hash)));
  }

  Future<void> clear(int studentId) =>
      (_db.update(_db.students)..where((t) => t.id.equals(studentId))).write(
        const StudentsCompanion(pinSalt: Value(null), pinHash: Value(null)),
      );
}

final learnerPinServiceProvider = Provider<LearnerPinService>(
  (ref) => LearnerPinService(ref.watch(dbProvider)),
);

/// My PIN for [student]: set one, or (with the current PIN) change or
/// remove it.
Future<void> showLearnerPinSettings(
  BuildContext context,
  WidgetRef ref,
  Student student,
) async {
  final service = ref.read(learnerPinServiceProvider);
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) =>
      messenger.showSnackBar(SnackBar(content: Text(text)));

  if (await service.isSet(student.id)) {
    if (!context.mounted) return;
    final current = await askTeacherPin(context, title: 'Current PIN');
    if (current == null) return;
    if (!await service.verify(student.id, current)) {
      return say('That PIN is not right.');
    }
    if (!context.mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('My PIN'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'change'),
            child: const Text('Change PIN'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'remove'),
            child: const Text('Remove PIN'),
          ),
        ],
      ),
    );
    if (action == 'remove') {
      await service.clear(student.id);
      return say('PIN removed.');
    }
    if (action != 'change') return;
  }

  if (!context.mounted) return;
  final next = await askTeacherPin(context, title: 'New PIN (4–8 digits)');
  if (next == null) return;
  if (!TeacherPin.isValidFormat(next)) return say('A PIN is 4 to 8 digits.');
  if (!context.mounted) return;
  final again = await askTeacherPin(context, title: 'New PIN again');
  if (again == null) return;
  if (again != next) return say('The two PINs did not match.');
  await service.set(student.id, next);
  say('PIN set.');
}
