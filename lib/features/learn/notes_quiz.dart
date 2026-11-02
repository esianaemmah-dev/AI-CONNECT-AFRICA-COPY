import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai_core/inference/inference_engine.dart';
import '../../ai_core/providers/ai_provider.dart';
import '../../curriculum/curriculum_models.dart';
import '../../db/providers/db_provider.dart';
import '../../services/custom_subject_service.dart';
import '../../services/learning/tutor_use.dart';
import '../../services/notes/note_quiz_builder.dart';
import '../../services/notes/quiz_scores.dart';
import '../../services/quiz_answer_service.dart';
import 'subject_notes.dart';

/// Multiple-choice questions written from the teacher's own notes — one
/// passage per question, so each question can be answered from what the
/// class was given, not from whatever the model happens to know.
class NotesQuizGenerator {
  NotesQuizGenerator(this._engine);

  final InferenceEngine _engine;

  /// Passages long enough to ask about, spread across the documents.
  static List<String> pickPassages(
    List<SubjectNote> notes, {
    int count = 5,
    math.Random? random,
  }) {
    final rnd = random ?? math.Random();
    final byDoc = [
      for (final n in notes)
        [
          for (final p in n.passages)
            if (p.length >= 120) p,
        ]..shuffle(rnd),
    ]..removeWhere((l) => l.isEmpty);
    final out = <String>[];
    // Round-robin, so one long document doesn't take every question.
    while (out.length < count && byDoc.any((l) => l.isNotEmpty)) {
      for (final l in byDoc) {
        if (l.isNotEmpty && out.length < count) out.add(l.removeLast());
      }
    }
    return out;
  }

  Future<QuizQuestion?> fromPassage(
    String passage, {
    required String subject,
  }) async => (await tryPassage(passage, subject: subject)).question;

  /// Like [fromPassage], but says when the engine itself failed — it
  /// answers with a stock sentence instead of throwing — so a caller that
  /// records progress can retry that passage instead of skipping it.
  Future<({QuizQuestion? question, bool engineFailed})> tryPassage(
    String passage, {
    required String subject,
    String? topic,
  }) async {
    final clipped = _clip(passage);
    final about = topic == null || topic.isEmpty ? '' : ', topic "$topic"';
    final prompt =
        '''You are a teacher writing a quiz for students of $subject$about.
Read the passage from the class notes, then write ONE multiple-choice question that can be answered using only this passage.

Passage:
"""
$clipped
"""

Respond ONLY with this JSON (no markdown, no explanation):
{"question": "...", "options": ["...", "...", "...", "..."], "correctIndex": 0, "explanation": "One sentence, quoting or paraphrasing the passage."}

Rules:
- Exactly 4 different options; only one is correct according to the passage.
- correctIndex is 0-3.
- Do not mention "the passage" in the question.''';
    try {
      final raw = await _engine.generate(
        prompt: prompt,
        maxTokens: 320,
        temperature: 0.3,
      );
      return (question: parse(raw), engineFailed: isEngineFallback(raw));
    } catch (e) {
      debugPrint('Notes quiz question failed: $e');
      return (question: null, engineFailed: true);
    }
  }

  /// A question from [passage] that has passed the checks below, so the
  /// answer it is marked by is the one the class notes give:
  ///
  /// - the options are shuffled (a small model puts the right answer first
  ///   far too often);
  /// - the keyed answer must be found in the passage at least as well as
  ///   any wrong option ([groundedInPassage]);
  /// - the model, shown only the passage and the question, must pick the
  ///   keyed option again ([answersFromPassage]).
  ///
  /// A question failing a check is dropped (`question` null). [engineFailed]
  /// as in [tryPassage].
  Future<({QuizQuestion? question, bool engineFailed})> checkedQuestion(
    String passage, {
    required String subject,
    String? topic,
    math.Random? random,

    /// Checked before the second model call: true gives the brain back to
    /// a learner, reported as [engineFailed] so the passage is retried.
    bool Function()? yieldIf,
  }) async {
    final r = await tryPassage(passage, subject: subject, topic: topic);
    final q = r.question;
    if (q == null) return r;
    final shuffled = shuffleOptions(q, random ?? math.Random());
    if (!groundedInPassage(shuffled, passage)) {
      return (question: null, engineFailed: false);
    }
    if (yieldIf?.call() ?? false) return (question: null, engineFailed: true);
    final check = await answersFromPassage(shuffled, passage);
    if (check.engineFailed) return (question: null, engineFailed: true);
    return (question: check.agrees ? shuffled : null, engineFailed: false);
  }

  /// [q] with its options in a random order, still keyed to the same one.
  static QuizQuestion shuffleOptions(QuizQuestion q, math.Random random) {
    final order = List<int>.generate(q.options.length, (i) => i)
      ..shuffle(random);
    return QuizQuestion(
      question: q.question,
      options: [for (final i in order) q.options[i]],
      correct: order.indexOf(q.correct),
      explanation: q.explanation,
    );
  }

  static Set<String> _words(String text) => {
    for (final w in text.toLowerCase().split(RegExp(r'[^a-z0-9]+')))
      if (w.length >= 3 || RegExp(r'^\d+$').hasMatch(w)) w,
  };

  /// Share of [option]'s words that appear in [passage].
  static double _support(String option, Set<String> passage) {
    final words = _words(option);
    if (words.isEmpty) return 0;
    return words.where(passage.contains).length / words.length;
  }

  /// False when a wrong option is clearly better supported by [passage]
  /// than the keyed answer — the key is likely wrong.
  static bool groundedInPassage(QuizQuestion q, String passage) {
    final words = _words(passage);
    final keyed = _support(q.options[q.correct], words);
    for (var i = 0; i < q.options.length; i++) {
      if (i == q.correct) continue;
      if (_support(q.options[i], words) > keyed + 0.34) return false;
    }
    return true;
  }

  /// Asks the model to answer [q] from [passage] alone; [agrees] when it
  /// picks the keyed option.
  Future<({bool agrees, bool engineFailed})> answersFromPassage(
    QuizQuestion q,
    String passage,
  ) async {
    const letters = ['A', 'B', 'C', 'D'];
    final prompt =
        '''Read the class notes, then answer the question using only the notes.

Notes:
"""
${_clip(passage)}
"""

Question: ${q.question}
${[for (var i = 0; i < q.options.length; i++) '${letters[i]}) ${q.options[i]}'].join('\n')}

Reply with the letter of the correct option only.''';
    try {
      final raw = await _engine.generate(
        prompt: prompt,
        maxTokens: 6,
        temperature: 0,
      );
      if (isEngineFallback(raw)) return (agrees: false, engineFailed: true);
      final m = RegExp(r'\b([ABCD])\b').firstMatch(raw.toUpperCase());
      final picked = m == null ? -1 : letters.indexOf(m[1]!);
      return (agrees: picked == q.correct, engineFailed: false);
    } catch (e) {
      debugPrint('Notes quiz check failed: $e');
      return (agrees: false, engineFailed: true);
    }
  }

  static String _clip(String passage) =>
      passage.length > 900 ? passage.substring(0, 900) : passage;

  /// The stock sentences the engines answer with when generation failed.
  static bool isEngineFallback(String raw) =>
      raw.contains('I hit a brief snag') ||
      raw.contains('on-device model is unavailable');

  /// The question in [raw], or null when it isn't a usable one.
  static QuizQuestion? parse(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start == -1 || end <= start) return null;
    try {
      final data = jsonDecode(raw.substring(start, end + 1));
      if (data is! Map) return null;
      final question = '${data['question'] ?? ''}'.trim();
      final options = [
        for (final o in (data['options'] as List? ?? const [])) '$o'.trim(),
      ];
      final correct = data['correctIndex'];
      if (question.isEmpty ||
          options.length != 4 ||
          options.any((o) => o.isEmpty) ||
          options.toSet().length != 4 ||
          correct is! num ||
          correct < 0 ||
          correct > 3) {
        return null;
      }
      final explanation = '${data['explanation'] ?? ''}'.trim();
      return QuizQuestion(
        question: question,
        options: options,
        correct: correct.toInt(),
        explanation: explanation,
      );
    } catch (_) {
      return null;
    }
  }
}

/// One subject's quiz as it is being written and answered.
class SubjectQuizState {
  const SubjectQuizState({
    this.questions = const [],
    this.topics = const [],
    this.topic,
    this.generating = false,
    this.target = 0,
    this.answers = const {},
    this.shownAt = const [],
    this.tutorUsed = const {},
    this.explanations = const {},
    this.explaining = const {},
    this.error,
  });

  final List<QuizQuestion> questions;

  /// When each of [questions] appeared, index for index.
  final List<DateTime> shownAt;

  /// Answered questions the tutor replied to the learner between the
  /// question appearing and the answer (`tutor_use.dart`).
  final Set<int> tutorUsed;

  /// The topic of each of [questions], index for index ('' for none).
  final List<String> topics;

  /// The topic this round is on; null for a round over every topic.
  final String? topic;
  final bool generating;

  /// Questions asked for this round.
  final int target;

  /// Question index → chosen option.
  final Map<int, int> answers;

  /// Question index → the AI's explanation, in the learner's language.
  final Map<int, String> explanations;

  /// Questions whose explanation is being generated right now.
  final Set<int> explaining;
  final String? error;

  int get score => [
    for (final e in answers.entries)
      if (questions[e.key].correct == e.value) 1,
  ].length;

  bool get finished =>
      !generating && questions.isNotEmpty && answers.length == questions.length;

  /// Topic → (correct, answered, answered with the tutor used) of this round.
  Map<String, QuizTopicTally> get scoreByTopic {
    final out = <String, QuizTopicTally>{};
    for (final e in answers.entries) {
      final t = e.key < topics.length ? topics[e.key] : '';
      final (c, n, a) = out[t] ?? (0, 0, 0);
      out[t] = (
        c + (questions[e.key].correct == e.value ? 1 : 0),
        n + 1,
        a + (tutorUsed.contains(e.key) ? 1 : 0),
      );
    }
    return out;
  }

  SubjectQuizState copyWith({
    List<QuizQuestion>? questions,
    List<String>? topics,
    bool? generating,
    int? target,
    Map<int, int>? answers,
    List<DateTime>? shownAt,
    Set<int>? tutorUsed,
    Map<int, String>? explanations,
    Set<int>? explaining,
    String? error,
    bool clearError = false,
  }) => SubjectQuizState(
    questions: questions ?? this.questions,
    topics: topics ?? this.topics,
    topic: topic,
    generating: generating ?? this.generating,
    target: target ?? this.target,
    answers: answers ?? this.answers,
    shownAt: shownAt ?? this.shownAt,
    tutorUsed: tutorUsed ?? this.tutorUsed,
    explanations: explanations ?? this.explanations,
    explaining: explaining ?? this.explaining,
    error: clearError ? null : error ?? this.error,
  );
}

/// Kept for the session, so switching tabs doesn't throw a quiz away.
class SubjectQuizNotifier extends FamilyNotifier<SubjectQuizState, String> {
  int _round = 0;

  @override
  SubjectQuizState build(String subjectId) => const SubjectQuizState();

  /// Questions per round taken from the ones written ahead.
  static const storedRoundSize = 10;

  /// Shows a round of the questions written ahead from the notes' topics
  /// (`NoteQuizBuilder`) at once — only [topic]'s when given, and only
  /// [documentTitle]'s (one note, from My notes → Take quiz) when given.
  /// False when there are none yet.
  Future<bool> startStored({String? topic, String? documentTitle}) async {
    final round = ++_round;
    try {
      final classUuid = await ref.read(learnerClassUuidProvider.future);
      final stored = [
        for (final q in await ref
            .read(noteQuizStoreProvider)
            .questions(arg, classUuid: classUuid))
          if ((topic == null || q.topic == topic) &&
              (documentTitle == null || q.documentTitle == documentTitle))
            q,
      ];
      if (round != _round || stored.isEmpty) return false;
      stored.shuffle();
      final pick = stored.take(storedRoundSize).toList();
      state = SubjectQuizState(
        questions: [for (final q in pick) q.question],
        topics: [for (final q in pick) q.topic],
        topic: topic,
        target: pick.length,
        shownAt: List.filled(pick.length, DateTime.now()),
      );
      return true;
    } catch (e) {
      debugPrint('Stored quiz unavailable: $e');
      return false;
    }
  }

  Future<void> start({int count = 5, String? topic}) async {
    if (await startStored(topic: topic)) return;
    final round = ++_round;
    state = SubjectQuizState(generating: true, target: count);
    try {
      final notes = await ref.read(subjectNotesProvider(arg).future);
      final subject = await ref.read(subjectByIdProvider(arg).future);
      final questions = <QuizQuestion>[];

      final passages = NotesQuizGenerator.pickPassages(notes, count: count);
      if (passages.isNotEmpty) {
        final engine = await ref.read(engineLoadedProvider.future);
        final generator = NotesQuizGenerator(engine);
        for (final p in passages) {
          final r = await generator.checkedQuestion(
            p,
            subject: subject?.name ?? arg,
          );
          if (round != _round) return;
          if (r.question case final q?) {
            questions.add(q);
            state = state.copyWith(
              questions: List.of(questions),
              topics: List.filled(questions.length, ''),
              shownAt: [...state.shownAt, DateTime.now()],
            );
          }
        }
      }

      // Built-in subjects without class notes use the curriculum's bank.
      if (questions.isEmpty && subject != null) {
        final bank = [
          for (final u in subject.units)
            for (final l in u.lessons) ...l.quiz,
        ]..shuffle();
        questions.addAll(bank.take(count));
      }
      if (round != _round) return;
      final now = DateTime.now();
      state = state.copyWith(
        questions: questions,
        topics: List.filled(questions.length, ''),
        shownAt: [
          for (var i = 0; i < questions.length; i++)
            i < state.shownAt.length ? state.shownAt[i] : now,
        ],
        generating: false,
        error: questions.isEmpty ? 'No questions available' : null,
      );
    } catch (e) {
      if (round != _round) return;
      debugPrint('Subject quiz failed: $e');
      state = state.copyWith(
        generating: false,
        error: state.questions.isEmpty ? 'Quiz unavailable' : null,
      );
    }
    // Every question answered while the round was still being written.
    if (round == _round && state.finished) unawaited(_record(state));
  }

  /// Has the AI explain the answer to question [index], in the learner's
  /// language, shown inline. Using it marks the question as answered with
  /// the AI (so Achievements can tell it apart from one done on their own).
  Future<void> explain(int index) async {
    if (state.explaining.isNotEmpty ||
        state.explanations.containsKey(index) ||
        index < 0 || index >= state.questions.length) {
      return;
    }
    final round = _round;
    final q = state.questions[index];
    state = state.copyWith(
      explaining: {...state.explaining, index},
      tutorUsed: {...state.tutorUsed, index},
    );
    try {
      final engine = await ref.read(engineLoadedProvider.future);
      final english = await explainQuizAnswer(engine, q);
      final text = await localizeIncoming(ref, english);
      if (round != _round) return;
      state = state.copyWith(
        explanations: {...state.explanations, index: text},
        explaining: state.explaining.difference({index}),
      );
    } catch (e) {
      debugPrint('Quiz explain failed: $e');
      // Fall back to the stored explanation, translated.
      final text = q.explanation.isEmpty
          ? 'The AI could not explain this one right now.'
          : await localizeIncoming(ref, q.explanation);
      if (round != _round) return;
      state = state.copyWith(
        explanations: {...state.explanations, index: text},
        explaining: state.explaining.difference({index}),
      );
    }
  }

  void answer(int index, int option) {
    if (state.answers.containsKey(index)) return;
    final shown = index < state.shownAt.length ? state.shownAt[index] : null;
    final used =
        shown != null && tutorUsedSince(ref.read(tutorLastReplyProvider), shown);
    state = state.copyWith(
      answers: {...state.answers, index: option},
      tutorUsed: used ? {...state.tutorUsed, index} : null,
    );
    if (state.finished) unawaited(_record(state));
  }

  /// Saves a finished round's score per topic for Achievements. Questions
  /// with no topic file under the subject's name. Guests have no learner,
  /// so nothing is saved.
  Future<void> _record(SubjectQuizState done) async {
    try {
      final student = await ref.read(activeStudentProvider.future);
      if (student == null) return;
      final name =
          (await ref.read(subjectByIdProvider(arg).future))?.name ?? arg;
      final byTopic = <String, QuizTopicTally>{};
      for (final e in done.scoreByTopic.entries) {
        final t = e.key.isEmpty ? name : e.key;
        final (c, n, a) = byTopic[t] ?? (0, 0, 0);
        byTopic[t] = (c + e.value.$1, n + e.value.$2, a + e.value.$3);
      }
      await ref
          .read(quizScoresProvider)
          .record(studentId: student.id, subjectId: arg, byTopic: byTopic);
    } catch (e) {
      debugPrint('Quiz score not saved: $e');
    }
  }

  void reset() {
    _round++;
    state = const SubjectQuizState();
  }
}

/// The topics a learner may take a quiz on in a subject, with how many
/// questions each has — live, so topics appear as questions are written.
final subjectQuizTopicsProvider = StreamProvider.autoDispose
    .family<List<(String, int)>, String>((ref, subjectId) async* {
      final classUuid = await ref.watch(learnerClassUuidProvider.future);
      await for (final qs in ref
          .watch(noteQuizStoreProvider)
          .watch(subjectId, classUuid: classUuid)) {
        final counts = <String, int>{};
        for (final q in qs) {
          counts[q.topic] = (counts[q.topic] ?? 0) + 1;
        }
        yield [for (final e in counts.entries) (e.key, e.value)];
      }
    });

final subjectQuizProvider =
    NotifierProvider.family<SubjectQuizNotifier, SubjectQuizState, String>(
      SubjectQuizNotifier.new,
    );
