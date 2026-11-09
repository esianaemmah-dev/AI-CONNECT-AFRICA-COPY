import 'dart:convert';

import 'package:flutter/services.dart';

/// Bundled, immutable draft pack. A field record always pins its version.
class GalsPack {
  GalsPack._(
    this.id,
    this.version,
    this.status,
    this.language,
    this.lessons,
    this.tools,
  );

  final String id;
  final String version;
  final String status;
  final String language;
  final List<GalsLesson> lessons;
  final List<GalsTool> tools;

  static const asset = 'assets/gals/packs/gals-foundation-v1.json';

  static Future<GalsPack> load() async => fromJson(
    jsonDecode(await rootBundle.loadString(asset)) as Map<String, dynamic>,
  );

  static GalsPack fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1 ||
        !{'draft', 'approved'}.contains(json['status'])) {
      throw const FormatException('Unsupported GALS pack schema or status');
    }
    final id = json['packId'] as String;
    final version = json['contentVersion'] as String;
    final language = json['defaultLanguage'] as String;
    final languages = json['languages'] as Map<String, dynamic>;
    final sources = json['sources'] as List;
    if (id.isEmpty || version.isEmpty || !languages.containsKey(language)) {
      throw const FormatException('Invalid GALS pack identity or language');
    }
    if (sources.isEmpty ||
        sources.any(
          (s) =>
              (s as Map<String, dynamic>)['name'] == null || s['url'] == null,
        )) {
      throw const FormatException('GALS pack requires source credits');
    }
    final lessons = (json['lessons'] as List).map((raw) {
      final item = raw as Map<String, dynamic>;
      final quiz = (item['quiz'] as List).map((raw) {
        final q = raw as Map<String, dynamic>;
        final choices =
            (q['choices'] as Map<String, dynamic>)[language] as List;
        final correct = q['correct'] as int;
        if (choices.length < 2 || correct < 0 || correct >= choices.length) {
          throw const FormatException('Invalid GALS quiz answer');
        }
        return GalsQuizQuestion(
          q['id'] as String,
          (q['question'] as Map<String, dynamic>)[language] as String,
          choices.cast<String>(),
          correct,
          (q['explanation'] as Map<String, dynamic>)[language] as String,
        );
      }).toList();
      return GalsLesson(
        item['id'] as String,
        (item['title'] as Map<String, dynamic>)[language] as String,
        (item['body'] as Map<String, dynamic>)[language] as String,
        quiz,
      );
    }).toList();
    final tools = (json['tools'] as List).map((raw) {
      final tool = raw as Map<String, dynamic>;
      final steps = (tool['steps'] as List).map((raw) {
        final step = raw as Map<String, dynamic>;
        final audio = step['audio'] as Map<String, dynamic>;
        final clip = audio[language];
        final reviewed =
            clip is Map<String, dynamic> &&
            clip['status'] == 'native_reviewed' &&
            (languages[language] as Map<String, dynamic>)['status'] ==
                'native_reviewed' &&
            clip['path'] is String &&
            RegExp(r'^[0-9a-f]{64}$').hasMatch('${clip['sha256']}') &&
            clip['durationSeconds'] is num;
        return GalsStep(
          step['id'] as String,
          (step['instruction'] as Map<String, dynamic>)[language] as String,
          reviewed,
        );
      }).toList();
      return GalsTool(
        tool['id'] as String,
        (tool['title'] as Map<String, dynamic>)[language] as String,
        steps,
      );
    }).toList();
    if (tools.map((t) => t.id).toSet().length != tools.length ||
        tools.any(
          (t) =>
              t.id.isEmpty ||
              t.steps.isEmpty ||
              t.steps.map((s) => s.id).toSet().length != t.steps.length,
        )) {
      throw const FormatException('Invalid or repeated GALS tool IDs');
    }
    return GalsPack._(
      id,
      version,
      json['status'] as String,
      language,
      lessons,
      tools,
    );
  }

  GalsTool? tool(String toolId) {
    for (final candidate in tools) {
      if (candidate.id == toolId) return candidate;
    }
    return null;
  }
}

class GalsLesson {
  const GalsLesson(this.id, this.title, this.body, this.quiz);
  final String id;
  final String title;
  final String body;
  final List<GalsQuizQuestion> quiz;
}

class GalsQuizQuestion {
  const GalsQuizQuestion(
    this.id,
    this.question,
    this.choices,
    this.correct,
    this.explanation,
  );
  final String id;
  final String question;
  final List<String> choices;
  final int correct;
  final String explanation;
}

class GalsTool {
  const GalsTool(this.id, this.title, this.steps);
  final String id;
  final String title;
  final List<GalsStep> steps;
}

class GalsStep {
  const GalsStep(this.id, this.instruction, this.hasAudio);
  final String id;
  final String instruction;
  final bool hasAudio;
}
