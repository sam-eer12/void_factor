import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../features/auth/auth_provider.dart';

class VerifyFailedScreen extends ConsumerWidget {
  const VerifyFailedScreen({super.key});

  /// Resends whichever email this user is actually waiting on.
  ///
  /// A live session means the account exists and only wants confirming; no
  /// session means there is nothing to confirm against and the address needs a
  /// sign-in link instead. Sending the wrong one hands back a code that cannot
  /// complete the flow the user is in.
  Future<bool> _resend(WidgetRef ref) async {
    final controller = ref.read(authControllerProvider.notifier);
    final user = FirebaseAuth.instance.currentUser;

    if (user != null) {
      try {
        await controller.sendVerificationEmail(user);
        return true;
      } catch (_) {
        return false;
      }
    }

    final state = ref.read(authControllerProvider);
    if (state.email.isEmpty) return false;
    return controller.sendPasswordlessLink(state.email, name: state.name);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authControllerProvider);
    // Either half is enough to resend: the signed-in address when the account
    // exists, the remembered one when it does not.
    final email = FirebaseAuth.instance.currentUser?.email ?? authState.email;

    return Scaffold(
      backgroundColor: MonolithTheme.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),

              // ── Back Button ──
              GestureDetector(
                onTap: () => Navigator.pushNamedAndRemoveUntil(
                  context,
                  '/',
                  (route) => false,
                ),
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

              // ── Void_Factor Branding ──
              Text(
                'Void_Factor',
                style: MonolithTheme.displayLarge,
              ),
              const SizedBox(height: 32),

              // ── Error Card ──
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: MonolithTheme.surface,
                  border: Border.all(color: MonolithTheme.error, width: 3),
                  boxShadow: MonolithTheme.hardShadow,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: MonolithTheme.error,
                      size: 64,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'VERIFICATION FAILED',
                      style: MonolithTheme.headlineMedium.copyWith(
                        color: MonolithTheme.error,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'The authentication link is invalid, expired, or has already been used.',
                      style: MonolithTheme.bodyMedium.copyWith(
                        color: MonolithTheme.outline,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),

              // ── Resend Link (if email is available) ──
              if (email.isNotEmpty) ...[
                if (authState.isLoading)
                  const Center(
                    child: CircularProgressIndicator.adaptive(
                      valueColor: AlwaysStoppedAnimation<Color>(MonolithTheme.primary),
                    ),
                  )
                else
                  MonolithButton(
                    label: 'RESEND LINK',
                    onPressed: () async {
                      final success = await _resend(ref);

                      if (!context.mounted) return;
                      if (success) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Verification link resent successfully.'),
                          ),
                        );
                        Navigator.pushNamed(context, '/verify-link');
                      } else {
                        final error = ref.read(authControllerProvider).error;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(error ?? 'Failed to resend link'),
                          ),
                        );
                      }
                    },
                  ),
                const SizedBox(height: 16),
              ],

              // ── Back to Login Button ──
              MonolithButton(
                label: 'RETURN TO LOGIN',
                style: MonolithButtonStyle.secondary,
                onPressed: () {
                  Navigator.pushNamedAndRemoveUntil(
                    context,
                    '/',
                    (route) => false,
                  );
                },
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
