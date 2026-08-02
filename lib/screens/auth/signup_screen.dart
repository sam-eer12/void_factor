import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
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
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> handleSecureSignUp({
    required String email,
    required String password,
    required String name,
    required BuildContext context,
  }) async {
    final auth = FirebaseAuth.instance;

    try {
      UserCredential userCredential = await auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (userCredential.user != null) {
        if (name.isNotEmpty) {
          await userCredential.user!.updateDisplayName(name);
        }

        // Send verification email in a separate try-catch so that
        // account creation success is never masked by a verification failure
        try {
          final actionCodeSettings = ActionCodeSettings(
            url: 'https://signinpractice-bfade.firebaseapp.com/onboarding',
            handleCodeInApp: true,
            androidPackageName: 'com.voidfactor.app',
            androidMinimumVersion: '1',
            androidInstallApp: true,
            iOSBundleId: 'com.voidfactor.app',
          );
          await userCredential.user!.sendEmailVerification(actionCodeSettings);
        } catch (_) {
          // Fallback: send verification without custom ActionCodeSettings
          await userCredential.user!.sendEmailVerification();
        }

        if (!context.mounted) return;
        Navigator.pushNamed(context, '/verify-link');
      }

    } on FirebaseAuthException catch (e) {
      if (!context.mounted) return;
      String message = 'Authentication failed.';
      if (e.code == 'email-already-in-use') {
        message = 'This email is already registered. Please log in.';
      } else if (e.code == 'weak-password') {
        message = 'The password provided is too weak.';
      } else if (e.code == 'invalid-email') {
        message = 'The email address is malformed.';
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('An unexpected error occurred.')),
      );
    }
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
                obscureText: true,
              ),
              const SizedBox(height: 40),

              // ── Initialize Button ──
              if (_isLoading)
                const Center(
                  child: CircularProgressIndicator.adaptive(
                    valueColor: AlwaysStoppedAnimation<Color>(MonolithTheme.primary),
                  ),
                )
              else
                MonolithButton(
                  label: 'SEND SIGN UP LINK',
                  onPressed: () async {
                    final name = _nameController.text.trim();
                    final email = _emailController.text.trim();
                    final password = _passwordController.text.trim();

                    if (name.isEmpty || email.isEmpty || password.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please fill all fields')),
                      );
                      return;
                    }

                    setState(() => _isLoading = true);
                    await handleSecureSignUp(
                      email: email,
                      password: password,
                      name: name,
                      context: context,
                    );
                    if (mounted) {
                      setState(() => _isLoading = false);
                    }
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
