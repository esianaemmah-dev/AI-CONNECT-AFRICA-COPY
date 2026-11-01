import 'package:ai_connect_africa/ai_core/inference/inference_engine.dart';
import 'package:ai_connect_africa/ai_core/inference/prompt_budget.dart';
import 'package:ai_connect_africa/ai_core/tutor/conversation_memory.dart';
import 'package:ai_connect_africa/ai_core/tutor/tutor_pipeline.dart';
import 'package:ai_connect_africa/services/chat_inference_pipeline.dart';
import 'package:ai_connect_africa/services/qwen_reasoning_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Engine extends InferenceEngine {
  final prompts = <String>[];
  final systems = <String?>[];
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
    prompts.add(prompt);
    systems.add(systemPrompt);
    const answer = 'First, plants make food. Second, animals consume it.';
    await emitToken(onToken, answer);
    return answer;
  }
}

void main() {
  test(
    'topic changes keep earlier questions in the actual fitted model prompt',
    () async {
      final engine = _Engine();
      final tutor = TutorPipeline(
        engine: engine,
        teacherNotes: (_) async =>
            List.filled(40, 'Living things need energy. ').join(),
      );
      await tutor.respond(studentMessage: 'What is photosynthesis?');
      await tutor.respond(studentMessage: 'What is gravity?');
      await tutor.respond(
        studentMessage: 'Compare this with my earlier question',
      );
      final fitted = fitLlamaChatBodies(
        system: engine.systems.last,
        user: engine.prompts.last,
      );
      expect(
        fitted.user,
        engine.prompts.last,
        reason: 'native budget must retain memory without further clipping',
      );
      expect(fitted.user, contains('Student: What is photosynthesis?'));
      expect(fitted.user, contains('Student: What is gravity?'));
      expect(
        fitted.user,
        contains('CURRENT: Compare this with my earlier question'),
      );
    },
  );

  test(
    'a short reference stays the current question and retrieval uses its context',
    () async {
      final engine = _Engine();
      final searches = <String>[];
      final tutor = TutorPipeline(
        engine: engine,
        teacherNotes: (query) async {
          searches.add(query);
          return '';
        },
      );
      await tutor.respond(studentMessage: 'What is photosynthesis?');
      await tutor.respond(studentMessage: 'Explain the second one');
      expect(
        engine.prompts.last,
        contains('Tutor: First, plants make food. Second, animals consume it.'),
      );
      expect(
        engine.prompts.last,
        contains('CURRENT: Explain the second one\nTutor:'),
      );
      expect(searches.last, contains('photosynthesis'));
      expect(
        engine.prompts.last,
        isNot(contains('CURRENT: What is photosynthesis? (follow-up:')),
      );
    },
  );

  test('topic grounding resets independently of conversation memory', () {
    final memory = ConversationMemory()
      ..remember(
        student: 'What is a cell?',
        tutor: 'A unit of life.',
        verified: ['cell: unit of life'],
        slots: {'unit': 'cm'},
      );
    memory.beginTopic('gravity');
    expect(memory.promptBlock(), contains('What is a cell?'));
    expect(memory.established, isEmpty);
    expect(memory.activeSlots, isEmpty);
    expect(memory.activeTopic, 'gravity');
  });

  test(
    'rolling digest advances instead of freezing on the oldest exchange',
    () {
      final memory = ConversationMemory(maxRawTurns: 4);
      for (var i = 0; i < 12; i++) {
        memory.remember(
          student: 'Explain concept number $i please',
          tutor: 'The answer for concept $i.',
        );
      }
      expect(memory.lessonDigest, contains('concept number 9'));
      expect(
        memory.lessonDigest!.length,
        lessThanOrEqualTo(memory.digestClipChars),
      );
      expect(memory.turns, hasLength(4));
      expect(memory.promptBlock(maxChars: 700), contains('DIGEST:'));
      for (final limit in [0, 1, 2, 40, 180, 700]) {
        expect(
          memory.promptBlock(maxChars: limit).length,
          lessThanOrEqualTo(limit),
        );
      }
    },
  );

  test('restoring a chat preserves cross-topic follow-up context', () async {
    final original = TutorPipeline(engine: _Engine());
    await original.respond(studentMessage: 'What is photosynthesis?');
    await original.respond(studentMessage: 'What is gravity?');
    final engine = _Engine();
    final restored = TutorPipeline(engine: engine);
    await restored.restoreSession(
      memory: original.memorySnapshot(),
      topic: original.currentTopic,
      nextStage: original.nextStage,
    );
    await restored.respond(
      studentMessage: 'What was my earlier biology question?',
    );
    expect(engine.prompts.last, contains('photosynthesis'));
    expect(engine.prompts.last, contains('gravity'));
    restored.reset();
    await restored.respond(studentMessage: 'What is a cell?');
    expect(engine.prompts.last, isNot(contains('photosynthesis')));
    expect(engine.prompts.last, isNot(contains('THREAD:')));
  });

  test(
    'routing to the programming tutor carries the current conversation',
    () async {
      final general = _Engine();
      final coding = _Engine();
      final tutor = TutorPipeline(engine: general);
      final chat = ChatInferencePipeline(
        tutor: tutor,
        reasoner: QwenReasoningService(general),
        loadProgrammingEngine: () async => coding,
      );
      await chat.completeTurn(
        userText: 'What is photosynthesis?',
        languageCode: 'en',
      );
      await chat.completeTurn(
        userText: 'Write Python code to illustrate that',
        languageCode: 'en',
      );
      expect(coding.prompts.last, contains('photosynthesis'));
      expect(
        coding.prompts.last,
        contains('CURRENT: Write Python code to illustrate that'),
      );
    },
  );
}
