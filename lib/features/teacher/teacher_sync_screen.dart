import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../collaboration/lan_discovery.dart';
import '../../collaboration/sync/class_crypto.dart';
import '../../collaboration/sync/mdns_discovery.dart';
import '../../collaboration/sync/class_share_server.dart';
import '../../core/theme/app_colors.dart';
import '../../curriculum/curriculum_models.dart';
import '../../services/custom_subject_service.dart';
import '../../db/otic_database.dart';
import '../../db/providers/db_provider.dart';
import '../../shared/widgets/studio_page.dart';
import '../collaborate/join_requests.dart';
import 'class_devices_panel.dart';
import 'class_progress_panel.dart';
import 'class_providers.dart';
import 'teacher_profiles.dart';
import 'co_teacher_widgets.dart' show subjectNames;

/// Shares one class/stream's notes with its students' devices on the same
/// Wi-Fi/hotspot.
///
/// Only students who typed this class's join code can pull anything, and
/// they get only the notes the teacher shared with this class (Lesson
/// materials → Share with classes). Server and discovery start and stop
/// together: a server nobody can find is useless, and announcing one that
/// isn't listening would send students to a dead connection.
class TeacherSyncScreen extends ConsumerStatefulWidget {
  const TeacherSyncScreen({super.key});

  @override
  ConsumerState<TeacherSyncScreen> createState() => _TeacherSyncScreenState();
}

class _TeacherSyncScreenState extends ConsumerState<TeacherSyncScreen> {
  ClassShareServer? _server;
  LanDiscoveryService? _announcer;

  final MdnsSyncDiscovery _mdns = MdnsSyncDiscovery();
  int? _selectedId;
  bool _starting = false;
  String? _error;
  String? _code;
  DateTime? _codeExpires;
  List<String> _subjects = const [];

  static const _codeLife = Duration(minutes: 15);

  bool get _running => _server?.isRunning ?? false;

  /// Repaints while sharing, so a code closed by too many wrong tries (or
  /// expired) shows without the teacher touching anything.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && _running) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _server?.dispose();
    _announcer?.dispose();
    _mdns.dispose();
    super.dispose();
  }

  Future<void> _stop() async {
    await _server?.stop();
    _announcer?.dispose();
    await _mdns.unregisterServer();
    if (!mounted) return;
    setState(() {
      _server = null;
      _announcer = null;
      _code = null;
    });
  }

  Future<void> _start(ClassGroup group, SyncIdentityData identity) async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final db = ref.read(dbProvider);
      final keyed = await db.classSyncDao.ensureClassKey(group);
      final server = ClassShareServer(db,
        teacherId: ref.read(activeTeacherIdProvider),
      );
      final port = await server.start(classUuids: {keyed.groupUuid!});
      final announcer = LanDiscoveryService(
        displayName: 'Teacher · ${classLabel(keyed)}',
        role: 'teacher',
        syncPort: port,
        schoolTag: schoolTag(identity.schoolId),
      );
      await announcer.start();
      // Additive — MdnsSyncDiscovery no-ops on Linux/web (see its doc).
      await _mdns.registerServer(className: classLabel(keyed), port: port);
      final subjects = await db.classSyncDao.sharedSubjects(keyed.groupUuid!);

      if (!mounted) {
        await server.stop();
        announcer.dispose();
        await _mdns.unregisterServer();
        return;
      }
      setState(() {
        _server = server;
        _announcer = announcer;
        _subjects = subjects;
      });
      await _newCode(keyed);
    } catch (e) {
      setState(() => _error = 'Could not start sharing: $e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _newCode(ClassGroup group) async {
    final code = await _server?.openJoinCode(group, ttl: _codeLife);
    if (!mounted) return;
    setState(() {
      _code = code;
      _codeExpires = code == null ? null : DateTime.now().add(_codeLife);
    });
  }

  /// Subjects as the teacher named them ("Web Development"), never their
  /// internal ids ("web_development").
  List<String> _subjectNames(List<String> ids) {
    final names = {
      for (final s
          in ref.watch(mergedSubjectsProvider).valueOrNull ?? const <Subject>[])
        s.id: s.name,
    };
    return [
      for (final id in ids)
        names[id] ??
            id
                .split('_')
                .where((w) => w.isNotEmpty)
                .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
                .join(' '),
    ];
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(activeTeacherProvider, (_, teacher) { if (teacher == null) unawaited(_stop()); });
    final taught = ref.watch(ownedClassesProvider);
    final classTeacher = ref.watch(classTeacherGroupsProvider);
    final classesAsync = taught.whenData(
      (classes) => visibleClassGroups(
        classes,
        classTeacher.valueOrNull ?? const [],
      ).where((c) => !c.joined).toList(),
    );
    final identity = ref.watch(syncIdentityProvider).valueOrNull;
    final ac = AppColors.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: const StudioAppBar(
        title: 'Sync',
        subtitle: 'Share notes with students',
        icon: Icons.sync_rounded,
        iconColor: AppColors.accentTeal,
        showBack: true,
      ),
      body: classesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (classes) {
          if (classes.isEmpty) {
            return ListView(
              padding: const EdgeInsets.all(24),
              children: const [
                Text('No classes yet', textAlign: TextAlign.center),
              ],
            );
          }
          final selected = classes.firstWhere(
            (c) => c.id == _selectedId,
            orElse: () => classes.first,
          );
          final hasSchool = identity?.schoolId != null;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!hasSchool) ...[
                const StudioCard(
                  accent: AppColors.accentOrange,
                  child: Row(
                    children: [
                      Icon(
                        Icons.school_outlined,
                        color: AppColors.accentOrange,
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text('School not set — the Admin sets it'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Text(
                'Class to share with',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: ac.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                initialValue: selected.id,
                items: [
                  for (final c in classes)
                    DropdownMenuItem(value: c.id, child: Text(classLabel(c))),
                ],
                onChanged: _running
                    ? null
                    : (id) => setState(() => _selectedId = id),
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _starting || !hasSchool
                    ? null
                    : () => _running ? _stop() : _start(selected, identity!),
                icon: _starting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        _running
                            ? Icons.stop_rounded
                            : Icons.play_arrow_rounded,
                      ),
                label: Text(
                  _running ? 'Stop' : 'Sync to class'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
              if (_running) ...[
                const SizedBox(height: 20),
                _JoinCodeCard(
                  code: _code,
                  expires: _codeExpires,
                  locked: _server?.joinLocked ?? false,
                  onNewCode: () => _newCode(selected),
                ),
                const SizedBox(height: 12),
                JoinRequestsCard(
                  server: _server!,
                  className: classLabel(selected),
                  subjectName: subjectNames(ref),
                ),
                const SizedBox(height: 12),
                StudioCard(
                  accent: _subjects.isEmpty
                      ? AppColors.accentOrange
                      : AppColors.accentGreen,
                  child: Text(
                    _subjects.isEmpty
                        ? 'No shared notes'
                        : 'Shared: ${_subjectNames(_subjects).join(', ')}',
                    style: TextStyle(color: ac.textPrimary, height: 1.4),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              ClassDevicesPanel(group: selected),
              const SizedBox(height: 20),
              ClassProgressPanel(group: selected),
              if (Platform.isWindows) ...[
                const SizedBox(height: 20),
                Text(
                  'If Windows asks, allow network access.',
                  style: TextStyle(fontSize: 12, color: ac.textSecondary),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _JoinCodeCard extends StatelessWidget {
  const _JoinCodeCard({
    required this.code,
    required this.expires,
    required this.locked,
    required this.onNewCode,
  });

  final String? code;
  final DateTime? expires;
  final bool locked;
  final VoidCallback onNewCode;

  @override
  Widget build(BuildContext context) {
    final ac = AppColors.of(context);
    final until = expires == null
        ? ''
        : ' until ${expires!.hour.toString().padLeft(2, '0')}:'
              '${expires!.minute.toString().padLeft(2, '0')}';
    return StudioCard(
      accent: AppColors.accentTeal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Join code',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: ac.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          if (locked)
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text(
                'Code locked after too many wrong attempts',
                style: TextStyle(color: Colors.red),
              ),
            ),
          if (code != null)
            Row(
              children: [
                SelectableText(
                  code!,
                  style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 4,
                    fontFamily: 'monospace',
                  ),
                ),
                IconButton(
                  tooltip: 'Copy',
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: code!)),
                ),
              ],
            ),
          const SizedBox(height: 4),
          Text(
            'Valid$until',
            style: TextStyle(fontSize: 12, color: ac.textSecondary),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onNewCode,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('New code'),
          ),
        ],
      ),
    );
  }
}
