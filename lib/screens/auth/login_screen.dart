import 'package:flutter/material.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_text_field.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MonolithTheme.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 60),

              // ── MONOLITH Logo ──
              Container(
                padding: const EdgeInsets.all(16),
                decoration: MonolithTheme.invertedCardDecoration,
                child: Text(
                  'M',
                  style: MonolithTheme.displayLarge.copyWith(
                    color: MonolithTheme.surface,
                    fontSize: 48,
                  ),
                ),
              ),
              const SizedBox(height: 40),

              // ── LOGIN Heading ──
              Text(
                'LOGIN',
                style: MonolithTheme.displayLarge,
              ),
              const SizedBox(height: 8),
              Container(
                width: 60,
                height: MonolithTheme.heroBorderWidth,
                color: MonolithTheme.primary,
              ),
              const SizedBox(height: 40),

              // ── Email Field ──
              MonolithTextField(
                label: 'Email',
                hint: 'your@email.com',
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 24),

              // ── Password Field ──
              MonolithTextField(
                label: 'Password',
                hint: '••••••••',
                controller: _passwordController,
                obscureText: _obscurePassword,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_off
                        : Icons.visibility,
                    color: MonolithTheme.primary,
                  ),
                  onPressed: () {
                    setState(() => _obscurePassword = !_obscurePassword);
                  },
                ),
              ),
              const SizedBox(height: 12),

              // ── Forgot Password ──
              Align(
                alignment: Alignment.centerRight,
                child: GestureDetector(
                  onTap: () {},
                  child: Text(
                    'FORGOT PASSWORD?',
                    style: MonolithTheme.labelMedium.copyWith(
                      decoration: TextDecoration.underline,
                      decorationThickness: 2,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 40),

              // ── Login Button ──
              MonolithButton(
                label: 'ACCESS SYSTEM',
                onPressed: () {
                  Navigator.pushReplacementNamed(context, '/dashboard');
                },
              ),
              const SizedBox(height: 24),

              // ── Divider ──
              Row(
                children: [
                  const Expanded(
                    child: Divider(
                      color: MonolithTheme.primary,
                      thickness: 1,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'OR',
                      style: MonolithTheme.labelMedium,
                    ),
                  ),
                  const Expanded(
                    child: Divider(
                      color: MonolithTheme.primary,
                      thickness: 1,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // ── Create Account ──
              MonolithButton(
                label: 'CREATE ACCOUNT',
                style: MonolithButtonStyle.secondary,
                onPressed: () {
                  Navigator.pushNamed(context, '/signup');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
