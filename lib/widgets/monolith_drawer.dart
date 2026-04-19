import 'package:flutter/material.dart';
import '../theme/monolith_theme.dart';

class MonolithDrawer extends StatelessWidget {
  final String userName;
  final VoidCallback? onProfileTap;
  final VoidCallback? onDashboardTap;
  final VoidCallback? onAiModelsTap;
  final VoidCallback? onHistoryTap;
  final VoidCallback? onLogoutTap;

  const MonolithDrawer({
    super.key,
    this.userName = 'USER',
    this.onProfileTap,
    this.onDashboardTap,
    this.onAiModelsTap,
    this.onHistoryTap,
    this.onLogoutTap,
  });

  @override
  Widget build(BuildContext context) {
    return Drawer(
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: Container(
        color: MonolithTheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Container(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 24,
                left: 24,
                right: 24,
                bottom: 24,
              ),
              color: MonolithTheme.primary,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'MONOLITH',
                    style: MonolithTheme.displayMedium.copyWith(
                      color: MonolithTheme.surface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'SYSTEM MENU',
                    style: MonolithTheme.labelMedium.copyWith(
                      color: MonolithTheme.surfaceContainerHigh,
                    ),
                  ),
                ],
              ),
            ),

            // Menu Items
            const SizedBox(height: 8),
            _buildMenuItem(Icons.person, 'PROFILE', onProfileTap),
            _buildDivider(),
            _buildMenuItem(Icons.adjust, 'DASHBOARD', onDashboardTap),
            _buildDivider(),
            _buildMenuItem(Icons.memory, 'AI MODELS', onAiModelsTap),
            _buildDivider(),
            _buildMenuItem(Icons.history, 'HISTORY', onHistoryTap),
            _buildDivider(),

            const Spacer(),

            // Logout
            _buildDivider(),
            _buildMenuItem(Icons.logout, 'LOGOUT', onLogoutTap),
            SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuItem(IconData icon, String label, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
        child: Row(
          children: [
            Icon(icon, color: MonolithTheme.primary, size: 22),
            const SizedBox(width: 16),
            Text(label, style: MonolithTheme.labelLarge),
          ],
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return const Divider(
      height: 0,
      thickness: 1,
      color: MonolithTheme.primary,
      indent: 24,
      endIndent: 24,
    );
  }
}
