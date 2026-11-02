import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/theme/app_colors.dart';
import '../../l10n/app_locale.dart';
import '../../services/pdf/diagram_detector.dart';
import '../../services/notes/note_pdf_store.dart';
import '../../shared/widgets/studio_page.dart';
import '../learn/subject_notes.dart';
import 'note_access.dart';
import 'pdf_reader.dart';
import '../teacher/teacher_pin.dart';

/// Opens [pdf] at [page] (1-based) — e.g. from the tutor's "see page 14".
/// Without a page it reopens where the reader left off.
void openNotePdf(BuildContext context, NotePdf pdf, {int? page}) {
  context.push(
    Uri(
      path: isTeacherRoute(GoRouterState.of(context).uri.path)
          ? '/teacher/note-pdf'
          : '/note-pdf',
      queryParameters: {
        'sha': pdf.sha256,
        'title': pdf.documentTitle,
        if (page != null) 'page': '$page',
      },
    ).toString(),
  );
}

/// A teacher's note as it was uploaded: the original PDF, pages and
/// pictures included, from this device's own storage.
class NotePdfScreen extends ConsumerWidget {
  const NotePdfScreen({
    super.key,
    required this.sha256,
    required this.title,
    this.initialPage = 0,
  });

  final String sha256;
  final String title;
  final int initialPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = title.isEmpty ? 'Note' : title;
    final allowed = ref.watch(notePdfAllowedProvider(sha256));
    if (allowed.valueOrNull != true) {
      return _bare(
        name,
        allowed.isLoading
            ? const Center(child: CircularProgressIndicator())
            : const NotRegisteredForNotes(),
      );
    }
    final file = ref.watch(notePdfPathProvider(sha256));
    return file.when(
      loading: () =>
          _bare(name, const Center(child: CircularProgressIndicator())),
      error: (e, _) => _bare(name, _Missing(reason: '$e')),
      data: (path) => path == null
          ? _bare(name, const _Missing())
          : PdfReader(
              path: path,
              title: name,
              memoryKey: sha256,
              initialPage: initialPage,
            ),
    );
  }

  Widget _bare(String name, Widget body) => Scaffold(
    backgroundColor: Colors.transparent,
    appBar: StudioAppBar(
      title: name,
      icon: Icons.picture_as_pdf_rounded,
      iconColor: AppColors.accentOrange,
    ),
    body: body,
  );
}

/// The stored file's path for a PDF's SHA-256, or null when it isn't here.
final notePdfPathProvider = FutureProvider.autoDispose.family<String?, String>((
  ref,
  sha,
) async {
  ref.watch(noteResourcesRevisionProvider);
  await pdfrxFlutterInitialize();
  return (await ref.read(notePdfStoreProvider).fileFor(sha))?.path;
});

class _Missing extends StatelessWidget {
  const _Missing({this.reason});

  final String? reason;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        'Not downloaded yet',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.of(context).textSecondary),
      ),
    ),
  );
}

/// "Open page 14" under a tutor reply that points at diagrams in the
/// teacher's PDFs — shown only for PDFs this learner may open and this
/// device has.
class DiagramPageButtons extends ConsumerWidget {
  const DiagramPageButtons({super.key, required this.diagrams});

  final List<DiagramMarker> diagrams;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final classUuid = ref.watch(learnerClassUuidProvider).valueOrNull;
    final pdfs =
        ref.watch(visibleNotePdfsProvider(classUuid)).valueOrNull ??
        const <NotePdf>[];
    final readable = ref.watch(readableNoteSubjectsProvider);
    if (!readable.hasValue) return const SizedBox.shrink();
    final byTitle = {
      for (final p in pdfs)
        if (canReadNotes(readable.value, p.subjectId)) p.documentTitle: p,
    };
    final buttons = [
      for (final d in diagrams)
        if (byTitle[d.document] case final pdf?)
          ActionChip(
            visualDensity: VisualDensity.compact,
            avatar: const Icon(Icons.picture_as_pdf_outlined, size: 16),
            label: Text(
              trFill(context, 'Open page {page}', {'page': '${d.page}'}),
            ),
            onPressed: () => openNotePdf(context, pdf, page: d.page),
          ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, left: 2),
      child: Wrap(spacing: 8, runSpacing: 6, children: buttons),
    );
  }
}
