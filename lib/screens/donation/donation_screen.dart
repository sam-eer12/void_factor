import 'package:flutter/material.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_card.dart';
import '../../widgets/monolith_bottom_nav.dart';

class DonationScreen extends StatelessWidget {
  const DonationScreen({super.key});

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
                  Text('MONOLITH', style: MonolithTheme.headlineLarge),
                ],
              ),
            ),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Header ──
                    Text('DONATION HUB',
                        style: MonolithTheme.displayLarge),
                    const SizedBox(height: 4),
                    Text(
                      'Architectural Philanthropy',
                      style: MonolithTheme.bodyMedium.copyWith(
                        color: MonolithTheme.outline,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // ── Domestic (India) ──
                    MonolithCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                color: MonolithTheme.primary,
                                child: const Icon(Icons.flag,
                                    color: MonolithTheme.surface,
                                    size: 18),
                              ),
                              const SizedBox(width: 12),
                              Text('DOMESTIC (INDIA)',
                                  style: MonolithTheme.headlineMedium),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'SCAN TO DONATE VIA UPI',
                            style: MonolithTheme.labelMedium.copyWith(
                              color: MonolithTheme.outline,
                            ),
                          ),
                          const SizedBox(height: 16),

                          // QR Placeholder
                          Center(
                            child: Container(
                              width: 200,
                              height: 200,
                              decoration: BoxDecoration(
                                color: MonolithTheme.surface,
                                border: Border.all(
                                  color: MonolithTheme.primary,
                                  width: MonolithTheme.heroBorderWidth,
                                ),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.qr_code_2,
                                      size: 100,
                                      color: MonolithTheme.primary),
                                  const SizedBox(height: 8),
                                  Text('UPI QR CODE',
                                      style: MonolithTheme.labelSmall),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 8),
                              color: MonolithTheme.primary,
                              child: Text(
                                'UPI: donate@monolith',
                                style:
                                    MonolithTheme.labelMedium.copyWith(
                                  color: MonolithTheme.surface,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── International ──
                    MonolithCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                color: MonolithTheme.primary,
                                child: const Icon(Icons.public,
                                    color: MonolithTheme.surface,
                                    size: 18),
                              ),
                              const SizedBox(width: 12),
                              Text('INTERNATIONAL',
                                  style: MonolithTheme.headlineMedium),
                            ],
                          ),
                          const SizedBox(height: 16),

                          _buildDonationOption('PAYPAL', Icons.payment),
                          const SizedBox(height: 8),
                          _buildDonationOption(
                              'STRIPE', Icons.credit_card),
                          const SizedBox(height: 8),
                          _buildDonationOption(
                              'CRYPTO', Icons.currency_bitcoin),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── System Note ──
                    MonolithCard(
                      inverted: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.info_outline,
                                  color: MonolithTheme.surface, size: 18),
                              const SizedBox(width: 8),
                              Text(
                                'SYSTEM NOTE',
                                style:
                                    MonolithTheme.labelLarge.copyWith(
                                  color: MonolithTheme.surface,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'INTERNATIONAL TRANSACTIONS ARE PROCESSED THROUGH '
                            'ENCRYPTED MONOLITHIC CHANNELS. ALL CONTRIBUTIONS '
                            'ARE FINAL.',
                            style: MonolithTheme.bodyMedium.copyWith(
                              color: MonolithTheme.surfaceContainerHigh,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Container(
                            height: 1,
                            color:
                                MonolithTheme.surface.withValues(alpha: 0.2),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'BUILDING THE MONOLITH.',
                            style: MonolithTheme.labelLarge.copyWith(
                              color: MonolithTheme.surface,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Status: Secure',
                                style:
                                    MonolithTheme.labelSmall.copyWith(
                                  color:
                                      MonolithTheme.surfaceContainerHigh,
                                ),
                              ),
                              Text(
                                'Version: 2.0.4-B',
                                style:
                                    MonolithTheme.labelSmall.copyWith(
                                  color:
                                      MonolithTheme.surfaceContainerHigh,
                                ),
                              ),
                            ],
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
              currentIndex: 0,
              onTap: (i) {
                if (i == 0) {
                  Navigator.pushReplacementNamed(context, '/dashboard');
                } else if (i == 1) {
                  Navigator.pushReplacementNamed(context, '/ai-vision');
                } else if (i == 2) {
                  Navigator.pushReplacementNamed(context, '/projections');
                } else if (i == 3) {
                  Navigator.pushReplacementNamed(context, '/settings');
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDonationOption(String label, IconData icon) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: MonolithTheme.containerDecoration,
      child: Row(
        children: [
          Icon(icon, color: MonolithTheme.primary, size: 22),
          const SizedBox(width: 12),
          Text(label, style: MonolithTheme.labelLarge),
          const Spacer(),
          const Icon(Icons.chevron_right,
              color: MonolithTheme.primary, size: 24),
        ],
      ),
    );
  }
}
