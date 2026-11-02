import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart'
    show InsertMode, TableUpdate, TableUpdateQuery, Value;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../../db/otic_database.dart';
import '../../services/assignments/class_assignments.dart';
import '../../services/assignments/learner_support.dart';
import '../../services/notes/note_pdf_store.dart';
import 'class_crypto.dart';
import 'class_enrolment.dart';
import 'device_keys.dart';
import 'device_registry.dart';
import 'failover_crypto.dart';
import 'p2p_failover_service.dart' show buildSealedLedger;
import 'progress_report.dart';
import 'routing_envelope.dart';
import 'share_keep_alive.dart';

/// Paths of the class-sync protocol. Version 4: a class may have
/// co-teacher devices, each delegated specific subjects and each serving
/// with its own signing key (`api/v4/coteacher/join`); a class's signed,
/// versioned roster of who may sign what travels alongside its manifests.
/// Version 3 added: classmates may pass the teacher's notes on, and every
/// channel carries the teacher's signed version. Earlier versions are not
/// served — an old build's requests to a v4 server simply don't match any
/// route, and vice versa, rather than a v4 device silently deleting notes
/// an old build can't account for.
const kJoinPath = 'api/v4/join';
const kHandshakePath = 'api/v4/sync/handshake';
const kChannelPath = 'api/v4/sync/channel';

/// A co-teacher device joining a class through its root teacher — grants
/// signing authority for the subjects the root allocates, not just read
/// access, so it gets its own code/TTL/approval flow separate from a
/// student's.
const kCoTeacherJoinPath = 'api/v4/coteacher/join';

/// A student device reporting its learners' progress to the teacher.
const kReportPath = 'api/v4/report';

/// The original PDF behind a note, by the SHA-256 its marker row records
/// (see `NotePdfStore`). Served only when that marker is in a channel the
/// requester may pull, so it reaches exactly who gets the note. Added
/// without a version bump: a build without it answers 404, and the note
/// still syncs as text.
const kFilePath = 'api/v4/sync/file';

/// Most bytes of a PDF one [kFilePath] reply carries when the requester
/// asks for a part (an `offset`), so a dropped connection loses one part,
/// not the whole file. Without `offset` the whole file comes back, as
/// before.
const kFileChunkBytes = 2 * 1024 * 1024;

/// After a sync, a student device tells the teacher which version of each
/// subject it now holds, so the teacher sees how many devices have a note.
/// Best-effort and added without a version bump: a build without it
/// answers 404 and nothing else changes.
const kAckPath = 'api/v4/sync/ack';

/// Host failover: a device pairing as this host's standby (code + Accept,
/// binding the standby's own key), then pulling the encrypted host ledger
/// with requests signed by that key. Root teacher device only.
const kStandbyPairPath = 'api/v4/failover/pair';
const kStandbyLedgerPath = 'api/v4/failover/ledger';

/// Header naming the standby's public key on a ledger request; the request
/// signature travels in [kMacHeader].
const kStandbyHeader = 'x-otic-standby';

/// Lifetime of a standby pairing code — short, like a co-teacher's: the
/// standby ends up holding the school's signing key (passphrase-sealed).
const kStandbyCodeTtl = Duration(minutes: 15);

/// Most learners one device may report at once — a shared classroom
/// device, not a whole school.
const kMaxReportsPerDevice = 60;

/// The port a sharing device listens on unless it is busy — also what a
/// student device assumes when an address is typed without one.
const kDefaultSyncPort = 8765;

/// Headers a sync request carries.
const kClassHeader = 'x-otic-class';
const kNonceHeader = 'x-otic-nonce';
const kMacHeader = 'x-otic-mac';

/// Wrong join codes tolerated from one device (address) before that device
/// is shut out until the sharer makes a new code.
///
/// Per device, not per server: a student's device tries its code on every
/// sharer it can see, so with two teachers — or several students sharing —
/// in one room, every other sharer's joins would otherwise count as wrong
/// guesses here and lock this sharer's whole class out mid-lesson. Guessing
/// stays pointless either way: a right code still needs the sharer's Accept.
const kMaxFailedJoins = 20;

/// How long a join waits for the sharer to tap Accept.
const kJoinApprovalTimeout = Duration(minutes: 2);

/// Default lifetime of a co-teacher invite code — shorter than a student's
/// (30 min), reflecting that it grants signing authority, not just read
/// access.
const kCoTeacherInviteTtl = Duration(minutes: 15);

/// Who is sharing.
enum ShareRole {
  /// A teacher device, serving notes of classes it created.
  teacher,

  /// A student device passing on the teacher's notes it received, to
  /// classmates who already joined the class through the teacher.
  classmate,
}

/// What kind of request is waiting for the sharer's Accept/Decline.
enum PendingJoinKind { student, coTeacher, standby }

/// Someone who typed the right code and is waiting for the sharer's answer.
class PendingJoin {
  const PendingJoin({
    required this.id,
    required this.name,
    required this.address,
    required this.classUuid,
    this.kind = PendingJoinKind.student,
    this.subjectIds = const [],
  });

  final String id;

  /// The learner's (or co-teacher's) name as their device sent it.
  /// Informational — the code is what proved they were given it.
  final String name;
  final String address;
  final String classUuid;
  final PendingJoinKind kind;

  /// [PendingJoinKind.coTeacher] only: the subjects this invite would
  /// allocate, so the approval UI can show what's being granted.
  final List<String> subjectIds;
}

class _OpenCode {
  _OpenCode(this.classUuid, this.expires, {this.subjectIds = const []});
  final String classUuid;
  final DateTime expires;

  /// Co-teacher codes only.
  final List<String> subjectIds;
}

class _Waiting {
  _Waiting(this.info);
  final PendingJoin info;
  final decision = Completer<bool>();
}

/// What this device knows about a class it's asked to sync, whichever of
/// `ClassGroups` (owned or joined) or `CoTeachingClasses` (delegated) it
/// came from — see [ClassShareServer._resolveServedClass].
class _ServedClass {
  const _ServedClass({
    required this.groupUuid,
    required this.schoolId,
    required this.classKey,
    required this.allocatedSubjects,
    this.rosterJson,
    this.retiredKeys = const [],
  });

  final String groupUuid;
  final String? schoolId;
  final String? classKey;

  /// Null for root (or a classmate, which has no allocation concept) —
  /// unrestricted. Non-null for a co-teacher device: only these subjects
  /// may ever be served or signed for.
  final Set<String>? allocatedSubjects;

  /// The class's signed co-teacher roster (JSON), forwarded verbatim —
  /// null if the class has never had a co-teacher.
  final String? rosterJson;

  /// Class keys a revocation replaced (root only). A trusted device still
  /// holding one may only ask for the current key, sealed to it.
  final List<String> retiredKeys;

  bool get isDelegate => allocatedSubjects != null;
}

/// The embedded HTTP server a sharing device runs so other devices on the
/// same Wi-Fi/hotspot can pull a class's notes.
///
/// Who gets what is enforced here, not by network position:
///
/// * **Joining takes the right code and the sharer's Accept.** A device
///   proves it knows the code (the code never crosses the network), then
///   waits while the sharer sees its name and taps Accept or Decline.
/// * **Teacher role:** only classes this device created, only notes it
///   wrote and explicitly shared with the class (`ClassSyncDao.sharedChunks`).
///   Replies are signed with the teacher key over the requester's nonce, and
///   each channel carries a signed, monotonic manifest.
/// * **Classmate role:** only the one class this device joined through the
///   teacher, only the notes it received, verbatim, with the teacher's
///   manifests — so the next device can check they are the teacher's and
///   newer than what it holds. Only devices this classmate accepted may
///   pull: their requests are MAC'd with the session token handed over at
///   join, not just the class key.
/// * Anything else — unknown class, bad MAC, wrong school, no session —
///   gets the same bare 404, so a guesser learns nothing.
class ClassShareServer {
  ClassShareServer(
    this._db, {
    this.role = ShareRole.teacher,
    this.joinRounds = kJoinKdfRounds,
    this.approvalTimeout = kJoinApprovalTimeout,
    this.teacherId,
    NotePdfStore? pdfStore,
  }) : pdfStore = pdfStore ?? NotePdfStore(_db);

  final OticDatabase _db;
  late final DeviceRegistry _devices = DeviceRegistry(_db);
  final ShareRole role;

  /// The signed-in teacher approving enrolments on this device.
  final int? teacherId;

  /// Where the notes' original PDFs are read from.
  final NotePdfStore pdfStore;

  /// PBKDF2 rounds for join codes — lowered only in tests.
  final int joinRounds;
  final Duration approvalTimeout;

  HttpServer? _server;
  final Set<String> serving = {};
  final Map<String, _OpenCode> _codes = {};

  /// Separate from [_codes]: a co-teacher code grants signing authority,
  /// not just read access, so it isn't spent by — or counted against —
  /// ordinary student join guessing.
  final Map<String, _OpenCode> _coTeacherCodes = {};

  /// Standby pairing codes (host failover) — kept apart for the same reason.
  final Map<String, _OpenCode> _standbyCodes = {};
  final Map<String, int> _failedJoins = {};

  final Map<String, _Waiting> _waiting = {};
  final _pendingCtrl = StreamController<List<PendingJoin>>.broadcast();

  /// Classmate role: tokens of devices the sharer accepted.
  final Set<String> _sessions = {};

  /// One class+subject's envelopes and digest, keyed `uuid/subject`. Every
  /// handshake used to rebuild and re-hash every shared note, once per
  /// student per sync; now that happens once per change. Cleared on any
  /// write to the notes, their shares or the classes, and [_cacheGen]
  /// stops a build that raced a write from being stored.
  final Map<String, ({List<ResourceChunkEnvelope> chunks, String digest})>
  _channelCache = {};
  int _cacheGen = 0;
  StreamSubscription<Set<TableUpdate>>? _cacheInvalidator;

  bool get isRunning => _server != null;
  int? get port => _server?.port;

  /// Whether some device was shut out for too many wrong codes.
  bool get joinLocked => _failedJoins.values.any((n) => n >= kMaxFailedJoins);

  bool _lockedOut(String address) =>
      (_failedJoins[address] ?? 0) >= kMaxFailedJoins;

  static String _remote(Request request) {
    final info = request.context['shelf.io.connection_info'];
    return info is HttpConnectionInfo ? info.remoteAddress.address : '';
  }

  /// Joins waiting for the sharer's Accept or Decline, oldest first.
  List<PendingJoin> get pendingJoins => [
    for (final w in _waiting.values) w.info,
  ];

  /// Emits [pendingJoins] every time it changes.
  Stream<List<PendingJoin>> get pendingJoinsStream => _pendingCtrl.stream;

  /// The sharer's answer to one waiting join.
  void decide(String id, {required bool accept}) {
    final w = _waiting.remove(id);
    if (w == null) return;
    if (!w.decision.isCompleted) w.decision.complete(accept);
    _emitPending();
  }

  /// Starts serving [classUuids]. Tries [port], then any free port — a
  /// device can be sharing as teacher and as classmate at once.
  Future<int> start({
    required Set<String> classUuids,
    int port = kDefaultSyncPort,
  }) async {
    serving
      ..clear()
      ..addAll(classUuids);
    if (_server != null) return _server!.port;
    HttpServer server;
    try {
      server = await shelf_io.serve(_route, InternetAddress.anyIPv4, port);
    } on SocketException {
      if (port == 0) rethrow;
      server = await shelf_io.serve(_route, InternetAddress.anyIPv4, 0);
    }
    _server = server;
    _cacheInvalidator ??= _db
        .tableUpdates(
          TableUpdateQuery.onAllTables([
            _db.topicResources,
            _db.resourceShares,
            _db.classGroups,
          ]),
        )
        .listen((_) {
          _cacheGen++;
          _channelCache.clear();
        });
    // Android: keep serving with the screen off or the app in the background.
    unawaited(ShareKeepAlive.acquire());
    return server.port;
  }

  Future<void> stop() async {
    if (_server != null) unawaited(ShareKeepAlive.release());
    await _server?.close(force: true);
    _server = null;
    unawaited(_cacheInvalidator?.cancel());
    _cacheInvalidator = null;
    _channelCache.clear();
    _cacheGen++;
    _codes.clear();
    _coTeacherCodes.clear();
    _standbyCodes.clear();
    _sessions.clear();
    for (final w in _waiting.values) {
      if (!w.decision.isCompleted) w.decision.complete(false);
    }
    _waiting.clear();
    _emitPending();
  }

  void dispose() {
    unawaited(stop());
    _pendingCtrl.close();
  }

  /// Opens a new join code for [group] (replacing any earlier one for it)
  /// and returns it for display, `XXXX-XXXX`. Null when this device can't
  /// share the class in its role: as teacher, a class it created; as
  /// classmate, a class it joined through the teacher.
  Future<String?> openJoinCode(
    ClassGroup group, {
    Duration ttl = const Duration(minutes: 15),
  }) async {
    final uuid = group.groupUuid;
    if (uuid == null) return null;
    final ClassGroup? usable;
    if (role == ShareRole.teacher) {
      // Only a class created here; never one joined as a student.
      if (group.joined) return null;
      final keyed = await _db.classSyncDao.ensureClassKey(group);
      usable = keyed.schoolId == null ? null : keyed;
    } else {
      usable = await _joinedClass(uuid);
    }
    if (usable == null) return null;
    _codes.removeWhere((_, c) => c.classUuid == uuid);
    final code = newJoinCode();
    _codes[normalizeJoinCode(code)!] = _OpenCode(
      uuid,
      DateTime.now().add(ttl));
    _failedJoins.clear();
    return code;
  }

  void closeJoinCodes() => _codes.clear();

  /// Opens a new co-teacher invite code for [group], allocating [subjectIds]
  /// on accept. Null when this device can't invite a co-teacher (a student
  /// device, or a class it doesn't own — only root ever invites), or when
  /// any of [subjectIds] is already allocated to another co-teacher of this
  /// class (re-checked here against a race with another invite flow, not
  /// just at the picker).
  Future<String?> openCoTeacherInviteCode(
    ClassGroup group, {
    required List<String> subjectIds,
    Duration ttl = kCoTeacherInviteTtl,
  }) async {
    final uuid = group.groupUuid;
    if (uuid == null || role != ShareRole.teacher || group.joined) {
      return null;
    }
    final keyed = await _db.classSyncDao.ensureClassKey(group);
    if (keyed.schoolId == null) return null;
    final already = await _db.coTeacherDao.allocatedSubjects(uuid);
    if (subjectIds.any(already.contains)) return null;
    _coTeacherCodes.removeWhere((_, c) => c.classUuid == uuid);
    final code = newJoinCode();
    _coTeacherCodes[normalizeJoinCode(code)!] = _OpenCode(
      uuid,
      DateTime.now().add(ttl),
      subjectIds: subjectIds,
    );
    return code;
  }

  /// Opens a code a standby device types to pair with this host (host
  /// failover). Null unless this is a teacher device sharing as teacher
  /// with a failover passphrase set (`P2PFailoverService.enableFailover`) —
  /// without one there is no ledger to hand over.
  Future<String?> openStandbyCode({Duration ttl = kStandbyCodeTtl}) async {
    if (role != ShareRole.teacher) return null;
    final me = await _db.classSyncDao.identity();
    if (me.schoolId == null || me.failoverSealKey == null) return null;
    _standbyCodes.clear();
    final code = newJoinCode();
    _standbyCodes[normalizeJoinCode(code)!] = _OpenCode(
      '',
      DateTime.now().add(ttl),
    );
    return code;
  }

  void _emitPending() {
    if (!_pendingCtrl.isClosed) _pendingCtrl.add(pendingJoins);
  }

  /// The class this device serves in its role, by uuid — used only for
  /// resolving a student/classmate join code, which only ever names a class
  /// this device fully owns (root) or fully joined, never a delegated one
  /// (co-teachers can't issue student codes; see [openCoTeacherInviteCode]
  /// vs [openJoinCode]).
  Future<ClassGroup?> _servedClass(String uuid) =>
      role == ShareRole.teacher
          ? _db.classSyncDao.ownedByUuid(uuid)
          : _joinedClass(uuid);

  Future<ClassGroup?> _joinedClass(String uuid) =>
      _db.classSyncDao.joinedByUuid(uuid);

  /// What this device knows about the class it's asked to sync, whichever
  /// of `ClassGroups` (owned or joined) or `CoTeachingClasses` (delegated)
  /// it came from — used by [_sync]'s handshake/channel/report dispatch,
  /// unlike [_servedClass] which only ever resolves a fully-owned or
  /// fully-joined class for the join flow above.
  Future<_ServedClass?> _resolveServedClass(String uuid) async {
    if (role == ShareRole.classmate) {
      final g = await _joinedClass(uuid);
      if (g == null) return null;
      return _ServedClass(
        groupUuid: uuid,
        schoolId: g.schoolId,
        classKey: g.classKey,
        allocatedSubjects: null,
      );
    }
    final owned = await _db.classSyncDao.ownedByUuid(uuid);
    if (owned != null) {
      return _ServedClass(
        groupUuid: uuid,
        schoolId: owned.schoolId,
        classKey: owned.classKey,
        allocatedSubjects: null,
        rosterJson: owned.rosterJson,
        retiredKeys: DeviceRegistry.retiredKeysOf(owned),
      );
    }
    final delegated = await _db.coTeacherDao.delegatedByUuid(uuid);
    if (delegated == null) return null;
    return _ServedClass(
      groupUuid: uuid,
      schoolId: delegated.schoolId,
      classKey: delegated.classKey,
      allocatedSubjects: {
        for (final s in jsonDecode(delegated.subjectIdsJson) as List)
          if (s is String) s,
      },
      rosterJson: delegated.rosterJson,
    );
  }

  // ── Routing ─────────────────────────────────────────────────────────────

  // A fresh response each time: a shelf Response's body can only be read once.
  static Response _notFound() => Response.notFound(
    '',
    headers: const {'content-type': 'application/json'},
  );

  Future<Response> _route(Request request) async {
    if (request.method != 'POST') return _notFound();
    try {
      return switch (request.url.path) {
        kJoinPath => await _join(request),
        kCoTeacherJoinPath when role == ShareRole.teacher =>
          await _coTeacherJoin(request),
        kHandshakePath || kChannelPath || kFilePath => await _sync(request),
        kAckPath when role == ShareRole.teacher => await _sync(request),
        kReportPath when role == ShareRole.teacher => await _sync(request),
        kStandbyPairPath when role == ShareRole.teacher =>
          await _standbyPair(request,
        ),
        kStandbyLedgerPath when role == ShareRole.teacher =>
          await _standbyLedger(request),
        _ => _notFound(),
      };
    } catch (_) {
      return _notFound();
    }
  }

  // ── Join ────────────────────────────────────────────────────────────────

  Future<Response> _join(Request request) async {
    final now = DateTime.now();
    _codes.removeWhere((_, c) => c.expires.isBefore(now));
    final from = _remote(request);
    if (_codes.isEmpty || _lockedOut(from)) return _notFound();
    final body = jsonDecode(await request.readAsString());
    final salt = body is Map ? body['nonce'] : null;
    final proof = body is Map ? body['proof'] : null;
    final rawName = body is Map ? body['name'] : null;
    final learnerUuid = body is Map ? body['learner_uuid'] : null;
    if (learnerUuid != null &&
        (learnerUuid is! String ||
            !RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(learnerUuid) ||
            rawName is! String ||
            rawName.trim().isEmpty ||
            rawName.length > 80)) {
      return _notFound();
    }
    if (salt is! String || salt.length < 16 || proof is! String) {
      return _notFound();
    }

    for (final entry in _codes.entries.toList()) {
      final secret = await joinSecret(entry.key, salt, rounds: joinRounds);
      if (!constantTimeEquals(await joinProof(secret, salt), proof)) continue;

      final group = await _servedClass(entry.value.classUuid);
      if (group == null || group.classKey == null || group.schoolId == null) {
        return _notFound();
      }

      // The right code — now the sharer decides.
      if (!await _approve(request, rawName, group.groupUuid!)) {
        return _notFound();
      }
      // A device on this build names itself, so it can be revoked later.
      final deviceKey = body['device_key'], boxKey = body['box_key'];
      if (role == ShareRole.teacher && deviceKey is String) {
        if (await _devices.isRevoked(group.groupUuid!, deviceKey)) {
          return _notFound();
        }
        await _devices.recordMember(
          group.groupUuid!,
          deviceKey,
          boxKey: boxKey is String ? boxKey : null,
          name: rawName is String ? rawName : null,
        );
      }

      final me = await _db.classSyncDao.identity();
      final Map<String, Object?> details;
      if (role == ShareRole.teacher) {
        final enrolment = learnerUuid is String
            ? await ClassEnrolment(_db).approve(
                learnerUuid: learnerUuid,
                name: rawName as String,
                group: group,
                teacherId: teacherId,
              )
            : null;
        details = {
          'teacher_name': teacherId == null ? 'Your teacher' : (await (_db.select(_db.teacherProfiles)..where((t) => t.id.equals(teacherId!))).getSingleOrNull())?.name ?? 'Your teacher',
          'school_id': group.schoolId,
          'school_name': me.schoolName ?? '',
          'class_group_uuid': group.groupUuid,
          'class_name': group.className,
          'stream_name': group.streamName,
          'class_key': group.classKey,
          'teacher_public_key': await signingPublicKey(me.signingSeed),
          'shared_subjects': await _db.classSyncDao.sharedSubjects(
            group.groupUuid!,
          ),
          if (enrolment != null) ...{
            'learner_uuid': learnerUuid,
            'enrolment_uuid': enrolment.uuid,
            'academic_year': enrolment.academicYear,
          },
          // So a brand-new student already has a cached roster before its
          // first sync, even one against a co-teacher's device — see
          // SelectiveSyncManager's bootstrap handling.
          if (group.rosterJson != null) 'roster': jsonDecode(group.rosterJson!),
        };
      } else {
        final token = newSessionToken();
        _sessions.add(token);
        details = {
          'school_id': group.schoolId,
          'class_group_uuid': group.groupUuid,
          'session_token': token,
        };
      }
      return _json({'bundle': await sealJoinBundle(secret, salt, details)});
    }
    _failedJoins[from] = (_failedJoins[from] ?? 0) + 1;
    return _notFound();
  }

  Future<bool> _approve(
    Request request,
    Object? rawName,
    String classUuid, {
    PendingJoinKind kind = PendingJoinKind.student,
    List<String> subjectIds = const [],
  }) async {
    final name = rawName is String && rawName.trim().isNotEmpty
        ? rawName.trim().substring(0, rawName.trim().length.clamp(0, 40))
        : (kind == PendingJoinKind.coTeacher ? 'A teacher' : 'A learner');
    final waiting = _Waiting(
      PendingJoin(
        id: newNonce(),
        name: name,
        address: _remote(request),
        classUuid: classUuid,
        kind: kind,
        subjectIds: subjectIds,
      ),
    );
    _waiting[waiting.info.id] = waiting;
    _emitPending();
    final accepted = await waiting.decision.future.timeout(
      approvalTimeout,
      onTimeout: () => false,
    );
    if (_waiting.remove(waiting.info.id) != null) _emitPending();
    return accepted && _server != null;
  }

  // ── Co-teacher join ─────────────────────────────────────────────────────

  Future<Response> _coTeacherJoin(Request request) async {
    final now = DateTime.now();
    _coTeacherCodes.removeWhere((_, c) => c.expires.isBefore(now));
    final from = _remote(request);
    if (_coTeacherCodes.isEmpty || _lockedOut(from)) return _notFound();
    final body = jsonDecode(await request.readAsString());
    final salt = body is Map ? body['nonce'] : null;
    final proof = body is Map ? body['proof'] : null;
    final rawName = body is Map ? body['name'] : null;
    final devicePublicKey = body is Map ? body['device_public_key'] : null;
    if (salt is! String ||
        salt.length < 16 ||
        proof is! String ||
        devicePublicKey is! String ||
        devicePublicKey.isEmpty) {
      return _notFound();
    }

    for (final entry in _coTeacherCodes.entries.toList()) {
      final secret = await joinSecret(entry.key, salt, rounds: joinRounds);
      final expected = await coTeacherJoinProof(secret, salt, devicePublicKey);
      if (!constantTimeEquals(expected, proof)) continue;

      final group = await _db.classSyncDao.ownedByUuid(entry.value.classUuid);
      if (group == null || group.classKey == null || group.schoolId == null) {
        return _notFound();
      }

      if (!await _approve(
        request,
        rawName,
        group.groupUuid!,
        kind: PendingJoinKind.coTeacher,
        subjectIds: entry.value.subjectIds,
      )) {
        return _notFound();
      }

      final name = rawName is String && rawName.trim().isNotEmpty
          ? rawName.trim().substring(0, rawName.trim().length.clamp(0, 40))
          : 'A teacher';
      final added = await _db.coTeacherDao.addCoTeacher(
        group: group,
        publicKey: devicePublicKey,
        name: name,
        subjectIds: entry.value.subjectIds,
      );
      if (!added) return _notFound();
      // Re-read: addCoTeacher just bumped rosterVersion/rosterJson.
      final updated = await _db.classSyncDao.ownedByUuid(group.groupUuid!);
      if (updated?.rosterJson == null) return _notFound();

      final me = await _db.classSyncDao.identity();
      final details = {
        'school_id': updated!.schoolId,
        'school_name': me.schoolName ?? '',
        'class_group_uuid': updated.groupUuid,
        'class_name': updated.className,
        'stream_name': updated.streamName,
        'class_key': updated.classKey,
        'root_public_key': await signingPublicKey(me.signingSeed),
        'subject_ids': entry.value.subjectIds,
        'roster': jsonDecode(updated.rosterJson!),
      };
      _coTeacherCodes.remove(entry.key);
      return _json({'bundle': await sealJoinBundle(secret, salt, details)});
    }
    _failedJoins[from] = (_failedJoins[from] ?? 0) + 1;
    return _notFound();
  }

  // ── Host failover: standby pairing and ledger ─────────────────────────

  Future<Response> _standbyPair(Request request) async {
    final now = DateTime.now();
    _standbyCodes.removeWhere((_, c) => c.expires.isBefore(now));
    final from = _remote(request);
    if (_standbyCodes.isEmpty || _lockedOut(from)) return _notFound();
    final body = jsonDecode(await request.readAsString());
    final salt = body is Map ? body['nonce'] : null;
    final proof = body is Map ? body['proof'] : null;
    final rawName = body is Map ? body['name'] : null;
    final standbyKey = body is Map ? body['device_public_key'] : null;
    if (salt is! String ||
        salt.length < 16 ||
        proof is! String ||
        standbyKey is! String ||
        standbyKey.isEmpty) {
      return _notFound();
    }

    for (final entry in _standbyCodes.entries.toList()) {
      final secret = await joinSecret(entry.key, salt, rounds: joinRounds);
      final expected = await standbyPairProof(secret, salt, standbyKey);
      if (!constantTimeEquals(expected, proof)) continue;

      final me = await _db.classSyncDao.identity();
      if (me.schoolId == null || me.failoverSealKey == null) {
        return _notFound();
      }
      if (!await _approve(
        request,
        rawName,
        '',
        kind: PendingJoinKind.standby,
      )) {
        return _notFound();
      }
      final name = rawName is String && rawName.trim().isNotEmpty
          ? rawName.trim().substring(0, rawName.trim().length.clamp(0, 40))
          : 'A standby device';
      await _db
          .into(_db.failoverStandbys)
          .insert(
            FailoverStandbysCompanion.insert(publicKey: standbyKey, name: name),
            mode: InsertMode.insertOrReplace,
          );
      _standbyCodes.remove(entry.key);
      return _json({
        'bundle': await sealJoinBundle(secret, salt, {
          'school_id': me.schoolId,
          'school_name': me.schoolName ?? '',
          'root_public_key': await signingPublicKey(me.signingSeed),
        }),
      });
    }
    _failedJoins[from] = (_failedJoins[from] ?? 0) + 1;
    return _notFound();
  }

  /// A paired standby pulling the current ledger. The request is signed
  /// with the standby's pinned key; the reply is the passphrase-sealed
  /// ledger, signed with the root key over the standby's nonce.
  Future<Response> _standbyLedger(Request request) async {
    final standbyKey = request.headers[kStandbyHeader];
    final nonce = request.headers[kNonceHeader];
    final sig = request.headers[kMacHeader];
    if (standbyKey == null || nonce == null || nonce.length < 16 || sig == null) {
      return _notFound();
    }
    final paired = await (_db.select(_db.failoverStandbys,
    )
          ..where((t) => t.publicKey.equals(standbyKey)))
        .getSingleOrNull();
    if (paired == null) return _notFound();
    final raw = await request.readAsString();
    if (!await verifyStandbyRequest(
      standbyPublicKey: standbyKey,
      path: kStandbyLedgerPath,
      nonce: nonce,
      body: raw,
      signature: sig,
    )) {
      return _notFound();
    }
    final ledger = await buildSealedLedger(_db);
    if (ledger == null) return _notFound();
    final me = await _db.classSyncDao.identity();
    final ledgerJson = jsonEncode(ledger);
    await (_db.update(_db.failoverStandbys,
    )
          ..where((t) => t.id.equals(paired.id)))
        .write(FailoverStandbysCompanion(lastMirroredAt: Value(DateTime.now())),
    );
    return _json({
      'ledger_json': ledgerJson,
      'sig': await signLedgerReply(
        rootSeed: me.signingSeed,
        nonce: nonce,
        ledgerJson: ledgerJson,
      ),
    });
  }

  // ── Sync ────────────────────────────────────────────────────────────────

  Future<Response> _sync(Request request) async {
    final classUuid = request.headers[kClassHeader];
    final nonce = request.headers[kNonceHeader];
    final mac = request.headers[kMacHeader];
    if (classUuid == null ||
        nonce == null ||
        nonce.length < 16 ||
        mac == null) {
      return _notFound();
    }
    if (!serving.contains(classUuid)) return _notFound();

    final served = await _resolveServedClass(classUuid);
    final classKey = served?.classKey;
    if (served == null || classKey == null || served.schoolId == null) {
      return _notFound();
    }

    final raw = await request.readAsString();
    final path = request.url.path;
    // Which device is asking: on this build every request is signed by
    // the device's own key. A revoked device is refused outright.
    final deviceKey = request.headers[kDeviceHeader];
    final deviceSig = request.headers[kDeviceSigHeader];
    final rootServes = role == ShareRole.teacher && !served.isDelegate;
    if (deviceKey != null) {
      if (deviceSig == null ||
          !await verifyDeviceRequest(
            deviceKey: deviceKey,
            signature: deviceSig,
            path: path,
            nonce: nonce,
            body: raw,
          )) {
        return _notFound();
      }
      if (rootServes && await _devices.isRevoked(classUuid, deviceKey)) {
        return _notFound();
      }
    }
    if (!await _macOk(classKey, path, nonce, raw, mac)) {
      return rootServes
          ? await _rekey(served, path, nonce, raw, mac, deviceKey)
          : _notFound();
    }

    final body = jsonDecode(raw);
    if (body is! Map || body['school_id'] != served.schoolId) {
      return _notFound();
    }
    if (rootServes && deviceKey != null) {
      final boxKey = body['box_key'];
      await _devices.recordMember(
        classUuid,
        deviceKey,
        boxKey: boxKey is String ? boxKey : null,
      );
    }

    final Object? reply = switch (path) {
      kHandshakePath => await _handshake(served),
      // A co-teacher device never receives progress reports — root only.
      kReportPath when !served.isDelegate =>
        await _report(served, classKey, nonce, body['report'],
      ),
      kReportPath => null,
      kFilePath => await _noteFile(
        served,
        body['subject_id'],
        body['sha256'],
        offset: body['offset'],
        length: body['length'],
      ),
      kAckPath when rootServes && deviceKey != null => await _ack(
        served,
        deviceKey,
        body['held'],
      ),
      kAckPath => null,
      _ => await _channel(served, body['subject_id']),
    };
    if (reply == null) return _notFound();

    if (role == ShareRole.classmate) {
      return _json(
        await sealRelayReply(
          classKey: classKey,
          requestNonce: nonce,
          json: reply,
          heavy: path == kFilePath,
        ),
      );
    }
    final me = await _db.classSyncDao.identity();
    return _json(
      await sealReply(
        classKey: classKey,
        signingSeed: me.signingSeed,
        requestNonce: nonce,
        json: reply,
        heavy: path == kFilePath,
      ),
    );
  }

  /// A trusted device still holding a key a revocation replaced: its
  /// handshake gets only the current key, sealed to its own box key and
  /// sent under the old one. Anything else — no device key, a revoked or
  /// unknown device, a device on an older build — gets the bare 404, so a
  /// revoked device learns nothing.
  Future<Response> _rekey(
    _ServedClass served,
    String path,
    String nonce,
    String raw,
    String mac,
    String? deviceKey,
  ) async {
    if (path != kHandshakePath || deviceKey == null) return _notFound();
    String? oldKey;
    for (final k in served.retiredKeys) {
      if (constantTimeEquals(
        await requestMac(classKey: k, path: path, nonce: nonce, body: raw),
        mac,
      )) {
        oldKey = k;
      }
    }
    if (oldKey == null) return _notFound();
    final member = await _devices.member(served.groupUuid, deviceKey);
    final boxKey = member?.boxKey;
    if (member == null || member.revokedAt != null || boxKey == null) {
      return _notFound();
    }
    await _devices.recordMember(served.groupUuid, deviceKey);
    final me = await _db.classSyncDao.identity();
    return _json(
      await sealReply(
        classKey: oldKey,
        signingSeed: me.signingSeed,
        requestNonce: nonce,
        json: {
          'rekey': await sealToDevice(
            recipientBoxKey: boxKey,
            json: {'class_uuid': served.groupUuid, 'class_key': served.classKey,
            },
          ),
        },
      ),
    );
  }

  /// Teacher: MAC'd with the class key. Classmate: MAC'd with the session
  /// token of a device this classmate accepted — the class key alone is
  /// not enough to pull from a classmate.
  Future<bool> _macOk(
    String classKey,
    String path,
    String nonce,
    String body,
    String mac,
  ) async {
    final keys = role == ShareRole.teacher ? [classKey] : _sessions.toList();
    var ok = false;
    for (final key in keys) {
      final expected = await requestMac(
        classKey: key,
        path: path,
        nonce: nonce,
        body: body,
      );
      if (constantTimeEquals(expected, mac)) ok = true;
    }
    return ok;
  }

  Future<Map<String, Object?>> _handshake(_ServedClass served) async {
    final uuid = served.groupUuid;
    final dao = _db.classSyncDao;
    final manifests = <Map<String, Object?>>[];
    if (role == ShareRole.teacher) {
      final me = await dao.identity();
      var subjects = await dao.sharedSubjects(uuid);
      if (served.allocatedSubjects != null) {
        // A co-teacher: never more than its own allocation, even if a
        // stale share row somehow named a subject outside it.
        subjects = subjects.where(served.allocatedSubjects!.contains).toList();
      } else {
        // Root: never re-offer a subject currently delegated to a
        // co-teacher — that device signs for it now.
        final delegated = await _db.coTeacherDao.allocatedSubjects(uuid);
        subjects = subjects.where((s) => !delegated.contains(s)).toList();
      }
      await dao.retireUnshared(uuid, subjects.toSet());
      for (final subject in subjects) {
        final digest = (await _cachedChannel(uuid, subject)).digest;
        final version = await dao.servedVersion(uuid, subject, digest);
        manifests.add(
          ChannelManifest(
            schoolId: served.schoolId!,
            classUuid: uuid,
            subjectId: subject,
            digest: digest,
            version: version,
            signature: await signManifest(
              signingSeed: me.signingSeed,
              schoolId: served.schoolId!,
              classUuid: uuid,
              subjectId: subject,
              digest: digest,
              version: version,
            ),
          ).toJson(),
        );
      }
    } else {
      // Exactly what the teacher (or co-teacher) signed — never re-signed,
      // never edited.
      for (final s in await dao.relayableChannels(uuid)) {
        manifests.add({
          'subject_id': s.subjectId,
          'digest': s.channelDigest,
          'version': s.channelVersion,
          'sig': s.manifestSig,
        });
      }
    }
    return {
      'class_group_uuid': uuid,
      'subjects': manifests,
      // The subjects taught to this class, so students can see and enroll
      // in them. Only in root's own (signed) reply — never a
      // co-teacher's or a classmate's.
      if (role == ShareRole.teacher && !served.isDelegate)
        'catalog': [
          for (final s in await dao.ownSubjects(classUuid: uuid))
            {'id': s.subjectId, 'name': s.name, 'icon': s.icon, 'color': s.color,
            },
        ],
      // Forwarded verbatim, whichever device this reply comes from — its
      // own signature is what makes it trustworthy, not who's relaying it.
      if (served.rosterJson != null) 'roster': jsonDecode(served.rosterJson!),
      // Root only: how many failover takeovers this host identity has had,
      // so students refuse a replaced device (see ClassGroups.hostEpoch).
      if (role == ShareRole.teacher && !served.isDelegate)
        'host_epoch': (await dao.identity()).hostGeneration,
    };
  }

  /// Root only: stores the members' progress a student device sent. Never
  /// reached for a delegated class — [_sync] refuses [kReportPath] first.
  Future<Map<String, Object?>?> _report(
    _ServedClass served,
    String classKey,
    String nonce,
    Object? sealed,
  ) async {
    final opened = await openReport(
      classKey: classKey,
      requestNonce: nonce,
      sealed: sealed,
    );
    if (opened is! List) return null;
    final reports = [
      for (final r in opened.take(kMaxReportsPerDevice))
        if (ProgressReport.fromJson(r) case final report?) report,
    ];
    await _db.classSyncDao.saveMemberReports(served.groupUuid, reports);
    // Each learner's answers to this device's assignments, and back the
    // grades of exactly those answers — never anyone else's.
    final assignments = ClassAssignments(_db);
    final grades = <GradePayload>[];
    final received = <String>[];
    for (final r in reports) {
      grades.addAll(
        await assignments.receive(
          classUuid: served.groupUuid,
          memberKey: r.memberKey,
          learnerName: r.name,
          submissions: r.submissions,
        ),
      );
      received.addAll(
        await assignments.heldFrom(r.memberKey, [
          for (final s in r.submissions) s.uuid,
        ]),
      );
    }
    // Extra help for exactly the learners that device reported.
    final support = await LearnerSupportService(_db,
    ).outgoing(
      served.groupUuid,
      [for (final r in reports) r.memberKey]);
    return {
      'saved': reports.length,
      'grades': [for (final g in grades) g.toJson()],
      // Answers this device now holds, so the learner's device can say so.
      'received': received,
      if (support.isNotEmpty) 'support': [for (final i in support) i.toJson()],
    };
  }

  /// Records which version of each subject [deviceKey] holds.
  Future<Map<String, Object?>?> _ack(
    _ServedClass served,
    String deviceKey,
    Object? held,
  ) async {
    if (held is! Map) return null;
    return {
      'kept': await _devices.recordHeld(served.groupUuid, deviceKey, held),
    };
  }

  Future<Map<String, Object?>?> _channel(
    _ServedClass served,
    Object? subject,
  ) async {
    if (subject is! String || subject.isEmpty) return null;
    if (served.allocatedSubjects != null &&
        !served.allocatedSubjects!.contains(subject)) {
      // Defense in depth: sharedChunks already returns nothing for a
      // subject this device never wrote/shared, but a delegate must never
      // serve a subject outside its allocation even if that changed.
      return null;
    }
    final channel = await _cachedChannel(served.groupUuid, subject);
    return {
      'subject_id': subject,
      'digest': channel.digest,
      'chunks': [for (final e in channel.chunks) e.toJson()],
    };
  }

  /// The PDF [sha] of [subject], if a note in that channel records it and
  /// this device has the file: the whole file, or with [offset] the part
  /// from there (at most [length], capped at [kFileChunkBytes]) and the
  /// file's total size, so the requester can carry on after a break.
  Future<Map<String, Object?>?> _noteFile(
    _ServedClass served,
    Object? subject,
    Object? sha, {
    Object? offset,
    Object? length,
  }) async {
    if (offset != null && (offset is! int || offset < 0)) return null;
    if (subject is! String || sha is! String || sha.length != 64) return null;
    if (served.allocatedSubjects != null &&
        !served.allocatedSubjects!.contains(subject)) {
      return null;
    }
    final channel = await _cachedChannel(served.groupUuid, subject);
    final listed = channel.chunks.any(
      (e) =>
          e.payload['topic_key'] == kPdfMarkerTopic &&
          '${e.payload['content_chunk']}'.contains('sha256=$sha '),
    );
    if (!listed) return null;
    // One file at a time: thirty students' first sync must not hold thirty
    // PDFs in a 4 GB phone's memory at once.
    final previous = _fileTurn;
    final done = Completer<void>();
    _fileTurn = done.future;
    await previous;
    try {
      final file = await pdfStore.fileFor(sha);
      if (file == null) return null;
      final path = file.path;
      if (offset is int) {
        final want = length is int && length > 0 && length < kFileChunkBytes
            ? length
            : kFileChunkBytes;
        final part = await Isolate.run(() {
          final raf = File(path).openSync();
          try {
            final total = raf.lengthSync();
            if (total > kMaxNotePdfBytes || offset > total) return null;
            raf.setPositionSync(offset);
            return (total: total, data: base64Encode(raf.readSync(want)));
          } finally {
            raf.closeSync();
          }
        });
        if (part == null) return null;
        return {
          'sha256': sha,
          'offset': offset,
          'total': part.total,
          'data': part.data,
        };
      }
      final data = await Isolate.run(() {
        final bytes = File(path).readAsBytesSync();
        return bytes.length > kMaxNotePdfBytes ? null : base64Encode(bytes);
      });
      if (data == null) return null;
      return {'sha256': sha, 'data': data};
    } catch (_) {
      return null;
    } finally {
      done.complete();
    }
  }

  /// Completes when the PDF being served before this one is out.
  Future<void> _fileTurn = Future.value();

  /// [subject]'s channel of [classUuid] as this device serves it in its
  /// role: its own shared notes (teacher), or the received copy (classmate).
  Future<({List<ResourceChunkEnvelope> chunks, String digest})> _cachedChannel(
    String classUuid,
    String subject,
  ) async {
    final key = '$classUuid/$subject';
    final hit = _channelCache[key];
    if (hit != null) return hit;
    final gen = _cacheGen;
    final rows = role == ShareRole.teacher
        ? await _db.classSyncDao.sharedChunks(classUuid, subject)
        : await _db.classSyncDao.receivedChunks(classUuid, subject);
    final chunks = await _envelopes(classUuid, rows);
    final built = (
      chunks: chunks,
      digest: await channelDigest(chunks.map((e) => e.chunkId)),
    );
    if (gen == _cacheGen) _channelCache[key] = built;
    return built;
  }

  /// Envelopes for [rows]. A received row stores exactly the payload the
  /// teacher sent, so a classmate's envelope hashes to the teacher's
  /// chunk id — which is what lets the next device check it.
  Future<List<ResourceChunkEnvelope>> _envelopes(
    String classUuid,
    List<TopicResource> rows,
  ) async => [
    for (final r in rows)
      ResourceChunkEnvelope.forChannel(
        classGroupUuid: classUuid,
        subjectId: r.subjectId,
        topicKey: r.topicKey,
        termMarker: r.termMarker,
        resourceTitle: r.resourceTitle,
        contentChunk: r.contentChunk,
        createdAt: r.createdAt,
        updatedAt: r.updatedAt,
        documentTitle: r.documentTitle,
      ),
  ];

  Response _json(Object body) => Response.ok(
    jsonEncode(body),
    headers: const {'content-type': 'application/json'},
  );
}
