import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../curriculum/online_topic_lookup.dart' show WebClip, WebPicture;

/// One earlier message of the chat, for [OnlineTutor.answer].
typedef TutorTurn = ({bool isUser, String text});

/// The online tutor's reply, and what the learner may want next ("Next:
/// Convection (Heat Transfer)", "Quiz me on Conduction"), shown as buttons.
typedef OnlineReply = ({String text, List<String> suggestions});

/// The online tutor: the school's tutor service (`backend/otic_cloud/tutor.py`)
/// answers with Claude when the device can reach it, and the chat answers on
/// the device when it can't.
///
/// - Off by default; a teacher turns it on (Teachers → Online AI tutor). The
///   app holds no API key: the key and the guardrails live on the server.
/// - Only the question, the recent chat and matched lesson text are sent;
///   nothing that names the learner.
/// - Any failure (no connection, server down, no key set, timeout) returns
///   null and the chat carries on offline. After a failure the service is
///   left alone for [retryAfter], so offline answers aren't held up by it.
class OnlineTutor {
  OnlineTutor({
    required this.baseUrl,
    this.accessToken = '',
    http.Client? client,
    // A school hub teaching a whole part of a topic on a laptop takes up to
    // about a minute; a server that is down fails at once.
    this.timeout = const Duration(seconds: 150),
    this.headersTimeout = const Duration(seconds: 15),
    this.chunkTimeout = const Duration(seconds: 45),
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String accessToken;

  /// Whole answer from the JSON endpoint, which replies only when done.
  final Duration timeout;

  /// Streaming: until the server answers at all. A server that is switched
  /// off or out of Wi-Fi range hangs rather than refusing, so without this
  /// the learner waited the whole [timeout] before the on-device tutor
  /// took over.
  final Duration headersTimeout;

  /// Streaming: the longest gap between two pieces of the answer.
  final Duration chunkTimeout;
  final http.Client _client;

  static const retryAfter = Duration(minutes: 1);
  DateTime? _failedAt;

  /// The answer to [message] (from Claude, or the school hub), or null when
  /// the online tutor can't answer.
  Future<OnlineReply?> answer(
    String message, {
    List<TutorTurn> history = const [],
    String? lesson,
    void Function(String)? onText,
  }) async {
    final failed = _failedAt;
    if (failed != null && DateTime.now().difference(failed) < retryAfter) {
      return null;
    }
    final turns = [
      for (final t in history)
        if (t.text.trim().isNotEmpty)
          {
            'role': t.isUser ? 'user' : 'assistant',
            'content': _clip(t.text.trim(), 4000),
          },
    ];
    try {
      if (onText != null) {
        final streamed = await _streamAnswer({
          'message': _clip(message, 2000),
          'history': turns.length > 12 ? turns.sublist(turns.length - 12) : turns,
          if (lesson != null && lesson.trim().isNotEmpty) 'lesson': _clip(lesson, 6000),
        }, onText);
        if (streamed.supported) return streamed.reply;
        // Older hub/provider servers keep working through their JSON endpoint.
      }
      final res = await _client
          .post(
            Uri.parse('${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/v1/tutor/answer'),
            headers: {
              'Content-Type': 'application/json',
              if (accessToken.isNotEmpty) 'X-Otic-Tutor-Token': accessToken,
            },
            body: jsonEncode({
              'message': _clip(message, 2000),
              'history': turns.length > 12 ? turns.sublist(turns.length - 12) : turns,
              if (lesson != null && lesson.trim().isNotEmpty) 'lesson': _clip(lesson, 6000),
            }),
          )
          .timeout(timeout);
      // The hub is healthy but has no content for this question.
      if (res.statusCode == 204) {
        _failedAt = null;
        return null;
      }
      if (res.statusCode != 200) {
        debugPrint('Online tutor unavailable (${res.statusCode}): ${res.body}');
        _failedAt = DateTime.now();
        return null;
      }
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final text = body['text'] as String?;
      _failedAt = null;
      if (text == null || text.trim().isEmpty) return null;
      final suggestions = body['suggestions'];
      return (
        text: text.trim(),
        suggestions: suggestions is List
            ? [for (final s in suggestions.whereType<String>().take(5)) if (s.trim().isNotEmpty) s.trim()]
            : const <String>[],
      );
    } catch (e) {
      debugPrint('Online tutor unreachable: $e');
      onText?.call('');
      _failedAt = DateTime.now();
      return null;
    }
  }

  Future<({bool supported, OnlineReply? reply})> _streamAnswer(
    Map<String, dynamic> body,
    void Function(String) onText,
  ) async {
    final request = http.Request('POST',
      Uri.parse('${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/v1/tutor/answer/stream'))
      ..headers.addAll({
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
        if (accessToken.isNotEmpty) 'X-Otic-Tutor-Token': accessToken,
      })
      ..body = jsonEncode(body);
    final response = await _client.send(request).timeout(headersTimeout);
    if (response.statusCode == 404 || response.statusCode == 405) {
      await response.stream.drain<void>();
      return (supported: false, reply: null);
    }
    if (response.statusCode == 204) {
      await response.stream.drain<void>();
      _failedAt = null;
      return (supported: true, reply: null);
    }
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      _failedAt = DateTime.now();
      return (supported: true, reply: null);
    }
    await for (final line in response.stream.timeout(chunkTimeout)
        .transform(utf8.decoder).transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final event = jsonDecode(line.substring(5).trim()) as Map<String, dynamic>;
      if (event['error'] != null) throw const FormatException('Hub stream interrupted');
      if (event['text'] case final String text) onText(text);
      if (event['done'] case final Map<String, dynamic> completed) {
        final text = completed['text'] as String?;
        if (text == null || text.trim().isEmpty) throw const FormatException('Empty hub answer');
        final suggestions = completed['suggestions'];
        _failedAt = null;
        return (supported: true, reply: (
          text: text.trim(),
          suggestions: suggestions is List
              ? [for (final s in suggestions.whereType<String>().take(5)) if (s.trim().isNotEmpty) s.trim()]
              : const <String>[],
        ));
      }
    }
    throw const FormatException('Hub stream ended before completion');
  }

  /// Pictures of [query] from the school hub's content packs; empty when the
  /// server has none, isn't a hub, or can't be reached.
  Future<List<WebPicture>> pictures(String query) async {
    final items = await _media(query, clips: false);
    return [
      for (final m in items)
        if (m['url'] is String)
          WebPicture(
            url: m['url'] as String,
            caption: m['caption'] as String? ?? '',
            credit: m['credit'] as String? ?? '',
          ),
    ];
  }

  /// Like [pictures], for video clips.
  Future<List<WebClip>> clips(String query) async {
    final items = await _media(query, clips: true);
    return [
      for (final m in items)
        if (m['url'] is String)
          WebClip(
            url: m['url'] as String,
            poster: m['poster'] as String?,
            caption: m['caption'] as String? ?? '',
            credit: m['credit'] as String? ?? '',
            seconds: (m['seconds'] as num?)?.round() ?? 0,
          ),
    ];
  }

  Future<List<Map<String, dynamic>>> _media(String query, {required bool clips}) async {
    final failed = _failedAt;
    if (failed != null && DateTime.now().difference(failed) < retryAfter) {
      return const [];
    }
    try {
      final res = await _client
          .get(
            Uri.parse('${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/v1/hub/pictures').replace(
              queryParameters: {'q': _clip(query, 300), 'clips': '$clips', 'max': '4'},
            ),
            headers: {if (accessToken.isNotEmpty) 'X-Otic-Tutor-Token': accessToken},
          )
          .timeout(const Duration(seconds: 10));
      // A Claude tutor server has no pictures: 404, and nothing to show.
      if (res.statusCode != 200) return const [];
      final items = (jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>)['items'];
      return items is List ? items.whereType<Map<String, dynamic>>().toList() : const [];
    } catch (e) {
      debugPrint('School hub pictures unavailable: $e');
      return const [];
    }
  }

  static String _clip(String text, int max) => text.length > max ? text.substring(0, max) : text;
}

/// The online tutor settings a teacher chose. Off by default.
class OnlineTutorSettings {
  const OnlineTutorSettings({
    this.enabled = false,
    this.url = defaultUrl,
    this.accessToken = '',
  });

  /// The tutor service on this computer — the demo setup. Schools set their
  /// own server's address.
  static const defaultUrl = 'http://127.0.0.1:8787';

  final bool enabled;
  final String url;
  final String accessToken;
}

class OnlineTutorSettingsNotifier extends StateNotifier<OnlineTutorSettings> {
  OnlineTutorSettingsNotifier() : super(const OnlineTutorSettings()) {
    _load();
  }

  static const _enabledKey = 'online_tutor_enabled';
  static const _urlKey = 'online_tutor_url';
  static const _tokenKey = 'online_tutor_token';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = OnlineTutorSettings(
        enabled: prefs.getBool(_enabledKey) ?? false,
        url: prefs.getString(_urlKey) ?? OnlineTutorSettings.defaultUrl,
        accessToken: prefs.getString(_tokenKey) ?? '',
      );
    } catch (_) {}
  }

  Future<void> update({bool? enabled, String? url, String? accessToken}) async {
    state = OnlineTutorSettings(
      enabled: enabled ?? state.enabled,
      url: (url ?? state.url).trim().isEmpty ? OnlineTutorSettings.defaultUrl : (url ?? state.url).trim(),
      accessToken: (accessToken ?? state.accessToken).trim(),
    );
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, state.enabled);
      await prefs.setString(_urlKey, state.url);
      await prefs.setString(_tokenKey, state.accessToken);
    } catch (_) {}
  }
}

final onlineTutorSettingsProvider =
    StateNotifierProvider<OnlineTutorSettingsNotifier, OnlineTutorSettings>(
      (ref) => OnlineTutorSettingsNotifier(),
    );

/// The online tutor, or null while a teacher hasn't switched it on.
final onlineTutorProvider = Provider<OnlineTutor?>((ref) {
  final s = ref.watch(onlineTutorSettingsProvider);
  if (!s.enabled) return null;
  return OnlineTutor(baseUrl: s.url, accessToken: s.accessToken);
});
