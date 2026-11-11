import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db/otic_database.dart';
import '../../shared/widgets/studio_page.dart';
import 'gals_field_store.dart';
import 'gals_pack.dart';

/// Staff-facing, bundled learning and local field work on a shared device.
class GalsScreen extends ConsumerStatefulWidget {
  const GalsScreen({super.key});
  @override
  ConsumerState<GalsScreen> createState() => _GalsScreenState();
}

class _GalsScreenState extends ConsumerState<GalsScreen> {
  late Future<GalsPackCatalog> _catalog;
  late Future<List<GalsChampion>> _champions;
  Future<GalsLessonCompletion?>? _completion;
  Future<List<GalsSharingRecord>>? _records;
  Future<List<GalsAchievementReview>>? _reviews;
  final _name = TextEditingController();
  final _group = TextEditingController();
  final _championAgeBand = TextEditingController();
  final _championLocation = TextEditingController();
  final _reflection = TextEditingController();
  final _ageBand = TextEditingController();
  final _location = TextEditingController();
  final _count = TextEditingController();
  final _reviewGoal = TextEditingController();
  final _reviewProgress = TextEditingController();
  final _reviewEnablers = TextEditingController();
  final _reviewChallenges = TextEditingController();
  final _reviewNextSteps = TextEditingController();
  final _answers = <String, int>{};
  final _activities = <String>{};
  final _attendanceGroups = <GalsAttendanceGroup>[];
  String? _championId;
  String? _lessonId;
  String _sex = 'not_recorded';
  String _championSex = 'not_recorded';
  DateTime _trainingDate = DateTime.now();
  bool _hasTrainingDate = false;
  DateTime _date = DateTime.now();
  int _page = 0;
  bool _saving = false;
  String? _message;

  GalsFieldStore get _store => ref.read(galsFieldStoreProvider);

  @override
  void initState() {
    super.initState();
    _catalog = GalsPackCatalog.load();
    _champions = _store.champions();
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _group,
      _championAgeBand,
      _championLocation,
      _reflection,
      _ageBand,
      _location,
      _count,
      _reviewGoal,
      _reviewProgress,
      _reviewEnablers,
      _reviewChallenges,
      _reviewNextSteps,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _select(String? id, GalsPack pack, GalsLesson lesson) {
    setState(() {
      _championId = id;
      _activities.clear();
      _attendanceGroups.clear();
      _count.clear();
      for (final field in [
        _reviewGoal,
        _reviewProgress,
        _reviewEnablers,
        _reviewChallenges,
        _reviewNextSteps,
      ]) {
        field.clear();
      }
      _message = null;
      _refresh(pack, lesson);
    });
  }

  void _refresh(GalsPack pack, GalsLesson lesson) {
    final id = _championId;
    _completion = id == null || lesson.toolId == null
        ? null
        : _store.completion(championId: id, pack: pack, lessonId: lesson.id);
    _records = id == null ? null : _store.sharingFor(id);
    _reviews = id == null ? null : _store.achievementReviewsFor(id);
  }

  void _selectLesson(String? id, GalsPack pack) {
    final lesson = id == null ? null : pack.lesson(id);
    if (lesson == null) return;
    setState(() {
      _lessonId = id;
      _answers.clear();
      _activities.clear();
      _attendanceGroups.clear();
      _count.clear();
      _reflection.clear();
      _message = null;
      _refresh(pack, lesson);
    });
  }

  Future<void> _save(Future<void> Function() action) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _message = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Text(text, style: Theme.of(context).textTheme.titleLarge),
  );

  Widget _championPicker(GalsPack pack, GalsLesson lesson) => FutureBuilder(
    future: _champions,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return TextButton(
          onPressed: () => setState(() {
            _champions = _store.champions();
          }),
          child: const Text('Could not load champions. Retry'),
        );
      }
      if (!snapshot.hasData) return const LinearProgressIndicator();
      final people = snapshot.data!;
      if (people.isEmpty)
        return const Text(
          'No champions saved yet. Add a fictional alias in Champion.',
        );
      return DropdownButtonFormField<String>(
        key: ValueKey('champion-$_championId-${people.length}'),
        initialValue: _championId,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Champion on this device'),
        items: [
          for (final p in people)
            DropdownMenuItem(
              value: p.id,
              child: Text('${p.displayName} · ${p.id.substring(0, 8)}'),
            ),
        ],
        onChanged: _saving ? null : (id) => _select(id, pack, lesson),
      );
    },
  );

  List<Widget> _learn(GalsPack pack, GalsLesson lesson, GalsTool? tool) => [
    Text(pack.programmeTitle, style: Theme.of(context).textTheme.titleMedium),
    Text(pack.audience),
    _heading(lesson.title),
    Text(lesson.body, style: const TextStyle(height: 1.6)),
    if (tool != null) ...[
      _heading('Purpose'),
      for (final item in tool.purpose)
        ListTile(leading: const Icon(Icons.flag_outlined), title: Text(item)),
      _heading('Prepare'),
      for (final item in tool.preparation)
        ListTile(
          leading: const Icon(Icons.inventory_2_outlined),
          title: Text(item),
        ),
      _heading('Paper activity'),
      for (var i = 0; i < tool.steps.length; i++)
        Card(
          child: ListTile(
            leading: CircleAvatar(child: Text('${i + 1}')),
            title: Text(tool.steps[i].instruction),
            subtitle: tool.steps[i].hasAudio
                ? const Text('Reviewed audio is listed in this pack.')
                : null,
          ),
        ),
      _heading('Facilitator prompts'),
      for (final prompt in tool.facilitatorPrompts)
        ListTile(
          leading: const Icon(Icons.question_answer_outlined),
          title: Text(prompt),
        ),
    ],
    _heading('Check your understanding'),
    for (final q in lesson.quiz) ...[
      Text(q.question, style: Theme.of(context).textTheme.titleMedium),
      Wrap(
        spacing: 8,
        children: [
          for (var i = 0; i < q.choices.length; i++)
            ChoiceChip(
              key: ValueKey('${q.id}-$i'),
              label: Text(q.choices[i]),
              selected: _answers[q.id] == i,
              onSelected: (_) => setState(() => _answers[q.id] = i),
            ),
        ],
      ),
      if (_answers.containsKey(q.id))
        Text(
          '${_answers[q.id] == q.correct ? 'Correct.' : 'Try again.'} ${q.explanation}',
        ),
      const SizedBox(height: 16),
    ],
    if (tool != null)
      TextField(
        key: const ValueKey('reflection'),
        controller: _reflection,
        maxLength: 600,
        minLines: 2,
        maxLines: 4,
        decoration: const InputDecoration(
          labelText: 'Practice reflection',
          hintText:
              'What would you change or ask a peer? Use a fictional example.',
        ),
      ),
    if (tool != null)
      FilledButton(
        onPressed: () => setState(() => _page = 1),
        child: const Text('Continue to champion'),
      ),
    for (final credit in pack.credits)
      Padding(padding: const EdgeInsets.only(top: 12), child: Text(credit)),
  ];

  List<Widget> _champion(GalsPack pack, GalsLesson lesson) => [
    _heading('Champion register'),
    if (lesson.toolId == null)
      const Text(
        'Choose a tool lesson in Learn before saving a champion learning record.',
      ),
    const Text(
      'Choose a saved champion above or create a fictional practice alias. A champion invites peers to learn; this is not certification.',
    ),
    TextField(
      key: const ValueKey('champion-alias'),
      controller: _name,
      maxLength: 80,
      enabled: !_saving,
      decoration: const InputDecoration(
        labelText: 'Fictional champion alias',
        hintText: 'Neri Example',
      ),
    ),
    TextField(
      controller: _group,
      maxLength: 80,
      enabled: !_saving,
      decoration: const InputDecoration(
        labelText: 'Group (optional, fictional for this draft)',
      ),
    ),
    TextField(
      controller: _championAgeBand,
      maxLength: 80,
      enabled: !_saving,
      decoration: const InputDecoration(
        labelText: 'Age band (optional, provisional)',
      ),
    ),
    TextField(
      controller: _championLocation,
      maxLength: 120,
      enabled: !_saving,
      decoration: const InputDecoration(
        labelText: 'Location (optional, fictional for this draft)',
      ),
    ),
    DropdownButtonFormField<String>(
      initialValue: _championSex,
      decoration: const InputDecoration(
        labelText: 'Champion category (optional, provisional)',
      ),
      items: const [
        DropdownMenuItem(value: 'not_recorded', child: Text('Not recorded')),
        DropdownMenuItem(value: 'female', child: Text('Female')),
        DropdownMenuItem(value: 'male', child: Text('Male')),
        DropdownMenuItem(
          value: 'another',
          child: Text('Another / self-described'),
        ),
      ],
      onChanged: _saving
          ? null
          : (value) => setState(() => _championSex = value!),
    ),
    SwitchListTile(
      value: _hasTrainingDate,
      title: const Text('Record training date (optional)'),
      contentPadding: EdgeInsets.zero,
      onChanged: _saving
          ? null
          : (value) => setState(() => _hasTrainingDate = value),
    ),
    if (_hasTrainingDate)
      TextButton(
        onPressed: _saving
            ? null
            : () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: _trainingDate,
                  firstDate: DateTime(2000),
                  lastDate: DateTime.now(),
                );
                if (date != null && mounted)
                  setState(() => _trainingDate = date);
              },
        child: Text(
          'Training date: ${_trainingDate.toIso8601String().substring(0, 10)}',
        ),
      ),
    FilledButton(
      onPressed: _saving
          ? null
          : () => _save(() async {
              final id = await _store.addChampion(
                _name.text,
                groupName: _group.text,
                sex: _championSex == 'not_recorded' ? null : _championSex,
                ageBand: _championAgeBand.text,
                location: _championLocation.text,
                trainingAt: _hasTrainingDate ? _trainingDate : null,
              );
              if (!mounted) return;
              _name.clear();
              _group.clear();
              _championAgeBand.clear();
              _championLocation.clear();
              setState(() {
                _champions = _store.champions();
              });
              _select(id, pack, lesson);
              setState(() => _message = 'Champion saved on this device.');
            }),
      child: const Text('Save champion'),
    ),
    const SizedBox(height: 20),
    if (_championId != null && lesson.toolId != null)
      FutureBuilder(
        future: _completion,
        builder: (context, snapshot) {
          if (snapshot.hasError) return _retryDetails(pack, lesson);
          if (snapshot.connectionState != ConnectionState.done)
            return const LinearProgressIndicator();
          final saved = snapshot.data;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (saved != null) ...[
                Text('Lesson completed · ${saved.contentVersion}'),
                Text('Saved reflection: ${saved.reflection}'),
                FilledButton(
                  onPressed: _saving ? null : () => setState(() => _page = 2),
                  child: const Text('Continue to peer sharing'),
                ),
              ] else ...[
                const Text(
                  'Save the checked lesson and short reflection for this champion.',
                ),
                FilledButton(
                  onPressed: _saving
                      ? null
                      : () => _save(() async {
                          await _store.completeLesson(
                            championId: _championId!,
                            pack: pack,
                            lessonId: lesson.id,
                            answers: Map.of(_answers),
                            reflection: _reflection.text,
                          );
                          if (!mounted) return;
                          setState(() {
                            _refresh(pack, lesson);
                            _page = 2;
                            _message = 'Lesson and reflection saved locally.';
                          });
                        }),
                  child: const Text('Save lesson completion'),
                ),
              ],
            ],
          );
        },
      ),
  ];

  Widget _retryDetails(GalsPack pack, GalsLesson lesson) => TextButton(
    onPressed: () => setState(() => _refresh(pack, lesson)),
    child: const Text('Could not load saved records. Retry'),
  );

  List<Widget> _share(GalsPack pack, GalsLesson lesson) {
    if (lesson.toolId == null || lesson.sessionPlanId == null) {
      return [
        const Text(
          'Choose a tool lesson before preparing a peer-sharing session.',
        ),
      ];
    }
    final plan = pack.sessionPlans.singleWhere(
      (p) => p.id == lesson.sessionPlanId,
    );
    return [
      _heading('${plan.title} · ${plan.minutes} min'),
      Text(plan.objective),
      _heading('Materials'),
      for (final item in plan.materials)
        ListTile(
          leading: const Icon(Icons.inventory_2_outlined),
          title: Text(item),
        ),
      _heading('Facilitator tips'),
      for (final item in plan.facilitatorTips)
        ListTile(
          leading: const Icon(Icons.lightbulb_outline),
          title: Text(item),
        ),
      for (final activity in plan.activities)
        CheckboxListTile(
          key: ValueKey('activity-${activity.id}'),
          contentPadding: EdgeInsets.zero,
          title: Text('${activity.minutes} min · ${activity.instruction}'),
          value: _activities.contains(activity.id),
          onChanged: _saving
              ? null
              : (done) => setState(() {
                  if (done == true) {
                    _activities.add(activity.id);
                  } else {
                    _activities.remove(activity.id);
                  }
                }),
        ),
      Text(plan.homework),
      _heading('Record this peer-sharing session'),
      const Text(
        'Tick the activities after trying them. Add separate attendance groups when known; use Not recorded and Unknown otherwise. Count each attendee in only one group. Counts are attendances, not unique people reached.',
      ),
      TextButton(
        onPressed: _saving
            ? null
            : () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime(2000),
                  lastDate: DateTime.now(),
                );
                if (date != null && mounted) setState(() => _date = date);
              },
        child: Text(
          'Session date: ${_date.toIso8601String().substring(0, 10)}',
        ),
      ),
      DropdownButtonFormField<String>(
        initialValue: _sex,
        decoration: const InputDecoration(
          labelText: 'Attendance category (provisional)',
        ),
        items: const [
          DropdownMenuItem(value: 'female', child: Text('Female')),
          DropdownMenuItem(value: 'male', child: Text('Male')),
          DropdownMenuItem(
            value: 'another',
            child: Text('Another / self-described'),
          ),
          DropdownMenuItem(value: 'not_recorded', child: Text('Not recorded')),
        ],
        onChanged: _saving ? null : (value) => setState(() => _sex = value!),
      ),
      TextField(
        key: const ValueKey('age-band'),
        controller: _ageBand,
        maxLength: 80,
        enabled: !_saving,
        decoration: const InputDecoration(
          labelText: 'Age band (provisional)',
          hintText: 'Adults (fictional group)',
        ),
      ),
      TextField(
        key: const ValueKey('location'),
        controller: _location,
        maxLength: 120,
        enabled: !_saving,
        decoration: const InputDecoration(
          labelText: 'Fictional location',
          hintText: 'Example Garden',
        ),
      ),
      TextField(
        key: const ValueKey('attendance'),
        controller: _count,
        keyboardType: TextInputType.number,
        enabled: !_saving,
        decoration: const InputDecoration(labelText: 'Session attendances'),
      ),
      for (final (index, group) in _attendanceGroups.indexed)
        ListTile(
          title: Text('${group.count} · ${group.sex} · ${group.ageBand}'),
          trailing: IconButton(
            tooltip: 'Remove attendance group',
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: _saving
                ? null
                : () => setState(() => _attendanceGroups.removeAt(index)),
          ),
        ),
      TextButton(
        onPressed: _saving
            ? null
            : () {
                final group = GalsAttendanceGroup(
                  _sex,
                  _ageBand.text,
                  int.tryParse(_count.text) ?? 0,
                );
                try {
                  group.validate();
                  setState(() {
                    _attendanceGroups.add(group);
                    _count.clear();
                    _message = null;
                  });
                } catch (error) {
                  setState(() => _message = '$error');
                }
              },
        child: const Text('Add attendance group'),
      ),
      if (_championId == null)
        const Text('Choose a champion to save this session.')
      else
        FutureBuilder(
          future: _completion,
          builder: (context, snapshot) {
            if (snapshot.hasError) return _retryDetails(pack, lesson);
            final ready =
                snapshot.connectionState == ConnectionState.done &&
                snapshot.hasData;
            return Column(
              children: [
                if (!ready)
                  const Text(
                    'Save this lesson version in Champion before recording a session.',
                  ),
                FilledButton(
                  onPressed:
                      !ready ||
                          _saving ||
                          _activities.length != plan.activities.length
                      ? null
                      : () => _save(() async {
                          final groups = [..._attendanceGroups];
                          if (_count.text.trim().isNotEmpty) {
                            groups.add(
                              GalsAttendanceGroup(
                                _sex,
                                _ageBand.text,
                                int.tryParse(_count.text) ?? 0,
                              ),
                            );
                          }
                          if (groups.isEmpty)
                            throw ArgumentError(
                              'Enter at least one attendance count',
                            );
                          final first = groups.removeAt(0);
                          await _store.recordSharing(
                            championId: _championId!,
                            pack: pack,
                            toolId: lesson.toolId!,
                            lessonId: lesson.id,
                            occurredAt: _date,
                            sex: first.sex,
                            ageBand: first.ageBand,
                            location: _location.text,
                            attendance: first.count,
                            additionalGroups: groups,
                          );
                          if (!mounted) return;
                          _count.clear();
                          _attendanceGroups.clear();
                          setState(() {
                            _activities.clear();
                            _refresh(pack, lesson);
                            _page = 3;
                            _message =
                                'Peer-sharing session saved offline on this device.';
                          });
                        }),
                  child: const Text('Save sharing on this device'),
                ),
              ],
            );
          },
        ),
    ];
  }

  List<Widget> _saved(GalsPackCatalog catalog, GalsLesson lesson) => [
    _heading('Saved sharing events on this device'),
    const Text(
      'Select a champion to retrieve their records. Open a session to see its original content version and attendance details.',
    ),
    if (_championId != null)
      FutureBuilder(
        future: _records,
        builder: (context, snapshot) {
          if (snapshot.hasError) return _retryDetails(catalog.active, lesson);
          if (!snapshot.hasData) return const LinearProgressIndicator();
          final records = snapshot.data!;
          if (records.isEmpty)
            return const Text('No sharing sessions saved for this champion.');
          return Column(
            children: [
              for (final record in records)
                Card(
                  child: ListTile(
                    title: Text(record.session.occurredAt.substring(0, 10)),
                    subtitle: Text(
                      '${record.sessionAttendances} session attendances · ${record.tools.map((t) => t.contentVersion).join(', ')}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openRecord(catalog, record),
                  ),
                ),
            ],
          );
        },
      ),
  ];

  List<Widget> _achievementReview(GalsPack pack, GalsLesson lesson) {
    if (lesson.toolId == null) {
      return [
        const Text(
          'Choose a tool lesson before opening its optional achievement review.',
        ),
      ];
    }
    final fields = <(String, TextEditingController)>[
      ('Goal (optional)', _reviewGoal),
      ('Progress noticed (optional)', _reviewProgress),
      ('Enabling factors (optional)', _reviewEnablers),
      ('Challenges (optional)', _reviewChallenges),
      ('Next steps (optional)', _reviewNextSteps),
    ];
    return [
      _heading('Optional achievement review'),
      const Text(
        'This is a voluntary local reflection, not proof of impact. Do not enter a private drawing, personal identifiers, photos or voice notes.',
      ),
      for (final field in fields)
        TextField(
          controller: field.$2,
          maxLength: 600,
          minLines: 2,
          maxLines: 3,
          enabled: !_saving,
          decoration: InputDecoration(labelText: field.$1),
        ),
      if (_championId == null)
        const Text('Choose a champion to save a review.')
      else ...[
        FilledButton(
          onPressed: _saving
              ? null
              : () => _save(() async {
                  await _store.recordAchievementReview(
                    championId: _championId!,
                    pack: pack,
                    toolId: lesson.toolId!,
                    reviewedAt: _date,
                    goal: _reviewGoal.text,
                    progress: _reviewProgress.text,
                    enablingFactors: _reviewEnablers.text,
                    challenges: _reviewChallenges.text,
                    nextSteps: _reviewNextSteps.text,
                  );
                  if (!mounted) return;
                  for (final field in fields) field.$2.clear();
                  setState(() {
                    _reviews = _store.achievementReviewsFor(_championId!);
                    _message = 'Optional review saved only on this device.';
                  });
                }),
          child: const Text('Save optional review'),
        ),
        FutureBuilder<List<GalsAchievementReview>>(
          future: _reviews,
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const SizedBox.shrink();
            if (snapshot.data!.isEmpty)
              return const Text('No optional reviews saved for this champion.');
            return Column(
              children: [
                for (final review in snapshot.data!)
                  Card(
                    child: ListTile(
                      title: Text(review.reviewedAt.substring(0, 10)),
                      subtitle: Text(
                        'Tool: ${review.toolId}\n${review.nextSteps ?? review.progress ?? 'No text recorded'}',
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    ];
  }

  Future<void> _openRecord(
    GalsPackCatalog catalog,
    GalsSharingRecord record,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Saved peer-sharing session'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Session: ${record.session.id}'),
                Text('Occurred: ${record.session.occurredAt}'),
                Text('Saved: ${record.session.createdAt}'),
                for (final group in record.attendance)
                  Text(
                    '${group.count} attendances · ${group.sex} · ${group.ageBand} · ${group.location}',
                  ),
                const Text('Unique people reached: unknown'),
                for (final reference in record.tools) ...[
                  const Divider(),
                  Text(
                    '${reference.packId} · ${reference.contentVersion} · ${reference.toolId}',
                  ),
                  if (catalog.find(reference.packId, reference.contentVersion)
                      case final pack?) ...[
                    Text(
                      pack.tool(reference.toolId)?.title ?? reference.toolId,
                    ),
                    for (final step
                        in pack.tool(reference.toolId)?.steps ?? <GalsStep>[])
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(step.instruction),
                      ),
                    if (record.session.lessonId case final lessonId?) ...[
                      Text(
                        'Lesson: ${pack.lesson(lessonId)?.title ?? lessonId}',
                      ),
                      FutureBuilder(
                        future: _store.completion(
                          championId: record.session.championId,
                          pack: pack,
                          lessonId: lessonId,
                        ),
                        builder: (context, snapshot) {
                          if (snapshot.hasError)
                            return const Text(
                              'Could not retrieve lesson completion.',
                            );
                          if (snapshot.connectionState != ConnectionState.done)
                            return const LinearProgressIndicator();
                          return Text(
                            snapshot.data == null
                                ? 'Lesson completion unavailable.'
                                : 'Completed: ${snapshot.data!.completedAt}\nReflection: ${snapshot.data!.reflection}',
                          );
                        },
                      ),
                    ] else
                      const Text(
                        'Legacy record: lesson completion was not recorded.',
                      ),
                  ] else
                    const Text(
                      'Original content version unavailable. Saved attendance and version reference are retained.',
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    appBar: const StudioAppBar(
      title: 'GALS · draft',
      showBack: true,
      showMenu: false,
    ),
    body: FutureBuilder<GalsPackCatalog>(
      future: _catalog,
      builder: (context, snapshot) {
        if (snapshot.hasError)
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Draft content unavailable.'),
                TextButton(
                  onPressed: () =>
                      setState(() => _catalog = GalsPackCatalog.load()),
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        final catalog = snapshot.data!;
        final pack = catalog.active;
        final lesson =
            pack.lesson(_lessonId ?? pack.lessons.first.id) ??
            pack.lessons.first;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Text(
                    'Original ${pack.status} · ${pack.version} · English · Offline · No audio',
                  ),
                  const Text('Fictional practice data only'),
                  DropdownButtonFormField<String>(
                    key: ValueKey('gals-lesson-${lesson.id}'),
                    initialValue: lesson.id,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Programme lesson or tool',
                    ),
                    items: [
                      for (final item in pack.lessons)
                        DropdownMenuItem(
                          value: item.id,
                          child: Text(item.title),
                        ),
                    ],
                    onChanged: _saving ? null : (id) => _selectLesson(id, pack),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final (index, label) in [
                        '1 Learn',
                        '2 Champion',
                        '3 Peer sharing',
                        '4 Review',
                        '5 Saved',
                      ].indexed)
                        ChoiceChip(
                          label: Text(label),
                          selected: _page == index,
                          onSelected: _saving
                              ? null
                              : (_) => setState(() {
                                  _page = index;
                                  _message = null;
                                }),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (_saving) const LinearProgressIndicator(),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Semantics(liveRegion: true, child: Text(_message!)),
              ),
            Expanded(
              child: SingleChildScrollView(
                key: ValueKey('gals-page-$_page'),
                padding: const EdgeInsets.all(20),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_page != 0) _championPicker(pack, lesson),
                        ...switch (_page) {
                          0 => _learn(
                            pack,
                            lesson,
                            lesson.toolId == null
                                ? null
                                : pack.tool(lesson.toolId!),
                          ),
                          1 => _champion(pack, lesson),
                          2 => _share(pack, lesson),
                          3 => _achievementReview(pack, lesson),
                          _ => _saved(catalog, lesson),
                        },
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}
