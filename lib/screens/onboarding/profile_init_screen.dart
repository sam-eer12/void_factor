import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_text_field.dart';
import '../../widgets/monolith_card.dart';
import '../../features/auth/session_provider.dart';

class ProfileInitScreen extends ConsumerStatefulWidget {
  const ProfileInitScreen({super.key});

  @override
  ConsumerState<ProfileInitScreen> createState() => _ProfileInitScreenState();
}

class _ProfileInitScreenState extends ConsumerState<ProfileInitScreen> {
  bool _isLoading = false;
  int _currentStep = 0;
  final _heightController = TextEditingController();
  final _weightController = TextEditingController();
  final _ageController = TextEditingController();
  final _apiKeyController = TextEditingController();
  String _selectedGender = 'MALE';
  String _selectedProvider = 'GEMINI';

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
    final title = _currentStep == 0 ? 'BODY DATA' : 'API INTEGRATION';
    final subtitle = _currentStep == 0
        ? 'Step 1 of 2: Physical Metrics Configuration'
        : 'Step 2 of 2: AI Model API Key Settings';

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
                title,
                style: MonolithTheme.displayLarge,
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: MonolithTheme.bodyMedium.copyWith(
                  color: MonolithTheme.outline,
                ),
              ),
              const SizedBox(height: 32),

              if (_currentStep == 0) ...[
                // ── Physical Metrics Section (Step 1) ──
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
                const SizedBox(height: 32),

                // ── Next Step Button ──
                MonolithButton(
                  label: 'NEXT STEP',
                  onPressed: () {
                    final height = double.tryParse(_heightController.text);
                    final weight = double.tryParse(_weightController.text);
                    final age = int.tryParse(_ageController.text);

                    if (height == null || weight == null || age == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please enter valid physical metrics.')),
                      );
                      return;
                    }
                    setState(() => _currentStep = 1);
                  },
                ),
              ] else ...[
                // ── API Key Page (Step 2) ──
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

                      // API Provider Selection
                      Text(
                        'API PROVIDER',
                        style: MonolithTheme.labelMedium,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: ['GEMINI', 'OPENROUTER', 'NVIDIA NIM'].map((provider) {
                          final isSelected = _selectedProvider == provider;
                          return Expanded(
                            child: GestureDetector(
                              onTap: () =>
                                  setState(() => _selectedProvider = provider),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                margin: EdgeInsets.only(
                                  right: provider != 'NVIDIA NIM' ? 6 : 0,
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
                                    provider,
                                    style: MonolithTheme.labelSmall.copyWith(
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
                      const SizedBox(height: 24),

                      // API Key Field
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

                // ── Control Buttons ──
                if (_isLoading)
                  const Center(
                    child: CircularProgressIndicator.adaptive(
                      valueColor: AlwaysStoppedAnimation<Color>(MonolithTheme.primary),
                    ),
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: MonolithButton(
                          label: 'BACK',
                          style: MonolithButtonStyle.secondary,
                          onPressed: () {
                            setState(() => _currentStep = 0);
                          },
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: MonolithButton(
                          label: 'INITIALIZE',
                          onPressed: () async {
                            final height = double.tryParse(_heightController.text);
                            final weight = double.tryParse(_weightController.text);
                            final age = int.tryParse(_ageController.text);
                            final gender = _selectedGender;
                            final apiKey = _apiKeyController.text.trim();

                            if (height == null || weight == null || age == null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Please enter valid physical metrics.')),
                              );
                              return;
                            }

                            if (apiKey.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Please enter your API Key.')),
                              );
                              return;
                            }

                            setState(() => _isLoading = true);
                            try {
                              await ref.read(sessionServiceProvider).completeOnboarding(
                                height: height,
                                weight: weight,
                                age: age,
                                gender: gender,
                                apiKey: apiKey,
                                apiProvider: _selectedProvider,
                              );
                              ref.read(authFlowProvider.notifier).markOnboardingComplete();
                              if (context.mounted) {
                                Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
                              }
                            } catch (e) {
                              setState(() => _isLoading = false);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Failed to save configuration: $e')),
                                );
                              }
                            }
                          },
                        ),
                      ),
                    ],
                  ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
