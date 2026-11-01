import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../collaboration/sync/progress_report.dart' show clockNote;
import '../../core/policy/policy.dart';
import '../../db/otic_database.dart';
import '../../db/providers/db_provider.dart';
import '../../services/assignments/class_assignments.dart';
import '../../services/assignments/learner_support.dart';
import '../../services/custom_subject_service.dart';
import '../../services/notes/note_pdf_store.dart';
import '../../services/pdf/pdf_page_extractor.dart';
import '../../shared/widgets/responsive.dart';
import '../../shared/widgets/studio_page.dart';
import '../learn/notes_quiz.dart';
import '../learn/subject_notes.dart';
import '../notes/note_pdf_screen.dart';
import '../teacher/teacher_profiles.dart';

final _visibleAssignmentsProvider =
    FutureProvider.autoDispose<List<ClassAssignment>>((ref) async {
      ref.watch(noteResourcesRevisionProvider);
      final classUuid = await ref.watch(learnerClassUuidProvider.future);
      return ref.watch(classAssignmentsProvider).visible(classUuid);
    });

final _mySubmissionsProvider = StreamProvider.autoDispose
    .family<List<AssignmentSubmission>, int>(
      (ref, studentId) =>
          ref.watch(classAssignmentsProvider).watchMine(studentId),
    );

final _myAttemptsProvider = StreamProvider.autoDispose
    .family<List<AssignmentAttempt>, int>(
      (ref, studentId) =>
          ref.watch(classAssignmentsProvider).watchAttempts(studentId),
    );

/// The PDF attached to an assignment, if this learner may open it.
final _assignmentPdfProvider = FutureProvider.autoDispose
    .family<NotePdf?, String>((ref, documentTitle) async {
      final classUuid = await ref.watch(learnerClassUuidProvider.future);
      return ref
          .watch(notePdfStoreProvider)
          .find(documentTitle, classUuid: classUuid);
    });

String _memberKey(Student s) => 'local/${s.id}';

final _mySupportProvider = StreamProvider.autoDispose
    .family<List<LearnerSupportItem>, int>(
      (ref, studentId) =>
          ref.watch(learnerSupportProvider).watchMine(studentId),
    );

/// "12 Oct 09:05", local time.
String formatWhen(DateTime t) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.day} ${months[l.month - 1]} ${two(l.hour)}:${two(l.minute)}';
}

/// "1 h 05 min", "12 min", "40 s".
String formatLeft(Duration d) {
  if (d.inMinutes < 1) return '${d.inSeconds.clamp(0, 59)} s';
  final h = d.inHours, m = d.inMinutes % 60;
  return h == 0 ? '$m min' : '$h h ${m.toString().padLeft(2, '0')} min';
}

/// The open/close times and time limit, e.g. "Closes 14 Oct 17:00 · 45 min".
String scheduleLine(ClassAssignment a) => [
  if (a.opensAt case final o?) 'Opens ${formatWhen(o)}',
  if (a.closesAt case final c?) 'Closes ${formatWhen(c)}',
  if (a.minutes case final m?) '$m min',
].join(' · ');

/// The active learner's assignments: answer them, then see the grade and
/// the teacher's feedback once their device has synced with the teacher.
/// Timed ones (homework, holiday assessments) are started once and handed
/// in when the learner is done or the time runs out.
class AssignmentsScreen extends ConsumerStatefulWidget {
  const AssignmentsScreen({super.key});

  @override
  ConsumerState<AssignmentsScreen> createState() => _AssignmentsScreenState();
}

class _AssignmentsScreenState extends ConsumerState<AssignmentsScreen> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Keeps "time left" current and hands in attempts that ran out while
    // the learner was away.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => _expire());
    WidgetsBinding.instance.addPostFrameCallback((_) => _expire());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _expire() async {
    final student = await ref.read(activeStudentProvider.future);
    final assignments = await ref.read(_visibleAssignmentsProvider.future);
    if (student == null || !mounted) return;
    final service = ref.read(classAssignmentsProvider);
    await service.submitExpired(
      student: student,
      assignments: assignments,
      memberKey: _memberKey(student),
    );
    // From here, a tutor reply marks the learner's answer "Tutor used".
    await service.markSeen(student.id, assignments);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final student = ref.watch(activeStudentProvider).valueOrNull;
    final assignments =
        ref.watch(_visibleAssignmentsProvider).valueOrNull ??
        const <ClassAssignment>[];
    final mine = student == null
        ? const <AssignmentSubmission>[]
        : ref.watch(_mySubmissionsProvider(student.id)).valueOrNull ??
              const <AssignmentSubmission>[];
    final attempts = student == null
        ? const <AssignmentAttempt>[]
        : ref.watch(_myAttemptsProvider(student.id)).valueOrNull ??
              const <AssignmentAttempt>[];
    final support = student == null
        ? const <LearnerSupportItem>[]
        : ref.watch(_mySupportProvider(student.id)).valueOrNull ??
              const <LearnerSupportItem>[];
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: const StudioAppBar(
        title: 'Assignments',
        subtitle: 'From your teachers',
        icon: Icons.assignment_rounded,
      ),
      body: MaxWidth(
        maxWidth: 800,
        child: assignments.isEmpty && support.isEmpty
            ? const Center(child: Text('No assignments'))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (final i in support)
                    _SupportCard(item: i, studentId: student!.id),
                  for (final a in assignments)
                    _AssignmentCard(
                      assignment: a,
                      latest: mine
                          .where((s) => s.assignmentId == a.id)
                          .firstOrNull,
                      // Untimed ones keep a row only to mark tutor use.
                      attempt: a.timed
                          ? attempts
                                .where((t) => t.assignmentId == a.id)
                                .firstOrNull
                          : null,
                      onAnswer: student == null
                          ? null
                          : () => a.timed
                                ? _openTimed(context, student, a)
                                : _answer(context, student, a),
                    ),
                ],
              ),
      ),
    );
  }

  Future<void> _openTimed(
    BuildContext context,
    Student student,
    ClassAssignment a,
  ) async {
    final service = ref.read(classAssignmentsProvider);
    var attempt = await service.attempt(student.id, a.id);
    if (attempt == null) {
      if (!context.mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(a.title),
          content: Text(
            [
              if (a.minutes case final m?) 'You have $m min once you start.',
              if (a.closesAt case final c?) 'Closes ${formatWhen(c)}.',
              'It is handed in when time runs out.',
            ].join('\n'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Start'),
            ),
          ],
        ),
      );
      if (go != true) return;
      attempt = await service.start(student.id, a);
      if (attempt == null) return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AssessmentScreen(
          student: student,
          assignment: a,
          attempt: attempt!,
        ),
      ),
    );
  }

  Future<void> _answer(
    BuildContext context,
    Student student,
    ClassAssignment a,
  ) async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(a.title),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 6,
            maxLines: 14,
            maxLength: kMaxAnswerChars,
            decoration: const InputDecoration(labelText: 'Your answer'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Submit'),
          ),
        ],
      ),
    );
    final text = controller.text;
    controller.dispose();
    if (ok != true) return;
    final service = ref.read(classAssignmentsProvider);
    await service.submit(
      student: student,
      assignment: a,
      answer: text,
      memberKey: _memberKey(student),
    );
    // Answering again opens a new window.
    await service.markSeen(student.id, [a]);
  }
}

class _AssignmentCard extends ConsumerWidget {
  const _AssignmentCard({
    required this.assignment,
    required this.latest,
    required this.attempt,
    required this.onAnswer,
  });

  final ClassAssignment assignment;
  final AssignmentSubmission? latest;
  final AssignmentAttempt? attempt;
  final VoidCallback? onAnswer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = assignment;
    final s = latest;
    final now = DateTime.now();
    final started = attempt == null
        ? null
        : DateTime.tryParse(attempt!.startedAt);
    final deadline = started == null ? null : a.deadlineFor(started);
    final pdf = ref.watch(_assignmentPdfProvider(a.documentTitle)).valueOrNull;

    final String status;
    final String? action;
    if (s != null) {
      status = [
        s.grade != null
            ? 'Grade ${s.grade}/${a.maxPoints}'
            : s.receivedAt != null
            ? 'Submitted · with your teacher'
            : 'Submitted · sends at your next Sync',
        if (s.tutorUsed == true) 'Tutor used',
      ].join(' · ');
      action = a.timed ? null : 'Answer again';
    } else if (started != null) {
      status = deadline == null
          ? 'In progress'
          : 'In progress · ${formatLeft(deadline.difference(now))} left';
      action = 'Continue';
    } else if (a.notOpenYet(now)) {
      status = 'Not open yet';
      action = null;
    } else if (a.closed(now)) {
      status = 'Closed';
      action = null;
    } else {
      status = 'Not submitted';
      action = a.timed ? 'Start' : 'Answer';
    }
    final schedule = scheduleLine(a);
    // A timed assessment's questions show only once its clock is running.
    final sealed = a.timed && started == null && s == null;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (a.kind != AssignmentKind.assignment)
              Text(
                a.kind.label,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            Text(a.title, style: Theme.of(context).textTheme.titleMedium),
            if (a.due != null) Text('Due ${a.due}'),
            if (schedule.isNotEmpty) Text(schedule),
            if (a.instructions.isNotEmpty && !sealed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(a.instructions),
              ),
            const SizedBox(height: 8),
            Text(status, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (s?.feedback case final f?)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Feedback: $f'),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (action != null)
                  FilledButton.tonal(onPressed: onAnswer, child: Text(action)),
                if (pdf != null && !sealed)
                  OutlinedButton.icon(
                    onPressed: () => openNotePdf(context, pdf),
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                    label: const Text('Open PDF'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Extra help from the learner's teacher: a message, a note to read and a
/// quiz on one topic. Opening either is reported back at the next Sync, and
/// so is Done.
class _SupportCard extends ConsumerWidget {
  const _SupportCard({required this.item, required this.studentId});

  final LearnerSupportItem item;
  final int studentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.read(learnerSupportProvider);
    final subject =
        (ref.watch(mergedSubjectsProvider).valueOrNull ?? const [])
            .where((s) => s.id == item.subjectId)
            .firstOrNull
            ?.name ??
        item.subjectId.replaceAll('_', ' ');
    final note = item.documentTitle;
    final pdf = note == null
        ? null
        : ref.watch(_assignmentPdfProvider(note)).valueOrNull;
    final done = item.doneAt != null;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'From your teacher',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            Text(
              [subject, if (item.topic.isNotEmpty) item.topic].join(' · '),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (item.message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(item.message),
              ),
            if (done)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Done',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (note != null)
                  OutlinedButton.icon(
                    onPressed: () async {
                      await service.markOpened(studentId, item.uuid);
                      if (!context.mounted) return;
                      if (pdf != null) {
                        openNotePdf(context, pdf);
                      } else {
                        await context.push(
                          '/learn/subject/${item.subjectId}?tab=0',
                        );
                      }
                    },
                    icon: const Icon(Icons.menu_book_outlined),
                    label: const Text('Read note'),
                  ),
                if (item.quiz && item.topic.isNotEmpty)
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      await service.markOpened(studentId, item.uuid);
                      await ref
                          .read(subjectQuizProvider(item.subjectId).notifier)
                          .startStored(topic: item.topic);
                      if (!context.mounted) return;
                      await context.push(
                        '/learn/subject/${item.subjectId}?tab=1',
                      );
                    },
                    icon: const Icon(Icons.quiz_outlined),
                    label: const Text('Take quiz'),
                  ),
                if (!done)
                  TextButton(
                    onPressed: () => service.markDone(studentId, item.uuid),
                    child: const Text('Done'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A timed assessment in progress: the countdown, the answer box (saved as
/// a draft while typing) and Submit. Handed in by itself when time runs
/// out. Leaving doesn't stop the clock.
class AssessmentScreen extends ConsumerStatefulWidget {
  const AssessmentScreen({
    super.key,
    required this.student,
    required this.assignment,
    required this.attempt,
  });

  final Student student;
  final ClassAssignment assignment;
  final AssignmentAttempt attempt;

  @override
  ConsumerState<AssessmentScreen> createState() => _AssessmentScreenState();
}

class _AssessmentScreenState extends ConsumerState<AssessmentScreen> {
  late final TextEditingController _text = TextEditingController(
    text: widget.attempt.draft,
  );
  late final DateTime? _deadline = widget.assignment.deadlineFor(
    DateTime.tryParse(widget.attempt.startedAt) ?? DateTime.now(),
  );
  Timer? _clock;
  Timer? _save;
  bool _done = false;

  /// Read once: the draft is saved from [dispose], where ref can't be used.
  late final ClassAssignments _service;

  @override
  void initState() {
    super.initState();
    _service = ref.read(classAssignmentsProvider);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_deadline != null && !DateTime.now().isBefore(_deadline)) {
        _submit(auto: true);
      } else if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _save?.cancel();
    if (!_done) {
      unawaited(
        _service.saveDraft(widget.student.id, widget.assignment.id, _text.text),
      );
    }
    _text.dispose();
    super.dispose();
  }

  void _changed(String _) {
    _save?.cancel();
    _save = Timer(const Duration(seconds: 1), () {
      _service.saveDraft(widget.student.id, widget.assignment.id, _text.text);
    });
  }

  Future<void> _submit({bool auto = false}) async {
    if (_done) return;
    _done = true;
    _clock?.cancel();
    _save?.cancel();
    final saved = await _service.submit(
      student: widget.student,
      assignment: widget.assignment,
      answer: _text.text,
      memberKey: _memberKey(widget.student),
      auto: auto,
      now: auto ? _deadline : null,
    );
    if (!mounted) return;
    if (!saved) {
      // Manual submit of an empty answer: keep going.
      _done = false;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Write an answer first')));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(auto ? 'Time is up — handed in' : 'Handed in')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.assignment;
    final left = _deadline?.difference(DateTime.now());
    final pdf = ref.watch(_assignmentPdfProvider(a.documentTitle)).valueOrNull;
    final low = left != null && left.inMinutes < 5;
    return Scaffold(
      appBar: AppBar(
        title: Text(a.title),
        actions: [
          if (left != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: Row(
                  children: [
                    Icon(
                      Icons.timer_outlined,
                      size: 18,
                      color: low ? Theme.of(context).colorScheme.error : null,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      formatLeft(left),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: low ? Theme.of(context).colorScheme.error : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      body: MaxWidth(
        maxWidth: 800,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (a.instructions.isNotEmpty) ...[
              Text(a.instructions),
              const SizedBox(height: 12),
            ],
            if (pdf != null) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => openNotePdf(context, pdf),
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('Open PDF'),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _text,
              onChanged: _changed,
              minLines: 10,
              maxLines: 24,
              maxLength: kMaxAnswerChars,
              decoration: const InputDecoration(
                labelText: 'Your answer',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => _submit(),
                child: const Text('Submit'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Teacher ───────────────────────────────────────────────────────────────

final _gradableProvider = FutureProvider.autoDispose<List<ClassAssignment>>((
  ref,
) async {
  ref.watch(noteResourcesRevisionProvider);
  final me = ref.watch(activeTeacherIdProvider);
  if (me == null) return const [];
  final policy = ref.watch(policyProvider);
  final out = <ClassAssignment>[];
  for (final a in await ref.watch(classAssignmentsProvider).own()) {
    if (await policy.can(
      TeacherActor(me),
      ChangeNote(a.subjectId, a.documentTitle),
    )) {
      out.add(a);
    }
  }
  return out;
});

final _submissionsProvider = StreamProvider.autoDispose
    .family<List<AssignmentSubmission>, String>(
      (ref, assignmentId) =>
          ref.watch(classAssignmentsProvider).watchSubmissions(assignmentId),
    );

/// Teacher → Assignments: the answers to the signed-in teacher's
/// assignments, to grade. Grades reach each learner at their next Sync.
class GradeAssignmentsScreen extends ConsumerWidget {
  const GradeAssignmentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final assignments =
        ref.watch(_gradableProvider).valueOrNull ?? const <ClassAssignment>[];
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: const StudioAppBar(
        title: 'Assignments',
        subtitle: 'Grade answers',
        icon: Icons.assignment_turned_in_rounded,
        showBack: true,
      ),
      body: MaxWidth(
        maxWidth: 900,
        child: assignments.isEmpty
            ? const Center(
                child: Text('No assignments — add one in Lesson materials'),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (final a in assignments) _Gradebook(assignment: a),
                ],
              ),
      ),
    );
  }
}

/// What the teacher should know about an answer: when a timed one was
/// started and handed in and whether it was late (by the learner's device
/// clock), whether the tutor was used, a timed one sent from an older app
/// that didn't time it, and a learner device clock that was off
/// ([clockOffset], from their last report). Null when there is nothing.
String? timingLine(
  ClassAssignment a,
  AssignmentSubmission s, {
  Duration? clockOffset,
}) {
  final started = s.startedAt == null ? null : DateTime.tryParse(s.startedAt!);
  final handed = DateTime.tryParse(s.createdAt);
  final parts = <String>[];
  if (started != null && handed != null) {
    final deadline = a.deadlineFor(started);
    final took = handed.difference(started);
    final late =
        deadline != null &&
        handed.isAfter(deadline.add(const Duration(minutes: 1)));
    parts.addAll([
      'Started ${formatWhen(started)}',
      'handed in ${formatWhen(handed)} (${formatLeft(took)})',
      if (late) 'late',
      if (s.answer.isEmpty) 'not answered',
    ]);
  } else if (a.timed) {
    // Every build that times assessments sends the start time.
    parts.add('older app: not timed');
  }
  if (s.tutorUsed == true) parts.add('Tutor used');
  if (clockNote(clockOffset) case final c?) parts.add(c);
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Teacher's device: each learner's device clock offset, by member key.
final _clockOffsetsProvider = StreamProvider.autoDispose<Map<String, Duration>>(
  (ref) => ref.watch(dbProvider).classSyncDao.watchClockOffsets(),
);

class _Gradebook extends ConsumerWidget {
  const _Gradebook({required this.assignment});
  final ClassAssignment assignment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subs =
        ref.watch(_submissionsProvider(assignment.id)).valueOrNull ??
        const <AssignmentSubmission>[];
    final schedule = scheduleLine(assignment);
    final clocks =
        ref.watch(_clockOffsetsProvider).valueOrNull ??
        const <String, Duration>{};
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        title: Text(assignment.title),
        subtitle: Text(
          [
            if (assignment.kind != AssignmentKind.assignment)
              assignment.kind.label,
            if (schedule.isNotEmpty) schedule,
            '${subs.length} answers',
          ].join(' · '),
        ),
        children: [
          for (final s in subs)
            ListTile(
              title: Text(s.learnerName),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (timingLine(
                        assignment,
                        s,
                        clockOffset: clocks[s.memberKey],
                      )
                      case final t?)
                    Text(t, style: const TextStyle(fontSize: 12)),
                  Text(s.answer, maxLines: 4, overflow: TextOverflow.ellipsis),
                ],
              ),
              trailing: Text(
                s.grade == null
                    ? 'Grade'
                    : '${s.grade}/${assignment.maxPoints}',
              ),
              onTap: () => _grade(context, ref, s),
            ),
        ],
      ),
    );
  }

  Future<void> _grade(
    BuildContext context,
    WidgetRef ref,
    AssignmentSubmission s,
  ) async {
    final clock = ref.read(_clockOffsetsProvider).valueOrNull?[s.memberKey];
    final grade = TextEditingController(text: s.grade?.toString() ?? '');
    final feedback = TextEditingController(text: s.feedback ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.learnerName),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (timingLine(assignment, s, clockOffset: clock) case final t?)
                  Text(t),
                SelectableText(s.answer),
                TextField(
                  controller: grade,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Grade (out of ${assignment.maxPoints})',
                  ),
                ),
                TextField(
                  controller: feedback,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Feedback'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final value = int.tryParse(grade.text.trim());
    final note = feedback.text;
    grade.dispose();
    feedback.dispose();
    if (ok != true || value == null) return;
    await ref
        .read(classAssignmentsProvider)
        .grade(s.uuid, value.clamp(0, assignment.maxPoints), note);
  }
}

/// What the teacher filled in on New assignment.
class _NewAssignment {
  const _NewAssignment({
    required this.kind,
    required this.title,
    required this.instructions,
    required this.points,
    this.opensAt,
    this.closesAt,
    this.minutes,
    this.pdf,
  });

  final AssignmentKind kind;
  final String title;
  final String instructions;
  final int points;
  final DateTime? opensAt;
  final DateTime? closesAt;
  final int? minutes;
  final PlatformFile? pdf;
}

/// Lesson materials → New assignment, for [subjectId]: typed in the app,
/// a PDF attached, or both. Returns the note's document title.
Future<String?> showNewAssignmentDialog(
  BuildContext context,
  WidgetRef ref,
  String subjectId,
) async {
  final r = await showDialog<_NewAssignment>(
    context: context,
    builder: (_) => const _NewAssignmentDialog(),
  );
  if (r == null) return null;
  final title = await ref
      .read(classAssignmentsProvider)
      .create(
        subjectId: subjectId,
        title: r.title,
        instructions: r.instructions,
        maxPoints: r.points,
        kind: r.kind,
        opensAt: r.opensAt,
        closesAt: r.closesAt,
        minutes: r.minutes,
      );
  final bytes = r.pdf?.bytes;
  if (title == null || bytes == null) return title;
  // The PDF becomes the assignment note's original, so it is signed,
  // shared and synced with it like any note PDF.
  try {
    final source = await PdfrxPageSource.open(bytes, name: r.pdf!.name);
    final pages = source.pageCount;
    await source.close();
    final store = ref.read(notePdfStoreProvider);
    final sha = await store.put(bytes);
    if (sha != null && pages > 0) {
      await store.recordOwn(
        subjectId: subjectId,
        documentTitle: title,
        sha: sha,
        pages: pages,
        bytes: bytes.length,
      );
    } else if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('PDF not attached')));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('PDF not attached')));
    }
  }
  return title;
}

class _NewAssignmentDialog extends StatefulWidget {
  const _NewAssignmentDialog();

  @override
  State<_NewAssignmentDialog> createState() => _NewAssignmentDialogState();
}

class _NewAssignmentDialogState extends State<_NewAssignmentDialog> {
  final _title = TextEditingController();
  final _instructions = TextEditingController();
  final _points = TextEditingController(text: '10');
  final _minutes = TextEditingController();
  var _kind = AssignmentKind.assignment;
  DateTime? _opens;
  DateTime? _closes;
  PlatformFile? _pdf;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _instructions.dispose();
    _points.dispose();
    _minutes.dispose();
    super.dispose();
  }

  Future<DateTime?> _pickWhen(DateTime? initial) async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: initial ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
    );
    if (day == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial ?? now),
    );
    if (time == null) return null;
    return DateTime(day.year, day.month, day.day, time.hour, time.minute);
  }

  Future<void> _pickPdf() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      withData: true,
    );
    final f = picked?.files.firstOrNull;
    if (f == null || !mounted) return;
    if (f.bytes == null || f.size > kMaxNotePdfBytes) {
      setState(() => _error = 'PDF over 40 MB');
      return;
    }
    setState(() {
      _pdf = f;
      _error = null;
    });
  }

  void _create() {
    final title = _title.text.trim();
    final points = int.tryParse(_points.text.trim());
    final minutesText = _minutes.text.trim();
    final minutes = minutesText.isEmpty ? null : int.tryParse(minutesText);
    String? error;
    if (title.isEmpty) {
      error = 'Title needed';
    } else if (points == null || points <= 0) {
      error = 'Points must be a number';
    } else if (minutesText.isNotEmpty &&
        (minutes == null || minutes <= 0 || minutes > kMaxAssessmentMinutes)) {
      error = 'Time limit: 1–$kMaxAssessmentMinutes min';
    } else if (_opens != null &&
        _closes != null &&
        !_closes!.isAfter(_opens!)) {
      error = 'Closes must be after opens';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(
      context,
      _NewAssignment(
        kind: _kind,
        title: title,
        instructions: _instructions.text,
        points: points!,
        opensAt: _opens,
        closesAt: _closes,
        minutes: minutes,
        pdf: _pdf,
      ),
    );
  }

  Widget _whenRow(
    String label,
    DateTime? value,
    ValueChanged<DateTime?> onChanged,
  ) => Row(
    children: [
      Expanded(
        child: Text(
          value == null ? '$label: —' : '$label: ${formatWhen(value)}',
        ),
      ),
      TextButton(
        onPressed: () async {
          final picked = await _pickWhen(value);
          if (picked != null) setState(() => onChanged(picked));
        },
        child: const Text('Set'),
      ),
      if (value != null)
        IconButton(
          tooltip: 'Clear',
          icon: const Icon(Icons.close, size: 18),
          onPressed: () => setState(() => onChanged(null)),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New assignment'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<AssignmentKind>(
                initialValue: _kind,
                decoration: const InputDecoration(labelText: 'Type'),
                items: [
                  for (final k in AssignmentKind.values)
                    DropdownMenuItem(value: k, child: Text(k.label)),
                ],
                onChanged: (k) => setState(() => _kind = k ?? _kind),
              ),
              TextField(
                controller: _title,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              TextField(
                controller: _instructions,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: 'Instructions / questions',
                ),
              ),
              TextField(
                controller: _points,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Points'),
              ),
              const SizedBox(height: 8),
              _whenRow('Opens', _opens, (v) => _opens = v),
              _whenRow('Closes', _closes, (v) => _closes = v),
              TextField(
                controller: _minutes,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Time limit (min)',
                  hintText: 'None',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _pdf == null ? 'No PDF' : _pdf!.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _pickPdf,
                    icon: const Icon(Icons.attach_file),
                    label: Text(_pdf == null ? 'Attach PDF' : 'Change'),
                  ),
                ],
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _create, child: const Text('Create')),
      ],
    );
  }
}
