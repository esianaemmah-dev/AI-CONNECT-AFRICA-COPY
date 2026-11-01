import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart' show ModelType;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/pdf/diagram_detector.dart';
import '../inference/cpu_support.dart';
import '../inference/memory_support.dart';
import '../inference/engine_scheduler.dart';
import '../inference/inference_engine.dart';
import '../inference/litert_lm_engine.dart';
import '../inference/llama_cpp_engine.dart';
import '../inference/mock_engine.dart';
import '../tutor/tutor_contract.dart';
import '../model/bundled_model_bootstrap.dart';
import '../model/dual_gguf_plan.dart';
import '../model/model_manager.dart';
import '../model/model_runtime_policy.dart';
import '../translate/afrislm_model_manager.dart';
import '../translate/drift_translation_store.dart';
import '../translate/follow_up_glossary.dart';
import '../translate/supported_languages.dart';
import '../translate/translation_pipeline.dart';
import '../translate/translation_quality.dart';
import '../tutor/programming_topic.dart';
import '../tutor/tutor_pipeline.dart';
import '../tutor/tutor_response.dart';
import '../tutor/school_math.dart';
import '../tutor/school_math_l10n.dart';
import '../science/science_text.dart';
import '../../curriculum/curriculum_models.dart';
import '../../curriculum/curriculum_provider.dart';
import '../online/online_tutor.dart';
import '../../curriculum/online_topic_lookup.dart';
import '../../curriculum/topic_explanations.dart';
import '../../l10n/app_locale.dart';
import '../../l10n/language_provider.dart';
import '../../db/providers/db_provider.dart';
import '../../memory/session_recall.dart';
import '../../memory/session_recall_store.dart';
import '../../safety/emotional_safety.dart';
import '../../services/afrislm_translation_service.dart';
import '../../services/ai_coder_service.dart';
import '../../services/ai_engine_service.dart';
import '../../services/chat_inference_pipeline.dart';
import '../../services/learning/tutor_use.dart';
import '../../services/offline_rag_service.dart';
import '../../services/qwen_chat_service.dart';
import '../../services/qwen_reasoning_service.dart';

/// Learn uses curriculum RAG. Wholesome chat (Home `/`) does not.
enum ChatSection { learn, wholesomeChat }

// ── Model status ────────────────────────────────────────────────────────────

final modelManagerProvider = Provider<ModelManager>((ref) => ModelManager());

final translateModelManagerProvider =
    Provider<AfriSlmModelManager>((ref) => AfriSlmModelManager());

/// Streams APK-bundled models into app storage once (Android fat APKs).
/// Slim builds and desktop no-op quickly. Chat/translate providers wait on this.
final bundledModelsBootstrapProvider =
    FutureProvider<BundledModelBootstrapResult>((ref) async {
  if (kIsWeb) {
    return const BundledModelBootstrapResult(
      chatReady: false,
      translateReady: false,
      extractedAnything: false,
    );
  }
  try {
    final bootstrap = BundledModelBootstrap(
      chatManager: ref.watch(modelManagerProvider),
      translateManager: ref.watch(translateModelManagerProvider),
    );
    return await bootstrap.ensureExtracted();
  } catch (e, st) {
    debugPrint('bundledModelsBootstrapProvider failed: $e\n$st');
    return const BundledModelBootstrapResult(
      chatReady: false,
      translateReady: false,
      extractedAnything: false,
      error: 'bootstrap failed',
    );
  }
});

/// The brain model file (Qwen2.5-Coder-1.5B) and whether it is usable.
final modelInfoProvider = FutureProvider<ModelInfo>((ref) async {
  if (kIsWeb) {
    return const ModelInfo(status: ModelStatus.notInstalled);
  }
  try {
    await ref.watch(bundledModelsBootstrapProvider.future);
    return await ref.watch(modelManagerProvider).checkModel();
  } catch (e, st) {
    debugPrint('modelInfoProvider failed: $e\n$st');
    return const ModelInfo(status: ModelStatus.notInstalled);
  }
});

/// The brain engine for this platform: LiteRT-LM on Android (NPU → GPU →
/// LiteRT CPU), llama.cpp on desktop. Never mixed — see
/// model_runtime_policy.dart.
InferenceEngine createBrainEngine() {
  if (androidUsesLiteRt) {
    return LiteRtLmEngineImpl(
      roleLabel: 'Qwen2.5-Coder 1.5B',
      roleKey: 'brain',
      schedulerLane: EngineLane.reason,
      modelType: ModelType.qwen,
    );
  }
  return LlamaCppEngineImpl(
    schedulerLane: EngineLane.reason,
    backendLabel: 'llama.cpp · Qwen2.5-Coder 1.5B (CPU×2)',
    nGpuLayers: 0,
    threads: 2,
    // `/no_think` is a Qwen3 switch; Qwen2.5 would read it as text.
    appendNoThink: false,
  );
}

/// The AfriSLM translator engine for this platform (same split as the brain).
InferenceEngine createTranslatorEngine() {
  if (androidUsesLiteRt) {
    return LiteRtLmEngineImpl(
      roleLabel: 'AfriSLM 0.8B',
      roleKey: 'translate',
      schedulerLane: EngineLane.translate,
      modelType: ModelType.qwen3,
      appendNoThink: true,
      isolatedTurns: true,
    );
  }
  return LlamaCppEngineImpl(
    schedulerLane: EngineLane.translate,
    backendLabel: 'llama.cpp · AfriSLM 0.8B',
  );
}

/// The two on-device models: one brain and one translator.
///
/// [reasoner] is Qwen2.5-Coder-1.5B. It does all reasoning and answer
/// generation — tutoring, practice, learning paths, and code for the labs
/// and builders. AfriSLM is the [translator] and is never used as a brain.
///
/// [shared] is only true when both roles accidentally point at the same
/// GGUF file — then hops stay sequential to avoid a nested native lock.
class DualModelRuntime {
  DualModelRuntime({
    required this.reasoner,
    this._translator,
    this.shared = false,
    this.translationDisabled = false,
    this.afrislmPath,
  });

  final InferenceEngine reasoner;
  InferenceEngine? _translator;
  final bool shared;
  final bool translationDisabled;

  /// On-disk AfriSLM path for lazy / retry load after Install Packages.
  String? afrislmPath;

  InferenceEngine? get translator => _translator;

  /// Programming work runs on the same brain — there is no second model.
  InferenceEngine get programming => reasoner;

  Future<InferenceEngine?>? _translatorLoad;

  /// Load AfriSLM if missing. Never throws — translation stays soft-fail.
  Future<InferenceEngine?> ensureTranslator() async {
    final existing = _translator;
    if (existing != null && existing.isReady) return existing;
    if (translationDisabled) return null;
    if (shared && identical(existing, reasoner)) return existing;

    final inflight = _translatorLoad;
    if (inflight != null) return inflight;

    final pending = _loadTranslator();
    _translatorLoad = pending;
    try {
      return await pending;
    } finally {
      if (identical(_translatorLoad, pending)) _translatorLoad = null;
    }
  }

  Future<InferenceEngine?> _loadTranslator() async {
    if (!androidUsesLiteRt && !cpuSupportsLlamaCpp) {
      debugPrint('TRANSLATION OFF: this CPU lacks AVX2 (llama.cpp would crash).');
      return null;
    }
    try {
      final info = await AfriSlmModelManager().checkModel();
      if (!info.isReady || info.path == null) {
        debugPrint('TRANSLATION OFF: AfriSLM model not on disk yet.');
        return null;
      }
      afrislmPath = info.path;
      final engine = createTranslatorEngine();
      await engine.loadModel(info.path!);
      _translator = engine;
      debugPrint('TRANSLATION ON: AfriSLM at ${info.path}');
      return engine;
    } catch (e, st) {
      debugPrint('TRANSLATION LOAD FAILED: $e\n$st');
      return null;
    }
  }

  /// Kept so existing callers keep working: always the brain.
  Future<InferenceEngine?> ensureProgramming() async => reasoner;

  AiCoderService? _coderService;

  /// Build prompts (sites, apps) on the brain.
  AiCoderService get coderService =>
      _coderService ??= AiCoderService(engine: reasoner);
}

/// Loads the brain when an AI feature first needs it. The translator remains
/// lazy until a non-English turn requests translation; loading both large
/// models eagerly can exhaust memory on classroom phones.
final dualModelRuntimeProvider = FutureProvider<DualModelRuntime>((ref) async {
  Future<DualModelRuntime> demo(DemoReason reason) async {
    final mock = MockEngine(demoReason: reason);
    await mock.loadModel('');
    return DualModelRuntime(reasoner: mock);
  }

  try {
    if (kIsWeb) return demo(DemoReason.web);

    await ref.watch(bundledModelsBootstrapProvider.future);
    final brainInfo = await ref.watch(modelInfoProvider.future);
    final translateInfo = await ref.watch(translateModelInfoProvider.future);
    final plan = planDualGgufs(brainInfo, translateInfo);

    final brainPath = plan.brainPath;
    if (brainPath == null || !isAllowedBrainPath(brainPath)) {
      debugPrint(
        'BRAIN missing. Place ${ModelManager.brainFileName} in models/ '
        '(or use Install Packages).',
      );
      return demo(DemoReason.modelNotInstalled);
    }

    if (!androidUsesLiteRt && !cpuSupportsLlamaCpp) {
      debugPrint('BRAIN skipped: this CPU lacks AVX2 (llama.cpp would crash).');
      return demo(DemoReason.unsupportedCpu);
    }

    final memoryGb = deviceMemoryGb;
    if (!memoryIsEnough(
      memoryGb,
      phone: defaultTargetPlatform == TargetPlatform.android,
    )) {
      debugPrint('BRAIN skipped: ${memoryGb?.toStringAsFixed(1)} GB RAM.');
      return demo(DemoReason.notEnoughMemory);
    }

    final reasoner = createBrainEngine();
    await reasoner.loadModel(brainPath);
    if (reasoner is LiteRtLmEngineImpl) {
      await reasoner.pinSystemPrompt(kTutorContract);
    }
    debugPrint('BRAIN loaded: ${reasoner.backendLabel} at $brainPath');

    const shared = false;
    final afrislmPath = plan.afrislmPath;
    if (plan.canTranslate && plan.sameFile) {
      debugPrint(
        'TRANSLATION OFF: AfriSLM path collided with the brain. '
        'Install the translation model separately.',
      );
    } else if (!plan.canTranslate) {
      debugPrint('TRANSLATION OFF: no AfriSLM model. English-only tutor.');
    }

    final runtime = DualModelRuntime(
      reasoner: reasoner,
      shared: shared,
      translationDisabled: plan.sameFile,
      afrislmPath: afrislmPath,
    );
    ref.onDispose(() async {
      await reasoner.dispose();
      final t = runtime.translator;
      if (t != null && !identical(t, reasoner)) {
        await t.dispose();
      }
    });
    return runtime;
  } catch (e, st) {
    debugPrint('dualModelRuntimeProvider failed: $e\n$st');
    return demo(DemoReason.loadFailed);
  }
});

// ── Engine lifecycle ─────────────────────────────────────────────────────────

final engineLoadedProvider = FutureProvider<InferenceEngine>((ref) async {
  return (await ref.watch(dualModelRuntimeProvider.future)).reasoner;
});

/// Same file as [modelInfoProvider] — programming uses the one brain. Kept
/// as its own name because screens ask "is the coder ready?".
final programmingModelInfoProvider = FutureProvider<ModelInfo>((ref) {
  return ref.watch(modelInfoProvider.future);
});

/// The brain. Kept as its own name for the labs and builders.
final programmingEngineProvider = FutureProvider<InferenceEngine>((ref) {
  return ref.watch(engineLoadedProvider.future);
});

/// Site/app build prompts on the brain.
final aiCoderServiceProvider = FutureProvider<AiCoderService>((ref) async {
  final runtime = await ref.watch(dualModelRuntimeProvider.future);
  return runtime.coderService;
});

/// GGUF / LiteRT chat brain service.
final qwenChatServiceProvider = FutureProvider<QwenChatService>((ref) async {
  final runtime = await ref.watch(dualModelRuntimeProvider.future);
  final info = await ref.watch(modelInfoProvider.future);
  final chat = QwenChatService(runtime.reasoner, modelPath: info.path);
  await chat.warmKvCache();
  return chat;
});

// ── Translation (AfriSLM) ────────────────────────────────────────────────────

final translateModelInfoProvider = FutureProvider<ModelInfo>((ref) async {
  if (kIsWeb) {
    return const ModelInfo(status: ModelStatus.notInstalled);
  }
  try {
    await ref.watch(bundledModelsBootstrapProvider.future);
    return ref.watch(translateModelManagerProvider).checkModel();
  } catch (e, st) {
    debugPrint('translateModelInfoProvider failed: $e\n$st');
    return const ModelInfo(status: ModelStatus.notInstalled);
  }
});

/// Null when translation isn't available (web, no GGUF installed, or
/// llama.cpp failed to load) — translation is always a soft-fail feature,
/// never something that blocks the chat itself.
final translateEngineLoadedProvider = FutureProvider<InferenceEngine?>((ref) async {
  if (kIsWeb) return null;
  final dual = await ref.watch(dualModelRuntimeProvider.future);
  final engine = await dual.ensureTranslator();
  if (engine == null) {
    debugPrint('TRANSLATION OFF: no AfriSLM GGUF loaded.');
  }
  return engine;
});

final translationPipelineProvider = FutureProvider<TranslationPipeline?>((ref) async {
  final engine = await ref.watch(translateEngineLoadedProvider.future);
  if (engine == null) return null;

  // The cache is keyed per model file, so a re-quantized or upgraded GGUF
  // misses rather than serving rows the previous model wrote.
  final modelInfo = await ref.watch(translateModelInfoProvider.future);
  final modelTag = modelInfo.path == null
      ? 'unknown'
      : modelTagFor(
          path: modelInfo.path!,
          sizeBytes: modelInfo.sizeBytes ?? 0,
        );

  return TranslationPipeline(
    engine,
    store: kIsWeb ? null : DriftTranslationStore(ref.watch(dbProvider)),
    modelTag: modelTag,
  );
});

/// Student's learning-language code (`en` if unknown).
///
/// Returning 'en' short-circuits every translation call before the pipeline
/// is even consulted, so a null student (guest, or a profile that has not
/// loaded yet when the first message lands) looks exactly like "translation
/// is broken" from the outside. Log what actually resolved.
///
/// An explicit in-session choice ([languageOverrideProvider]) wins over the
/// stored profile — that is the only way a guest gets a language at all, and
/// it means the model routing agrees with the labels on screen the instant
/// the picker moves, without waiting on the DB write.
///
/// Stays async even though [appLanguageProvider] is synchronous: awaiting the
/// profile is what stops the *first* message of a session being sent
/// untranslated because the student row had not loaded yet.
Future<String> studentLanguageCode(Ref ref) async {
  final override = ref.read(languageOverrideProvider);
  String? persisted;
  try {
    persisted = await ref.read(persistedLanguageProvider.future);
  } catch (e) {
    debugPrint('TRANSLATION: persisted language unread: $e');
  }
  String? studentLanguage;
  try {
    final student = await ref.read(activeStudentProvider.future);
    studentLanguage = student?.language;
    if (student == null) {
      debugPrint('TRANSLATION: no active student row (prefs/override still apply).');
    }
  } catch (e) {
    debugPrint('TRANSLATION OFF: could not read active student: $e');
  }
  final resolved = resolveLearningLanguage(
    override: override,
    persisted: persisted,
    studentLanguage: studentLanguage,
  );
  debugPrint(
    'TRANSLATION lang=$resolved (override=$override prefs=$persisted '
    'student=$studentLanguage)',
  );
  return resolved;
}

/// Best-effort: local-language student text → English for the tutor.
///
/// Pass [langCode] when the caller has already resolved the language for this
/// turn, so one exchange cannot be read in one language and answered in
/// another if the student switches mid-generation.
Future<String> localizeOutgoing(Ref ref, String text, {String? langCode}) async {
  final lang = langCode ?? await studentLanguageCode(ref);
  if (lang == 'en' || text.trim().isEmpty) return text;
  try {
    final pipeline = await ref.read(translationPipelineProvider.future);
    if (pipeline == null) {
      debugPrint('TRANSLATION OFF: no pipeline (in: $lang -> en).');
      return text;
    }
    return await pipeline.toEnglish(text, lang);
  } catch (e) {
    debugPrint('TRANSLATION FAILED (in: $lang -> en): $e');
    return text;
  }
}

/// [localizeIncoming] with the outcome attached, so a caller can tell a real
/// translation from a fallback to English.
///
/// The plain [localizeIncoming] cannot: it returns a String either way, and
/// that ambiguity is exactly how a failed translation used to reach students
/// looking like a working one. Chat uses this; screens that have nowhere to
/// show the distinction keep the simpler wrapper.
Future<TranslationOutcome> localizeIncomingDetailed(
  Ref ref,
  String englishText, {
  TokenCallback? onToken,
  String? langCode,
}) async {
  final lang = langCode ?? await studentLanguageCode(ref);
  if (lang == 'en' || englishText.trim().isEmpty) {
    return TranslationOutcome.passthrough(englishText);
  }
  try {
    final pipeline = await ref.read(translationPipelineProvider.future);
    if (pipeline == null) {
      debugPrint('TRANSLATION OFF: no pipeline (out: en -> $lang).');
      return TranslationOutcome(
        text: englishText,
        translated: false,
        failure: 'translation model unavailable',
      );
    }
    return await pipeline.fromEnglishDetailed(
      englishText,
      lang,
      onToken: onToken,
    );
  } catch (e) {
    debugPrint('TRANSLATION FAILED (out: en -> $lang): $e');
    return TranslationOutcome(
      text: englishText,
      translated: false,
      failure: '$e',
    );
  }
}

/// Best-effort: English tutor text → student's learning language.
Future<String> localizeIncoming(
  Ref ref,
  String englishText, {
  TokenCallback? onToken,
  String? langCode,
}) async {
  final outcome = await localizeIncomingDetailed(
    ref,
    englishText,
    onToken: onToken,
    langCode: langCode,
  );
  return outcome.text;
}

/// Translates a reply and its follow-up prompt.
///
/// This previously returned [followUp] untranslated, so follow-up questions
/// stayed in English even when everything above them was localized.
/// [TranslationPipeline.fromEnglishPair] now translates each part in its own
/// call — AfriSLM was trained on single-text translation, and the labelled
/// two-part prompt this used to send was off-distribution enough that the
/// reply regularly came back unparseable and fell through to English.
Future<(TranslationOutcome, TranslationOutcome)> localizeIncomingPairDetailed(
  Ref ref,
  String reply,
  String followUp, {
  String? langCode,
}) async {
  final lang = langCode ?? await studentLanguageCode(ref);
  if (lang == 'en') {
    return (
      TranslationOutcome.passthrough(reply),
      TranslationOutcome.passthrough(followUp),
    );
  }
  try {
    final pipeline = await ref.read(translationPipelineProvider.future);
    if (pipeline == null) {
      debugPrint('TRANSLATION OFF: no pipeline (pair: en -> $lang).');
      const failure = 'translation model unavailable';
      return (
        TranslationOutcome(text: reply, translated: false, failure: failure),
        TranslationOutcome(text: followUp, translated: false, failure: failure),
      );
    }
    return await pipeline.fromEnglishPairDetailed(reply, followUp, lang);
  } catch (e) {
    debugPrint('TRANSLATION FAILED (pair: en -> $lang): $e');
    return (
      TranslationOutcome(text: reply, translated: false, failure: '$e'),
      TranslationOutcome(text: followUp, translated: false, failure: '$e'),
    );
  }
}

/// Text-only wrapper for [localizeIncomingPairDetailed].
Future<(String, String)> localizeIncomingPair(
  Ref ref,
  String reply,
  String followUp, {
  String? langCode,
}) async {
  final (r, f) =
      await localizeIncomingPairDetailed(ref, reply, followUp, langCode: langCode);
  return (r.text, f.text);
}

/// Warm AfriSLM so the first non-English turn is not blocked on model load.
///
/// If the pipeline resolved to null (file was still downloading, or llama.cpp
/// failed once), rediscover the GGUF and rebuild providers. Never unloads the
/// chat brain.
Future<TranslationPipeline?> ensureTranslationPipeline(Ref ref) async {
  try {
    final existing = await ref.read(translationPipelineProvider.future);
    if (existing != null) return existing;

    final runtime = await ref.read(dualModelRuntimeProvider.future);
    var engine = await runtime.ensureTranslator();
    if (engine == null) {
      ref.invalidate(translateModelInfoProvider);
      final info = await ref.read(translateModelInfoProvider.future);
      if (info.isReady) {
        runtime.afrislmPath = info.path;
        engine = await runtime.ensureTranslator();
      }
    }
    if (engine == null) {
      debugPrint('ensureTranslationPipeline: AfriSLM still unavailable.');
      return null;
    }

    ref.invalidate(translateEngineLoadedProvider);
    ref.invalidate(translationPipelineProvider);
    ref.invalidate(afrislmTranslationServiceProvider);
    ref.invalidate(aiEngineServiceProvider);
    ref.invalidate(chatInferencePipelineProvider);
    return await ref.read(translationPipelineProvider.future);
  } catch (e) {
    debugPrint('ensureTranslationPipeline failed: $e');
    return null;
  }
}

/// Batch-translate path titles. English sessions pass through unchanged.
Future<List<String>> localizeMany(Ref ref, List<String> strings) async {
  if (strings.isEmpty) return strings;
  final lang = await studentLanguageCode(ref);
  if (lang == 'en') return strings;
  final out = <String>[];
  for (final s in strings) {
    out.add(await localizeIncoming(ref, s, langCode: lang));
  }
  return out;
}

/// User-facing AI runtime status (real model vs demo).
class AiStatus {
  const AiStatus({
    required this.isDemo,
    required this.title,
    required this.detail,
    this.backendLabel,
  });

  final bool isDemo;
  final String title;
  final String detail;
  final String? backendLabel;

  factory AiStatus.fromEngine(InferenceEngine engine) {
    if (engine is MockEngine) {
      return AiStatus(
        isDemo: true,
        title: engine.demoReason.title,
        detail: engine.demoReason.detail,
        backendLabel: engine.backendLabel,
      );
    }
    return AiStatus(
      isDemo: false,
      title: 'AI ready',
      detail: 'Answers are made on this device.',
      backendLabel: engine.backendLabel,
    );
  }
}

final aiStatusProvider = Provider<AsyncValue<AiStatus>>((ref) {
  return ref.watch(engineLoadedProvider).when(
        data: (engine) => AsyncData(AiStatus.fromEngine(engine)),
        loading: () => const AsyncLoading(),
        error: (e, st) => AsyncError(e, st),
      );
});

// ── Tutor pipeline ───────────────────────────────────────────────────────────

final tutorPipelineProvider = FutureProvider<TutorPipeline>((ref) async {
  final engine = await ref.watch(engineLoadedProvider.future);
  final curriculum = ref.watch(curriculumServiceProvider);
  curriculum.loadAll();
  final rag = ref.watch(offlineRagServiceProvider);
  final explanations = ref.watch(topicExplanationServiceProvider);
  explanations.all();
  return TutorPipeline(
    engine: engine,
    curriculum: curriculum,
    teacherNotes: (text) => rag.retrieveAcrossSubjects(text, limit: 2),
    explanations: explanations,
  );
});

final qwenReasoningServiceProvider = FutureProvider<QwenReasoningService>((ref) async {
  final runtime = await ref.watch(dualModelRuntimeProvider.future);
  final info = await ref.watch(modelInfoProvider.future);
  final service = QwenReasoningService(
    runtime.reasoner,
    modelPath: info.path,
  );
  await service.warmKvCache();
  return service;
});

final afrislmTranslationServiceProvider =
    FutureProvider<AfriSlmTranslationService?>((ref) async {
  final pipeline = await ref.watch(translationPipelineProvider.future);
  if (pipeline == null) return null;
  final engine = await ref.watch(translateEngineLoadedProvider.future);
  return AfriSlmTranslationService(pipeline, engine: engine);
});

/// Translator isolation facade (no LiteRT/GGUF loaders inside).
final aiEngineServiceProvider = FutureProvider<AiEngineService>((ref) async {
  final translator = await ref.watch(afrislmTranslationServiceProvider.future);
  return AiEngineService(translator);
});

final chatInferencePipelineProvider = FutureProvider<ChatInferencePipeline>((ref) async {
  final runtime = await ref.watch(dualModelRuntimeProvider.future);
  final reasoner = await ref.watch(qwenReasoningServiceProvider.future);
  final tutor = await ref.watch(tutorPipelineProvider.future);
  final translator = await ref.watch(afrislmTranslationServiceProvider.future);
  return ChatInferencePipeline(
    reasoner: reasoner,
    tutor: tutor,
    translator: translator,
    loadProgrammingEngine: runtime.ensureProgramming,
  );
});

// ── Chat state ───────────────────────────────────────────────────────────────

class ChatState {
  const ChatState({
    this.messages = const [],
    this.isGenerating = false,
    this.streamingText = '',
    this.streamingMath,
    this.turnTokens = const Stream.empty(),
    this.errorMessage,
  });

  final List<ChatMessage> messages;
  final bool isGenerating;
  final String streamingText;
  final SchoolMathSolution? streamingMath;
  final Stream<String> turnTokens;
  final String? errorMessage;

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isGenerating,
    String? streamingText,
    SchoolMathSolution? streamingMath,
    Stream<String>? turnTokens,
    String? errorMessage,
    bool clearError = false,
    bool clearStreamingMath = false,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isGenerating: isGenerating ?? this.isGenerating,
      streamingText: streamingText ?? this.streamingText,
      streamingMath:
          clearStreamingMath ? null : (streamingMath ?? this.streamingMath),
      turnTokens: turnTokens ?? this.turnTokens,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class ChatMessage {
  const ChatMessage({
    required this.text,
    required this.isUser,
    this.stage,
    this.followUp,
    this.isError = false,
    this.translatedLanguage,
    this.translationFailure,
    this.math,
    this.mathCoach = false,
    this.lesson,
    this.recap,
    this.diagrams = const [],
    this.suggestions = const [],
  });

  final String text;
  final bool isUser;

  /// What the learner may want next ("Next: Convection (Heat Transfer)",
  /// "Quiz me on Conduction"): buttons under the latest reply that send
  /// their text.
  final List<String> suggestions;

  /// Teacher-PDF pages this reply points to — see [TutorResponse.diagrams].
  final List<DiagramMarker> diagrams;

  /// Set only on the single placeholder message that opens a reopened chat.
  ///
  /// Gist lines are clipped, so rendering them as ordinary bubbles would show
  /// a student their own words cut mid-sentence and read as data loss. The UI
  /// draws this as one distinct "picking up from" recap card instead.
  final SessionRecall? recap;

  bool get isRecap => recap != null;
  final TutorStage? stage;
  final String? followUp;
  final bool isError;

  /// Set when this message was translated for display — the language code
  /// it was translated into (tutor replies) or the language the student
  /// wrote in and that was translated to English behind the scenes (user
  /// messages). Null means no translation was involved.
  final String? translatedLanguage;

  /// Set when the student is learning in a non-English language but this
  /// reply could not be translated, so what they are reading is English.
  ///
  /// Without this the fallback is invisible: the reply simply arrives in
  /// English and looks like the tutor chose to answer that way. Carrying the
  /// reason lets the UI say "shown in English — translation unavailable"
  /// instead of silently lying by omission.
  final String? translationFailure;

  /// Dart-computed worked solution. Formulas stay in English so translation
  /// cannot scramble the arithmetic.
  final SchoolMathSolution? math;
  final bool mathCoach;

  /// Curriculum lesson matched on this user question (Learn mode).
  final Lesson? lesson;

  ChatMessage copyWith({Lesson? lesson}) {
    return ChatMessage(
      text: text,
      isUser: isUser,
      stage: stage,
      followUp: followUp,
      isError: isError,
      translatedLanguage: translatedLanguage,
      translationFailure: translationFailure,
      math: math,
      mathCoach: mathCoach,
      lesson: lesson ?? this.lesson,
      diagrams: diagrams,
      suggestions: suggestions,
    );
  }
}

class ChatNotifier extends AsyncNotifier<ChatState> {
  ChatSection _section = ChatSection.learn;
  bool _programmingSubject = false;

  /// Bumped by [reset]. A turn that started before a refresh must not write
  /// its reply — or leave its prompt memory — in the conversation that
  /// replaced it.
  int _epoch = 0;

  /// The chat currently open, or null before its first turn has landed.
  ///
  /// One id per conversation, minted lazily and cleared by [reset], so the
  /// sidebar index gets one row per chat instead of one per reply.
  String? _sessionId;

  /// Last persisted state of the open chat, kept in memory so each turn
  /// appends to it rather than re-reading the file.
  SessionRecall? _recall;
  Future<void> _pendingContext = Future<void>.value();

  void _queueContext(Future<void> Function() remember) {
    _pendingContext = _pendingContext.then((_) => remember());
  }

  String? get openSessionId => _sessionId;

  @override
  Future<ChatState> build() async {
    return const ChatState();
  }

  static const _safetyEngine = EmotionalSafetyEngine();

  void setSection(ChatSection section) => _section = section;

  void setProgrammingSubject(bool value) => _programmingSubject = value;

  void clearError() {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(clearError: true));
  }

  Future<void> send(String message, {ChatSection? section}) async {
    final current = state.valueOrNull ?? const ChatState();
    if (current.isGenerating) return;
    final epoch = _epoch;
    final useCurriculum =
        (section ?? _section) == ChatSection.learn;

    final thread = <ChatMessage>[
      ...current.messages,
      ChatMessage(text: message, isUser: true),
    ];
    final tokenCtrl = StreamController<String>.broadcast();
    state = AsyncData(current.copyWith(
      messages: List<ChatMessage>.from(thread),
      isGenerating: true,
      streamingText: '',
      turnTokens: tokenCtrl.stream,
      clearError: true,
      clearStreamingMath: true,
    ));

    var replyRecorded = false;
    void pushUi(String cumulative) {
      if (!tokenCtrl.isClosed) tokenCtrl.add(cumulative);
      final cur = state.valueOrNull;
      if (cur == null || !cur.isGenerating || epoch != _epoch) return;
      state = AsyncData(cur.copyWith(streamingText: cumulative));
      // The learner reads the reply as it streams: in memory per token, on
      // disk once, so a reply stopped mid-way still counts.
      ref.read(tutorLastReplyProvider.notifier).state = DateTime.now();
      if (!replyRecorded) {
        replyRecorded = true;
        unawaited(recordTutorReply(ref));
      }
    }

    void pushMath(SchoolMathSolution partial) {
      final cur = state.valueOrNull;
      if (cur == null || !cur.isGenerating || epoch != _epoch) return;
      state = AsyncData(cur.copyWith(streamingMath: partial));
    }

    final lang = await studentLanguageCode(ref);

    // A whole syllabus topic ("What is photosynthesis?") is reviewed text and
    // needs no model, so it is shown at once instead of waiting for the model
    // to load or finish background work, in the Learn and Home chats alike.
    // The tutor is told afterwards, for the follow-ups. Translated chats take
    // the normal path. With no lesson on it, a teacher may have allowed an
    // online look-up. Anything the safety check flags takes the normal path.
    final safe = _safetyEngine.check(message);
    if (lang == 'en' &&
        !_programmingSubject &&
        !safe.bypassTutor &&
        safe.tutorNote == null) {
      final explanations = ref.read(topicExplanationServiceProvider);

      // "Connect to internet", "go online": an instruction to the device, not
      // a topic to teach. Answered plainly, pointing back to the chat's topic.
      if (_asksToGoOnline.hasMatch(message.trim().toLowerCase())) {
        final earlier = _lastTopicAskedAbout(thread.take(thread.length - 1));
        final reply = "I can't switch the internet on myself. Turn on Wi-Fi or "
            "mobile data on this device, and I'll use the connection on my own "
            'for pictures and look-ups.'
            '${earlier == null ? '' : ' Then ask me about **$earlier** again.'}';
        thread.add(
          ChatMessage(text: reply, isUser: false, stage: TutorStage.answer),
        );
        _queueContext(
          () => _noteExchange(message, reply, epoch, topic: earlier),
        );
        await tokenCtrl.close();
        if (epoch != _epoch) return;
        state = AsyncData(
          state.requireValue.copyWith(
            messages: List<ChatMessage>.from(thread),
            isGenerating: false,
            streamingText: '',
            clearError: true,
            clearStreamingMath: true,
          ),
        );
        ref.read(tutorLastReplyProvider.notifier).state = DateTime.now();
        unawaited(recordTutorReply(ref));
        return;
      }

      // "Give me a photo", "show me a picture of a frog": the model can't make
      // pictures, so the app answers with real ones — the bundled diagram,
      // and freely licensed photos when a teacher allows online look-ups.
      final clipFor = clipRequestSubject(message);
      final clipSubject = clipFor == null
          ? null
          : clipFor.isNotEmpty
              ? clipFor
              : _lastTopicAskedAbout(thread.take(thread.length - 1));
      if (clipSubject != null) {
        // The school hub's own clips first: they play without internet.
        final hub = ref.read(onlineTutorProvider);
        final online = ref.read(onlineTopicLookupEnabledProvider);
        var clips = hub == null ? const <WebClip>[] : await hub.clips(clipSubject);
        if (clips.isEmpty && online) {
          clips = await ref.read(onlineTopicLookupProvider).clips(clipSubject);
        }
        final reply = clipsReply(
          clipSubject,
          clips,
          onlineAllowed: online || hub != null,
        );
        thread.add(
          ChatMessage(text: reply, isUser: false, stage: TutorStage.answer),
        );
        _queueContext(
          () => _noteExchange(message, reply, epoch, topic: clipSubject),
        );
        await tokenCtrl.close();
        if (epoch != _epoch) return;
        state = AsyncData(
          state.requireValue.copyWith(
            messages: List<ChatMessage>.from(thread),
            isGenerating: false,
            streamingText: '',
            clearError: true,
            clearStreamingMath: true,
          ),
        );
        ref.read(tutorLastReplyProvider.notifier).state = DateTime.now();
        unawaited(recordTutorReply(ref));
        return;
      }

      final pictureFor = pictureRequestSubject(message);
      final earlierTopic = pictureFor == null
          ? null
          : _lastTopicAskedAbout(thread.take(thread.length - 1));
      final pictureTopic = pictureFor == null
          ? null
          : pictureFor.isNotEmpty
              ? pictureFor
              : earlierTopic;
      if (pictureTopic != null) {
        // "Images of its diverse cultures": try "africa diverse cultures"
        // before "diverse cultures" on its own.
        final candidates = pictureFor!.isEmpty
            ? [pictureTopic]
            : pictureSubjectCandidates(message, pictureFor, earlierTopic);
        var pictureSubject = candidates.first;
        TopicExplanation? local;
        var web = const <WebPicture>[];
        var fromHub = false;
        final hub = ref.read(onlineTutorProvider);
        for (final c in candidates) {
          local ??= await explanations.localPicture(c);
          // The school hub's own pictures first: they show without internet.
          if (hub != null) {
            web = await hub.pictures(c);
            fromHub = web.isNotEmpty;
          }
          if (web.isEmpty && ref.read(onlineTopicLookupEnabledProvider)) {
            web = await ref.read(onlineTopicLookupProvider).pictures(c);
          }
          if (web.isNotEmpty || local != null) {
            pictureSubject = c;
            break;
          }
        }
        if (local != null) {
          thread[thread.length - 1] =
              thread.last.copyWith(lesson: local.asLesson());
        }
        final reply = picturesReply(
          pictureSubject,
          local: local,
          web: web,
          onlineAllowed: ref.read(onlineTopicLookupEnabledProvider) || hub != null,
          from: fromHub ? 'the school library' : 'Wikipedia',
        );
        thread.add(
          ChatMessage(text: reply, isUser: false, stage: TutorStage.answer),
        );
        _queueContext(
          () => _noteExchange(message, reply, epoch, topic: pictureSubject),
        );
        await tokenCtrl.close();
        if (epoch != _epoch) return;
        state = AsyncData(
          state.requireValue.copyWith(
            messages: List<ChatMessage>.from(thread),
            isGenerating: false,
            streamingText: '',
            clearError: true,
            clearStreamingMath: true,
          ),
        );
        ref.read(tutorLastReplyProvider.notifier).state = DateTime.now();
        unawaited(recordTutorReply(ref));
        return;
      }

      // "Who is the president of Uganda?": people and office-holders change
      // and the on-device model only guesses, so they are looked up, and
      // when that can't be done the learner is told so plainly.
      final asksWho = whoTopic(message) != null;
      final who = asksWho && ref.read(onlineTopicLookupEnabledProvider)
          ? await ref.read(onlineTopicLookupProvider).lookUp(message)
          : null;
      if (asksWho && who == null) {
        const reply = "I can't check facts about people right now — that needs "
            'the online look-up, and the device may be offline. Ask your '
            'teacher, or try again when you are connected. I can help with any '
            'school subject in the meantime.';
        thread.add(
          const ChatMessage(
            text: reply,
            isUser: false,
            stage: TutorStage.answer,
          ),
        );
        _queueContext(
          () => _noteExchange(message, reply, epoch, topic: whoTopic(message)),
        );
        await tokenCtrl.close();
        if (epoch != _epoch) return;
        state = AsyncData(
          state.requireValue.copyWith(
            messages: List<ChatMessage>.from(thread),
            isGenerating: false,
            streamingText: '',
            clearError: true,
            clearStreamingMath: true,
          ),
        );
        ref.read(tutorLastReplyProvider.notifier).state = DateTime.now();
        unawaited(recordTutorReply(ref));
        return;
      }
      final named = who != null ? null : await explanations.match(message);
      // A topic no lesson is named after ("triangles") still grounds the
      // answer in the lesson that covers it.
      final local =
          who != null ? null : named ?? await explanations.covering(message);
      // The online tutor first, when a teacher has switched it on and it can
      // be reached, grounded in any lesson that matched: it answers far
      // better than the on-device model, and a school hub teaches a whole
      // topic part by part ("Teach me heat transfer"), with suggestions.
      // The lessons on this device below are the fallback.
      final online = who == null ? ref.read(onlineTutorProvider) : null;
      final reply = online == null
          ? null
          : await online.answer(
              message,
              history: [
                for (final m in thread.take(thread.length - 1))
                  if (!m.isError)
                    if (m.recap case final recap?)
                      for (final e in recap.exchanges.reversed.take(6).toList().reversed)
                        ...[(isUser: true, text: e.question), (isUser: false, text: e.answer)]
                    else
                      (isUser: m.isUser, text: m.text),
              ],
              lesson: local?.groundingNotes(message, max: 3000),
              onText: pushUi,
            );
      if (reply != null) {
        thread.add(
          ChatMessage(
            text: reply.text,
            isUser: false,
            stage: TutorStage.answer,
            suggestions: reply.suggestions,
          ),
        );
        await tokenCtrl.close();
        if (epoch != _epoch) return;
        state = AsyncData(
          state.requireValue.copyWith(
            messages: List<ChatMessage>.from(thread),
            isGenerating: false,
            streamingText: '',
            clearError: true,
            clearStreamingMath: true,
          ),
        );
        ref.read(tutorLastReplyProvider.notifier).state = DateTime.now();
        unawaited(recordTutorReply(ref));
        _queueContext(() => _saveOnlineTurn(message, reply.text, epoch));
        return;
      }
      var topic = who ??
          (local != null && asksForWholeTopic(message, local.wholeTopicNames)
              ? local
              : null);
      // "Teach me about triangles": no lesson is called that, so the topic is
      // put together from every lesson that teaches it, with a picture —
      // the online look-up's, when allowed and this has none.
      if (topic == null && named == null) {
        topic = await explanations.compose(message);
        if (topic != null &&
            topic.diagram == null &&
            ref.read(onlineTopicLookupEnabledProvider)) {
          final web =
              await ref.read(onlineTopicLookupProvider).lookUp(message);
          if (web != null) topic = topic.withOnline(web);
        }
      }
      if (topic == null &&
          local == null &&
          ref.read(onlineTopicLookupEnabledProvider)) {
        topic = await ref.read(onlineTopicLookupProvider).lookUp(message);
      }
      if (topic != null) {
        thread[thread.length - 1] = thread.last.copyWith(
          lesson: topic.asLesson(),
        );
        final name = topic.title.isEmpty ? 'this topic' : topic.title;
        thread.add(
          ChatMessage(
            text: topic.fullText(),
            isUser: false,
            stage: TutorStage.answer,
            suggestions: [
              'Give me an example of $name',
              'Explain $name more simply',
              'Quiz me on $name',
            ],
          ),
        );
        await tokenCtrl.close();
        if (epoch != _epoch) return;
        state = AsyncData(
          state.requireValue.copyWith(
            messages: List<ChatMessage>.from(thread),
            isGenerating: false,
            streamingText: '',
            clearError: true,
            clearStreamingMath: true,
          ),
        );
        ref.read(tutorLastReplyProvider.notifier).state = DateTime.now();
        unawaited(recordTutorReply(ref));
        final explained = topic;
        _queueContext(() => _handOverExplanation(explained, message, epoch));
        return;
      }
    }

    if (lang != 'en') {
      await ensureTranslationPipeline(ref);
    }

    final ChatInferencePipeline cascade;
    try {
      cascade = await ref.read(chatInferencePipelineProvider.future);
      cascade.preferProgramming = _programmingSubject ||
          looksLikeProgramming(message);
    } catch (e) {
      await tokenCtrl.close();
      if (epoch != _epoch) return;
      thread.add(ChatMessage(
        text: _friendlyAiError(e),
        isUser: false,
        isError: true,
      ));
      state = AsyncData(state.requireValue.copyWith(
        messages: List<ChatMessage>.from(thread),
        isGenerating: false,
        streamingText: '',
        errorMessage: _friendlyAiError(e),
      ));
      return;
    }

    // True when a refresh landed mid-turn, so nothing from this turn may be
    // shown or remembered. The tutor has already written the exchange into
    // the conversation memory reset() just cleared, so clear it again —
    // unless a newer turn is running, which would lose its own context.
    bool discardIfStale() {
      if (epoch == _epoch) return false;
      if (!(state.valueOrNull?.isGenerating ?? false)) cascade.reset();
      return true;
    }

    String englishForSafety = message;
    if (lang != 'en' &&
        !queryLooksLikeMath(message) &&
        !isMathPassThrough(message)) {
      englishForSafety = toEnglishFollowUp(message, langCode: lang) ??
          await localizeOutgoing(ref, message, langCode: lang);
    }

    final safety = _safetyEngine.check(englishForSafety);
    if (safety.bypassTutor) {
      final support = await localizeIncoming(
        ref,
        safety.supportMessage!,
        langCode: lang,
      );
      pushUi(support);
      await tokenCtrl.close();
      if (discardIfStale()) return;
      thread.add(ChatMessage(text: support, isUser: false));
      state = AsyncData(
        state.requireValue.copyWith(
          messages: List<ChatMessage>.from(thread),
          isGenerating: false,
          streamingText: '',
        ),
      );
      return;
    }

    try {
      final hasTranslator =
          cascade.translator != null && cascade.translator!.isAvailable;
      await _pendingContext;
      if (discardIfStale()) return;
      final turn = await cascade.completeTurn(
        userText: message,
        languageCode: lang,
        useCurriculum: useCurriculum,
        safetyNote: safety.tutorNote,
        // Never feed local-language text to Qwen as "English" when AfriSLM
        // is still missing after Install Packages — let the cascade soft-fail.
        pretranslatedEnglish: queryLooksLikeMath(message) ||
                isMathPassThrough(message) ||
                lang == 'en' ||
                !hasTranslator
            ? null
            : englishForSafety,
        onUiToken: pushUi,
      );

      if (turn.response.lesson != null) {
        final lastUserIdx = thread.lastIndexWhere((m) => m.isUser);
        if (lastUserIdx >= 0) {
          thread[lastUserIdx] = thread[lastUserIdx].copyWith(
            lesson: turn.response.lesson,
          );
        }
      }

      var reply = turn.displayText;
      var followUp = turn.response.followUpPrompt;
      var math = turn.response.math;
      var translatedLanguage = turn.translatedLanguage;
      var translationFailure = turn.translationFailure;

      if (math != null) {
        pushMath(math);
        try {
          math = await localizeSchoolMath(
            math,
            langCode: lang,
            translate: (english) async {
              final o = await localizeIncomingDetailed(
                ref,
                english,
                langCode: lang,
              );
              return o.translated ? o.text : english;
            },
            onProgress: pushMath,
          );
          if (lang != 'en') translatedLanguage = lang;
        } catch (e) {
          debugPrint('TRANSLATION FAILED for math steps (en -> $lang): $e');
        }
        if (turn.response.text.trimLeft().startsWith('Step')) {
          reply = '';
        }
      }

      if (followUp.isNotEmpty) {
        followUp = _chromeFollowUp(followUp, lang);
      }

      thread.add(ChatMessage(
        text: reply,
        isUser: false,
        stage: turn.response.stage,
        followUp: followUp,
        translatedLanguage: translatedLanguage,
        translationFailure: translationFailure,
        math: math,
        mathCoach: turn.response.mathCoach,
        diagrams: turn.response.diagrams,
      ));

      await tokenCtrl.close();
      if (discardIfStale()) return;
      state = AsyncData(state.requireValue.copyWith(
        messages: List<ChatMessage>.from(thread),
        isGenerating: false,
        streamingText: '',
        clearError: true,
        clearStreamingMath: true,
      ));
      unawaited(recordTutorReply(ref));

      final pipeline = await ref.read(tutorPipelineProvider.future);
      unawaited(_saveSessionSnapshot(
        pipeline,
        turn.response,
        thread.length,
      ));
      // `message` is what the student actually typed, before any translation
      // to English — a sidebar title they cannot recognise is worthless.
      unawaited(_persistSession(
        pipeline: pipeline,
        studentMessage: message,
        reply: reply.isEmpty ? turn.response.text : reply,
        response: turn.response,
        epoch: epoch,
      ));
    } catch (e) {
      await tokenCtrl.close();
      if (discardIfStale()) return;
      final friendly = _friendlyAiError(e);
      thread.add(ChatMessage(text: friendly, isUser: false, isError: true));
      state = AsyncData(state.requireValue.copyWith(
        messages: List<ChatMessage>.from(thread),
        isGenerating: false,
        streamingText: '',
        errorMessage: friendly,
      ));
    }
  }

  /// "Connect to internet", "please go online", "turn on wifi" — an order to
  /// the device. "How do I connect to the internet?" is a question, and is
  /// taught as usual.
  static final _asksToGoOnline = RegExp(
    r'^(please |pls |can you |could you )?'
    r'(connect( me)?( to)?( the)? (internet|wi-?fi|network|online)|'
    r'go online|get online|(turn|switch) on( the)? (internet|wi-?fi|data))'
    r'( please| now)?[.!?]*$',
  );

  /// The topic the learner last asked about ("what is a frog" → "frog"),
  /// newest first, for a picture request that names none.
  static String? _lastTopicAskedAbout(Iterable<ChatMessage> earlier) {
    for (final m in earlier.toList().reversed) {
      if (!m.isUser) continue;
      final picture = pictureRequestSubject(m.text) ?? clipRequestSubject(m.text);
      if (picture != null && picture.isNotEmpty) return picture;
      final asked = askedTopic(m.text);
      if (asked != null) return asked;
    }
    return null;
  }

  /// Tells the tutor about a turn the chat answered itself (a picture, a
  /// clip, a look-up), so the next message follows on from it.
  Future<void> _noteExchange(
    String message,
    String reply,
    int epoch, {
    String? topic,
  }) async {
    try {
      final pipeline = await ref.read(tutorPipelineProvider.future);
      if (epoch != _epoch) return;
      pipeline.noteExchange(message, reply, topic: topic);
    } catch (e) {
      debugPrint('Turn not noted for the tutor: $e');
    }
  }

  /// Saves a turn the online tutor answered, as after any other turn.
  Future<void> _saveOnlineTurn(String message, String reply, int epoch) async {
    try {
      final pipeline = await ref.read(tutorPipelineProvider.future);
      if (epoch != _epoch) return;
      // The on-device tutor takes over when the connection drops; it must
      // know what was said so far.
      pipeline.noteExchange(message, reply);
      final response = TutorResponse(
        stage: TutorStage.answer,
        text: reply,
        followUpPrompt: '',
        topic: pipeline.currentTopic,
      );
      final count = state.valueOrNull?.messages.length ?? 0;
      unawaited(_saveSessionSnapshot(pipeline, response, count));
      unawaited(_persistSession(
        pipeline: pipeline,
        studentMessage: message,
        reply: reply,
        response: response,
        epoch: epoch,
      ));
    } catch (e) {
      debugPrint('Online tutor turn not saved: $e');
    }
  }

  /// Gives the tutor a whole-topic explanation [send] showed without it, then
  /// saves the chat as after any other turn.
  Future<void> _handOverExplanation(
    TopicExplanation topic,
    String message,
    int epoch,
  ) async {
    try {
      final pipeline = await ref.read(tutorPipelineProvider.future);
      if (epoch != _epoch) return;
      final response = await pipeline.adoptExplanation(topic, message);
      final count = state.valueOrNull?.messages.length ?? 0;
      unawaited(_saveSessionSnapshot(pipeline, response, count));
      unawaited(_persistSession(
        pipeline: pipeline,
        studentMessage: message,
        reply: response.text,
        response: response,
        epoch: epoch,
      ));
    } catch (e) {
      debugPrint('Topic explanation hand-over failed: $e');
    }
  }

  Future<void> _saveSessionSnapshot(
    TutorPipeline pipeline,
    TutorResponse response,
    int msgCount,
  ) async {
    try {
      final student = await ref.read(activeStudentProvider.future);
      if (student == null) return;
      final db = ref.read(dbProvider);

      // Truncate — never call the chat model again here (it queued behind
      // the student's next question and made replies feel stuck).
      final summary = response.text.length > 200
          ? '${response.text.substring(0, 200)}…'
          : response.text;

      await db.sessionDao.saveSession(
        studentId: student.id,
        topic: response.topic,
        summary: summary,
        highestStage: response.stage.name,
        messageCount: msgCount,
      );
      ref.invalidate(recentSessionsProvider(student.id));
    } catch (_) {
      // Never crash the chat if DB write fails
    }
  }

  /// Write the open chat to its recall file and index row.
  ///
  /// Runs unawaited after every turn. Deliberately not debounced: the files
  /// are a few KB, and batching would mean a hard close loses the most recent
  /// turn — precisely the one a student is most likely to come back for.
  Future<void> _persistSession({
    required TutorPipeline pipeline,
    required String studentMessage,
    required String reply,
    required TutorResponse response,
    required int epoch,
  }) async {
    try {
      if (epoch != _epoch) return;
      final student = await ref.read(activeStudentProvider.future);
      // Guests keep no saved state, so there is nothing to index against.
      if (student == null) return;

      final now = DateTime.now();
      final existing = _recall;
      final id = _sessionId ??= SessionRecallStore.newSessionId();

      final base = existing ??
          SessionRecall(
            id: id,
            studentId: student.id,
            title: SessionRecall.titleFrom(studentMessage),
            topic: response.topic,
            stage: response.stage.name,
            createdAt: now,
            updatedAt: now,
          );

      // Topic changes keep this conversation's history and original title.
      // Persist the current grounding and memory together for reopening.
      final updated = base.withExchange(
        question: studentMessage,
        answer: reply,
        stage: response.stage.name,
        memory: pipeline.memorySnapshot(),
        topic: response.topic.isEmpty ? base.topic : response.topic,
        at: now,
      );

      if (epoch != _epoch) return;
      _recall = updated;

      final store = ref.read(sessionRecallStoreProvider);
      await store.save(updated);
      await ref.read(dbProvider).chatSessionDao.upsertSession(
            id: updated.id,
            studentId: student.id,
            title: updated.title,
            topic: updated.topic,
            preview: updated.preview,
            stage: updated.stage,
            turnCount: updated.turnCount,
            updatedAt: now,
          );
    } catch (e) {
      // A failed write must never take the chat down with it.
      debugPrint('session recall: persist failed: $e');
    }
  }

  /// Reopen a saved chat: restore the tutor's memory and show a recap.
  ///
  /// Returns false when the recall file is missing or damaged, so the caller
  /// can drop the stale tile instead of leaving the student on a blank chat
  /// that silently does nothing.
  Future<bool> restoreSession(String id) async {
    final store = ref.read(sessionRecallStoreProvider);
    final recall = await store.load(id);
    if (recall == null) return false;

    // Start from a clean slate, then adopt the saved session. reset() bumps
    // the epoch, which also cancels any turn still in flight.
    reset();

    try {
      final pipeline = await ref.read(tutorPipelineProvider.future);
      await pipeline.restoreSession(
        memory: recall.memory,
        topic: recall.topic,
        nextStage: TutorStage.values.firstWhere(
          (s) => s.name == recall.stage,
          orElse: () => TutorStage.answer,
        ),
      );
    } catch (e) {
      // Memory could not be seeded — the chat still opens, just colder.
      debugPrint('session recall: could not seed tutor memory: $e');
    }

    _sessionId = recall.id;
    _recall = recall;
    state = AsyncData(ChatState(
      messages: [ChatMessage(text: '', isUser: false, recap: recall)],
    ));
    return true;
  }

  /// Forget a saved chat entirely — index row and file.
  Future<void> deleteSession(String id) async {
    await ref.read(dbProvider).chatSessionDao.deleteSession(id);
    await ref.read(sessionRecallStoreProvider).delete(id);
    if (_sessionId == id) {
      reset();
    }
  }

  void reset() {
    _epoch++;
    _programmingSubject = false;
    // The next turn starts a new chat rather than appending to the one that
    // was on screen.
    _sessionId = null;
    _recall = null;
    _pendingContext = Future<void>.value();
    ref.read(chatInferencePipelineProvider).valueOrNull?.reset();
    ref.read(tutorPipelineProvider).valueOrNull?.reset();
    unawaited(
      ref.read(engineLoadedProvider).valueOrNull?.resetSession() ??
          Future<void>.value(),
    );
    state = const AsyncData(ChatState());
  }
}

String _chromeFollowUp(String followUp, String lang) {
  if (lang == 'en' || followUp.isEmpty) return followUp;
  const keys = [
    'Your turn — try this:',
    'Give it a try and tell me your answer.',
    'Try it, then tell me your answer.',
    'Have another go, or ask me to show the full steps.',
    'Want another problem like this?',
    'Take your time — there are no wrong answers here.',
    'Do you understand so far, or shall I explain it differently?',
    'Can you think of another real-life example like this?',
    'Share what you made or describe your idea.',
    'Great work! Ready to explore the next topic?',
    'Try changing one value in the example and tell me what happens.',
    'In your own words, what does that line of code do?',
    'Paste your attempt — I will check it.',
    'Where would you use this in a real program?',
    'Write a tiny program that uses this idea.',
    'What is one thing you can now do in code that you could not before?',
  ];
  for (final key in keys) {
    if (!hasUiString(lang, key)) continue;
    final localized = uiString(lang, key)!;
    if (followUp == key) return localized;
    if (followUp.startsWith(key)) {
      return '$localized${followUp.substring(key.length)}';
    }
  }
  return followUp;
}

String _friendlyAiError(Object e) {
  final raw = e.toString();
  if (raw.contains('ModelLoadException') || raw.contains('failed to load')) {
    return 'The classroom assistant could not start. Open Settings → Install Packages, then try again.';
  }
  if (raw.contains('SocketException') || raw.contains('Connection')) {
    return 'Couldn’t reach the classroom assistant. Open Settings, then try again.';
  }
  return 'Couldn’t get an answer just now. Please try again.';
}

final chatProvider = AsyncNotifierProvider<ChatNotifier, ChatState>(ChatNotifier.new);

/// Cumulative localized tokens for the in-flight bubble ([StreamBuilder]).
final chatUiTokenStreamProvider = StreamProvider<String>((ref) {
  final tokens = ref.watch(chatProvider).valueOrNull?.turnTokens;
  return tokens ?? const Stream<String>.empty();
});
