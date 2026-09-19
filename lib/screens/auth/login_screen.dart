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
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// The primary route in. Nothing here depends on an email arriving, on which
  /// device a link is opened, or on App Links being verified — which is what
  /// makes it the one path that cannot be broken by any of those.
  Future<void> _signInWithPassword() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      _toast('Enter your email and password');
      return;
    }

    final user = await ref
        .read(authControllerProvider.notifier)
        .signInWithPassword(email, password);

    if (!mounted) return;
    if (user == null) {
      _toast(ref.read(authControllerProvider).error ?? 'Sign-in failed');
      return;
    }

    // An account created but never confirmed still signs in — Firebase does not
    // block it — so the gate is here. The session is live, which is exactly
    // what the verify screen needs: it can poll, and a link opened on any
    // device will release this one.
    if (!user.emailVerified) {
      // A send that fails must not strand them on the login screen with a
      // signed-in session and no explanation: the verify screen can resend,
      // and its polling is already watching for a link sent earlier.
      var sent = true;
      try {
        await ref.read(authControllerProvider.notifier).sendVerificationEmail(user);
      } catch (_) {
        sent = false;
      }
      if (!mounted) return;
      _toast(sent
          ? 'Confirm your email to continue — we sent a new link.'
          : 'Confirm your email to continue. Use RESEND if no link arrives.');
      Navigator.pushNamed(context, '/verify-link');
      return;
    }

    Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
  }

  /// The way back in for someone who has forgotten their password. Kept
  /// secondary because the code in the email is single-use and burned by
  /// whichever device opens it — so it only works if the link is opened on
  /// this phone, which the confirmation says out loud.
  Future<void> _sendSignInLink() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      _toast('Enter your email first');
      return;
    }

    final success = await ref
        .read(authControllerProvider.notifier)
        .sendPasswordlessLink(email);

    if (!mounted) return;
    if (success) {
      _toast('Link sent. Open it on this device — it will not work elsewhere.');
      Navigator.pushNamed(context, '/verify-link');
      return;
    }

    final error = ref.read(authControllerProvider).error;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error ?? 'Failed to send login link'),
        action: SnackBarAction(
          label: 'CREATE ACCOUNT',
          onPressed: () => Navigator.pushNamed(context, '/signup'),
        ),
      ),
    );
  }

  Future<void> _signInWithGoogle() async {
    final user =
        await ref.read(authControllerProvider.notifier).signInWithGoogle();
    if (!mounted) return;
    if (user != null) {
      Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
      return;
    }
    final error = ref.read(authControllerProvider).error;
    if (error != null) _toast(error);
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

              // ── Void_Factor Logo ──
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
              const SizedBox(height: 20),

              // ── Password Field ──
              MonolithTextField(
                label: 'Password',
                hint: '••••••••',
                controller: _passwordController,
                obscureText: true,
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
                  label: 'LOG IN',
                  onPressed: _signInWithPassword,
                ),
                const SizedBox(height: 16),
                MonolithButton(
                  label: 'SIGN IN WITH GOOGLE',
                  style: MonolithButtonStyle.secondary,
                  icon: Icons.login_outlined,
                  onPressed: _signInWithGoogle,
                ),
                const SizedBox(height: 16),
                Center(
                  child: GestureDetector(
                    onTap: _sendSignInLink,
                    child: Text(
                      'FORGOT PASSWORD? EMAIL ME A LINK',
                      style: MonolithTheme.labelMedium.copyWith(
                        decoration: TextDecoration.underline,
                        decorationThickness: 2,
                      ),
                    ),
                  ),
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
