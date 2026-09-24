import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/monolith_theme.dart';
import '../../features/auth/session_provider.dart';
import 'login_screen.dart';
import '../onboarding/profile_init_screen.dart';
import '../dashboard/monolith_shell.dart';

class AuthGate extends ConsumerStatefulWidget {
  const AuthGate({super.key});

  @override
  ConsumerState<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<AuthGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Re-evaluate session on app resume (handles inactivity expiry)
      ref.read(authFlowProvider.notifier).checkFlow();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Screens above this one are restored on a relaunch before the session has
    // been checked. If the check then lands anywhere but the dashboard — the
    // session was ended from another device while the app was away — those
    // screens belong to a user who is no longer signed in here, and must not
    // stay stacked over the login screen.
    ref.listen<AuthFlowState>(authFlowProvider, (previous, next) {
      final settledOrStarting = previous == AuthFlowState.loading ||
          previous == AuthFlowState.dashboard;
      final signedOut =
          next == AuthFlowState.login || next == AuthFlowState.onboarding;
      if (settledOrStarting && signedOut) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });

    final flowState = ref.watch(authFlowProvider);

    switch (flowState) {
      case AuthFlowState.loading:
        return const Scaffold(
          backgroundColor: MonolithTheme.background,
          body: Center(
            child: CircularProgressIndicator.adaptive(
              valueColor: AlwaysStoppedAnimation<Color>(MonolithTheme.primary),
            ),
          ),
        );
      case AuthFlowState.login:
        return const LoginScreen();
      case AuthFlowState.onboarding:
        return const ProfileInitScreen();
      case AuthFlowState.dashboard:
        return const MonolithShell(initialIndex: 0);
    }
  }
}
