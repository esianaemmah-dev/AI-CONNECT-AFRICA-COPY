import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai_core/providers/ai_provider.dart';
import '../../core/theme/app_colors.dart';
import '../../db/providers/db_provider.dart';
import '../../gamification/badge_service.dart';
import '../../l10n/app_locale.dart';
import '../../services/quiz_answer_service.dart';
import '../../shared/widgets/responsive.dart';
import '../notes/note_access.dart';
import '../notes/note_pdf_screen.dart';
import '../notes/pdf_reader.dart';
import 'notes_quiz.dart';
import 'subject_notes.dart';

/// A subject's notes as the teacher uploaded them: the original PDF,
/// shown as it is. Text pulled out of a file is for the tutor only, never
/// shown here as a stand-in for the document.
class SubjectNotesTab extends ConsumerStatefulWidget {
  const SubjectNotesTab({super.key, required this.subjectId});

  final String subjectId;

  @override
  ConsumerState<SubjectNotesTab> createState() => _SubjectNotesTabState();
}

class _SubjectNotesTabState extends ConsumerState<SubjectNotesTab> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final ac = AppColors.of(context);
    final readable = ref.watch(readableNoteSubjectsProvider);
    if (readable.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!canReadNotes(readable.valueOrNull ?? const {}, widget.subjectId)) {
      return const NotRegisteredForNotes();
    }
    final notesAsync = ref.watch(subjectNotesProvider(widget.subjectId));
    return notesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(tr(context, 'Notes unavailable'))),
      data: (all) {
        // Notes with their original PDF first, so one opens by default.
        final notes = [
          ...all.where((n) => n.pdf != null),
          ...all.where((n) => n.pdf == null),
        ];
        if (notes.isEmpty) {
          return Center(
            child: Text(
              tr(context, 'No notes yet'),
              style: TextStyle(color: ac.textSecondary),
            ),
          );
        }
        final note = notes.firstWhere(
          (n) => n.title == _selected,
          orElse: () => notes.first,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (notes.length > 1)
              SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  children: [
                    for (final n in notes)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          avatar: Icon(
                            n.pdf != null
                                ? Icons.picture_as_pdf_outlined
                                : Icons.description_outlined,
                            size: 16,
                          ),
                          label: Text(n.title),
                          selected: n.title == note.title,
                          onSelected: (_) =>
                              setState(() => _selected = n.title),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: _NoteBody(key: ValueKey(note.title), note: note),
            ),
          ],
        );
      },
    );
  }
}

class _NoteBody extends ConsumerWidget {
  const _NoteBody({super.key, required this.note});

  final SubjectNote note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ac = AppColors.of(context);
    final pdf = note.pdf;
    if (pdf != null && note.pdfOnDevice) {
      final path = ref.watch(notePdfPathProvider(pdf.sha256)).valueOrNull;
      if (path == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return PdfReader(
        path: path,
        title: note.title,
        memoryKey: pdf.sha256,
        embedded: true,
        onFullScreen: () => openNotePdf(context, pdf),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          tr(
            context,
            pdf == null
                ? 'Original not kept. Re-upload the PDF to view it.'
                : 'Not downloaded yet',
          ),
          textAlign: TextAlign.center,
          style: TextStyle(color: ac.textSecondary),
        ),
      ),
    );
  }
}

/// Questions written from the subject's notes, answered in place.
class SubjectQuizTab extends ConsumerStatefulWidget {
  const SubjectQuizTab({super.key, required this.subjectId});

  final String subjectId;

  @override
  ConsumerState<SubjectQuizTab> createState() => _SubjectQuizTabState();
}

class _SubjectQuizTabState extends ConsumerState<SubjectQuizTab> {
  String get subjectId => widget.subjectId;

  @override
  void initState() {
    super.initState();
    // Questions written ahead from the notes come up at once, no button.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final quiz = ref.read(subjectQuizProvider(subjectId));
      if (quiz.questions.isEmpty && !quiz.generating) {
        ref.read(subjectQuizProvider(subjectId).notifier).startStored();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppColors.of(context);
    final quiz = ref.watch(subjectQuizProvider(subjectId));
    final notifier = ref.read(subjectQuizProvider(subjectId).notifier);
    // The quiz and the chat share one engine.
    final chatBusy = ref.watch(
      chatProvider.select((c) => c.valueOrNull?.isGenerating ?? false),
    );

    final topics =
        ref.watch(subjectQuizTopicsProvider(subjectId)).valueOrNull ??
        const <(String, int)>[];
    final topicChips = topics.isEmpty
        ? null
        : _TopicChips(
            topics: topics,
            selected: quiz.topic,
            onSelected: (t) => notifier.startStored(topic: t),
          );

    if (quiz.questions.isEmpty && !quiz.generating) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (topicChips != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: topicChips,
              ),
              const SizedBox(height: 16),
            ],
            Icon(Icons.quiz_outlined, size: 48, color: ac.textSecondary),
            const SizedBox(height: 12),
            if (quiz.error != null) ...[
              Text(
                tr(context, quiz.error!),
                style: TextStyle(color: ac.textSecondary),
              ),
              const SizedBox(height: 12),
            ],
            FilledButton.icon(
              onPressed: chatBusy ? null : () => notifier.start(),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(tr(context, 'Start quiz')),
            ),
          ],
        ),
      );
    }

    return MaxWidth(
      maxWidth: 820,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          if (topicChips != null) ...[topicChips, const SizedBox(height: 12)],
          Row(
            children: [
              Text(
                trFill(context, 'Score {score}/{total}', {
                  'score': '${quiz.score}',
                  'total': '${quiz.answers.length}',
                }),
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: ac.textPrimary,
                ),
              ),
              const Spacer(),
              if (quiz.generating)
                Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${quiz.questions.length}/${quiz.target}',
                      style: TextStyle(fontSize: 12, color: ac.textSecondary),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < quiz.questions.length; i++)
            _QuestionCard(
              index: i,
              subjectId: subjectId,
              chosen: quiz.answers[i],
            ),
          if (quiz.finished) ...[
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: chatBusy
                  ? null
                  : () => notifier.start(topic: quiz.topic),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(tr(context, 'New quiz')),
            ),
          ],
        ],
      ),
    );
  }
}

/// "All topics" and one chip per topic with stored questions.
class _TopicChips extends StatelessWidget {
  const _TopicChips({
    required this.topics,
    required this.selected,
    required this.onSelected,
  });

  final List<(String, int)> topics;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          ChoiceChip(
            label: Text(tr(context, 'All topics')),
            selected: selected == null,
            onSelected: (_) => onSelected(null),
          ),
          for (final (topic, count) in topics) ...[
            const SizedBox(width: 8),
            ChoiceChip(
              label: Text('$topic ($count)'),
              selected: selected == topic,
              onSelected: (_) => onSelected(topic),
            ),
          ],
        ],
      ),
    );
  }
}

class _QuestionCard extends ConsumerWidget {
  const _QuestionCard({
    required this.index,
    required this.subjectId,
    required this.chosen,
  });

  final int index;
  final String subjectId;
  final int? chosen;

  Future<void> _choose(WidgetRef ref, int option, bool correct) async {
    ref.read(subjectQuizProvider(subjectId).notifier).answer(index, option);
    final student = await ref.read(activeStudentProvider.future);
    if (student == null) return;
    await ref
        .read(badgeServiceProvider)
        .onPracticeAnswered(student.id, attempted: 1, correct: correct ? 1 : 0);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ac = AppColors.of(context);
    final quiz = ref.watch(subjectQuizProvider(subjectId));
    final q = quiz.questions[index];
    final answered = chosen != null;
    final tutorUsed = quiz.tutorUsed.contains(index);
    final chatBusy = ref.watch(chatProvider.select((chat) => chat.valueOrNull?.isGenerating ?? false));
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${index + 1}. ${q.question}',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                height: 1.4,
                color: ac.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            for (var o = 0; o < q.options.length; o++)
              _Option(
                letter: String.fromCharCode(65 + o),
                text: q.options[o],
                state: !answered
                    ? _OptionState.open
                    : o == q.correct
                    ? _OptionState.correct
                    : o == chosen
                    ? _OptionState.wrong
                    : _OptionState.idle,
                onTap: answered ? null : () => _choose(ref, o, o == q.correct),
              ),
            // Answer with AI: the model explains the answer, in the
            // learner's language. Using it marks the question AI-assisted.
            if (quiz.explaining.contains(index))
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('Asking AI…', style: TextStyle(fontSize: 12)),
                  ],
                ),
              )
            else if (!quiz.explanations.containsKey(index))
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: chatBusy || quiz.explaining.isNotEmpty ? null : () => ref
                      .read(subjectQuizProvider(subjectId).notifier)
                      .explain(index),
                  icon: const Icon(Icons.smart_toy_outlined, size: 18),
                  label: Text(tr(context, 'Answer with AI')),
                ),
              ),
            if (tutorUsed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    const Icon(
                      Icons.smart_toy_outlined,
                      size: 14,
                      color: AppColors.accentOrange,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      tr(context, 'Answered with AI'),
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.accentOrange,
                      ),
                    ),
                  ],
                ),
              ),
            if (quiz.explanations[index] case final ai?) ...[
              const SizedBox(height: 8),
              Text('${tr(context, 'Correct answer')}: ${quizAnswerLabel(q)}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.accentOrange.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  ai,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: ac.textPrimary,
                  ),
                ),
              ),
            ] else if (answered && q.explanation.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                q.explanation,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: ac.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum _OptionState { open, idle, correct, wrong }

class _Option extends StatelessWidget {
  const _Option({
    required this.letter,
    required this.text,
    required this.state,
    required this.onTap,
  });

  final String letter;
  final String text;
  final _OptionState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final divider = Theme.of(context).dividerColor;
    final (border, fill, icon) = switch (state) {
      _OptionState.correct => (
        AppColors.teachColor,
        AppColors.teachColor.withValues(alpha: 0.08),
        Icons.check_circle,
      ),
      _OptionState.wrong => (
        Colors.red,
        Colors.red.withValues(alpha: 0.06),
        Icons.cancel,
      ),
      _ => (divider, Colors.transparent, null),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: border),
          ),
          child: Row(
            children: [
              Text(letter, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(width: 12),
              Expanded(child: Text(text)),
              if (icon != null) Icon(icon, size: 18, color: border),
            ],
          ),
        ),
      ),
    );
  }
}
