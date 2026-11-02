import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../db/providers/db_provider.dart';
import '../../collaboration/sync/learner_sync_controller.dart';
import '../notes/my_notes_screen.dart';
import '../notes/note_pdf_screen.dart';
import '../notes/pdf_reader.dart';

final newClassMaterialsProvider = FutureProvider.autoDispose<int>((ref) async {
  ref.watch(readingActivityProvider);
  final learner = await ref.watch(activeStudentProvider.future);
  if (learner == null) return 0;
  final subjects = await ref.watch(myNotesProvider.future);
  final prefs = await SharedPreferences.getInstance();
  return [
    for (final subject in subjects)
      for (final (pdf, here) in subject.pdfs)
        if (here &&
            prefs.getBool('pdf_seen_${learner.id}:${pdf.sha256}') != true)
          pdf,
  ].length;
});

/// Read-only overview composed from the same notes and sync state as My notes.
class ClassLearningPanel extends ConsumerWidget {
  const ClassLearningPanel({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final learner = ref.watch(activeStudentProvider).valueOrNull;
    if (learner == null) return const SizedBox.shrink();
    final sync = ref.watch(learnerSyncProvider);
    final unread = ref.watch(newClassMaterialsProvider).valueOrNull ?? 0;
    final subjects = ref.watch(myNotesProvider).valueOrNull ?? [];
    final held = [
      for (final s in subjects)
        for (final (pdf, here) in s.pdfs)
          if (here) pdf,
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.school_outlined),
                const SizedBox(width: 8),
                Expanded(child: Text('${learner.name} · My class')),
                TextButton(
                  onPressed: () => context.push('/learners'),
                  child: const Text('Switch learner'),
                ),
              ],
            ),
            Text(sync.status),
            if (unread > 0) Text('New from your teacher: $unread materials'),
            if (sync.busy) const LinearProgressIndicator(),
            Wrap(
              spacing: 8,
              children: [
                if (held.isNotEmpty)
                  TextButton.icon(
                    icon: const Icon(Icons.book_outlined),
                    onPressed: () async {
                      final last = (await SharedPreferences.getInstance())
                          .getString('pdf_last_${learner.id}');
                      final pdf = held.firstWhere(
                        (p) => p.sha256 == last,
                        orElse: () => held.first,
                      );
                      if (context.mounted) openNotePdf(context, pdf);
                    },
                    label: const Text('Continue reading'),
                  ),
                TextButton(
                  onPressed: () => context.push('/my-notes'),
                  child: Text('My notes (${held.length})'),
                ),
                TextButton(
                  onPressed: () => context.push('/assignments'),
                  child: const Text('Assignments'),
                ),
                TextButton(
                  onPressed: sync.busy
                      ? null
                      : () => learner.classGroupId == null
                            ? context.push('/class-sync')
                            : sync.sync(),
                  child: Text(
                    learner.classGroupId == null
                        ? 'Join class'
                        : 'Get latest materials',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
