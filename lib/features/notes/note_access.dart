import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/policy/policy.dart';
import '../../core/theme/app_colors.dart';
import '../../l10n/app_locale.dart';
import '../../services/notes/note_pdf_store.dart';
import '../learn/subject_notes.dart';

/// Subjects whose notes the person at the device may read (see
/// [Policy.watchReadableSubjects]): null means every subject. Nobody
/// deletes notes from here; that stays in the PIN-gated Lesson materials.
final readableNoteSubjectsProvider = StreamProvider.autoDispose<Set<String>?>((
  ref,
) async* {
  final actor = await ref.watch(notesActorProvider.future);
  yield* ref.watch(policyProvider).watchReadableSubjects(actor);
});

bool canReadNotes(Set<String>? readable, String subjectId) =>
    readable == null || readable.contains(subjectId);

/// Whether the active learner may open the PDF with this SHA-256: it must
/// be one their class can see, in a subject they registered for.
final notePdfAllowedProvider = FutureProvider.autoDispose.family<bool, String>((
  ref,
  sha,
) async {
  ref.watch(noteResourcesRevisionProvider);
  final readable = await ref.watch(readableNoteSubjectsProvider.future);
  if (readable == null) return true;
  final classUuid = await ref.watch(learnerClassUuidProvider.future);
  for (final p
      in await ref
          .watch(notePdfStoreProvider)
          .visibleTo(classUuid, assignments: true)) {
    if (p.sha256 == sha && readable.contains(p.subjectId)) return true;
  }
  return false;
});

/// Shown in place of a subject's notes to a learner not registered for it.
class NotRegisteredForNotes extends StatelessWidget {
  const NotRegisteredForNotes({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.lock_outline_rounded,
            size: 40,
            color: AppColors.of(context).textSecondary,
          ),
          const SizedBox(height: 12),
          Text(
            tr(context, 'Join your class to read its learning materials'),
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.of(context).textSecondary),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => context.push('/class-sync'),
            child: Text(tr(context, 'Join a class')),
          ),
        ],
      ),
    ),
  );
}
