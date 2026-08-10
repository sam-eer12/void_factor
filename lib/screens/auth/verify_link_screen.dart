import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_text_field.dart';
import '../../features/auth/auth_provider.dart';

class VerifyLinkScreen extends ConsumerStatefulWidget {
  const VerifyLinkScreen({super.key});

  @override
  ConsumerState<VerifyLinkScreen> createState() => _VerifyLinkScreenState();
}

class _VerifyLinkScreenState extends ConsumerState<VerifyLinkScreen> {
  final _linkController = TextEditingController();
  late Timer _timer;
  int _secondsRemaining = 300; // 5 minutes
  bool _isVerified = false;

  final _syncEngine = VerificationPollingEngine();

  @override
  void initState() {
    super.initState();
    _startTimer();
    _syncEngine.startVerificationPolling(context, () {
      Navigator.pushNamedAndRemoveUntil(context, '/onboarding', (route) => false);
    });
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining > 0) {
        setState(() {
          _secondsRemaining--;
        });
      } else {
        _timer.cancel();
      }
    });
  }

  String _formatTime(int totalSeconds) {
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _timer.cancel();
    _syncEngine.dispose();
    _linkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);
    final isExpired = _secondsRemaining == 0;

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

                        // ── Success State or Waiting State ──
                        if (_isVerified) ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: MonolithTheme.primary,
                              border: Border.all(color: MonolithTheme.primary, width: 2),
                              boxShadow: MonolithTheme.hardShadow,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.check_circle_outline,
                                  color: MonolithTheme.surface,
                                  size: 64,
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  'VERIFICATION COMPLETE',
                                  style: MonolithTheme.headlineMedium.copyWith(
                                    color: MonolithTheme.surface,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Your identity has been authenticated. Redirecting you to the system configuration...',
                                  style: MonolithTheme.bodyMedium.copyWith(
                                    color: MonolithTheme.surfaceContainerHigh,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        ] else ...[
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
                          const SizedBox(height: 32),

                          // ── Buffering & Timer Indicator ──
                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: MonolithTheme.cardDecoration,
                            child: Row(
                              children: [
                                isExpired
                                    ? const Icon(
                                        Icons.error_outline,
                                        color: MonolithTheme.error,
                                        size: 28,
                                      )
                                    : const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 3,
                                          valueColor: AlwaysStoppedAnimation<Color>(MonolithTheme.primary),
                                        ),
                                      ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        isExpired
                                            ? 'LINK EXPIRED'
                                            : 'WAITING FOR CONFIRMATION...',
                                        style: MonolithTheme.labelMedium.copyWith(
                                          color: isExpired ? MonolithTheme.error : MonolithTheme.primary,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        isExpired
                                            ? 'Please request a new access link.'
                                            : 'Expires in: ${_formatTime(_secondsRemaining)}',
                                        style: MonolithTheme.labelSmall.copyWith(
                                          color: MonolithTheme.outline,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        const SizedBox(height: 40),

                        // ── Paste Link Field (Only show if not verified) ──
                        if (!_isVerified) ...[
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
                              onPressed: isExpired
                                  ? null
                                  : () async {
                                      final link = _linkController.text.trim();
                                      if (link.isEmpty) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('Please paste the email link to sign in')),
                                        );
                                        return;
                                      }

                                      // Check if it is a verification link (contains oobCode and mode=verifyEmail)
                                      final uri = Uri.tryParse(link);
                                      if (uri != null && uri.queryParameters['mode'] == 'verifyEmail' && uri.queryParameters['oobCode'] != null) {
                                        try {
                                          final auth = FirebaseAuth.instance;
                                          await auth.applyActionCode(uri.queryParameters['oobCode']!);
                                          final user = auth.currentUser;
                                          if (user != null) {
                                            await user.reload();
                                          }
                                          if (auth.currentUser?.emailVerified == true) {
                                            setState(() {
                                              _isVerified = true;
                                            });
                                            _timer.cancel();
                                            _syncEngine.dispose();
                                            if (!context.mounted) return;
                                            Future.delayed(const Duration(seconds: 2), () {
                                              if (context.mounted) {
                                                Navigator.pushNamedAndRemoveUntil(
                                                  context,
                                                  '/onboarding',
                                                  (route) => false,
                                                );
                                              }
                                            });
                                            return;
                                          }
                                        } catch (e) {
                                          if (!context.mounted) return;
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(content: Text('Verification failed: ${e.toString()}')),
                                          );
                                          return;
                                        }
                                      }

                                      final user = await ref
                                          .read(authControllerProvider.notifier)
                                          .signInWithLink(link);

                                      if (!context.mounted) return;
                                      if (user != null) {
                                        setState(() {
                                          _isVerified = true;
                                        });

                                        // Stop the countdown timer
                                        _timer.cancel();
                                        _syncEngine.dispose();

                                        // Wait a short moment to let user read success message, then navigate to '/onboarding'
                                        Future.delayed(const Duration(seconds: 2), () {
                                          if (context.mounted) {
                                            Navigator.pushNamedAndRemoveUntil(
                                              context,
                                              '/onboarding',
                                              (route) => false,
                                            );
                                          }
                                        });
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
                                  setState(() {
                                    _secondsRemaining = 300;
                                  });
                                  _timer.cancel();
                                  _startTimer();
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
                        ],

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

class VerificationPollingEngine {
  Timer? _pollingTimer;

  void startVerificationPolling(BuildContext context, VoidCallback onVerified) {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        try {
          await user.reload();
          final updatedUser = FirebaseAuth.instance.currentUser;
          if (updatedUser != null && updatedUser.emailVerified) {
            timer.cancel();
            onVerified();
          }
        } catch (_) {
          // Ignore transient network errors during background polling
        }
      }
    });
  }

  void dispose() {
    _pollingTimer?.cancel();
  }
}
