import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:ai_connect_africa/ai_core/inference/inference_engine.dart';
import 'package:ai_connect_africa/curriculum/curriculum_models.dart';
import 'package:ai_connect_africa/db/otic_database.dart';
import 'package:ai_connect_africa/db/providers/db_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ai_connect_africa/features/learn/notes_quiz.dart';
import 'package:ai_connect_africa/services/notes/note_pdf_store.dart';
import 'package:ai_connect_africa/services/notes/note_quiz_builder.dart';
import 'package:ai_connect_africa/services/notes/note_quiz_store.dart';
import 'package:ai_connect_africa/services/notes/note_text_indexer.dart';
import 'package:ai_connect_africa/services/notes/note_background_work.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_connect_africa/services/notes/quiz_scores.dart';
import 'package:ai_connect_africa/services/ocr/ocr_engine.dart';
import 'package:ai_connect_africa/services/offline_storage_service.dart';
import 'package:ai_connect_africa/services/pdf/pdf_page_extractor.dart';
import 'package:ai_connect_africa/services/resource_import_service.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// A PDF with [pages] pages that fails the test if any page is read.
class _UnreadPdf implements PdfPageSource {
  _UnreadPdf(this.pages);
  final int pages;
  bool closed = false;

  @override
  int get pageCount => pages;

  @override
  Future<PageText> text(int page) => throw StateError('page $page was read');

  @override
  Future<RenderedPage?> render(int page, {required int maxSide}) =>
      throw StateError('page $page was rendered');

  @override
  Future<void> close() async => closed = true;
}

/// Writes a question keyed to "Carbon dioxide", and when asked to check
/// one, answers with the letter of [checkAnswer] wherever it was shuffled.
class _QuizEngine extends InferenceEngine {
  _QuizEngine({this.checkAnswer = 'Carbon dioxide'});
  final String checkAnswer;

  @override
  bool get isReady => true;
  @override
  String get backendLabel => 'Fake';
  @override
  Future<void> loadModel(String modelPath) async {}
  @override
  Future<String> generate({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
    TokenCallback? onToken,
    String? systemPrompt,
  }) async {
    if (prompt.contains('Reply with the letter')) {
      final line = RegExp(
        '^([ABCD])\\) ${RegExp.escape(checkAnswer)}\$',
        multiLine: true,
      ).firstMatch(prompt);
      return line?[1] ?? 'A';
    }
    return '{"question": "What gas do plants take in?", "options": '
        '["Carbon dioxide", "Oxygen", "Nitrogen", "Helium"], '
        '"correctIndex": 0, "explanation": "Plants take in carbon dioxide."}';
  }

  @override
  Future<void> dispose() async {}
}

const _passage =
    'Plants take in carbon dioxide from the air through their leaves. '
    'Using sunlight and water they turn it into glucose and give out oxygen.';

class _TextPdf extends _UnreadPdf {
  _TextPdf() : super(3);

  @override
  Future<PageText> text(int page) async => const PageText(_passage, []);

  @override
  Future<RenderedPage?> render(int page, {required int maxSide}) async => null;
}

class _RecordingBuilder extends NoteQuizBuilder {
  _RecordingBuilder(super.ref);
  final completed = Completer<void>();
  int calls = 0;

  @override
  Future<void> enqueue(
    String subjectId,
    String documentTitle, {
    bool fresh = false,
  }) async {
    calls++;
    if (!completed.isCompleted) completed.complete();
  }
}

void main() {
  group('uploading a PDF', () {
    late OticDatabase db;
    late Directory dir;
    late NotePdfStore store;

    setUp(() async {
      db = OticDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
      dir = await Directory.systemTemp.createTemp('otic_upload');
      store = NotePdfStore(db, root: () async => dir);
    });
    tearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });

    test(
      'extracts in the background and queues generation once at completion',
      () async {
        SharedPreferences.setMockInitialValues({});
        final pdf = _TextPdf();
        late _RecordingBuilder builder;
        final container = ProviderContainer(
          overrides: [
            dbProvider.overrideWithValue(db),
            notePdfStoreProvider.overrideWithValue(store),
            ocrEngineProvider.overrideWith((ref) async => null),
            noteBackgroundWorkProvider.overrideWithValue(
              NoteBackgroundWork(pause: Duration.zero),
            ),
            noteQuizBuilderProvider.overrideWith(
              (ref) => builder = _RecordingBuilder(ref),
            ),
            noteTextIndexerProvider.overrideWith(
              (ref) => NoteTextIndexer(ref, openPdf: (_, _) async => pdf),
            ),
          ],
        );
        addTearDown(container.dispose);
        final bytes = Uint8List.fromList('%PDF-1.4 book'.codeUnits);
        final sha = (await store.put(bytes))!;
        await store.recordOwn(
          subjectId: 'biology',
          documentTitle: 'Book',
          sha: sha,
          pages: 3,
          bytes: bytes.length,
        );
        final marker = (await store.recorded()).single;
        builder = container.read(noteQuizBuilderProvider) as _RecordingBuilder;
        await container.read(noteTextIndexerProvider).enqueue(marker);
        await builder.completed.future.timeout(const Duration(seconds: 5));
        expect(builder.calls, 1);
        expect(pdf.closed, isTrue);
        expect(
          container.read(noteTextIndexerProvider).isReading('biology', 'Book'),
          isFalse,
        );
        expect(
          await db.topicResourceDao.ownNoteText(
            subjectId: 'biology',
            documentTitle: 'Book',
          ),
          hasLength(3),
        );
      },
    );

    test(
      'saves at once, reading no page, and hands it to the reader',
      () async {
        final pdf = _UnreadPdf(600);
        final handed = <NotePdf>[];
        final noted = <String>[];
        final report =
            await ResourceImportService(
              OfflineStorageService(db),
              openPdf: (_, _) async => pdf,
              pdfStore: store,
              onPdfSaved: handed.add,
              onNoteSaved: (_, title) => noted.add(title),
            ).importBytes(
              fileName: 'Biology_Book.pdf',
              bytes: Uint8List.fromList('%PDF-1.4 a big book'.codeUnits),
              subjectId: 'biology',
              documentTitle: 'Biology Book (2)',
            );

        expect(report.ok, isTrue, reason: report.failure);
        expect(report.readingLater, isTrue);
        expect(report.pageCount, 600);
        expect(pdf.closed, isTrue);
        expect(handed.single.pages, 600);
        expect(handed.single.documentTitle, 'Biology Book (2)');
        // Questions wait for text, which the reader writes later.
        expect(noted, isEmpty);

        // Openable now: the marker is there and the file is kept.
        final recorded = await store.recorded(subjectId: 'biology');
        expect(recorded.single.documentTitle, 'Biology Book (2)');
        expect(await store.fileFor(recorded.single.sha256), isNotNull);
        final text = await db.topicResourceDao.ownNoteText(
          subjectId: 'biology',
          documentTitle: 'Biology Book (2)',
        );
        expect(text, isEmpty);
      },
    );

    test('a second file in the subject is added beside the first', () async {
      final importer = ResourceImportService(
        OfflineStorageService(db),
        openPdf: (_, _) async => _UnreadPdf(3),
        pdfStore: store,
        onPdfSaved: (_) {},
      );
      for (final (name, body) in [
        ('Term 1.pdf', 'one'),
        ('Term 2.pdf', 'two'),
      ]) {
        await importer.importBytes(
          fileName: name,
          bytes: Uint8List.fromList('%PDF-1.4 $body'.codeUnits),
          subjectId: 'biology',
        );
      }
      final titles = (await store.recorded(
        subjectId: 'biology',
      )).map((p) => p.documentTitle).toSet();
      expect(titles, {'Term 1', 'Term 2'});
    });

    test('an already open PDF list updates on save and deletion', () async {
      final container = ProviderContainer(
        overrides: [
          dbProvider.overrideWithValue(db),
          notePdfStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      final provider = ownNotePdfsProvider('biology');
      final saved = <String>[];
      final removed = <String>[];
      final added = container.listen(provider, (_, value) {
        if (value.valueOrNull?.containsKey('Book') == true) saved.add('Book');
        if (saved.isNotEmpty && value.valueOrNull?.isEmpty == true) {
          removed.add('Book');
        }
      });
      addTearDown(added.close);
      expect(await container.read(provider.future), isEmpty);
      await ResourceImportService(
        OfflineStorageService(db),
        openPdf: (_, _) async => _UnreadPdf(600),
        pdfStore: store,
        onPdfSaved: (_) {},
      ).importBytes(
        fileName: 'Book.pdf',
        bytes: Uint8List.fromList('%PDF-1.4 book'.codeUnits),
        subjectId: 'biology',
      );
      await pumpEventQueue(times: 50);
      expect(saved, isNotEmpty);
      expect((await container.read(provider.future))['Book']?.pages, 600);
      await db.delete(db.topicResources).go();
      await pumpEventQueue(times: 50);
      expect(removed, isNotEmpty);
    });
  });

  test(
    'resuming drops only rows of a batch cut off before it was recorded',
    () async {
      final db = OticDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      addTearDown(db.close);
      final storage = OfflineStorageService(db);
      final before = DateTime.utc(2026, 10, 6, 9);
      final recordedAt = DateTime.utc(2026, 10, 6, 9, 1);
      final after = DateTime.utc(2026, 10, 6, 9, 2);
      for (final (topic, at) in [('Cells', before), ('Tissues', after)]) {
        await storage.insertTopicResource(
          subjectId: 'biology',
          topicKey: topic,
          resourceTitle: 'Book — $topic',
          content: 'Notes about $topic and how they work in living things.',
          documentTitle: 'Book',
          createdAt: at,
        );
      }
      await db.topicResourceDao.insertQuizRow(
        subjectId: 'biology',
        documentTitle: 'Book',
        content: '[QUIZ: page=0] {}',
        termMarker: 0,
      );

      await db.topicResourceDao.deleteOwnNoteText(
        subjectId: 'biology',
        documentTitle: 'Book',
        createdAfter: recordedAt.toIso8601String(),
      );
      final left = await db.topicResourceDao.ownNoteText(
        subjectId: 'biology',
        documentTitle: 'Book',
      );
      expect(left.map((r) => r.topicKey), ['cells']);
      expect(
        await db.topicResourceDao.quizRows(subjectId: 'biology'),
        hasLength(1),
      );
    },
  );

  group('topics', () {
    TopicResource row(int id, String topic, String content) => TopicResource(
      id: id,
      subjectId: 'biology',
      topicKey: topic.toLowerCase(),
      termMarker: 0,
      resourceTitle: 'Book — $topic',
      contentChunk: content,
      createdAt: '2026-10-06T00:00:00Z',
      documentTitle: 'Book',
    );

    test('group a note’s rows by heading, in order', () {
      final topics = noteTopics([
        row(1, 'Cells', 'Cells are small.'),
        row(2, 'Tissues', 'Tissues are groups of cells.'),
        row(3, 'Cells', 'Cells divide.'),
      ], 'Book');
      expect(topics.map((t) => t.title), ['Cells', 'Tissues']);
      expect(topics.first.text, 'Cells are small.\n\nCells divide.');
    });

    test('ask more about a long topic, never about a caption', () {
      expect(topicPassages('Figure 1'), isEmpty);
      expect(topicPassages(_passage), hasLength(1));
      final long = List.filled(30, _passage).join('\n\n');
      final passages = topicPassages(long);
      expect(passages.length, greaterThan(1));
      expect(passages.length, lessThanOrEqualTo(8));
    });
  });

  group('marking by the notes', () {
    const q = QuizQuestion(
      question: 'What gas do plants take in?',
      options: ['Carbon dioxide', 'Oxygen', 'Nitrogen', 'Helium'],
      correct: 0,
      explanation: '',
    );

    test('shuffled options keep the same answer', () {
      for (var seed = 0; seed < 10; seed++) {
        final s = NotesQuizGenerator.shuffleOptions(q, Random(seed));
        expect(s.options[s.correct], 'Carbon dioxide');
        expect(s.options.toSet(), q.options.toSet());
      }
    });

    test('a key the passage contradicts is caught', () {
      expect(NotesQuizGenerator.groundedInPassage(q, _passage), isTrue);
      const wrong = QuizQuestion(
        question: 'What gas do plants take in?',
        options: ['Helium', 'Carbon dioxide from the air', 'Neon', 'Argon'],
        correct: 0,
        explanation: '',
      );
      expect(NotesQuizGenerator.groundedInPassage(wrong, _passage), isFalse);
    });

    test(
      'a question is kept only when the notes give the same answer',
      () async {
        final kept = await NotesQuizGenerator(
          _QuizEngine(),
        ).checkedQuestion(_passage, subject: 'Biology', random: Random(3));
        expect(kept.question, isNotNull);
        expect(
          kept.question!.options[kept.question!.correct],
          'Carbon dioxide',
        );

        final dropped = await NotesQuizGenerator(
          _QuizEngine(checkAnswer: 'Oxygen'),
        ).checkedQuestion(_passage, subject: 'Biology', random: Random(3));
        expect(dropped.question, isNull);
        expect(dropped.engineFailed, isFalse);
      },
    );

    test('a stored question keeps its topic', () {
      final back = NoteQuizStore.parse(
        NoteQuizStore.format(q, 0, topic: 'Photosynthesis'),
      )!;
      expect(back.topic, 'Photosynthesis');
      expect(NoteQuizStore.parse(NoteQuizStore.format(q, 3))!.topic, isNull);
    });
  });

  test('quiz scores: latest round and best per topic', () async {
    final db = OticDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    addTearDown(db.close);
    final scores = QuizScores(db);
    await scores.record(
      studentId: 1,
      subjectId: 'biology',
      byTopic: {'Cells': (4, 5, 0), 'Tissues': (1, 2, 0)},
      at: DateTime.utc(2026, 10, 5),
    );
    await scores.record(
      studentId: 1,
      subjectId: 'biology',
      byTopic: {'Cells': (2, 5, 1)},
      at: DateTime.utc(2026, 10, 6),
    );
    await scores.record(
      studentId: 2,
      subjectId: 'biology',
      byTopic: {'Cells': (5, 5, 0)},
    );

    final mine = await scores.watch(1).first;
    expect(mine.map((s) => s.topic), ['Cells', 'Tissues']);
    final cells = mine.first;
    expect((cells.lastCorrect, cells.lastTotal), (2, 5));
    expect(cells.bestPercent, 80);
    expect(cells.rounds, 2);
    expect(cells.lastTutorUsed, 1);
  });
}
