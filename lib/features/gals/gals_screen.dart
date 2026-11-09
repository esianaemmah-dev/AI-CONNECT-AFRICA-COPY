import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/widgets/studio_page.dart';
import 'gals_field_store.dart';
import 'gals_pack.dart';

/// A deliberately small staff-facing draft: paper activity + local record.
class GalsScreen extends ConsumerStatefulWidget {
  const GalsScreen({super.key});

  @override
  ConsumerState<GalsScreen> createState() => _GalsScreenState();
}

class _GalsScreenState extends ConsumerState<GalsScreen> {
  late final Future<GalsPack> _pack = GalsPack.load();
  final _name = TextEditingController();
  final _ageBand = TextEditingController();
  final _location = TextEditingController();
  final _count = TextEditingController();
  String? _championId;
  String _sex = 'not_recorded';
  int? _quizAnswer;
  bool _saving = false;
  String? _message;
  int _revision = 0;

  @override
  void dispose() {
    _name.dispose();
    _ageBand.dispose();
    _location.dispose();
    _count.dispose();
    super.dispose();
  }

  Future<void> _addChampion() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final id = await ref.read(galsFieldStoreProvider).addChampion(_name.text);
      if (!mounted) return;
      _name.clear();
      setState(() {
        _championId = id;
        _revision++;
        _message = 'Champion saved on this device.';
      });
    } catch (e) {
      if (mounted) setState(() => _message = 'Could not save champion: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addSharing(GalsPack pack, GalsTool tool) async {
    if (_saving || _championId == null) return;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await ref
          .read(galsFieldStoreProvider)
          .recordSharing(
            championId: _championId!,
            pack: pack,
            toolId: tool.id,
            occurredAt: DateTime.now(),
            sex: _sex,
            ageBand: _ageBand.text,
            location: _location.text,
            attendance: int.tryParse(_count.text) ?? 0,
          );
      if (!mounted) return;
      _count.clear();
      setState(() {
        _revision++;
        _message =
            'Sharing and session attendance saved locally. Unique reach is unknown.';
      });
    } catch (e) {
      if (mounted) setState(() => _message = 'Could not save sharing: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    appBar: const StudioAppBar(
      title: 'GALS · draft',
      showBack: true,
      showMenu: false,
    ),
    body: FutureBuilder<GalsPack>(
      future: _pack,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Draft pack unavailable: ${snapshot.error}'),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final pack = snapshot.data!;
        final tool = pack.tools.first;
        final lesson = pack.lessons.first;
        final question = lesson.quiz.first;
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Draft for Oxfam review · English only · No audio included',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(lesson.title, style: Theme.of(context).textTheme.titleLarge),
            Text(lesson.body),
            const SizedBox(height: 12),
            Text(
              question.question,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Wrap(
              spacing: 8,
              children: [
                for (var i = 0; i < question.choices.length; i++)
                  ChoiceChip(
                    label: Text(question.choices[i]),
                    selected: _quizAnswer == i,
                    onSelected: (_) => setState(() => _quizAnswer = i),
                  ),
              ],
            ),
            if (_quizAnswer != null)
              Text(
                '${_quizAnswer == question.correct ? 'Correct. ' : 'Try again. '}${question.explanation}',
              ),
            const Divider(height: 32),
            Text(tool.title, style: Theme.of(context).textTheme.headlineSmall),
            const Text(
              'Participants draw on paper. Ask questions and let them choose what to share.',
            ),
            for (var i = 0; i < tool.steps.length; i++)
              Card(
                child: ListTile(
                  leading: CircleAvatar(child: Text('${i + 1}')),
                  title: Text(tool.steps[i].instruction),
                  subtitle: const Text(
                    'No reviewed audio playback in this draft',
                  ),
                ),
              ),
            const SizedBox(height: 10),
            const Text(
              'Source credit: Oxfam Uganda and CEFORD GALS guides. Original draft wording; no manual images.',
            ),
            const Divider(height: 36),
            Text(
              'Champion register (this device)',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Champion alias (avoid personal identifiers)',
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _saving ? null : _addChampion,
              child: const Text('Save champion'),
            ),
            FutureBuilder(
              key: ValueKey('champions-$_revision'),
              future: ref.read(galsFieldStoreProvider).champions(),
              builder: (context, snapshot) {
                final people = snapshot.data;
                if (people == null) return const SizedBox.shrink();
                return DropdownButtonFormField<String>(
                  initialValue: people.any((p) => p.id == _championId)
                      ? _championId
                      : null,
                  decoration: const InputDecoration(
                    labelText: 'Sharing by champion',
                  ),
                  items: [
                    for (final p in people)
                      DropdownMenuItem(value: p.id, child: Text(p.displayName)),
                  ],
                  onChanged: (id) => setState(() => _championId = id),
                );
              },
            ),
            const SizedBox(height: 14),
            Text(
              'Record sharing: ${tool.title}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Text(
              'This draft records one aggregate attendance category per event. Attendance is not unique people reached.',
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
                DropdownMenuItem(
                  value: 'not_recorded',
                  child: Text('Not recorded'),
                ),
              ],
              onChanged: (value) =>
                  setState(() => _sex = value ?? 'not_recorded'),
            ),
            TextField(
              controller: _ageBand,
              decoration: const InputDecoration(
                labelText: 'Age band (provisional)',
              ),
            ),
            TextField(
              controller: _location,
              decoration: const InputDecoration(labelText: 'Location'),
            ),
            TextField(
              controller: _count,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Session attendances',
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _saving || _championId == null
                  ? null
                  : () => _addSharing(pack, tool),
              child: const Text('Save sharing on this device'),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_message!),
              ),
            if (_championId != null)
              FutureBuilder(
                key: ValueKey('sharing-$_revision-$_championId'),
                future: ref
                    .read(galsFieldStoreProvider)
                    .sharingFor(_championId!),
                builder: (context, snapshot) {
                  final records = snapshot.data;
                  if (records == null) return const SizedBox.shrink();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Saved sharing events on this device'),
                      for (final record in records)
                        Card(
                          child: ListTile(
                            title: Text(
                              '${record.session.occurredAt.substring(0, 10)} · ${record.tools.map((t) => t.packId == pack.id && t.contentVersion == pack.version && pack.tool(t.toolId) != null ? pack.tool(t.toolId)!.title : '${t.toolId} (pack ${t.contentVersion} unavailable)').join(', ')}',
                            ),
                            subtitle: Text(
                              '${record.sessionAttendances} session attendances · ${record.tools.map((t) => t.contentVersion).join(', ')} · unique people unknown',
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            const SizedBox(height: 60),
          ],
        );
      },
    ),
  );
}
