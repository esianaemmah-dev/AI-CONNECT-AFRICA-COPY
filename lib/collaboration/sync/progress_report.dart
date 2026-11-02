import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../db/otic_database.dart';
import '../../services/assignments/class_assignments.dart';
import '../../services/assignments/learner_support.dart';
import '../../services/notes/quiz_scores.dart';
import 'class_crypto.dart' show signingPublicKey;

/// One learner's progress as their device reports it to the teacher.
///
/// Compressed summaries only (CLAUDE.md → Student Memory Engine): totals,
/// per-topic mastery, strengths and weaknesses. Never chats, answers or
/// anything the learner typed. Small and bounded — a report is a few KB
/// however long the learner has used the app.
class ProgressReport {
  const ProgressReport({
    required this.memberKey,
    required this.name,
    required this.points,
    required this.streakDays,
    required this.lessonsCompleted,
    required this.practiceAttempted,
    required this.practiceCorrect,
    required this.scenariosCompleted,
    required this.lastActive,
    required this.topics,
    required this.strengths,
    required this.weaknesses,
    this.enrolled = const [],
    this.submissions = const [],
    this.quizzes = const [],
    this.support = const [],
    this.sentAt,
  });

  /// The learner device's clock when it sent the report (ISO-8601 UTC).
  /// The teacher's device compares it with its own to see a wrong clock,
  /// since every assignment time is the learner device's. Left out of
  /// [reportDigest]: it changes on every sync.
  final String? sentAt;

  /// The teacher's extra help for this learner (`learner_support.dart`):
  /// whether they opened it and marked it done, by the learner device's
  /// clock.
  final List<({String id, String? openedAt, String? doneAt})> support;
  static const maxSupport = 20;

  /// The latest quiz round per subject and topic, most recent first: counts
  /// only, never the questions or answers. [tutorUsed] is how many answers
  /// came after the tutor replied; null when the round predates that.
  final List<
    ({String subject, String topic, int correct, int total, int? tutorUsed})
  >
  quizzes;
  static const maxQuizzes = 20;

  /// The learner's answers to the teacher's assignments — sent explicitly
  /// as their work, the one thing they typed that leaves the device.
  final List<SubmissionPayload> submissions;
  static const maxSubmissions = 20;

  /// Subject ids the learner says they take (a record, not a lock).
  final List<String> enrolled;
  static const maxEnrolled = 30;

  final String memberKey;
  final String name;
  final int points;
  final int streakDays;
  final int lessonsCompleted;
  final int practiceAttempted;
  final int practiceCorrect;
  final int scenariosCompleted;

  /// ISO-8601 UTC, the learner device's clock (may be wrong).
  final String? lastActive;

  /// Most recently studied topics first, mastery 0–100.
  final List<({String topic, int level})> topics;
  final List<String> strengths;
  final List<String> weaknesses;

  static const maxTopics = 20;
  static const _maxList = 5;
  static const _maxText = 80;

  /// Mean mastery over [topics], or null with none.
  int? get meanLevel => topics.isEmpty
      ? null
      : (topics.map((t) => t.level).reduce((a, b) => a + b) / topics.length)
            .round();

  Map<String, Object?> toJson() => {
    'member': memberKey,
    'name': name,
    'points': points,
    'streak': streakDays,
    'lessons': lessonsCompleted,
    'practice': practiceAttempted,
    'correct': practiceCorrect,
    'scenarios': scenariosCompleted,
    'last_active': lastActive,
    'topics': [
      for (final t in topics) {'t': t.topic, 'l': t.level},
    ],
    'strengths': strengths,
    'weaknesses': weaknesses,
    'enrolled': enrolled,
    'submissions': [for (final s in submissions) s.toJson()],
    // Only when there is one, so reports without quizzes keep their digest.
    if (quizzes.isNotEmpty)
      'quizzes': [
        for (final q in quizzes)
          {
            's': q.subject,
            't': q.topic,
            'c': q.correct,
            'n': q.total,
            if (q.tutorUsed != null) 'a': q.tutorUsed,
          },
      ],
    if (support.isNotEmpty)
      'support': [
        for (final s in support) {'id': s.id, 'o': ?s.openedAt, 'd': ?s.doneAt},
      ],
    if (sentAt != null) 'sent_at': sentAt,
  };

  /// Reads a report from another device. Null when it isn't one. Every
  /// field is clipped, so a buggy or hostile device can't bloat the
  /// teacher's database.
  static ProgressReport? fromJson(Object? json) {
    if (json is! Map) return null;
    final member = json['member'], name = json['name'];
    if (member is! String || member.isEmpty || member.length > 120) {
      return null;
    }
    if (name is! String || name.trim().isEmpty) return null;
    int n(Object? v) => v is int && v >= 0 ? v : 0;
    List<String> strings(Object? v) => [
      if (v is List)
        for (final s in v.take(_maxList))
          if (s is String && s.trim().isNotEmpty) _clip(s.trim()),
    ];
    final topics = <({String topic, int level})>[];
    final rawTopics = json['topics'];
    if (rawTopics is List) {
      for (final t in rawTopics.take(maxTopics)) {
        if (t is Map && t['t'] is String && t['l'] is int) {
          topics.add((
            topic: _clip(t['t'] as String),
            level: (t['l'] as int).clamp(0, 100),
          ));
        }
      }
    }
    final last = json['last_active'], sent = json['sent_at'];
    String? iso(Object? v) => v is String && v.length <= 40 ? v : null;
    return ProgressReport(
      memberKey: member,
      name: _clip(name.trim()),
      points: n(json['points']),
      streakDays: n(json['streak']),
      lessonsCompleted: n(json['lessons']),
      practiceAttempted: n(json['practice']),
      practiceCorrect: n(json['correct']),
      scenariosCompleted: n(json['scenarios']),
      lastActive: last is String && last.length <= 40 ? last : null,
      topics: topics,
      strengths: strings(json['strengths']),
      weaknesses: strings(json['weaknesses']),
      enrolled: [
        if (json['enrolled'] case final List ids)
          for (final id in ids.take(maxEnrolled))
            if (id is String && RegExp(r'^[a-z0-9_]{1,60}$').hasMatch(id)) id,
      ],
      submissions: [
        if (json['submissions'] case final List subs)
          for (final s in subs.take(maxSubmissions))
            ?SubmissionPayload.fromJson(s),
      ],
      quizzes: [
        if (json['quizzes'] case final List qs)
          for (final q in qs.take(maxQuizzes))
            if (q is Map &&
                q['s'] is String &&
                q['t'] is String &&
                q['c'] is int &&
                q['n'] is int &&
                (q['n'] as int) > 0 &&
                (q['n'] as int) <= 100)
              (
                subject: _clip(q['s'] as String),
                topic: _clip(q['t'] as String),
                total: q['n'] as int,
                correct: (q['c'] as int).clamp(0, q['n'] as int),
                tutorUsed: q['a'] is int
                    ? (q['a'] as int).clamp(0, q['n'] as int)
                    : null,
              ),
      ],
      support: [
        if (json['support'] case final List items)
          for (final s in items.take(maxSupport))
            if (s is Map &&
                s['id'] is String &&
                (s['id'] as String).length <= 64)
              (
                id: s['id'] as String,
                openedAt: iso(s['o']),
                doneAt: iso(s['d']),
              ),
      ],
      sentAt: iso(sent),
    );
  }

  static String _clip(String s) =>
      s.length > _maxText ? s.substring(0, _maxText) : s;

  /// How far the learner device's clock was from the teacher's when this
  /// report arrived at [receivedAt] (the teacher's clock): positive when
  /// it runs fast. Null when the report has no clock (older builds).
  Duration? clockOffset(String receivedAt) {
    final sent = DateTime.tryParse(sentAt ?? '');
    final got = DateTime.tryParse(receivedAt);
    if (sent == null || got == null) return null;
    return sent.difference(got);
  }
}

/// A learner device's clock off by more than this is shown to the teacher,
/// beside the assignment times it stamped.
const kClockWarnAfter = Duration(minutes: 5);

/// "device clock 2 h 05 min fast", or null within [kClockWarnAfter].
String? clockNote(Duration? offset) {
  if (offset == null || offset.abs() <= kClockWarnAfter) return null;
  final d = offset.abs();
  final h = d.inHours, m = d.inMinutes % 60;
  final size = d.inDays >= 2
      ? '${d.inDays} days'
      : h == 0
      ? '$m min'
      : '$h h ${m.toString().padLeft(2, '0')} min';
  return 'device clock $size ${offset.isNegative ? 'slow' : 'fast'}';
}

/// Reports for every learner on this device who is in [group] — what a
/// student device sends its teacher on sync. [deviceKey] makes each
/// learner's key unique across devices.
Future<List<ProgressReport>> buildProgressReports(
  OticDatabase db,
  ClassGroup group, {
  required String deviceKey,
}) async {
  final learners = await (db.select(
    db.students,
  )..where((t) => t.classGroupId.equals(group.id))).get();
  // Timed assessments whose time ran out are handed in first, so the
  // teacher gets them even if the learner never reopened Assignments.
  final uuid = group.groupUuid;
  if (uuid != null) {
    final assignments = ClassAssignments(db);
    final visible = await assignments.visible(uuid);
    for (final s in learners) {
      await assignments.submitExpired(
        student: s,
        assignments: visible,
        memberKey: 'local/${s.id}',
      );
    }
  }
  final sentAt = DateTime.now().toUtc().toIso8601String();
  return [
    for (final s in learners)
      await _reportFor(db, group, s, deviceKey, sentAt: sentAt),
  ];
}

Future<ProgressReport> _reportFor(
  OticDatabase db,
  ClassGroup group,
  Student s,
  String deviceKey, {
  String? sentAt,
}) async {
  final progress =
      await (db.select(db.topicProgress)
            ..where((t) => t.studentId.equals(s.id))
            ..orderBy([(t) => OrderingTerm.desc(t.lastStudiedAt)])
            ..limit(ProgressReport.maxTopics))
          .get();
  return ProgressReport(
    memberKey: '$deviceKey/${s.id}',
    name: s.name,
    points: s.totalPoints,
    streakDays: s.streakDays,
    lessonsCompleted: s.totalLessonsCompleted,
    practiceAttempted: s.totalPracticeAttempted,
    practiceCorrect: s.totalPracticeCorrect,
    scenariosCompleted: s.totalScenariosCompleted,
    lastActive: s.lastActiveAt.toUtc().toIso8601String(),
    topics: [for (final p in progress) (topic: p.topic, level: p.level)],
    strengths: _list(s.strengthsJson),
    weaknesses: _list(s.weaknessesJson),
    enrolled: (await db.classSyncDao.watchReadable(s.id).first)
            .take(ProgressReport.maxEnrolled)
            .toList()
          ..sort(),
    submissions: group.groupUuid == null
        ? const []
        : await ClassAssignments(db).outgoing(s.id, group.groupUuid!),
    quizzes: [
      for (final q in QuizScores.summarize(
        await (db.select(db.quizResults)
              ..where((t) => t.studentId.equals(s.id))
              ..orderBy([(t) => OrderingTerm.asc(t.id)]))
            .get(),
      ).take(ProgressReport.maxQuizzes))
        (
          subject: q.subjectId,
          topic: q.topic,
          correct: q.lastCorrect,
          total: q.lastTotal,
          tutorUsed: q.lastTutorUsed,
        ),
    ],
    support: group.groupUuid == null
        ? const []
        : await LearnerSupportService(db).acks(s.id, group.groupUuid!),
    sentAt: sentAt,
  );
}

/// Identifies a report's content: equal digests, nothing new to send.
/// The send time is left out, so an unchanged report keeps its digest.
String reportDigest(ProgressReport r) => sha256
    .convert(utf8.encode(jsonEncode(r.toJson()..remove('sent_at'))))
    .toString();

/// On the learner's device, once the teacher's reply confirms [reports]:
/// remembers what the teacher now holds for each learner.
Future<void> markReportsSent(
  OticDatabase db,
  List<ProgressReport> reports,
) async {
  for (final r in reports) {
    final id = int.tryParse(r.memberKey.split('/').last);
    if (id == null) continue;
    await (db.update(db.students)..where((t) => t.id.equals(id))).write(
      StudentsCompanion(progressSentDigest: Value(reportDigest(r))),
    );
  }
}

/// Whether [student]'s progress as it is now has reached their teacher.
/// Null when there is no teacher to send it to (not in a class this device
/// joined).
Future<bool?> progressSent(OticDatabase db, Student student) async {
  final groupId = student.classGroupId;
  if (groupId == null) return null;
  final group = await (db.select(
    db.classGroups,
  )..where((t) => t.id.equals(groupId))).getSingleOrNull();
  if (group == null || !group.joined || group.groupUuid == null) return null;
  final sent = student.progressSentDigest;
  if (sent == null) return false;
  final report = await _reportFor(
    db,
    group,
    student,
    await reportDeviceKey(db),
  );
  return reportDigest(report) == sent;
}

/// This device's part of every learner's key in its reports.
Future<String> reportDeviceKey(OticDatabase db) async {
  final me = await db.classSyncDao.identity();
  return (await signingPublicKey(me.signingSeed)).substring(0, 16);
}

List<String> _list(String json) {
  try {
    final v = jsonDecode(json);
    return [
      if (v is List)
        for (final s in v)
          if (s is String) s,
    ];
  } catch (_) {
    return const [];
  }
}
