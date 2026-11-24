import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/library_provider.dart';
import '../providers/theme_provider.dart';
import '../util/platform.dart';
import '../util/text_scale.dart';
import 'tabs/backlog_tab.dart';
import 'tabs/completed_tab.dart';
import 'tabs/play_next_tab.dart';
import 'tabs/settings_tab.dart';
import 'tabs/stats_tab.dart';
import '../util/ui_tokens.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  int _selectedIndex = 0;

  static const _destinations = [
    (label: 'Backlog',   icon: Icons.inbox_outlined,         selectedIcon: Icons.inbox),
    (label: 'Completed', icon: Icons.check_circle_outline,   selectedIcon: Icons.check_circle),
    (label: 'Play Next', icon: Icons.play_arrow_outlined,    selectedIcon: Icons.play_arrow),
    (label: 'Stats',     icon: Icons.bar_chart_outlined,     selectedIcon: Icons.bar_chart),
    (label: 'Settings',  icon: Icons.settings_outlined,      selectedIcon: Icons.settings),
  ];

  static const _views = [
    BacklogTab(),
    CompletedTab(),
    PlayNextTab(),
    StatsTab(),
    SettingsTab(),
  ];

  @override
  Widget build(BuildContext context) {
    ref.watch(initialSyncProvider);

    ref.listen<SyncState>(syncStateProvider, (previous, next) {
      if (previous?.status == SyncStatus.syncing &&
          next.status == SyncStatus.idle &&
          next.notification != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.notification!),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    });

    final isMobileOS = context.isMobileOS;
    final isDesktop = !isMobileOS;
    final navPosition = ref.watch(navigationPositionProvider);
    final showTopNav = isDesktop && navPosition == NavigationPosition.top;
    final showRailLeft = isDesktop && navPosition == NavigationPosition.left;
    final showRailRight = isDesktop && navPosition == NavigationPosition.right;
    final body = IndexedStack(index: _selectedIndex, children: _views);

    return Scaffold(
      appBar: AppBar(
        title: const Text('BacklogForge'),
        actions: [
          if (showTopNav)
            ..._destinations.asMap().entries.map(
                  (e) => Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: 8, horizontal: 2),
                    child: _TopNavItem(
                      label: e.value.label,
                      isSelected: _selectedIndex == e.key,
                      onTap: () =>
                          setState(() => _selectedIndex = e.key),
                    ),
                  ),
                ),
          if (showTopNav) const SizedBox(width: 4),
        ],
      ),
      body: Row(
        children: [
          if (showRailLeft)
            _buildRail(),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: kMaxContentWidth),
                child: body,
              ),
            ),
          ),
          if (showRailRight)
            _buildRail(),
        ],
      ),
      bottomNavigationBar: !isDesktop
          ? _buildNavBar(context)
          : null,
    );
  }

  /// Five labelled destinations fit one phone width only at normal text sizes.
  /// With a large font setting the labels would break mid-word ("Complet|ed"),
  /// so the nav bar keeps its own text at normal size and shows just the
  /// selected label; the icons stay and every destination keeps its tooltip
  /// and screen-reader label.
  Widget _buildNavBar(BuildContext context) {
    final large = isLargeText(context);
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: large ? TextScaler.noScaling : null,
      ),
      child: NavigationBar(
        labelBehavior: large
            ? NavigationDestinationLabelBehavior.onlyShowSelected
            : NavigationDestinationLabelBehavior.alwaysShow,
              selectedIndex: _selectedIndex,
              onDestinationSelected: (i) =>
                  setState(() => _selectedIndex = i),
              destinations: _destinations
                  .map((d) => NavigationDestination(
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.selectedIcon),
                        label: d.label,
                      ))
                  .toList(),
      ),
    );
  }

  Widget _buildRail() => NavigationRail(
        selectedIndex: _selectedIndex,
        labelType: NavigationRailLabelType.all,
        onDestinationSelected: (i) =>
            setState(() => _selectedIndex = i),
        destinations: _destinations
            .map((d) => NavigationRailDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selectedIcon),
                  label: Text(d.label),
                ))
            .toList(),
      );
}

class _TopNavItem extends StatelessWidget {
  const _TopNavItem({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: AnimatedContainer(
        duration: kAnimFast,
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? cs.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: tt.labelLarge?.copyWith(
            color: isSelected ? cs.primary : cs.onSurfaceVariant,
            fontWeight:
                isSelected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
