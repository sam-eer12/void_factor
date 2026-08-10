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
