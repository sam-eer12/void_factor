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

class _VerifyLinkScreenState extends ConsumerState<VerifyLinkScreen>
    with WidgetsBindingObserver {
  final _linkController = TextEditingController();
  late Timer _timer;
  int _secondsRemaining = 300; // 5 minutes
  bool _isVerified = false;

  final _syncEngine = VerificationPollingEngine();

  /// Whether this device holds a session that a remote confirmation can
  /// release.
  ///
  /// True for the sign-up and unverified-login paths, where the account
  /// already signed this device in — those are the flows where clicking the
  /// link on a laptop still works, because the confirmation lands on the
  /// server and this device notices. False on the passwordless path, where
  /// there is no session yet and the one-time code has to be spent *here*.
  bool get _hasPendingSession => FirebaseAuth.instance.currentUser != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTimer();
    _syncEngine.start(onVerified: _onVerified);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the mail app — or from a laptop, phone in hand — is the
    // moment the answer is most likely to have changed. Waiting out the rest of
    // the poll interval here is what made the app look dead on return.
    if (state == AppLifecycleState.resumed) {
      _syncEngine.checkNow();
    }
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

  /// The single exit taken by all three routes in — the poll, the resume check
  /// and the pasted link — so none of them can leave the timers running or
  /// land somewhere the others do not.
  void _onVerified() {
    if (_isVerified || !mounted) return;

    _timer.cancel();
    _syncEngine.dispose();
    setState(() => _isVerified = true);

    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      // Back to the gate rather than straight to '/onboarding': the gate is
      // what knows whether this user still has onboarding to do or a dashboard
      // to return to. Pushing onboarding directly sent people who had already
      // finished it through it a second time.
      Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
    });
  }

  Future<void> _submitPastedLink() async {
    final link = _linkController.text.trim();
    if (link.isEmpty) {
      _toast('Please paste the link from the email');
      return;
    }

    final uri = Uri.tryParse(link);
    final mode = uri?.queryParameters['mode'];
    final oobCode = uri?.queryParameters['oobCode'];

    // A verification code is applied against the session this device already
    // holds; a sign-in code mints a new one. They are not interchangeable, and
    // which arrived is written on the link.
    if (mode == 'verifyEmail' && oobCode != null) {
      try {
        final auth = FirebaseAuth.instance;
        await auth.applyActionCode(oobCode);
        await auth.currentUser?.reload();
        if (auth.currentUser?.emailVerified == true) {
          _onVerified();
          return;
        }
        if (!mounted) return;
        _toast('Email confirmed, but this device has no session. Log in again.');
      } catch (e) {
        if (!mounted) return;
        _toast('Verification failed: ${e.toString()}');
      }
      return;
    }

    final user =
        await ref.read(authControllerProvider.notifier).signInWithLink(link);

    if (!mounted) return;
    if (user != null) {
      _onVerified();
      return;
    }
    _toast(ref.read(authControllerProvider).error ?? 'Authentication failed');
  }

  Future<void> _resend() async {
    final user = FirebaseAuth.instance.currentUser;

    // Same screen, two different emails. Sending a sign-in link to someone who
    // is already signed in and merely unconfirmed would hand them a code that
    // cannot confirm anything.
    if (user != null) {
      try {
        await ref.read(authControllerProvider.notifier).sendVerificationEmail(user);
      } catch (e) {
        if (!mounted) return;
        _toast('Could not resend: ${e.toString()}');
        return;
      }
      if (!mounted) return;
      _restartCountdown();
      _toast('Confirmation link resent to ${user.email ?? 'your address'}.');
      return;
    }

    final email = ref.read(authControllerProvider).email;
    if (email.isEmpty) {
      _toast('Could not resend. Go back and enter your email again.');
      return;
    }

    final success = await ref
        .read(authControllerProvider.notifier)
        .sendPasswordlessLink(email, name: ref.read(authControllerProvider).name);

    if (!mounted) return;
    if (success) {
      _restartCountdown();
      _toast('Sign-in link resent. Open it on this device.');
      return;
    }
    _toast(ref.read(authControllerProvider).error ?? 'Failed to resend link');
  }

  void _restartCountdown() {
    _timer.cancel();
    setState(() => _secondsRemaining = 300);
    _startTimer();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer.cancel();
    _syncEngine.dispose();
    _linkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);
    // The countdown has run out — which says nothing about the link, whose own
    // validity Firebase measures in hours. It is a prompt to resend, not a
    // verdict, so it no longer blocks the button underneath it.
    final countdownDone = _secondsRemaining == 0;

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

                        // ── Void_Factor Branding ──
                        Text(
                          'Void_Factor',
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
                                  'Your identity has been authenticated. Taking you in...',
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
                                  _hasPendingSession
                                      ? 'We have dispatched a confirmation link to your email. Open it anywhere — on this phone or on a computer — and this screen will carry on by itself.'
                                      : 'We have dispatched a sign-in link to your email. Open it on this device: the link signs in whichever device opens it, and it can only be used once.',
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
                                countdownDone
                                    ? const Icon(
                                        Icons.mark_email_unread_outlined,
                                        color: MonolithTheme.primary,
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
                                        countdownDone
                                            ? 'STILL WAITING'
                                            : 'WAITING FOR CONFIRMATION...',
                                        style: MonolithTheme.labelMedium.copyWith(
                                          color: MonolithTheme.primary,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        countdownDone
                                            ? 'No email yet? Resend it below.'
                                            : 'Checking for: ${_formatTime(_secondsRemaining)}',
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
                              onPressed: _submitPastedLink,
                            ),
                          const SizedBox(height: 24),

                          // ── Resend Link ──
                          Center(
                            child: GestureDetector(
                              onTap: _resend,
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

/// Watches the server for a confirmation this device did not perform itself.
///
/// `emailVerified` is a property of the *account*, not of this session, so a
/// link opened in a browser on another machine changes it here too — but only
/// once the local user record is refetched. That refetch is the whole engine:
/// [checkNow] is the single implementation, driven on a timer and also called
/// directly when the app returns to the foreground.
class VerificationPollingEngine {
  Timer? _pollingTimer;
  VoidCallback? _onVerified;
  bool _finished = false;

  void start({required VoidCallback onVerified}) {
    _onVerified = onVerified;
    _pollingTimer?.cancel();
    _pollingTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => checkNow());
  }

  Future<void> checkNow() async {
    if (_finished) return;
    final user = FirebaseAuth.instance.currentUser;
    // No session to refresh — the passwordless path, where the code has to be
    // spent on this device and nothing the server holds can release it.
    if (user == null) return;

    try {
      await user.reload();
    } catch (_) {
      // Transient network failure. The next tick — or the next resume — asks
      // again; treating it as "not verified" is already the right answer.
      return;
    }

    if (FirebaseAuth.instance.currentUser?.emailVerified == true) {
      _finished = true;
      _pollingTimer?.cancel();
      _onVerified?.call();
    }
  }

  void dispose() {
    _finished = true;
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }
}
