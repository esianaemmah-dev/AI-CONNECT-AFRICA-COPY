import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../db/daos/class_group_dao.dart';
import '../../db/otic_database.dart';
import '../../db/providers/db_provider.dart';
import '../../shared/widgets/responsive.dart';
import '../../shared/widgets/studio_page.dart';
import 'class_providers.dart';

String _shortWhen(DateTime dt) {
  final local = dt.toLocal();
  final m = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  final h = local.hour.toString().padLeft(2, '0');
  final min = local.minute.toString().padLeft(2, '0');
  return '$m/$d $h:$min';
}

/// Which learners the dashboard is showing.
sealed class _Filter {
  const _Filter();
  bool includes(Student s);
}

/// The learners of every class this teacher teaches.
class _AllLearners extends _Filter {
  const _AllLearners([this.classIds = const {}]);
  final Set<int> classIds;
  @override
  bool includes(Student s) => classIds.contains(s.classGroupId);
}

class _InClass extends _Filter {
  const _InClass(this.group);
  final ClassGroup group;
  @override
  bool includes(Student s) => s.classGroupId == group.id;
}

/// Classes, streams and every learner's progress, for teachers on a shared
/// device.
///
/// Progress is read live from `topic_progress` (see [learnerStatsProvider]);
/// the class numbers are computed here from the learner rows on screen, so
/// the summary and the list below it can never disagree.
class TeacherDashboardScreen extends ConsumerStatefulWidget {
  const TeacherDashboardScreen({super.key});

  @override
  ConsumerState<TeacherDashboardScreen> createState() =>
      _TeacherDashboardScreenState();
}

class _TeacherDashboardScreenState
    extends ConsumerState<TeacherDashboardScreen> {
  _Filter _filter = const _AllLearners();

  @override
  Widget build(BuildContext context) {
    final learnersAsync = ref.watch(allLearnersProvider);
    // Classes this teacher may see: the subjects they teach, plus any stream
    // they are Class Teacher of. Every class still labels its learners.
    final classes = visibleClassGroups(
      ref.watch(myClassGroupsProvider).valueOrNull ?? const <ClassGroup>[],
      ref.watch(classTeacherGroupsProvider).valueOrNull ?? const <ClassGroup>[],
    );
    final allClasses =
        ref.watch(classGroupsProvider).valueOrNull ?? const <ClassGroup>[];
    final stats =
        ref.watch(learnerStatsProvider).valueOrNull ??
        const <int, LearnerStats>{};
    final classById = {for (final c in allClasses) c.id: c};
    final mine = {for (final c in classes) c.id};

    // A class deleted or renamed elsewhere must not leave the filter holding
    // a stale row.
    final _Filter filter = switch (_filter) {
      _InClass(:final group) when mine.contains(group.id) => _InClass(
        classById[group.id]!,
      ),
      _ => _AllLearners(mine),
    };

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: StudioAppBar(
        title: 'Teacher',
        subtitle: 'Classes, learners and progress',
        icon: Icons.groups_rounded,
        iconColor: AppColors.accentBlue,
        actions: [
          StudioHeaderIconButton(
            tooltip: 'Subjects & lesson materials',
            icon: Icons.folder_copy_rounded,
            onTap: () => context.push('/teacher/materials'),
          ),
          const SizedBox(width: 8),
          StudioHeaderIconButton(
            tooltip: 'Sync class material to student devices',
            icon: Icons.sync_rounded,
            onTap: () => context.push('/teacher/sync'),
          ),
          const SizedBox(width: 8),
          StudioHeaderIconButton(
            tooltip: 'Switch learner',
            icon: Icons.switch_account_rounded,
            onTap: () => context.push('/learners'),
          ),
          const SizedBox(width: 8),
          StudioHeaderIconButton(
            tooltip: 'Account & PIN',
            icon: Icons.lock_rounded,
            onTap: () => context.push('/teachers'),
          ),
        ],
      ),
      body: MaxWidth(
        maxWidth: 900,
        child: learnersAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Could not load learners: $e')),
          data: (learners) {
            final shown = learners.where(filter.includes).toList();
            final now = DateTime.now();
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
              children: [
                const _TeacherPinCard(),
                const SizedBox(height: 12),
                _ClassChips(
                  classes: classes,
                  selected: filter,
                  onSelected: (f) => setState(() => _filter = f),
                ),
                const SizedBox(height: 14),
                _ClassSummary(
                  title: switch (filter) {
                    _AllLearners() => 'All my learners',
                    _InClass(:final group) => classLabel(group),
                  },
                  learners: shown,
                  stats: stats,
                  now: now,
                  actions: [
                    // Subjects are shared by every class; this is a shortcut
                    // so a teacher doesn't have to leave the class to add one.
                    TextButton.icon(
                      onPressed: () => context.push('/teacher/materials'),
                      icon: const Icon(Icons.library_add_rounded, size: 18),
                      label: const Text('Subjects & materials'),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (shown.isEmpty)
                  _EmptyLearners(message: 'No learners')
                else
                  for (final s in shown)
                    _LearnerCard(
                      learner: s,
                      stats: stats[s.id] ?? LearnerStats.empty,
                      group: classById[s.classGroupId],
                      now: now,
                      onOpen: () => context.push('/teacher/${s.id}'),
                    ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ClassChips extends StatelessWidget {
  const _ClassChips({
    required this.classes,
    required this.selected,
    required this.onSelected,
  });

  final List<ClassGroup> classes;
  final _Filter selected;
  final ValueChanged<_Filter> onSelected;

  bool _isSelected(_Filter f) => switch ((f, selected)) {
    (_AllLearners(), _AllLearners()) => true,
    (_InClass(group: final a), _InClass(group: final b)) => a.id == b.id,
    _ => false,
  };

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, _Filter f) => ChoiceChip(
      label: Text(label),
      selected: _isSelected(f),
      onSelected: (_) => onSelected(f),
    );

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        chip('All my learners', const _AllLearners()),
        for (final c in classes) chip(classLabel(c), _InClass(c)),
      ],
    );
  }
}

class _ClassSummary extends StatelessWidget {
  const _ClassSummary({
    required this.title,
    required this.learners,
    required this.stats,
    required this.now,
    required this.actions,
  });

  final String title;
  final List<Student> learners;
  final Map<int, LearnerStats> stats;
  final DateTime now;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final rows = [for (final s in learners) stats[s.id] ?? LearnerStats.empty];
    final started = rows.where((r) => r.topics > 0).toList();
    final mastery = started.isEmpty
        ? null
        : started.map((r) => r.averageLevel).reduce((a, b) => a + b) /
              started.length;
    final sessions = rows.fold<int>(0, (sum, r) => sum + r.sessions);
    final needHelp = learners
        .where(
          (s) =>
              needsHelpReason(s, stats[s.id] ?? LearnerStats.empty, now) !=
              null,
        )
        .length;

    Widget metric(String value, String label) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
        ],
      ),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
        color: AppColors.primary.withValues(alpha: 0.04),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              metric('${learners.length}', 'learners'),
              metric(
                mastery == null ? '—' : '${mastery.round()}%',
                'avg mastery',
              ),
              metric('$sessions', 'sessions'),
              metric('$needHelp', 'need attention'),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(spacing: 4, children: actions),
        ],
      ),
    );
  }
}

class _LearnerCard extends StatelessWidget {
  const _LearnerCard({
    required this.learner,
    required this.stats,
    required this.group,
    required this.now,
    required this.onOpen,
  });

  final Student learner;
  final LearnerStats stats;
  final ClassGroup? group;
  final DateTime now;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final reason = needsHelpReason(learner, stats, now);
    final mastery = stats.averageLevel.round();

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: colors.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onOpen,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: colors.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              learner.name,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: colors.textPrimary,
                              ),
                            ),
                          ),
                          if (reason != null) ...[
                            const SizedBox(width: 8),
                            _Flag(reason),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        [
                          if (group != null) classLabel(group!),
                          if (learner.grade != null &&
                              learner.grade!.isNotEmpty)
                            learner.grade!,
                          '${stats.topics} topics',
                          '${stats.sessions} sessions',
                          'Active ${_shortWhen(learner.lastActiveAt)}',
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: stats.topics == 0 ? 0 : mastery / 100,
                                minHeight: 6,
                                backgroundColor: AppColors.primary.withValues(
                                  alpha: 0.1,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            stats.topics == 0 ? '—' : '$mastery%',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Flag extends StatelessWidget {
  const _Flag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Color(0xFFB45309),
        ),
      ),
    );
  }
}

class _EmptyLearners extends StatelessWidget {
  const _EmptyLearners({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
      child: Column(
        children: [
          Icon(Icons.groups_outlined, size: 44, color: colors.textHint),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textSecondary, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class TeacherStudentDetailScreen extends ConsumerWidget {
  const TeacherStudentDetailScreen({super.key, required this.studentId});

  final int studentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final studentsAsync = ref.watch(allLearnersProvider);
    final classes =
        ref.watch(classGroupsProvider).valueOrNull ?? const <ClassGroup>[];
    final sessionsAsync = ref.watch(recentSessionsProvider(studentId));
    final progressAsync = ref.watch(topicProgressProvider(studentId));
    final colors = AppColors.of(context);

    // Only a learner in a class this teacher may see (teaches, or is Class
    // Teacher of).
    final mine = {
      for (final c in visibleClassGroups(
        ref.watch(myClassGroupsProvider).valueOrNull ?? const <ClassGroup>[],
        ref.watch(classTeacherGroupsProvider).valueOrNull ??
            const <ClassGroup>[],
      ))
        c.id,
    };
    Student? student;
    final list = studentsAsync.valueOrNull;
    if (list != null) {
      for (final s in list) {
        if (s.id == studentId && mine.contains(s.classGroupId)) {
          student = s;
          break;
        }
      }
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: StudioAppBar(
        title: student?.name ?? 'Learner',
        subtitle: 'Student progress detail',
        showBack: true,
        showMenu: false,
      ),
      body: MaxWidth(
        maxWidth: 900,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (student != null) ...[
              _DetailHeader(
                student: student,
                group: classes
                    .where((c) => c.id == student?.classGroupId)
                    .firstOrNull,
              ),
              const SizedBox(height: 20),
            ],
            Text(
              'Topic progress',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 15,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            progressAsync.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('Could not load progress: $e'),
              data: (topics) {
                if (topics.isEmpty) {
                  return Text(
                    'No topics studied yet.',
                    style: TextStyle(color: colors.textSecondary),
                  );
                }
                return Column(
                  children: topics
                      .map(
                        (t) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(t.topic),
                          subtitle: Text('${t.sessionsCount} sessions'),
                          trailing: Text(
                            'Lv ${t.level}',
                            style: const TextStyle(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                );
              },
            ),
            const SizedBox(height: 20),
            Text(
              'Recent sessions',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 15,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            sessionsAsync.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('Could not load sessions: $e'),
              data: (sessions) {
                if (sessions.isEmpty) {
                  return Text(
                    'No chat sessions saved yet.',
                    style: TextStyle(color: colors.textSecondary),
                  );
                }
                return Column(
                  children: sessions.map((s) {
                    final when = _shortWhen(s.sessionAt);
                    return Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: colors.border),
                        color: colors.surface,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.topic,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${s.highestStage} · ${s.messageCount} messages · $when',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.textSecondary,
                            ),
                          ),
                          if (s.summary.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              s.summary,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.4,
                                color: colors.textSecondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({required this.student, this.group});
  final Student student;
  final ClassGroup? group;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
        color: AppColors.primary.withValues(alpha: 0.04),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            student.name,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            [
              if (group != null) classLabel(group!),
              if (student.grade != null) 'Grade ${student.grade}',
              '${student.totalPoints} points',
              '${student.streakDays}-day streak',
              'Style: ${student.learningStyle}',
            ].join(' · '),
            style: TextStyle(color: colors.textSecondary, height: 1.35),
          ),
        ],
      ),
    );
  }
}

/// Teacher PIN, kept with the rest of the teacher tools (it used to live in
/// Settings → Teachers).
class _TeacherPinCard extends ConsumerWidget {
  const _TeacherPinCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ac = AppColors.of(context);
    return Material(
      color: ac.surface,
      borderRadius: BorderRadius.circular(14),
      child: ListTile(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: ac.border),
        ),
        leading: const Icon(
          Icons.lock_outline_rounded,
          color: AppColors.accentBlue,
        ),
        title: const Text('Staff account'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/teachers'),
      ),
    );
  }
}
