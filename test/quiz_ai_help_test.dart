import 'dart:async';

import 'package:ai_connect_africa/ai_core/inference/inference_engine.dart';
import 'package:ai_connect_africa/ai_core/providers/ai_provider.dart';
import 'package:ai_connect_africa/curriculum/curriculum_models.dart';
import 'package:ai_connect_africa/db/otic_database.dart';
import 'package:ai_connect_africa/db/providers/db_provider.dart';
import 'package:ai_connect_africa/features/learn/notes_quiz.dart';
import 'package:ai_connect_africa/features/learn/subject_notes.dart';
import 'package:ai_connect_africa/l10n/language_provider.dart';
import 'package:ai_connect_africa/services/notes/note_quiz_store.dart';
import 'package:ai_connect_africa/services/quiz_answer_service.dart';
import 'package:ai_connect_africa/shared/widgets/quiz_ai_answer.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const question = QuizQuestion(
  question: 'What gas do plants take in?',
  options: ['Oxygen', 'Carbon dioxide', 'Nitrogen', 'Helium'],
  correct: 1,
  explanation: 'Plants need carbon dioxide to make glucose.',
);

class _Engine extends InferenceEngine {
  final prompts = <String>[];
  Completer<String>? pending;
  String reply =
      '<think>hidden</think>1. Plants make glucose.\n2. Carbon dioxide supplies the carbon.';
  @override
  bool get isReady => true;
  @override
  String get backendLabel => 'test';
  @override
  Future<void> loadModel(String modelPath) async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<String> generate({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
    TokenCallback? onToken,
    String? systemPrompt,
  }) async {
    expect(maxTokens, lessThanOrEqualTo(384));
    prompts.add(prompt);
    return pending == null ? reply : pending!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'quiz tutor uses the answer key and asks for an educational method',
    () async {
      final engine = _Engine();
      final text = await explainQuizAnswer(engine, question);
      expect(quizAnswerLabel(question), 'B) Carbon dioxide');
      expect(
        engine.prompts.single,
        contains('Correct answer: B) Carbon dioxide'),
      );
      expect(engine.prompts.single, contains('two to four short steps'));
      expect(engine.prompts.single, contains(question.explanation));
      expect(text, contains('Carbon dioxide supplies the carbon'));
      expect(text, isNot(contains('hidden')));
    },
  );
  test('an empty generated explanation uses the saved teaching note', () async {
    final engine = _Engine()..reply = '';
    expect(await explainQuizAnswer(engine, question), question.explanation);
  });
  test('supported math uses calculated steps without an extra model call', () async {
    final engine = _Engine();
    const mathQuestion = QuizQuestion(question: '250 + 100',
      options: ['350', '250', '100', '150'], correct: 0, explanation: 'Add the two values.');
    final text = await explainQuizAnswer(engine, mathQuestion);
    expect(text, contains('350'));
    expect(engine.prompts, isEmpty);
  });

  group('uploaded-note quiz help', () {
    late OticDatabase db;
    late _Engine engine;
    late ProviderContainer container;
    setUp(() async {
      db = OticDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
      engine = _Engine();
      container = ProviderContainer(
        overrides: [
          dbProvider.overrideWithValue(db),
          activeStudentProvider.overrideWith((ref) async => null),
          learnerClassUuidProvider.overrideWith((ref) async => null),
          engineLoadedProvider.overrideWith((ref) async => engine),
        ],
      );
      container.read(languageOverrideProvider.notifier).adoptSaved('en');
      for (final title in ['First', 'Second']) {
        await db.topicResourceDao.insertQuizRow(
          subjectId: 'biology',
          documentTitle: title,
          termMarker: 0,
          content: NoteQuizStore.format(question, 1),
        );
      }
    });
    tearDown(() async {
      container.dispose();
      await db.close();
    });
    test(
      'help is marked AI-assisted and shows the method without selecting for the learner',
      () async {
        final notifier = container.read(
          subjectQuizProvider('biology').notifier,
        );
        await notifier.startStored(documentTitle: 'First');
        await notifier.explain(0);
        final state = container.read(subjectQuizProvider('biology'));
        expect(state.tutorUsed, contains(0));
        expect(state.answers, isEmpty);
        expect(state.explanations[0], contains('Plants make glucose'));
        expect(state.explaining, isEmpty);
      },
    );
    test('a late answer cannot overwrite the next quiz round', () async {
      final notifier = container.read(subjectQuizProvider('biology').notifier);
      await notifier.startStored(documentTitle: 'First');
      engine.pending = Completer<String>();
      final explaining = notifier.explain(0);
      await pumpEventQueue();
      await notifier.explain(0);
      expect(engine.prompts, hasLength(1));
      await notifier.startStored(documentTitle: 'Second');
      engine.pending!.complete('An explanation from the old round.');
      await explaining;
      final state = container.read(subjectQuizProvider('biology'));
      expect(state.explanations, isEmpty);
      expect(state.tutorUsed, isEmpty);
    });
  });

  testWidgets(
    'Answer with AI reveals the correct option and explanatory steps',
    (tester) async {
      final engine = _Engine();
      final container = ProviderContainer(
        overrides: [
          activeStudentProvider.overrideWith((ref) async => null),
          engineLoadedProvider.overrideWith((ref) async => engine),
        ],
      );
      addTearDown(container.dispose);
      container.read(languageOverrideProvider.notifier).adoptSaved('en');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: QuizAiAnswer(question: question)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Answer with AI'));
      await tester.pumpAndSettle();
      expect(find.text('Correct answer: B) Carbon dioxide'), findsOneWidget);
      expect(find.textContaining('Plants make glucose'), findsOneWidget);
      expect(find.textContaining('<think>'), findsNothing);
    },
  );
}
