import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_connect_africa/ai_core/inference/inference_engine.dart';
import 'package:ai_connect_africa/ai_core/providers/ai_provider.dart';
import 'package:ai_connect_africa/ai_core/tutor/tutor_pipeline.dart';
import 'package:ai_connect_africa/curriculum/online_topic_lookup.dart';
import 'package:ai_connect_africa/db/providers/db_provider.dart';
import 'package:ai_connect_africa/services/chat_inference_pipeline.dart';
import 'package:ai_connect_africa/services/qwen_chat_service.dart';

/// Holds every generation open until the test releases it, so a refresh can
/// be issued while a turn is still in flight.
class _PendingEngine extends InferenceEngine {
  final prompts = <String>[];
  final _pending = <Completer<String>>[];

  @override
  bool get isReady => true;

  @override
  String get backendLabel => 'test';

  @override
  Future<void> loadModel(String modelPath) async {}

  @override
  Future<String> generate({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
    TokenCallback? onToken,
    String? systemPrompt,
  }) {
    prompts.add(prompt);
    final completer = Completer<String>();
    _pending.add(completer);
    return completer.future;
  }

  void completeNext(String text) => _pending.removeAt(0).complete(text);

  @override
  Future<void> dispose() async {}
}

void main() {
  late _PendingEngine engine;
  late TutorPipeline tutor;
  late ProviderContainer container;

  setUp(() {
    engine = _PendingEngine();
    tutor = TutorPipeline(engine: engine);
    final pipeline = ChatInferencePipeline(
      reasoner: QwenReasoningService(engine),
      tutor: tutor,
    );
    container = ProviderContainer(
      overrides: [
        activeStudentProvider.overrideWith((ref) async => null),
        chatInferencePipelineProvider.overrideWith((ref) async => pipeline),
        tutorPipelineProvider.overrideWith((ref) async => tutor),
        engineLoadedProvider.overrideWith((ref) async => engine),
        // No internet look-ups: the turn under test goes to the engine.
        onlineTopicLookupEnabledProvider.overrideWith(
          (ref) => OnlineTopicLookupSetting.fixed(false),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  test('a follow-up waits for a direct reply to enter tutor memory', () async {
    final ready = Completer<TutorPipeline>();
    final cascade = ChatInferencePipeline(reasoner: QwenReasoningService(engine), tutor: tutor);
    final delayed = ProviderContainer(overrides: [
      activeStudentProvider.overrideWith((ref) async => null),
      chatInferencePipelineProvider.overrideWith((ref) async => cascade),
      tutorPipelineProvider.overrideWith((ref) => ready.future),
      engineLoadedProvider.overrideWith((ref) async => engine),
      onlineTopicLookupEnabledProvider.overrideWith((ref) => OnlineTopicLookupSetting.fixed(false)),
    ]);
    addTearDown(delayed.dispose);
    final notifier = delayed.read(chatProvider.notifier);
    await delayed.read(chatProvider.future);
    await notifier.send('go online');
    final followUp = notifier.send('Why can you not do that?');
    await pumpEventQueue();
    expect(engine.prompts, isEmpty);
    ready.complete(tutor);
    await pumpEventQueue(times: 50);
    expect(engine.prompts.single, contains('Student: go online'));
    expect(engine.prompts.single, contains("I can't switch the internet on myself"));
    engine.completeNext('Only you can turn on this device connection.');
    await followUp;
  });

  test('a refresh mid-turn discards the reply and its prompt memory',
      () async {
    final notifier = container.read(chatProvider.notifier);
    await container.read(chatProvider.future);

    final firstTurn = notifier.send('What is gravity?');
    await pumpEventQueue();
    expect(engine.prompts, hasLength(1), reason: 'turn should have started');

    notifier.reset();
    expect(container.read(chatProvider).valueOrNull?.messages, isEmpty);

    engine.completeNext('Gravity pulls objects toward each other.');
    await firstTurn;

    expect(
      container.read(chatProvider).valueOrNull?.messages,
      isEmpty,
      reason: 'the discarded turn must not reappear after it resolves',
    );

    final secondTurn = notifier.send('What is photosynthesis?');
    await pumpEventQueue();
    engine.completeNext('Plants turn light into food.');
    await secondTurn;

    expect(engine.prompts.last, isNot(contains('gravity')));
    expect(
      engine.prompts.last,
      isNot(contains('THREAD')),
      reason: 'conversation memory must start empty after a refresh',
    );
    expect(
      container.read(chatProvider).valueOrNull?.messages.first.text,
      'What is photosynthesis?',
    );
  });

  test('a turn that finishes without a refresh is kept and remembered',
      () async {
    final notifier = container.read(chatProvider.notifier);
    await container.read(chatProvider.future);

    final firstTurn = notifier.send('What is gravity?');
    await pumpEventQueue();
    engine.completeNext('Gravity pulls objects toward each other.');
    await firstTurn;

    expect(container.read(chatProvider).valueOrNull?.messages, hasLength(2));

    final secondTurn = notifier.send('Tell me more');
    await pumpEventQueue();
    engine.completeNext('It also keeps planets in orbit.');
    await secondTurn;

    expect(engine.prompts.last, contains('THREAD'));
    expect(engine.prompts.last, contains('gravity'));
  });
}
