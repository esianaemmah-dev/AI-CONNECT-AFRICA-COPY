import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ai_core/inference/inference_engine.dart';
import '../../ai_core/providers/ai_provider.dart';
import '../../db/otic_database.dart';
import '../../db/providers/db_provider.dart';
import '../../features/learn/notes_quiz.dart';
import '../../features/learn/subject_notes.dart';
import '../custom_subject_service.dart';
import '../assignments/class_assignments.dart';
import '../offline_storage_service.dart';
import '../hybrid_model_orchestrator.dart';
import '../pdf/diagram_detector.dart';
import '../learning/tutor_use.dart';
import 'note_quiz_store.dart';
import 'note_text_indexer.dart';
import 'note_background_work.dart';

/// Passages shorter than this are headings or captions, not worth a question.
const _minPassageChars = 120;

/// Text per question: a topic gets one question per this many characters,
/// between 1 and [_maxPerTopic].
const _charsPerQuestion = 2500;
const _maxPerTopic = 8;

/// Writes quiz questions for each topic (section heading) of this device's
/// notes, in the background, as soon as the text is there — so a learner
/// who opens Quiz gets questions instantly instead of waiting on the model.
///
/// - Works from the note's stored text, so it never reads a PDF twice; a
///   PDF's text arrives from [NoteTextIndexer] a batch at a time, and while
///   it is still being read the last topic waits (it may still grow).
/// - Every question is checked against its passage before it is kept
///   ([NotesQuizGenerator.checkedQuestion]), so it is marked by the answer
///   the notes give.
/// - Only this device's own notes: a received note is signed by its teacher
///   and can't take new rows. Students get the questions on sync.
/// - Saves each finished passage, so closing the app loses at most one
///   question; [resumePending] carries on at the next launch.
/// - Waits while the chat is answering. Both share the one brain.
/// - When the engine fails (it answers with a stock sentence rather than
///   throwing) the passage is retried later, never skipped.
class NoteQuizBuilder {
  NoteQuizBuilder(this._ref);

  final Ref _ref;
  final _queue = Queue<(String, String)>();
  bool _running = false;

  /// The note [_build] is working on, and notes queued again meanwhile:
  /// more text arrived (or a new upload reset it), so it is built again.
  (String, String)? _building;
  final _again = <(String, String)>{};
  Timer? _retry;

  static const retryAfter = Duration(minutes: 2);

  static String doneKey(String subjectId, String documentTitle) =>
      'note_quiz_topics:$subjectId|$documentTitle';

  /// Queues the note [documentTitle] of [subjectId]. [fresh] (a new upload)
  /// drops its earlier questions and starts again.
  Future<void> enqueue(
    String subjectId,
    String documentTitle, {
    bool fresh = false,
  }) async {
    final note = (subjectId, documentTitle);
    // Before the reset, so a build in progress writes nothing after it.
    if (note == _building) _again.add(note);
    if (fresh) await _reset(subjectId, documentTitle);
    if (!_queue.contains(note)) _queue.add(note);
    unawaited(_pump());
  }

  Future<void> _reset(String subjectId, String documentTitle) async {
    await _ref
        .read(dbProvider)
        .topicResourceDao
        .deleteQuizRows(subjectId: subjectId, documentTitle: documentTitle);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(doneKey(subjectId, documentTitle));
  }

  /// Queues every own note with text. Notes whose questions were written
  /// per page, before topics, get per-topic ones instead.
  Future<void> resumePending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final notes = await _ref
          .read(dbProvider)
          .topicResourceDao
          .ownNotesWithText();
      for (final (subject, title) in notes) {
        final fresh = prefs.getStringList(doneKey(subject, title)) == null;
        await enqueue(subject, title, fresh: fresh);
      }
    } catch (e) {
      debugPrint('Note quiz resume failed: $e');
    }
  }

  Future<void> _pump() async {
    if (_running || (_retry?.isActive ?? false)) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final note = _queue.first;
        _building = note;
        bool ok;
        try {
          ok = await _build(note.$1, note.$2);
        } catch (e) {
          debugPrint('Note quiz failed, retrying later: $e');
          ok = false;
        } finally {
          _building = null;
        }
        if (_again.remove(note) && ok) continue;
        if (!ok) {
          _retry?.cancel();
          _retry = Timer(retryAfter, () {
            _retry = null;
            unawaited(_pump());
          });
          return;
        }
        _queue.removeFirst();
      }
    } finally {
      _running = false;
    }
  }

  /// False when the engine is unavailable and the note must be tried again.
  Future<bool> _build(String subjectId, String documentTitle) async {
    final db = _ref.read(dbProvider);
    final rows = await db.topicResourceDao.ownNoteText(
      subjectId: subjectId,
      documentTitle: documentTitle,
    );
    if (rows.isEmpty) return true;
    final topics = noteTopics(rows, documentTitle);
    final reading = _ref
        .read(noteTextIndexerProvider)
        .isReading(subjectId, documentTitle);
    final prefs = await SharedPreferences.getInstance();
    final key = doneKey(subjectId, documentTitle);
    final done = {...?prefs.getStringList(key)};
    // Recorded even with nothing to ask, so resume knows this note is
    // on topics.
    if (prefs.getStringList(key) == null) await prefs.setStringList(key, []);

    final work = <(NoteTopic, int, String)>[];
    for (var t = 0; t < topics.length; t++) {
      if (reading && t == topics.length - 1) break;
      final passages = topicPassages(topics[t].text);
      for (var i = 0; i < passages.length; i++) {
        final id = '${topics[t].key}#$i';
        if (!done.contains(id)) work.add((topics[t], i, passages[i]));
      }
    }
    if (work.isEmpty) {
      if (!reading) {
        await _ref
            .read(classAssignmentsProvider)
            .prepareNotePractice(subjectId, documentTitle);
      }
      return true;
    }

    await _chatIdle();
    final InferenceEngine brain;
    try {
      brain = await _ref.read(engineLoadedProvider.future);
    } catch (e) {
      debugPrint('Note quiz: brain unavailable, retrying later: $e');
      return false;
    }
    if (brain.isDemo || !brain.isReady) return false;

    final generator = NotesQuizGenerator(brain);
    var subject = subjectId;
    try {
      subject =
          (await _ref.read(subjectByIdProvider(subjectId).future))?.name ??
          subject;
    } catch (_) {}
    final term = rows.first.termMarker;

    final note = (subjectId, documentTitle);
    for (final (topic, i, passage) in work) {
      if (_again.contains(note)) return true;
      if (!await _stillThere(db, subjectId, documentTitle)) return true;
      await _chatIdle();
      final started = DateTime.now();
      final r = await _ref.read(noteBackgroundWorkProvider).run(() async {
        // Chat may have started while this job waited behind a PDF page.
        // Release the slot and retry later rather than holding up extraction.
        if (_foregroundRecently()) return null;
        return generator.checkedQuestion(
          readableNoteText(passage),
          subject: subject,
          topic: topic.title,
          yieldIf: _foregroundBusy,
        );
      });
      if (r == null) return false;
      if (r.engineFailed) return false;
      if (_again.contains(note)) return true;
      final q = r.question;
      if (q != null && await _stillThere(db, subjectId, documentTitle)) {
        await db.topicResourceDao.insertQuizRow(
          subjectId: subjectId,
          documentTitle: documentTitle,
          content: NoteQuizStore.format(
            q,
            _pageOf(passage),
            topic: topic.title,
          ),
          termMarker: term,
        );
        _ref.invalidate(topicResourcesProvider(subjectId));
      }
      done.add('${topic.key}#$i');
      await prefs.setStringList(key, done.toList());
      debugPrint(
        'Note quiz: "$documentTitle" / ${topic.title} #$i '
        '${q == null ? 'dropped' : 'saved'} in '
        '${DateTime.now().difference(started).inMilliseconds} ms',
      );
    }
    if (!_ref
        .read(noteTextIndexerProvider)
        .isReading(subjectId, documentTitle)) {
      await _ref
          .read(classAssignmentsProvider)
          .prepareNotePractice(subjectId, documentTitle);
    }
    return true;
  }

  /// False once the note was deleted.
  Future<bool> _stillThere(
    OticDatabase db,
    String subjectId,
    String documentTitle,
  ) async {
    final row =
        await (db.select(db.topicResources)
              ..where((t) => t.subjectId.equals(subjectId))
              ..where((t) => t.documentTitle.equals(documentTitle))
              ..where((t) => t.classGroupUuid.isNull())
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  /// How long the chat must have been quiet before a question is written.
  /// One question holds the brain for a while on a laptop CPU, so a learner
  /// still chatting would wait behind it; this keeps quiz writing to the
  /// pauses between lessons.
  static const chatQuietFor = Duration(minutes: 2);

  /// Returns once the chat has not been answering for [chatQuietFor].
  Future<void> _chatIdle() async {
    DateTime? busyAt;
    while (true) {
      if (_foregroundBusy()) busyAt = DateTime.now();
      final last = [
        busyAt,
        _ref.read(tutorLastReplyProvider),
        HybridModelOrchestrator.instance.lastActive,
      ].whereType<DateTime>().fold<DateTime?>(
        null,
        (a, b) => a == null || b.isAfter(a) ? b : a,
      );
      if (last == null || DateTime.now().difference(last) >= chatQuietFor) {
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  /// The chat is answering, or a builder, lab or chat job holds the brain.
  bool _foregroundBusy() =>
      (_ref.read(chatProvider).valueOrNull?.isGenerating ?? false) ||
      HybridModelOrchestrator.instance.busy;

  /// [_foregroundBusy], or it was within [chatQuietFor]: the learner is
  /// still using the AI, so a question written now would make them wait.
  bool _foregroundRecently() {
    if (_foregroundBusy()) return true;
    final now = DateTime.now();
    for (final t in [
      _ref.read(tutorLastReplyProvider),
      HybridModelOrchestrator.instance.lastActive,
    ]) {
      if (t != null && now.difference(t) < chatQuietFor) return true;
    }
    return false;
  }

  void dispose() => _retry?.cancel();
}

/// One topic of a note: its section rows' text, in order.
class NoteTopic {
  const NoteTopic({required this.key, required this.title, required this.text});

  /// The rows' `topic_key`.
  final String key;

  /// The section heading as the teacher wrote it (the note's title for a
  /// note without headings).
  final String title;
  final String text;
}

/// [rows] (one note's text rows) grouped by topic, in the order they
/// first appear.
List<NoteTopic> noteTopics(List<TopicResource> rows, String documentTitle) {
  final order = <String>[];
  final titles = <String, String>{};
  final texts = <String, StringBuffer>{};
  final prefix = '$documentTitle — ';
  for (final r in rows) {
    if (!texts.containsKey(r.topicKey)) {
      order.add(r.topicKey);
      texts[r.topicKey] = StringBuffer();
      titles[r.topicKey] = r.resourceTitle.startsWith(prefix)
          ? r.resourceTitle.substring(prefix.length)
          : r.resourceTitle;
    }
    texts[r.topicKey]!
      ..write(r.contentChunk)
      ..write('\n\n');
  }
  return [
    for (final k in order)
      NoteTopic(key: k, title: titles[k]!, text: texts[k].toString().trim()),
  ];
}

/// The passages of a topic's [text] to ask about: one per
/// [_charsPerQuestion] characters (at most [_maxPerTopic]), spread evenly
/// over the topic, each about 900 characters cut at paragraph breaks.
List<String> topicPassages(String text) {
  final windows = <String>[];
  final buf = StringBuffer();
  for (final para in text.split(RegExp(r'\n\s*\n'))) {
    final p = para.trim();
    if (p.isEmpty) continue;
    if (buf.isNotEmpty && buf.length + p.length > 900) {
      windows.add(buf.toString());
      buf.clear();
    }
    if (buf.isNotEmpty) buf.write('\n\n');
    buf.write(p);
  }
  if (buf.isNotEmpty) windows.add(buf.toString());
  final usable = [
    for (final w in windows)
      if (readableNoteText(w).length >= _minPassageChars) w,
  ];
  if (usable.isEmpty) return const [];
  final want = (text.length / _charsPerQuestion).ceil().clamp(1, _maxPerTopic);
  if (usable.length <= want) return usable;
  return [
    for (var i = 0; i < want; i++)
      usable[(i * (usable.length - 1) / (want == 1 ? 1 : want - 1)).round()],
  ];
}

/// The PDF page a passage is from, when a diagram marker in it says; else 0.
int _pageOf(String passage) {
  final markers = DiagramMarker.parseAll(passage);
  return markers.isEmpty ? 0 : markers.first.page;
}

final noteQuizBuilderProvider = Provider<NoteQuizBuilder>((ref) {
  final builder = NoteQuizBuilder(ref);
  ref.onDispose(builder.dispose);
  return builder;
});

final noteQuizStoreProvider = Provider<NoteQuizStore>(
  (ref) => NoteQuizStore(ref.watch(dbProvider)),
);
