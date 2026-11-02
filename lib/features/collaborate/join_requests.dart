import 'package:flutter/material.dart';

import '../../collaboration/sync/class_share_server.dart';
import '../../core/theme/app_colors.dart';
import '../../shared/widgets/studio_page.dart';

/// Devices that typed the right code and are waiting for the sharer to let
/// them in — shown on the teacher's and a sharing student's screen alike.
/// Nothing is handed over until Accept is tapped; unanswered requests time
/// out on their own.
class JoinRequestsCard extends StatelessWidget {
  const JoinRequestsCard({super.key, required this.server, this.subjectName,
    this.className,
  });

  final ClassShareServer server;
  final String? className;

  /// Turns a subject id into its display name, for a co-teacher request's
  /// "would teach" line. Falls back to the id itself.
  final String Function(String subjectId)? subjectName;

  @override
  Widget build(BuildContext context) {
    final ac = AppColors.of(context);
    return StreamBuilder<List<PendingJoin>>(
      stream: server.pendingJoinsStream,
      initialData: server.pendingJoins,
      builder: (context, snap) {
        final pending = snap.data ?? const <PendingJoin>[];
        return StudioCard(
          accent: pending.isEmpty ? AppColors.accentTeal : AppColors.accentOrange,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                pending.isEmpty
                    ? 'No join requests'
                    : 'Asking to join (${pending.length})',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: ac.textPrimary,
                ),
              ),
              for (final p in pending)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Icon(
                        switch (p.kind) {
                          PendingJoinKind.coTeacher => Icons.school_rounded,
                          PendingJoinKind.standby => Icons.backup_rounded,
                          PendingJoinKind.student =>
                            Icons.person_outline_rounded,
                        },
                        size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.address.isEmpty
                                  ? p.name
                                  : '${p.name} · ${p.address}',
                              style: TextStyle(color: ac.textPrimary),
                            ),
                            if (p.kind == PendingJoinKind.student &&
                                className != null)
                              Text(
                                'Wants to join $className',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: ac.textSecondary,
                                ),
                            ),
                            if (p.kind == PendingJoinKind.standby)
                              Text(
                                'Standby device',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: ac.textSecondary,
                                ),
                              ),
                            if (p.kind == PendingJoinKind.coTeacher)
                              Text(
                                'Co-teacher · ${p.subjectIds.map(subjectName ?? (s) => s).join(', ')}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: ac.textSecondary,
                                ),
                              ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () => server.decide(p.id, accept: false),
                        child: const Text('Decline'),
                      ),
                      const SizedBox(width: 4),
                      FilledButton(
                        onPressed: () => server.decide(p.id, accept: true),
                        child: Text(
                          p.kind == PendingJoinKind.student && className != null
                              ? 'Enrol learner'
                              : 'Accept',
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
