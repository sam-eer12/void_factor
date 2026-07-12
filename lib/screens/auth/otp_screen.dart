import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../app/auth_provider.dart';

class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({super.key});

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  final List<TextEditingController> _controllers =
      List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _focusNodes = List.generate(6, (_) => FocusNode());

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  void _onOtpChanged(String value, int index) {
    if (value.isNotEmpty && index < 5) {
      _focusNodes[index + 1].requestFocus();
    }
    if (value.isEmpty && index > 0) {
      _focusNodes[index - 1].requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);

    return Scaffold(
      backgroundColor: MonolithTheme.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight,
                ),
                child: IntrinsicHeight(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 40),

                        // ── Back Button ──
                        GestureDetector(
                          onTap: () => Navigator.pop(context),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: MonolithTheme.containerDecoration,
                            child: const Icon(
                              Icons.arrow_back,
                              color: MonolithTheme.primary,
                              size: 20,
                            ),
                          ),
                        ),
                        const SizedBox(height: 40),

                        // ── MONOLITH Logo ──
                        Text(
                          'MONOLITH',
                          style: MonolithTheme.displayLarge,
                        ),
                        const SizedBox(height: 32),

                        // ── Verify Identity Heading ──
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          decoration: MonolithTheme.invertedCardDecoration,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'VERIFY IDENTITY',
                                style: MonolithTheme.headlineLarge.copyWith(
                                  color: MonolithTheme.surface,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Enter the 6-digit code sent to your email.',
                                style: MonolithTheme.bodyMedium.copyWith(
                                  color: MonolithTheme.surfaceContainerHigh,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 40),

                        // ── OTP Input ──
                        Text(
                          'VERIFICATION CODE',
                          style: MonolithTheme.labelMedium,
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: List.generate(6, (index) {
                            return SizedBox(
                              width: 48,
                              height: 56,
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: MonolithTheme.primary,
                                    width: MonolithTheme.borderWidth,
                                  ),
                                  boxShadow: MonolithTheme.smallHardShadow,
                                  color: MonolithTheme.surface,
                                ),
                                child: TextField(
                                  controller: _controllers[index],
                                  focusNode: _focusNodes[index],
                                  textAlign: TextAlign.center,
                                  keyboardType: TextInputType.number,
                                  maxLength: 1,
                                  style: MonolithTheme.headlineLarge,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                  ],
                                  decoration: const InputDecoration(
                                    counterText: '',
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                  onChanged: (v) => _onOtpChanged(v, index),
                                ),
                              ),
                            );
                          }),
                        ),
                        const SizedBox(height: 40),

                        // ── Verify Button ──
                        if (authState.isLoading)
                          const Center(
                            child: CircularProgressIndicator.adaptive(
                              valueColor: AlwaysStoppedAnimation<Color>(MonolithTheme.primary),
                            ),
                          )
                        else
                          MonolithButton(
                            label: 'VERIFY IDENTITY',
                            onPressed: () async {
                              final enteredOtp = _controllers.map((c) => c.text).join();
                              if (enteredOtp.length < 6) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Please enter all 6 digits')),
                                );
                                return;
                              }

                              final success = await ref
                                  .read(authControllerProvider.notifier)
                                  .verifyOtpAndSignup(enteredOtp);

                              if (!context.mounted) return;
                              if (success) {
                                Navigator.pushNamedAndRemoveUntil(
                                  context,
                                  '/',
                                  (route) => false,
                                );
                              } else {
                                final error = ref.read(authControllerProvider).error;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(error ?? 'Verification failed')),
                                );
                              }
                            },
                          ),
                        const SizedBox(height: 24),

                        // ── Resend ──
                        Center(
                          child: GestureDetector(
                            onTap: () {
                              ref.read(authControllerProvider.notifier).resendOtp();
                              final newOtp = ref.read(authControllerProvider).otp;

                              // Show code to help user test
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Verification code resent. Code: $newOtp'),
                                  duration: const Duration(seconds: 5),
                                ),
                              );
                            },
                            child: Text(
                              'RESEND CODE',
                              style: MonolithTheme.labelMedium.copyWith(
                                decoration: TextDecoration.underline,
                                decorationThickness: 2,
                              ),
                            ),
                          ),
                        ),

                        const Spacer(),

                        // ── Timer ──
                        Center(
                          child: Container(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            decoration: MonolithTheme.containerDecoration,
                            child: Text(
                              'EXPIRES IN 04:59',
                              style: MonolithTheme.labelMedium,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
