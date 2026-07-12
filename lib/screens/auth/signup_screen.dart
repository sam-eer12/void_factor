import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_text_field.dart';
import '../../app/auth_provider.dart';

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
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
              const SizedBox(height: 32),

              // ── MONOLITH Branding ──
              Text(
                'MONOLITH',
                style: MonolithTheme.displayLarge,
              ),
              const SizedBox(height: 24),

              // ── NEW USER heading ──
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: MonolithTheme.invertedCardDecoration,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'NEW USER',
                      style: MonolithTheme.headlineLarge.copyWith(
                        color: MonolithTheme.surface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Initialize your training node.',
                      style: MonolithTheme.bodyMedium.copyWith(
                        color: MonolithTheme.surfaceContainerHigh,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              // ── Full Name ──
              MonolithTextField(
                label: 'Full Name',
                hint: 'John Doe',
                controller: _nameController,
                keyboardType: TextInputType.name,
              ),
              const SizedBox(height: 20),

              // ── Email ──
              MonolithTextField(
                label: 'Email',
                hint: 'your@email.com',
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 20),

              // ── Password ──
              MonolithTextField(
                label: 'Password',
                hint: '••••••••',
                controller: _passwordController,
                obscureText: _obscurePassword,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_off
                        : Icons.visibility,
                    color: MonolithTheme.primary,
                  ),
                  onPressed: () {
                    setState(() => _obscurePassword = !_obscurePassword);
                  },
                ),
              ),
              const SizedBox(height: 20),

              // ── Confirm Password ──
              MonolithTextField(
                label: 'Confirm Password',
                hint: '••••••••',
                controller: _confirmPasswordController,
                obscureText: _obscureConfirm,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureConfirm
                        ? Icons.visibility_off
                        : Icons.visibility,
                    color: MonolithTheme.primary,
                  ),
                  onPressed: () {
                    setState(() => _obscureConfirm = !_obscureConfirm);
                  },
                ),
              ),
              const SizedBox(height: 32),

              // ── Initialize Button ──
              MonolithButton(
                label: 'INITIALIZE',
                onPressed: () {
                  final name = _nameController.text.trim();
                  final email = _emailController.text.trim();
                  final password = _passwordController.text;
                  final confirmPassword = _confirmPasswordController.text;

                  if (name.isEmpty || email.isEmpty || password.isEmpty || confirmPassword.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please fill all fields')),
                    );
                    return;
                  }

                  if (password != confirmPassword) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Passwords do not match')),
                    );
                    return;
                  }

                  if (password.length < 6) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Password must be at least 6 characters')),
                    );
                    return;
                  }

                  // Start verification
                  ref.read(authControllerProvider.notifier).initiateSignup(
                    name: name,
                    email: email,
                    password: password,
                  );

                  // Retrieve the generated OTP from state
                  final generatedOtp = ref.read(authControllerProvider).otp;

                  // Show verification HUD/Dialog so the user can easily see the code
                  showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (dialogContext) => AlertDialog(
                      backgroundColor: MonolithTheme.surface,
                      shape: const RoundedRectangleBorder(
                        side: BorderSide(color: MonolithTheme.primary, width: 2),
                      ),
                      title: Text(
                        'IDENTITY VERIFICATION CODE',
                        style: MonolithTheme.headlineMedium,
                      ),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'A verification code has been generated for $email.',
                            style: MonolithTheme.bodyMedium,
                          ),
                          const SizedBox(height: 16),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(16),
                            color: MonolithTheme.primary,
                            child: Center(
                              child: Text(
                                generatedOtp,
                                style: MonolithTheme.headlineLarge.copyWith(
                                  color: MonolithTheme.surface,
                                  letterSpacing: 8,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Enter this code on the next screen to verify and activate your node.',
                            style: MonolithTheme.labelSmall.copyWith(color: MonolithTheme.outline),
                          ),
                        ],
                      ),
                      actions: [
                        TextButton(
                          onPressed: () {
                            Navigator.pop(dialogContext); // Close dialog
                            Navigator.pushNamed(context, '/otp'); // Navigate to OTP screen
                          },
                          child: Text(
                            'PROCEED',
                            style: MonolithTheme.labelLarge,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 24),

              // ── Already a user ──
              Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'ALREADY A USER? ',
                      style: MonolithTheme.labelMedium,
                    ),
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        color: MonolithTheme.primary,
                        child: Text(
                          'LOG IN',
                          style: MonolithTheme.labelMedium.copyWith(
                            color: MonolithTheme.surface,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
