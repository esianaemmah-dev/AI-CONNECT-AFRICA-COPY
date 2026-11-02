import 'dart:convert';

import 'package:drift/drift.dart';

import '../../curriculum/curriculum_provider.dart' show CurriculumService;
import '../../curriculum/subject_style.dart';
import '../../db/otic_database.dart';
import '../../features/teacher/teaching_scope.dart';
import '../../services/audit/audit_log.dart';
import '../sync/class_crypto.dart';
import '../sync/class_enrolment.dart';
import '../sync/device_registry.dart';
import 'admin_records_crypto.dart';

/// Why a bundle of school records was refused, or null when it was taken.
typedef AdminRecordsError = String;

/// The Admin's school records as one signed bundle, sent one way: from the
/// device the Admin uses to another device.
///
/// - The bundle is the exact JSON text of the records plus the Admin key's
///   signature over that text. A receiver takes it only if the signature
///   checks out against the Admin key it already trusts (the first bundle
///   it ever takes, after the Admin tapped Accept, pins that key) and the
///   version is newer than the one it holds — so it can't be forged,
///   edited or rolled back.
/// - Applying is one transaction and idempotent: the same bundle twice
///   changes nothing.
/// - Teachers and learners are added or updated, never deleted: a device
///   keeps a learner's local progress even if the Admin removed them.
///   Assignments and enrolments are replaced whole.
class AdminRecords {
  AdminRecords(this._db);

  final OticDatabase _db;

  // ── Sending (the Admin's device) ──────────────────────────────────────

  /// This device's Admin row, with a signing key minted on first use.
  Future<AdminIdentityRow?> _admin() async {
    final row = await (_db.select(
      _db.adminIdentity,
    )..where((t) => t.id.equals(1))).getSingleOrNull();
    if (row == null || row.signingSeed != null) return row;
    await (_db.update(_db.adminIdentity)..where((t) => t.id.equals(1))).write(
      AdminIdentityCompanion(signingSeed: Value(newSigningSeed())),
    );
    return (_db.select(
      _db.adminIdentity,
    )..where((t) => t.id.equals(1))).getSingle();
  }

  /// The signed bundle of every school record, at a new version. Null
  /// unless this device's Admin is set up and the school is set.
  /// [takeover] (sealed Admin details) lets the Admin take over on the
  /// receiving device with their passphrase.
  Future<Map<String, Object?>?> export({Map<String, Object?>? takeover}) =>
      _db.transaction(() async {
        final admin = await _admin();
        final me = await _db.classSyncDao.identity();
        if (admin == null || admin.signingSeed == null || me.schoolId == null) {
          return null;
        }
        final state = await _state();
        final version =
            [admin.recordsVersion, state?.version ?? 0,
            ].reduce((a, b) => a > b ? a : b) +
            1;
        await (_db.update(_db.adminIdentity)..where((t) => t.id.equals(1)))
            .write(AdminIdentityCompanion(recordsVersion: Value(version)));

        final teachers = await _db.select(_db.teacherProfiles).get();
        final teacherUuid = {for (final t in teachers) t.id: t.uuid};
        final classes = <ClassGroup>[];
        for (final c in await (_db.select(
          _db.classGroups,
        )..where((t) => t.joined.equals(false))).get()) {
          if (c.groupUuid == null) continue;
          classes.add(await _db.classSyncDao.ensureClassKey(c));
        }
        final learners = await _db.select(_db.students).get();
        final learnerUuid = {for (final l in learners) l.id: l.uuid};

        final payload = jsonEncode({
          'format': kAdminRecordsFormat,
          'school_id': me.schoolId,
          'school_name': me.schoolName ?? '',
          'version': version,
          'issued_at': DateTime.now().toUtc().toIso8601String(),
          'admin_public_key': await signingPublicKey(admin.signingSeed!),
          'teachers': [
            for (final t in teachers)
              if (t.uuid != null)
                {
                  'uuid': t.uuid,
                  'name': t.name,
                  'pin_salt': t.pinSalt,
                  'pin_hash': t.pinHash,
                },
          ],
          'classes': [
            for (final c in classes)
              {
                'uuid': c.groupUuid,
                'name': c.className,
                'stream': c.streamName,
                'class_key': c.classKey,
              },
          ],
          'subjects': [
            for (final s in await (_db.select(
              _db.customSubjects,
            )..where((t) => t.classGroupUuid.isNull())).get())
              {
                'id': s.subjectId,
                'name': s.name,
                'icon': s.icon,
                'color': s.color,
              },
          ],
          'removed_subjects': [
            for (final r in await _db.select(_db.removedSubjects).get())
              r.subjectId,
          ],
          'assignments': [
            for (final a in await _db.select(_db.teachingAssignments).get())
              if (teacherUuid[a.teacherId] != null)
                {
                  'uuid': a.uuid,
                  'teacher_uuid': teacherUuid[a.teacherId],
                  'class_uuid': a.classGroupUuid,
                  'subject_id': a.subjectId,
                  'year': a.academicYear,
                  'term': a.term,
                },
          ],
          'learners': [
            for (final l in learners)
              if (l.uuid != null)
                {
                  'uuid': l.uuid,
                  'name': l.name,
                  'grade': l.grade,
                  'language': l.language,
                  'pin_salt': l.pinSalt,
                  'pin_hash': l.pinHash,
                },
          ],
          'enrolments': [
            for (final e in await _db.select(_db.studentEnrolments).get())
              if (learnerUuid[e.studentId] != null)
                {
                  'uuid': e.uuid,
                  'learner_uuid': learnerUuid[e.studentId],
                  'class_uuid': e.classGroupUuid,
                  'year': e.academicYear,
                  'status': e.status,
                },
          ],
          'class_teachers': [
            for (final a in await _db.select(_db.classTeacherAssignments).get())
              if (teacherUuid[a.teacherId] != null)
                {
                  'uuid': a.uuid,
                  'teacher_uuid': teacherUuid[a.teacherId],
                  'class_uuid': a.classGroupUuid,
                },
          ],
          'revoked_devices': [
            for (final d in await _db.select(_db.revokedDevices).get())
              {
                'device_key': d.deviceKey,
                'name': d.name,
                'revoked_at': d.revokedAt,
              },
          ],
          'takeover': ?takeover,
        });
        return {
          'payload': payload,
          'sig': await signAdminRecords(admin.signingSeed!, payload),
        };
      });

  // ── Receiving ─────────────────────────────────────────────────────────

  Future<AdminRecordsStateRow?> _state() => (_db.select(
    _db.adminRecordsState,
  )..where((t) => t.id.equals(1))).getSingleOrNull();

  /// What this device holds from the Admin, or null.
  Future<AdminRecordsStateRow?> received() => _state();

  /// Checks and applies [bundle]. Null when taken; else why not.
  Future<AdminRecordsError?> apply(Object? bundle) async {
    if (bundle is! Map) return 'Not school records';
    final payload = bundle['payload'], sig = bundle['sig'];
    if (payload is! String || sig is! String) return 'Not school records';
    final Map<String, Object?> r;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, Object?>) return 'Not school records';
      r = decoded;
    } catch (_) {
      return 'Not school records';
    }
    final key = r['admin_public_key'], version = r['version'];
    final schoolId = r['school_id'];
    if (r['format'] != kAdminRecordsFormat ||
        key is! String ||
        version is! int ||
        schoolId is! String) {
      return 'Not school records';
    }
    if (!await verifyAdminRecords(key, payload, sig)) {
      return 'The records’ signature doesn’t check out';
    }
    final state = await _state();
    if (state != null && state.adminPublicKey != key) {
      return 'These records are from a different Admin';
    }
    if (state != null && version <= state.version) {
      return 'This device already has these records or newer';
    }
    if (await (_db.select(
          _db.adminIdentity,
        )..where((t) => t.id.equals(1))).getSingleOrNull() !=
        null) {
      return 'This device is the Admin’s';
    }
    final me = await _db.classSyncDao.identity();
    if (me.schoolId != null && me.schoolId != schoolId) {
      return 'This device belongs to ${me.schoolName ?? 'another school'}';
    }

    await _db.transaction(() async {
      if (me.schoolId == null) {
        await _db.classSyncDao.adoptSchool(
          schoolId: schoolId,
          schoolName: r['school_name'] as String? ?? '',
        );
      }

      // Teachers: added or updated by portable id.
      final teacherId = <String, int>{};
      for (final t in _maps(r['teachers'])) {
        final uuid = t['uuid'], name = t['name'];
        final salt = t['pin_salt'], hash = t['pin_hash'];
        if (uuid is! String ||
            name is! String ||
            salt is! String ||
            hash is! String) {
          continue;
        }
        final existing = await (_db.select(
          _db.teacherProfiles,
        )..where((x) => x.uuid.equals(uuid))).getSingleOrNull();
        if (existing == null) {
          teacherId[uuid] = await _db
              .into(_db.teacherProfiles)
              .insert(
                TeacherProfilesCompanion.insert(
                  name: name,
                  pinSalt: salt,
                  pinHash: hash,
                  createdAt: DateTime.now().toUtc().toIso8601String(),
                  uuid: Value(uuid),
                ),
              );
        } else {
          teacherId[uuid] = existing.id;
          await (_db.update(
            _db.teacherProfiles,
          )..where((x) => x.id.equals(existing.id))).write(
            TeacherProfilesCompanion(
              name: Value(name),
              pinSalt: Value(salt),
              pinHash: Value(hash),
            ),
          );
        }
      }

      // Classes and streams, with their class keys so either device can
      // share them.
      final classId = <String, int>{};
      for (final c in _maps(r['classes'])) {
        final uuid = c['uuid'], name = c['name'];
        if (uuid is! String || name is! String) continue;
        final stream = c['stream'] as String?;
        final classKey = c['class_key'] as String?;
        final existing = await _db.classGroupDao.findByUuid(uuid);
        if (existing == null) {
          classId[uuid] = await _db
              .into(_db.classGroups)
              .insert(
                ClassGroupsCompanion.insert(
                  className: name,
                  streamName: Value(stream),
                  groupUuid: Value(uuid),
                  schoolId: Value(schoolId),
                  classKey: Value(classKey),
                ),
              );
        } else if (existing.joined) {
          // Joined through the teacher: keep it, and keep its learners in it.
          classId[uuid] = existing.id;
        } else {
          classId[uuid] = existing.id;
          await (_db.update(
            _db.classGroups,
          )..where((x) => x.id.equals(existing.id))).write(
            ClassGroupsCompanion(
              className: Value(name),
              streamName: Value(stream),
              schoolId: Value(schoolId),
              classKey: existing.classKey == null
                  ? Value(classKey)
                  : const Value.absent(),
            ),
          );
        }
      }

      // Subjects.
      for (final s in _maps(r['subjects'])) {
        final id = s['id'], name = s['name'];
        if (id is! String || name is! String) continue;
        final style = subjectStyleFor(name);
        final values = CustomSubjectsCompanion(
          name: Value(name),
          icon: Value(s['icon'] as String? ?? style.icon),
          color: Value(s['color'] as String? ?? style.color),
          classGroupUuid: const Value(null),
        );
        final existing = await _db.customSubjectDao.bySubjectId(id);
        if (existing == null) {
          await _db
              .into(_db.customSubjects)
              .insert(
                values.copyWith(
                  subjectId: Value(id),
                  createdAt: Value(DateTime.now().toUtc().toIso8601String()),
                ),
              );
        } else {
          await (_db.update(
            _db.customSubjects,
          )..where((x) => x.id.equals(existing.id))).write(values);
        }
      }

      // Removed built-in subjects: replaced whole. Records from an older
      // build don't carry the list and leave it alone.
      final removed = r['removed_subjects'];
      if (removed is List) {
        await _db.delete(_db.removedSubjects).go();
        for (final id in removed.whereType<String>()) {
          if (!CurriculumService.bundledSubjectIds.contains(id)) continue;
          await _db
              .into(_db.removedSubjects)
              .insertOnConflictUpdate(
                RemovedSubjectsCompanion.insert(
                  subjectId: id,
                  removedAt: DateTime.now().toUtc().toIso8601String(),
                ),
              );
        }
      }

      // Assignments: replaced whole.
      await _db.delete(_db.teachingAssignments).go();
      for (final a in _maps(r['assignments'])) {
        final uuid = a['uuid'], t = a['teacher_uuid'], c = a['class_uuid'];
        final subject = a['subject_id'], year = a['year'];
        if (uuid is! String ||
            t is! String ||
            c is! String ||
            subject is! String ||
            year is! int ||
            teacherId[t] == null) {
          continue;
        }
        await _db
            .into(_db.teachingAssignments)
            .insert(
              TeachingAssignmentsCompanion.insert(
                uuid: uuid,
                teacherId: teacherId[t]!,
                classGroupUuid: c,
                subjectId: subject,
                academicYear: year,
                term: Value(a['term'] as int? ?? 0),
                createdAt: DateTime.now().toUtc().toIso8601String(),
              ),
            );
      }

      // Learners: added or updated by portable id.
      final learnerId = <String, int>{};
      for (final l in _maps(r['learners'])) {
        final uuid = l['uuid'], name = l['name'];
        if (uuid is! String || name is! String) continue;
        final values = StudentsCompanion(
          name: Value(name),
          grade: Value(l['grade'] as String?),
          pinSalt: Value(l['pin_salt'] as String?),
          pinHash: Value(l['pin_hash'] as String?),
        );
        final existing = await (_db.select(
          _db.students,
        )..where((x) => x.uuid.equals(uuid))).getSingleOrNull();
        if (existing == null) {
          learnerId[uuid] = await _db
              .into(_db.students)
              .insert(
                values.copyWith(
                  uuid: Value(uuid),
                  language: Value(l['language'] as String? ?? 'en'),
                ),
              );
        } else {
          learnerId[uuid] = existing.id;
          await (_db.update(
            _db.students,
          )..where((x) => x.id.equals(existing.id))).write(values);
        }
      }

      // Enrolments: replaced whole; each learner's class follows their
      // active one.
      await _db.delete(_db.studentEnrolments).go();
      final activeClass = <int, int?>{
        for (final id in learnerId.values) id: null,
      };
      for (final e in _maps(r['enrolments'])) {
        final uuid = e['uuid'], l = e['learner_uuid'], c = e['class_uuid'];
        final year = e['year'], status = e['status'];
        if (uuid is! String ||
            l is! String ||
            c is! String ||
            year is! int ||
            status is! String ||
            learnerId[l] == null) {
          continue;
        }
        await _db
            .into(_db.studentEnrolments)
            .insert(
              StudentEnrolmentsCompanion.insert(
                uuid: uuid,
                studentId: learnerId[l]!,
                classGroupUuid: c,
                academicYear: year,
                status: Value(status),
                createdAt: DateTime.now().toUtc().toIso8601String(),
              ),
            );
        if (status == 'active') activeClass[learnerId[l]!] = classId[c];
      }
      for (final e in activeClass.entries) {
        await _db.classGroupDao.assignLearner(e.key, e.value);
      }

      // Class Teachers: replaced whole. Records from an older build don't
      // carry them and leave them alone.
      final classTeachers = r['class_teachers'];
      if (classTeachers is List) {
        await _db.delete(_db.classTeacherAssignments).go();
        for (final a in _maps(classTeachers)) {
          final uuid = a['uuid'], t = a['teacher_uuid'], c = a['class_uuid'];
          if (uuid is! String ||
              t is! String ||
              c is! String ||
              teacherId[t] == null) {
            continue;
          }
          await _db
              .into(_db.classTeacherAssignments)
              .insert(
                ClassTeacherAssignmentsCompanion.insert(
                  uuid: uuid,
                  teacherId: teacherId[t]!,
                  classGroupUuid: c,
                  createdAt: DateTime.now().toUtc().toIso8601String(),
                ),
                mode: InsertMode.insertOrIgnore,
              );
        }
      }

      // Learners a Class Teacher registered here: in these records means
      // the Admin has them; otherwise they keep their enrolment until the
      // Admin takes them.
      final inRecords = {
        for (final e in await _db.select(_db.studentEnrolments).get()) e.uuid,
      };
      final now = DateTime.now().toUtc().toIso8601String();
      for (final reg in await (_db.select(
        _db.learnerRegistrations,
      )..where((t) => t.sentAt.isNull())).get()) {
        if (inRecords.contains(reg.enrolmentUuid)) {
          await (_db.update(_db.learnerRegistrations)
                ..where((t) => t.id.equals(reg.id)))
              .write(LearnerRegistrationsCompanion(sentAt: Value(now)));
          continue;
        }
        final group = await _db.classGroupDao.findByUuid(reg.classGroupUuid);
        if (group != null) {
          await ClassEnrolment(_db).enrol(
            studentId: reg.studentId,
            group: group,
            enrolmentUuid: reg.enrolmentUuid,
          );
        }
      }

      // What this device serves follows the new assignments.
      await TeachingScope(_db).pruneShares();

      // Devices the Admin revoked for the whole school. Added, never
      // removed: an older copy of the records can't un-revoke one.
      for (final d in _maps(r['revoked_devices'])) {
        final deviceKey = d['device_key'], at = d['revoked_at'];
        if (deviceKey is! String || at is! String) continue;
        final name = d['name'];
        await _db
            .into(_db.revokedDevices)
            .insert(
              RevokedDevicesCompanion.insert(
                deviceKey: deviceKey,
                name: Value(name is String ? name : ''),
                revokedAt: at,
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }

      final takeover = r['takeover'];
      await _db
          .into(_db.adminRecordsState)
          .insertOnConflictUpdate(
            AdminRecordsStateCompanion.insert(
              id: const Value(1),
              adminPublicKey: key,
              version: version,
              schoolId: schoolId,
              receivedAt: DateTime.now().toUtc().toIso8601String(),
              takeoverJson: Value(
                takeover is Map ? jsonEncode(takeover) : null,
              ),
            ),
          );
    });
    // Revoked devices lose every class this device serves them.
    await DeviceRegistry(_db).applySchoolRevocations();
    return null;
  }

  // ── Class Teachers' registrations ────────────────────────────────────

  /// Learners a Class Teacher registered on this device that the Admin's
  /// device hasn't taken yet — sent with the next request for records.
  Future<List<Map<String, Object?>>> pendingRegistrations() async {
    final out = <Map<String, Object?>>[];
    for (final reg in await (_db.select(
      _db.learnerRegistrations,
    )..where((t) => t.sentAt.isNull())).get()) {
      final learner = await (_db.select(
        _db.students,
      )..where((t) => t.id.equals(reg.studentId))).getSingleOrNull();
      final teacher = await (_db.select(
        _db.teacherProfiles,
      )..where((t) => t.id.equals(reg.teacherId))).getSingleOrNull();
      final enrolment = await (_db.select(
        _db.studentEnrolments,
      )..where((t) => t.uuid.equals(reg.enrolmentUuid))).getSingleOrNull();
      if (learner?.uuid == null || teacher?.uuid == null) continue;
      out.add({
        'learner_uuid': learner!.uuid,
        'name': learner.name,
        'class_uuid': reg.classGroupUuid,
        'enrolment_uuid': reg.enrolmentUuid,
        'year': enrolment?.academicYear ?? DateTime.now().year,
        'teacher_uuid': teacher!.uuid,
        'registered_at': reg.createdAt,
      });
    }
    return out;
  }

  /// The names of the teachers [registrations] say they come from, for the
  /// Admin's Accept prompt.
  Future<Map<String, int>> registrationsByTeacher(
    List<Map<String, Object?>> registrations,
  ) async {
    final out = <String, int>{};
    for (final r in registrations) {
      final t = r['teacher_uuid'];
      if (t is! String) continue;
      final teacher = await (_db.select(
        _db.teacherProfiles,
      )..where((x) => x.uuid.equals(t))).getSingleOrNull();
      final name = teacher?.name ?? 'Unknown teacher';
      out[name] = (out[name] ?? 0) + 1;
    }
    return out;
  }

  /// On the Admin's device: takes learners registered by Class Teachers —
  /// only into a class/stream the Admin gave that teacher. Existing learners
  /// keep their portable identity; an enrolment already received is not
  /// replayed, so an old registration cannot undo a later Admin decision.
  /// Returns how many were taken and refused.
  Future<({int taken, int refused})> takeRegistrations(
    List<Map<String, Object?>> registrations,
  ) async {
    if (await _admin() == null) {
      return (taken: 0, refused: registrations.length);
    }
    var taken = 0, refused = 0;
    final audit = AuditLogService(_db);
    for (final r in registrations.take(500)) {
      final learner = r['learner_uuid'], name = r['name'];
      final c = r['class_uuid'], e = r['enrolment_uuid'];
      final t = r['teacher_uuid'], year = r['year'];
      if (learner is! String ||
          learner.length > 64 ||
          name is! String ||
          name.trim().isEmpty ||
          name.length > 80 ||
          c is! String ||
          e is! String ||
          e.length > 64 ||
          t is! String ||
          year is! int) {
        refused++;
        continue;
      }
      final teacher = await (_db.select(
        _db.teacherProfiles,
      )..where((x) => x.uuid.equals(t))).getSingleOrNull();
      final group = await _db.classGroupDao.findByUuid(c);
      final allowed =
          teacher != null &&
          group != null &&
          !group.joined &&
          await ClassEnrolment(_db).mayEnrol(teacher.id, c);
      if (!allowed) {
        refused++;
        await audit.record(
          'device',
          'refused.registration',
          detail: '${teacher == null ? 'unknown teacher' : 'teacher:${teacher.id}'} $c',
        );
        continue;
      }
      final existing = await (_db.select(
        _db.students,
      )..where((x) => x.uuid.equals(learner))).getSingleOrNull();
      final knownEnrolment = await (_db.select(
        _db.studentEnrolments,
      )..where((x) => x.uuid.equals(e))).getSingleOrNull();
      if (knownEnrolment != null) {
        taken++;
        continue;
      }
      final now = DateTime.now().toUtc().toIso8601String();
      final id = await _db.transaction(() async {
        final id =
            existing?.id ??
            await _db.studentDao.createStudent(
          StudentsCompanion.insert(name: name.trim(), uuid: Value(learner)),
        );
        await ClassEnrolment(_db).enrol(
          studentId: id,
          group: group,
          enrolmentUuid: e,
          academicYear: year,
        );
        final registration = LearnerRegistrationsCompanion.insert(
                studentId: id,
                teacherId: teacher.id,
                classGroupUuid: c,
                enrolmentUuid: e,
                createdAt: r['registered_at'] is String
                    ? r['registered_at'] as String
                    : now,
                sentAt: Value(now),
              );
        await _db
            .into(_db.learnerRegistrations)
            .insert(
              registration,
              onConflict: DoUpdate(
                (_) => registration,
                target: [_db.learnerRegistrations.studentId],
              ),
            );
        return id;
      });
      taken++;
      await audit.record(
        'teacher:${teacher.id}',
        'learner.registered',
        detail: 'learner:$id $c',
      );
    }
    return (taken: taken, refused: refused);
  }

  /// Makes this device the Admin's, from the sealed details in the last
  /// records received. False when there are none or [passphrase] is wrong.
  Future<bool> takeOver(String passphrase) async {
    final state = await _state();
    final sealed = state?.takeoverJson;
    if (state == null || sealed == null) return false;
    final decoded = jsonDecode(sealed);
    if (decoded is! Map<String, Object?>) return false;
    final admin = await openAdminTakeover(
      passphrase: passphrase,
      sealed: decoded,
    );
    final seed = admin?['seed'], name = admin?['name'];
    final salt = admin?['pin_salt'], hash = admin?['pin_hash'];
    if (seed is! String ||
        name is! String ||
        salt is! String ||
        hash is! String ||
        await signingPublicKey(seed) != state.adminPublicKey) {
      return false;
    }
    await _db.transaction(() async {
      await _db
          .into(_db.adminIdentity)
          .insertOnConflictUpdate(
            AdminIdentityCompanion.insert(
              id: const Value(1),
              name: name,
              pinSalt: salt,
              pinHash: hash,
              pinPlain: const Value(null),
              recoverySalt: const Value(null),
              recoveryHash: const Value(null),
              createdAt: DateTime.now().toUtc().toIso8601String(),
              signingSeed: Value(seed),
              recordsVersion: Value(state.version),
            ),
          );
      await (_db.update(_db.adminRecordsState)..where((t) => t.id.equals(1)))
          .write(const AdminRecordsStateCompanion(takeoverJson: Value(null)));
    });
    return true;
  }

  /// The Admin's details for [sealAdminTakeover].
  Future<Map<String, Object?>?> takeoverDetails() async {
    final admin = await _admin();
    if (admin == null || admin.signingSeed == null) return null;
    return {
      'seed': admin.signingSeed,
      'name': admin.name,
      'pin_salt': admin.pinSalt,
      'pin_hash': admin.pinHash,
    };
  }

  static Iterable<Map<String, Object?>> _maps(Object? list) => [
    if (list is List)
      for (final m in list)
        if (m is Map<String, Object?>) m,
  ];
}
