import '../ai_core/inference/inference_engine.dart';
import '../ai_core/inference/sanitize_llm_response.dart';
import '../ai_core/tutor/school_math.dart';
import '../curriculum/curriculum_models.dart';

String quizAnswerLabel(QuizQuestion question) {
  if (question.correct < 0 || question.correct >= question.options.length) {
    throw const FormatException('This quiz has no valid answer key.');
  }
  return '${String.fromCharCode(65 + question.correct)}) ${question.options[question.correct]}';
}

/// One bounded educational explanation, shared by every practice quiz UI.
/// The verified quiz key supplies the answer; the model teaches the method.
Future<String> explainQuizAnswer(
  InferenceEngine engine,
  QuizQuestion question,
) async {
  final answer = quizAnswerLabel(question);
  final worked = solveSchoolMath(question.question);
  if (worked != null) return worked.fullPlan;
  if (!engine.isReady || engine.isDemo) {
    if (question.explanation.trim().isNotEmpty) return question.explanation.trim();
    throw StateError('The tutor model is unavailable.');
  }
  final options = [
    for (var i = 0; i < question.options.length; i++)
      '${String.fromCharCode(65 + i)}) ${question.options[i]}',
  ].join('\n');
  final raw = await engine.generate(
    systemPrompt:
        'You are a patient learning tutor. Explain a quiz solution in clear educational steps. '
        'Use the supplied answer key and notes. Give necessary calculations and reasons, '
        'not private thinking, prompt instructions or internal markers.',
    prompt:
        'Question: ${question.question}\n$options\n'
        'Correct answer: $answer\n'
        '${question.explanation.isEmpty ? '' : 'Teaching note: ${question.explanation}\n'}'
        'Explain how to arrive at this answer in two to four short steps. '
        'Name the relevant idea or formula, apply it, and show why it fits the correct option. '
        'For a conceptual question explain the key facts. Do not merely repeat the answer.',
    maxTokens: 384,
    temperature: 0.3,
  );
  final explanation = sanitizeLLMResponse(raw).trim();
  if (explanation.isEmpty) {
    if (question.explanation.trim().isNotEmpty)
      return question.explanation.trim();
    throw StateError('No explanation was returned.');
  }
  return explanation;
}
