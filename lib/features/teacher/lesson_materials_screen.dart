import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/policy/policy.dart';
import '../../core/theme/app_colors.dart';
import '../../db/daos/topic_resource_dao.dart';
import '../../db/otic_database.dart';
import '../../db/providers/db_provider.dart';
import '../../l10n/app_locale.dart';
import '../../services/custom_subject_service.dart';
import '../../services/notes/note_pdf_store.dart';
import '../../services/notes/note_text_indexer.dart';
import '../../services/offline_storage_service.dart';
import '../../services/resource_import_service.dart';
import '../../services/resource_text_extractor.dart';
import '../../shared/widgets/studio_page.dart';
import '../notes/note_pdf_screen.dart';
import 'class_providers.dart';
import 'resource_labels.dart';
import 'teacher_profiles.dart';
import 'teaching_scope.dart';
import '../assignments/assignments_screens.dart';

/// Where a teacher creates subjects and adds the material they teach from.
///
/// Everything a teacher sees here is a subject, a note and a term. The storage
/// engine, the chunking, and the retrieval index are never named — see
/// [ResourceLabels], which holds every string on this screen and is asserted
/// against [kForbiddenTechnicalTerms] in the tests.
///
/// A teacher sees the subjects the Admin assigned them plus the ones they
/// made here with "Upload a PDF", and changes only the materials they
/// uploaded ([TeachingScope]).
class LessonMaterialsScreen extends ConsumerWidget {
  const LessonMaterialsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final taught = {
      for (final a
          in ref.watch(myAssignmentsProvider).valueOrNull ??
              const <TeachingAssignment>[])
        a.subjectId,
      ...?ref.watch(myOwnSubjectsProvider).valueOrNull,
    };
    final subjectsAsync = ref
        .watch(customSubjectsProvider)
        .whenData(
          (all) => [
            for (final s in all)
              if (s.classGroupUuid == null && taught.contains(s.subjectId)) s,
          ],
        );

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: StudioAppBar(
        title: tr(context, ResourceLabels.workspace),
        subtitle: tr(context, ResourceLabels.workspaceSubtitle),
        icon: Icons.folder_copy_rounded,
        iconColor: AppColors.accentBlue,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _quickUpload(
          context,
          ref,
          subjectsAsync.valueOrNull ?? const <CustomSubject>[],
        ),
        icon: const Icon(Icons.upload_file),
        label: Text(tr(context, ResourceLabels.quickUpload)),
      ),
      body: subjectsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (subjects) {
          if (subjects.isEmpty) {
            return _EmptyState(
              title: tr(context, ResourceLabels.noSubjects),
              hint: tr(context, ResourceLabels.quickUploadHint),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 100),
            children: [
              StudioSectionHeader(
                title: tr(context, ResourceLabels.mySubjects),
              ),
              const SizedBox(height: 12),
              for (final s in subjects)
                _SubjectTile(subject: s, key: ValueKey(s.subjectId)),
            ],
          );
        },
      ),
    );
  }
}

// ── Upload a PDF: pick or name the subject, then upload ─────────────────

/// Asks which subject the files are for — one this teacher already has, or
/// a new one they name, made on the spot and kept as theirs — then runs the
/// same upload as the subject's own Upload button.
Future<void> _quickUpload(
  BuildContext context,
  WidgetRef ref,
  List<CustomSubject> mine,
) async {
  final me = ref.read(activeTeacherIdProvider);
  if (me == null) return;

  // A subject of theirs, or [_newSubject]; null when dismissed.
  final choice = mine.isEmpty
      ? _newSubject
      : await showDialog<Object>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: Text(tr(ctx, ResourceLabels.pickSubject)),
            children: [
              for (final s in mine)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, s),
                  child: Text(s.name),
                ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, _newSubject),
                child: Text(
                  tr(ctx, ResourceLabels.newSubjectOption),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        );
  if (choice == null || !context.mounted) return;

  var subject = choice is CustomSubject ? choice : null;
  if (subject == null) {
    final name = await _askSubjectName(context);
    if (name == null || !context.mounted) return;
    final created = await ref
        .read(customSubjectServiceProvider)
        .create(name: name);
    if (!context.mounted) return;
    if (!created.ok) {
      _toast(context, tr(context, created.error ?? ''));
      return;
    }
    await ref
        .read(teachingScopeProvider)
        .recordOwnSubject(me, created.subjectId!);
    ref.invalidate(customSubjectsProvider);
    ref.invalidate(mergedSubjectsProvider);
    subject = await ref
        .read(dbProvider)
        .customSubjectDao
        .bySubjectId(created.subjectId!);
    if (subject == null || !context.mounted) return;
    _toast(context, tr(context, ResourceLabels.subjectCreated));
  }

  await _Upload(subject)._addFromFile(context, ref);
}

/// "New subject…" in [_quickUpload]'s picker.
const _newSubject = Object();

/// [_SubjectActions] for a subject with no tile on screen yet.
class _Upload with _SubjectActions {
  _Upload(this.subject);

  @override
  final CustomSubject subject;
}

Future<String?> _askSubjectName(BuildContext context) async {
  final ctl = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr(ctx, ResourceLabels.newSubject)),
      content: TextField(
        controller: ctl,
        autofocus: true,
        decoration: InputDecoration(
          labelText: tr(ctx, ResourceLabels.subjectName),
          hintText: tr(ctx, ResourceLabels.subjectNameHint),
        ),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(tr(ctx, ResourceLabels.cancel)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctl.text),
          child: Text(tr(ctx, ResourceLabels.createSubject)),
        ),
      ],
    ),
  );
  ctl.dispose();
  final trimmed = name?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

class _SubjectTile extends ConsumerWidget with _SubjectActions {
  const _SubjectTile({required this.subject, super.key});

  @override
  final CustomSubject subject;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resources = ref.watch(topicResourcesProvider(subject.subjectId));
    final pdfs =
        ref.watch(ownNotePdfsProvider(subject.subjectId)).valueOrNull ??
        const <String, NotePdf>{};
    final shares =
        ref.watch(noteSharesProvider(subject.subjectId)).valueOrNull ??
        const {};
    final reach =
        ref.watch(noteReachProvider(subject.subjectId)).valueOrNull ??
        const <String, int>{};
    final reading = ref.watch(noteReadingProvider);
    final me = ref.watch(activeTeacherIdProvider);
    final owners =
        ref.watch(noteOwnersProvider(subject.subjectId)).valueOrNull ??
        const <String, int>{};
    // Where this subject's notes may go: the classes this teacher teaches
    // this subject to.
    final teachesTo = {
      for (final a
          in ref.watch(myAssignmentsProvider).valueOrNull ??
              const <TeachingAssignment>[])
        if (a.subjectId == subject.subjectId) a.classGroupUuid,
    };
    final classes = <({String uuid, String label})>[
      for (final c
          in ref.watch(ownedClassesProvider).valueOrNull ??
              const <ClassGroup>[])
        if (teachesTo.contains(c.groupUuid))
          (uuid: c.groupUuid!, label: classLabel(c)),
    ];
    final classNames = <String?, String>{
      for (final c in classes) c.uuid: c.label,
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        leading: const Icon(Icons.menu_book_rounded),
        title: Text(
          subject.name,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: resources.maybeWhen(
          data: (list) => Text(
            list.isEmpty
                ? tr(context, ResourceLabels.noResources)
                : '${list.length}',
          ),
          orElse: () => null,
        ),
        children: [
          resources.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(16),
              child: LinearProgressIndicator(),
            ),
            error: (e, _) =>
                Padding(padding: const EdgeInsets.all(16), child: Text('$e')),
            data: (list) => Column(
              children: [
                // Only this teacher's notes, and any nobody owns.
                for (final r in list)
                  if ((owners[r.resourceTitle] ?? me) == me)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.description_outlined, size: 20),
                      title: Text(r.resourceTitle),
                      subtitle: Text(
                        [
                          ResourceLabels.termLabel(context, r.termMarker),
                          _sharedWith(
                            context,
                            shares[r.resourceTitle],
                            classNames,
                          ),
                          ?_onDevices(context, shares[r.resourceTitle], reach),
                          ?_status(
                            context,
                            r,
                            reading[NoteTextIndexer.noteKey(
                              subject.subjectId,
                              r.resourceTitle,
                            )],
                            hasPdf: pdfs.containsKey(r.resourceTitle),
                          ),
                        ].join(' · '),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (pdfs[r.resourceTitle] case final pdf?)
                            IconButton(
                              tooltip: tr(context, 'Open the PDF'),
                              icon: const Icon(Icons.picture_as_pdf_outlined),
                              onPressed: () => openNotePdf(context, pdf),
                            ),
                          IconButton(
                            tooltip: tr(context, 'Share with classes'),
                            icon: Icon(
                              (shares[r.resourceTitle] ?? const {}).isEmpty
                                  ? Icons.group_add_outlined
                                  : Icons.groups_rounded,
                            ),
                            onPressed: () => _share(
                              context,
                              ref,
                              r,
                              classes,
                              shares[r.resourceTitle] ?? const {},
                            ),
                          ),
                          IconButton(
                            tooltip: tr(context, ResourceLabels.removeResource),
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _remove(context, ref, r),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => _addFromFile(context, ref),
                  icon: const Icon(Icons.upload_file, size: 18),
                  label: Text(tr(context, ResourceLabels.uploadFile)),
                ),
                OutlinedButton.icon(
                  onPressed: () => _addTyped(context, ref),
                  icon: const Icon(Icons.edit_note, size: 18),
                  label: Text(tr(context, ResourceLabels.typeNotes)),
                ),
                OutlinedButton.icon(
                  onPressed: () => _addAssignment(context, ref),
                  icon: const Icon(Icons.assignment_add, size: 18),
                  label: Text(tr(context, 'New assignment')),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// One subject's material actions, for its tile and for "Upload a PDF".
mixin _SubjectActions {
  CustomSubject get subject;

  void _refresh(WidgetRef ref) {
    ref.invalidate(topicResourcesProvider(subject.subjectId));
    ref.invalidate(ownNotePdfsProvider(subject.subjectId));
    // A deleted note's PDF goes with it.
    unawaited(ref.read(notePdfStoreProvider).collectGarbage());
    ref.invalidate(customSubjectsProvider);
    ref.invalidate(mergedSubjectsProvider);
    ref.invalidate(subjectByIdProvider(subject.subjectId));
  }

  /// Whether the signed-in teacher teaches this subject (to upload), or
  /// also uploaded [documentTitle] (to change or share it); tells them when
  /// not. Every change checks this.
  Future<bool> _mine(
    BuildContext context,
    WidgetRef ref, [
    String? documentTitle,
  ]) async {
    final ok = await ref
        .read(policyProvider)
        .can(
          TeacherActor(ref.read(activeTeacherIdProvider)),
          documentTitle == null
              ? UploadNote(subject.subjectId)
              : ChangeNote(subject.subjectId, documentTitle),
        );
    if (!ok && context.mounted) {
      _toast(context, tr(context, ResourceLabels.notYours));
    }
    return ok;
  }

  /// Records the signed-in teacher as the uploader of [documentTitle].
  Future<void> _own(WidgetRef ref, String documentTitle) async {
    final me = ref.read(activeTeacherIdProvider);
    if (me == null) return;
    await ref
        .read(teachingScopeProvider)
        .recordOwner(subject.subjectId, documentTitle, me);
  }

  /// Adds one or more files to this subject. A PDF is saved at once —
  /// students can open it straight away — and its pages are read in the
  /// background; other files are quick to read and are read now.
  Future<void> _addFromFile(BuildContext context, WidgetRef ref) async {
    if (!await _mine(context, ref) || !context.mounted) return;
    final term = await _askTerm(context);
    if (term == null || !context.mounted) return;

    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: tr(context, ResourceLabels.uploadFile),
      type: FileType.custom,
      allowedExtensions: kSupportedResourceExtensions,
      allowMultiple: true,
    );
    final paths = [
      for (final f in picked?.files ?? const <PlatformFile>[])
        if (f.path != null) f.path!,
    ];
    if (paths.isEmpty || !context.mounted) return;

    // A file named like a note already here is added beside it, never
    // over it.
    final taken = {
      for (final r in await ref.read(
        topicResourcesProvider(subject.subjectId).future,
      ))
        r.resourceTitle.toLowerCase(),
    };
    String uniqueTitle(String path) {
      final base = stripFileExtension(path.split(RegExp(r'[/\\]')).last);
      var title = base;
      for (var n = 2; taken.contains(title.toLowerCase()); n++) {
        title = '$base ($n)';
      }
      taken.add(title.toLowerCase());
      return title;
    }

    if (!context.mounted) return;
    final progress = ValueNotifier<(int, int)>((0, 0));
    final file = ValueNotifier<String>('');
    final cancelling = ValueNotifier<bool>(false);
    final navigator = Navigator.of(context, rootNavigator: true);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _ReadingDialog(
          progress: progress,
          file: file,
          cancelling: cancelling,
        ),
      ),
    );

    final reports = <ImportReport>[];
    try {
      for (var i = 0; i < paths.length; i++) {
        if (cancelling.value) break;
        final title = uniqueTitle(paths[i]);
        if (paths.length > 1 && context.mounted) {
          file.value = trFill(context, ResourceLabels.fileOfFiles, {
            'n': '${i + 1}',
            'total': '${paths.length}',
            'title': title,
          });
        }
        progress.value = (0, 0);
        reports.add(
          await ref
              .read(resourceImportServiceProvider)
              .importFile(
                path: paths[i],
                subjectId: subject.subjectId,
                termMarker: term,
                documentTitle: title,
                onProgress: (done, total) =>
                    progress.value = (done < total ? done + 1 : total, total),
                isCancelled: () => cancelling.value,
              ),
        );
      }
    } finally {
      navigator.pop();
      progress.dispose();
      file.dispose();
      cancelling.dispose();
    }
    _refresh(ref);
    if (!context.mounted) return;

    final added = reports.where((r) => r.ok).toList();
    for (final r in added) {
      await _own(ref, r.documentTitle);
    }
    if (!context.mounted) return;
    final failed = reports.where((r) => !r.ok && !r.cancelled).toList();
    if (failed.isNotEmpty) {
      _showFailure(
        context,
        failed.length == 1 && reports.length == 1
            ? failed.single.failure ?? ''
            : [
                for (final r in failed) '${r.fileName}: ${r.failure ?? ''}',
              ].join('\n\n'),
      );
    }
    if (added.isEmpty) {
      if (failed.isEmpty) {
        final cancelled = reports.where((r) => r.cancelled);
        if (cancelled.isNotEmpty) {
          _toast(context, cancelled.first.failure ?? '');
        }
      }
      return;
    }
    final available = await ref.read(ownedClassesProvider.future);
    final assignments = await ref.read(myAssignmentsProvider.future);
    final allowed = {
      for (final a in assignments)
        if (a.subjectId == subject.subjectId) a.classGroupUuid,
    };
    final classes = [
      for (final c in available)
        if (allowed.contains(c.groupUuid))
          (uuid: c.groupUuid!, label: classLabel(c)),
    ];
    // Shared at once with every class this teacher teaches the subject to,
    // so learners there get it on their next sync (every 30 s while
    // connected) — the PDF opens right away; its text and quizzes follow
    // as the background reader gets through it. Untick classes later with
    // Share with classes.
    final sharedWith = classes.isEmpty
        ? const <String>[]
        : await _shareWithAll(
            ref,
            [for (final r in added) r.documentTitle],
            classes,
          );
    if (!context.mounted) return;
    final shareLine = classes.isEmpty
        ? tr(
            context,
            'Only on this device until the Admin assigns you this subject '
            'for a class',
          )
        : sharedWith.isEmpty
        ? null
        : trFill(context, 'Shared with {classes}', {
            'classes': sharedWith.join(', '),
          });
    if (!context.mounted) return;
    if (added.length > 1) {
      _toast(
        context,
        [
          trFill(context, ResourceLabels.filesAdded, {
            'count': '${added.length}',
          }),
          ?shareLine,
        ].join(' · '),
      );
      return;
    }
    final report = added.single;
    // Name the file the teacher added — never how it was split inside.
    final details = [
      if (report.ocrPages > 0)
        trFill(context, ResourceLabels.pagesScanned, {
          'count': '${report.ocrPages}',
        }),
      if (report.diagramCount > 0)
        trFill(context, ResourceLabels.diagramsMarked, {
          'count': '${report.diagramCount}',
        }),
      if (report.unreadablePages > 0)
        trFill(context, ResourceLabels.pagesUnreadable, {
          'count': '${report.unreadablePages}',
        }),
      if (report.format == 'pdf' && !report.keptOriginal)
        tr(context, 'Text only — PDF too large to keep'),
      ?shareLine,
    ];
    _toast(
      context,
      [
        trFill(context, ResourceLabels.fileAdded, {
          'title': report.documentTitle,
        }),
        ...details,
      ].join(' · '),
    );
  }

  /// An assignment travels like a note: share it with classes to send it.
  Future<void> _addAssignment(BuildContext context, WidgetRef ref) async {
    if (!await _mine(context, ref) || !context.mounted) return;
    final title = await showNewAssignmentDialog(
      context,
      ref,
      subject.subjectId,
    );
    if (title == null) return;
    await _own(ref, title);
    _refresh(ref);
  }

  Future<void> _addTyped(BuildContext context, WidgetRef ref) async {
    if (!await _mine(context, ref) || !context.mounted) return;
    final titleCtl = TextEditingController();
    final bodyCtl = TextEditingController();

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, ResourceLabels.addNote)),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: tr(ctx, ResourceLabels.noteTitle),
                  hintText: tr(ctx, ResourceLabels.noteTitleHint),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: bodyCtl,
                minLines: 5,
                maxLines: 12,
                decoration: InputDecoration(
                  labelText: tr(ctx, ResourceLabels.noteContent),
                  hintText: tr(ctx, ResourceLabels.noteContentHint),
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr(ctx, ResourceLabels.cancel)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr(ctx, ResourceLabels.saveNote)),
          ),
        ],
      ),
    );

    final title = titleCtl.text;
    final body = bodyCtl.text;
    titleCtl.dispose();
    bodyCtl.dispose();
    if (saved != true || !context.mounted) return;

    final term = await _askTerm(context);
    if (term == null || !context.mounted) return;

    final report = await ref
        .read(resourceImportServiceProvider)
        .importText(
          title: title,
          content: body,
          subjectId: subject.subjectId,
          termMarker: term,
        );
    if (!context.mounted) return;

    if (!report.ok) {
      _showFailure(context, report.failure ?? '');
      return;
    }
    await _own(ref, report.documentTitle);
    _refresh(ref);
    if (!context.mounted) return;
    _toast(context, tr(context, ResourceLabels.noteSaved));
  }

  /// Pages still being read, questions written, or that nothing could be
  /// read; null when there is nothing to say.
  String? _status(
    BuildContext context,
    ResourceSummary r,
    (int, int)? reading, {
    required bool hasPdf,
  }) {
    if (reading != null) {
      return trFill(context, ResourceLabels.readingPages, {
        'done': '${reading.$1}',
        'total': '${reading.$2}',
      });
    }
    if (hasPdf && r.textCount == 0) {
      return tr(context, ResourceLabels.noReadableText);
    }
    if (r.quizCount > 0) {
      return trFill(context, ResourceLabels.questionsReady, {
        'count': '${r.quizCount}',
      });
    }
    return null;
  }

  /// How many devices hold this note as it is now, across the classes this
  /// device owns that it is shared with; null when there are none.
  String? _onDevices(
    BuildContext context,
    Set<String>? uuids,
    Map<String, int> reach,
  ) {
    final counted = uuids?.where(reach.containsKey) ?? const <String>[];
    if (counted.isEmpty) return null;
    final n = counted.fold(0, (sum, u) => sum + reach[u]!);
    return switch (n) {
      0 => tr(context, 'Only on this device'),
      1 => tr(context, 'On 1 device'),
      _ => trFill(context, 'On {n} devices', {'n': '$n'}),
    };
  }

  String _sharedWith(
    BuildContext context,
    Set<String>? uuids,
    Map<String?, String> classNames,
  ) {
    final names = [
      for (final u in uuids ?? const <String>{})
        if (classNames[u] != null) classNames[u]!,
    ]..sort();
    return names.isEmpty
        ? tr(context, 'Not shared with any class')
        : trFill(context, 'Shared with {classes}', {
            'classes': names.join(', '),
          });
  }

  /// Which classes/streams receive this note when they sync. Only this
  /// subject's note goes, only to the ticked classes.
  /// Shares each of [documentTitles] with every class in [classes] the
  /// signed-in teacher may share it into ([Policy] still decides). Returns
  /// the labels of the classes it went to.
  Future<List<String>> _shareWithAll(
    WidgetRef ref,
    List<String> documentTitles,
    List<({String uuid, String label})> classes,
  ) async {
    final policy = ref.read(policyProvider);
    final me = TeacherActor(ref.read(activeTeacherIdProvider));
    final dao = ref.read(dbProvider).classSyncDao;
    final reached = <String>{};
    for (final title in documentTitles) {
      final to = <String>{
        for (final c in classes)
          if (await policy.can(me, ShareNote(subject.subjectId, title, c.uuid)))
            c.uuid,
      };
      if (to.isEmpty) continue;
      await dao.setShares(
        subjectId: subject.subjectId,
        documentTitle: title,
        classUuids: to,
      );
      reached.addAll(to);
    }
    return [
      for (final c in classes)
        if (reached.contains(c.uuid)) c.label,
    ];
  }

  Future<void> _share(
    BuildContext context,
    WidgetRef ref,
    ResourceSummary resource,
    List<({String uuid, String label})> classes,
    Set<String> current,
  ) async {
    if (classes.isEmpty) {
      _toast(context, tr(context, 'No classes assigned for this subject'));
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString('last_shared_class_${subject.subjectId}');
    final initial = current.isNotEmpty
        ? current
        : {if (classes.any((c) => c.uuid == last)) last!};
    if (!context.mounted) return;
    final chosen = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) {
        final picked = {...initial};
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: Text(
              trFill(ctx, 'Share “{title}” with', {
                'title': resource.resourceTitle,
              }),
            ),
            content: SizedBox(
              width: 380,
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final c in classes)
                    CheckboxListTile(
                      value: picked.contains(c.uuid),
                      title: Text(c.label),
                      onChanged: (on) => setState(
                        () => on == true
                            ? picked.add(c.uuid)
                            : picked.remove(c.uuid),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr(ctx, ResourceLabels.cancel)),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, picked),
                child: Text(tr(ctx, 'Save')),
              ),
            ],
          ),
        );
      },
    );
    if (chosen == null || !context.mounted) return;
    if (chosen.isNotEmpty)
      await prefs.setString(
        'last_shared_class_${subject.subjectId}',
        chosen.first,
      );
    if (!context.mounted) return;
    if (!await _mine(context, ref, resource.resourceTitle)) return;
    final policy = ref.read(policyProvider);
    final me = TeacherActor(ref.read(activeTeacherIdProvider));
    for (final uuid in chosen) {
      if (!await policy.can(
        me,
        ShareNote(subject.subjectId, resource.resourceTitle, uuid),
      )) {
        if (context.mounted) {
          _toast(context, tr(context, ResourceLabels.notYours));
        }
        return;
      }
    }
    await ref
        .read(dbProvider)
        .classSyncDao
        .setShares(
          subjectId: subject.subjectId,
          documentTitle: resource.resourceTitle,
          classUuids: chosen,
        );
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    ResourceSummary resource,
  ) async {
    final confirmed = await _confirm(
      context,
      tr(context, ResourceLabels.removeConfirm),
      tr(context, ResourceLabels.removeResource),
    );
    if (!confirmed || !context.mounted) return;
    if (!await _mine(context, ref, resource.resourceTitle) ||
        !context.mounted) {
      return;
    }

    final removed = await ref
        .read(offlineStorageServiceProvider)
        .deleteTopicResourceByTitle(
          resource.resourceTitle,
          subjectId: subject.subjectId,
        );
    await ref
        .read(teachingScopeProvider)
        .forgetOwner(subject.subjectId, resource.resourceTitle);
    if (!context.mounted) return;

    _refresh(ref);
    _toast(
      context,
      tr(
        context,
        removed > 0
            ? ResourceLabels.noteRemoved
            : ResourceLabels.nothingToRemove,
      ),
    );
  }

  /// Which term this material belongs to — the Term Core Tracker.
  Future<int?> _askTerm(BuildContext context) {
    return showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr(ctx, ResourceLabels.termTracker)),
        children: [
          for (final marker in ResourceLabels.termOptions)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, marker),
              child: Text(ResourceLabels.termLabel(ctx, marker)),
            ),
        ],
      ),
    );
  }
}

// ── Small shared pieces ──────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_open_rounded,
              size: 48,
              color: Theme.of(context).hintColor,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            if (hint.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

void _toast(BuildContext context, String message) {
  if (message.isEmpty) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
}

/// Page-by-page progress while a file is read; a scanned book takes minutes.
class _ReadingDialog extends StatelessWidget {
  const _ReadingDialog({
    required this.progress,
    required this.file,
    required this.cancelling,
  });

  final ValueNotifier<(int, int)> progress;

  /// "File 2 of 5: …" when several files are added; '' for one.
  final ValueNotifier<String> file;
  final ValueNotifier<bool> cancelling;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(tr(context, ResourceLabels.reading)),
        content: ValueListenableBuilder<(int, int)>(
          valueListenable: progress,
          builder: (context, value, _) {
            final (page, total) = value;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ValueListenableBuilder<String>(
                  valueListenable: file,
                  builder: (context, name, _) => name.isEmpty
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(name),
                        ),
                ),
                LinearProgressIndicator(
                  value: total == 0 ? null : page / total,
                ),
                if (total > 0) ...[
                  const SizedBox(height: 12),
                  Text(
                    trFill(context, ResourceLabels.readingPage, {
                      'page': '$page',
                      'total': '$total',
                    }),
                  ),
                ],
              ],
            );
          },
        ),
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: cancelling,
            builder: (context, stopping, _) => TextButton(
              onPressed: stopping ? null : () => cancelling.value = true,
              child: Text(
                tr(
                  context,
                  stopping ? ResourceLabels.cancelling : ResourceLabels.cancel,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A failure a teacher needs to read and act on, so it gets a dialog rather
/// than a snack bar that disappears while they are still reading it.
void _showFailure(BuildContext context, String reason) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.error_outline),
      title: Text(tr(ctx, ResourceLabels.readFailed)),
      content: Text(reason),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

Future<bool> _confirm(
  BuildContext context,
  String message,
  String confirmLabel,
) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(tr(ctx, ResourceLabels.cancel)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
