import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ai_core/providers/ai_provider.dart';
import '../../core/app_info_provider.dart';
import '../../core/theme/app_colors.dart';
import '../../db/otic_database.dart';
import '../../db/providers/db_provider.dart';
import '../../features/learn/path/path_provider.dart';
import '../../l10n/app_locale.dart';
import 'home_atmosphere_background.dart';

const _brandLogoAsset = 'assets/branding/ai-connect-africa-logo.png';
const _sidebarCollapsedKey = 'shell_sidebar_collapsed';

/// Shared shell chrome — matches mobile + desktop mockups.
abstract final class ShellNavStyle {
  static const fontFamily = 'Inter';
  static const navy = AppColors.navy;
  static const active = AppColors.primary;
  static const tile = Color(0xFFE8F1FE);
  static const labelSize = 9.5;
  static const sideLabelSize = 14.0;
  static const iconSize = 22.0;
  static const tileRadius = 14.0;
  static const tileSize = 42.0;
}

final sidebarCollapsedProvider =
    StateNotifierProvider<_SidebarCollapsedNotifier, bool>((ref) {
  return _SidebarCollapsedNotifier();
});

class _SidebarCollapsedNotifier extends StateNotifier<bool> {
  _SidebarCollapsedNotifier() : super(false) {
    _load();
  }

  Future<void>? _ready;

  Future<void> _load() {
    return _ready ??= () async {
      final prefs = await SharedPreferences.getInstance();
      state = prefs.getBool(_sidebarCollapsedKey) ?? false;
    }();
  }

  Future<void> toggle() async {
    await _ready;
    state = !state;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_sidebarCollapsedKey, state);
  }
}

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  static final mobileScaffoldKey = GlobalKey<ScaffoldState>();

  /// Primary destinations — identical on mobile bottom bar and desktop sidebar.
  static const _primary = [
    _NavDest('Home', Icons.home_outlined, Icons.home_rounded, '/'),
    _NavDest(
      'Learn',
      Icons.menu_book_outlined,
      Icons.menu_book_rounded,
      '/learn',
    ),
    _NavDest(
      'Create',
      Icons.auto_awesome_outlined,
      Icons.auto_awesome_rounded,
      '/create',
    ),
    _NavDest(
      'Projects',
      Icons.folder_outlined,
      Icons.folder_rounded,
      '/projects',
    ),
  ];

  static const _settings = _NavDest(
    'Settings',
    Icons.settings_outlined,
    Icons.settings_rounded,
    '/settings',
  );

  /// Extra destinations shown in the mobile drawer and desktop sidebar.
  ///
  /// Lesson Materials used to be listed here too, reachable by any student.
  /// It is teacher-only workspace (already PIN-gated behind `/teacher*` —
  /// see teacher_pin.dart) and is reached from the Teacher dashboard's own
  /// toolbar button instead (teacher_dashboard_screen.dart), so it has no
  /// business in the student-facing nav at all.
  static const _overflow = [
    _NavDest(
      'My notes',
      Icons.picture_as_pdf_outlined,
      Icons.picture_as_pdf_rounded,
      '/my-notes',
    ),
    _NavDest(
      'Assignments',
      Icons.assignment_outlined,
      Icons.assignment_rounded,
      '/assignments',
    ),
    _NavDest(
      'Achievements',
      Icons.emoji_events_outlined,
      Icons.emoji_events_rounded,
      '/achievements',
    ),
    _NavDest('Staff access', Icons.badge_outlined, Icons.badge_rounded, '/teachers'),
  ];

  static const kNavBarHeight = 72.0;
  static const _kExpandedWidth = 248.0;
  /// Slim icon rail — mockup collapsed sidebar (~56px).
  static const _kCollapsedWidth = 56.0;

  int _primaryIndex(String path) {
    if (path == '/' || path == '/chat') return 0;
    // Practice & Apply open from Learn.
    if (path == '/practice' || path.startsWith('/practice/')) return 1;
    for (var i = 1; i < _primary.length; i++) {
      final p = _primary[i].path;
      if (path == p || path.startsWith('$p/')) return i;
    }
    return -1;
  }

  bool _settingsSelected(String path) =>
      path == '/settings' || path.startsWith('/settings/');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = GoRouterState.of(context).uri.path;
    final primaryIndex = _primaryIndex(path);
    final settingsSelected = _settingsSelected(path);
    final isWide = MediaQuery.sizeOf(context).width >= 640;
    final collapsed = ref.watch(sidebarCollapsedProvider);

    if (isWide) {
      return HomeAtmosphereBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Row(
            children: [
              _SideNav(
                collapsed: collapsed,
                primaryIndex: primaryIndex,
                settingsSelected: settingsSelected,
                primary: _primary,
                overflow: _overflow,
                settings: _settings,
                onToggleCollapse: () =>
                    ref.read(sidebarCollapsedProvider.notifier).toggle(),
              ),
              Container(width: 1, color: AppColors.of(context).border),
              Expanded(child: child),
            ],
          ),
        ),
      );
    }

    return HomeAtmosphereBackground(
      child: Scaffold(
        key: mobileScaffoldKey,
        backgroundColor: Colors.transparent,
        body: child,
        drawer: _AppDrawer(
          primaryIndex: primaryIndex,
          settingsSelected: settingsSelected,
          primary: _primary,
          settings: _settings,
          overflow: _overflow,
        ),
        bottomNavigationBar: _FrostedBottomNav(
          destinations: _primary,
          selectedIndex: primaryIndex,
        ),
      ),
    );
  }
}

class _FrostedBottomNav extends StatelessWidget {
  const _FrostedBottomNav({
    required this.destinations,
    required this.selectedIndex,
  });

  final List<_NavDest> destinations;
  final int selectedIndex;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;

    // Solid white bar — no top border / harsh edge line.
    return Material(
      color: Colors.white,
      elevation: 0,
      child: SizedBox(
        height: AppShell.kNavBarHeight + bottom,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottom),
          child: Row(
            children: [
              for (var i = 0; i < destinations.length; i++)
                Expanded(
                  child: _BottomNavItem(
                    dest: destinations[i],
                    selected: selectedIndex == i,
                    onTap: () => context.go(destinations[i].path),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  const _BottomNavItem({
    required this.dest,
    required this.selected,
    required this.onTap,
  });

  final _NavDest dest;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Desktop Home chrome (blue rail + blue→peach gradient), sized to the
    // bottom-bar cell so it never overflows (was causing the yellow glitch).
    final color = selected ? ShellNavStyle.active : ShellNavStyle.navy;

    return Semantics(
      button: true,
      label: tr(context, dest.label),
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: selected
                  ? const LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Color(0xFFDCEBFE),
                        Color(0xFFEEE8FE),
                        Color(0x00EEE8FE),
                      ],
                      stops: [0.0, 0.55, 1.0],
                    )
                  : null,
            ),
            child: Stack(
              children: [
                if (selected)
                  Positioned(
                    left: 0,
                    top: 10,
                    bottom: 10,
                    child: Container(
                      width: 3,
                      decoration: BoxDecoration(
                        color: ShellNavStyle.active,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        selected ? dest.selectedIcon : dest.icon,
                        size: 20,
                        color: color,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        tr(context, dest.label),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: ShellNavStyle.fontFamily,
                          fontSize: 9,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w500,
                          color: color,
                        ),
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

class _SideNav extends ConsumerWidget {
  const _SideNav({
    required this.collapsed,
    required this.primaryIndex,
    required this.settingsSelected,
    required this.primary,
    required this.overflow,
    required this.settings,
    required this.onToggleCollapse,
  });

  final bool collapsed;
  final int primaryIndex;
  final bool settingsSelected;
  final List<_NavDest> primary;
  final List<_NavDest> overflow;
  final _NavDest settings;
  final VoidCallback onToggleCollapse;

  bool _overflowSelected(String path, _NavDest dest) =>
      path == dest.path || path.startsWith('${dest.path}/');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ac = AppColors.of(context);
    final width = collapsed ? AppShell._kCollapsedWidth : AppShell._kExpandedWidth;
    final path = GoRouterState.of(context).uri.path;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      width: width,
      color: Colors.white,
      child: Column(
        children: [
          const SizedBox(height: 16),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: collapsed ? 6 : 14),
            child: collapsed
                ? Column(
                    children: [
                      const _BrandLogo(size: 30),
                      const SizedBox(height: 6),
                      _CollapseButton(collapsed: true, onTap: onToggleCollapse),
                    ],
                  )
                : Row(
                    children: [
                      const _BrandLogo(size: 36),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'CONNECT AFRICA',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: ShellNavStyle.fontFamily,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.25,
                            color: ShellNavStyle.navy,
                          ),
                        ),
                      ),
                      _CollapseButton(collapsed: false, onTap: onToggleCollapse),
                    ],
                  ),
          ),
          const SizedBox(height: 14),
          Container(height: 1, color: ac.border),
          const SizedBox(height: 6),
          Expanded(
            child: ListView(
              padding: EdgeInsets.symmetric(
                horizontal: collapsed ? 4 : 8,
                vertical: 4,
              ),
              children: [
                for (var i = 0; i < primary.length; i++)
                  _NavRow(
                    dest: primary[i],
                    selected: primaryIndex == i,
                    collapsed: collapsed,
                    onTap: () => context.go(primary[i].path),
                  ),
                const SizedBox(height: 8),
                for (final dest in overflow)
                  _NavRow(
                    dest: dest,
                    selected: _overflowSelected(path, dest),
                    collapsed: collapsed,
                    onTap: () => context.go(dest.path),
                  ),
                if (!collapsed) ...[
                  const SizedBox(height: 10),
                  const _RecentChatsSection(collapsed: false),
                ] else ...[
                  const SizedBox(height: 6),
                  _RecentChatsIconButton(),
                ],
              ],
            ),
          ),
          Container(height: 1, color: ac.border),
          Padding(
            padding: EdgeInsets.fromLTRB(
              collapsed ? 4 : 8,
              8,
              collapsed ? 4 : 8,
              12,
            ),
            child: _NavRow(
              dest: settings,
              selected: settingsSelected,
              collapsed: collapsed,
              onTap: () => context.go(settings.path),
            ),
          ),
          if (!collapsed)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppColors.online,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Consumer(
                    builder: (context, ref, _) {
                      final version =
                          ref.watch(packageInfoProvider).valueOrNull?.version;
                      return Flexible(
                        child: Text(
                          version == null
                              ? tr(context, 'Offline')
                              : '${tr(context, 'Offline')} · v$version',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: ShellNavStyle.fontFamily,
                            fontSize: 11,
                            color: ac.textHint,
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _CollapseButton extends StatelessWidget {
  const _CollapseButton({required this.collapsed, required this.onTap});

  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: collapsed ? 'Expand sidebar' : 'Collapse sidebar',
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      icon: Icon(
        collapsed ? Icons.chevron_right_rounded : Icons.chevron_left_rounded,
        size: 20,
        color: AppColors.of(context).textHint,
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.dest,
    required this.selected,
    required this.collapsed,
    required this.onTap,
  });

  final _NavDest dest;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = tr(context, dest.label);
    final iconData = selected ? dest.selectedIcon : dest.icon;
    final iconColor = selected ? ShellNavStyle.active : ShellNavStyle.navy;
    final textColor = selected ? ShellNavStyle.navy : ShellNavStyle.navy.withValues(alpha: 0.72);

    if (collapsed) {
      const tile = 40.0;
      final item = Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            height: 44,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: tile,
                  height: tile,
                  decoration: BoxDecoration(
                    color: selected ? ShellNavStyle.tile : Colors.transparent,
                    borderRadius:
                        BorderRadius.circular(ShellNavStyle.tileRadius),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    iconData,
                    size: 20,
                    color: iconColor,
                  ),
                ),
                if (selected)
                  Positioned(
                    right: 2,
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: const BoxDecoration(
                        color: ShellNavStyle.active,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      return Tooltip(message: label, child: item);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: selected
                ? const LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Color(0xFFDCEBFE),
                      Color(0xFFEEE8FE),
                      Color(0x00EEE8FE),
                    ],
                    stops: [0.0, 0.55, 1.0],
                  )
                : null,
          ),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 24,
                decoration: BoxDecoration(
                  color: selected ? ShellNavStyle.active : Colors.transparent,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(width: 12),
              Icon(iconData, size: 20, color: iconColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: ShellNavStyle.fontFamily,
                    fontSize: ShellNavStyle.sideLabelSize,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: textColor,
                  ),
                ),
              ),
              if (selected)
                const Padding(
                  padding: EdgeInsets.only(right: 10),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: ShellNavStyle.active,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentChatsIconButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Tooltip(
      message: tr(context, 'Recent chats'),
      child: IconButton(
        onPressed: () {
          // Expand so the user can browse recent chats.
          final collapsed = ref.read(sidebarCollapsedProvider);
          if (collapsed) {
            ref.read(sidebarCollapsedProvider.notifier).toggle();
          }
        },
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        icon: Icon(
          Icons.chat_bubble_outline_rounded,
          size: 20,
          color: AppColors.of(context).textHint,
        ),
      ),
    );
  }
}

class _RecentChatsSection extends ConsumerStatefulWidget {
  const _RecentChatsSection({required this.collapsed});

  final bool collapsed;

  @override
  ConsumerState<_RecentChatsSection> createState() =>
      _RecentChatsSectionState();
}

class _RecentChatsSectionState extends ConsumerState<_RecentChatsSection> {
  final _search = TextEditingController();
  String _query = '';
  bool _showSearch = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _relative(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 60) return '${d.inMinutes.clamp(1, 59)}m';
    if (d.inHours < 24) return '${d.inHours}h';
    if (d.inDays < 7) return '${d.inDays}d';
    return '${(d.inDays / 7).floor()}w';
  }

  /// Reopen a saved chat.
  ///
  /// This used to reset the thread and re-send the detected topic word as a
  /// brand-new question, which discarded whatever was on screen and answered
  /// something the student never asked. It now restores the tutor's memory
  /// and shows a recap of what the chat covered.
  Future<void> _openSession(ChatSession session) async {
    final notifier = ref.read(chatProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final restored = await notifier.restoreSession(session.id);
    if (!mounted) return;
    if (!restored) {
      // The recall file is missing or damaged. Drop the tile instead of
      // leaving a row that opens a blank chat and looks broken.
      await notifier.deleteSession(session.id);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(tr(context, 'That chat could no longer be opened.')),
      ));
      return;
    }
    if (!mounted) return;
    context.go('/');
  }

  void _newChat() {
    ref.read(chatProvider.notifier).reset();
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    if (widget.collapsed) return const SizedBox.shrink();
    final ac = AppColors.of(context);
    final student = ref.watch(activeStudentProvider).valueOrNull;

    // One row per chat, straight off the index table — the tiles no longer
    // come from SessionSummaries, which holds one row per *reply* and made
    // the same conversation appear a dozen times over.
    List<ChatSession> sessions = const [];
    if (student != null) {
      sessions =
          ref.watch(chatSessionsProvider(student.id)).valueOrNull ?? const [];
    }

    final needle = _query.trim().toLowerCase();
    final filtered = needle.isEmpty
        ? sessions
        : sessions
            .where((s) =>
                s.title.toLowerCase().contains(needle) ||
                s.preview.toLowerCase().contains(needle) ||
                s.topic.toLowerCase().contains(needle))
            .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tr(context, 'Recent chats'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: ac.textPrimary,
                  ),
                ),
              ),
              IconButton(
                tooltip: tr(context, 'Search'),
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _showSearch = !_showSearch),
                icon: Icon(Icons.search_rounded, size: 18, color: ac.textHint),
              ),
              IconButton(
                tooltip: tr(context, 'New chat'),
                visualDensity: VisualDensity.compact,
                onPressed: _newChat,
                icon: Icon(Icons.edit_square, size: 16, color: ac.textHint),
              ),
            ],
          ),
        ),
        if (_showSearch)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: TextField(
              controller: _search,
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              style: TextStyle(fontSize: 12.5, color: ac.textPrimary),
              decoration: InputDecoration(
                isDense: true,
                hintText: tr(context, 'Search'),
                hintStyle: TextStyle(fontSize: 12.5, color: ac.textHint),
                prefixIcon:
                    Icon(Icons.search_rounded, size: 16, color: ac.textHint),
                prefixIconConstraints: const BoxConstraints(minWidth: 36),
                filled: true,
                fillColor: ac.iconWell.withValues(alpha: 0.55),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Text(
              tr(context, 'No recent chats yet'),
              style: TextStyle(fontSize: 12, color: ac.textHint),
            ),
          )
        else
          for (final s in filtered.take(12))
            _RecentChatTile(
              title: s.title,
              subtitle: s.preview,
              timeLabel: _relative(s.updatedAt),
              pinned: s.pinned,
              onTap: () => _openSession(s),
              onTogglePin: () => ref
                  .read(dbProvider)
                  .chatSessionDao
                  .setPinned(s.id, !s.pinned),
            ),
      ],
    );
  }
}

class _RecentChatTile extends StatelessWidget {
  const _RecentChatTile({
    required this.title,
    required this.timeLabel,
    required this.onTap,
    required this.onTogglePin,
    this.subtitle = '',
    this.pinned = false,
  });

  final String title;

  /// Last thing the tutor said, clipped. Without it every tile in a subject
  /// looks identical and there is no way to tell two chats apart.
  final String subtitle;
  final String timeLabel;
  final bool pinned;
  final VoidCallback onTap;

  /// "Keep this chat" — exempts it from the 30-day rolling retention sweep
  /// ([StorageHousekeeper]) without changing anything else about it.
  final VoidCallback onTogglePin;

  @override
  Widget build(BuildContext context) {
    final ac = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: Row(
          children: [
            const SizedBox(width: 6),
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 15,
              color: ac.textHint,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: ac.textPrimary,
                    ),
                  ),
                  if (subtitle.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: ac.textHint),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Text(
              timeLabel,
              style: TextStyle(fontSize: 11, color: ac.textHint),
            ),
            IconButton(
              tooltip: tr(
                context,
                pinned ? 'Keeping this chat — tap to allow it to expire' : 'Keep this chat',
              ),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              onPressed: onTogglePin,
              icon: Icon(
                pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                size: 14,
                color: pinned ? AppColors.primary : ac.textHint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AppDrawer extends ConsumerWidget {
  const _AppDrawer({
    required this.primaryIndex,
    required this.settingsSelected,
    required this.primary,
    required this.settings,
    required this.overflow,
  });

  final int primaryIndex;
  final bool settingsSelected;
  final List<_NavDest> primary;
  final _NavDest settings;
  final List<_NavDest> overflow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pathsAsync = ref.watch(studentPathsProvider);
    final ac = AppColors.of(context);

    return Drawer(
      backgroundColor: ac.surface,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Row(
                children: [
                  const _BrandLogo(size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'AI Connect Africa',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: ac.textPrimary,
                          ),
                        ),
                        Text(
                          tr(context, 'Learn, Create & Build'),
                          style: TextStyle(fontSize: 11, color: ac.textHint),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Container(
              height: 1,
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: ac.border,
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                children: [
                  pathsAsync.when(
                    data: (rows) {
                      if (rows.isEmpty) return const SizedBox.shrink();
                      final paths = rows.map(parsedFromRow).toList();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                            child: Text(
                              'MY PATHS',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.0,
                                color: ac.textHint,
                              ),
                            ),
                          ),
                          ...paths.take(5).map(
                                (p) => ListTile(
                                  dense: true,
                                  leading: const Icon(
                                    Icons.route,
                                    size: 18,
                                    color: AppColors.learnColor,
                                  ),
                                  title: Text(
                                    p.topic,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: ac.textPrimary,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    '${p.completedLessons}/${p.totalLessons} lessons',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: ac.textHint,
                                    ),
                                  ),
                                  onTap: () {
                                    Navigator.pop(context);
                                    context.push(
                                      '/path/${Uri.encodeComponent(p.topic)}',
                                    );
                                  },
                                ),
                              ),
                          Container(
                            height: 1,
                            margin: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            color: ac.border,
                          ),
                        ],
                      );
                    },
                    loading: () => const SizedBox.shrink(),
                    error: (_, __) => const SizedBox.shrink(),
                  ),
                  for (var i = 0; i < primary.length; i++)
                    _DrawerTile(
                      dest: primary[i],
                      selected: primaryIndex == i,
                      onTap: () {
                        context.go(primary[i].path);
                        Navigator.pop(context);
                      },
                    ),
                  _DrawerTile(
                    dest: settings,
                    selected: settingsSelected,
                    onTap: () {
                      context.go(settings.path);
                      Navigator.pop(context);
                    },
                  ),
                  const SizedBox(height: 8),
                  for (final dest in overflow)
                    _DrawerTile(
                      dest: dest,
                      selected: GoRouterState.of(context).uri.path == dest.path ||
                          GoRouterState.of(context)
                              .uri
                              .path
                              .startsWith('${dest.path}/'),
                      onTap: () {
                        context.go(dest.path);
                        Navigator.pop(context);
                      },
                    ),
                  const SizedBox(height: 8),
                  const _RecentChatsSection(collapsed: false),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerTile extends StatelessWidget {
  const _DrawerTile({
    required this.dest,
    required this.selected,
    required this.onTap,
  });

  final _NavDest dest;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Match expanded desktop sidebar: blue rail + blue→peach gradient.
    final color = selected ? ShellNavStyle.active : ShellNavStyle.navy;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: selected
                ? const LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Color(0xFFDCEBFE),
                      Color(0xFFEEE8FE),
                      Color(0x00EEE8FE),
                    ],
                    stops: [0.0, 0.55, 1.0],
                  )
                : null,
          ),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 24,
                margin: const EdgeInsets.only(left: 4),
                decoration: BoxDecoration(
                  color: selected ? ShellNavStyle.active : Colors.transparent,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                selected ? dest.selectedIcon : dest.icon,
                color: color,
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  tr(context, dest.label),
                  style: TextStyle(
                    fontFamily: ShellNavStyle.fontFamily,
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected
                        ? ShellNavStyle.navy
                        : ShellNavStyle.navy.withValues(alpha: 0.72),
                  ),
                ),
              ),
              if (selected)
                const Padding(
                  padding: EdgeInsets.only(right: 10),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: ShellNavStyle.active,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavDest {
  const _NavDest(this.label, this.icon, this.selectedIcon, this.path);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final String path;
}

class _BrandLogo extends StatelessWidget {
  const _BrandLogo({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      _brandLogoAsset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      semanticLabel: 'Logo',
    );
  }
}
