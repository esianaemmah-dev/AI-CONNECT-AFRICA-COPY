import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai_core/providers/ai_provider.dart';
import '../../l10n/language_provider.dart';
import '../../ai_core/tutor/school_math.dart';
import '../../ai_core/tutor/school_math_l10n.dart';
import '../../services/quiz_answer_service.dart';
import '../../core/theme/app_colors.dart';
import '../../curriculum/curriculum_models.dart';
import '../../l10n/app_locale.dart';
import 'worked_solution.dart';

/// Button on a quiz question that streams a worked solution (steps + calculations).
class QuizAiAnswer extends ConsumerStatefulWidget {
  const QuizAiAnswer({super.key, required this.question});

  final QuizQuestion question;

  @override
  ConsumerState<QuizAiAnswer> createState() => _QuizAiAnswerState();
}

class _QuizAiAnswerState extends ConsumerState<QuizAiAnswer> {
  bool _busy = false;
  String _text = '';
  String? _error;
  SchoolMathSolution? _math;

  Future<void> _run() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _text = '';
      _error = null;
      _math = null;
    });
    try {
      final q = widget.question;
      quizAnswerLabel(q);
      final solved = solveSchoolMath(
        q.question,
      );
      if (solved != null) {
        final lang = ref.read(appLanguageProvider);
        var shown = solved;
        if (lang != 'en') {
          final pipeline = await ref.read(translationPipelineProvider.future);
          if (pipeline != null) {
            shown = await localizeSchoolMath(
              solved,
              translate: (english) => pipeline.fromEnglish(english, lang),
            );
          }
        }
        if (mounted) setState(() => _math = shown);
        return;
      }
      final engine = await ref.read(engineLoadedProvider.future);
      final english = await explainQuizAnswer(engine, q);
      var shown = english;
      final lang = ref.read(appLanguageProvider);
      if (lang != 'en') {
        final translator = await ref.read(translationPipelineProvider.future);
        if (translator != null) shown = await translator.fromEnglish(english, lang);
      }
      if (mounted) setState(() => _text = shown);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not get a worked solution. Try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final chatBusy = ref.watch(chatProvider.select((chat) => chat.valueOrNull?.isGenerating ?? false));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _busy || chatBusy ? null : _run,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome, size: 18),
          label: Text(tr(context, 'Answer with AI')),
        ),
        if (_math != null || _text.isNotEmpty || _error != null) ...[
          const SizedBox(height: 10),
          if (_error == null) Text('${tr(context, 'Correct answer')}: ${quizAnswerLabel(widget.question)}',
            style: const TextStyle(fontWeight: FontWeight.w600)),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
            ),
            child: _error != null
                ? Text(
                    _error!,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: Colors.red,
                    ),
                  )
                : _math != null
                    ? WorkedSolutionView(solution: _math!, compact: true)
                    : Text(
                        _text,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: cs.onSurface,
                        ),
                      ),
          ),
        ],
      ],
    );
  }
}
