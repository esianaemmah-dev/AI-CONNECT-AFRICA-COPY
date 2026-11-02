import 'dart:async';
import 'dart:convert';
import 'dart:io' show Socket;
import 'dart:isolate';

import 'package:drift/drift.dart' show Value;
import 'package:http/http.dart' as http;

import '../../curriculum/curriculum_provider.dart' show CurriculumService;
import '../../curriculum/subject_style.dart';
import '../../db/otic_database.dart';
import '../../services/assignments/class_assignments.dart';
import '../../services/assignments/learner_support.dart';
import 'class_crypto.dart';
import 'class_enrolment.dart';
import 'device_keys.dart';
import 'device_registry.dart';
import 'class_share_server.dart'
    show
        kAckPath,
        kChannelPath,
        kClassHeader,
        kCoTeacherJoinPath,
        kHandshakePath,
        kJoinApprovalTimeout,
        kJoinPath,
        kMacHeader,
        kFileChunkBytes,
        kFilePath,
        kMaxReportsPerDevice,
        kNonceHeader,
        kReportPath;
import '../../services/notes/note_pdf_store.dart';
import 'progress_report.dart';
import 'routing_envelope.dart';

/// [json] decoded as a `{publicKey: version}` floor map — see
/// `sync_state.signer_versions_json`. Malformed or absent decodes to empty,
/// which is the correct "nothing accepted from anyone yet" starting point.
Map<String, int> decodeSignerVersions(String? json) {
  if (json == null) return const {};
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return const {};
    return {
      for (final e in decoded.entries)
        if (e.value is num) e.key as String: (e.value as num).toInt(),
    };
  } catch (_) {
    return const {};
  }
}

/// One malformed or mismatched block, kept for a post-sync report rather
/// than only a running count.
class RejectedChunk {
  const RejectedChunk({required this.reason, this.routingKey});
  final String reason;
  final String? routingKey;
}

/// What one sync run actually did.
class SyncResult {
  const SyncResult({
    required this.subjectsChecked,
    required this.subjectsUpdated,
    required this.chunksInserted,
    required this.rejected,
    this.subjectsRemoved = 0,
    this.learnersReported = 0,
    this.pdfsFetched = 0,
    this.error,
  });

  /// Learners on this device whose progress the teacher received.
  final int learnersReported;

  /// Notes' original PDFs downloaded this run (only ones this device
  /// didn't have).
  final int pdfsFetched;

  final int subjectsChecked;
  final int subjectsUpdated;
  final int chunksInserted;
  final int subjectsRemoved;
  final List<RejectedChunk> rejected;

  /// Set only when the whole run failed before touching any subject.
  final String? error;

  bool get ok => error == null;

  static SyncResult failed(String error) => SyncResult(
    subjectsChecked: 0,
    subjectsUpdated: 0,
    chunksInserted: 0,
    rejected: const [],
    error: error,
  );
}

/// The subjects a teacher's handshake offers, checked and clipped: a
/// well-formed id that isn't a built-in subject's, a short name, an icon key
/// and a `#rrggbb` colour. Anything else is dropped.
List<({String id, String name, String icon, String color})> offeredSubjects(
  Object? catalog,
) {
  final idOk = RegExp(r'^[a-z0-9_]{1,60}$');
  final colorOk = RegExp(r'^#[0-9a-fA-F]{6}$');
  final out = <({String id, String name, String icon, String color})>[];
  if (catalog is! List) return out;
  for (final s in catalog.take(100)) {
    if (s is! Map) continue;
    final id = s['id'], name = s['name'], icon = s['icon'], color = s['color'];
    if (id is! String ||
        !idOk.hasMatch(id) ||
        CurriculumService.bundledSubjectIds.contains(id)) {
      continue;
    }
    if (name is! String || name.trim().isEmpty || name.length > 60) continue;
    final style = subjectStyleFor(name);
    out.add((
      id: id,
      name: name.trim(),
      icon: icon is String && icon.length <= 40 ? icon : style.icon,
      color: color is String && colorOk.hasMatch(color) ? color : style.color,
    ));
  }
  return out;
}

/// A sharing device seen on the network (or typed in).
typedef TeacherEndpoint = ({String address, int port});

/// Outcome of typing a teacher's join code.
class JoinResult {
  const JoinResult.joined(ClassGroup this.group, this.schoolName)
    : error = null;
  const JoinResult.failed(String this.error) : group = null, schoolName = null;

  final ClassGroup? group;
  final String? schoolName;
  final String? error;
  bool get ok => group != null;
}

/// Access a classmate granted this device: their address, the class, and
/// the session token that lets this device pull from them. Held in memory
/// only — it ends when either device stops.
class ClassmateSession {
  const ClassmateSession({
    required this.endpoint,
    required this.group,
    required this.token,
  });
  final TeacherEndpoint endpoint;
  final ClassGroup group;
  final String token;
}

/// Outcome of typing a classmate's code.
class ClassmateJoinResult {
  const ClassmateJoinResult.joined(ClassmateSession this.session)
    : error = null;
  const ClassmateJoinResult.failed(String this.error) : session = null;
  final ClassmateSession? session;
  final String? error;
  bool get ok => session != null;
}

/// Outcome of typing a co-teacher invite code.
class CoTeacherJoinResult {
  const CoTeacherJoinResult.joined() : error = null, ok = true;
  const CoTeacherJoinResult.failed(String this.error) : ok = false;
  final String? error;
  final bool ok;
}

/// A student device's side of class sync: joining a class with the
/// teacher's code, pulling that class's notes from the teacher, and pulling
/// them from a classmate who is passing them on.
///
/// Each subject is replaced as a whole, in one transaction, and only when
/// every chunk checks out — a teacher's edits and removals arrive exactly,
/// and a bad reply never leaves half a subject behind. A failing subject
/// never stops the next one.
///
/// Every subject comes with the teacher's signed manifest (digest +
/// version). From a classmate, a subject is taken only if that signature
/// checks against the teacher key pinned at join and its version is newer
/// than this device's — a classmate can pass notes on, but can't edit,
/// invent, remove or roll back any of them.
class SelectiveSyncManager {
  SelectiveSyncManager(
    this._db, {
    http.Client? client,
    this.joinRounds = kJoinKdfRounds,
    this.approvalTimeout = kJoinApprovalTimeout,
    NotePdfStore? pdfStore,
  }) : _client = client ?? http.Client(),
       pdfStore = pdfStore ?? NotePdfStore(_db);

  final OticDatabase _db;
  late final DeviceRegistry _devices = DeviceRegistry(_db);
  final http.Client _client;

  /// Where received notes' original PDFs are kept.
  final NotePdfStore pdfStore;

  /// A note's PDF can be tens of MB over a phone hotspot.
  static const _fileTimeout = Duration(minutes: 3);

  /// PBKDF2 rounds for join codes — lowered only in tests.
  final int joinRounds;

  /// How long a join waits for the sharer's Accept.
  final Duration approvalTimeout;

  static const _timeout = Duration(seconds: 20);

  /// How long a sync waits for an address to accept a connection before
  /// skipping it. A device on the same Wi-Fi/hotspot answers in
  /// milliseconds; without this, every stale address (a remembered typed
  /// one, a device that stopped sharing) cost the full [_timeout] — twice,
  /// with the retry pass.
  static const kReachTimeout = Duration(seconds: 2);

  /// Subjects fetched at once. Each reply is still verified and written one
  /// subject at a time, in order.
  static const _parallelFetches = 4;

  /// [candidates] that accept a TCP connection, tried all at once.
  static Future<List<TeacherEndpoint>> reachable(
    List<TeacherEndpoint> candidates, {
    Duration timeout = kReachTimeout,
  }) async {
    final up = await Future.wait([
      for (final e in candidates)
        Socket.connect(e.address, e.port, timeout: timeout).then(
          (s) {
            s.destroy();
            return true;
          },
          onError: (_) => false),
    ]);
    return [
      for (var i = 0; i < candidates.length; i++)
        if (up[i]) candidates[i],
    ];
  }

  // ── Join ────────────────────────────────────────────────────────────────

  /// Sends a join proof for [code] to each endpoint in turn and returns the
  /// first opened bundle. The code never leaves this device: only a proof
  /// derived from it does. Waits while the sharer decides.
  Future<Map<String, Object?>?> _requestJoin(
    List<TeacherEndpoint> endpoints,
    String code,
    String name, {
    String? learnerUuid,
  }) async {
    final salt = newNonce();
    final secret = await joinSecret(code, salt, rounds: joinRounds);
    final proof = await joinProof(secret, salt);
    final keys = await _devices.myKeys();
    for (final t in await reachable(endpoints)) {
      try {
        final response = await _client
            .post(
              Uri.parse('http://${t.address}:${t.port}/$kJoinPath'),
              headers: const {'content-type': 'application/json'},
              body: jsonEncode({
                'nonce': salt,
                'proof': proof,
                'name': name,
                if (learnerUuid != null) 'learner_uuid': learnerUuid,
                ...keys,
              }),
            )
            .timeout(approvalTimeout + _timeout);
        if (response.statusCode != 200) continue;
        final opened = await openJoinBundle(
          secret,
          salt,
          (jsonDecode(response.body) as Map)['bundle'],
        );
        if (opened is Map) return Map<String, Object?>.from(opened);
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// Tries [typedCode] against each teacher on the network, as [name].
  Future<JoinResult> joinClass({
    required List<TeacherEndpoint> teachers,
    required String typedCode,
    String name = '',
    int? studentId,
    Future<bool> Function(String className, String schoolName, String teacherName)? confirmClass,
  }) async {
    final code = normalizeJoinCode(typedCode);
    if (code == null) {
      return const JoinResult.failed(
        'That isn’t a join code — it has 8 letters and numbers, like K7M4-P9QX.',
      );
    }
    if (teachers.isEmpty) {
      return const JoinResult.failed(
        'No teacher is sharing a class on this Wi-Fi right now.',
      );
    }
    final enrolments = ClassEnrolment(_db);
    final learner = studentId == null
        ? null
        : await _db.studentDao.getStudentById(studentId);
    if (studentId != null && learner == null) {
      return const JoinResult.failed('Choose a learner first.');
    }
    final uuid = studentId == null
        ? null
        : await enrolments.learnerUuid(studentId);
    final bundle = await _requestJoin(
      teachers,
      code,
      learner?.name ?? name,
      learnerUuid: uuid,
    );
    if (bundle == null) {
      return const JoinResult.failed(
        'You weren’t let in. Check the code, that it hasn’t expired, and that '
        'your teacher tapped Accept.',
      );
    }
    if (bundle['learner_uuid'] != null && bundle['learner_uuid'] != uuid) {
      return const JoinResult.failed('The approval is for another learner.');
    }
    if (confirmClass != null && !await confirmClass(
      bundle['class_name'] is String ? bundle['class_name'] as String : '',
      bundle['school_name'] is String ? bundle['school_name'] as String : '',
      bundle['teacher_name'] is String ? bundle['teacher_name'] as String : 'Your teacher',
    )) return const JoinResult.failed('Joining cancelled.');
    final result = await _acceptBundle(bundle);
    if (result.ok && studentId != null) {
      await enrolments.enrol(
        studentId: studentId,
        group: result.group!,
        enrolmentUuid: bundle['enrolment_uuid'] is String
            ? bundle['enrolment_uuid'] as String
            : null,
        academicYear: bundle['academic_year'] is int
            ? bundle['academic_year'] as int
            : null,
      );
      if (bundle['shared_subjects'] case final List subjects) {
        await _db.classSyncDao.registerClassSubjects(
          result.group!.groupUuid!,
          subjects.whereType<String>().where(
            (id) => RegExp(r'^[a-z0-9_]{1,60}$').hasMatch(id),
          ),
          studentId: studentId,
        );
      }
    }
    return result;
  }

  Future<JoinResult> _acceptBundle(Map<String, Object?> b) async {
    final schoolId = b['school_id'], schoolName = b['school_name'];
    final uuid = b['class_group_uuid'], className = b['class_name'];
    final classKey = b['class_key'], teacherKey = b['teacher_public_key'];
    final stream = b['stream_name'];
    if (schoolId is! String ||
        uuid is! String ||
        className is! String ||
        classKey is! String ||
        teacherKey is! String) {
      return const JoinResult.failed(
        'The teacher’s device sent incomplete class details.',
      );
    }
    final school = schoolName is String ? schoolName : '';

    final me = await _db.classSyncDao.identity();
    // Any device may teach and join classes; just not its own.
    final local = await _db.classGroupDao.findByUuid(uuid);
    if (local != null &&
        !local.joined &&
        await _db.classSyncDao.hostsClass(uuid)) {
      return const JoinResult.failed('This class was created on this device.');
    }
    if (me.schoolId != null && me.schoolId != schoolId) {
      return JoinResult.failed(
        'This device belongs to ${me.schoolName ?? 'another school'}. '
        'That class is at ${school.isEmpty ? 'a different school' : school}, so it can’t be joined here.',
      );
    }
    final group = await _db.classSyncDao.upsertJoinedClass(
      groupUuid: uuid,
      className: className,
      streamName: stream is String && stream.isNotEmpty ? stream : null,
      schoolId: schoolId,
      classKey: classKey,
      teacherPublicKey: teacherKey,
    );
    if (group == null) {
      return const JoinResult.failed(
        'This device is the teacher’s own device for that class.',
      );
    }
    await _db.classSyncDao.adoptSchool(schoolId: schoolId, schoolName: school);
    await _db.classSyncDao.becomeStudentDevice();
    return JoinResult.joined(group, school);
  }

  /// Tries a classmate's [typedCode]. Only works for a class this device
  /// already joined through the teacher — a classmate can pass the
  /// teacher's notes on, never let someone into the class.
  Future<ClassmateJoinResult> joinClassmate({
    required List<TeacherEndpoint> classmates,
    required String typedCode,
    String name = '',
  }) async {
    final code = normalizeJoinCode(typedCode);
    if (code == null) {
      return const ClassmateJoinResult.failed(
        'That isn’t a code — it has 8 letters and numbers, like K7M4-P9QX.',
      );
    }
    if (classmates.isEmpty) {
      return const ClassmateJoinResult.failed(
        'No classmate is sharing on this Wi-Fi right now. Type their '
        'address if they are.',
      );
    }
    final salt = newNonce();
    final secret = await joinSecret(code, salt, rounds: joinRounds);
    final proof = await joinProof(secret, salt);
    for (final c in await reachable(classmates)) {
      final Map<String, Object?> b;
      try {
        final response = await _client
            .post(
              Uri.parse('http://${c.address}:${c.port}/$kJoinPath'),
              headers: const {'content-type': 'application/json'},
              body: jsonEncode({'nonce': salt, 'proof': proof, 'name': name}),
            )
            .timeout(approvalTimeout + _timeout);
        if (response.statusCode != 200) continue;
        final opened = await openJoinBundle(
          secret,
          salt,
          (jsonDecode(response.body) as Map)['bundle'],
        );
        if (opened is! Map) continue;
        b = Map<String, Object?>.from(opened);
      } catch (_) {
        continue;
      }
      final uuid = b['class_group_uuid'], token = b['session_token'];
      if (uuid is! String || token is! String) {
        return const ClassmateJoinResult.failed(
          'Your classmate’s device sent incomplete details.',
        );
      }
      final group = await _db.classSyncDao.joinedByUuid(uuid);
      if (group == null || group.schoolId != b['school_id']) {
        return const ClassmateJoinResult.failed(
          'That classmate is sharing a class this device hasn’t joined. Join '
          'your class with your teacher’s code first.',
        );
      }
      return ClassmateJoinResult.joined(
        ClassmateSession(endpoint: c, group: group, token: token),
      );
    }
    return const ClassmateJoinResult.failed(
      'You weren’t let in. Check the code, that it hasn’t expired, and that '
      'your classmate tapped Accept.',
    );
  }

  // ── Join as a co-teacher ────────────────────────────────────────────────

  /// Tries a co-teacher invite [typedCode] against each candidate root
  /// device on the network, as [name]. The class is recorded as
  /// [ownerTeacherId]'s (the teacher signed in here).
  Future<CoTeacherJoinResult> joinAsCoTeacher({
    required List<TeacherEndpoint> roots,
    required String typedCode,
    String name = '',
    int? ownerTeacherId,
  }) async {
    final code = normalizeJoinCode(typedCode);
    if (code == null) {
      return const CoTeacherJoinResult.failed(
        'That isn’t an invite code — it has 8 letters and numbers, like '
        'K7M4-P9QX.',
      );
    }
    if (roots.isEmpty) {
      return const CoTeacherJoinResult.failed(
        'No teacher device is sharing on this Wi-Fi right now.',
      );
    }
    final me = await _db.classSyncDao.identity();
    final myPublicKey = await signingPublicKey(me.signingSeed);
    final salt = newNonce();
    final secret = await joinSecret(code, salt, rounds: joinRounds);
    final proof = await coTeacherJoinProof(secret, salt, myPublicKey);

    for (final t in await reachable(roots)) {
      final Map<String, Object?> b;
      try {
        final response = await _client
            .post(
              Uri.parse('http://${t.address}:${t.port}/$kCoTeacherJoinPath'),
              headers: const {'content-type': 'application/json'},
              body: jsonEncode({
                'nonce': salt,
                'proof': proof,
                'name': name,
                'device_public_key': myPublicKey,
              }),
            )
            .timeout(approvalTimeout + _timeout);
        if (response.statusCode != 200) continue;
        final opened = await openJoinBundle(
          secret,
          salt,
          (jsonDecode(response.body) as Map)['bundle'],
        );
        if (opened is! Map) continue;
        b = Map<String, Object?>.from(opened);
      } catch (_) {
        continue;
      }

      final schoolId = b['school_id'], schoolName = b['school_name'];
      final uuid = b['class_group_uuid'], className = b['class_name'];
      final classKey = b['class_key'], rootKey = b['root_public_key'];
      final stream = b['stream_name'];
      if (schoolId is! String ||
          uuid is! String ||
          className is! String ||
          classKey is! String ||
          rootKey is! String) {
        return const CoTeacherJoinResult.failed(
          'The teacher’s device sent incomplete details.',
        );
      }
      final roster = ClassRoster.fromJson(
        b['roster'],
        schoolId: schoolId,
        classUuid: uuid,
      );
      if (roster == null || !await verifyRoster(roster, rootKey)) {
        return const CoTeacherJoinResult.failed(
          'The teacher’s device sent a roster that doesn’t check out — try '
          'again, and make sure both devices are up to date.',
        );
      }
      // Only ever trust what the root's own signature grants this device —
      // never the plain-text echo of subject ids alongside it.
      final mine = [
        for (final e in roster.entries)
          if (e.publicKey == myPublicKey) ...e.subjectIds,
      ];
      if (mine.isEmpty) {
        return const CoTeacherJoinResult.failed(
          'The teacher’s device didn’t confirm this device’s subjects in '
          'its signed roster.',
        );
      }
      final local = await _db.classGroupDao.findByUuid(uuid);
      if (local != null && !local.joined) {
        return const CoTeacherJoinResult.failed(
          'This class was created on this device.',
        );
      }
      final held = await _db.coTeacherDao.delegatedByUuid(uuid);
      if (held != null &&
          held.ownerTeacherId != null &&
          held.ownerTeacherId != ownerTeacherId) {
        return const CoTeacherJoinResult.failed(
          'Another teacher on this device co-teaches this class.',
        );
      }
      if (me.schoolId != null && me.schoolId != schoolId) {
        return CoTeacherJoinResult.failed(
          'This device belongs to ${me.schoolName ?? 'another school'}. '
          'That class is at ${schoolName is String && schoolName.isNotEmpty ? schoolName : 'a different school'}, so it can’t be co-taught here.',
        );
      }
      if (me.schoolId == null) {
        await _db.classSyncDao.adoptSchool(
          schoolId: schoolId,
          schoolName: schoolName is String ? schoolName : '',
        );
      }
      await _db.classSyncDao.claimTeacherRole();
      await _db.coTeacherDao.upsertDelegatedClass(
        classUuid: uuid,
        className: className,
        streamName: stream is String && stream.isNotEmpty ? stream : null,
        schoolId: schoolId,
        classKey: classKey,
        rootPublicKey: rootKey,
        subjectIds: mine,
        roster: roster,
        ownerTeacherId: ownerTeacherId,
      );
      return const CoTeacherJoinResult.joined();
    }
    return const CoTeacherJoinResult.failed(
      'You weren’t let in. Check the code, that it hasn’t expired, and that '
      'the teacher tapped Accept.',
    );
  }

  /// Co-teacher device: asks root (any of [roots]) for [delegated]'s current
  /// roster and stores this device's allocation from it — the only way a
  /// co-teacher learns it was given another subject, lost one, or was
  /// revoked outright. True when a root answered with a valid roster.
  /// Students are never at risk while this hasn't run: they verify every
  /// manifest against their own copy of the roster regardless of what this
  /// device still believes it may serve.
  Future<bool> refreshDelegatedClass({
    required List<TeacherEndpoint> roots,
    required CoTeachingClass delegated,
  }) async {
    final me = await _db.classSyncDao.identity();
    final myKey = await signingPublicKey(me.signingSeed);
    for (final root in await reachable(roots)) {
      try {
        final hello = await _signedCall(
          root,
          kHandshakePath,
          {'school_id': delegated.schoolId},
          uuid: delegated.classGroupUuid,
          macKey: delegated.classKey,
          open: (nonce, sealed) => openReply(
            classKey: delegated.classKey,
            teacherPublicKey: delegated.rootPublicKey,
            requestNonce: nonce,
            sealed: sealed,
          ),
        );
        final roster = ClassRoster.fromJson(
          hello['roster'],
          schoolId: delegated.schoolId,
          classUuid: delegated.classGroupUuid,
        );
        if (roster == null ||
            roster.version < delegated.rosterVersion ||
            !await verifyRoster(roster, delegated.rootPublicKey)) {
          continue;
        }
        await _db.coTeacherDao.updateCachedRoster(
          delegated.classGroupUuid,
          roster,
          myKey,
        );
        return true;
      } catch (_) {
        continue;
      }
    }
    return false;
  }

  // ── Sync with the teacher ───────────────────────────────────────────────

  /// Every discovered [candidates] that answer for [group], merged. Unlike
  /// [syncClass], never stops at the first success: with co-teachers, a
  /// class's subjects can come from several devices at once — root's own
  /// endpoint and each co-teacher's — and each only ever carries its own
  /// allocated subjects, so a full sync needs all of them, not just
  /// whichever answers first.
  Future<SyncResult> syncClassEverywhere({
    required List<TeacherEndpoint> candidates,
    required ClassGroup group,
  }) async {
    if (candidates.isEmpty) {
      return SyncResult.failed(
        'No teacher is sharing on this Wi-Fi right now.',
      );
    }
    final live = await reachable(candidates);
    if (live.isEmpty) {
      // Same wording a failed sync already shows students.
      return SyncResult.failed(
        'Could not sync with ${candidates.first.address}. Make sure it is still sharing '
        '${group.className}${group.streamName == null ? '' : ' ${group.streamName}'}.',
      );
    }
    var current = group;
    final results = <TeacherEndpoint, SyncResult>{};
    for (final endpoint in live) {
      results[endpoint] = await syncClass(teacher: endpoint, group: current);
      current = await _refreshedGroup(current);
    }
    // One retry pass: an endpoint that failed here — e.g. a co-teacher this
    // device had no cached roster to verify against yet — may succeed now,
    // if another endpoint's reply this same round supplied a fresher one
    // (see the bootstrap note on [syncClass]).
    for (final endpoint in live) {
      if (results[endpoint]!.ok) continue;
      results[endpoint] = await syncClass(teacher: endpoint, group: current);
      current = await _refreshedGroup(current);
    }
    return _mergeResults(results.values);
  }

  Future<ClassGroup> _refreshedGroup(ClassGroup group) async =>
      await _db.classSyncDao.joinedByUuid(group.groupUuid!) ?? group;

  SyncResult _mergeResults(Iterable<SyncResult> results) {
    final ok = results.where((r) => r.ok).toList();
    if (ok.isEmpty) return results.first;
    return SyncResult(
      subjectsChecked: ok.fold(0, (a, r) => a + r.subjectsChecked),
      subjectsUpdated: ok.fold(0, (a, r) => a + r.subjectsUpdated),
      chunksInserted: ok.fold(0, (a, r) => a + r.chunksInserted),
      subjectsRemoved: ok.fold(0, (a, r) => a + r.subjectsRemoved),
      learnersReported: ok.fold(0, (a, r) => a + r.learnersReported),
      pdfsFetched: ok.fold(0, (a, r) => a + r.pdfsFetched),
      rejected: [
        for (final r in results)
          if (r.ok)
            ...r.rejected
          else
            RejectedChunk(reason: r.error ?? 'a teacher device could not be reached',
            ),
      ],
    );
  }

  /// Pulls every subject [teacher] signs for [group] — root's own device,
  /// or one of the class's co-teacher devices; [syncClassEverywhere] calls
  /// this once per discovered endpoint.
  ///
  /// Which key actually answered isn't known in advance: [teacher] might be
  /// root or any co-teacher, so the reply is opened against every key this
  /// device currently trusts for the class (root's pinned key, plus every
  /// key in its cached roster) until one verifies. **Bootstrapping**: the
  /// very first contact with a class is always root's own join bundle
  /// (only root admits students), and that bundle already carries the
  /// class's current roster if one exists — so even a student who joins
  /// after a co-teacher does has a cached roster before ever syncing. A
  /// student who joined *before* a co-teacher existed only gets the
  /// updated roster from a reply that includes one — see
  /// [syncClassEverywhere]'s retry pass for what covers a co-teacher's
  /// endpoint being tried before root's in the same round.
  Future<SyncResult> syncClass({
    required TeacherEndpoint teacher,
    required ClassGroup group,
    bool rekeyed = false,
  }) async {
    final uuid = group.groupUuid, classKey = group.classKey;
    final rootKey = group.teacherPublicKey, schoolId = group.schoolId;
    if (!group.joined ||
        uuid == null ||
        classKey == null ||
        rootKey == null ||
        schoolId == null) {
      return SyncResult.failed('Join this class with your teacher’s code first.',
      );
    }
    var roster = _decodeCachedRoster(
      group,
      schoolId: schoolId,
      classUuid: uuid,
    );
    final candidateKeys = <String>{
      rootKey,
      ...?roster?.entries.map((e) => e.publicKey),
    }.toList();

    String? signer;
    Future<Map<String, Object?>> call(
      String path,
      Map<String, Object?> body, {
      Future<Map<String, Object?>> Function(String nonce)? extra,
      Duration? timeout,
    }) => _signedCall(
      teacher,
      path,
      body,
      uuid: uuid,
      macKey: classKey,
      extra: extra,
      timeout: timeout,
      open: (nonce, sealed) async {
        SyncTrustError? lastError;
        for (final key in candidateKeys) {
          try {
            final opened = await openReply(
              classKey: classKey,
              teacherPublicKey: key,
              requestNonce: nonce,
              sealed: sealed,
            );
            signer = key;
            return opened;
          } on SyncTrustError catch (e) {
            lastError = e;
          }
        }
        throw lastError ??
            const SyncTrustError('reply is not signed by a key this class trusts',
            );
      },
    );

    final List<ChannelManifest> manifests;
    try {
      final hello = await call(kHandshakePath, {
        'school_id': schoolId,
        'box_key': (await _devices.myKeys())['box_key'],
      });
      // A device was revoked and the class key replaced: the teacher sent
      // this device the new one, sealed to it. Take it and sync again.
      if (hello['rekey'] != null && signer == rootKey && !rekeyed) {
        final fresh = await _takeNewClassKey(group, hello['rekey']);
        if (fresh == null) {
          throw const SyncTrustError('the new class key did not open');
        }
        return syncClass(teacher: teacher, group: fresh, rekeyed: true);
      }
      // Host failover: a root-signed reply from a device a standby has
      // since taken over from carries an older epoch. Refuse it before it
      // can drop or replace anything (it holds the same key, so its
      // signature alone proves nothing). A co-teacher's reply carries none.
      if (signer == rootKey) {
        final epoch = hello['host_epoch'] is int ? hello['host_epoch'] as int : 0;
        if (epoch < (group.hostEpoch ?? 0)) {
          throw const SyncTrustError(
            'it was replaced by a newer teacher device for this class',
          );
        }
        if (epoch > (group.hostEpoch ?? 0)) {
          await _db.classSyncDao.raiseHostEpoch(uuid, epoch);
        }
      }
      manifests = await _manifests(hello, schoolId: schoolId, classUuid: uuid);
      roster = await _refreshRosterIfNewer(
        hello['roster'],
        current: roster,
        rootKey: rootKey,
        uuid: uuid,
        schoolId: schoolId,
      );
      // Root's own subjects — only ever taken from root's own reply. A
      // co-teacher's reply never carries a catalog (see
      // ClassShareServer._handshake).
      if (hello['catalog'] != null) {
        await _db.classSyncDao.replaceReceivedSubjects(
          uuid,
          offeredSubjects(hello['catalog']),
        );
      }
    } catch (e) {
      return SyncResult.failed(
        e is SyncTrustError
            ? 'That device isn’t your class’s teacher: ${e.message}.'
            : 'Could not sync with ${teacher.address}. Make sure it is still sharing '
                  '${group.className}${group.streamName == null ? '' : ' ${group.streamName}'}.',
      );
    }

    final answeredBy = signer ?? rootKey;
    // A manifest's subject must actually be this device's to sign, by the
    // roster — one answering for a subject the roster doesn't grant it is
    // rejected here even though its own transport signature checked out.
    final trusted = [
      for (final m in manifests)
        if ((roster?.signerFor(m.subjectId, rootKey) ?? rootKey) == answeredBy)
          m,
    ];

    // This signer's own list is authoritative for whatever it signs —
    // anything of its own not on it was unshared, or reassigned away.
    // Scoped so it can never touch another signer's channels: root
    // syncing can't drop a co-teacher's, and vice versa.
    final removed = await _db.classSyncDao.dropChannelsForSigner(
      uuid,
      answeredBy,
      {for (final m in trusted) m.subjectId},
      treatNullSignerAsThis: answeredBy == rootKey,
    );
    final run = await _pullChannels(
      trusted,
      group: group,
      signerFor: (_) => answeredBy,
      call: (path, body) => call(path, body),
      fromTeacher: true,
    );

    // Then tell root how this device's learners in the class are doing —
    // never a co-teacher, whose server refuses reports outright.
    // Best-effort: a failed report never fails the sync.
    var reported = 0;
    if (answeredBy == rootKey) {
      try {
        final deviceKey = await reportDeviceKey(_db);
        final reports = await buildProgressReports(
          _db,
          group,
          deviceKey: deviceKey,
        );
        if (reports.isNotEmpty) {
          final ack = await call(
            kReportPath,
            {'school_id': schoolId},
            extra: (nonce) async => {
              'report': await sealReport(
                classKey: classKey,
                requestNonce: nonce,
                json: [for (final r in reports) r.toJson()],
              ),
            },
          );
          reported = ack['saved'] is int ? ack['saved'] as int : 0;
          // The teacher holds these reports as they are now.
          if (reported == reports.length) await markReportsSent(_db, reports);
          // The teacher's grades for this device's learners' answers.
          if (ack['grades'] case final List grades) {
            await ClassAssignments(_db).applyGrades([
              for (final g in grades.take(200)) ?GradePayload.fromJson(g),
            ]);
          }
          // Answers the teacher's device now holds.
          if (ack['received'] case final List received) {
            await ClassAssignments(_db).markReceived([
              for (final u in received.take(500))
                if (u is String) u,
            ]);
          }
          // The teacher's extra help for this device's learners.
          if (ack['support'] case final List items) {
            await LearnerSupportService(_db).receive(
              group: group,
              deviceKey: deviceKey,
              items: [
                for (final i in items.take(
                  kMaxSupportPerLearner * kMaxReportsPerDevice,
                ))
                  ?SupportPayload.fromJson(i),
              ],
            );
          }
        }
      } catch (_) {}
      // Which version of each subject this device now holds, so the
      // teacher sees how many devices have a note. Best-effort: an older
      // teacher build answers 404.
      try {
        await call(kAckPath, {
          'school_id': schoolId,
          'held': await _db.classSyncDao.heldVersions(uuid, rootKey),
        });
      } catch (_) {}
    }

    // Last: a long download must never hold up the progress report.
    final pdfs = await _fetchMissingPdfs(
      uuid,
      schoolId,
      subjects: {for (final m in trusted) m.subjectId},
      call: (path, body) => call(path, body, timeout: _fileTimeout),
    );

    return SyncResult(
      subjectsChecked: trusted.length,
      subjectsUpdated: run.updated,
      chunksInserted: run.inserted,
      subjectsRemoved: removed,
      rejected: run.rejected,
      learnersReported: reported,
      pdfsFetched: pdfs,
    );
  }

  ClassRoster? _decodeCachedRoster(
    ClassGroup group, {
    required String schoolId,
    required String classUuid,
  }) {
    if (group.rosterJson == null) return null;
    try {
      return ClassRoster.fromJson(
        jsonDecode(group.rosterJson!),
        schoolId: schoolId,
        classUuid: classUuid,
      );
    } catch (_) {
      return null;
    }
  }

  /// If [rawRoster] parses, is newer than [current], and is genuinely
  /// signed by [rootKey], caches it and drops any channel it revokes trust
  /// from — before pulling anything else this round, so a revoked
  /// co-teacher's content never lingers past the sync that learns of it.
  /// Returns the roster now in effect (the fresh one, or [current]
  /// unchanged).
  Future<ClassRoster?> _refreshRosterIfNewer(
    Object? rawRoster, {
    required ClassRoster? current,
    required String rootKey,
    required String uuid,
    required String schoolId,
  }) async {
    if (rawRoster == null) return current;
    final fresh = ClassRoster.fromJson(
      rawRoster,
      schoolId: schoolId,
      classUuid: uuid,
    );
    if (fresh == null || fresh.version <= (current?.version ?? -1)) {
      return current;
    }
    if (!await verifyRoster(fresh, rootKey)) return current;
    await _db.classSyncDao.cacheRoster(uuid, fresh);
    await _db.classSyncDao.applyRosterRevocations(uuid, fresh, rootKey);
    return fresh;
  }

  // ── Sync with a classmate ───────────────────────────────────────────────

  /// Pulls from a classmate every subject whose signer-scoped version is
  /// newer than this device's. Never drops anything: a classmate's list
  /// says nothing about what any signer still shares — only a sync
  /// straight with the signer itself does that (see [syncClass]).
  Future<SyncResult> syncFromClassmate(ClassmateSession session) async {
    final group = session.group;
    final uuid = group.groupUuid!, classKey = group.classKey!;
    final schoolId = group.schoolId!, rootKey = group.teacherPublicKey!;
    Future<Map<String, Object?>> call(
      String path,
      Map<String, Object?> body, {
      Duration? timeout,
    }) => _signedCall(
          session.endpoint,
          path,
          body,
          uuid: uuid,
          macKey: session.token,
          timeout: timeout,
          open: (nonce, sealed) => openRelayReply(
            classKey: classKey,
            requestNonce: nonce,
            sealed: sealed,
          ),
        );

    var roster = _decodeCachedRoster(group, schoolId: schoolId, classUuid: uuid,
    );
    final List<ChannelManifest> manifests;
    try {
      final hello = await call(kHandshakePath, {'school_id': schoolId});
      manifests = await _manifests(hello, schoolId: schoolId, classUuid: uuid);
      roster = await _refreshRosterIfNewer(
        hello['roster'],
        current: roster,
        rootKey: rootKey,
        uuid: uuid,
        schoolId: schoolId,
      );
    } catch (e) {
      return SyncResult.failed(
        'Could not get notes from your classmate. Make sure they are still '
        'sharing, then try again.',
      );
    }
    // A relayed batch can mix subjects from several original signers (root
    // and any co-teacher this classmate itself synced) — resolved per
    // manifest from the roster, not assumed constant for the whole call.
    final resolvedRoster = roster;
    final run = await _pullChannels(
      manifests,
      group: group,
      signerFor: (m) => resolvedRoster?.signerFor(m.subjectId, rootKey) ?? rootKey,
      call: (path, body) => call(path, body),
      fromTeacher: false,
    );
    final pdfs = await _fetchMissingPdfs(
      uuid,
      schoolId,
      subjects: {for (final m in manifests) m.subjectId},
      call: (path, body) => call(path, body, timeout: _fileTimeout),
    );
    return SyncResult(
      subjectsChecked: manifests.length,
      subjectsUpdated: run.updated,
      chunksInserted: run.inserted,
      rejected: run.rejected,
      pdfsFetched: pdfs,
    );
  }

  // ── Shared pulling ──────────────────────────────────────────────────────

  Future<List<ChannelManifest>> _manifests(
    Map<String, Object?> hello, {
    required String schoolId,
    required String classUuid,
  }) async {
    final out = <ChannelManifest>[];
    for (final s in (hello['subjects'] as List? ?? const [])) {
      final m = ChannelManifest.fromJson(
        s,
        schoolId: schoolId,
        classUuid: classUuid,
      );
      if (m != null) out.add(m);
    }
    return out;
  }

  /// [signerFor] resolves, per manifest, the key that's allowed to sign its
  /// subject: a constant (whichever device this call is talking to
  /// directly) for a direct teacher/co-teacher sync, or per-subject from
  /// the class roster for a classmate relay, whose one batch can mix
  /// several original signers.
  Future<({int updated, int inserted, List<RejectedChunk> rejected})>
  _pullChannels(
    List<ChannelManifest> manifests, {
    required ClassGroup group,
    required String Function(ChannelManifest m) signerFor,
    required Future<Map<String, Object?>> Function(
      String path,
      Map<String, Object?> body,
    )
    call,
    required bool fromTeacher,
  }) async {
    final uuid = group.groupUuid!;
    final dao = _db.classSyncDao;
    var updated = 0;
    var inserted = 0;
    final rejected = <RejectedChunk>[];

    // 1. Which subjects need pulling — signature and version checks only,
    //    no network.
    final todo = <({ChannelManifest m, String signer, Map<String, int> floors})>[];
    for (final m in manifests) {
      final routingKey = '$uuid/${m.subjectId}';
      final signer = signerFor(m);
      try {
        if (!await verifyManifest(m, signer)) {
          rejected.add(
            RejectedChunk(
              reason: 'not signed by your class’s teacher',
              routingKey: routingKey,
            ),
          );
          continue;
        }
        final local = await dao.channelState(uuid, m.subjectId);
        final floors = decodeSignerVersions(local?.signerVersionsJson);
        final floor = floors[signer];

        if (local?.channelDigest == m.digest &&
            local?.manifestSigner == signer) {
          if (local!.channelVersion != m.version ||
              local.manifestSig != m.signature) {
            await dao.updateManifest(
              classUuid: uuid,
              subjectId: m.subjectId,
              version: m.version,
              manifestSig: m.signature,
              signer: signer,
              signerVersionsJson: jsonEncode({...floors, signer: m.version}),
            );
          }
          continue;
        }
        // Gated only by this signer's own floor — never another signer's
        // version number, which is what makes a handoff safe in either
        // direction (see sync_state.signer_versions_json). A subject the
        // teacher removed is a tombstone at some floor value; a classmate
        // relaying an older copy of it can't bring it back.
        if (floor != null && m.version <= floor) continue;
        todo.add((m: m, signer: signer, floors: floors));
      } catch (e) {
        rejected.add(
          RejectedChunk(
            reason: e is SyncTrustError ? e.message : 'subject failed: $e',
            routingKey: routingKey,
          ),
        );
      }
    }

    // 2. Fetch a few subjects at once (round trips dominate on a hotspot),
    //    then check and write each one by itself, in order.
    for (var i = 0; i < todo.length; i += _parallelFetches) {
      final window = todo.sublist(
        i,
        (i + _parallelFetches).clamp(0, todo.length),
      );
      final replies = await Future.wait([
        for (final t in window)
          call(kChannelPath, {
            'school_id': group.schoolId,
            'subject_id': t.m.subjectId,
          }).then<Object>((r) => r, onError: (Object e) => e),
      ]);
      for (var k = 0; k < window.length; k++) {
        final (:m, :signer, :floors) = window[k];
        final routingKey = '$uuid/${m.subjectId}';
        try {
          final reply = replies[k];
          if (reply is! Map<String, Object?>) throw reply;
          final rows = <TopicResourcesCompanion>[];
          final ids = <String>[];
          final bad = <RejectedChunk>[];
          for (final raw in (reply['chunks'] as List? ?? const [])) {
            try {
              final envelope = ResourceChunkEnvelope.fromJson(raw);
              rows.add(_ingest(envelope, routingKey, uuid, m.subjectId));
              ids.add(envelope.chunkId);
            } on FormatException catch (e) {
              bad.add(RejectedChunk(reason: e.message, routingKey: routingKey));
            } on StateError catch (e) {
              bad.add(RejectedChunk(reason: e.message, routingKey: routingKey));
            }
          }
          final digest = await channelDigest(ids);
          if (bad.isEmpty && digest != m.digest) {
            bad.add(
              RejectedChunk(
                reason: fromTeacher
                    ? 'the notes changed while syncing — sync again'
                    : 'the notes don’t match what your teacher signed',
                routingKey: routingKey,
              ),
            );
          }
          if (bad.isNotEmpty) {
            // All or nothing: keep the copy this device already has.
            rejected.addAll(bad);
            continue;
          }
          await dao.replaceChannel(
            classUuid: uuid,
            subjectId: m.subjectId,
            rows: rows,
            digest: digest,
            version: m.version,
            manifestSig: m.signature,
            signer: signer,
            signerVersionsJson: jsonEncode({...floors, signer: m.version}),
          );
          updated++;
          inserted += rows.length;
        } catch (e) {
          rejected.add(
            RejectedChunk(
              reason: e is SyncTrustError ? e.message : 'subject failed: $e',
              routingKey: routingKey,
            ),
          );
        }
      }
    }
    await dao.registerMaterialSubjects(uuid);
    return (updated: updated, inserted: inserted, rejected: rejected);
  }

  /// Downloads the original PDF of every received note in [subjects] of
  /// [classUuid] that this device doesn't have yet. Each one must hash to
  /// the SHA-256 in its marker row — which came in the signed, verified
  /// channel — so whoever serves it can't swap it. Best-effort: a missing
  /// PDF never fails the sync, and the note still works as text.
  ///
  /// Downloaded in parts that are kept on disk, so a break (a dropped
  /// connection, the app closed) costs one part, and the next sync carries
  /// on. A device on an older build sends the whole file instead.
  Future<int> _fetchMissingPdfs(
    String classUuid,
    String schoolId, {
    required Set<String> subjects,
    required Future<Map<String, Object?>> Function(
      String path,
      Map<String, Object?> body,
    )
    call,
  }) async {
    var fetched = 0;
    try {
      for (final p in await pdfStore.recorded(classUuid: classUuid)) {
        if (!subjects.contains(p.subjectId)) continue;
        if (p.bytes > kMaxNotePdfBytes || await pdfStore.has(p.sha256)) {
          continue;
        }
        try {
          if (await _fetchPdf(p, schoolId, call)) fetched++;
        } catch (_) {
          // Not on that device (an older build, or a co-teacher's subject).
        }
      }
      // Replaced or unshared notes leave files nothing refers to.
      await pdfStore.collectGarbage();
    } catch (_) {}
    return fetched;
  }

  /// One PDF, part by part from where an earlier download stopped.
  /// Returns whether it is now stored.
  Future<bool> _fetchPdf(
    NotePdf p,
    String schoolId,
    Future<Map<String, Object?>> Function(String, Map<String, Object?>) call,
  ) async {
    var offset = await pdfStore.partialLength(p.sha256);
    if (offset > p.bytes) {
      // Longer than the signed size: it can't be this file.
      await pdfStore.dropPartial(p.sha256);
      offset = 0;
    }
    // Bounded: a server that never finishes can't keep this loop going.
    for (var i = 0; i <= kMaxNotePdfBytes ~/ kFileChunkBytes + 1; i++) {
      final reply = await call(kFilePath, {
        'school_id': schoolId,
        'subject_id': p.subjectId,
        'sha256': p.sha256,
        'offset': offset,
        'length': kFileChunkBytes,
      });
      final data = reply['data'];
      if (data is! String) return false;
      final bytes = await Isolate.run(() => base64Decode(data));
      final total = reply['total'];
      if (total is! int) {
        // An older build: the whole file at once.
        await pdfStore.dropPartial(p.sha256);
        return await pdfStore.put(bytes, expectedSha: p.sha256) != null;
      }
      if (reply['offset'] != offset ||
          total > kMaxNotePdfBytes ||
          !await pdfStore.appendPartial(p.sha256, bytes, offset)) {
        return false;
      }
      offset += bytes.length;
      if (offset >= total) return pdfStore.finishPartial(p.sha256);
      if (bytes.isEmpty) return false;
    }
    return false;
  }

  /// Opens a class key the teacher sealed to this device and stores it.
  /// Null when it isn't for [group] or doesn't open.
  Future<ClassGroup?> _takeNewClassKey(ClassGroup group, Object? sealed) async {
    try {
      final opened = await openSealedToDevice(
        boxSeed: await _devices.boxSeed(),
        sealed: sealed,
      );
      if (opened is! Map) return null;
      final key = opened['class_key'];
      if (opened['class_uuid'] != group.groupUuid || key is! String) {
        return null;
      }
      return _db.classSyncDao.replaceJoinedClassKey(group.id, key);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, Object?>> _signedCall(
    TeacherEndpoint endpoint,
    String path,
    Map<String, Object?> body, {
    required String uuid,
    required String macKey,
    required Future<Object?> Function(String nonce, Object? sealed) open,
    Future<Map<String, Object?>> Function(String nonce)? extra,
    Duration? timeout,
  }) async {
    final nonce = newNonce();
    final raw = jsonEncode({...body, if (extra != null) ...await extra(nonce)});
    final response = await _client
        .post(
          Uri.parse('http://${endpoint.address}:${endpoint.port}/$path'),
          headers: {
            'content-type': 'application/json',
            kClassHeader: uuid,
            kNonceHeader: nonce,
            kMacHeader: await requestMac(
              classKey: macKey,
              path: path,
              nonce: nonce,
              body: raw,
            ),
            ...await _devices.requestHeaders(
              path: path,
              nonce: nonce,
              body: raw,
            ),
          },
          body: raw,
        )
        .timeout(timeout ?? _timeout);
    if (response.statusCode != 200) {
      throw StateError(
        'the sharing device refused this request (${response.statusCode})',
      );
    }
    final opened = await open(nonce, jsonDecode(response.body));
    if (opened is! Map) throw const SyncTrustError('reply is not an object');
    return Map<String, Object?>.from(opened);
  }

  /// One chunk's checks: its routing key names this class+subject, and its
  /// content matches its own hash.
  TopicResourcesCompanion _ingest(
    ResourceChunkEnvelope envelope,
    String expectedRoutingKey,
    String classUuid,
    String subjectId,
  ) {
    if (envelope.routingKey != expectedRoutingKey) {
      throw StateError(
        'routing key mismatch: expected $expectedRoutingKey, got ${envelope.routingKey}',
      );
    }
    if (!envelope.hashMatches) {
      throw StateError('chunk content does not match its id');
    }
    final p = envelope.payload;
    final topicKey = p['topic_key'], termMarker = p['term_marker'];
    final title = p['resource_title'], content = p['content_chunk'];
    final createdAt = p['created_at'], updatedAt = p['updated_at'];
    if (p['subject_id'] != subjectId ||
        topicKey is! String ||
        termMarker is! int ||
        title is! String ||
        content is! String ||
        createdAt is! String) {
      throw const FormatException('payload missing or mistyped fields');
    }
    return TopicResourcesCompanion.insert(
      subjectId: subjectId,
      topicKey: topicKey,
      termMarker: Value(termMarker),
      resourceTitle: title,
      contentChunk: content,
      createdAt: createdAt,
      classGroupUuid: Value(classUuid),
      updatedAt: Value(updatedAt is String ? updatedAt : createdAt),
      documentTitle: Value(
        p['document_title'] is String ? p['document_title'] as String : title,
      ),
    );
  }

  void dispose() => _client.close();
}
