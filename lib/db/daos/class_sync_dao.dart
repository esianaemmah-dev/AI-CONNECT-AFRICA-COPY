import 'dart:convert';

import 'package:drift/drift.dart';

import '../../collaboration/sync/class_crypto.dart';
import '../../collaboration/sync/progress_report.dart';
import '../../collaboration/sync/sync_ids.dart';
import '../otic_database.dart';
import '../note_document_title.dart';
import '../tables/class_groups_table.dart';
import '../tables/custom_subjects_table.dart';
import '../tables/learner_subjects_table.dart';
import '../tables/member_reports_table.dart';
import '../tables/resource_shares_table.dart';
import '../tables/served_channels_table.dart';
import '../tables/sync_identity_table.dart';
import '../tables/sync_state_table.dart';
import '../tables/topic_resources_table.dart';

part 'class_sync_dao.g.dart';

/// Everything class sync decides "who gets what" from.
///
/// The serving rule lives in one query, [sharedChunks]: a chunk goes to a
/// class only if it was written on this device (not received from another
/// teacher) *and* its note has an explicit share row for that class. Notes
/// nobody shared, and notes this device received, are never served.
@DriftAccessor(
  tables: [
    ClassGroups,
    ResourceShares,
    SyncIdentity,
    TopicResources,
    SyncState,
    ServedChannels,
    MemberReports,
    CustomSubjects,
    LearnerSubjects,
  ],
)
class ClassSyncDao extends DatabaseAccessor<OticDatabase>
    with _$ClassSyncDaoMixin {
  ClassSyncDao(super.db);

  // ── This device ─────────────────────────────────────────────────────────

  /// This device's identity, creating its signing key the first time.
  Future<SyncIdentityData> identity() async {
    final row = await (select(
      syncIdentity,
    )..where((t) => t.id.equals(1))).getSingleOrNull();
    if (row != null) return row;
    await into(syncIdentity).insert(
      SyncIdentityCompanion.insert(
        id: const Value(1),
        signingSeed: newSigningSeed(),
      ),
      mode: InsertMode.insertOrIgnore,
    );
    return (select(syncIdentity)..where((t) => t.id.equals(1))).getSingle();
  }

  /// A joined class's new key, handed over after the teacher revoked a
  /// device. Never touches a class this device serves.
  Future<ClassGroup?> replaceJoinedClassKey(int classId, String key) async {
    await (update(classGroups)
          ..where((t) => t.id.equals(classId) & t.joined.equals(true)))
        .write(ClassGroupsCompanion(classKey: Value(key)));
    return (select(classGroups)
          ..where((t) => t.id.equals(classId) & t.joined.equals(true)))
        .getSingleOrNull();
  }

  /// The version of each of [classUuid]'s subjects this device holds from
  /// [signer] (root's key also covers rows from before signers were kept).
  Future<Map<String, int>> heldVersions(
    String classUuid,
    String signer,
  ) async => {
    for (final r
        in await (select(syncState)
              ..where((t) => t.classGroupUuid.equals(classUuid))
              ..where((t) => t.channelDigest.isNotNull())
              ..where((t) => t.channelVersion.isNotNull())
              ..where(
                (t) =>
                    t.manifestSigner.isNull() | t.manifestSigner.equals(signer),
              ))
            .get())
      r.subjectId: r.channelVersion!,
  };

  Stream<SyncIdentityData?> watchIdentity() =>
      (select(syncIdentity)..where((t) => t.id.equals(1))).watchSingleOrNull();

  /// Names this device's school (Admin). Renaming keeps the school's id, so
  /// classes already joined stay valid.
  Future<void> setSchoolName(String name) async {
    final me = await identity();
    await (update(syncIdentity)..where((t) => t.id.equals(1))).write(
      SyncIdentityCompanion(
        schoolId: Value(me.schoolId ?? newSyncId()),
        schoolName: Value(name.trim()),
      ),
    );
  }

  // ── This device's role ──────────────────────────────────────────────────

  /// [kRoleTeacher], [kRoleStudent], or null (undecided): what this device
  /// did first, kept as a record only. Nothing is gated on it — every
  /// device can teach and join classes; teachers are told apart by their
  /// profiles (`teacher_profiles`).
  Future<String?> deviceRole() async => (await identity()).deviceRole;

  Stream<String?> watchDeviceRole() =>
      watchIdentity().map((row) => row?.deviceRole);

  /// Makes this the teacher device. False on a student device — a device
  /// that joined a class through a teacher can't claim the class.
  Future<bool> claimTeacherRole() async {
    final role = await deviceRole();
    if (role == kRoleStudent) return false;
    if (role == kRoleTeacher) return true;
    await (update(syncIdentity)..where((t) => t.id.equals(1))).write(
      const SyncIdentityCompanion(deviceRole: Value(kRoleTeacher)),
    );
    return true;
  }

  /// Marks this a student device, on its first join through a teacher.
  /// Never overwrites a role already recorded.
  Future<void> becomeStudentDevice() async {
    if (await deviceRole() != null) return;
    await (update(syncIdentity)..where((t) => t.id.equals(1))).write(
      const SyncIdentityCompanion(deviceRole: Value(kRoleStudent)),
    );
  }

  /// A student device takes its school from the first class it joins.
  Future<void> adoptSchool({
    required String schoolId,
    required String schoolName,
  }) async {
    final me = await identity();
    if (me.schoolId != null) return;
    await (update(syncIdentity)..where((t) => t.id.equals(1))).write(
      SyncIdentityCompanion(
        schoolId: Value(schoolId),
        schoolName: Value(schoolName),
      ),
    );
  }

  // ── Classes ─────────────────────────────────────────────────────────────

  /// Classes this device created — the only ones it may ever serve or
  /// share notes with.
  Future<List<ClassGroup>> ownedClasses() =>
      (select(classGroups)
            ..where((t) => t.joined.equals(false) & t.groupUuid.isNotNull())
            ..orderBy([
              (t) => OrderingTerm.asc(t.className),
              (t) => OrderingTerm.asc(t.streamName),
            ]))
          .get();

  /// Classes this device joined as a student.
  Future<List<ClassGroup>> joinedClasses() =>
      (select(classGroups)..where((t) => t.joined.equals(true))).get();

  Stream<List<ClassGroup>> watchOwnedClasses() =>
      (select(classGroups)
            ..where((t) => t.joined.equals(false) & t.groupUuid.isNotNull())
            ..orderBy([
              (t) => OrderingTerm.asc(t.className),
              (t) => OrderingTerm.asc(t.streamName),
            ]))
          .watch();

  Future<ClassGroup?> ownedByUuid(String uuid) =>
      (select(classGroups)
            ..where((t) => t.groupUuid.equals(uuid) & t.joined.equals(false)))
          .getSingleOrNull();

  /// A class this device joined through its teacher, with everything a
  /// classmate share needs (key, school, pinned teacher key). Null otherwise.
  Future<ClassGroup?> joinedByUuid(String uuid) async {
    final g =
        await (select(classGroups)
              ..where((t) => t.groupUuid.equals(uuid) & t.joined.equals(true)))
            .getSingleOrNull();
    if (g == null ||
        g.classKey == null ||
        g.schoolId == null ||
        g.teacherPublicKey == null) {
      return null;
    }
    return g;
  }

  /// Gives an owned class its key and school the first time it's synced.
  ///
  /// Re-reads the row first: [group] may be a copy from before the key was
  /// minted, and minting a second key would lock out every student who
  /// already joined with the first.
  Future<ClassGroup> ensureClassKey(ClassGroup stale) async {
    final group = await (select(
      classGroups,
    )..where((t) => t.id.equals(stale.id))).getSingle();
    if (group.classKey != null && group.schoolId != null) return group;
    final me = await identity();
    await (update(classGroups)..where((t) => t.id.equals(group.id))).write(
      ClassGroupsCompanion(
        classKey: Value(group.classKey ?? newClassKey()),
        schoolId: Value(group.schoolId ?? me.schoolId),
      ),
    );
    return (select(
      classGroups,
    )..where((t) => t.id.equals(group.id))).getSingle();
  }

  /// True when this device serves [groupUuid] to others: it has shared a
  /// note or served a channel for it. A class row alone (the Admin's records
  /// put every class on every device) does not make a device its teacher.
  Future<bool> hostsClass(String groupUuid) async {
    final shared = await (select(resourceShares)
          ..where((t) => t.classGroupUuid.equals(groupUuid))
          ..limit(1))
        .get();
    if (shared.isNotEmpty) return true;
    final served = await (select(servedChannels)
          ..where((t) => t.classGroupUuid.equals(groupUuid))
          ..limit(1))
        .get();
    return served.isNotEmpty;
  }

  /// Records a class joined from a teacher (student device). Returns null
  /// when this device itself owns a class with that id — it is the teacher.
  Future<ClassGroup?> upsertJoinedClass({
    required String groupUuid,
    required String className,
    String? streamName,
    required String schoolId,
    required String classKey,
    required String teacherPublicKey,
  }) async {
    final existing = await (select(
      classGroups,
    )..where((t) => t.groupUuid.equals(groupUuid))).getSingleOrNull();
    final values = ClassGroupsCompanion(
      className: Value(className),
      streamName: Value(streamName),
      schoolId: Value(schoolId),
      classKey: Value(classKey),
      teacherPublicKey: Value(teacherPublicKey),
      joined: const Value(true),
    );
    if (existing != null) {
      // A row the Admin's records created is not "hosted" until something is
      // shared from it, so a learner's device may still join that class.
      if (!existing.joined && await hostsClass(groupUuid)) return null;
      await (update(
        classGroups,
      )..where((t) => t.id.equals(existing.id))).write(values);
    } else {
      await into(
        classGroups,
      ).insert(values.copyWith(groupUuid: Value(groupUuid)));
    }
    return (select(
      classGroups,
    )..where((t) => t.groupUuid.equals(groupUuid))).getSingle();
  }

  // ── Shares (teacher device) ─────────────────────────────────────────────

  /// Classes each note of [subjectId] is shared with, keyed by the note's
  /// document title (what the teacher's list shows).
  Stream<Map<String, Set<String>>> watchSharesForSubject(String subjectId) =>
      (select(
        resourceShares,
      )..where((t) => t.subjectId.equals(subjectId))).watch().map((rows) {
        final out = <String, Set<String>>{};
        for (final r in rows) {
          (out[r.documentTitle] ??= {}).add(r.classGroupUuid);
        }
        return out;
      });

  /// Shares one note — a whole uploaded file, every section of it — with
  /// exactly [classUuids]. Only classes this device may serve that subject
  /// to are kept, whatever the caller passes: classes it owns (any
  /// subject), and classes it co-teaches (only the subjects it's allocated
  /// there). Enforced here, not just in the picker, so a stale screen can't
  /// share outside this device's lane.
  Future<void> setShares({
    required String subjectId,
    required String documentTitle,
    required Set<String> classUuids,
  }) async {
    final owned = {
      for (final c in await ownedClasses()) c.groupUuid!,
      for (final d in await attachedDatabase.coTeacherDao.delegatedClasses())
        if ((jsonDecode(d.subjectIdsJson) as List).contains(subjectId))
          d.classGroupUuid,
    };
    await transaction(() async {
      await customUpdate(
        'DELETE FROM resource_shares WHERE subject_id = ? '
        'AND (document_title = ? OR document_title IN ('
        'SELECT resource_title FROM topic_resources WHERE subject_id = ? '
        'AND class_group_uuid IS NULL AND document_title IS NULL '
        'AND ${noteDocumentTitleSql()} = ?))',
        variables: [
          Variable.withString(subjectId),
          Variable.withString(documentTitle),
          Variable.withString(subjectId),
          Variable.withString(documentTitle),
        ],
        updates: {resourceShares},
      );
      for (final uuid in classUuids.intersection(owned)) {
        await into(resourceShares).insert(
          ResourceSharesCompanion.insert(
            subjectId: subjectId,
            documentTitle: documentTitle,
            classGroupUuid: uuid,
          ),
        );
      }
    });
  }

  // ── Serving (teacher device) ────────────────────────────────────────────

  static final _servedJoin =
      'FROM topic_resources t '
      'JOIN resource_shares s '
      '  ON s.subject_id = t.subject_id '
      '  AND (s.document_title = ${noteDocumentTitleSql(alias: 't')} '
      '       OR s.document_title = COALESCE(t.document_title, t.resource_title)) '
      'WHERE s.class_group_uuid = ? '
      // Written here, not received from another device: received notes are
      // never passed on.
      '  AND t.class_group_uuid IS NULL';

  /// Subjects [classUuid] has at least one shared note in.
  Future<List<String>> sharedSubjects(String classUuid) async {
    final rows = await customSelect(
      'SELECT DISTINCT t.subject_id AS subject_id $_servedJoin ORDER BY t.subject_id',
      variables: [Variable.withString(classUuid)],
      readsFrom: {topicResources, resourceShares},
    ).get();
    return [for (final r in rows) r.read<String>('subject_id')];
  }

  /// Every chunk [classUuid] may receive in [subjectId].
  Future<List<TopicResource>> sharedChunks(
    String classUuid,
    String subjectId,
  ) async {
    final rows = await customSelect(
      'SELECT DISTINCT t.* $_servedJoin AND t.subject_id = ? ORDER BY t.id',
      variables: [
        Variable.withString(classUuid),
        Variable.withString(subjectId),
      ],
      readsFrom: {topicResources, resourceShares},
    ).get();
    return [for (final r in rows) topicResources.map(r.data)];
  }

  /// The version to sign [subjectId]'s channel of [classUuid] with, now that
  /// its digest is [digest]. Goes up by one whenever the digest changes, and
  /// never down — see [ServedChannels].
  Future<int> servedVersion(
    String classUuid,
    String subjectId,
    String digest,
  ) => transaction(() async {
    final row = await _served(classUuid, subjectId);
    if (row == null) {
      // A host that took over (failover) starts new channels above every
      // version the replaced device could have signed.
      final first = generationFloor((await identity()).hostGeneration) + 1;
      await into(servedChannels).insert(
        ServedChannelsCompanion.insert(
          classGroupUuid: classUuid,
          subjectId: subjectId,
          digest: Value(digest),
          version: first,
        ),
      );
      return first;
    }
    if (row.digest == digest) return row.version;
    await (update(servedChannels)..where((t) => t.id.equals(row.id))).write(
      ServedChannelsCompanion(
        digest: Value(digest),
        version: Value(row.version + 1),
      ),
    );
    return row.version + 1;
  });

  /// Marks every channel of [classUuid] no longer in [shared] as removed,
  /// with a new version — so re-sharing it later is newer still, and a
  /// classmate's old copy of it is never newer than the removal.
  Future<void> retireUnshared(String classUuid, Set<String> shared) =>
      transaction(() async {
        final rows =
            await (select(servedChannels)..where(
                  (t) =>
                      t.classGroupUuid.equals(classUuid) & t.digest.isNotNull(),
                ))
                .get();
        for (final r in rows.where((r) => !shared.contains(r.subjectId))) {
          await (update(servedChannels)..where((t) => t.id.equals(r.id))).write(
            ServedChannelsCompanion(
              digest: const Value(null),
              version: Value(r.version + 1),
            ),
          );
        }
      });

  Future<ServedChannel?> _served(String classUuid, String subjectId) =>
      (select(servedChannels)..where(
            (t) =>
                t.classGroupUuid.equals(classUuid) &
                t.subjectId.equals(subjectId),
          ))
          .getSingleOrNull();

  // ── Subjects the teacher offers ─────────────────────────────────────────

  /// Subjects made on this device — the list a class's host sends with
  /// every sync. For [classUuid], only the subjects the Admin assigned a
  /// teacher to teach that class; every subject while the class has no
  /// assignments yet.
  Future<List<CustomSubject>> ownSubjects({String? classUuid}) async {
    final all =
        await (select(customSubjects)
              ..where((t) => t.classGroupUuid.isNull())
              ..orderBy([(t) => OrderingTerm.asc(t.name)]))
            .get();
    if (classUuid == null) return all;
    final taught = {
      for (final a in await (select(
        db.teachingAssignments,
      )..where((t) => t.classGroupUuid.equals(classUuid))).get())
        a.subjectId,
    };
    if (taught.isEmpty) return all;
    return [
      for (final s in all)
        if (taught.contains(s.subjectId)) s,
    ];
  }

  /// Replaces the subjects [classUuid]'s teacher offers with [offered], in
  /// one transaction. A subject this device made itself is never touched,
  /// and one already received from another class keeps its row.
  Future<void> replaceReceivedSubjects(
    String classUuid,
    List<({String id, String name, String icon, String color})> offered,
  ) => transaction(() async {
    final keep = {for (final s in offered) s.id};
    await (delete(customSubjects)..where(
          (t) => t.classGroupUuid.equals(classUuid) & t.subjectId.isNotIn(keep),
        ))
        .go();
    final at = DateTime.now().toUtc().toIso8601String();
    for (final s in offered) {
      final existing = await (select(
        customSubjects,
      )..where((t) => t.subjectId.equals(s.id))).getSingleOrNull();
      if (existing == null) {
        await into(customSubjects).insert(
          CustomSubjectsCompanion.insert(
            subjectId: s.id,
            name: s.name,
            icon: Value(s.icon),
            color: Value(s.color),
            createdAt: at,
            classGroupUuid: Value(classUuid),
          ),
        );
      } else if (existing.classGroupUuid == classUuid) {
        await (update(
          customSubjects,
        )..where((t) => t.id.equals(existing.id))).write(
          CustomSubjectsCompanion(
            name: Value(s.name),
            icon: Value(s.icon),
            color: Value(s.color),
          ),
        );
      }
    }
  });

  // ── Subjects a learner takes ────────────────────────────────────────────

  Stream<Set<String>> watchEnrolled(int studentId) =>
      (select(learnerSubjects)..where((t) => t.studentId.equals(studentId)))
          .watch()
          .map((rows) => {for (final r in rows) r.subjectId});

  /// Subjects whose notes [studentId] may read: those they registered for
  /// in My subjects (classes joined through a teacher), plus every subject
  /// taught to the class the Admin enrolled them in.
  Stream<Set<String>> watchReadable(int studentId) => customSelect(
    'SELECT subject_id FROM learner_subjects WHERE student_id = ?1 '
    'UNION '
    'SELECT t.subject_id FROM teaching_assignments t '
    'JOIN student_enrolments e ON e.class_group_uuid = t.class_group_uuid '
    "WHERE e.student_id = ?1 AND e.status = 'active'",
    variables: [Variable.withInt(studentId)],
    readsFrom: {
      learnerSubjects,
      attachedDatabase.teachingAssignments,
      attachedDatabase.studentEnrolments,
    },
  ).watch().map((rows) => {for (final r in rows) r.read<String>('subject_id')});

  Future<List<String>> enrolledSubjects(int studentId) async => [
    for (final r
        in await (select(learnerSubjects)
              ..where((t) => t.studentId.equals(studentId))
              ..orderBy([(t) => OrderingTerm.asc(t.id)]))
            .get())
      r.subjectId,
  ];

  Future<void> setEnrolled(
    int studentId,
    String subjectId,
    bool enrolled,
  ) async {
    if (!enrolled) {
      await (delete(learnerSubjects)..where(
            (t) =>
                t.studentId.equals(studentId) & t.subjectId.equals(subjectId),
          ))
          .go();
      return;
    }
    await into(learnerSubjects).insert(
      LearnerSubjectsCompanion.insert(
        studentId: studentId,
        subjectId: subjectId,
        enrolledAt: DateTime.now().toUtc().toIso8601String(),
      ),
      mode: InsertMode.insertOrIgnore,
    );
  }

  // ── Members' progress (teacher device) ──────────────────────────────────

  /// Stores each learner's latest report, replacing their previous one —
  /// all in one transaction, so a class list never shows half a sync.
  Future<void> saveMemberReports(
    String classUuid,
    List<ProgressReport> reports,
  ) => transaction(() async {
    final at = DateTime.now().toUtc().toIso8601String();
    for (final r in reports) {
      await into(memberReports).insert(
        MemberReportsCompanion.insert(
          classGroupUuid: classUuid,
          memberKey: r.memberKey,
          name: r.name,
          reportJson: jsonEncode(r.toJson()),
          receivedAt: at,
        ),
        onConflict: DoUpdate(
          (_) => MemberReportsCompanion(
            name: Value(r.name),
            reportJson: Value(jsonEncode(r.toJson())),
            receivedAt: Value(at),
          ),
          target: [memberReports.classGroupUuid, memberReports.memberKey],
        ),
      );
    }
  });

  /// Every member's latest report for [classUuid], by name.
  Stream<List<({ProgressReport report, String receivedAt})>> watchMemberReports(
    String classUuid,
  ) =>
      (select(memberReports)
            ..where((t) => t.classGroupUuid.equals(classUuid))
            ..orderBy([(t) => OrderingTerm.asc(t.name)]))
          .watch()
          .map(
            (rows) => [
              for (final r in rows)
                if (_report(r.reportJson) case final report?)
                  (report: report, receivedAt: r.receivedAt),
            ],
          );

  /// Each member's device clock offset from this device's, as measured
  /// when their latest report arrived (any class), by member key.
  Stream<Map<String, Duration>> watchClockOffsets() =>
      select(memberReports).watch().map(
        (rows) => {
          for (final r in rows)
            if (_report(r.reportJson)?.clockOffset(r.receivedAt)
                case final offset?)
              r.memberKey: offset,
        },
      );

  static ProgressReport? _report(String json) {
    try {
      return ProgressReport.fromJson(jsonDecode(json));
    } catch (_) {
      return null;
    }
  }

  // ── Receiving (student device) ──────────────────────────────────────────

  /// This device's record of one channel: digest, the teacher's version and
  /// signature. Null when it never had the channel.
  Future<SyncStateData?> channelState(String classUuid, String subjectId) =>
      (select(syncState)..where(
            (t) =>
                t.classGroupUuid.equals(classUuid) &
                t.subjectId.equals(subjectId),
          ))
          .getSingleOrNull();

  Future<String?> channelDigestFor(String classUuid, String subjectId) async =>
      (await channelState(classUuid, subjectId))?.channelDigest;

  /// Channels of [classUuid] this device holds with the teacher's signature
  /// — what it can pass on to a classmate. Tombstones are not offered.
  Future<List<SyncStateData>> relayableChannels(String classUuid) =>
      (select(syncState)..where(
            (t) =>
                t.classGroupUuid.equals(classUuid) &
                t.channelDigest.isNotNull() &
                t.channelVersion.isNotNull() &
                t.manifestSig.isNotNull(),
          ))
          .get();

  /// The chunks this device received for one channel, in arrival order —
  /// passed on to a classmate exactly as the teacher sent them.
  Future<List<TopicResource>> receivedChunks(
    String classUuid,
    String subjectId,
  ) =>
      (select(topicResources)
            ..where(
              (t) =>
                  t.classGroupUuid.equals(classUuid) &
                  t.subjectId.equals(subjectId),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();

  /// Replaces this device's copy of one class+subject channel in one
  /// transaction — edits and removals on the teacher's side arrive as-is,
  /// with no duplicates left behind. [version] and [manifestSig] are the
  /// signer's, kept so the channel can be passed on. [signer] and
  /// [signerVersionsJson] feed the per-signer version floor (see
  /// `sync_state.signer_versions_json`) — pass the map already bumped for
  /// this acceptance; computing it is the caller's job
  /// ([SelectiveSyncManager] via [decodeSignerVersions]/[bumpSignerVersion]),
  /// since accepting the manifest and persisting the floor must agree.
  Future<void> replaceChannel({
    required String classUuid,
    required String subjectId,
    required List<TopicResourcesCompanion> rows,
    required String digest,
    int? version,
    String? manifestSig,
    String? signer,
    String? signerVersionsJson,
  }) => transaction(() async {
    await (delete(topicResources)..where(
          (t) =>
              t.classGroupUuid.equals(classUuid) &
              t.subjectId.equals(subjectId),
        ))
        .go();
    for (var i = 0; i < rows.length; i += 50) {
      await batch(
        (b) => b.insertAll(
          topicResources,
          rows.sublist(i, (i + 50).clamp(0, rows.length)),
        ),
      );
    }
    final at = DateTime.now().toUtc().toIso8601String();
    await into(syncState).insert(
      SyncStateCompanion.insert(
        classGroupUuid: classUuid,
        subjectId: subjectId,
        lastSyncedAt: at,
        channelDigest: Value(digest),
        channelVersion: Value(version),
        manifestSig: Value(manifestSig),
        manifestSigner: Value(signer),
        signerVersionsJson: Value(signerVersionsJson),
      ),
      onConflict: DoUpdate(
        (_) => SyncStateCompanion(
          lastSyncedAt: Value(at),
          channelDigest: Value(digest),
          channelVersion: Value(version),
          manifestSig: Value(manifestSig),
          manifestSigner: Value(signer),
          signerVersionsJson: Value(signerVersionsJson),
        ),
        target: [syncState.classGroupUuid, syncState.subjectId],
      ),
    );
  });

  /// Records a signer's version and signature for a channel whose notes are
  /// already current here (same digest) — e.g. a copy synced before
  /// channels were signed, which could not otherwise be passed on.
  Future<void> updateManifest({
    required String classUuid,
    required String subjectId,
    required int version,
    required String manifestSig,
    String? signer,
    String? signerVersionsJson,
  }) =>
      (update(syncState)..where(
            (t) =>
                t.classGroupUuid.equals(classUuid) &
                t.subjectId.equals(subjectId),
          ))
          .write(
            SyncStateCompanion(
              channelVersion: Value(version),
              manifestSig: Value(manifestSig),
              manifestSigner: Value(signer),
              signerVersionsJson: Value(signerVersionsJson),
            ),
          );

  /// Drops channels of [classUuid] currently attributed to [signer] that
  /// aren't in [keepSubjects] — a signer's own "I no longer share this"
  /// (an ordinary unshare, or a subject reassigned away by a roster
  /// change), scoped so it never touches a channel another signer (root, or
  /// a different co-teacher) currently owns. [treatNullSignerAsThis] is set
  /// only when [signer] is root's own key: a channel predating co-teachers
  /// has no recorded signer at all, and such a channel is always root's.
  ///
  /// Only a sync straight with [signer]'s own device may call this — a
  /// classmate's list of subjects says nothing about what any signer still
  /// shares. The channel's sync_state row stays behind as a tombstone (no
  /// digest, version and signer-floor kept), so an older copy can't bring
  /// it back.
  Future<int> dropChannelsForSigner(
    String classUuid,
    String signer,
    Set<String> keepSubjects, {
    bool treatNullSignerAsThis = false,
  }) => transaction(() async {
    final rows =
        await (select(syncState)..where(
              (t) =>
                  t.classGroupUuid.equals(classUuid) &
                  t.channelDigest.isNotNull(),
            ))
            .get();
    final gone = rows
        .where(
          (r) =>
              r.manifestSigner == signer ||
              (r.manifestSigner == null && treatNullSignerAsThis),
        )
        .map((r) => r.subjectId)
        .toSet();
    if (treatNullSignerAsThis) {
      // Pre-co-teacher safety net: content stored with no sync_state row at
      // all yet (shouldn't normally happen, but this predates that
      // guarantee) is only ever root's to clean up.
      final localSubjects = await customSelect(
        'SELECT DISTINCT subject_id FROM topic_resources WHERE class_group_uuid = ?',
        variables: [Variable.withString(classUuid)],
        readsFrom: {topicResources},
      ).get();
      gone.addAll(localSubjects.map((r) => r.read<String>('subject_id')));
    }
    gone.removeAll(keepSubjects);
    for (final subject in gone) {
      await (delete(topicResources)..where(
            (t) =>
                t.classGroupUuid.equals(classUuid) &
                t.subjectId.equals(subject),
          ))
          .go();
      await (update(syncState)..where(
            (t) =>
                t.classGroupUuid.equals(classUuid) &
                t.subjectId.equals(subject),
          ))
          .write(
            const SyncStateCompanion(
              channelDigest: Value(null),
              manifestSig: Value(null),
            ),
          );
    }
    return gone.length;
  });

  /// Caches a freshly-verified roster on a joined (or owned) class row —
  /// student and classmate devices only ever trust a roster they verified
  /// themselves against root's pinned key; this just persists the result.
  Future<void> cacheRoster(String classUuid, ClassRoster roster) async {
    final g = await (select(
      classGroups,
    )..where((t) => t.groupUuid.equals(classUuid))).getSingleOrNull();
    if (g == null) return;
    await (update(classGroups)..where((t) => t.id.equals(g.id))).write(
      ClassGroupsCompanion(
        rosterVersion: Value(roster.version),
        rosterJson: Value(jsonEncode(roster.toJson())),
      ),
    );
  }

  /// Student device: records that a root-signed handshake for [classUuid]
  /// carried [epoch] — never lowers it (see `ClassGroups.hostEpoch`).
  Future<void> raiseHostEpoch(String classUuid, int epoch) async {
    await customUpdate(
      'UPDATE class_groups SET host_epoch = ? '
      'WHERE group_uuid = ? AND joined = 1 '
      '  AND COALESCE(host_epoch, 0) < ?',
      variables: [
        Variable.withInt(epoch),
        Variable.withString(classUuid),
        Variable.withInt(epoch),
      ],
      updates: {classGroups},
    );
  }

  // ── Co-teacher roster revocation (student/relay device) ─────────────────

  /// Every channel of [classUuid] whose cached signer no longer matches
  /// [signerFor] under [roster] — dropped the same way a signer's own
  /// unshare is, since a revoked co-teacher's content is no longer trusted
  /// regardless of whether the device itself is still reachable.
  Future<int> applyRosterRevocations(
    String classUuid,
    ClassRoster roster,
    String rootPublicKey,
  ) => transaction(() async {
    final rows =
        await (select(syncState)..where(
              (t) =>
                  t.classGroupUuid.equals(classUuid) &
                  t.channelDigest.isNotNull(),
            ))
            .get();
    var dropped = 0;
    for (final r in rows) {
      final currentSigner = r.manifestSigner ?? rootPublicKey;
      final allowedSigner = roster.signerFor(r.subjectId, rootPublicKey);
      if (currentSigner == allowedSigner) continue;
      await (delete(topicResources)..where(
            (t) =>
                t.classGroupUuid.equals(classUuid) &
                t.subjectId.equals(r.subjectId),
          ))
          .go();
      await (update(syncState)..where((t) => t.id.equals(r.id))).write(
        const SyncStateCompanion(
          channelDigest: Value(null),
          manifestSig: Value(null),
        ),
      );
      dropped++;
    }
    return dropped;
  });
}
