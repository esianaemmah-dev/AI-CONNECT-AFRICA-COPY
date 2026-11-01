import '../inference/sanitize_llm_response.dart';
import '../translate/follow_up_glossary.dart';

/// Compressed English chat memory for the tutor prompt (Learn chat).
///
/// Design goals:
/// - Continuity across turns without blowing llama.cpp `n_batch`
/// - Multilingual short follow-ups stay on the last question
/// - Never store local-language student UI text or full transcripts
/// - Reject empty / error / "snag" tutor replies so they do not poison THREAD
/// - Always produce a bounded [promptBlock] even under adversarial growth
class ConversationMemory {
  ConversationMemory({
    this.maxRawTurns = 6,
    this.maxFacts = 6,
    this.turnClipChars = 180,
    this.factClipChars = 90,
    this.digestClipChars = 280,
    this.anchorClipChars = 240,
    this.maxSlots = 4,
    this.maxEntities = 6,
    this.maxUnresolved = 2,
    this.stateClipChars = 60,
  }) : assert(maxRawTurns >= 2 && maxRawTurns.isEven);

  /// Raw Student/Tutor lines kept verbatim (always an even count).
  final int maxRawTurns;
  final int maxFacts;
  final int turnClipChars;
  final int factClipChars;
  final int digestClipChars;
  final int anchorClipChars;
  final int maxSlots;
  final int maxEntities;
  final int maxUnresolved;

  /// Clip for each topic / intent / slot value / entity.
  final int stateClipChars;

  /// Rolling one-line digest of older exchanges folded out of [turns].
  String? lessonDigest;

  /// Last substantive student question (for follow-up resolution).
  String? anchorQuestion;

  // Active conversation state used to resolve follow-ups. Every collection is
  // capped (oldest dropped) so the recall file stays bounded.
  String? activeTopic;
  String? activeIntent;
  final Map<String, String> activeSlots = {};
  final List<String> activeEntities = [];
  final List<String> unresolvedQuestions = [];

  final List<({String role, String text})> turns = [];
  final List<String> established = [];

  bool get isEmpty =>
      turns.isEmpty &&
      established.isEmpty &&
      (lessonDigest == null || lessonDigest!.isEmpty);

  int get exchangeCount => turns.length ~/ 2;

  /// A new subject changes grounding, not the conversation the learner sees.
  void beginTopic(String topic) {
    established.clear();
    anchorQuestion = null;
    activeTopic = topic.isEmpty ? null : _clip(topic, stateClipChars);
    activeIntent = null;
    activeSlots.clear();
    activeEntities.clear();
    unresolvedQuestions.clear();
  }

  void clear() {
    turns.clear();
    established.clear();
    lessonDigest = null;
    anchorQuestion = null;

    activeTopic = null;
    activeIntent = null;
    activeSlots.clear();
    activeEntities.clear();
    unresolvedQuestions.clear();
  }

  /// Record one English exchange. Returns `false` when the write was rejected
  /// (empty student, transient tutor failure, etc.) so callers can skip stage
  /// side-effects if needed.
  bool remember({
    required String student,
    required String tutor,
    List<String> verified = const [],
    String? languageCode,
    String? topic,
    String? intent,
    Map<String, String> slots = const {},
    List<String> entities = const [],
  }) {
    final studentClean = _cleanStudent(student, languageCode: languageCode);
    final tutorClean = _cleanTutor(tutor);
    if (studentClean.isEmpty) return false;
    if (tutorClean == null) return false;

    if (_isSubstantiveStudent(studentClean)) {
      anchorQuestion = _clip(studentClean, anchorClipChars);
    }

    turns.add((role: 'student', text: _clip(studentClean, turnClipChars)));
    turns.add((role: 'tutor', text: _clip(tutorClean, turnClipChars)));

    // Applied on every accepted turn, not only substantive ones: a short
    // correction ("in cm") is exactly what sets a slot.
    _mergeActiveState(
      topic: topic,
      intent: intent,
      slots: slots,
      entities: entities,
    );
    _mergeFacts(verified);
    _foldOverflow();
    return true;
  }

  /// A supplied topic or intent replaces the current one. Slots merge by key
  /// (a corrected value overwrites the old one); entities are deduped.
  void _mergeActiveState({
    String? topic,
    String? intent,
    Map<String, String> slots = const {},
    List<String> entities = const [],
  }) {
    final t = topic?.trim() ?? '';
    if (t.isNotEmpty) activeTopic = _clip(t, stateClipChars);
    final i = intent?.trim() ?? '';
    if (i.isNotEmpty) activeIntent = _clip(i, stateClipChars);

    for (final entry in slots.entries) {
      final key = _clip(entry.key.trim(), stateClipChars);
      final value = _clip(entry.value.trim(), stateClipChars);
      if (key.isEmpty || value.isEmpty) continue;
      // Re-insert so the newest slot is last and survives the cap.
      activeSlots.remove(key);
      activeSlots[key] = value;
    }
    while (activeSlots.length > maxSlots) {
      activeSlots.remove(activeSlots.keys.first);
    }

    for (final raw in entities) {
      final value = _clip(raw.trim(), stateClipChars);
      if (value.isEmpty) continue;
      activeEntities.remove(value);
      activeEntities.add(value);
    }
    if (activeEntities.length > maxEntities) {
      activeEntities.removeRange(0, activeEntities.length - maxEntities);
    }
  }

  /// Record a question the tutor hasn't answered yet (newest kept).
  void addUnresolved(String question) {
    final q = _clip(question.trim(), turnClipChars);
    if (q.isEmpty) return;
    unresolvedQuestions.remove(q);
    unresolvedQuestions.add(q);
    if (unresolvedQuestions.length > maxUnresolved) {
      unresolvedQuestions.removeRange(
        0,
        unresolvedQuestions.length - maxUnresolved,
      );
    }
  }

  void _mergeFacts(List<String> verified) {
    for (final raw in verified) {
      final fact = _clip(raw.trim(), factClipChars);
      if (fact.isEmpty) continue;
      final key = _factKey(fact);
      established.removeWhere((e) => _factKey(e) == key);
      established.add(fact);
    }
    if (established.length > maxFacts) {
      established.removeRange(0, established.length - maxFacts);
    }
  }

  static String _factKey(String fact) {
    final i = fact.indexOf(':');
    if (i > 0) return fact.substring(0, i).trim().toLowerCase();
    return fact.toLowerCase();
  }

  void _foldOverflow() {
    while (turns.length > maxRawTurns) {
      final student = turns.removeAt(0).text;
      final tutor = turns.isNotEmpty && turns.first.role == 'tutor'
          ? turns.removeAt(0).text
          : '';
      final bit = tutor.isEmpty
          ? 'Student asked: ${_clip(student, 90)}'
          : 'Student: ${_clip(student, 90)} → Tutor: ${_clip(tutor, 110)}';
      final prev = lessonDigest?.trim();
      final parts = [
        if (prev != null && prev.isNotEmpty) ...prev.split(' | '),
        bit,
      ];
      while (parts.length > 1 && parts.join(' | ').length > digestClipChars) {
        parts.removeAt(0);
      }
      lessonDigest = _clip(parts.join(' | '), digestClipChars);
    }
    // Repair odd length if something went wrong — never ship broken THREAD.
    if (turns.length.isOdd) {
      turns.removeLast();
    }
  }

  static String _cleanStudent(String raw, {String? languageCode}) {
    var t = raw.trim();
    if (t.isEmpty) return '';
    final gloss = toEnglishFollowUp(t, langCode: languageCode);
    if (gloss != null) t = gloss;
    return t.replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Returns cleaned tutor text, or `null` to reject the write.
  static String? _cleanTutor(String raw) {
    final cleaned = sanitizeLLMResponse(raw).trim();
    if (cleaned.isEmpty) return null;
    if (_isTransientFailure(cleaned)) return null;
    return cleaned.replaceAll(RegExp(r'\s+'), ' ');
  }

  static bool _isTransientFailure(String text) {
    final t = text.toLowerCase();
    return t.contains('brief snag') ||
        t.contains('could not finish that answer') ||
        t.contains('ask again in one short sentence') ||
        t.contains('on-device model is unavailable') ||
        t.contains('generation interrupted') ||
        t.startsWith("couldn't get an answer") ||
        t.startsWith('couldn’t get an answer');
  }

  static bool _isSubstantiveStudent(String text) {
    if (text.length <= 12 && !text.contains('?')) return false;
    final gloss = toEnglishFollowUp(text);
    if (gloss != null && gloss == normalizeFollowUp(text)) {
      // Pure follow-up chip — do not replace the anchor.
      if (text.length <= 24) return false;
    }
    return true;
  }

  static String _clip(String text, int max) {
    if (text.length <= max) return text;
    if (max <= 1) return '…';
    return '${text.substring(0, max - 1)}…';
  }

  bool isContinuing(String message, {String? languageCode}) {
    if (turns.isEmpty && (anchorQuestion == null || anchorQuestion!.isEmpty)) {
      return false;
    }
    final gloss = toEnglishFollowUp(message, langCode: languageCode);
    final t = normalizeFollowUp(gloss ?? message);
    if (t.isEmpty) return false;

    if (_continuingPhrases.contains(t)) return true;
    if (RegExp(
          r'\b(earlier|previous|above|second|third|former|latter)\b',
        ).hasMatch(t) ||
        RegExp(r'\b(it|its|this|that|they|them|these|those)\b').hasMatch(t) ||
        t.startsWith('compare ') ||
        t.startsWith('instead ') ||
        t.startsWith('make it ') ||
        t.startsWith('use the ')) {
      return true;
    }
    if (t.startsWith('what about') ||
        t.startsWith('and then') ||
        t.startsWith('tell me more') ||
        t.startsWith('explain') ||
        // "I mean the president of Uganda": a correction of the last ask.
        t.startsWith('i mean') ||
        t.startsWith('i meant') ||
        t.startsWith('no i mean') ||
        t.startsWith('what i mean') ||
        t.startsWith("i don't understand") ||
        t.startsWith('i dont understand')) {
      return true;
    }
    // Very short follow-ups without a new topic question mark.
    if (t.length <= 12 && !t.contains('?')) return true;
    return false;
  }

  static const _continuingPhrases = {
    'yes',
    'yeah',
    'yep',
    'ok',
    'okay',
    'sure',
    'no',
    'why',
    'how',
    'what',
    'more',
    'again',
    'example',
    'an example',
    'explain',
    'explain more',
    'continue',
    'go on',
    'next',
    'and then',
    'what about that',
  };

  bool isCorrection(String message, {String? languageCode}) {
    final gloss = toEnglishFollowUp(message, langCode: languageCode);
    final t = (gloss ?? message).trim().toLowerCase();
    return t.contains("that's wrong") ||
        t.contains('that is wrong') ||
        t.contains('incorrect') ||
        t.contains('not true') ||
        t.startsWith('no,') ||
        t.contains('you are wrong') ||
        t.contains('you got it wrong');
  }

  /// Drops the fact named by [factKey], or the newest fact when no key is
  /// known (the student only said "that's wrong").
  void noteCorrection({String? factKey}) {
    if (factKey != null && factKey.trim().isNotEmpty) {
      invalidateFact(factKey);
    } else if (established.isNotEmpty) {
      established.removeLast();
    }
  }

  void invalidateFact(String key) {
    final normalizedKey = key.trim().toLowerCase();
    if (normalizedKey.isEmpty) return;
    established.removeWhere((fact) => _factKey(fact) == normalizedKey);
  }

  /// Snapshot the whole mutable state so a session can be reopened later.
  ///
  /// Only the already-clipped fields are written — [turns] is capped at
  /// [maxRawTurns] and each entry at [turnClipChars], so this stays a
  /// compressed recall, never a transcript.
  Map<String, Object?> toJson() => {
    'digest': lessonDigest,
    'anchor': anchorQuestion,
    'schemaVersion': 2,
    'activeTopic': activeTopic,
    'activeIntent': activeIntent,
    'activeSlots': Map<String, String>.from(activeSlots),
    'activeEntities': List<String>.from(activeEntities),
    'unresolvedQuestions': List<String>.from(unresolvedQuestions),
    'turns': [
      for (final t in turns) {'role': t.role, 'text': t.text},
    ],
    'facts': List<String>.from(established),
  };

  /// Re-seed from [toJson]. Replaces any current state.
  ///
  /// Tolerates a partially written or hand-edited file: anything of the wrong
  /// shape is skipped rather than throwing, because a damaged recall file
  /// should degrade to a thinner memory, not block reopening the chat.
  void restoreFrom(Map<String, Object?> json) {
    clear();
    final digest = json['digest'];
    if (digest is String && digest.isNotEmpty) {
      lessonDigest = _clip(digest, digestClipChars);
    }
    final anchor = json['anchor'];
    if (anchor is String && anchor.isNotEmpty) {
      anchorQuestion = _clip(anchor, anchorClipChars);
    }
    final rawTurns = json['turns'];
    if (rawTurns is List) {
      for (final entry in rawTurns) {
        if (entry is! Map) continue;
        final role = entry['role'];
        final text = entry['text'];
        if (role is! String || text is! String) continue;
        if (role != 'student' && role != 'tutor') continue;
        if (text.isEmpty) continue;
        turns.add((role: role, text: _clip(text, turnClipChars)));
      }
      // turns must stay an even, bounded Student/Tutor sequence.
      if (turns.isNotEmpty && turns.first.role != 'student') {
        turns.removeAt(0);
      }
      if (turns.length.isOdd) turns.removeLast();
      while (turns.length > maxRawTurns) {
        turns.removeRange(0, 2);
      }
    }
    final facts = json['facts'];
    if (facts is List) {
      for (final f in facts) {
        if (f is! String || f.trim().isEmpty) continue;
        final fact = _clip(f.trim(), factClipChars);
        if (!established.contains(fact)) established.add(fact);
        if (established.length >= maxFacts) break;
      }
    }

    // Active state (schemaVersion 2). Older files have none of these keys.
    // Routed through the same merge as [remember] so caps and clips apply.
    final topic = json['activeTopic'];
    final intent = json['activeIntent'];
    final rawSlots = json['activeSlots'];
    final rawEntities = json['activeEntities'];
    _mergeActiveState(
      topic: topic is String ? topic : null,
      intent: intent is String ? intent : null,
      slots: {
        if (rawSlots is Map)
          for (final entry in rawSlots.entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
      },
      entities: [
        if (rawEntities is List)
          for (final item in rawEntities)
            if (item is String) item,
      ],
    );
    final rawQuestions = json['unresolvedQuestions'];
    if (rawQuestions is List) {
      for (final item in rawQuestions) {
        if (item is String) addUnresolved(item);
      }
    }
  }

  String resolveCurrent(String message, {String? languageCode}) {
    final gloss = toEnglishFollowUp(message, langCode: languageCode);
    final resolvedFollowUp = gloss ?? message.trim();
    if (!isContinuing(message, languageCode: languageCode)) {
      return resolvedFollowUp;
    }
    final anchor = anchorQuestion?.trim();
    if (anchor != null && anchor.isNotEmpty) {
      return '$anchor (follow-up: $resolvedFollowUp)';
    }
    for (final turn in turns.reversed) {
      if (turn.role == 'student') {
        return '${turn.text} (follow-up: $resolvedFollowUp)';
      }
    }
    return resolvedFollowUp;
  }

  /// Prompt fragment for the tutor. When [maxChars] is set, shrinks digest
  /// then oldest THREAD lines, then ESTABLISHED — never throws.
  String promptBlock({int? maxChars}) {
    try {
      return _promptBlockUnsafe(maxChars: maxChars);
    } catch (_) {
      // Absolute last resort — chat must stay up.
      final anchor = anchorQuestion;
      if (anchor == null || anchor.isEmpty) return '';
      return 'THREAD:\nStudent: ${_clip(anchor, 120)}\n';
    }
  }

  String _promptBlockUnsafe({int? maxChars}) {
    if (isEmpty) return '';
    if (maxChars != null && maxChars <= 2) return '';

    final digest = lessonDigest?.trim();
    var threadLines = [
      for (final turn in turns)
        '${turn.role == 'student' ? 'Student' : 'Tutor'}: ${turn.text}',
    ];
    var facts = List<String>.from(established);

    // Optional active-state sections; dropped before THREAD is touched,
    // because THREAD is what keeps follow-ups coherent on a 1.5B model.
    var withUnresolved = true;
    var withEntities = true;
    var withSlots = true;

    String build({
      required String? dig,
      required List<String> lines,
      required List<String> factLines,
    }) {
      final buf = StringBuffer();
      final topic = activeTopic;
      if (topic != null && topic.isNotEmpty) {
        buf.writeln('ACTIVE_TOPIC: $topic');
      }
      final intent = activeIntent;
      if (intent != null && intent.isNotEmpty) {
        buf.writeln('ACTIVE_INTENT: $intent');
      }
      if (withSlots && activeSlots.isNotEmpty) {
        buf.writeln('ACTIVE_CONSTRAINTS:');
        for (final entry in activeSlots.entries) {
          buf.writeln('- ${entry.key}: ${entry.value}');
        }
      }
      if (withEntities && activeEntities.isNotEmpty) {
        buf.writeln('ACTIVE_ENTITIES: ${activeEntities.join(', ')}');
      }
      if (withUnresolved && unresolvedQuestions.isNotEmpty) {
        buf.writeln('UNRESOLVED_QUESTIONS:');
        for (final question in unresolvedQuestions) {
          buf.writeln('- $question');
        }
      }
      if (dig != null && dig.isNotEmpty) {
        buf.writeln('DIGEST: $dig');
      }
      if (lines.isNotEmpty) {
        buf.writeln('THREAD:');
        for (final line in lines) {
          buf.writeln(line);
        }
      }
      if (factLines.isNotEmpty) {
        buf.writeln('ESTABLISHED:');
        for (final fact in factLines) {
          buf.writeln('- $fact');
        }
      }
      return buf.toString();
    }

    var block = build(dig: digest, lines: threadLines, factLines: facts);
    if (maxChars == null || block.length <= maxChars) return block;

    // 0) Drop optional active state, least useful first.
    withUnresolved = false;
    block = build(dig: digest, lines: threadLines, factLines: facts);
    if (block.length <= maxChars) return block;
    withEntities = false;
    block = build(dig: digest, lines: threadLines, factLines: facts);
    if (block.length <= maxChars) return block;
    withSlots = false;
    block = build(dig: digest, lines: threadLines, factLines: facts);
    if (block.length <= maxChars) return block;

    // Compress each recent message before dropping whole exchanges. Keep a
    // small rolling digest so a topic change doesn't hide all earlier asks.
    final compactDigest = digest == null ? null : _clip(digest, 150);
    threadLines = [for (final line in threadLines) _clip(line, 90)];
    block = build(dig: compactDigest, lines: threadLines, factLines: facts);
    if (block.length <= maxChars) return block;

    // 2) Drop oldest THREAD pairs until one exchange remains.
    while (threadLines.length > 2 && block.length > maxChars) {
      threadLines = threadLines.sublist(threadLines.length >= 2 ? 2 : 1);
      block = build(dig: compactDigest, lines: threadLines, factLines: facts);
    }
    if (block.length <= maxChars) return block;

    // 3) Drop facts from the oldest.
    while (facts.isNotEmpty && block.length > maxChars) {
      facts = facts.sublist(1);
      block = build(dig: compactDigest, lines: threadLines, factLines: facts);
    }
    if (block.length <= maxChars) return block;

    // 4) Hard-clip final block, keeping the tail (CURRENT follows this block).
    if (block.length <= maxChars) return block;
    return '…\n${block.substring(block.length - maxChars + 2)}';
  }

  /// Compact view for session analysis / student memory snapshots.
  String analysisTranscript({int maxTurns = 6}) {
    final buf = StringBuffer();
    final dig = lessonDigest?.trim();
    if (dig != null && dig.isNotEmpty) {
      buf.writeln('Earlier: $dig');
    }
    final recent = turns.length > maxTurns
        ? turns.sublist(turns.length - maxTurns)
        : turns;
    for (final t in recent) {
      buf.writeln('${t.role == 'tutor' ? 'Tutor' : 'Student'}: ${t.text}');
    }
    return buf.toString().trim();
  }
}
