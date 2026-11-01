import 'package:ai_connect_africa/voice/speech_text.dart';
import 'package:ai_connect_africa/voice/voice_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('reads words without Markdown, links, or code strings', () {
    final text = speechText(
      '## **Photosynthesis**\n- Plants use _sunlight_.\n'
      '[Read more](https://example.com/notes)\n```python\nprint("hidden")\n```',
    );
    expect(text, 'Photosynthesis Plants use sunlight. Read more');
  });
  test('omits internal records, hidden reasoning and model markers', () {
    final text = speechText(
      '<think>private reasoning</think><|im_start|>\n'
      '[PDF: sha256=abc | pages=2 | bytes=300]\n'
      '[QUIZ: page=1] {"correctIndex": 2}\n'
      '[ASSIGNMENT] {"id":"internal-id"}\n'
        'Plants make food. /no_think __MATH_0__ ⟦0⟧',
    );
    expect(text, 'Plants make food.');
  });
  test('keeps mathematical meaning without speaking LaTeX commands', () {
    final text = speechText(
      r'The answer is $\frac{1}{2}$. Then $\sqrt{9} = 3$ and $2 \times 3 = 6$.',
    );
    expect(text, contains('1 over 2'));
    expect(text, contains('square root of 9 = 3'));
    expect(text, contains('2 times 3 = 6'));
    expect(text, isNot(contains('frac')));
    expect(text, isNot(contains(r'\')));
    expect(text, isNot(contains(r'$')));
  });
  test('keeps local-language text and visible HTML words', () {
    expect(
      speechText('<p><strong>Amakoola</strong> &amp; amazzi.</p>'),
      'Amakoola & amazzi.',
    );
    expect(speechText('Énergie, ብርሃን, àwọn ewé.'), 'Énergie, ብርሃን, àwọn ewé.');
    expect(speechText('A &#60; B and &#x3b1;.'), 'A < B and α.');
  });
  test('cleaning is safe to apply at both the view and voice service', () {
    final once = speechText(r'**Answer:** $\frac{3}{4}$ of the total.');
    expect(speechText(once), once);
  });
  test(
    'voice plugin receives only cleaned prose and tapping again stops it',
    () async {
      const channel = MethodChannel('flutter_tts');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'getLanguages') return ['en-US'];
            return 1;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final voice = VoiceService();
      await voice.speak('## **Plants** use sunlight.');
      final spoken = calls.singleWhere((c) => c.method == 'speak').arguments;
      expect(spoken is Map ? spoken['text'] : spoken, 'Plants use sunlight.');
      expect(voice.speakingText, 'Plants use sunlight.');
      await voice.speak('Plants use sunlight.');
      expect(calls.where((c) => c.method == 'speak'), hasLength(1));
      expect(voice.isSpeaking, isFalse);
    },
  );
}
