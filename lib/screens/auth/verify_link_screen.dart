import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_text_field.dart';
import '../../app/auth_provider.dart';

class VerifyLinkScreen extends ConsumerStatefulWidget {
  const VerifyLinkScreen({super.key});

  @override
  ConsumerState<VerifyLinkScreen> createState() => _VerifyLinkScreenState();
}

class _VerifyLinkScreenState extends ConsumerState<VerifyLinkScreen> {
  final _linkController = TextEditingController();

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
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

                        // ── MONOLITH Branding ──
                        Text(
                          'MONOLITH',
                          style: MonolithTheme.displayLarge,
                        ),
                        const SizedBox(height: 32),

                        // ── Check Mailbox Heading ──
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          decoration: MonolithTheme.invertedCardDecoration,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'CHECK MAILBOX',
                                style: MonolithTheme.headlineLarge.copyWith(
                                  color: MonolithTheme.surface,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'We have dispatched a secure authentication link to your email.',
                                style: MonolithTheme.bodyMedium.copyWith(
                                  color: MonolithTheme.surfaceContainerHigh,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 40),

                        // ── Paste Link Field ──
                        MonolithTextField(
                          label: 'PASTE AUTHENTICATION LINK',
                          hint: 'https://signinpractice-bfade.firebaseapp.com/__/auth/...',
                          controller: _linkController,
                          keyboardType: TextInputType.url,
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
                            label: 'COMPLETE ACCESS',
                            onPressed: () async {
                              final link = _linkController.text.trim();
                              if (link.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Please paste the email link to sign in')),
                                );
                                return;
                              }

                              final user = await ref
                                  .read(authControllerProvider.notifier)
                                  .signInWithLink(link);

                              if (!context.mounted) return;
                              if (user != null) {
                                Navigator.pushNamedAndRemoveUntil(
                                  context,
                                  '/',
                                  (route) => false,
                                );
                              } else {
                                final error = ref.read(authControllerProvider).error;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(error ?? 'Authentication failed')),
                                );
                              }
                            },
                          ),
                        const SizedBox(height: 24),

                        // ── Resend Link ──
                        Center(
                          child: GestureDetector(
                            onTap: () async {
                              final email = authState.email;
                              if (email.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Could not resend. Go back and enter your email again.')),
                                );
                                return;
                              }

                              final success = await ref
                                  .read(authControllerProvider.notifier)
                                  .sendPasswordlessLink(email, name: authState.name);

                              if (!context.mounted) return;
                              if (success) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Verification link resent successfully.')),
                                );
                              } else {
                                final error = ref.read(authControllerProvider).error;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(error ?? 'Failed to resend link')),
                                );
                              }
                            },
                            child: Text(
                              'RESEND LINK',
                              style: MonolithTheme.labelMedium.copyWith(
                                decoration: TextDecoration.underline,
                                decorationThickness: 2,
                              ),
                            ),
                          ),
                        ),

                        const Spacer(),
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
