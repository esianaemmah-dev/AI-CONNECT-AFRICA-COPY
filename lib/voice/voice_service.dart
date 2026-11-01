import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'voice_locales.dart';
import 'speech_text.dart';

/// Offline-friendly voice I/O using the device's built-in TTS and STT engines.
/// On Android, STT uses on-device recognition when available (no audio stored).
class VoiceService {
  VoiceService();

  final FlutterTts _tts = FlutterTts();
  final SpeechToText _stt = SpeechToText();

  bool _initialized = false;
  bool _sttReady = false;
  String? _speakingText;

  void Function(String? text)? onSpeakingChanged;

  bool get isSpeaking => _speakingText != null;
  String? get speakingText => _speakingText;

  void _setSpeaking(String? text) {
    _speakingText = text;
    onSpeakingChanged?.call(text);
  }

  Future<bool> initialize() async {
    if (_initialized) return _sttReady;

    await _tts.setSpeechRate(0.48);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    _tts.setCompletionHandler(() {
      _setSpeaking(null);
    });
    _tts.setCancelHandler(() {
      _setSpeaking(null);
    });

    _sttReady = await _stt.initialize(
      onStatus: (_) {},
      onError: (_) {},
    );
    _initialized = true;
    return _sttReady;
  }

  Future<void> speak(String text, {String languageCode = 'en'}) async {
    final cleaned = speechText(text);
    if (cleaned.isEmpty) return;

    if (_speakingText == cleaned) {
      await stopSpeaking();
      return;
    }

    await stopSpeaking();
    try {
      final langs = await _tts.getLanguages;
      final tags = langs is List
          ? langs.map((e) => '$e')
          : const <String>[];
      final tag = resolveLocale(languageCode, tags) ?? 'en-US';
      await _tts.setLanguage(tag);
    } catch (_) {
      await _tts.setLanguage('en-US');
    }
    _setSpeaking(cleaned);
    await _tts.stop();
    await _tts.speak(cleaned);
  }

  Future<void> stopSpeaking() async {
    await _tts.stop();
    _setSpeaking(null);
  }

  bool get isListening => _stt.isListening;

  /// Starts dictation. Prefers on-device recognition when the platform supports it.
  Future<bool> startListening({
    required void Function(String text, bool isFinal) onResult,
    void Function(String message)? onError,
    String localeId = '',
  }) async {
    if (!_sttReady) {
      final ok = await initialize();
      if (!ok) {
        onError?.call('Speech recognition is not available on this device.');
        return false;
      }
    }

    if (_stt.isListening) {
      await _stt.stop();
    }

    final locale = localeId.isNotEmpty ? localeId : 'en_US';

    await _stt.listen(
      listenOptions: SpeechListenOptions(
        localeId: locale,
        listenMode: ListenMode.dictation,
        partialResults: true,
        cancelOnError: true,
        onDevice: !kIsWeb,
      ),
      onResult: (SpeechRecognitionResult result) {
        onResult(result.recognizedWords, result.finalResult);
      },
    );
    return true;
  }

  Future<void> stopListening() async {
    if (_stt.isListening) {
      await _stt.stop();
    }
  }

  Future<void> dispose() async {
    await stopListening();
    await stopSpeaking();
  }
}
