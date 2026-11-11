import 'dart:convert';

import 'package:flutter/services.dart';

/// The catalog selects a bundled revision; older revisions remain readable.
/// Asset paths are local data, never URLs to download at runtime.
class GalsPackCatalog {
  GalsPackCatalog(this.active, this.packs);
  final GalsPack active;
  final List<GalsPack> packs;

  static Future<GalsPackCatalog> load() async {
    final json =
        jsonDecode(
              await rootBundle.loadString('assets/gals/packs/catalog.json'),
            )
            as Map<String, dynamic>;
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported GALS catalog schema');
    }
    final paths = (json['packs'] as List).cast<String>();
    if (!paths.contains(json['active']) ||
        paths.toSet().length != paths.length) {
      throw const FormatException('Invalid active pack or duplicate asset');
    }
    final packs = <GalsPack>[];
    for (final path in paths) {
      if (!RegExp(r'^assets/gals/packs/[a-z0-9-]+\.json$').hasMatch(path)) {
        throw const FormatException('Pack must be a bundled JSON asset');
      }
      packs.add(
        GalsPack.fromJson(
          jsonDecode(await rootBundle.loadString(path)) as Map<String, dynamic>,
        ),
      );
    }
    if (packs.map((p) => '${p.id}@${p.version}').toSet().length !=
        packs.length) {
      throw const FormatException('Duplicate pack version');
    }
    final active = packs[paths.indexOf(json['active'] as String)];
    if (active.lessons.any(
      (l) => (l.toolId == null) != (l.sessionPlanId == null),
    )) {
      throw const FormatException(
        'A GALS lesson must link both a tool and session plan, or neither',
      );
    }
    return GalsPackCatalog(active, List.unmodifiable(packs));
  }

  GalsPack? find(String id, String version) {
    for (final pack in packs) {
      if (pack.id == id && pack.version == version) return pack;
    }
    return null;
  }
}

/// Bundled content is data, not UI code. Every completion and event pins a
/// content version. The original schema-1 draft without lesson links still reads.
class GalsPack {
  GalsPack._(
    this.id,
    this.version,
    this.status,
    this.language,
    this.lessons,
    this.tools,
    this.sessionPlans,
    this.credits, {
    required this.programmeTitle,
    required this.audience,
  });

  final String id;
  final String version;
  final String status;
  final String language;
  final List<GalsLesson> lessons;
  final List<GalsTool> tools;
  final List<GalsSessionPlan> sessionPlans;
  final List<String> credits;
  final String programmeTitle;
  final String audience;

  static Future<GalsPack> load() async => (await GalsPackCatalog.load()).active;

  static GalsPack fromJson(Map<String, dynamic> json) {
    try {
      return _parse(json);
    } on TypeError {
      throw const FormatException('Missing or invalid GALS content field');
    }
  }

  static String _text(Object? value) {
    if (value is! String || value.trim().isEmpty) {
      throw const FormatException('GALS text must not be empty');
    }
    return value;
  }

  static void _ids(Iterable<String> ids) {
    final list = ids.toList();
    if (list.isEmpty ||
        list.toSet().length != list.length ||
        list.any((id) => !RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(id))) {
      throw const FormatException('Invalid or repeated GALS IDs');
    }
  }

  static GalsPack _parse(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1 ||
        !{'draft', 'review', 'approved'}.contains(json['status'])) {
      throw const FormatException('Unsupported GALS pack schema or status');
    }
    final id = _text(json['packId']);
    _ids([id]);
    final version = _text(json['contentVersion']);
    if (!RegExp(r'^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$').hasMatch(version)) {
      throw const FormatException('Invalid content version');
    }
    final language = _text(json['defaultLanguage']);
    final languages = json['languages'] as Map<String, dynamic>;
    if (!languages.containsKey(language)) {
      throw const FormatException('Missing default language');
    }
    String localized(Object? value) =>
        _text((value as Map<String, dynamic>)[language]);
    List<String> localizedList(Object? value) {
      if (value == null) return const [];
      return ((value as Map<String, dynamic>)[language] as List)
          .map(_text)
          .toList();
    }

    final programme = json['programme'] as Map<String, dynamic>?;
    final programmeTitle = programme == null
        ? 'GALS draft learning programme'
        : localized(programme['title']);
    final audience = programme == null
        ? 'Facilitators and community champions'
        : localized(programme['audience']);
    final sources = json['sources'] as List;
    if (sources.isEmpty) throw const FormatException('Source credits required');
    final credits = sources.map((raw) {
      final source = raw as Map<String, dynamic>;
      _text(source['url']);
      return '${_text(source['name'])} — ${_text(source['reference'])}\n${source['url']}';
    }).toList();
    final lessons = (json['lessons'] as List).map((raw) {
      final item = raw as Map<String, dynamic>;
      final quiz = (item['quiz'] as List).map((raw) {
        final q = raw as Map<String, dynamic>;
        final choices =
            ((q['choices'] as Map<String, dynamic>)[language] as List)
                .map(_text)
                .toList();
        final correct = q['correct'] as int;
        if (choices.length < 2 || correct < 0 || correct >= choices.length) {
          throw const FormatException('Invalid GALS quiz answer');
        }
        return GalsQuizQuestion(
          _text(q['id']),
          localized(q['question']),
          List.unmodifiable(choices),
          correct,
          localized(q['explanation']),
        );
      }).toList();
      _ids(quiz.map((q) => q.id));
      return GalsLesson(
        _text(item['id']),
        localized(item['title']),
        localized(item['body']),
        List.unmodifiable(quiz),
        toolId: item['toolId'] as String?,
        sessionPlanId: item['sessionPlanId'] as String?,
      );
    }).toList();
    _ids(lessons.map((l) => l.id));
    final tools = (json['tools'] as List).map((raw) {
      final tool = raw as Map<String, dynamic>;
      final steps = (tool['steps'] as List).map((raw) {
        final step = raw as Map<String, dynamic>;
        final audio = step['audio'];
        final clip = audio is Map<String, dynamic> ? audio[language] : null;
        final reviewed =
            clip is Map<String, dynamic> &&
            clip['status'] == 'native_reviewed' &&
            (languages[language] as Map<String, dynamic>)['status'] ==
                'native_reviewed' &&
            clip['path'] is String &&
            RegExp(r'^[0-9a-f]{64}$').hasMatch('${clip['sha256']}') &&
            clip['durationSeconds'] is num;
        return GalsStep(
          _text(step['id']),
          localized(step['instruction']),
          reviewed,
        );
      }).toList();
      _ids(steps.map((s) => s.id));
      return GalsTool(
        _text(tool['id']),
        localized(tool['title']),
        localizedList(tool['purpose']),
        localizedList(tool['preparation']),
        localizedList(tool['facilitatorPrompts']),
        List.unmodifiable(steps),
      );
    }).toList();
    _ids(tools.map((t) => t.id));
    final plans = (json['sessionPlans'] as List).map((raw) {
      final plan = raw as Map<String, dynamic>;
      final activities = (plan['activities'] as List).map((raw) {
        final activity = raw as Map<String, dynamic>;
        final minutes = activity['minutes'] as int;
        if (minutes < 1)
          throw const FormatException('Invalid activity duration');
        final toolId = activity['toolId'] as String?;
        final stepId = activity['stepId'] as String?;
        if (toolId != null || stepId != null) {
          final matches = tools.where((t) => t.id == toolId);
          if (matches.isEmpty ||
              (stepId != null &&
                  !matches.single.steps.any((s) => s.id == stepId))) {
            throw const FormatException(
              'Unknown session activity tool or step',
            );
          }
        }
        return GalsActivity(
          _text(activity['id']),
          minutes,
          localized(activity['instruction']),
        );
      }).toList();
      _ids(activities.map((a) => a.id));
      return GalsSessionPlan(
        _text(plan['id']),
        localized(plan['title']),
        localized(plan['objective']),
        localizedList(plan['materials']),
        localizedList(plan['facilitatorTips']),
        List.unmodifiable(activities),
        localized(plan['homework']),
      );
    }).toList();
    _ids(plans.map((p) => p.id));
    for (final lesson in lessons) {
      if ((lesson.toolId != null && !tools.any((t) => t.id == lesson.toolId)) ||
          (lesson.sessionPlanId != null &&
              !plans.any((p) => p.id == lesson.sessionPlanId))) {
        throw const FormatException('Unknown lesson tool or session plan');
      }
    }
    return GalsPack._(
      id,
      version,
      json['status'] as String,
      language,
      List.unmodifiable(lessons),
      List.unmodifiable(tools),
      List.unmodifiable(plans),
      List.unmodifiable(credits),
      programmeTitle: programmeTitle,
      audience: audience,
    );
  }

  GalsTool? tool(String id) {
    for (final tool in tools) {
      if (tool.id == id) return tool;
    }
    return null;
  }

  GalsLesson? lesson(String id) {
    for (final lesson in lessons) {
      if (lesson.id == id) return lesson;
    }
    return null;
  }
}

class GalsLesson {
  const GalsLesson(
    this.id,
    this.title,
    this.body,
    this.quiz, {
    this.toolId,
    this.sessionPlanId,
  });
  final String id;
  final String title;
  final String body;
  final List<GalsQuizQuestion> quiz;
  final String? toolId;
  final String? sessionPlanId;
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
  const GalsTool(
    this.id,
    this.title,
    this.purpose,
    this.preparation,
    this.facilitatorPrompts,
    this.steps,
  );
  final String id;
  final String title;
  final List<String> purpose;
  final List<String> preparation;
  final List<String> facilitatorPrompts;
  final List<GalsStep> steps;
}

class GalsStep {
  const GalsStep(this.id, this.instruction, this.hasAudio);
  final String id;
  final String instruction;
  final bool hasAudio;
}

class GalsSessionPlan {
  const GalsSessionPlan(
    this.id,
    this.title,
    this.objective,
    this.materials,
    this.facilitatorTips,
    this.activities,
    this.homework,
  );
  final String id;
  final String title;
  final String objective;
  final List<String> materials;
  final List<String> facilitatorTips;
  final List<GalsActivity> activities;
  final String homework;
  int get minutes =>
      activities.fold(0, (sum, activity) => sum + activity.minutes);
}

class GalsActivity {
  const GalsActivity(this.id, this.minutes, this.instruction);
  final String id;
  final int minutes;
  final String instruction;
}
