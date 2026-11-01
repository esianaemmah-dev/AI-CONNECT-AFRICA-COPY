import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// PDF extraction and question generation share one background slot. Small
/// pauses between units leave time for rendering and foreground work.
class NoteBackgroundWork {
  NoteBackgroundWork({this.pause = const Duration(milliseconds: 250)});

  final Duration pause;
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() work) {
    final result = _tail.then((_) async {
      await Future<void>.delayed(pause);
      return work();
    });
    // A failed unit must not poison the queue for other documents.
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}

final noteBackgroundWorkProvider = Provider<NoteBackgroundWork>(
  (ref) => NoteBackgroundWork(),
);
