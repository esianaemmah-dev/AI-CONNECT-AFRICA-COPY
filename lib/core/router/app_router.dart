import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ai_core/providers/ai_provider.dart';
import '../../ai_core/tutor/programming_topic.dart';
import '../../app.dart';
import '../../db/providers/db_provider.dart';
import '../../features/achievements/achievements_screen.dart';
import '../../features/admin/admin_screen.dart';
import '../../features/admin/admin_service.dart';
import '../../features/assignments/assignments_screens.dart';
import '../../features/notes/my_notes_screen.dart';
import '../../features/notes/note_pdf_screen.dart';
import '../../features/teacher/register_learners_screen.dart';
import '../../features/teachers/cloud_screen.dart';
import '../../features/teachers/teachers_screen.dart';
import '../../features/certificates/certificates_screen.dart';
import '../../features/collaborate/class_sync_screen.dart';
import '../../features/collaborate/classmate_sync_screen.dart';
import '../../features/create/create_screen.dart';
import '../../features/app_dev_lab/app_chat_builder_screen.dart';
import '../../features/app_dev_lab/app_dev_lab_screen.dart';
import '../../features/curriculum_browser/lesson_screen.dart';
import '../../features/python_lab/python_lab_screen.dart';
import '../../features/curriculum_browser/subjects_screen.dart';
import '../../features/curriculum_browser/units_screen.dart';
import '../../features/learn/learn_screen.dart';
import '../../features/learners/learner_picker_screen.dart';
import '../../features/learn/path/path_detail_screen.dart';
import '../../features/onboarding/onboarding_screen.dart';
import '../../features/practice/practice_screen.dart';
import '../../features/projects/projects_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/teacher/lesson_materials_screen.dart';
import '../../features/teacher/teacher_sync_screen.dart';
import '../../features/teacher/teacher_dashboard_screen.dart';
import '../../features/teacher/teacher_pin.dart';
import '../../features/teacher/teacher_pin_screen.dart';
import '../../features/teacher/teacher_profiles.dart';
import '../../features/site_builder/site_chat_builder_screen.dart';
import '../../features/web_dev_lab/web_dev_lab_screen.dart';
import '../../screens/package_fetch_screen.dart';
import '../../shared/widgets/app_shell.dart';

final _rootKey = GlobalKey<NavigatorState>();
final _shellKey = GlobalKey<NavigatorState>();

/// Recovery codes and other staff dialogs must disappear when staff locks.
void dismissStaffOverlays() {
  _rootKey.currentState?.popUntil((route) => route.isFirst);
}

/// The screen navigated to just before this one, so the gate can tell
/// opening Teachers/Admin afresh from the unlock flow returning to it.
String? _lastRouterLocation;

/// Provider-aware router so the redirect can read [hasProfileProvider].
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/',
    redirect: (context, state) async {
      final path = state.uri.path;
      if (path == '/onboarding') return null;

      final onboarding = await _onboardingRedirect(ref, path);
      if (onboarding != null) return onboarding;

      // Opening Teachers or Admin re-asks for the PIN every time: entering
      // from anywhere outside that area re-locks it, so a prior unlock is
      // never reused. The unlock screen navigates back to /teachers itself,
      // so a return from /unlock must not re-lock.
      final prev = _lastRouterLocation;
      _lastRouterLocation = path;
      // Outside the PIN-protected teacher area, the active learner is
      // using the app. Do not carry teacher privileges into learner pages.
      if (!isTeacherRoute(path) && path != '/unlock') {
        ref.read(teacherUnlockedProvider.notifier).state = false;
        ref.read(activeTeacherProvider.notifier).state = null;
      }
      if (path != '/admin') {
        ref.read(adminSessionProvider.notifier).state = null;
      }
      if (path == '/teachers' &&
          prev != '/unlock' &&
          (prev == null || !isTeacherRoute(prev))) {
        ref.read(teacherUnlockedProvider.notifier).state = false;
      }
      if (path == '/admin' && prev != '/admin') {
        ref.read(adminSessionProvider.notifier).state = null;
      }

      // Teachers sits behind the Teachers PIN, when one is set…
      if (!isTeacherRoute(path)) return null;
      return teacherProfileRedirect(
        state.uri,
        signedIn: kIsWeb || (ref.read(activeTeacherProvider) != null && ref.read(teacherProfileServiceProvider).valid(ref.read(activeTeacherProvider)!.id)),
      );
    },
    routes: [
      // Onboarding is outside the shell (no nav bar/sidebar)
      GoRoute(
        path: '/onboarding',
        builder: (_, __) => const OnboardingScreen(),
      ),
      GoRoute(
        path: '/packages',
        builder: (_, __) => const PackageFetchScreen(),
      ),
      ShellRoute(
        navigatorKey: _shellKey,
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          // Home is the AI chat workspace (formerly `/chat`).
          GoRoute(
            path: '/',
            builder: (_, state) {
              final topic = state.uri.queryParameters['topic'];
              final sectionParam = state.uri.queryParameters['section'];
              final subject = state.uri.queryParameters['subject'];
              final section = topic != null || sectionParam == 'learn'
                  ? ChatSection.learn
                  : ChatSection.wholesomeChat;
              final programming =
                  isProgrammingSubjectId(subject) ||
                  looksLikeProgramming(topic ?? '');
              // Skip ModelGate on web only — the browser build can't run a
              // local model at all. Android/Windows/Linux need the AfriSLM GGUF.
              if (kIsWeb) {
                return LearnScreen(
                  initialTopic: topic,
                  section: section,
                  programmingSubject: programming,
                );
              }
              return ModelGate(
                child: LearnScreen(
                  initialTopic: topic,
                  section: section,
                  programmingSubject: programming,
                ),
              );
            },
          ),
          GoRoute(path: '/home', redirect: (_, __) => '/'),
          GoRoute(
            path: '/chat',
            redirect: (_, state) {
              final q = state.uri.query;
              return q.isEmpty ? '/' : '/?$q';
            },
          ),
          GoRoute(path: '/learn', builder: (_, __) => const SubjectsScreen()),
          GoRoute(
            path: '/teacher/materials',
            builder: (_, __) => const LessonMaterialsScreen(),
          ),
          GoRoute(
            path: '/teacher/sync',
            builder: (_, __) => const TeacherSyncScreen(),
          ),
          // Co-teaching and standby screens were removed (2026-10-06).
          GoRoute(path: '/teacher/co-teach', redirect: (_, __) => '/teacher/sync',
          ),
          GoRoute(path: '/teacher/standby', redirect: (_, __) => '/teacher/sync',
          ),
          GoRoute(
            path: '/learn/subject/:id',
            builder: (_, state) =>
                UnitsScreen(
                  subjectId: state.pathParameters['id'] ?? '',
                  initialTab:
                      int.tryParse(state.uri.queryParameters['tab'] ?? '') ?? 0,
                ),
          ),
          GoRoute(
            path: '/learn/subject/:id/lesson/:unit/:lesson',
            builder: (_, state) => LessonScreen(
              subjectId: state.pathParameters['id'] ?? '',
              unitIndex: int.tryParse(state.pathParameters['unit'] ?? '0') ?? 0,
              lessonIndex:
                  int.tryParse(state.pathParameters['lesson'] ?? '0') ?? 0,
            ),
          ),
          GoRoute(
            path: '/path/:topic',
            builder: (_, state) => PathDetailScreen(
              topic: Uri.decodeComponent(state.pathParameters['topic'] ?? ''),
            ),
          ),
          GoRoute(
            path: '/practice',
            builder: (_, __) => const PracticeScreen(),
          ),
          GoRoute(path: '/create', builder: (_, __) => const CreateScreen()),
          GoRoute(path: '/weblab', builder: (_, __) => const WebDevLabScreen()),
          GoRoute(path: '/applab', builder: (_, __) => const AppDevLabScreen()),
          GoRoute(
            path: '/appchat',
            builder: (_, __) => const AppChatBuilderScreen(),
          ),
          GoRoute(path: '/sitebuilder', redirect: (_, __) => '/sitechat'),
          GoRoute(
            path: '/sitechat',
            builder: (_, __) => const SiteChatBuilderScreen(),
          ),
          GoRoute(
            path: '/pythonlab',
            builder: (_, __) => const PythonLabScreen(),
          ),
          GoRoute(
            path: '/projects',
            builder: (_, __) => const ProjectsScreen(),
          ),
          GoRoute(
            path: '/achievements',
            builder: (_, __) => const AchievementsScreen(),
          ),
          GoRoute(
            path: '/my-notes',
            builder: (_, __) => const MyNotesScreen()),
          // Student side of class sync — deliberately outside /teacher*, so
          // no teacher PIN: the join code is what grants access.
          GoRoute(
            path: '/class-sync',
            builder: (_, __) => const ClassSyncScreen(),
          ),
          // Student-to-student note sharing, opened from My notes.
          GoRoute(
            path: '/classmate-sync',
            builder: (_, __) => const ClassmateSyncScreen(),
          ),
          // Removed: every device can teach.
          GoRoute(path: '/teacher-setup', redirect: (_, __) => '/teachers'),
          GoRoute(path: '/student-device', redirect: (_, __) => '/teachers'),
          GoRoute(
            path: '/certificates',
            builder: (_, __) => const CertificatesScreen(),
          ),
          GoRoute(
            path: '/teacher',
            builder: (_, __) => const TeacherDashboardScreen(),
          ),
          GoRoute(
            path: '/teacher/:id',
            builder: (_, state) => TeacherStudentDetailScreen(
              studentId: int.tryParse(state.pathParameters['id'] ?? '') ?? 0,
            ),
          ),
          GoRoute(
            path: '/note-pdf',
            builder: (_, state) => NotePdfScreen(
              sha256: state.uri.queryParameters['sha'] ?? '',
              title: state.uri.queryParameters['title'] ?? '',
              initialPage:
                  int.tryParse(state.uri.queryParameters['page'] ?? '') ?? 0,
            ),
          ),
          GoRoute(
            path: '/teacher/note-pdf',
            builder: (_, state) => NotePdfScreen(
              sha256: state.uri.queryParameters['sha'] ?? '',
              title: state.uri.queryParameters['title'] ?? '',
              initialPage:
                  int.tryParse(state.uri.queryParameters['page'] ?? '') ?? 0,
            ),
          ),
          GoRoute(
            path: '/teachers',
            builder: (_, __) => const TeachersScreen(),
          ),
          // Behind the Teachers PIN; the Admin's parts also need the Admin.
          GoRoute(
            path: '/teachers/cloud',
            builder: (_, __) => const CloudScreen(),
          ),
          GoRoute(
            path: '/admin',
            builder: (_, __) => const AdminScreen()),
          GoRoute(
            path: '/assignments',
            builder: (_, __) => const AssignmentsScreen(),
          ),
          GoRoute(
            path: '/teacher/register-learners',
            builder: (_, __) => const RegisterLearnersScreen(),
          ),
          GoRoute(
            path: '/teacher/assignments',
            builder: (_, __) => const GradeAssignmentsScreen(),
          ),
          GoRoute(
            path: '/settings',
            builder: (_, __) => const SettingsScreen(),
          ),
          GoRoute(
            path: '/learners',
            builder: (_, __) => const LearnerPickerScreen(),
          ),
          GoRoute(
            path: '/unlock',
        redirect: (_, __) => '/teachers',
            builder: (_, state) {
              final to = state.uri.queryParameters['to'] ?? '/teacher';
              // Only ever continue into the gated area, never to an
              // arbitrary location passed in the query string.
              return TeacherUnlockScreen(
                destination: isTeacherRoute(Uri.parse(to).path)
                    ? to
                    : '/teacher',
              );
            },
          ),
        ],
      ),
    ],
  );
});

/// Where to send someone who has not finished onboarding, or null.
Future<String?> _onboardingRedirect(Ref ref, String location) async {
  // Fast path: SharedPreferences is written synchronously by onboarding
  // before it navigates away, so a name here means onboarding is done —
  // no need to wait on the (slower, background-written) database.
  final prefs = await SharedPreferences.getInstance();
  final name = prefs.getString('student_name');
  if (name != null && name.isNotEmpty) return null;

  // The Admin section has its own PIN and needs no learner profile: a
  // staff-only device must reach it before anyone has onboarded.
  if (location == '/admin') return null;

  // On web there's no database — SharedPreferences is authoritative.
  if (kIsWeb) return '/onboarding';

  // Learners the Admin added reached this device, but nobody has picked
  // themselves here yet: ask who is learning rather than opening someone
  // else's profile. Teachers and the Admin can still work.
  if (prefs.getInt(kActiveStudentIdKey) == null &&
      !const ['/learners', '/teachers', '/admin', '/unlock',
      ].contains(location) &&
      !location.startsWith('/teacher')) {
    try {
      final learners = await ref.read(dbProvider).studentDao.getAllStudents();
      if (learners.isNotEmpty) return '/learners';
    } catch (_) {}
  }

  try {
    final hasProfile = await ref
        .read(hasProfileProvider.future)
        .timeout(const Duration(seconds: 3));
    if (!hasProfile) return '/onboarding';
  } catch (_) {
    return '/onboarding';
  }
  return null;
}
