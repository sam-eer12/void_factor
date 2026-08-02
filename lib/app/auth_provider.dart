import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'session_provider.dart';
import 'health_providers.dart';

final authStateProvider = StreamProvider<User?>((ref) {
  return FirebaseAuth.instance.authStateChanges();
});

class SignupState {
  final String name;
  final String email;
  final String? error;
  final bool isLoading;
  final bool isLinkSent;

  SignupState({
    this.name = '',
    this.email = '',
    this.error,
    this.isLoading = false,
    this.isLinkSent = false,
  });

  SignupState copyWith({
    String? name,
    String? email,
    String? error,
    bool? isLoading,
    bool? isLinkSent,
  }) {
    return SignupState(
      name: name ?? this.name,
      email: email ?? this.email,
      error: error,
      isLoading: isLoading ?? this.isLoading,
      isLinkSent: isLinkSent ?? this.isLinkSent,
    );
  }
}

class AuthController extends Notifier<SignupState> {
  FirebaseAuth get _auth => FirebaseAuth.instance;

  @override
  SignupState build() {
    return SignupState();
  }

  // Send Email Verification (for email/password or manually verified accounts)
  Future<void> sendVerificationEmail(User user) async {
    final actionCodeSettings = ActionCodeSettings(
      url: 'https://signinpractice-bfade.firebaseapp.com/onboarding',
      handleCodeInApp: true,
      androidPackageName: 'com.voidfactor.app',
      androidInstallApp: true,
      androidMinimumVersion: '1',
      iOSBundleId: 'com.voidfactor.app',
    );
    await user.sendEmailVerification(actionCodeSettings);
  }

  // Send Passwordless Email Sign-in/Sign-up Link
  Future<bool> sendPasswordlessLink(String email, {String? name}) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final actionCodeSettings = ActionCodeSettings(
        url: 'https://signinpractice-bfade.firebaseapp.com/onboarding',
        handleCodeInApp: true,
        androidPackageName: 'com.voidfactor.app',
        androidMinimumVersion: '1',
        androidInstallApp: true,
        iOSBundleId: 'com.voidfactor.app',
      );

      await _auth.sendSignInLinkToEmail(
        email: email,
        actionCodeSettings: actionCodeSettings,
      );

      // Save email and optional name to secure storage
      const secureStorage = FlutterSecureStorage();
      await secureStorage.write(key: 'email_for_signin', value: email);
      if (name != null && name.isNotEmpty) {
        await secureStorage.write(key: 'name_for_signin', value: name);
      } else {
        await secureStorage.delete(key: 'name_for_signin');
      }

      state = SignupState(
        email: email,
        name: name ?? '',
        isLinkSent: true,
      );
      return true;
    } on FirebaseAuthException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.message ?? "Failed to send verification link.",
      );
      return false;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: "An unexpected error occurred: ${e.toString()}",
      );
      return false;
    }
  }

  // Verify and complete Passwordless sign-in with the clicked/pasted link
  Future<User?> signInWithLink(String emailLink) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      const secureStorage = FlutterSecureStorage();
      final savedEmail = await secureStorage.read(key: 'email_for_signin');
      if (savedEmail == null || savedEmail.isEmpty) {
        throw Exception("No email found to complete sign-in. Please ensure you are signing in from the same device or re-request the link.");
      }

      if (!_auth.isSignInWithEmailLink(emailLink)) {
        throw Exception("The provided link is not a valid Firebase sign-in link.");
      }

      final UserCredential userCredential = await _auth.signInWithEmailLink(
        email: savedEmail,
        emailLink: emailLink,
      );

      final user = userCredential.user;
      if (user != null) {
        final savedName = await secureStorage.read(key: 'name_for_signin');
        if (savedName != null && savedName.isNotEmpty) {
          await user.updateDisplayName(savedName);
        }
      }

      // Clear temporary auth data
      await secureStorage.delete(key: 'email_for_signin');
      await secureStorage.delete(key: 'name_for_signin');

      state = SignupState();
      return user;
    } on FirebaseAuthException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.message ?? "Authentication failed.",
      );
      return null;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
      return null;
    }
  }

  // Google Sign-In
  Future<User?> signInWithGoogle() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await GoogleSignIn.instance.initialize();
      final googleUser = await GoogleSignIn.instance.authenticate();
      final googleAuth = googleUser.authentication;
      final AuthCredential credential = GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
      );

      final UserCredential userCredential = await _auth.signInWithCredential(credential);
      state = SignupState();
      return userCredential.user;
    } on FirebaseAuthException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.message ?? "Google Sign-In failed.",
      );
      return null;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
      return null;
    }
  }

  // Sign out
  Future<void> signOut() async {
    await _auth.signOut();
    // Email-link users never initialize GoogleSignIn, so signing out of Google
    // can throw ("not initialized") in google_sign_in 7.x. Guard it so a
    // Google failure can never abort the Firebase sign-out or session clear.
    try {
      await GoogleSignIn.instance.initialize();
      await GoogleSignIn.instance.signOut();
    } catch (_) {
      // No active Google session (or Google not configured) — nothing to do.
    }
    await ref.read(sessionServiceProvider).clearSession();
    // Drop the cached profile so a different user signing in next can't see
    // the previous user's stale metrics.
    ref.invalidate(profileProvider);
    // Reset the in-memory health state too. clearSession() only wipes the
    // secure-storage keys; these root-scoped notifiers otherwise retain the
    // prior user's "enabled" status + cached metrics (and keep the refresh
    // timer / HealthKit observer running) until the app is killed. Invalidating
    // them tears down the timer/observer via onDispose and rebuilds from the
    // now-cleared store, so the next user starts genuinely disconnected.
    ref.invalidate(healthMetricsProvider);
    ref.invalidate(healthStatusProvider);
  }
}

final authControllerProvider = NotifierProvider<AuthController, SignupState>(() {
  return AuthController();
});

/// Signs the user out of Firebase, Google, and the local session, then returns
/// to the login screen with a fully cleared navigation stack.
///
/// Every "log out" entry point should call this so the teardown is identical
/// everywhere — previously some screens only navigated to `/login` while
/// leaving the Firebase/session state intact, which silently re-logged the
/// user back in.
Future<void> performLogout(BuildContext context, WidgetRef ref) async {
  await ref.read(authControllerProvider.notifier).signOut();
  if (!context.mounted) return;
  Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
}

