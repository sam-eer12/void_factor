import 'package:flutter/material.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_text_field.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
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
                  Navigator.pushNamed(context, '/otp');
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
