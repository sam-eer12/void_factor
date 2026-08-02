import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_card.dart';
import '../../widgets/monolith_button.dart';
import '../../app/auth_provider.dart';
import '../../app/session_provider.dart';
import '../dashboard/monolith_shell.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authStateProvider).value;
    final profileAsync = ref.watch(profileProvider);

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
                    onTap: () => MonolithShell.setActiveTab(context, 0, '/dashboard'),
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
                            child: user?.photoURL != null
                                ? Image.network(
                                    user!.photoURL!,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) => const Icon(
                                      Icons.person,
                                      color: MonolithTheme.surface,
                                      size: 40,
                                    ),
                                  )
                                : const Icon(
                                    Icons.person,
                                    color: MonolithTheme.surface,
                                    size: 40,
                                  ),
                          ),
                          const SizedBox(height: 16),
                          Text(user?.displayName ?? 'USER',
                              style: MonolithTheme.headlineLarge),
                          const SizedBox(height: 4),
                          Text(
                            user?.email ?? 'user@monolith.ai',
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
                          profileAsync.when(
                            data: (profile) {
                              final height = _fmt(profile.height);
                              final weight = _fmt(profile.weight);
                              final age = profile.age > 0
                                  ? profile.age.toString()
                                  : '--';
                              return Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceAround,
                                children: [
                                  _buildProfileStat('HEIGHT', '$height CM'),
                                  Container(
                                    width: MonolithTheme.borderWidth,
                                    height: 40,
                                    color: MonolithTheme.primary,
                                  ),
                                  _buildProfileStat('WEIGHT', '$weight KG'),
                                  Container(
                                    width: MonolithTheme.borderWidth,
                                    height: 40,
                                    color: MonolithTheme.primary,
                                  ),
                                  _buildProfileStat('AGE', age),
                                ],
                              );
                            },
                            loading: () => const Center(
                              child: SizedBox(
                                height: 40,
                                width: 40,
                                child: CircularProgressIndicator.adaptive(
                                  valueColor: AlwaysStoppedAnimation<Color>(MonolithTheme.primary),
                                ),
                              ),
                            ),
                            error: (e, s) => Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceAround,
                              children: [
                                _buildProfileStat('HEIGHT', '-- CM'),
                                Container(
                                  width: MonolithTheme.borderWidth,
                                  height: 40,
                                  color: MonolithTheme.primary,
                                ),
                                _buildProfileStat('WEIGHT', '-- KG'),
                                Container(
                                  width: MonolithTheme.borderWidth,
                                  height: 40,
                                  color: MonolithTheme.primary,
                                ),
                                _buildProfileStat('AGE', '--'),
                              ],
                            ),
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
                      () => Navigator.pushNamed(context, '/edit-profile'),
                    ),
                    const SizedBox(height: 8),
                    _buildSettingsTile(
                      Icons.flag_outlined,
                      'GOALS & DIET',
                      'Weight goal, target & allergies',
                      () => Navigator.pushNamed(context, '/goals-diet'),
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
          ],
        ),
      ),
    );
  }

  // Formats a metric for display: 0 (unset) shows as '--', whole numbers drop
  // the trailing '.0'.
  String _fmt(double value) {
    if (value <= 0) return '--';
    return value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
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
