import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_text_field.dart';
import '../../features/auth/auth_provider.dart';

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (name.isEmpty || email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all fields')),
      );
      return;
    }

    final user = await ref.read(authControllerProvider.notifier).signUpWithPassword(
          name: name,
          email: email,
          password: password,
        );

    if (!mounted) return;
    if (user != null) {
      Navigator.pushNamed(context, '/verify-link');
      return;
    }

    final error = ref.read(authControllerProvider).error;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? 'Account creation failed.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);

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
                onTap: () async {
                  // Sign out so AuthGate goes back to login, not onboarding.
                  // Route through the controller for the same full teardown
                  // (Google + session + cached profile) used everywhere else.
                  await ref.read(authControllerProvider.notifier).signOut();
                  if (!context.mounted) return;
                  Navigator.pop(context);
                },
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

              // ── Void_Factor Branding ──
              Text(
                'Void_Factor',
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
                obscureText: true,
              ),
              const SizedBox(height: 40),

              // ── Initialize Button ──
              if (authState.isLoading)
                const Center(
                  child: CircularProgressIndicator.adaptive(
                    valueColor: AlwaysStoppedAnimation<Color>(MonolithTheme.primary),
                  ),
                )
              else
                MonolithButton(
                  label: 'CREATE ACCOUNT',
                  onPressed: _submit,
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
                      onTap: () async {
                        // Sign out so AuthGate goes back to login, not onboarding.
                        await ref.read(authControllerProvider.notifier).signOut();
                        if (!context.mounted) return;
                        Navigator.pop(context);
                      },
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
