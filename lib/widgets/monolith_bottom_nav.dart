import 'package:flutter/material.dart';
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
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(
            color: MonolithTheme.primary,
            width: MonolithTheme.borderWidth,
          ),
        ),
      ),
      child: SafeArea(
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              _buildNavItem(0, Icons.grid_view, 'DASHBOARD'),
              _buildNavItem(1, Icons.center_focus_strong, 'VISION'),
              _buildNavItem(2, Icons.insights, 'STATS'),
              _buildNavItem(3, Icons.settings, 'CONFIG'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(int index, IconData icon, String label) {
    final isSelected = currentIndex == index;

    return Expanded(
      child: GestureDetector(
        onTap: () => onTap(index),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          color: isSelected ? MonolithTheme.primary : Colors.transparent,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 22,
                color: isSelected
                    ? MonolithTheme.surface
                    : MonolithTheme.outline,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: MonolithTheme.labelSmall.copyWith(
                  color: isSelected
                      ? MonolithTheme.surface
                      : MonolithTheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
