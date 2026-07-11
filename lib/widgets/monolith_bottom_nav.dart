import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../theme/monolith_theme.dart';

class MonolithBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const MonolithBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GlassTabBar.bottom(
      tabs: const [
        GlassTab(
          icon: Icon(Icons.grid_view),
          label: 'DASHBOARD',
        ),
        GlassTab(
          icon: Icon(Icons.center_focus_strong),
          label: 'VISION',
        ),
        GlassTab(
          icon: Icon(Icons.insights),
          label: 'STATS',
        ),
        GlassTab(
          icon: Icon(Icons.settings),
          label: 'CONFIG',
        ),
      ],
      selectedIndex: currentIndex,
      onTabSelected: onTap,
      barHeight: 54,
      iconSize: 22,
      labelFontSize: 10,
      selectedIconColor: MonolithTheme.primary,
      unselectedIconColor: MonolithTheme.outline,
      selectedLabelColor: MonolithTheme.primary,
      unselectedLabelColor: MonolithTheme.outline,
      indicatorColor: MonolithTheme.primary.withValues(alpha: 0.15),
      settings: const LiquidGlassSettings(
        thickness: 35,
        blur: 12,
        refractiveIndex: 1.4,
        glassColor: Colors.white12,
      ),
    );
  }
}
