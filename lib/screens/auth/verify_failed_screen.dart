import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../app/auth_provider.dart';

class VerifyFailedScreen extends ConsumerWidget {
  const VerifyFailedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authControllerProvider);
    final email = authState.email;

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

              // ── MONOLITH Branding ──
              Text(
                'MONOLITH',
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
                      final success = await ref
                          .read(authControllerProvider.notifier)
                          .sendPasswordlessLink(email, name: authState.name);

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
