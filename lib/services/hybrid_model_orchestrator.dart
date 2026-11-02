import '../ai_core/inference/engine_scheduler.dart';

/// Serializes chat / coder / translator so only one model runs native
/// decode at a time (memory safety on low-RAM devices).
///
/// Every job here is one a learner is waiting on (builders, labs, chat), so
/// it also records when the AI was last used in the foreground. Background
/// work (note quizzes) checks [busy] and [lastActive] and stays out of the
/// way, because llama.cpp can't stop a decode once it has started.
class HybridModelOrchestrator {
  HybridModelOrchestrator._();
  static final HybridModelOrchestrator instance = HybridModelOrchestrator._();

  int _running = 0;
  DateTime? _lastActive;

  /// A foreground job is queued or running.
  bool get busy => _running > 0;

  /// When the last foreground job started or finished.
  DateTime? get lastActive => _lastActive;

  Future<T> runExclusive<T>(Future<T> Function() job) async {
    _running++;
    _lastActive = DateTime.now();
    try {
      return await EngineScheduler.instance.exclusive(
        job,
        lane: EngineLane.hybrid,
      );
    } finally {
      _running--;
      _lastActive = DateTime.now();
    }
  }
}
