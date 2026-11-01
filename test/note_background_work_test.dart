import 'dart:async';

import 'package:ai_connect_africa/services/notes/note_background_work.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'background jobs are serial and a failed job does not block the next',
    () async {
      final queue = NoteBackgroundWork(pause: Duration.zero);
      final release = Completer<void>();
      final order = <String>[];
      final first = queue.run(() async {
        order.add('page');
        await release.future;
        throw StateError('unreadable page');
      });
      final failed = expectLater(first, throwsStateError);
      final second = queue.run(() async => order.add('question'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(order, ['page']);
      release.complete();
      await failed;
      await second;
      expect(order, ['page', 'question']);
    },
  );
}
