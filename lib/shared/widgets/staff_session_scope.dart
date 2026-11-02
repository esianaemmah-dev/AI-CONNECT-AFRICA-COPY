import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/admin/admin_service.dart';
import '../../features/teacher/teacher_profiles.dart';
import '../../features/teacher/teacher_pin.dart';
import '../../collaboration/sync/learner_sync_controller.dart';
import '../../core/router/app_router.dart';

class StaffSessionScope extends ConsumerStatefulWidget {
  const StaffSessionScope({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<StaffSessionScope> createState() => _StaffSessionScopeState();
}

class _StaffSessionScopeState extends ConsumerState<StaffSessionScope>
    with WidgetsBindingObserver {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _check());
    Future.microtask(() {
      if (mounted) ref.read(learnerSyncProvider).start();
    });
  }

  void _check() {
    final admin = ref.read(adminSessionProvider);
    final teacher = ref.read(activeTeacherProvider);
    if ((admin != null && !admin.isValid) || (teacher != null &&
        !ref.read(teacherProfileServiceProvider).valid(teacher.id))) {
      _lock();
    }
  }

  void _lock() {
    final hadStaff = ref.read(adminSessionProvider) != null ||
        ref.read(activeTeacherProvider) != null;
    ref.read(adminSessionProvider.notifier).state = null;
    ref.read(activeTeacherProvider.notifier).state = null;
    ref.read(teacherUnlockedProvider.notifier).state = false;
    if (hadStaff) {
      dismissStaffOverlays();
      ref.read(appRouterProvider).go('/');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) return;
    final active = state == AppLifecycleState.resumed;
    if (!active) _lock();
    ref.read(learnerSyncProvider).foreground(active);
  }

  void _activity() {
    ref.read(adminSessionProvider)?.lease.touch();
    final teacher = ref.read(activeTeacherProvider);
    if (teacher != null)
      ref.read(teacherProfileServiceProvider).leases[teacher.id]?.touch();
    _check();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      activeTeacherProvider,
      (_, __) => ref.read(appRouterProvider).refresh(),
    );
    final teacher = ref.watch(activeTeacherProvider);
    final admin = ref.watch(adminSessionProvider);
    final content = teacher == null && admin == null
        ? widget.child
        : Column(
            children: [
              Material(
                child: SafeArea(
                  bottom: false,
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      const Icon(Icons.lock_outline),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${teacher?.name ?? admin!.name} · ${teacher == null ? 'Admin' : 'Teacher'} mode',
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          _lock();
                          ref.read(appRouterProvider).go('/');
                        },
                        child: const Text('Return to learner'),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(child: widget.child),
            ],
          );
    return Listener(
      onPointerDown: (_) => _activity(),
      onPointerSignal: (_) => _activity(),
      child: Focus(
        onKeyEvent: (_, __) {
          _activity();
          return KeyEventResult.ignored;
        },
        child: content,
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
