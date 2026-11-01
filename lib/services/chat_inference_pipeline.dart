import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ai_core/inference/inference_engine.dart';
import '../ai_core/inference/llama_cpp_engine.dart';
import '../ai_core/inference/runtime_config.dart';
import '../ai_core/inference/sanitize_llm_response.dart';
import '../ai_core/inference/stream_cascade.dart';
import '../ai_core/science/science_text.dart';
import '../ai_core/translate/follow_up_glossary.dart';
import '../ai_core/translate/translation_pipeline.dart';
import '../ai_core/tutor/programming_topic.dart';
import '../ai_core/tutor/school_math.dart';
import '../ai_core/tutor/tutor_contract.dart';
import '../ai_core/tutor/tutor_pipeline.dart';
import '../ai_core/tutor/tutor_response.dart';
import 'afrislm_translation_service.dart';
import 'qwen_reasoning_service.dart';

/// Result of one dual-model turn.
class ChatPipelineTurn {
  const ChatPipelineTurn({
    required this.response,
    required this.displayText,
    required this.englishUser,
    this.translatedLanguage,
    this.translationFailure,
  });

  final TutorResponse response;
  final String displayText;
  final String englishUser;
  final String? translatedLanguage;
  final String? translationFailure;
}

/// Asymmetric cascade: AfriSLM inbound → Qwen English KV → AfriSLM outbound.
///
/// Local-language strings never enter Qwen. Math / LaTeX / chemistry skip
/// AfriSLM. Separate GGUF instances overlap Qwen decode with outbound
/// translation. A shared engine stays sequential to avoid a nested lock.
class ChatInferencePipeline {
  ChatInferencePipeline({
    required this.reasoner,
    required this.tutor,
    this.translator,
    this.loadProgrammingEngine,
  });

  final QwenReasoningService reasoner;
  final TutorPipeline tutor;
  final AfriSlmTranslationService? translator;
  final Future<InferenceEngine?> Function()? loadProgrammingEngine;

  /// Sticky: once a Learn subject is programming, stay on the 1.5B brain.
  bool preferProgramming = false;

  TutorPipeline? _programmingTutor;
  QwenReasoningService? _programmingReasoner;
  bool _programmingThread = false;

  bool get canOverlapNative {
    final t = translator?.engine;
    if (t == null || identical(t, reasoner.engine)) return false;
    // LiteRT + AfriSLM on phones must stay sequential (4 GB RAM). Only
    // dual llama.cpp instances safely overlap decode.
    return reasoner.engine is LlamaCppEngineImpl && t is LlamaCppEngineImpl;
  }

  void reset() {
    preferProgramming = false;
    _programmingThread = false;
    tutor.reset();
    _programmingTutor?.reset();
    unawaited(reasoner.resetSession());
    unawaited(_programmingReasoner?.resetSession() ?? Future<void>.value());
  }

  Future<(TutorPipeline, QwenReasoningService)> _brainFor(
    String englishUser,
    String userText,
  ) async {
    final wants =
        preferProgramming ||
        _programmingThread ||
        looksLikeProgramming(englishUser) ||
        looksLikeProgramming(userText);
    if (!wants || loadProgrammingEngine == null) {
      return (tutor, reasoner);
    }
    try {
      final engine = await loadProgrammingEngine!();
      if (engine == null) return (tutor, reasoner);
      final isNew = _programmingTutor == null;
      _programmingTutor ??= TutorPipeline(
        engine: engine,
        curriculum: tutor.curriculum,
        systemPrompt: kProgrammingTutorContract,
        maxTokens: kProgrammingMaxTokens,
        codingCoach: true,
        teacherNotes: tutor.teacherNotes,
      );
      if (isNew) {
        await _programmingTutor!.restoreSession(
          memory: tutor.memorySnapshot(),
          topic: tutor.currentTopic,
          nextStage: tutor.nextStage,
        );
      }
      _programmingReasoner ??= QwenReasoningService(engine);
      _programmingThread = true;
      return (_programmingTutor!, _programmingReasoner!);
    } catch (e) {
      debugPrint('Programming tutor setup failed, using the general tutor: $e');
      return (tutor, reasoner);
    }
  }

  /// Cumulative localized display text for [StreamBuilder].
  Stream<String> runTurn({
    required String userText,
    required String languageCode,
    bool useCurriculum = true,
    String? safetyNote,
    void Function(String cumulative)? onUiToken,
  }) {
    final controller = StreamController<String>();
    unawaited(() async {
      try {
        final turn = await completeTurn(
          userText: userText,
          languageCode: languageCode,
          useCurriculum: useCurriculum,
          safetyNote: safetyNote,
          onUiToken: (c) {
            onUiToken?.call(c);
            if (!controller.isClosed) controller.add(c);
          },
        );
        if (!controller.isClosed) controller.add(turn.displayText);
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      } finally {
        if (!controller.isClosed) await controller.close();
      }
    }());
    return controller.stream;
  }

  Future<ChatPipelineTurn> completeTurn({
    required String userText,
    required String languageCode,
    bool useCurriculum = true,
    String? safetyNote,
    String? pretranslatedEnglish,
    void Function(String cumulative)? onUiToken,
  }) async {
    final skipInbound =
        pretranslatedEnglish != null ||
        languageCode == 'en' ||
        isMathPassThrough(userText) ||
        queryLooksLikeMath(userText) ||
        toEnglishFollowUp(userText, langCode: languageCode) != null ||
        looksLikeEnglish(userText);

    final ingest = EnglishIngestBuffer();
    Future<TranslationOutcome>? inboundFuture;
    if (pretranslatedEnglish != null) {
      ingest
        ..add(pretranslatedEnglish)
        ..close();
    } else if (!skipInbound && translator != null && translator!.isAvailable) {
      final pending = translator!.toEnglishDetailed(
        userText,
        languageCode,
        onToken: ingest.add,
      );
      inboundFuture = pending;
      unawaited(pending.whenComplete(ingest.close));
    } else {
      ingest
        ..add(toEnglishFollowUp(userText, langCode: languageCode) ?? userText)
        ..close();
    }

    final early = await ingest.waitForReasoningPrompt();
    if (!ingest.isClosed) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }

    var englishUser = ingest.snapshot.trim();
    if (englishUser.isEmpty) englishUser = early.trim();
    if (englishUser.isEmpty) englishUser = userText;

    if (inboundFuture != null && !canOverlapNative) {
      final outcome = await inboundFuture;
      if (outcome.translated && outcome.text.trim().isNotEmpty) {
        englishUser = outcome.text.trim();
      }
    }

    final (activeTutor, activeReasoner) = await _brainFor(
      englishUser,
      userText,
    );

    final overlapOutbound =
        languageCode != 'en' && translator != null && canOverlapNative;

    final englishCtrl = StreamController<String>();
    final rawUi = StringBuffer();
    final ui = StringBuffer();
    void pushUi(String chunk) {
      final next = joinCascade(rawUi.toString(), chunk);
      rawUi
        ..clear()
        ..write(next);
      final cleaned = sanitizeLLMResponse(next);
      ui
        ..clear()
        ..write(cleaned);
      onUiToken?.call(ui.toString());
    }

    final queued = <String>[];
    var translateFree =
        skipInbound || inboundFuture == null || !canOverlapNative;

    final uiDone = Completer<void>();
    late final StreamSubscription<String> uiSub;
    void onUiDone() {
      if (!uiDone.isCompleted) uiDone.complete();
    }

    if (languageCode == 'en' || translator == null) {
      uiSub = englishCtrl.stream.listen(
        pushUi,
        onDone: onUiDone,
        onError: (Object e, StackTrace st) {
          if (!uiDone.isCompleted) uiDone.completeError(e, st);
        },
      );
    } else if (overlapOutbound) {
      uiSub = _outboundUiStream(englishCtrl.stream, languageCode).listen(
        pushUi,
        onDone: onUiDone,
        onError: (Object e, StackTrace st) {
          if (!uiDone.isCompleted) uiDone.completeError(e, st);
        },
      );
    } else {
      uiSub = englishCtrl.stream.listen(
        (_) {},
        onDone: onUiDone,
        onError: (Object e, StackTrace st) {
          if (!uiDone.isCompleted) uiDone.completeError(e, st);
        },
      );
    }

    TutorResponse? response;
    Object? error;
    StackTrace? errorSt;
    try {
      final qwen = activeTutor.respond(
        studentMessage: englishUser,
        safetyNote: safetyNote,
        languageCode: 'en',
        useCurriculum: useCurriculum && !queryLooksLikeMath(englishUser),
        onToken: (token) async {
          if (!translateFree) {
            queued.add(token);
            return;
          }
          if (!englishCtrl.isClosed) englishCtrl.add(token);
        },
      );

      if (inboundFuture != null && canOverlapNative) {
        final outcome = await inboundFuture;
        if (outcome.translated && outcome.text.trim().isNotEmpty) {
          // Inbound finished; Qwen already started on [englishUser].
        }
        translateFree = true;
        for (final token in queued) {
          if (!englishCtrl.isClosed) englishCtrl.add(token);
        }
        queued.clear();
      }

      response = await qwen;
    } catch (e, st) {
      error = e;
      errorSt = st;
    } finally {
      if (!englishCtrl.isClosed) await englishCtrl.close();
      try {
        await uiDone.future;
      } catch (_) {}
      await uiSub.cancel();
    }
    if (error != null) {
      debugPrint('ChatInferencePipeline turn failed: $error\n$errorSt');
      const fallback =
          'I hit a brief snag finishing that answer. Please ask again in one short sentence.';
      final display = ui.toString().trim().isNotEmpty
          ? sanitizeLLMResponse(ui.toString()).trim()
          : fallback;
      if (display == fallback) onUiToken?.call(fallback);
      return ChatPipelineTurn(
        response: TutorResponse(
          stage: TutorStage.answer,
          text: display,
          followUpPrompt: '',
          topic: '',
        ),
        displayText: display,
        englishUser: englishUser,
        translationFailure: 'generation interrupted',
      );
    }
    final done = response!;

    var display = ui.toString();
    String? translatedLanguage;
    String? translationFailure;

    if (languageCode != 'en' &&
        translator != null &&
        !overlapOutbound &&
        done.math == null) {
      display = '';
      await for (final chunk in _outboundUiStream(
        Stream<String>.fromIterable(
          done.text.isEmpty ? const <String>[] : [done.text],
        ),
        languageCode,
      )) {
        display = joinCascade(display, chunk);
        onUiToken?.call(display);
      }
      if (display.trim().isNotEmpty) translatedLanguage = languageCode;
    } else if (languageCode == 'en') {
      if (display.trim().isEmpty) display = done.text;
    } else if (translator == null) {
      if (display.trim().isEmpty) display = done.text;
      translationFailure = 'translation model unavailable';
    } else if (display.trim().isNotEmpty) {
      // Overlap path: rejected AfriSLM falls back to English source text.
      // Do not mark that as a successful local-language translation.
      if (display.trim() == done.text.trim()) {
        translationFailure = 'translation failed';
      } else {
        translatedLanguage = languageCode;
      }
    } else if (done.text.trim().isNotEmpty && done.math == null) {
      display = done.text;
      translationFailure = 'translation failed';
    }

    activeReasoner.rememberEnglish(user: englishUser, assistant: done.text);

    return ChatPipelineTurn(
      response: done,
      displayText: sanitizeLLMResponse(
        display.trim().isEmpty ? done.text : display,
      ),
      englishUser: englishUser,
      translatedLanguage: translatedLanguage,
      translationFailure: translationFailure,
    );
  }

  Stream<String> _outboundUiStream(
    Stream<String> englishTokens,
    String languageCode,
  ) async* {
    await for (final span in englishTokens.transform(
      const FormulaBypassTransformer(),
    )) {
      if (span.bypassTranslation || span.text.trim().isEmpty) {
        yield span.text;
        await yieldToEventLoop();
        continue;
      }
      await for (final local in translator!.streamToLocal(
        span.text,
        languageCode,
      )) {
        yield local;
        await yieldToEventLoop();
      }
    }
  }
}
