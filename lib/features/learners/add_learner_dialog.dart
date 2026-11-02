import '../admin/admin_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db/otic_database.dart';
import '../../db/providers/db_provider.dart';
import '../../l10n/app_locale.dart';
import '../teacher/class_providers.dart';

/// Asks for a new learner's name, grade and class, creates the profile, and
/// returns its id — or null when cancelled.
///
/// Kept to the fields a teacher can fill in for a whole class quickly. The
/// learner can complete the rest (interests, language) from Settings.
Future<int?> showAddLearnerDialog(
  BuildContext context,
  WidgetRef ref, {
  int? initialClassGroupId,
}) async {
  final result = await showDialog<_NewLearner>(
    context: context,
    builder: (_) => _AddLearnerDialog(initialClassGroupId: initialClassGroupId),
  );
  if (result == null) return null;
  try { return await ref.read(studentNotifierProvider.notifier).addLearner(
        name: result.name,
        grade: result.grade,
        classGroupId: result.classGroupId,
      ); } on StateError {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Ask your class teacher to approve enrolment.')));
    return null;
  }
}

class _NewLearner {
  const _NewLearner(this.name, this.grade, this.classGroupId);
  final String name;
  final String? grade;
  final int? classGroupId;
}

class _AddLearnerDialog extends ConsumerStatefulWidget {
  const _AddLearnerDialog({this.initialClassGroupId});
  final int? initialClassGroupId;

  @override
  ConsumerState<_AddLearnerDialog> createState() => _AddLearnerDialogState();
}

class _AddLearnerDialogState extends ConsumerState<_AddLearnerDialog> {
  final _name = TextEditingController();
  final _grade = TextEditingController();
  late int? _classGroupId = widget.initialClassGroupId;

  @override
  void dispose() {
    _name.dispose();
    _grade.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final grade = _grade.text.trim();
    Navigator.pop(
      context,
      _NewLearner(name, grade.isEmpty ? null : grade, _classGroupId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final admin = ref.watch(adminSessionProvider);
    final classes = admin?.isValid == true
        ? ref.watch(classGroupsProvider).valueOrNull ?? const <ClassGroup>[]
        : ref.watch(classTeacherGroupsProvider).valueOrNull ?? const <ClassGroup>[];
    return AlertDialog(
      title: Text(tr(context, 'Add learner')),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(labelText: tr(context, 'Name')),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _grade,
              decoration: InputDecoration(
                labelText: tr(context, 'Grade (optional)'),
              ),
            ),
            if (classes.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<int?>(
                initialValue: _classGroupId,
                decoration: InputDecoration(labelText: tr(context, 'Class')),
                items: [
                  DropdownMenuItem(
                    value: null,
                    child: Text(tr(context, 'No class')),
                  ),
                  for (final c in classes)
                    DropdownMenuItem(value: c.id, child: Text(classLabel(c))),
                ],
                onChanged: (v) => setState(() => _classGroupId = v),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr(context, 'Cancel')),
        ),
        FilledButton(onPressed: _submit, child: Text(tr(context, 'Add'))),
      ],
    );
  }
}
