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
      barHeight: 64,
      iconSize: 22,
      labelFontSize: 10,
      selectedIconColor: MonolithTheme.primary,
      unselectedIconColor: const Color(0xFF333333),
      selectedLabelColor: MonolithTheme.primary,
      unselectedLabelColor: const Color(0xFF333333),
      indicatorColor: MonolithTheme.primary.withValues(alpha: 0.15),
      settings: const LiquidGlassSettings(
        thickness: 1.5,
        blur: 10,
        refractiveIndex: 1.15,
        glassColor: Colors.white12,
      ),
    );
  }
}
