import 'package:flutter/material.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/signup_screen.dart';
import '../screens/auth/otp_screen.dart';
import '../screens/auth/auth_gate.dart';
import '../screens/onboarding/profile_init_screen.dart';
import '../screens/dashboard/monolith_shell.dart';
import '../screens/food_log/manual_food_log_screen.dart';
import '../screens/donation/donation_screen.dart';

class AppRoutes {
  AppRoutes._();

  static const String authGate = '/';
  static const String login = '/login';
  static const String signup = '/signup';
  static const String otp = '/otp';
  static const String profileInit = '/profile-init';
  static const String dashboard = '/dashboard';
  static const String aiVision = '/ai-vision';
  static const String projections = '/projections';
  static const String foodLog = '/food-log';
  static const String settings = '/settings';
  static const String donation = '/donation';

  static Map<String, WidgetBuilder> get routes => {
        authGate: (_) => const AuthGate(),
        login: (_) => const LoginScreen(),
        signup: (_) => const SignupScreen(),
        otp: (_) => const OtpScreen(),
        profileInit: (_) => const ProfileInitScreen(),
        dashboard: (_) => const MonolithShell(initialIndex: 0),
        aiVision: (_) => const MonolithShell(initialIndex: 1),
        projections: (_) => const MonolithShell(initialIndex: 2),
        settings: (_) => const MonolithShell(initialIndex: 3),
        foodLog: (_) => const ManualFoodLogScreen(),
        donation: (_) => const DonationScreen(),
      };
}
