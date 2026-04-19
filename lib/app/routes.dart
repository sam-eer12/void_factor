import 'package:flutter/material.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/signup_screen.dart';
import '../screens/auth/otp_screen.dart';
import '../screens/onboarding/profile_init_screen.dart';
import '../screens/dashboard/dashboard_screen.dart';
import '../screens/vision/ai_vision_screen.dart';
import '../screens/stats/projections_screen.dart';
import '../screens/food_log/manual_food_log_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/donation/donation_screen.dart';

class AppRoutes {
  AppRoutes._();

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
        login: (_) => const LoginScreen(),
        signup: (_) => const SignupScreen(),
        otp: (_) => const OtpScreen(),
        profileInit: (_) => const ProfileInitScreen(),
        dashboard: (_) => const DashboardScreen(),
        aiVision: (_) => const AiVisionScreen(),
        projections: (_) => const ProjectionsScreen(),
        foodLog: (_) => const ManualFoodLogScreen(),
        settings: (_) => const SettingsScreen(),
        donation: (_) => const DonationScreen(),
      };
}
