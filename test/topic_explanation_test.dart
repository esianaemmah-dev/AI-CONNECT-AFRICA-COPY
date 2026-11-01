import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_connect_africa/ai_core/inference/inference_engine.dart';
import 'package:ai_connect_africa/ai_core/tutor/tutor_pipeline.dart';
import 'package:ai_connect_africa/curriculum/curriculum_models.dart';
import 'package:ai_connect_africa/curriculum/curriculum_provider.dart';
import 'package:ai_connect_africa/curriculum/online_topic_lookup.dart';
import 'package:ai_connect_africa/curriculum/topic_explanations.dart';

class _Engine extends InferenceEngine {
  final prompts = <String>[];

  @override
  bool get isReady => true;

  @override
  String get backendLabel => 'test';

  @override
  Future<void> loadModel(String modelPath) async {}

  @override
  Future<String> generate({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
    TokenCallback? onToken,
    String? systemPrompt,
  }) async {
    prompts.add(prompt);
    return 'Because palisade cells get the most light.';
  }

  @override
  Future<void> dispose() async {}
}

/// Serves the real bundled pack from disk, as the app's asset bundle would.
class _DiskBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(await File(key).readAsBytes());
}

TopicExplanationService _service({Directory? updates, bool lessons = false}) =>
    TopicExplanationService(
      bundle: _DiskBundle(),
      updatesDir: () async => updates,
      subjects: lessons ? _bundledSubjects : null,
    );

Future<List<Subject>> _bundledSubjects() async => [
  for (final id in CurriculumService.bundledSubjectIds)
    Subject.fromJson(
      jsonDecode(await File('assets/curriculum/$id.json').readAsString())
          as Map<String, dynamic>,
    ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every bundled pack parses and its diagrams exist', () async {
    for (final id in TopicExplanationService.bundledPacks) {
      final topics = TopicExplanationService.parsePack(
        await File('assets/topic_explanations/$id.json').readAsString(),
      );
      expect(topics, isNotEmpty);
      for (final t in topics) {
        expect(t.sections, isNotEmpty, reason: t.id);
        expect(t.aliases, isNotEmpty, reason: t.id);
        if (t.diagram != null) {
          expect(File(t.diagram!).existsSync(), isTrue, reason: t.diagram);
        }
      }
    }
  });

  test('asking for the whole topic is told apart from a detail', () {
    const names = ['photosynthesis', 'how plants make food'];
    expect(asksForWholeTopic('What is photosynthesis?', names), isTrue);
    expect(asksForWholeTopic('Explain photosynthesis fully', names), isTrue);
    expect(asksForWholeTopic('Please explain to me about the photosynthesis', names), isTrue);
    expect(asksForWholeTopic('teach me how plants make food', names), isTrue);
    expect(asksForWholeTopic('What is the equation for photosynthesis?', names), isFalse);
    expect(asksForWholeTopic('Why does photosynthesis need light?', names), isFalse);
  });

  test('the whole topic is shown as written, with its diagram, and no model call', () async {
    final engine = _Engine();
    final tutor = TutorPipeline(engine: engine, explanations: _service());
    final streamed = StringBuffer();
    final reply = await tutor.respond(
      studentMessage: 'What is photosynthesis?',
      onToken: streamed.write,
    );
    expect(engine.prompts, isEmpty);
    expect(reply.text, contains('6CO2 + 6H2O → C6H12O6 + 6O2'));
    expect(reply.text, contains('Check your understanding'));
    expect(streamed.toString(), reply.text);
    expect(reply.lesson?.diagram, 'assets/curriculum/diagrams/biology/photosynthesis.svg');
  });

  test('the open (Home) chat teaches the topic too, and grounds its follow-up', () async {
    final engine = _Engine();
    final tutor = TutorPipeline(engine: engine, explanations: _service());
    final reply = await tutor.respond(
      studentMessage: 'What is photosynthesis?',
      useCurriculum: false,
    );
    expect(engine.prompts, isEmpty);
    expect(reply.text, contains('6CO2 + 6H2O'));
    await tutor.respond(studentMessage: 'Why does it need light?', useCurriculum: false);
    expect(engine.prompts.single, contains('Topic: Photosynthesis'));
  });

  test('a new question or a greeting leaves the explanation behind', () async {
    for (final next in ['what is love', 'good afternoon']) {
      final engine = _Engine();
      final tutor = TutorPipeline(engine: engine, explanations: _service());
      await tutor.respond(studentMessage: 'what is photosynthesis', useCurriculum: false);
      await tutor.respond(studentMessage: next, useCurriculum: false);
      // The chat so far may still be in the thread; the lesson must not be
      // fed in as the material to answer from.
      expect(engine.prompts.single, isNot(contains('Topic: Photosynthesis')), reason: next);
    }
    // A new question changes grounding while preserving the chat above it.
    final engine = _Engine();
    final tutor = TutorPipeline(engine: engine, explanations: _service());
    await tutor.respond(studentMessage: 'what is photosynthesis', useCurriculum: false);
    await tutor.respond(studentMessage: 'what is love', useCurriculum: false);
    expect(engine.prompts.single, contains('THREAD:'));
    expect(engine.prompts.single, contains('photosynthesis'));
    expect(engine.prompts.single, contains('CURRENT: what is love'));
  });

  test('first aid keeps its short word and never selects camera or taxation', () async {
    final service = _service(lessons: true);
    final lesson = await service.covering('what is first aid');
    expect(lesson, isNull);
    expect(await service.match('what is first aid'), isNull);
    expect(lesson?.title.toLowerCase(), isNot(contains('taxation')));
    final picture = await service.localPicture('first aid');
    expect(picture?.title.toLowerCase(), isNot(contains('camera')));
    expect(picture?.title.toLowerCase(), isNot(contains('taxation')));
    final composed = await service.compose('what is first aid');
    expect(composed?.fullText().toLowerCase(), isNot(contains('drawing aid')));
  });

  test('a topic no lesson is named after is grounded in the lesson covering it', () async {
    final service = _service(lessons: true);
    final t = await service.covering('can you teach me about triangles');
    expect(t, isNotNull);
    expect(t!.fullText().toLowerCase(), contains('triangle'));
    expect(asksForWholeTopic('can you teach me about triangles', t.wholeTopicNames), isFalse);
    expect(await service.covering('good afternoon'), isNull);
  });

  test('a topic no lesson is named after is put together from the lessons that teach it', () async {
    final t = (await _service(lessons: true).compose('teach me about Triangles'))!;
    final text = t.fullText();
    expect(t.title, 'Triangles');
    expect(t.diagram, 'assets/curriculum/diagrams/mathematics/triangles.svg');
    expect(File(t.diagram!).existsSync(), isTrue);
    expect(t.sections.length, greaterThanOrEqualTo(3));
    expect(text, contains('Where this is taught:'));
    expect(text.toLowerCase(), contains('triangle'));
    // ignore: avoid_print
    print(text);
    expect(await _service(lessons: true).compose('what is zzzz'), isNull);
  });

  test('a new topic after a greeting retains context and asks the current question', () async {
    final engine = _Engine();
    final tutor = TutorPipeline(engine: engine, explanations: _service(lessons: true));
    await tutor.respond(studentMessage: 'good afternoon', useCurriculum: false);
    await tutor.respond(studentMessage: 'can you teach me about triangles', useCurriculum: false);
    final prompt = engine.prompts.last;
    expect(prompt, contains('Student: good afternoon'));
    expect(prompt, contains('CURRENT: can you teach me about triangles'));
    expect(prompt.toLowerCase(), contains('triangle'));
  });

  test('a follow-up pointing back with "it" stays on the topic', () async {
    final engine = _Engine();
    final tutor = TutorPipeline(engine: engine, explanations: _service());
    await tutor.respond(studentMessage: 'Explain photosynthesis');
    await tutor.respond(studentMessage: 'why is it important?');
    expect(engine.prompts.single, contains('Topic: Photosynthesis'));
  });

  test('a follow-up goes to the model, grounded in the explanation', () async {
    final engine = _Engine();
    final tutor = TutorPipeline(engine: engine, explanations: _service());
    await tutor.respond(studentMessage: 'Explain photosynthesis');
    await tutor.respond(
      studentMessage: 'Why do palisade cells have so many chloroplasts?',
    );
    expect(engine.prompts.single, contains('Topic: Photosynthesis'));
    expect(engine.prompts.single, contains('palisade'));
  });

  test('an explanation shown without the model still grounds the follow-up', () async {
    final engine = _Engine();
    final service = _service();
    final tutor = TutorPipeline(engine: engine, explanations: service);
    final topic = (await service.match('What is photosynthesis?'))!;
    await tutor.adoptExplanation(topic, 'What is photosynthesis?');
    expect(engine.prompts, isEmpty);
    await tutor.respond(studentMessage: 'Why does it need light?');
    expect(engine.prompts.single, contains('Topic: Photosynthesis'));
  });

  test('every curriculum lesson becomes a full explanation', () async {
    final lessons = await _service(lessons: true).lessons();
    expect(lessons.length, greaterThan(300));
    for (final t in lessons) {
      expect(t.sections, isNotEmpty, reason: t.title);
      for (final s in t.sections) {
        expect(s.body.trim(), isNotEmpty, reason: '${t.title}: ${s.heading}');
      }
      expect(t.wholeTopicNames, isNotEmpty, reason: t.title);
    }
  });

  test('a lesson is taught whole from its title, grounded from a key term', () async {
    final service = _service(lessons: true);
    final algebra = (await service.match('What is algebra?'))!;
    expect(algebra.title, 'Algebra 1');
    expect(asksForWholeTopic('What is algebra?', algebra.wholeTopicNames), isTrue);
    final text = algebra.fullText();
    expect(text, contains('Worked example'));
    expect(text, contains('**Answer:**'));
    expect(text, contains('Check your understanding'));

    final photosynthesis = (await service.match('What is photosynthesis?'))!;
    expect(photosynthesis.fromPack, isTrue, reason: 'the reviewed pack wins');

    final cells = (await service.match('Explain cells'))!;
    expect(cells.asLesson().diagram, isNotNull);
  });

  test('every added diagram names a real lesson and a bundled file, with a credit', () async {
    final added = LessonDiagram.parseAll(
      await File('assets/topic_explanations/diagrams.json').readAsString(),
    );
    final lessons = {
      for (final s in await _bundledSubjects())
        for (final u in s.units)
          for (final l in u.lessons) '${s.id}|${l.title}',
    };
    for (final e in added.entries) {
      expect(lessons, contains(e.key));
      expect(File(e.value.asset).existsSync(), isTrue, reason: e.value.asset);
      if (e.value.credit.isNotEmpty) expect(e.value.credit, contains('Wikimedia Commons'));
    }
    final flower = (await _service(lessons: true).match('Explain flowering plants'))!;
    expect(flower.asLesson().diagram, added['biology|Flowering Plants']!.asset);
    expect(flower.fullText(), contains('Diagram: '));
  });

  test('picture requests are recognised, with their subject', () {
    expect(pictureRequestSubject('give me a photo'), '');
    expect(pictureRequestSubject('give me images'), '');
    expect(pictureRequestSubject('can I have an image?'), '');
    expect(pictureRequestSubject('show me a picture of a frog'), 'frog');
    expect(pictureRequestSubject('show me a frog'), 'frog');
    expect(pictureRequestSubject('draw a frog'), 'frog');
    expect(pictureRequestSubject('please sketch me a flower'), 'flower');
    expect(pictureRequestSubject('can you show me a triangle?'), 'triangle');
    expect(pictureRequestSubject('draw a diagram of a frog'), 'frog');
    expect(pictureRequestSubject('draw it'), '');
    expect(pictureRequestSubject('show me how to solve this'), isNull);
    expect(pictureRequestSubject('show me my progress'), isNull);
    expect(pictureRequestSubject('show me an example of fractions'), isNull);
    expect(pictureRequestSubject('show me a video of a frog'), isNull);

    expect(pictureRequestSubject('what does a frog look like'), 'frog');
    expect(pictureRequestSubject('diagram of the heart please'), 'heart');
    expect(pictureRequestSubject('what is a frog'), isNull);
    expect(pictureRequestSubject('explain the diagram on page 14'), isNull);
    expect(pictureRequestSubject('some images about its diverse cultures'), 'diverse cultures');
    expect(
      pictureRequestSubject('i mean show me the picture of the president of  uganda'),
      'president uganda',
    );
    expect(pictureRequestSubject('show me a picture of him'), '');
  });

  test('"Who is …?" names a person or office to look up', () {
    expect(whoTopic('Who is the president of Uganda'), 'president of uganda');
    expect(askedTopic('who was Kabaka Mutesa I?'), 'kabaka mutesa i');
    expect(askedTopic('where is africa located on global scale'), 'africa');
    expect(askedTopic('Where is Lake Victoria?'), 'lake victoria');
    expect(whoTopic('What is a frog'), isNull);
  });

  test('a picture request that points back joins the earlier topic', () {
    expect(
      pictureSubjectCandidates('some images about its diverse cultures', 'diverse cultures',
          'population and urbanisation in africa'),
      ['africa diverse cultures', 'population diverse cultures', 'diverse cultures'],
    );
    expect(
      pictureSubjectCandidates('images of its people', 'people', 'africa continent'),
      ['africa people', 'continent people', 'people'],
    );
    // No back-reference, or nothing earlier: the subject alone.
    expect(pictureSubjectCandidates('a picture of a frog', 'frog', 'africa'), ['frog']);
    expect(pictureSubjectCandidates('pictures of its cells', 'cells', null), ['cells']);
  });

  test('a picture request uses the bundled diagram, and says so when there is none', () async {
    final service = _service(lessons: true);
    final triangle = await service.localPicture('triangles');
    expect(triangle?.diagram, 'assets/curriculum/diagrams/mathematics/triangles.svg');
    expect(picturesReply('triangles', local: triangle), contains('shown above'));
    expect(await service.localPicture('frog'), isNull);
    expect(picturesReply('frog'), contains('Look up topics online'));
  });

  test('web pictures are shown inline with their credit, links kept intact', () {
    final text = picturesReply(
      'frog',
      web: const [
        WebPicture(
          url: 'https://upload.example/thumb/Frog_(Rana)2.jpg',
          caption: 'A common *frog*',
          credit: 'Jane Doe, CC BY-SA 4.0, via Wikimedia Commons',
        ),
      ],
      onlineAllowed: true,
    );
    expect(text, contains('![A common frog](https://upload.example/thumb/Frog_%28Rana%292.jpg)'));
    expect(text, contains('CC BY-SA 4.0'));
  });

  test('clip requests are recognised, with their subject', () {
    expect(clipRequestSubject('show me a video of a volcano'), 'volcano');
    expect(clipRequestSubject('any clips?'), '');
    expect(clipRequestSubject('can I watch a video'), '');
    expect(clipRequestSubject('give me a photo'), isNull);
    expect(clipRequestSubject('what is a frog'), isNull);
  });

  test('clips are shown as stills linked to the video, with length and credit', () {
    final text = clipsReply('frog', const [
      WebClip(
        url: 'https://upload.example/frog.webm.480p.vp9.webm',
        poster: 'https://upload.example/frog.jpg',
        caption: 'Frog croaking',
        credit: 'Jane, CC BY 4.0, via Wikimedia Commons',
        seconds: 75,
      ),
    ]);
    expect(text, contains('[![▶ Frog croaking](https://upload.example/frog.jpg)](https://upload.example/frog.webm.480p.vp9.webm)'));
    expect(text, contains('(1:15)'));
    expect(text, contains('CC BY 4.0'));
    expect(clipsReply('frog', const [], onlineAllowed: false), contains('Look up topics online'));
  });

  group('online look-up', () {
    test('clips: the small WebM, free licences, relevant and short only', () async {
      Map<String, dynamic> video(int index, String name, String license, {double duration = 30, String caption = ''}) => {
        'title': 'File:$name',
        'index': index,
        'videoinfo': [
          {
            'url': 'https://upload.example/$name',
            'thumburl': 'https://upload.example/$name.jpg',
            'size': 90000000,
            'duration': duration,
            'derivatives': [
              {'type': 'video/webm; codecs="vp9"', 'height': 1080, 'src': 'https://upload.example/$name.1080p.webm'},
              {'type': 'video/webm; codecs="vp9"', 'height': 240, 'src': 'https://upload.example/$name.240p.webm'},
              {'type': 'video/webm; codecs="vp9"', 'height': 480, 'src': 'https://upload.example/$name.480p.webm'},
              {'type': 'video/quicktime', 'height': 360, 'src': 'https://upload.example/$name.360p.mov'},
            ],
            'extmetadata': {
              'LicenseShortName': {'value': license},
              'ImageDescription': {'value': caption},
            },
          },
        ],
      };
      final client = MockClient((req) async => http.Response(
            jsonEncode({
              'query': {
                'pages': {
                  '1': video(2, 'Frog_swimming.webm', 'CC BY-SA 4.0'),
                  '2': video(1, 'Frog_croaking.webm', 'CC0'),
                  '3': video(3, 'Frog_copyrighted.webm', 'All rights reserved'),
                  '4': video(4, 'Frog_documentary.webm', 'CC BY 4.0', duration: 3600),
                  '5': video(5, 'Pond_at_night.webm', 'CC BY 4.0'),
                },
              },
            }),
            200,
          ));
      final clips = await OnlineTopicLookup(client: client).clips('frog');
      expect(clips.map((c) => c.url), [
        'https://upload.example/Frog_croaking.webm.480p.webm',
        'https://upload.example/Frog_swimming.webm.480p.webm',
      ]);
      expect(clips.first.poster, 'https://upload.example/Frog_croaking.webm.jpg');
      expect(await OnlineTopicLookup(client: client).clips('human reproduction'), isEmpty);
    });

    http.Client wikipedia({String description = 'Large body of fresh water'}) =>
        MockClient((req) async {
          if (req.url.path.contains('/page/summary/')) {
            return http.Response(
              jsonEncode({
                'type': 'standard',
                'title': 'Lake Victoria',
                'description': description,
                'extract': 'Lake Victoria is one of the African Great Lakes.',
                'thumbnail': {'source': 'https://upload.example/lake.png'},
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'query': {
                'pages': {
                  '1': {
                    'extract':
                        'Lake Victoria is one of the African Great Lakes, shared by Uganda, Kenya and Tanzania.\n'
                        'It is the largest tropical lake in the world and the source of the White Nile.',
                  },
                },
              },
            }),
            200,
          );
        });

    test('how and why questions can get credited internet explanations', () async {
      final lookup = OnlineTopicLookup(client: wikipedia());
      expect((await lookup.lookUp('How do lakes form?'))?.fullText(), contains('CC BY-SA'));
      expect((await lookup.lookUp('Why are lakes important?'))?.fullText(), contains('not from your syllabus'));
      expect(await lookup.lookUp('hello'), isNull);
    });

    test('a topic question gets the introduction, marked and credited', () async {
      final t = await OnlineTopicLookup(client: wikipedia()).lookUp('What is Lake Victoria?');
      expect(t, isNotNull);
      expect(t!.summary, contains('Uganda'));
      expect(t.diagram, 'https://upload.example/lake.png');
      expect(t.fullText(), contains('not from your syllabus'));
      expect(t.fullText(), contains('CC BY-SA'));
    });

    test('pages that are not schoolwork are refused', () async {
      final t = await OnlineTopicLookup(
        client: wikipedia(description: '2019 American film'),
      ).lookUp('What is Lake Victoria?');
      expect(t, isNull);
    });

    test('pictures: free licences only, page furniture and unsuitable files dropped', () async {
      final client = MockClient((req) async {
        if (req.url.path.contains('/page/summary/')) {
          return http.Response(
            jsonEncode({
              'type': 'standard',
              'title': 'Frog',
              'description': 'Order of amphibians',
              'originalimage': {'source': 'https://upload.example/Lead_frog.jpg'},
            }),
            200,
          );
        }
        Map<String, dynamic> file(String name, String license, {int width = 800, String mime = 'image/jpeg'}) => {
          'title': 'File:$name',
          'imageinfo': [
            {
              'thumburl': 'https://upload.example/$name',
              'mime': mime,
              'width': width,
              'extmetadata': {
                'LicenseShortName': {'value': license},
                'Artist': {'value': '<a href="x">Jane</a>'},
                'ImageDescription': {'value': 'A frog'},
              },
            },
          ],
        };
        return http.Response(
          jsonEncode({
            'query': {
              'pages': {
                '1': file('Tree_frog.jpg', 'CC BY-SA 4.0'),
                '2': file('Lead_frog.jpg', 'Public domain'),
                '3': file('Frog_all_rights.jpg', 'All rights reserved'),
                '4': file('Commons-logo.svg', 'Public domain', mime: 'image/svg+xml'),
                '5': file('Frog_nude_art.jpg', 'CC0'),
                '6': file('Tiny_frog.jpg', 'CC0', width: 120),
              },
            },
          }),
          200,
        );
      });
      final pics = await OnlineTopicLookup(client: client).pictures('frog');
      expect(pics.map((p) => p.url), [
        'https://upload.example/Lead_frog.jpg',
        'https://upload.example/Tree_frog.jpg',
      ]);
      expect(pics.first.credit, 'Jane, Public domain, via Wikimedia Commons');
    });

    test('no online pictures for sensitive topics', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      });
      final lookup = OnlineTopicLookup(client: client);
      expect(await lookup.pictures('human body'), isEmpty);
      expect(await lookup.pictures('sexual reproduction in humans'), isEmpty);
      expect(calls, 0);
    });

    test('no connection finds nothing and does not throw', () async {
      final offline = MockClient((_) async => throw const SocketException('offline'));
      expect(await OnlineTopicLookup(client: offline).lookUp('What is Lake Victoria?'), isNull);
    });

    test('only "What is …?" style questions are looked up', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('{}', 404);
      });
      await OnlineTopicLookup(client: client).lookUp('my name is Ann');
      expect(calls, 0);
    });
  });

  test('a newer pack update replaces the bundled topic', () async {
    final dir = await Directory.systemTemp.createTemp('topic_packs');
    addTearDown(() => dir.delete(recursive: true));
    final bundled = jsonDecode(
      await File('assets/topic_explanations/biology.json').readAsString(),
    ) as Map<String, dynamic>;
    final topic = Map<String, dynamic>.from((bundled['topics'] as List).first as Map)
      ..['version'] = 2
      ..['summary'] = 'Updated summary.';
    await File('${dir.path}/biology.json').writeAsString(
      jsonEncode({'subject': 'Biology', 'topics': [topic]}),
    );
    final t = await _service(updates: dir).match('photosynthesis');
    expect(t?.version, 2);
    expect(t?.summary, 'Updated summary.');
  });
}
