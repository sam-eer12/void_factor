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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(32),
          border: Border.all(
            color: MonolithTheme.primary.withValues(alpha: 0.15),
            width: 2.0,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: GlassTabBar.bottom(
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
            horizontalPadding: 0,
            verticalPadding: 0,
            iconSize: 22,
            labelFontSize: 10,
            selectedIconColor: MonolithTheme.primary,
            unselectedIconColor: const Color(0xFF333333),
            selectedLabelColor: MonolithTheme.primary,
            unselectedLabelColor: const Color(0xFF333333),
            indicatorColor: MonolithTheme.primary.withValues(alpha: 0.15),
            settings: const LiquidGlassSettings(
              thickness: 0.8,
              blur: 4,
              refractiveIndex: 1.8,
              glassColor: Color(0x03FFFFFF),
            ),
          ),
        ),
      ),
    );
  }
}
