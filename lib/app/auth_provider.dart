import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'session_provider.dart';

final authStateProvider = StreamProvider<User?>((ref) {
  return FirebaseAuth.instance.authStateChanges();
});

class SignupState {
  final String name;
  final String email;
  final String password;
  final String otp;
  final String? error;
  final bool isLoading;

  SignupState({
    this.name = '',
    this.email = '',
    this.password = '',
    this.otp = '',
    this.error,
    this.isLoading = false,
  });

  SignupState copyWith({
    String? name,
    String? email,
    String? password,
    String? otp,
    String? error,
    bool? isLoading,
  }) {
    return SignupState(
      name: name ?? this.name,
      email: email ?? this.email,
      password: password ?? this.password,
      otp: otp ?? this.otp,
      error: error,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class AuthController extends Notifier<SignupState> {
  FirebaseAuth get _auth => FirebaseAuth.instance;

  @override
  SignupState build() {
    return SignupState();
  }

  // Generate 6-digit OTP
  String generateOtp() {
    final rand = Random();
    final otpVal = 100000 + rand.nextInt(900000);
    return otpVal.toString();
  }

  // Start Signup flow (generate OTP, save temporary signup details)
  void initiateSignup({
    required String name,
    required String email,
    required String password,
  }) {
    final otp = generateOtp();
    state = SignupState(
      name: name,
      email: email,
      password: password,
      otp: otp,
    );
  }

  // Resend OTP
  void resendOtp() {
    final newOtp = generateOtp();
    state = state.copyWith(otp: newOtp);
  }

  // Verify OTP and complete registration
  Future<bool> verifyOtpAndSignup(String enteredOtp) async {
    if (enteredOtp != state.otp) {
      state = state.copyWith(error: "Invalid verification code.");
      return false;
    }

    state = state.copyWith(isLoading: true, error: null);
    try {
      // Create user in Firebase
      final UserCredential userCredential = await _auth.createUserWithEmailAndPassword(
        email: state.email,
        password: state.password,
      );

      // Update user profile display name
      if (userCredential.user != null) {
        await userCredential.user!.updateDisplayName(state.name);
      }

      state = SignupState(); // Reset signup state on success
      return true;
    } on FirebaseAuthException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.message ?? "Registration failed. Please try again.",
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

  // Email/Password login
  Future<User?> signInWithEmail(String email, String password) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final UserCredential userCredential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      state = SignupState();
      return userCredential.user;
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
      // Initialize the plugin if required
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
    await GoogleSignIn.instance.signOut();
    await ref.read(sessionServiceProvider).clearSession();
  }
}

final authControllerProvider = NotifierProvider<AuthController, SignupState>(() {
  return AuthController();
});
