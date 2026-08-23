import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'account_deletion.dart';
import 'session_provider.dart';
import '../food_log/food_log_store.dart';
import '../health/health_background_service.dart';
import '../health/health_providers.dart';

final authStateProvider = StreamProvider<User?>((ref) {
  return FirebaseAuth.instance.authStateChanges();
});

/// Secure-storage keys holding the email — and optional name — an email-link
/// sign-in was started with.
///
/// Named rather than repeated inline so the deletion path provably clears the
/// same keys the sign-in path writes.
const String _emailHintKey = 'email_for_signin';
const String _nameHintKey = 'name_for_signin';

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
      await secureStorage.write(key: _emailHintKey, value: email);
      if (name != null && name.isNotEmpty) {
        await secureStorage.write(key: _nameHintKey, value: name);
      } else {
        await secureStorage.delete(key: _nameHintKey);
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
      final savedEmail = await secureStorage.read(key: _emailHintKey);
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
        final savedName = await secureStorage.read(key: _nameHintKey);
        if (savedName != null && savedName.isNotEmpty) {
          await user.updateDisplayName(savedName);
        }
      }

      // Clear temporary auth data
      await secureStorage.delete(key: _emailHintKey);
      await secureStorage.delete(key: _nameHintKey);

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

/// [AccountDeletionService] wired to the real SDKs, the local log file and the
/// session.
///
/// Every seam is a closure over a singleton rather than a provider read, because
/// after the auth user is gone there is no uid left to read from: the food log
/// file in particular has to be found by the uid captured *before* the delete,
/// which is why it is built directly here instead of through
/// `foodLogStoreProvider`.
final accountDeletionServiceProvider = Provider<AccountDeletionService>((ref) {
  final auth = FirebaseAuth.instance;
  const secureStorage = FlutterSecureStorage();

  return AccountDeletionService(
    currentUid: () => auth.currentUser?.uid,
    providerIds: () =>
        auth.currentUser?.providerData
            .map((info) => info.providerId)
            .toList() ??
        const [],
    reauthenticate: () => _reauthenticateWithGoogle(auth),
    // `users/{uid}` is the only document the app owns, and it has no
    // subcollections — so one delete is the whole remote footprint.
    remoteDelete: (uid) => FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .delete()
        .timeout(const Duration(seconds: 15)),
    authDelete: () async {
      final user = auth.currentUser;
      // Returning normally here would report a deletion that never happened,
      // and the teardown would then wipe the local data of a live account.
      if (user == null) throw StateError('No signed-in user to delete');
      await user.delete();
    },
    deleteLogFile: (uid) async {
      final dir = await getApplicationDocumentsDirectory();
      await FoodLogStore(dir: dir, uid: uid).delete();
    },
    clearSession: () => ref.read(sessionServiceProvider).clearSession(),
    clearSignInHints: () async {
      await secureStorage.delete(key: _emailHintKey);
      await secureStorage.delete(key: _nameHintKey);
    },
    cancelBackgroundWork: cancelHealthRefresh,
  );
});

/// Has Google confirm the signed-in user, then hands the fresh credential to
/// Firebase.
///
/// The outcome is classified here rather than inside [AccountDeletionService] so
/// that service never has to know how `google_sign_in` reports a dismissed
/// picker.
Future<ReauthResult> _reauthenticateWithGoogle(FirebaseAuth auth) async {
  final user = auth.currentUser;
  if (user == null) return ReauthResult.failed;

  try {
    await GoogleSignIn.instance.initialize();
    final googleUser = await GoogleSignIn.instance.authenticate();
    await user.reauthenticateWithCredential(
      GoogleAuthProvider.credential(idToken: googleUser.authentication.idToken),
    );
    return ReauthResult.confirmed;
  } on GoogleSignInException catch (error) {
    // Backing out of the account picker is a decision, not a fault.
    return error.code == GoogleSignInExceptionCode.canceled
        ? ReauthResult.cancelled
        : ReauthResult.failed;
  } on FirebaseAuthException catch (error) {
    // A valid credential belonging to somebody else. Proceeding on it would ask
    // Firebase to delete an account the user did not intend to touch.
    return error.code == 'user-mismatch'
        ? ReauthResult.wrongAccount
        : ReauthResult.failed;
  } catch (_) {
    return ReauthResult.failed;
  }
}

/// Deletes the account and, if it succeeded, returns to login with a cleared
/// stack — the same landing as [performLogout], so the two teardowns cannot
/// leave the app in different states.
///
/// The result is handed back rather than shown here: only the caller has a
/// [ScaffoldMessenger] to say it in.
Future<DeletionResult> performAccountDeletion(
  BuildContext context,
  WidgetRef ref,
) async {
  final result = await ref.read(accountDeletionServiceProvider).deleteAccount();
  if (result.outcome != DeletionOutcome.deleted) return result;

  // Deleting the Firebase user leaves the device's Google session standing, so
  // one tap on the login screen would quietly mint a brand-new account. Guarded
  // for the same reason as in signOut(): an email-link user never initialized
  // GoogleSignIn, and a throw here must not undo a deletion that has succeeded.
  try {
    await GoogleSignIn.instance.initialize();
    await GoogleSignIn.instance.signOut();
  } catch (_) {
    // No Google session to end.
  }

  // The in-memory half of the teardown, matching signOut(): clearSession() only
  // wipes storage, so these root-scoped providers would otherwise keep serving
  // the deleted user's profile and metrics — and keep the refresh timer and
  // HealthKit observer alive — until the app is killed.
  ref.invalidate(profileProvider);
  ref.invalidate(healthMetricsProvider);
  ref.invalidate(healthStatusProvider);
  // The food log cache needs no invalidation of its own: it is built from
  // foodLogStoreProvider, which watches authStateProvider, so a null user drops
  // the deleted account's entries out of it on its own.

  if (!context.mounted) return result;
  Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
  return result;
}


