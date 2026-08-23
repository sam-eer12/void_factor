import 'package:flutter/material.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/signup_screen.dart';
import '../screens/auth/verify_link_screen.dart';
import '../screens/auth/verify_failed_screen.dart';
import '../screens/auth/auth_gate.dart';
import '../screens/onboarding/profile_init_screen.dart';
import '../screens/dashboard/monolith_shell.dart';
import '../screens/food_log/manual_food_log_screen.dart';
import '../screens/donation/donation_screen.dart';
import '../screens/settings/edit_profile_screen.dart';
import '../screens/settings/goals_diet_screen.dart';
import '../screens/settings/health_connect_screen.dart';
import '../screens/settings/api_key_screen.dart';

class AppRoutes {
  AppRoutes._();

  static const String authGate = '/';
  static const String login = '/login';
  static const String signup = '/signup';
  static const String verifyLink = '/verify-link';
  static const String profileInit = '/profile-init';
  static const String onboarding = '/onboarding';
  static const String verifyFailed = '/verify-failed';
  static const String dashboard = '/dashboard';
  static const String aiVision = '/ai-vision';
  static const String projections = '/projections';
  static const String foodLog = '/food-log';
  static const String settings = '/settings';
  static const String donation = '/donation';
  static const String editProfile = '/edit-profile';
  static const String goalsDiet = '/goals-diet';
  static const String healthConnect = '/health-connect';
  static const String apiKey = '/api-key';

  static Map<String, WidgetBuilder> get routes => {
        authGate: (_) => const AuthGate(),
        login: (_) => const LoginScreen(),
        signup: (_) => const SignupScreen(),
        verifyLink: (_) => const VerifyLinkScreen(),
        verifyFailed: (_) => const VerifyFailedScreen(),
        profileInit: (_) => const ProfileInitScreen(),
        onboarding: (_) => const ProfileInitScreen(),
        dashboard: (_) => const MonolithShell(initialIndex: 0),
        aiVision: (_) => const MonolithShell(initialIndex: 1),
        projections: (_) => const MonolithShell(initialIndex: 2),
        settings: (_) => const MonolithShell(initialIndex: 3),
        foodLog: (_) => const ManualFoodLogScreen(),
        donation: (_) => const DonationScreen(),
        editProfile: (_) => const EditProfileScreen(),
        goalsDiet: (_) => const GoalsDietScreen(),
        healthConnect: (_) => const HealthConnectScreen(),
        apiKey: (_) => const ApiKeyScreen(),
      };
}
