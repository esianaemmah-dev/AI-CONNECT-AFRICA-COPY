import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:drift/native.dart';
import 'package:ai_connect_africa/db/otic_database.dart';
import 'package:ai_connect_africa/db/providers/db_provider.dart';
import 'package:ai_connect_africa/collaboration/sync/learner_sync_controller.dart';
import 'package:ai_connect_africa/collaboration/sync/selective_sync_manager.dart';
import 'package:ai_connect_africa/services/notes/note_pdf_store.dart';

class _PausedTransfer extends SelectiveSyncManager {
  _PausedTransfer(super.db, this.response, this.started);
  final Completer<SyncResult> response;
  final Completer<void> started;
  @override
  Future<SyncResult> syncClassEverywhere({required List<TeacherEndpoint> candidates, required ClassGroup group}) {
    started.complete();
    return response.future;
  }
}

void main() {
  test('creating a local profile cannot self-enrol in a class', () async {
    SharedPreferences.setMockInitialValues({});
    final db = OticDatabase.forTesting(NativeDatabase.memory());
    final group = await db.classGroupDao.createClass(className: 'S2');
    final container = ProviderContainer(overrides: [dbProvider.overrideWithValue(db)]);
    try {
      final profiles = container.read(studentNotifierProvider.notifier);
      await expectLater(profiles.addLearner(name: 'Amina', classGroupId: group), throwsStateError);
      expect(await db.select(db.students).get(), isEmpty);
      final id = await profiles.addLearner(name: 'Amina');
      expect((await db.studentDao.getStudentById(id))!.classGroupId, isNull);
      expect(await db.select(db.studentEnrolments).get(), isEmpty);
    } finally { container.dispose(); await db.close(); }
  });
  test('concurrent requests share one transfer and a missing PDF requires retry', () async {
    SharedPreferences.setMockInitialValues({});
    final db = OticDatabase.forTesting(NativeDatabase.memory());
    final dir = await Directory.systemTemp.createTemp('learner_transfer');
    final classId = await db.classGroupDao.createClass(className: 'S2');
    await (db.update(db.classGroups)..where((t) => t.id.equals(classId)))
        .write(const ClassGroupsCompanion(joined: Value(true)));
    final group = (await db.select(db.classGroups).get()).single;
    final id = await db.studentDao.createStudent(StudentsCompanion.insert(name: 'Amina', classGroupId: Value(classId)));
    final student = await db.studentDao.getStudentById(id);
    await db.topicResourceDao.insertChunk(subjectId: 'chemistry', topicKey: kPdfMarkerTopic,
      termMarker: 0, resourceTitle: 'Acids', classGroupUuid: group.groupUuid,
      contentChunk: NotePdf.markerText('a' * 64, 1, 32));
    final response = Completer<SyncResult>();
    final started = Completer<void>();
    var transfers = 0;
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      activeStudentProvider.overrideWith((ref) async => student),
      notePdfStoreProvider.overrideWithValue(NotePdfStore(db, root: () async => dir)),
      learnerSyncProvider.overrideWith((ref) => LearnerSyncController(ref, managerFactory: (db) {
        transfers++;
        return _PausedTransfer(db, response, started);
      })),
    ]);
    try {
      final controller = container.read(learnerSyncProvider);
      await controller.setAddress('127.0.0.1');
      final first = controller.sync(group: group);
      final second = controller.sync(group: group);
      await started.future;
      expect(transfers, 1);
      response.complete(const SyncResult(subjectsChecked: 1, subjectsUpdated: 0,
        chunksInserted: 0, rejected: []));
      await Future.wait([first, second]);
      expect(controller.busy, isFalse);
      expect(controller.phase, LearnerSyncPhase.needsAttention);
      expect(controller.error, contains('PDFs are not on this device'));
    } finally {
      container.dispose(); await db.close(); await dir.delete(recursive: true);
    }
  });
  test('background discovery never joins or changes class membership', () async {
    SharedPreferences.setMockInitialValues({});
    final db = OticDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      activeStudentProvider.overrideWith((ref) async => null),
    ]);
    try {
      final controller = container.read(learnerSyncProvider);
      controller.foreground(false);
      await controller.start();
      expect(controller.discovery, isNull);
      expect(await controller.sync(), isNull);
      expect(await db.select(db.classGroups).get(), isEmpty);
      expect(await db.select(db.studentEnrolments).get(), isEmpty);
      controller.waiting(true);
      controller.restart();
      expect(controller.phase, LearnerSyncPhase.disconnected);
      expect(controller.result, isNull);
      expect(controller.error, isNull);
      expect(controller.endpoints, isEmpty);
    } finally { container.dispose(); await db.close(); }
  });
  test('manual address is persisted and deduplicated without granting access', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(overrides: [
      activeStudentProvider.overrideWith((ref) async => null),
    ]);
    try {
      final controller = container.read(learnerSyncProvider);
      controller.foreground(false);
      await controller.setAddress('192.168.43.1');
      expect(controller.endpoints, hasLength(1));
      expect((await SharedPreferences.getInstance()).getString('class_sync_teacher_address'), '192.168.43.1');
      expect(controller.phase, LearnerSyncPhase.disconnected);
      await controller.setAddress('');
      expect(controller.endpoints, isEmpty);
    } finally { container.dispose(); }
  });
}
