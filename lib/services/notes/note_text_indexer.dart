import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../db/providers/db_provider.dart';
import '../ocr/ocr_engine.dart';
import '../offline_storage_service.dart';
import '../pdf/pdf_page_extractor.dart';
import '../resource_import_service.dart';
import 'note_pdf_store.dart';
import 'note_quiz_builder.dart';
import 'note_background_work.dart';

/// Reads an uploaded PDF's pages into the note's text, in the background.
///
/// An upload only stores the PDF and its marker row, so the note can be
/// opened at once however long the book is. Its text — what the tutor
/// searches and the quizzes are written from — arrives here, a batch of
/// pages at a time:
///
/// - each batch is split at its headings (the heading in force at the end of
///   one batch carries into the next) and written in one insert;
/// - after each batch the next page is saved, so closing the app loses at
///   most one batch; rows of a batch cut off before it was recorded are
///   dropped on resume (by their `created_at`);
/// - once extraction finishes, [NoteQuizBuilder] writes questions from the
///   stored text, avoiding repeated model jobs as each page arrives;
/// - it stops once the note is deleted or re-uploaded.
///
/// Rows go in through drift, so the class share server's cache sees them and
/// students receive the text on their next sync.
class NoteTextIndexer {
  NoteTextIndexer(this._ref, {PdfOpener? openPdf})
    : _openPdf = openPdf ?? _defaultOpenPdf;

  static Future<PdfPageSource> _defaultOpenPdf(Uint8List bytes, String name) =>
      PdfrxPageSource.open(bytes, name: name);

  final Ref _ref;
  final PdfOpener _openPdf;
  final _queue = Queue<NotePdf>();
  bool _running = false;

  static const batchPages = 1;

  static String _id(NotePdf p) =>
      '${p.subjectId}|${p.documentTitle}|${p.sha256}';
  static String nextKey(NotePdf p) => 'note_text_next:${_id(p)}';
  static String _atKey(NotePdf p) => 'note_text_at:${_id(p)}';
  static String _topicKey(NotePdf p) => 'note_text_topic:${_id(p)}';

  /// Key of [noteReadingProvider]'s map.
  static String noteKey(String subjectId, String documentTitle) =>
      '$subjectId|$documentTitle';

  /// True while [documentTitle]'s pages are queued or being read.
  bool isReading(String subjectId, String documentTitle) => _queue.any(
    (p) => p.subjectId == subjectId && p.documentTitle == documentTitle,
  );

  /// Queues [pdf]. [fresh] (a new upload) starts from page 1.
  Future<void> enqueue(NotePdf pdf, {bool fresh = false}) async {
    if (pdf.classGroupUuid != null) return;
    final prefs = await SharedPreferences.getInstance();
    if (fresh) {
      await prefs.setInt(nextKey(pdf), 1);
      await prefs.remove(_atKey(pdf));
      await prefs.remove(_topicKey(pdf));
      // A title freed by a deleted note may be reused: drop what the quiz
      // builder recorded for the old one.
      await _ref
          .read(noteQuizBuilderProvider)
          .enqueue(pdf.subjectId, pdf.documentTitle, fresh: true);
    }
    if (!_queue.any((q) => _id(q) == _id(pdf))) {
      _queue.add(pdf);
      _setProgress(pdf, (prefs.getInt(nextKey(pdf)) ?? 1) - 1);
    }
    unawaited(_pump());
  }

  /// Queues every own PDF whose pages are not all read. A PDF imported
  /// before this existed already has its text and is marked done.
  Future<void> resumePending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final db = _ref.read(dbProvider);
      final pdfs = await _ref
          .read(notePdfStoreProvider)
          // An assignment's PDF is never read into the tutor's notes.
          .recorded(ownOnly: true, assignments: false);
      for (final p in pdfs) {
        var next = prefs.getInt(nextKey(p));
        if (next == null) {
          final text = await db.topicResourceDao.ownNoteText(
            subjectId: p.subjectId,
            documentTitle: p.documentTitle,
          );
          if (text.isNotEmpty) {
            await prefs.setInt(nextKey(p), p.pages + 1);
            continue;
          }
          next = 1;
        }
        if (p.pages == 0 || next <= p.pages) await enqueue(p);
      }
    } catch (e) {
      debugPrint('Note reading resume failed: $e');
    }
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final pdf = _queue.first;
        try {
          await _read(pdf);
        } catch (e) {
          debugPrint('Reading "${pdf.documentTitle}" failed: $e');
        }
        _queue.removeFirst();
        _clearProgress(pdf);
        _refresh(pdf);
        // Generate from the complete text once, after releasing this note.
        unawaited(
          _ref
              .read(noteQuizBuilderProvider)
              .enqueue(pdf.subjectId, pdf.documentTitle),
        );
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _read(NotePdf pdf) async {
    final store = _ref.read(notePdfStoreProvider);
    final file = await store.fileFor(pdf.sha256);
    if (file == null) return;
    final prefs = await SharedPreferences.getInstance();
    final dao = _ref.read(dbProvider).topicResourceDao;
    final storage = _ref.read(offlineStorageServiceProvider);

    final PdfPageSource source;
    try {
      source = await _openPdf(await file.readAsBytes(), 'read-${pdf.sha256}');
    } catch (e) {
      debugPrint('Reading: could not open "${pdf.documentTitle}": $e');
      await prefs.setInt(nextKey(pdf), pdf.pages + 1);
      return;
    }
    OcrEngine? ocr;
    try {
      ocr = await _ref.read(ocrEngineProvider.future);
    } catch (_) {}

    try {
      final pages = source.pageCount;
      var next = prefs.getInt(nextKey(pdf)) ?? 1;
      if (next <= 1) {
        await dao.deleteOwnNoteText(
          subjectId: pdf.subjectId,
          documentTitle: pdf.documentTitle,
        );
      } else if (prefs.getString(_atKey(pdf)) case final at?) {
        await dao.deleteOwnNoteText(
          subjectId: pdf.subjectId,
          documentTitle: pdf.documentTitle,
          createdAfter: at,
        );
      }
      var topic = prefs.getString(_topicKey(pdf)) ?? pdf.documentTitle;
      final term = await _termOf(pdf);

      while (next <= pages) {
        if (!await _stillRecorded(store, pdf)) return;
        final last = math.min(next + batchPages - 1, pages);
        final read = await _ref
            .read(noteBackgroundWorkProvider)
            .run(
              () => extractPdfPages(
                source,
                documentTitle: pdf.documentTitle,
                ocr: ocr,
                firstPage: next,
                lastPage: last,
                onProgress: (done, _) => _setProgress(pdf, done, pages),
              ),
            );
        if (!await _stillRecorded(store, pdf)) return;
        if (read.text.trim().isNotEmpty) {
          final stamp = DateTime.now();
          final sections = splitIntoSections(read.text, fallbackTitle: topic);
          for (final s in sections) {
            await storage.insertTopicResource(
              subjectId: pdf.subjectId,
              topicKey: s.title,
              resourceTitle: s.title == pdf.documentTitle
                  ? pdf.documentTitle
                  : '${pdf.documentTitle} — ${s.title}',
              content: s.body,
              termMarker: term,
              documentTitle: pdf.documentTitle,
              createdAt: stamp,
            );
          }
          if (sections.isNotEmpty) topic = sections.last.title;
        }
        // After the rows: a batch is done only once this is saved.
        await prefs.setString(
          _atKey(pdf),
          DateTime.now().toUtc().toIso8601String(),
        );
        await prefs.setString(_topicKey(pdf), topic);
        next = last + 1;
        await prefs.setInt(nextKey(pdf), next);
        _setProgress(pdf, last, pages);
        _refresh(pdf);
      }
      await prefs.setInt(nextKey(pdf), pages + 1);
    } finally {
      await source.close();
    }
  }

  Future<bool> _stillRecorded(NotePdfStore store, NotePdf pdf) async {
    final own = await store.recorded(subjectId: pdf.subjectId, ownOnly: true);
    return own.any(
      (p) => p.sha256 == pdf.sha256 && p.documentTitle == pdf.documentTitle,
    );
  }

  /// The term of the note's PDF marker, so its text files with it.
  Future<int> _termOf(NotePdf pdf) async {
    final db = _ref.read(dbProvider);
    final row =
        await (db.select(db.topicResources)
              ..where((t) => t.subjectId.equals(pdf.subjectId))
              ..where((t) => t.documentTitle.equals(pdf.documentTitle))
              ..where((t) => t.classGroupUuid.isNull())
              ..limit(1))
            .getSingleOrNull();
    return row?.termMarker ?? 0;
  }

  void _setProgress(NotePdf pdf, int done, [int? total]) {
    final key = noteKey(pdf.subjectId, pdf.documentTitle);
    final n = _ref.read(noteReadingProvider.notifier);
    n.state = {...n.state, key: (done, total ?? pdf.pages)};
  }

  void _clearProgress(NotePdf pdf) {
    final n = _ref.read(noteReadingProvider.notifier);
    n.state = {...n.state}..remove(noteKey(pdf.subjectId, pdf.documentTitle));
  }

  void _refresh(NotePdf pdf) =>
      _ref.invalidate(topicResourcesProvider(pdf.subjectId));
}

final noteTextIndexerProvider = Provider<NoteTextIndexer>(
  (ref) => NoteTextIndexer(ref),
);

/// Notes whose pages are being read, by [NoteTextIndexer.noteKey]:
/// (pages read, pages in the PDF).
final noteReadingProvider = StateProvider<Map<String, (int, int)>>(
  (ref) => const {},
);
