import 'package:flutter/material.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_card.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_bottom_nav.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MonolithTheme.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // ── Top Bar ──
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: const BoxDecoration(
                color: MonolithTheme.surface,
                border: Border(
                  bottom: BorderSide(
                    color: MonolithTheme.primary,
                    width: MonolithTheme.borderWidth,
                  ),
                ),
              ),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: MonolithTheme.containerDecoration,
                      child: const Icon(Icons.arrow_back,
                          color: MonolithTheme.primary, size: 22),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text('SYSTEM SETTINGS',
                      style: MonolithTheme.headlineLarge),
                ],
              ),
            ),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Profile Section ──
                    Text('PROFILE', style: MonolithTheme.headlineMedium),
                    const SizedBox(height: 16),
                    MonolithCard(
                      child: Column(
                        children: [
                          // Avatar
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              color: MonolithTheme.primary,
                              border: Border.all(
                                color: MonolithTheme.primary,
                                width: MonolithTheme.heroBorderWidth,
                              ),
                            ),
                            child: const Icon(
                              Icons.person,
                              color: MonolithTheme.surface,
                              size: 40,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text('USER_001',
                              style: MonolithTheme.headlineLarge),
                          const SizedBox(height: 4),
                          Text(
                            'user@monolith.ai',
                            style: MonolithTheme.bodyMedium.copyWith(
                              color: MonolithTheme.outline,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Container(
                            height: MonolithTheme.borderWidth,
                            color: MonolithTheme.primary,
                          ),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceAround,
                            children: [
                              _buildProfileStat('HEIGHT', '175 CM'),
                              Container(
                                width: MonolithTheme.borderWidth,
                                height: 40,
                                color: MonolithTheme.primary,
                              ),
                              _buildProfileStat('WEIGHT', '70 KG'),
                              Container(
                                width: MonolithTheme.borderWidth,
                                height: 40,
                                color: MonolithTheme.primary,
                              ),
                              _buildProfileStat('AGE', '25'),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // ── Management Section ──
                    Text('MANAGEMENT', style: MonolithTheme.headlineMedium),
                    const SizedBox(height: 16),

                    _buildSettingsTile(
                      Icons.person_outline,
                      'EDIT PROFILE',
                      'Update physical metrics',
                      () {},
                    ),
                    const SizedBox(height: 8),
                    _buildSettingsTile(
                      Icons.notifications_none,
                      'NOTIFICATIONS',
                      'Configure system alerts',
                      () {},
                    ),
                    const SizedBox(height: 8),
                    _buildSettingsTile(
                      Icons.palette_outlined,
                      'APPEARANCE',
                      'Visual system configuration',
                      () {},
                    ),
                    const SizedBox(height: 8),
                    _buildSettingsTile(
                      Icons.health_and_safety_outlined,
                      'HEALTH CONNECT',
                      'Sync with health services',
                      () {},
                    ),
                    const SizedBox(height: 8),
                    _buildSettingsTile(
                      Icons.shield_outlined,
                      'PRIVACY',
                      'Data management & export',
                      () {},
                    ),
                    const SizedBox(height: 24),

                    // ── API Key ──
                    MonolithCard(
                      inverted: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.vpn_key,
                                  color: MonolithTheme.surface, size: 20),
                              const SizedBox(width: 12),
                              Text(
                                'ROTATE API KEY',
                                style:
                                    MonolithTheme.headlineMedium.copyWith(
                                  color: MonolithTheme.surface,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Current key expires in 23 days. Rotation recommended.',
                            style: MonolithTheme.bodyMedium.copyWith(
                              color: MonolithTheme.surfaceContainerHigh,
                            ),
                          ),
                          const SizedBox(height: 16),
                          MonolithButton(
                            label: 'ROTATE KEY',
                            style: MonolithButtonStyle.secondary,
                            onPressed: () {},
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // ── Danger Zone ──
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: MonolithTheme.error,
                          width: MonolithTheme.borderWidth,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'DANGER ZONE',
                            style: MonolithTheme.labelLarge.copyWith(
                              color: MonolithTheme.error,
                            ),
                          ),
                          const SizedBox(height: 16),
                          MonolithButton(
                            label: 'DELETE ACCOUNT',
                            style: MonolithButtonStyle.tertiary,
                            onPressed: () {},
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),

            MonolithBottomNav(
              currentIndex: 3,
              onTap: (i) {
                if (i == 0) {
                  Navigator.pushReplacementNamed(context, '/dashboard');
                } else if (i == 1) {
                  Navigator.pushReplacementNamed(context, '/ai-vision');
                } else if (i == 2) {
                  Navigator.pushReplacementNamed(context, '/projections');
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileStat(String label, String value) {
    return Column(
      children: [
        Text(value, style: MonolithTheme.headlineMedium),
        const SizedBox(height: 4),
        Text(
          label,
          style: MonolithTheme.labelSmall.copyWith(
            color: MonolithTheme.outline,
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsTile(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: MonolithCard(
        hasShadow: false,
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                border: Border.all(
                  color: MonolithTheme.primary,
                  width: MonolithTheme.borderWidth,
                ),
              ),
              child: Icon(icon, color: MonolithTheme.primary, size: 20),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: MonolithTheme.labelLarge),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: MonolithTheme.labelSmall.copyWith(
                      color: MonolithTheme.outline,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                color: MonolithTheme.primary, size: 24),
          ],
        ),
      ),
    );
  }
}
