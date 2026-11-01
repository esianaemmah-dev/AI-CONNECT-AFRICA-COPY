import 'package:flutter_test/flutter_test.dart';

import 'package:ai_connect_africa/ai_core/tutor/conversation_memory.dart';

void main() {
  test('yes continues the last real question, not a new topic', () {
    final m = ConversationMemory();
    m.remember(
      student: 'What is photosynthesis?',
      tutor: 'Plants make food from sunlight.',
      verified: ['photosynthesis: plants make glucose using light, water, CO2'],
    );

    expect(m.isContinuing('yes'), isTrue);
    expect(m.resolveCurrent('yes'), contains('photosynthesis'));
    expect(m.resolveCurrent('yes'), isNot(equals('yes')));
  });

  test('"I mean …" corrects the last ask instead of starting afresh', () {
    final m = ConversationMemory();
    m.remember(
      student: 'Who is the president of Uganda?',
      tutor: 'The President of Uganda is the head of state.',
    );
    expect(m.isContinuing('i mean show me his picture'), isTrue);
    expect(m.isContinuing('I meant the vice president'), isTrue);
  });

  test('THREAD keeps both sides of the last exchange', () {
    final m = ConversationMemory();
    m.remember(
      student: 'What is photosynthesis?',
      tutor: 'Plants make food from sunlight and carbon dioxide.',
    );
    final block = m.promptBlock();
    expect(block, contains('Student: What is photosynthesis?'));
    expect(block, contains('Tutor: Plants make food'));
  });

  test('only verified facts are ESTABLISHED', () {
    final m = ConversationMemory();
    m.remember(
      student: 'Explain cells',
      tutor: 'Cells are made of cheese.',
      verified: ['cell: the basic unit of life'],
    );
    expect(m.established, ['cell: the basic unit of life']);
    expect(m.promptBlock(), contains('ESTABLISHED'));
  });

  test('a correction drops the newest established fact', () {
    final m = ConversationMemory();
    m.remember(
      student: 'What is DNA?',
      tutor: 'A recipe in the cell.',
      verified: ['DNA: genetic material'],
    );
    expect(m.isCorrection("that's wrong"), isTrue);
    m.noteCorrection();
    expect(m.established, isEmpty);
  });

  test('why stays anchored to the last question', () {
    final m = ConversationMemory();
    m.remember(student: 'Why do we have seasons?', tutor: 'Earth tilts.');
    expect(m.resolveCurrent('why'), contains('seasons'));
  });

  test('older exchanges fold into DIGEST instead of vanishing', () {
    final m = ConversationMemory(maxRawTurns: 4);
    m.remember(student: 'What is a cell?', tutor: 'Basic unit of life.');
    m.remember(student: 'What is DNA?', tutor: 'Genetic material.');
    m.remember(
      student: 'What is a gene?',
      tutor: 'A DNA segment that codes for a trait.',
    );
    expect(m.turns.length, 4);
    expect(m.lessonDigest, isNotNull);
    expect(m.lessonDigest, contains('cell'));
    final block = m.promptBlock();
    expect(block, contains('DIGEST:'));
    expect(block, contains('gene'));
    expect(block, contains('DNA'));
  });

  test('transient tutor failures are not remembered', () {
    final m = ConversationMemory();
    final ok = m.remember(
      student: 'What is gravity?',
      tutor:
          'I hit a brief snag finishing that answer. Please ask again in one short sentence.',
    );
    expect(ok, isFalse);
    expect(m.isEmpty, isTrue);
  });

  test('promptBlock respects maxChars without throwing', () {
    final m = ConversationMemory();
    for (var i = 0; i < 3; i++) {
      m.remember(
        student: 'Question number $i about ecosystems and food webs in detail?',
        tutor:
            'Answer number $i explains producers consumers and decomposers with local examples.',
        verified: ['ecosystem: living and non-living parts interacting $i'],
      );
    }
    final tight = m.promptBlock(maxChars: 180);
    expect(tight.length, lessThanOrEqualTo(180));
    expect(() => m.promptBlock(maxChars: 40), returnsNormally);
  });

  test('duplicate facts collapse to the newest wording', () {
    final m = ConversationMemory();
    m.remember(
      student: 'What is a cell?',
      tutor: 'Unit of life.',
      verified: ['cell: basic unit'],
    );
    m.remember(
      student: 'Say more about cells',
      tutor: 'They make tissues.',
      verified: ['cell: the basic unit of life'],
    );
    expect(
      m.established.where((e) => e.toLowerCase().startsWith('cell:')),
      hasLength(1),
    );
    expect(m.established.last, contains('basic unit of life'));
  });

  test('anchor survives follow-up chips', () {
    final m = ConversationMemory();
    m.remember(
      student: 'What is photosynthesis?',
      tutor: 'Plants make food from light.',
    );
    m.remember(student: 'why', tutor: 'Chlorophyll captures light energy.');
    expect(m.anchorQuestion, contains('photosynthesis'));
    expect(m.resolveCurrent('more'), contains('photosynthesis'));
  });

  group('active state', () {
    test('a short correction still updates a slot', () {
      final m = ConversationMemory();
      m.remember(
        student: 'How long is the field?',
        tutor: 'It is 100 metres long.',
        topic: 'Measurement',
        slots: {'unit': 'metres'},
      );
      m.remember(student: 'in cm', tutor: '10,000 cm.', slots: {'unit': 'cm'});
      expect(m.activeSlots, {'unit': 'cm'});
      expect(m.activeTopic, 'Measurement');
      expect(m.turns, hasLength(4));
    });

    test('collections stay capped', () {
      final m = ConversationMemory();
      m.remember(
        student: 'What is a cell?',
        tutor: 'Basic unit of life.',
        entities: [for (var i = 0; i < 50; i++) 'entity $i'],
        slots: {for (var i = 0; i < 50; i++) 'k$i': 'v$i'},
      );
      for (var i = 0; i < 50; i++) {
        m.addUnresolved('question $i?');
      }
      expect(m.activeEntities, hasLength(m.maxEntities));
      expect(m.activeEntities.last, 'entity 49');
      expect(m.activeSlots, hasLength(m.maxSlots));
      expect(m.activeSlots['k49'], 'v49');
      expect(m.unresolvedQuestions, hasLength(m.maxUnresolved));
    });

    test('round-trips through toJson and restoreFrom', () {
      final m = ConversationMemory()
        ..remember(
          student: 'What is photosynthesis?',
          tutor: 'Plants make food from light.',
          topic: 'Photosynthesis',
          intent: 'explain',
          slots: {'level': 'S2'},
          entities: ['chlorophyll'],
        )
        ..addUnresolved('Why are leaves green?');
      final copy = ConversationMemory()..restoreFrom(m.toJson());
      expect(copy.activeTopic, 'Photosynthesis');
      expect(copy.activeIntent, 'explain');
      expect(copy.activeSlots, {'level': 'S2'});
      expect(copy.activeEntities, ['chlorophyll']);
      expect(copy.unresolvedQuestions, ['Why are leaves green?']);
    });

    test('an older recall file without active state still restores', () {
      final m = ConversationMemory()
        ..restoreFrom({
          'anchor': 'What is DNA?',
          'turns': [
            {'role': 'student', 'text': 'What is DNA?'},
            {'role': 'tutor', 'text': 'Genetic material.'},
          ],
        });
      expect(m.turns, hasLength(2));
      expect(m.activeTopic, isNull);
      expect(m.activeSlots, isEmpty);
    });

    test('active state is dropped before THREAD under a tight budget', () {
      final m = ConversationMemory()
        ..remember(
          student: 'What is photosynthesis?',
          tutor: 'Plants make food from light.',
          topic: 'Photosynthesis',
          entities: [for (var i = 0; i < 6; i++) 'a long entity name $i'],
        );
      final block = m.promptBlock(maxChars: 160);
      expect(block, contains('THREAD:'));
      expect(block, isNot(contains('ACTIVE_ENTITIES')));
    });

    test('a correction with a key drops only that fact', () {
      final m = ConversationMemory()
        ..remember(
          student: 'What is DNA?',
          tutor: 'Genetic material.',
          verified: ['DNA: genetic material', 'Gene: DNA segment'],
        );
      m.noteCorrection(factKey: 'DNA');
      expect(m.established, ['Gene: DNA segment']);
    });
  });
}
