import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../db/otic_database.dart';
import '../../db/providers/db_provider.dart';
import '../../services/custom_subject_service.dart';
import '../../services/notes/note_pdf_store.dart';
import '../../services/offline/offline_readiness.dart';
import '../lan_discovery.dart';
import 'class_crypto.dart';
import 'mdns_discovery.dart';
import 'selective_sync_manager.dart';
import 'sync_address.dart';

enum LearnerSyncPhase {
  disconnected,
  findingTeacher,
  waitingForApproval,
  downloading,
  upToDate,
  needsAttention,
}

/// One foreground discovery/transfer owner shared by every learner page.
class LearnerSyncController extends ChangeNotifier {
  LearnerSyncController(this.ref, {this.managerFactory});
  final Ref ref;
  final SelectiveSyncManager Function(OticDatabase)? managerFactory;
  LanDiscoveryService? discovery;
  MdnsSyncDiscovery? _mdns;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  List<LanPeer> peers = [];
  List<MdnsSyncPeer> mdnsPeers = [];
  String? tag;
  String address = '';
  String? error;
  SyncResult? result;
  LearnerSyncPhase phase = LearnerSyncPhase.disconnected;
  bool _alive = true, _foreground = true, _starting = false;
  int _generation = 0;
  DateTime? _lastAutomatic;
  Future<SyncResult?>? _transfer;
  SelectiveSyncManager? _manager;

  bool get busy => _transfer != null;
  String get status =>
      error ??
      switch (phase) {
        LearnerSyncPhase.disconnected =>
          'Offline — downloaded materials are ready to read',
        LearnerSyncPhase.findingTeacher => 'Finding your teacher',
        LearnerSyncPhase.waitingForApproval => 'Waiting for teacher approval',
        LearnerSyncPhase.downloading => 'Downloading class materials',
        LearnerSyncPhase.upToDate => 'Your class materials are up to date',
        LearnerSyncPhase.needsAttention =>
          'Try getting the latest materials again',
      };
  void _emit() {
    if (_alive) notifyListeners();
  }

  List<TeacherEndpoint> get endpoints {
    final found = <String, TeacherEndpoint>{};
    void add(TeacherEndpoint e) {
      found['${e.address}:${e.port}'] = e;
    }

    for (final p in peers) {
      if (p.isSyncServer && (tag == null || p.schoolTag == tag)) {
        add((address: p.address, port: p.syncPort!));
      }
    }
    for (final p in mdnsPeers) {
      add((address: p.address, port: p.port));
    }
    final manual = parseTeacherAddress(address);
    if (manual != null) add(manual);
    return found.values.toList();
  }

  List<TeacherEndpoint> get classmates => [
    for (final p in peers)
      if (p.isClassmateShare && (tag == null || tag == p.schoolTag))
        (address: p.address, port: p.syncPort!),
  ];

  Future<void> start() async {
    if (!_alive || !_foreground || _starting || discovery != null || kIsWeb)
      return;
    _starting = true;
    final generation = _generation;
    try {
      final learner = await ref.read(activeStudentProvider.future);
      final identity = await ref.read(dbProvider).classSyncDao.identity();
      if (!_alive || !_foreground || generation != _generation) return;
      address =
          (await SharedPreferences.getInstance()).getString(
            'class_sync_teacher_address',
          ) ??
          '';
      if (!_alive || generation != _generation) return;
      tag = schoolTag(identity.schoolId);
      final service = LanDiscoveryService(
        displayName: learner?.name ?? 'Learner',
        schoolTag: tag,
      );
      discovery = service;
      _mdns = MdnsSyncDiscovery();
      phase = LearnerSyncPhase.findingTeacher;
      _emit();
      _subscriptions.add(
        service.peers.listen((list) {
          peers = list;
          _changed();
        }),
      );
      _subscriptions.add(
        _mdns!.peers.listen((list) {
          mdnsPeers = list;
          _changed();
        }),
      );
      await service.start();
      await _mdns!.startDiscovering();
      _changed();
    } catch (_) {
      if (_alive && generation == _generation) {
        phase = LearnerSyncPhase.disconnected;
        _emit();
      }
    } finally {
      if (generation == _generation) _starting = false;
    }
  }

  void _changed() {
    if (!_alive || !_foreground) return;
    _emit();
    if (endpoints.isNotEmpty &&
        !busy &&
        phase != LearnerSyncPhase.waitingForApproval &&
        (_lastAutomatic == null ||
            DateTime.now().difference(_lastAutomatic!) >=
                const Duration(seconds: 30))) {
      _lastAutomatic = DateTime.now();
      unawaited(sync());
    }
  }

  Future<SyncResult?> sync({ClassGroup? group}) {
    if (_transfer != null) return _transfer!;
    final future = _sync(group);
    _transfer = future;
    return future.whenComplete(() {
      _transfer = null;
      _emit();
    });
  }

  Future<SyncResult?> _sync(ClassGroup? group) async {
    final generation = _generation;
    final db = ref.read(dbProvider);
    final learner = await ref.read(activeStudentProvider.future);
    if (group == null && learner?.classGroupId != null) {
      group = await (db.select(
        db.classGroups,
      )..where((t) => t.id.equals(learner!.classGroupId!))).getSingleOrNull();
    }
    if (!_alive ||
        !_foreground ||
        generation != _generation ||
        group == null ||
        !group.joined)
      return null;
    if (endpoints.isEmpty) {
      phase = LearnerSyncPhase.disconnected;
      _emit();
      return null;
    }
    error = null;
    phase = LearnerSyncPhase.downloading;
    _emit();
    final manager = managerFactory?.call(db) ?? SelectiveSyncManager(db);
    _manager = manager;
    try {
      final received = await manager.syncClassEverywhere(
        candidates: endpoints,
        group: group,
      );
      if (!_alive || generation != _generation) return null;
      result = received;
      error = received.error;
      final store = ref.read(notePdfStoreProvider);
      var missing = false;
      for (final pdf in await store.recorded(classUuid: group.groupUuid)) {
        if (!await store.has(pdf.sha256)) missing = true;
      }
      if (!_alive || generation != _generation) return null;
      if (missing && error == null) {
        error = 'Some PDFs are not on this device yet. Get latest materials to resume.';
      }
      phase = received.ok && received.rejected.isEmpty && !missing
          ? LearnerSyncPhase.upToDate
          : LearnerSyncPhase.needsAttention;
      ref.invalidate(customSubjectsProvider);
      ref.invalidate(noteResourcesRevisionProvider);
      ref.invalidate(offlineReadinessProvider(group.id));
      _emit();
      return received;
    } catch (_) {
      if (_alive && generation == _generation) {
        error =
            'Connection interrupted. Your next sync will resume the download.';
        phase = LearnerSyncPhase.needsAttention;
        _emit();
      }
      return null;
    } finally {
      manager.dispose();
      if (identical(_manager, manager)) _manager = null;
    }
  }

  Future<void> setAddress(String value) async {
    address = value;
    if (value.trim().isEmpty || parseTeacherAddress(value) != null) {
      await (await SharedPreferences.getInstance()).setString(
        'class_sync_teacher_address',
        value,
      );
    }
    _emit();
  }

  void waiting(bool value) {
    if (value) {
      phase = LearnerSyncPhase.waitingForApproval;
    } else if (phase == LearnerSyncPhase.waitingForApproval) {
      phase = LearnerSyncPhase.findingTeacher;
    }
    _emit();
  }

  void foreground(bool value) {
    _foreground = value;
    if (value) {
      _lastAutomatic = null;
      unawaited(start());
    } else {
      _stop();
    }
  }

  void restart() {
    _stop();
    _lastAutomatic = null;
    unawaited(start());
  }

  void _stop() {
    _generation++;
    _starting = false;
    _manager?.dispose();
    _manager = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    discovery?.dispose();
    discovery = null;
    unawaited(_mdns?.dispose());
    _mdns = null;
    peers = [];
    mdnsPeers = [];
    result = null;
    error = null;
    phase = LearnerSyncPhase.disconnected;
  }

  @override
  void dispose() {
    _alive = false;
    _stop();
    super.dispose();
  }
}

final learnerSyncProvider = ChangeNotifierProvider<LearnerSyncController>((
  ref,
) {
  final controller = LearnerSyncController(ref);
  ref.listen(activeStudentProvider, (before, after) {
    if (before?.valueOrNull?.id != after.valueOrNull?.id) controller.restart();
  });
  return controller;
});
