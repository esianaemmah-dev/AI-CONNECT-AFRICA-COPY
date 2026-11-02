import '../learn/class_learning_panel.dart';
import '../../collaboration/sync/learner_sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../l10n/app_locale.dart';
import '../../services/notes/note_pdf_store.dart';
import '../../services/notes/note_quiz_builder.dart';
import '../../services/notes/note_quiz_store.dart';
import '../../shared/widgets/responsive.dart';
import '../../shared/widgets/studio_page.dart';
import '../learn/notes_quiz.dart';
import '../learn/subject_badge.dart';
import '../learn/subject_notes.dart';
import 'note_access.dart';
import 'note_pdf_screen.dart';

/// One subject's PDFs in My notes, and whether each file is on the device.
class MyNotesSubject {
  const MyNotesSubject(this.id, this.name, this.pdfs, [this.quizzes = const {}]);

  final String id;
  final String name;
  final List<(NotePdf, bool)> pdfs;

  /// Quiz questions written from each note so far, by document title.
  final Map<String, int> quizzes;
}

/// The teacher's PDFs for every subject in the active learner's class
/// (all subjects on the teacher's own device). Read-only.
final myNotesProvider = FutureProvider.autoDispose<List<MyNotesSubject>>((
  ref,
) async {
  ref.watch(noteResourcesRevisionProvider);
  final readable = await ref.watch(readableNoteSubjectsProvider.future);
  final classUuid = await ref.watch(learnerClassUuidProvider.future);
  final subjects = await ref.watch(learnerNoteSubjectsProvider.future);
  final store = ref.watch(notePdfStoreProvider);
  final quizStore = ref.watch(noteQuizStoreProvider);
  final pdfs = await store.visibleTo(classUuid);
  return [
    for (final (id, name) in subjects)
      if (canReadNotes(readable, id))
        MyNotesSubject(
          id,
          name,
          [
            for (final p in pdfs)
              if (p.subjectId == id) (p, await store.has(p.sha256)),
          ],
          _countByNote(await quizStore.questions(id, classUuid: classUuid)),
        ),
  ].where((s) => s.pdfs.isNotEmpty).toList();
});

Map<String, int> _countByNote(List<StoredQuizQuestion> questions) {
  final counts = <String, int>{};
  for (final q in questions) {
    counts[q.documentTitle] = (counts[q.documentTitle] ?? 0) + 1;
  }
  return counts;
}

/// Opens the subject's Quiz tab on a round of [documentTitle]'s questions.
Future<void> _takeQuiz(
  BuildContext context,
  WidgetRef ref,
  String subjectId,
  String documentTitle,
) async {
  await ref
      .read(subjectQuizProvider(subjectId).notifier)
      .startStored(documentTitle: documentTitle);
  if (!context.mounted) return;
  // Tab 1 is Quiz on every subject (UnitsScreen).
  await context.push('/learn/subject/${Uri.encodeComponent(subjectId)}?tab=1');
}

class MyNotesScreen extends ConsumerWidget {
  const MyNotesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(learnerSyncProvider);
    final ac = AppColors.of(context);
    final notes = ref.watch(myNotesProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: StudioAppBar(
        title: tr(context, 'My notes'),
        icon: Icons.picture_as_pdf_rounded,
        iconColor: AppColors.accentOrange,
        actions: [
          IconButton(
            tooltip: tr(context, 'Share with a classmate'),
            icon: const Icon(Icons.group_rounded),
            onPressed: () => context.push('/classmate-sync'),
          ),
        ],
      ),
      body: notes.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(tr(context, 'Notes unavailable'))),
        data: (subjects) => subjects.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr(context, 'No notes for your subjects'),
                      style: TextStyle(color: ac.textSecondary),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () => context.push('/class-sync'),
                      child: Text(tr(context, 'Join a class')),
                    ),
                  ],
                ),
              )
            : MaxWidth(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    const ClassLearningPanel(),
                    // One collapsible section per subject.
                    for (final s in subjects)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: StudioCard(
                        padding: EdgeInsets.zero,
                        child: Theme(
                          data: Theme.of(context)
                              .copyWith(dividerColor: Colors.transparent),
                          child: ExpansionTile(
                            initiallyExpanded: true,
                            leading: SubjectBadge(subjectId: s.id, size: 30),
                            title: Text(
                              s.name,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: ac.textPrimary,
                              ),
                            ),
                            subtitle: Text(
                              trFill(context, '{n} notes', {'n': '${s.pdfs.length}'}),
                              style: TextStyle(
                                fontSize: 12,
                                color: ac.textSecondary,
                              ),
                            ),
                            children: [
                              for (final (pdf, here) in s.pdfs)
                                ListTile(
                                  leading: Icon(
                                    Icons.picture_as_pdf_outlined,
                                    color: here
                                        ? AppColors.accentOrange
                                        : ac.textHint,
                                  ),
                                  title: Text(pdf.documentTitle),
                                  subtitle: Text(
                                    here
                                        ? trFill(context, '{n} pages', {
                                            'n': '${pdf.pages}',
                                          })
                                        : tr(context, 'Not downloaded yet'),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if ((s.quizzes[pdf.documentTitle] ?? 0) >
                                          0)
                                        TextButton.icon(
                                          onPressed: () => _takeQuiz(
                                            context,
                                            ref,
                                            s.id,
                                            pdf.documentTitle,
                                          ),
                                          icon: const Icon(
                                            Icons.quiz_outlined,
                                            size: 18,
                                          ),
                                          label: Text(tr(context, 'Take quiz')),
                                        ),
                                      if (here)
                                        const Icon(Icons.chevron_right_rounded),
                                    ],
                                  ),
                                  enabled: here,
                                  onTap: () => openNotePdf(context, pdf),
                                ),
                              // Open the whole subject in Learn.
                              ListTile(
                                leading: const Icon(Icons.menu_book_outlined),
                                title: Text(tr(context, 'Open subject')),
                                trailing: const Icon(Icons.chevron_right_rounded),
                                onTap: () => context.push(
                                  '/learn/subject/${Uri.encodeComponent(s.id)}',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}
