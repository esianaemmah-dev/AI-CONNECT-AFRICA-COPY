import '../../collaboration/sync/learner_sync_controller.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../collaboration/lan_discovery.dart';
import '../../collaboration/sync/selective_sync_manager.dart';
import '../../collaboration/sync/sync_address.dart';
import '../../core/theme/app_colors.dart';
import '../../db/otic_database.dart';
import '../../db/providers/db_provider.dart';
import '../../l10n/app_locale.dart';
import '../../shared/widgets/responsive.dart';
import '../../shared/widgets/studio_page.dart';
import '../teacher/class_providers.dart';
import 'classmate_share_cards.dart';
import 'offline_readiness_card.dart';

const _manualAddressKey = 'class_sync_teacher_address';

/// The learner's side of class sync: type the teacher's join code once, then
/// tap Sync now to pull the class's shared notes.
///
/// Works on any device on the teacher's Wi-Fi/hotspot — a phone, a PC — and
/// needs no teacher login: the join code and the class key it hands over are
/// what decide who gets notes (see `SelectiveSyncManager`).
///
/// The teacher's device is found automatically when the network allows it.
/// Phone hotspots and some school Wi-Fi block that, so the teacher's address
/// can also be typed in by hand.
class ClassSyncScreen extends ConsumerStatefulWidget {
  const ClassSyncScreen({super.key});

  @override
  ConsumerState<ClassSyncScreen> createState() => _ClassSyncScreenState();
}

class _ClassSyncScreenState extends ConsumerState<ClassSyncScreen> {
  LearnerSyncController get _sync => ref.read(learnerSyncProvider);
  LanDiscoveryService? get _service => _sync.discovery;
  String? get _discoveryNote => _sync.error;
  final _code = TextEditingController();
  final _address = TextEditingController();
  bool _joining = false;
  bool _syncing = false;
  SyncResult? _result;
  String? _syncError;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _code.dispose();
    _address.dispose();

    super.dispose();
  }

  Future<void> _start() async {
    await _sync.start();
    if (mounted) setState(() => _address.text = _sync.address);
  }

  List<TeacherEndpoint> get _endpoints => _sync.endpoints;
  List<TeacherEndpoint> get _classmates => _sync.classmates;

  bool get _addressInvalid =>
      _address.text.trim().isNotEmpty &&
      parseTeacherAddress(_address.text) == null;

  Future<void> _rememberAddress() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final typed = parseTeacherAddress(_address.text);
      if (typed == null) return;
      await prefs.setString(_manualAddressKey, _address.text.trim());
    } catch (_) {}
  }

  Future<void> _join() async {
    if (_code.text.trim().isEmpty || _joining) return;
    if (_addressInvalid) {
      _message('That teacher address doesn’t look right. Try 192.168.43.1');
      return;
    }
    setState(() => _joining = true);
    await _sync.setAddress(_address.text);
    _sync.waiting(true);
    final manager = SelectiveSyncManager(ref.read(dbProvider));
    try {
      final me = await ref.read(activeStudentProvider.future);
      if (me == null) {
        _message('Choose a learner before joining a class.');
        return;
      }
      final result = await manager.joinClass(
        teachers: _endpoints,
        typedCode: _code.text,
        studentId: me.id,
        confirmClass: (name, school, teacher) async {
          if (!mounted ||
              ref.read(activeStudentProvider).valueOrNull?.id != me.id)
            return false;
          return await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Confirm your class'),
                  content: Text('$name\n$school\n$teacher'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Join and download'),
                    ),
                  ],
                ),
              ) ??
              false;
        },
      );
      if (!mounted) return;
      if (!result.ok) {
        _message(result.error!);
        return;
      }
      unawaited(_rememberAddress());
      ref.invalidate(activeStudentProvider);
      if (!mounted) return;
      _code.clear();
      setState(() {
        _result = null;
        _syncError = null;
        _joining = false;
      });
      _message(
        'Joined ${classLabel(result.group!)}'
        '${(result.schoolName ?? '').isEmpty ? '' : ' at ${result.schoolName}'}. '
        'Downloading your class materials.',
      );
      await _syncNow(result.group!);
    } catch (_) {
      if (mounted) _message('Could not finish joining your class. Try again.');
    } finally {
      manager.dispose();
      _sync.waiting(false);
      if (mounted) setState(() => _joining = false);
    }
  }

  /// Syncs with every teacher device found — the class's own teacher and any
  /// co-teachers, each of which only carries its own subjects. Every reply
  /// is checked against keys this device already trusts for the class (the
  /// teacher's, pinned at join, and the co-teachers in its signed roster),
  /// so a wrong or fake device can only fail, never feed this one notes.
  Future<void> _syncNow(ClassGroup group) async {
    if (_addressInvalid) {
      _message('Check the teacher address in Connection help.');
      return;
    }
    setState(() => _syncing = true);
    await _rememberAddress();
    await _sync.setAddress(_address.text);
    final result = await _sync.sync(group: group);
    if (mounted)
      setState(() {
        _syncing = false;
        _result = result;
        _syncError = _sync.error;
      });
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          showCloseIcon: true,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 8),
        ),
      );
  }

  static String _summary(SyncResult r) {
    final reported = r.learnersReported == 0
        ? ''
        : ' Your progress was sent to your teacher.';
    final pdfs = r.pdfsFetched == 0
        ? ''
        : ' ${r.pdfsFetched} PDF${r.pdfsFetched == 1 ? '' : 's'} downloaded.';
    return _notesSummary(r) + pdfs + reported;
  }

  static String _notesSummary(SyncResult r) {
    final s = r.subjectsChecked;
    final subjects = '$s subject${s == 1 ? '' : 's'}';
    if (r.subjectsUpdated == 0 &&
        r.subjectsRemoved == 0 &&
        r.rejected.isEmpty) {
      return 'Up to date — $subjects.';
    }
    final removed = r.subjectsRemoved == 0
        ? ''
        : ', removed ${r.subjectsRemoved} no longer shared';
    final problems = r.rejected.isEmpty
        ? ''
        : ' — ${r.rejected.length} problem${r.rejected.length == 1 ? '' : 's'}, '
              'those kept as they were';
    return 'Updated ${r.subjectsUpdated} of $subjects$removed$problems.';
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(learnerSyncProvider);
    final ac = AppColors.of(context);
    final studentAsync = ref.watch(activeStudentProvider);
    final classes = ref.watch(classGroupsProvider).valueOrNull ?? const [];
    final classId = studentAsync.valueOrNull?.classGroupId;
    ClassGroup? group;
    for (final c in classes) {
      if (c.id == classId) group = c;
    }
    final joined = group != null && group.joined;
    final endpoints = _endpoints;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: StudioAppBar(
        title: tr(context, 'Sync'),
        subtitle: tr(context, 'Class notes'),
        icon: Icons.sync_rounded,
        iconColor: AppColors.accentTeal,
      ),
      body: MaxWidth(
        maxWidth: 760,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(_sync.status),
            if (_sync.busy) const LinearProgressIndicator(),
            if (joined) ...[
              StudioCard(
                accent: AppColors.accentTeal,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'My class: ${classLabel(group)}',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: ac.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      endpoints.isEmpty
                          ? 'Waiting for teacher…'
                          : '${endpoints.length} teacher device'
                                '${endpoints.length == 1 ? '' : 's'} nearby.',
                      style: TextStyle(fontSize: 12, color: ac.textSecondary),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _syncing ? null : () => _syncNow(group!),
                      icon: _syncing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync_rounded, size: 18),
                      label: const Text('Get latest materials'),
                    ),
                    if (_result != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        _summary(_result!),
                        style: TextStyle(
                          fontSize: 12.5,
                          color: ac.textSecondary,
                        ),
                      ),
                    ],
                    if (_syncError != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        _syncError!,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Colors.red,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              OfflineReadinessCard(classId: group.id),
              const SizedBox(height: 16),
              const Text('All materials shared with your class are included.'),
              TextButton.icon(
                onPressed: () => context.push('/my-notes'),
                icon: const Icon(Icons.menu_book_outlined),
                label: const Text('Open my notes'),
              ),

              const SizedBox(height: 16),
              GetFromClassmateCard(
                group: group,
                found: _classmates,
                learnerName: studentAsync.valueOrNull?.name ?? '',
              ),
              const SizedBox(height: 16),
              ShareWithClassmatesCard(group: group, discovery: _service),
              const SizedBox(height: 16),
            ],
            StudioCard(
              accent: AppColors.accentOrange,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    joined ? 'Join a different class' : 'Join your class',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: ac.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _code,
                    textCapitalization: TextCapitalization.characters,
                    style: const TextStyle(
                      letterSpacing: 3,
                      fontWeight: FontWeight.w700,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'K7M4-P9QX',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _join(),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _joining || _code.text.trim().isEmpty
                        ? null
                        : _join,
                    icon: _joining
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.vpn_key_outlined, size: 18),
                    label: Text(
                      _joining ? 'Waiting for approval…' : 'Join class',
                    ),
                  ),
                ],
              ),
            ),
            ExpansionTile(
              title: const Text('Connection help'),
              children: [
                TextField(
                  controller: _address,
                  decoration: const InputDecoration(
                    labelText: 'Teacher address',
                  ),
                  onChanged: (value) => _sync.setAddress(value),
                ),
              ],
            ),
            if (_discoveryNote != null) ...[
              const SizedBox(height: 12),
              Text(
                _discoveryNote!,
                style: TextStyle(fontSize: 12, color: ac.textSecondary),
              ),
            ],
            if (!kIsWeb && Platform.isWindows) ...[
              const SizedBox(height: 16),
              Text(
                'If Windows asks, allow network access.',
                style: TextStyle(fontSize: 12, color: ac.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
