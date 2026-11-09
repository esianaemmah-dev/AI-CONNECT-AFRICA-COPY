import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:go_router/go_router.dart';

import '../../ai_core/providers/ai_provider.dart';
import '../../ai_core/online/online_tutor.dart';
import '../../core/app_info_provider.dart';
import '../../curriculum/online_topic_lookup.dart';
import '../../core/theme/app_colors.dart';
import '../../db/otic_database.dart';
import '../../l10n/app_locale.dart';
import '../../shared/widgets/responsive.dart';
import '../../shared/widgets/studio_page.dart';
import '../teacher/class_providers.dart';
import '../teacher/register_learners_screen.dart';
import '../teacher/teacher_pin_screen.dart';
import '../teacher/teacher_profiles.dart';

/// Teachers — the school's teacher devices and everything that manages this
/// one: the teacher tools, the school, learner profiles, learning packages
/// and updates. Replaced the separate Admin dashboard: a school has several
/// teachers (co-teachers, a standby), and they are the ones who manage the
/// devices.
///
/// PIN-gated like the rest of the teacher area, but not role-gated: a
/// student's device has learners to manage too, so the teacher-device
/// sections only appear where they apply.
class TeachersScreen extends ConsumerWidget {
  const TeachersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final packagesAsync = ref.watch(_packagesInstalledProvider);
    final packageInfoAsync = ref.watch(packageInfoProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: StudioAppBar(
        title: tr(context, 'Staff access'),
        subtitle: tr(context, 'Sign in and teach'),
        icon: Icons.groups_rounded,
        iconColor: AppColors.accentBlue,
      ),
      body: MaxWidth(
        maxWidth: 900,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── Teachers ─────────────────────────────────────────────────
            const _SectionTitle('Teachers'),
            const _TeacherDevicesCard(),
            const SizedBox(height: 20),

            // ── Device ───────────────────────────────────────────────────
            const _SectionTitle('Device'),
            _InfoCard(
              children: [
                _InfoRow(
                  icon: Icons.computer,
                  label: 'Platform',
                  value:
                      '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
                ),
                _InfoRow(
                  icon: Icons.apps,
                  label: 'App version',
                  value: packageInfoAsync.when(
                    data: (info) =>
                        'Version ${info.version} (build ${info.buildNumber})',
                    loading: () => 'Loading…',
                    error: (_, __) => 'Unknown',
                  ),
                ),
                const _InfoRow(
                  icon: Icons.wifi_off,
                  label: 'Network',
                  value: 'Offline',
                ),
              ],
            ),
            const SizedBox(height: 20),

            // ── Learning packages ────────────────────────────────────────
            const _SectionTitle('Learning packages'),
            _InfoCard(
              children: [
                CheckboxListTile(
                  value: packagesAsync.valueOrNull ?? false,
                  onChanged: null,
                  title: const Text('Installed'),
                ),
              ],
            ),
            const SizedBox(height: 20),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppColors.primary,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(children: children),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(
        icon,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        size: 20,
      ),
      title: Text(label, style: const TextStyle(fontSize: 13)),
      subtitle: Text(
        value,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).hintColor,
        ),
      ),
    );
  }
}

/// Whether the learning packages (the tutor and the translator) are both
/// installed. Re-checked each time Teachers opens.
final _packagesInstalledProvider = FutureProvider.autoDispose<bool>((ref) async {
  final brain = await ref.watch(modelInfoProvider.future);
  final translator = await ref.watch(translateModelManagerProvider).checkModel();
  return brain.isReady && translator.isReady;
});

/// The teachers who use this device. Signed out: their profiles to sign in
/// to, and adding one. Signed in: what that teacher teaches, the devices
/// their classes work with, and the teacher tools.
class _TeacherDevicesCard extends ConsumerWidget {
  const _TeacherDevicesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(activeTeacherProvider);
    final hint = Theme.of(context).hintColor;
    final chevron = Icon(Icons.chevron_right, color: hint);

    if (me == null) {
      final profiles =
          ref.watch(teacherProfilesProvider).valueOrNull ??
          const <TeacherProfile>[];
      return _InfoCard(
        children: [
          for (final t in profiles)
            ListTile(
              leading: const Icon(Icons.person_rounded),
              title: Text(t.name),
              trailing: chevron,
              onTap: () => _signIn(context, ref, t),
            ),
          if (profiles.isEmpty)
            const ListTile(
              leading: Icon(Icons.info_outline_rounded),
              title: Text('No teachers yet'),
              subtitle: Text('The Admin adds teachers'),
            ),
          ListTile(leading: const Icon(Icons.admin_panel_settings_outlined), title: const Text('Admin sign in'), onTap: () => context.push('/admin')),

        ],
      );
    }

    final owned =
        ref.watch(ownedClassesProvider).valueOrNull ?? const <ClassGroup>[];
    final classTeacherOf =
        ref.watch(myClassTeacherClassesProvider).valueOrNull ??
        const <ClassGroup>[];
    final mine = owned.isEmpty
        ? 'No classes'
        : 'Teaches ${owned.length} ${owned.length == 1 ? 'class' : 'classes'}';

    return Column(
      children: [
        _InfoCard(
          children: [
            ListTile(
              leading: const Icon(Icons.verified_user_rounded),
              title: Text(me.name),
              subtitle: Text(mine),
              trailing: TextButton(
                onPressed: () =>
                    ref.read(activeTeacherProvider.notifier).state = null,
                child: const Text('Sign out'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _InfoCard(
          children: [
            if (classTeacherOf.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.how_to_reg_rounded),
                title: const Text('Register learners'),
                subtitle: Text(classTeacherOf.map(classLabel).join(', ')),
                trailing: chevron,
                onTap: () => context.push('/teacher/register-learners'),
              ),
            for (final (icon, title, path) in const [
              (Icons.groups_outlined, 'Classes & learners', '/teacher'),
              (Icons.route_outlined, 'GALS · draft field tools', '/teacher/gals'),
              (
                Icons.folder_copy_outlined,
                'Lesson materials',
                '/teacher/materials',
              ),
              (
                Icons.assignment_turned_in_outlined,
                'Assignments',
                '/teacher/assignments',
              ),
              (Icons.sync_rounded, 'Sync', '/teacher/sync'),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(title),
                trailing: chevron,
                onTap: () => context.push(path),
              ),
            ListTile(leading: const Icon(Icons.cloud_outlined), title: const Text('School cloud'), onTap: () => context.push('/teachers/cloud')),
            SwitchListTile(
              secondary: const Icon(Icons.travel_explore_rounded),
              title: const Text('Look up topics online'),
              subtitle: const Text(
                'When connected, answer "What is…?" questions no lesson covers '
                'from Wikipedia. Marked as not from the syllabus.',
              ),
              value: ref.watch(onlineTopicLookupEnabledProvider),
              onChanged: (on) =>
                  ref.read(onlineTopicLookupEnabledProvider.notifier).set(on),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.cloud_outlined),
              title: const Text('Online AI tutor'),
              subtitle: const Text(
                'When the school tutor server can be reached, Claude answers '
                'questions. Offline, the AI on this device answers.',
              ),
              value: ref.watch(onlineTutorSettingsProvider).enabled,
              onChanged: (on) =>
                  ref.read(onlineTutorSettingsProvider.notifier).update(enabled: on),
            ),
            if (ref.watch(onlineTutorSettingsProvider).enabled)
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('Tutor server'),
                subtitle: Text(ref.watch(onlineTutorSettingsProvider).url),
                trailing: chevron,
                onTap: () => _editTutorServer(context, ref),
              ),
            ListTile(
              leading: const Icon(Icons.password_rounded),
              title: const Text('My PIN'),
              trailing: chevron,
              onTap: () => _changeMyPin(context, ref, me),
            ),
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('Admin sign in'),
              trailing: chevron,
              onTap: () => context.push('/admin'),
            ),

          ],
        ),
      ],
    );
  }

  Future<void> _signIn(
    BuildContext context,
    WidgetRef ref,
    TeacherProfile teacher,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final pin = await askTeacherPin(context, title: teacher.name);
    if (pin == null) return;
    final signedIn = await ref
        .read(teacherProfileServiceProvider)
        .signIn(teacher.id, pin);
    if (signedIn == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('That PIN is not right.')),
      );
      return;
    }
    ref.read(activeTeacherProvider.notifier).state = signedIn;
  }

  /// The address of the school's tutor server, and its access token if the
  /// server was given one (OTIC_TUTOR_TOKEN).
  Future<void> _editTutorServer(BuildContext context, WidgetRef ref) async {
    final s = ref.read(onlineTutorSettingsProvider);
    final url = TextEditingController(text: s.url);
    final token = TextEditingController(text: s.accessToken);
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tutor server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: url,
              decoration: const InputDecoration(
                labelText: 'Address',
                hintText: OnlineTutorSettings.defaultUrl,
              ),
            ),
            TextField(
              controller: token,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Access token (if any)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (save == true) {
      await ref
          .read(onlineTutorSettingsProvider.notifier)
          .update(url: url.text, accessToken: token.text);
    }
    url.dispose();
    token.dispose();
  }

  Future<void> _changeMyPin(
    BuildContext context,
    WidgetRef ref,
    TeacherProfile me,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final current = await askTeacherPin(context, title: 'Current PIN');
    if (current == null || !context.mounted) return;
    final next = await askTeacherPin(context, title: 'New PIN (4–8 digits)');
    if (next == null || !context.mounted) return;
    final again = await askTeacherPin(context, title: 'New PIN again');
    if (again == null) return;
    if (again != next) {
      messenger.showSnackBar(
        const SnackBar(content: Text('The two PINs did not match.')),
      );
      return;
    }
    final changed = await ref
        .read(teacherProfileServiceProvider)
        .changePin(me.id, current, next);
    messenger.showSnackBar(
      SnackBar(
        content: Text(changed ? 'PIN changed.' : 'That PIN is not right.'),
      ),
    );
  }
}
