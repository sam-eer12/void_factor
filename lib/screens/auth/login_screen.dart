import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_text_field.dart';
import '../../features/auth/auth_provider.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
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
              const SizedBox(height: 60),

              // ── MONOLITH Logo ──
              Container(
                padding: EdgeInsets.zero,
                decoration: MonolithTheme.invertedCardDecoration,
                child: Image.asset(
                  'assets/images/icon3.jpg',
                  height: 105,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 40),

              // ── LOGIN Heading ──
              Text(
                'LOGIN',
                style: MonolithTheme.displayLarge,
              ),
              const SizedBox(height: 8),
              Container(
                width: 60,
                height: MonolithTheme.heroBorderWidth,
                color: MonolithTheme.primary,
              ),
              const SizedBox(height: 40),

              // ── Email Field ──
              MonolithTextField(
                label: 'Email',
                hint: 'your@email.com',
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 40),

              // ── Login Button & Google Sign-In ──
              if (authState.isLoading)
                const Center(
                  child: CircularProgressIndicator.adaptive(
                    valueColor: AlwaysStoppedAnimation<Color>(MonolithTheme.primary),
                  ),
                )
              else ...[
                MonolithButton(
                  label: 'SEND SIGN IN LINK',
                  onPressed: () async {
                    final email = _emailController.text.trim();
                    if (email.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please enter your email')),
                      );
                      return;
                    }
                    final success = await ref
                        .read(authControllerProvider.notifier)
                        .sendPasswordlessLink(email);
                    if (!context.mounted) return;
                    if (success) {
                      Navigator.pushNamed(context, '/verify-link');
                    } else {
                      final error = ref.read(authControllerProvider).error;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(error ?? 'Failed to send login link'),
                          action: SnackBarAction(
                            label: 'CREATE ACCOUNT',
                            onPressed: () {
                              Navigator.pushNamed(context, '/signup');
                            },
                          ),
                        ),
                      );
                    }
                  },
                ),
                const SizedBox(height: 16),
                MonolithButton(
                  label: 'SIGN IN WITH GOOGLE',
                  style: MonolithButtonStyle.secondary,
                  icon: Icons.login_outlined,
                  onPressed: () async {
                    final user = await ref
                        .read(authControllerProvider.notifier)
                        .signInWithGoogle();
                    if (!context.mounted) return;
                    if (user != null) {
                      Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
                    } else {
                      final error = ref.read(authControllerProvider).error;
                      if (error != null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(error)),
                        );
                      }
                    }
                  },
                ),
              ],
              const SizedBox(height: 24),

              // ── Divider ──
              Row(
                children: [
                  const Expanded(
                    child: Divider(
                      color: MonolithTheme.primary,
                      thickness: 1,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'OR',
                      style: MonolithTheme.labelMedium,
                    ),
                  ),
                  const Expanded(
                    child: Divider(
                      color: MonolithTheme.primary,
                      thickness: 1,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // ── Create Account ──
              MonolithButton(
                label: 'CREATE ACCOUNT',
                style: MonolithButtonStyle.secondary,
                onPressed: () {
                  Navigator.pushNamed(context, '/signup');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
