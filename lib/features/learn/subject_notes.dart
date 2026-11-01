import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db/daos/topic_resource_dao.dart' show kRecordTopicPrefix;
import '../../db/otic_database.dart';
import '../../db/note_document_title.dart';
import '../../db/providers/db_provider.dart';
import '../../curriculum/curriculum_models.dart';
import '../../curriculum/curriculum_provider.dart';
import '../../services/custom_subject_service.dart';
import '../../services/notes/note_pdf_store.dart';
import '../../services/pdf/diagram_detector.dart';
import '../../services/resource_text_extractor.dart';

/// One teacher note in a subject, as a learner sees it: the original PDF
/// when there is one, and its text.
class SubjectNote {
  const SubjectNote({
    required this.title,
    required this.passages,
    this.pdf,
    this.pdfOnDevice = false,
  });

  final String title;

  /// The note's text, chunk by chunk, diagram markers made readable.
  final List<String> passages;
  final NotePdf? pdf;

  /// Whether [pdf]'s file is on this device (a student's arrives on sync).
  final bool pdfOnDevice;

  String get text => passages.join('\n\n');
}

/// The active learner's class (`group_uuid`): on a shared device it decides
/// whose received notes they may see.
final learnerClassUuidProvider = FutureProvider.autoDispose<String?>((
  ref,
) async {
  final me = await ref.watch(activeStudentProvider.future);
  final id = me?.classGroupId;
  if (id == null) return null;
  final db = ref.watch(dbProvider);
  final group = await (db.select(
    db.classGroups,
  )..where((t) => t.id.equals(id))).getSingleOrNull();
  return group?.groupUuid;
});

/// [subjectId]'s notes this learner may read: this device's own, plus
/// those received for their class — never another class's.
final subjectNotesProvider = FutureProvider.autoDispose
    .family<List<SubjectNote>, String>((ref, subjectId) async {
      ref.watch(noteResourcesRevisionProvider);
      final classUuid = await ref.watch(learnerClassUuidProvider.future);
      final db = ref.watch(dbProvider);
      final store = ref.watch(notePdfStoreProvider);
      final rows = await db.topicResourceDao.chunksForSubject(
        subjectId: subjectId,
        visibleClassUuid: classUuid,
        // Every page of every note — a cap cut off later pages and notes.
        limit: null,
      );
      final pdfs = {
        for (final p in await store.visibleTo(classUuid))
          if (p.subjectId == subjectId) p.documentTitle: p,
      };
      return buildSubjectNotes(rows, pdfs, (sha) => store.has(sha));
    });

/// Subjects this learner has notes in, as (id, name) — their class's and
/// this device's own, never another class's.
final learnerNoteSubjectsProvider =
    FutureProvider.autoDispose<List<(String, String)>>((ref) async {
      ref.watch(noteResourcesRevisionProvider);
      final classUuid = await ref.watch(learnerClassUuidProvider.future);
      final db = ref.watch(dbProvider);
      final ids = await db.topicResourceDao.subjectIdsWithNotes(
        visibleClassUuid: classUuid,
      );
      final byId = await ref.watch(subjectsByIdProvider.future);
      return [
        for (final id in ids) (id, byId[id]?.name ?? subjectNameFromId(id)),
      ]..sort((a, b) => a.$2.toLowerCase().compareTo(b.$2.toLowerCase()));
    });

/// How many notes (uploaded files) the active learner may read in each
/// subject — what the subject's Notes tab lists.
final noteCountsProvider = FutureProvider.autoDispose<Map<String, int>>((
  ref,
) async {
  ref.watch(noteResourcesRevisionProvider);
  final classUuid = await ref.watch(learnerClassUuidProvider.future);
  final rows = await ref
      .watch(dbProvider)
      .topicResourceDao
      .visibleNoteTitles(visibleClassUuid: classUuid);
  final titles = <String, Set<String>>{};
  for (final (subject, document, resource) in rows) {
    (titles[subject] ??= {}).add(document ?? legacyDocumentTitle(resource));
  }
  return {for (final e in titles.entries) e.key: e.value.length};
});

/// Every subject by id, for its name and card look: the school's and the
/// built-ins (even ones the Admin removed, so notes received for them still
/// sit under their subject).
final subjectsByIdProvider = FutureProvider.autoDispose<Map<String, Subject>>((
  ref,
) async {
  return {
    for (final s in await ref.watch(allSubjectsProvider.future)) s.id: s,
    for (final s in await ref.watch(mergedSubjectsProvider.future)) s.id: s,
  };
});

/// A readable name for a subject id with no record here, e.g.
/// `local_farming` → "Local Farming".
String subjectNameFromId(String id) => id
    .split('_')
    .where((w) => w.isNotEmpty)
    .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
    .join(' ');

/// Groups chunk [rows] into notes, oldest first, in upload order.
Future<List<SubjectNote>> buildSubjectNotes(
  List<TopicResource> rows,
  Map<String, NotePdf> pdfs,
  Future<bool> Function(String sha) onDevice,
) async {
  final sorted = [
    for (final r in rows)
      if (!r.topicKey.startsWith(kRecordTopicPrefix)) r,
  ]..sort((a, b) => a.id.compareTo(b.id));
  final byTitle = <String, List<String>>{};
  for (final r in sorted) {
    final title = r.documentTitle ?? legacyDocumentTitle(r.resourceTitle);
    final text = readableNoteText(r.contentChunk);
    if (text.isNotEmpty) (byTitle[title] ??= []).add(text);
  }
  for (final t in pdfs.keys) {
    byTitle.putIfAbsent(t, () => []);
  }
  return [
    for (final e in byTitle.entries)
      SubjectNote(
        title: e.key,
        passages: e.value,
        pdf: pdfs[e.key],
        pdfOnDevice: pdfs[e.key] != null && await onDevice(pdfs[e.key]!.sha256),
      ),
  ];
}

/// The document a section row stored before `document_title` existed
/// belongs to: its title was "Document — Section". Without this, each
/// section of one old upload showed as its own partial note.
String legacyDocumentTitle(String resourceTitle) {
  return legacyNoteDocumentTitle(resourceTitle);
}

/// Chunk text with each `[DIAGRAM: …]` marker turned into a short line.
String readableNoteText(String chunk) {
  // Notes stored before unreadable lines were dropped at import.
  var out = dropUnreadableLines(chunk);
  for (final m in DiagramMarker.parseAll(chunk)) {
    final what = m.hasCaption ? m.caption : 'Diagram';
    out = out.replaceFirst(m.format(), '[$what — page ${m.page}]');
  }
  return out.trim();
}
