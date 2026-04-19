import 'package:flutter/material.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_text_field.dart';
import '../../widgets/monolith_card.dart';

class ProfileInitScreen extends StatefulWidget {
  const ProfileInitScreen({super.key});

  @override
  State<ProfileInitScreen> createState() => _ProfileInitScreenState();
}

class _ProfileInitScreenState extends State<ProfileInitScreen> {
  final _heightController = TextEditingController();
  final _weightController = TextEditingController();
  final _ageController = TextEditingController();
  final _apiKeyController = TextEditingController();
  String _selectedGender = 'MALE';

  @override
  void dispose() {
    _heightController.dispose();
    _weightController.dispose();
    _ageController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MonolithTheme.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),

              // ── Header ──
              Text(
                'INITIALIZE',
                style: MonolithTheme.displayLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'System Configuration required',
                style: MonolithTheme.bodyMedium.copyWith(
                  color: MonolithTheme.outline,
                ),
              ),
              const SizedBox(height: 32),

              // ── Physical Metrics Section ──
              MonolithCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          color: MonolithTheme.primary,
                          child: const Icon(
                            Icons.straighten,
                            color: MonolithTheme.surface,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'PHYSICAL METRICS',
                          style: MonolithTheme.headlineMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Height & Weight row
                    Row(
                      children: [
                        Expanded(
                          child: MonolithTextField(
                            label: 'Height (cm)',
                            hint: '175',
                            controller: _heightController,
                            keyboardType: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: MonolithTextField(
                            label: 'Weight (kg)',
                            hint: '70',
                            controller: _weightController,
                            keyboardType: TextInputType.number,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // Age
                    MonolithTextField(
                      label: 'Age',
                      hint: '25',
                      controller: _ageController,
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 20),

                    // Gender Selection
                    Text(
                      'GENDER',
                      style: MonolithTheme.labelMedium,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: ['MALE', 'FEMALE', 'OTHER'].map((gender) {
                        final isSelected = _selectedGender == gender;
                        return Expanded(
                          child: GestureDetector(
                            onTap: () =>
                                setState(() => _selectedGender = gender),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              margin: EdgeInsets.only(
                                right: gender != 'OTHER' ? 8 : 0,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? MonolithTheme.primary
                                    : MonolithTheme.surface,
                                border: Border.all(
                                  color: MonolithTheme.primary,
                                  width: MonolithTheme.borderWidth,
                                ),
                              ),
                              child: Center(
                                child: Text(
                                  gender,
                                  style:
                                      MonolithTheme.labelMedium.copyWith(
                                    color: isSelected
                                        ? MonolithTheme.surface
                                        : MonolithTheme.primary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // ── API Integration Section ──
              MonolithCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          color: MonolithTheme.primary,
                          child: const Icon(
                            Icons.api,
                            color: MonolithTheme.surface,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'API INTEGRATION',
                          style: MonolithTheme.headlineMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    MonolithTextField(
                      label: 'API Key',
                      hint: 'Enter your API key',
                      controller: _apiKeyController,
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: MonolithTheme.primary,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.lock,
                              size: 16, color: MonolithTheme.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Key is stored locally. Never transmitted unencrypted.',
                              style: MonolithTheme.labelSmall.copyWith(
                                color: MonolithTheme.outline,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              // ── Initialize Button ──
              MonolithButton(
                label: 'INITIALIZE SYSTEM',
                onPressed: () {
                  Navigator.pushReplacementNamed(context, '/dashboard');
                },
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
