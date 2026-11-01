import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../collaboration/cloud/cloud_sync.dart';
import '../../collaboration/sync/sync_ids.dart';
import '../../db/daos/topic_resource_dao.dart'
    show kAssignmentRecordTopicKey, kQuizTopicKey, kRecordTopicPrefix;
import '../../db/otic_database.dart';
import '../../db/providers/db_provider.dart';
import '../notes/note_quiz_store.dart';

/// Topic key of a class assignment's row. Like the PDF marker and quiz
/// rows it is part of a note, so it is signed with the teacher's channel,
/// shared only with the classes the teacher ticks, and never searched.
const kAssignmentTopicKey = kAssignmentRecordTopicKey;

/// The answer a learner may send, at most.
const kMaxAnswerChars = 4000;

/// What a teacher sets: an ordinary assignment, homework, or a holiday
/// assessment.
enum AssignmentKind {
  assignment('Assignment'),
  homework('Homework'),
  holiday('Holiday assessment');

  const AssignmentKind(this.label);
  final String label;

  static AssignmentKind from(Object? name) => values.firstWhere(
    (k) => k.name == name,
    orElse: () => AssignmentKind.assignment,
  );
}

/// Longest time limit a teacher may set, in minutes (one day).
const kMaxAssessmentMinutes = 24 * 60;

/// A teacher's assignment to a class: what learners see and answer.
class ClassAssignment {
  const ClassAssignment({
    required this.id,
    required this.subjectId,
    required this.title,
    required this.instructions,
    required this.maxPoints,
    this.due,
    this.documentTitle = '',
    this.kind = AssignmentKind.assignment,
    this.opensAt,
    this.closesAt,
    this.minutes,
  });

  final String id;
  final String subjectId;
  final String title;
  final String instructions;
  final int maxPoints;

  /// ISO-8601 date, or null.
  final String? due;

  /// The note it travels in.
  final String documentTitle;

  final AssignmentKind kind;

  /// It can't be started before [opensAt] or after [closesAt] (UTC); null
  /// means no limit on that side.
  final DateTime? opensAt;
  final DateTime? closesAt;

  /// Time limit from when the learner starts it; null for none.
  final int? minutes;

  /// Started once, then submitted when the learner is done or the time
  /// runs out — never answered again.
  bool get timed => minutes != null || closesAt != null;

  bool notOpenYet(DateTime now) => opensAt != null && now.isBefore(opensAt!);
  bool closed(DateTime now) => closesAt != null && !now.isBefore(closesAt!);

  /// When an attempt started at [startedAt] must be submitted: the time
  /// limit or the closing time, whichever comes first. Null when neither.
  DateTime? deadlineFor(DateTime startedAt) {
    final byLimit = minutes == null
        ? null
        : startedAt.add(Duration(minutes: minutes!));
    if (byLimit == null) return closesAt;
    if (closesAt == null) return byLimit;
    return byLimit.isBefore(closesAt!) ? byLimit : closesAt;
  }

  /// The signed note row's JSON. New keys are written only when set, so an
  /// ordinary assignment reads exactly as before.
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'instructions': instructions,
    'max': maxPoints,
    'due': due,
    if (kind != AssignmentKind.assignment) 'kind': kind.name,
    if (opensAt != null) 'opens': opensAt!.toUtc().toIso8601String(),
    if (closesAt != null) 'closes': closesAt!.toUtc().toIso8601String(),
    if (minutes != null) 'minutes': minutes,
  };

  String format() => '[ASSIGNMENT] ${jsonEncode(toJson())}';

  static ClassAssignment? parse(TopicResource row) {
    final text = row.contentChunk.trim();
    if (!text.startsWith('[ASSIGNMENT] ')) return null;
    try {
      final j = jsonDecode(text.substring('[ASSIGNMENT] '.length));
      if (j is! Map) return null;
      final id = j['id'], title = j['title'], max = j['max'];
      if (id is! String || title is! String || max is! int || max <= 0) {
        return null;
      }
      DateTime? at(Object? v) =>
          v is String ? DateTime.tryParse(v)?.toUtc() : null;
      final mins = j['minutes'];
      return ClassAssignment(
        id: id,
        subjectId: row.subjectId,
        title: title,
        instructions: j['instructions'] is String
            ? j['instructions'] as String
            : '',
        maxPoints: max,
        due: j['due'] is String ? j['due'] as String : null,
        documentTitle: row.documentTitle ?? row.resourceTitle,
        kind: AssignmentKind.from(j['kind']),
        opensAt: at(j['opens']),
        closesAt: at(j['closes']),
        minutes: mins is int && mins > 0 && mins <= kMaxAssessmentMinutes
            ? mins
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}

/// A submission as it travels in a learner's progress report.
class SubmissionPayload {
  const SubmissionPayload({
    required this.uuid,
    required this.assignmentId,
    required this.subjectId,
    required this.answer,
    required this.createdAt,
    this.startedAt,
    this.tutorUsed,
  });

  SubmissionPayload.fromRow(AssignmentSubmission r)
    : this(
        uuid: r.uuid,
        assignmentId: r.assignmentId,
        subjectId: r.subjectId,
        answer: r.answer,
        createdAt: r.createdAt,
        startedAt: r.startedAt,
        tutorUsed: r.tutorUsed,
      );

  final String uuid;
  final String assignmentId;
  final String subjectId;
  final String answer;
  final String createdAt;

  /// When a timed assessment was started; null when untimed.
  final String? startedAt;

  /// Whether the tutor replied while the learner worked on it; null when
  /// unknown (an older build).
  final bool? tutorUsed;

  Map<String, Object?> toJson() => {
    'uuid': uuid,
    'assignment': assignmentId,
    'subject': subjectId,
    'answer': answer,
    'created_at': createdAt,
    // Only when set, so an untimed answer's report reads as before.
    if (startedAt != null) 'started_at': startedAt,
    if (tutorUsed != null) 'tutor_used': tutorUsed,
  };

  /// Null when [json] isn't one. Clipped, so a device can't bloat the
  /// teacher's database.
  static SubmissionPayload? fromJson(Object? json) {
    if (json is! Map) return null;
    final uuid = json['uuid'], a = json['assignment'], s = json['subject'];
    final answer = json['answer'], at = json['created_at'];
    if (uuid is! String ||
        uuid.isEmpty ||
        uuid.length > 64 ||
        a is! String ||
        a.length > 64 ||
        s is! String ||
        s.length > 60 ||
        answer is! String ||
        at is! String ||
        at.length > 40) {
      return null;
    }
    final started = json['started_at'], tutor = json['tutor_used'];
    return SubmissionPayload(
      uuid: uuid,
      assignmentId: a,
      subjectId: s,
      answer: answer.length > kMaxAnswerChars
          ? answer.substring(0, kMaxAnswerChars)
          : answer,
      createdAt: at,
      startedAt: started is String && started.length <= 40 ? started : null,
      tutorUsed: tutor is bool ? tutor : null,
    );
  }
}

/// A grade as it travels back to the learner's device.
class GradePayload {
  const GradePayload({
    required this.uuid,
    required this.grade,
    required this.version,
    this.feedback,
    this.gradedAt,
  });

  final String uuid;
  final int grade;
  final int version;
  final String? feedback;
  final String? gradedAt;

  Map<String, Object?> toJson() => {
    'uuid': uuid,
    'grade': grade,
    'version': version,
    'feedback': feedback,
    'graded_at': gradedAt,
  };

  static GradePayload? fromJson(Object? json) {
    if (json is! Map) return null;
    final uuid = json['uuid'], grade = json['grade'], v = json['version'];
    if (uuid is! String || grade is! int || v is! int || v <= 0) return null;
    final feedback = json['feedback'];
    return GradePayload(
      uuid: uuid,
      grade: grade,
      version: v,
      feedback: feedback is String
          ? (feedback.length > 1000 ? feedback.substring(0, 1000) : feedback)
          : null,
      gradedAt: json['graded_at'] is String
          ? json['graded_at'] as String
          : null,
    );
  }
}

/// Queues a record for the school cloud plug-in (`cloud_sync.dart`).
typedef CloudRecordSink =
    Future<void> Function(String kind, String refUuid, {String? recordId});

/// Class assignments, submissions and grades.
class ClassAssignments {
  ClassAssignments(this._db, {CloudRecordSink? cloud}) : _cloud = cloud;

  final OticDatabase _db;
  final CloudRecordSink? _cloud;

  /// Reuses checked quiz questions for one practice assignment per note.
  /// It stays local until the teacher chooses to share it with a class.
  Future<String?> prepareNotePractice(
    String subjectId,
    String noteTitle,
  ) => _db.transaction(() async {
    final source =
        await (_db.select(_db.topicResources)
              ..where((t) => t.subjectId.equals(subjectId))
              ..where((t) => t.documentTitle.equals(noteTitle))
              ..where((t) => t.classGroupUuid.isNull())
              ..where((t) => t.topicKey.like('$kRecordTopicPrefix%').not())
              ..limit(1))
            .getSingleOrNull();
    if (source == null) return null;
    final title = 'Practice: $noteTitle';
    final documentTitle = '${AssignmentKind.assignment.label} — $title';
    final existing =
        await (_db.select(_db.topicResources)
              ..where((t) => t.subjectId.equals(subjectId))
              ..where((t) => t.documentTitle.equals(documentTitle))
              ..where((t) => t.classGroupUuid.isNull())
              ..limit(1))
            .getSingleOrNull();
    if (existing != null) return documentTitle;
    final questions = NoteQuizStore.fromRows(
      await (_db.select(_db.topicResources)
            ..where((t) => t.subjectId.equals(subjectId))
            ..where((t) => t.documentTitle.equals(noteTitle))
            ..where((t) => t.classGroupUuid.isNull())
            ..where((t) => t.topicKey.equals(kQuizTopicKey))
            ..orderBy([(t) => OrderingTerm.asc(t.id)])
            ..limit(8))
          .get(),
    );
    if (questions.isEmpty) return null;
    final body = StringBuffer('Answer these questions from $noteTitle.\n\n');
    for (var i = 0; i < questions.length; i++) {
      final q = questions[i].question;
      body.writeln('${i + 1}. ${q.question}');
      for (var j = 0; j < q.options.length; j++) {
        body.writeln('${String.fromCharCode(65 + j)}) ${q.options[j]}');
      }
      body.writeln();
    }
    final saved = await create(
      subjectId: subjectId,
      title: title,
      instructions: body.toString(),
      maxPoints: questions.length,
      termMarker: source.termMarker,
    );
    final owner =
        await (_db.select(_db.noteOwners)
              ..where((t) => t.subjectId.equals(subjectId))
              ..where((t) => t.documentTitle.equals(noteTitle)))
            .getSingleOrNull();
    if (saved != null && owner != null) {
      await _db
          .into(_db.noteOwners)
          .insertOnConflictUpdate(
            NoteOwnersCompanion.insert(
              subjectId: subjectId,
              documentTitle: saved,
              teacherId: owner.teacherId,
            ),
          );
    }
    return saved;
  });

  Future<void> _queue(String kind, String uuid, {String? recordId}) async {
    try {
      await _cloud?.call(kind, uuid, recordId: recordId);
    } catch (_) {
      // The outbox is best-effort; the local record is what counts.
    }
  }

  // ── Teacher ───────────────────────────────────────────────────────────

  /// Writes a new assignment into this device's notes for [subjectId]; the
  /// teacher shares it with classes like any note. Returns its document
  /// title.
  Future<String?> create({
    required String subjectId,
    required String title,
    required String instructions,
    required int maxPoints,
    String? due,
    int termMarker = 0,
    AssignmentKind kind = AssignmentKind.assignment,
    DateTime? opensAt,
    DateTime? closesAt,
    int? minutes,
  }) async {
    final t = title.trim();
    if (t.isEmpty || maxPoints <= 0) return null;
    if (opensAt != null && closesAt != null && !closesAt.isAfter(opensAt)) {
      return null;
    }
    if (minutes != null && (minutes <= 0 || minutes > kMaxAssessmentMinutes)) {
      return null;
    }
    final documentTitle = '${kind.label} — $t';
    final a = ClassAssignment(
      id: newSyncId(),
      subjectId: subjectId,
      title: t,
      instructions: instructions.trim(),
      maxPoints: maxPoints,
      due: due,
      kind: kind,
      opensAt: opensAt?.toUtc(),
      closesAt: closesAt?.toUtc(),
      minutes: minutes,
    );
    final at = DateTime.now().toUtc().toIso8601String();
    await _db
        .into(_db.topicResources)
        .insert(
          TopicResourcesCompanion.insert(
            subjectId: subjectId,
            topicKey: kAssignmentTopicKey,
            termMarker: Value(termMarker),
            resourceTitle: documentTitle,
            contentChunk: a.format(),
            createdAt: at,
            documentTitle: Value(documentTitle),
            updatedAt: Value(at),
          ),
        );
    await _queue(CloudKind.assignment, a.id);
    return documentTitle;
  }

  /// This device's own assignments (the ones it may grade).
  Future<List<ClassAssignment>> own() async => [
    for (final r
        in await (_db.select(_db.topicResources)
              ..where((t) => t.topicKey.equals(kAssignmentTopicKey))
              ..where((t) => t.classGroupUuid.isNull()))
            .get())
      ?ClassAssignment.parse(r),
  ];

  /// Grades a submission. The version goes up by one, so the learner's
  /// device takes it over any earlier grade.
  Future<void> grade(String submissionUuid, int grade, String? feedback) async {
    final row = await (_db.select(
      _db.assignmentSubmissions,
    )..where((t) => t.uuid.equals(submissionUuid))).getSingleOrNull();
    if (row == null) return;
    final version = row.gradeVersion + 1;
    await (_db.update(
      _db.assignmentSubmissions,
    )..where((t) => t.id.equals(row.id))).write(
      AssignmentSubmissionsCompanion(
        grade: Value(grade),
        feedback: Value(feedback?.trim().isEmpty ?? true ? null : feedback),
        gradeVersion: Value(version),
        gradedAt: Value(DateTime.now().toUtc().toIso8601String()),
      ),
    );
    await _queue(
      CloudKind.grade,
      submissionUuid,
      recordId: 'grade:$submissionUuid:$version',
    );
  }

  Stream<List<AssignmentSubmission>> watchSubmissions(String assignmentId) =>
      (_db.select(_db.assignmentSubmissions)
            ..where((t) => t.assignmentId.equals(assignmentId))
            ..orderBy([(t) => OrderingTerm.asc(t.learnerName)]))
          .watch();

  // ── Learner ───────────────────────────────────────────────────────────

  /// Assignments a learner in [classUuid] may see: this device's own, and
  /// those received for their class.
  Future<List<ClassAssignment>> visible(String? classUuid) async => [
    for (final r
        in await (_db.select(_db.topicResources)
              ..where((t) => t.topicKey.equals(kAssignmentTopicKey))
              ..where(
                (t) => classUuid == null
                    ? t.classGroupUuid.isNull()
                    : t.classGroupUuid.isNull() |
                          t.classGroupUuid.equals(classUuid),
              ))
            .get())
      ?ClassAssignment.parse(r),
  ];

  /// Saves [student]'s answer. A new answer is a new submission; nothing
  /// earlier is overwritten. A timed assessment takes one submission only,
  /// stamped with when its attempt started, and [auto] (time ran out)
  /// submits even an empty answer so the teacher sees it was not done.
  /// Returns false when nothing was saved.
  Future<bool> submit({
    required Student student,
    required ClassAssignment assignment,
    required String answer,
    required String memberKey,
    bool auto = false,
    DateTime? now,
  }) async {
    final text = answer.trim();
    if (text.isEmpty && !auto) return false;
    final at = now ?? DateTime.now();
    String? startedAt;
    final attempt = await this.attempt(student.id, assignment.id);
    if (assignment.timed) {
      if (await _submitted(student.id, assignment.id)) return false;
      // Closed and never started: nothing to hand in.
      if (attempt == null && assignment.closed(at)) return false;
      startedAt = attempt?.startedAt ?? at.toUtc().toIso8601String();
    }
    // The tutor's first reply since the learner started (timed) or first
    // saw it (untimed), up to the hand-in. Unknown without that record.
    final tutorAt = DateTime.tryParse(attempt?.tutorAt ?? '');
    final bool? tutorUsed = attempt == null
        ? null
        : tutorAt != null && !tutorAt.isAfter(at);
    final uuid = newSyncId();
    await _db.transaction(() async {
      await _db
          .into(_db.assignmentSubmissions)
          .insert(
            AssignmentSubmissionsCompanion.insert(
              uuid: uuid,
              assignmentId: assignment.id,
              subjectId: assignment.subjectId,
              studentId: Value(student.id),
              memberKey: memberKey,
              learnerName: student.name,
              answer: text.length > kMaxAnswerChars
                  ? text.substring(0, kMaxAnswerChars)
                  : text,
              createdAt: at.toUtc().toIso8601String(),
              startedAt: Value(startedAt),
              tutorUsed: Value(tutorUsed),
            ),
          );
      await (_db.delete(_db.assignmentAttempts)..where(
            (t) =>
                t.studentId.equals(student.id) &
                t.assignmentId.equals(assignment.id),
          ))
          .go();
    });
    await _queue(CloudKind.submission, uuid);
    return true;
  }

  Future<bool> _submitted(int studentId, String assignmentId) async =>
      (await (_db.select(_db.assignmentSubmissions)
            ..where((t) => t.studentId.equals(studentId))
            ..where((t) => t.assignmentId.equals(assignmentId))
            ..limit(1))
          .getSingleOrNull()) !=
      null;

  // ── Timed assessments ─────────────────────────────────────────────────

  /// [studentId]'s attempt in progress at [assignmentId], if any.
  Future<AssignmentAttempt?> attempt(int studentId, String assignmentId) =>
      (_db.select(_db.assignmentAttempts)
            ..where((t) => t.studentId.equals(studentId))
            ..where((t) => t.assignmentId.equals(assignmentId)))
          .getSingleOrNull();

  Stream<List<AssignmentAttempt>> watchAttempts(int studentId) => (_db.select(
    _db.assignmentAttempts,
  )..where((t) => t.studentId.equals(studentId))).watch();

  /// Starts the clock, once. Returns the attempt, or null when it can't be
  /// started now (not open yet, closed, or already handed in).
  Future<AssignmentAttempt?> start(
    int studentId,
    ClassAssignment assignment, {
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final existing = await attempt(studentId, assignment.id);
    if (existing != null) return existing;
    if (assignment.notOpenYet(at) || assignment.closed(at)) return null;
    if (await _submitted(studentId, assignment.id)) return null;
    await _db
        .into(_db.assignmentAttempts)
        .insert(
          AssignmentAttemptsCompanion.insert(
            studentId: studentId,
            assignmentId: assignment.id,
            startedAt: at.toUtc().toIso8601String(),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    return attempt(studentId, assignment.id);
  }

  /// Records when [studentId] first saw each untimed assignment of
  /// [assignments] they may still answer, so a tutor reply after that marks
  /// their answer "Tutor used". Timed ones start with [start] instead.
  Future<void> markSeen(
    int studentId,
    Iterable<ClassAssignment> assignments, {
    DateTime? now,
  }) async {
    final at = (now ?? DateTime.now()).toUtc().toIso8601String();
    for (final a in assignments) {
      if (a.timed) continue;
      await _db
          .into(_db.assignmentAttempts)
          .insert(
            AssignmentAttemptsCompanion.insert(
              studentId: studentId,
              assignmentId: a.id,
              startedAt: at,
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }
  }

  /// Keeps what the learner has typed so far.
  Future<void> saveDraft(int studentId, String assignmentId, String draft) =>
      (_db.update(_db.assignmentAttempts)
            ..where((t) => t.studentId.equals(studentId))
            ..where((t) => t.assignmentId.equals(assignmentId)))
          .write(
            AssignmentAttemptsCompanion(
              draft: Value(
                draft.length > kMaxAnswerChars
                    ? draft.substring(0, kMaxAnswerChars)
                    : draft,
              ),
            ),
          );

  /// Hands in every attempt of [student] whose time has run out, as its
  /// draft stands — e.g. after the app was closed mid-assessment. Returns
  /// how many.
  Future<int> submitExpired({
    required Student student,
    required List<ClassAssignment> assignments,
    required String memberKey,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final byId = {for (final a in assignments) a.id: a};
    var n = 0;
    for (final a in await (_db.select(
      _db.assignmentAttempts,
    )..where((t) => t.studentId.equals(student.id))).get()) {
      final assignment = byId[a.assignmentId];
      final started = DateTime.tryParse(a.startedAt);
      if (assignment == null || started == null) continue;
      final deadline = assignment.deadlineFor(started);
      if (deadline == null || at.isBefore(deadline)) continue;
      if (await submit(
        student: student,
        assignment: assignment,
        answer: a.draft,
        memberKey: memberKey,
        auto: true,
        now: deadline,
      )) {
        n++;
      }
    }
    return n;
  }

  Stream<List<AssignmentSubmission>> watchMine(int studentId) =>
      (_db.select(_db.assignmentSubmissions)
            ..where((t) => t.studentId.equals(studentId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  // ── Sync ──────────────────────────────────────────────────────────────

  /// [studentId]'s submissions to assignments received for [classUuid] —
  /// what their progress report carries to the teacher.
  Future<List<SubmissionPayload>> outgoing(
    int studentId,
    String classUuid,
  ) async {
    final ids = {for (final a in await _received(classUuid)) a.id};
    if (ids.isEmpty) return const [];
    final rows =
        await (_db.select(_db.assignmentSubmissions)
              ..where((t) => t.studentId.equals(studentId))
              ..where((t) => t.assignmentId.isIn(ids))
              ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
              ..limit(20))
            .get();
    return [for (final r in rows) SubmissionPayload.fromRow(r)];
  }

  Future<List<ClassAssignment>> _received(String classUuid) async => [
    for (final r
        in await (_db.select(_db.topicResources)
              ..where((t) => t.topicKey.equals(kAssignmentTopicKey))
              ..where((t) => t.classGroupUuid.equals(classUuid)))
            .get())
      ?ClassAssignment.parse(r),
  ];

  /// On the teacher's device: stores what [memberKey] submitted, only for
  /// this device's own assignments shared with [classUuid] — a learner
  /// can't answer anything else, or edit an answer already received.
  /// Returns the grades of those submissions to send back.
  Future<List<GradePayload>> receive({
    required String classUuid,
    required String memberKey,
    required String learnerName,
    required List<SubmissionPayload> submissions,
  }) async {
    if (submissions.isEmpty) return const [];
    final shared = {
      for (final s in await (_db.select(
        _db.resourceShares,
      )..where((t) => t.classGroupUuid.equals(classUuid))).get())
        (s.subjectId, s.documentTitle),
    };
    final allowed = {
      for (final a in await own())
        if (shared.contains((a.subjectId, a.documentTitle))) a.id,
    };
    final out = <GradePayload>[];
    for (final s in submissions) {
      if (!allowed.contains(s.assignmentId)) continue;
      final existing = await (_db.select(
        _db.assignmentSubmissions,
      )..where((t) => t.uuid.equals(s.uuid))).getSingleOrNull();
      if (existing == null) {
        await _db
            .into(_db.assignmentSubmissions)
            .insert(
              AssignmentSubmissionsCompanion.insert(
                uuid: s.uuid,
                assignmentId: s.assignmentId,
                subjectId: s.subjectId,
                memberKey: memberKey,
                learnerName: learnerName,
                answer: s.answer,
                createdAt: s.createdAt,
                startedAt: Value(s.startedAt),
                tutorUsed: Value(s.tutorUsed),
                receivedAt: Value(DateTime.now().toUtc().toIso8601String()),
              ),
            );
        await _queue(CloudKind.submission, s.uuid);
        continue;
      }
      // Never another learner's row, and never a new answer in an old one.
      if (existing.memberKey != memberKey) continue;
      if (existing.grade != null && existing.gradeVersion > 0) {
        out.add(
          GradePayload(
            uuid: existing.uuid,
            grade: existing.grade!,
            version: existing.gradeVersion,
            feedback: existing.feedback,
            gradedAt: existing.gradedAt,
          ),
        );
      }
    }
    return out;
  }

  /// On the teacher's device: which of [uuids] it holds as [memberKey]'s
  /// answers — what the reply tells the learner's device arrived.
  Future<List<String>> heldFrom(
    String memberKey,
    Iterable<String> uuids,
  ) async {
    final wanted = uuids.toSet();
    if (wanted.isEmpty) return const [];
    return [
      for (final r
          in await (_db.select(_db.assignmentSubmissions)
                ..where((t) => t.uuid.isIn(wanted))
                ..where((t) => t.memberKey.equals(memberKey)))
              .get())
        r.uuid,
    ];
  }

  /// On the learner's device: its answers the teacher's device confirmed it
  /// holds. Returns how many were newly marked.
  Future<int> markReceived(Iterable<String> uuids) async {
    final wanted = uuids.toSet();
    if (wanted.isEmpty) return 0;
    return (_db.update(_db.assignmentSubmissions)
          ..where((t) => t.uuid.isIn(wanted))
          ..where((t) => t.studentId.isNotNull())
          ..where((t) => t.receivedAt.isNull()))
        .write(
          AssignmentSubmissionsCompanion(
            receivedAt: Value(DateTime.now().toUtc().toIso8601String()),
          ),
        );
  }

  /// On the learner's device: takes grades newer than the ones it holds,
  /// for its own submissions only. Returns how many changed.
  Future<int> applyGrades(List<GradePayload> grades) async {
    var changed = 0;
    for (final g in grades) {
      final row = await (_db.select(
        _db.assignmentSubmissions,
      )..where((t) => t.uuid.equals(g.uuid))).getSingleOrNull();
      if (row == null || row.studentId == null) continue;
      if (g.version <= row.gradeVersion) continue;
      await (_db.update(
        _db.assignmentSubmissions,
      )..where((t) => t.id.equals(row.id))).write(
        AssignmentSubmissionsCompanion(
          grade: Value(g.grade),
          feedback: Value(g.feedback),
          gradeVersion: Value(g.version),
          gradedAt: Value(g.gradedAt),
          receivedAt: Value(
            row.receivedAt ?? DateTime.now().toUtc().toIso8601String(),
          ),
        ),
      );
      changed++;
    }
    return changed;
  }
}

final classAssignmentsProvider = Provider<ClassAssignments>((ref) {
  final outbox = ref.watch(cloudOutboxProvider);
  return ClassAssignments(
    ref.watch(dbProvider),
    cloud: (kind, uuid, {recordId}) async {
      await outbox.enqueue(kind, uuid, recordId: recordId);
      unawaited(outbox.flush());
    },
  );
});
