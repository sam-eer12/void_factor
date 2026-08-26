import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../models/user_profile.dart';
import 'auth_provider.dart';
import '../food_log/api_credentials.dart';
import '../health/health_repository.dart';
import '../profile/profile_repository.dart';
import '../projection/hf_token_store.dart';

class SessionService {
  SessionService(this._profileRepository);

  final ProfileRepository _profileRepository;

  final _secureStorage = const FlutterSecureStorage();
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  static const _sessionIdKey = 'session_id';
  static const _lastActivityKey = 'last_activity_time';
  static const _profileCompletedKey = 'profile_completed';

  // Generate a new 32-character session ID
  String _generateSessionId() {
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // Get current session ID from secure storage
  Future<String?> getSessionId() async {
    return await _secureStorage.read(key: _sessionIdKey);
  }

  // Clear all session storage (on logout)
  Future<void> clearSession() async {
    await _secureStorage.delete(key: _sessionIdKey);
    await _secureStorage.delete(key: _lastActivityKey);
    await _secureStorage.delete(key: _profileCompletedKey);
    await _secureStorage.delete(key: ApiCredentialStore.keyKey);
    await _secureStorage.delete(key: ApiCredentialStore.providerKey);
    // The model token is this user's HuggingFace credential, so it leaves with
    // them — on a shared device the next user must not be able to download
    // against it. The downloaded model file itself deliberately stays: it holds
    // nothing personal, and re-fetching half a gigabyte per login would be
    // hostile.
    await _secureStorage.delete(key: HuggingFaceTokenStore.tokenKey);
    // Drop cached health data + the connection flag so the next user starts
    // disconnected and can't read the prior user's metrics. Named via the
    // repository's constants rather than repeated literals — four copies of a
    // key is how one of them drifts.
    await _secureStorage.delete(key: HealthRepository.metricsKey);
    await _secureStorage.delete(key: HealthRepository.enabledKey);
    await _secureStorage.delete(key: HealthRepository.energyWindowKey);
    await _secureStorage.delete(key: HealthRepository.authorizedTypesVersionKey);
    // Drop the mirrored profile blob so the next user can't read stale data.
    await _profileRepository.clearLocal();
  }

  // Load the current user's profile (Firestore-backed, local fallback).
  Future<UserProfile> loadProfile() async {
    return await _profileRepository.load();
  }

  // Initialize/refresh the session and check onboarding
  // Returns:
  // - 'onboarding': if the user needs to fill onboarding
  // - 'dashboard': if the session is valid and onboarding is complete
  Future<String> manageSessionAndFlow() async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      return 'login';
    }

    final uid = currentUser.uid;
    final now = DateTime.now();

    try {
      // 1. Verify user ID is still valid from Firebase Auth
      await currentUser.reload();
    } catch (e) {
      // User is no longer valid (e.g., deleted, disabled)
      await clearSession();
      return 'login';
    }

    // 2. Fetch the user profile and session ID from Firestore
    DocumentSnapshot<Map<String, dynamic>> doc;
    try {
      doc = await _db.collection('users').doc(uid).get().timeout(const Duration(seconds: 15));
    } catch (e) {
      // Network error or fetch failed, fallback to local caching if valid
      final localProfileCompleted = await _secureStorage.read(key: _profileCompletedKey);
      if (localProfileCompleted == 'true') {
        return 'dashboard';
      }
      return 'onboarding';
    }

    if (!doc.exists) {
      return 'onboarding';
    }

    final profile = doc.data();
    if (profile == null) {
      return 'onboarding';
    }

    // 3. Verify session ID from Firestore
    final remoteSessionId = profile['sessionId'] as String?;
    final localSessionId = await _secureStorage.read(key: _sessionIdKey);
    final lastActivityStr = await _secureStorage.read(key: _lastActivityKey);

    bool needNewSession = false;

    if (localSessionId == null || lastActivityStr == null) {
      needNewSession = true;
    } else {
      final lastActivity = DateTime.tryParse(lastActivityStr);
      if (lastActivity == null) {
        needNewSession = true;
      } else {
        final difference = now.difference(lastActivity).inDays;
        if (difference >= 30) {
          needNewSession = true;
        }
      }
    }

    if (needNewSession) {
      // Generate a new session ID
      final newSessionId = _generateSessionId();
      await _secureStorage.write(key: _sessionIdKey, value: newSessionId);
      await _secureStorage.write(key: _lastActivityKey, value: now.toIso8601String());

      // Update Firestore with the new session ID
      await _db.collection('users').doc(uid).update({'sessionId': newSessionId});
    } else {
      // Local session exists. Check if it matches the remote session ID
      if (remoteSessionId == null || remoteSessionId != localSessionId) {
        // Session mismatch: session has been invalidated or logged in from another device
        await clearSession();
        return 'login';
      }
      // Renew inactivity timer locally
      await _secureStorage.write(key: _lastActivityKey, value: now.toIso8601String());
    }

    // Reconcile the profile schema: mirror it locally and, if the document
    // predates the new goal/diet fields, upgrade it in place (per-user
    // backfill). Safe to run every sync; a no-op once already current.
    await _profileRepository.reconcileSchema(profile);
    await _secureStorage.write(key: _profileCompletedKey, value: 'true');

    return 'dashboard';
  }

  // Save onboarding details, generate a session ID and mark completed.
  Future<void> completeOnboarding({
    required double height,
    required double weight,
    required int age,
    required String gender,
    required String apiKey,
    required String apiProvider,
  }) async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) throw Exception('No authenticated user');

    final uid = currentUser.uid;
    final newSessionId = _generateSessionId();
    final now = DateTime.now();

    // 1. Establish session + creation metadata via a merge write so it composes
    //    with the profile write below without either clobbering the other.
    await _db.collection('users').doc(uid).set(
      {
        'sessionId': newSessionId,
        'createdAt': now.toIso8601String(),
      },
      SetOptions(merge: true),
    ).timeout(const Duration(seconds: 15));

    // 2. Persist the profile (Firestore merge + local blob) via the repository.
    //    New goal/diet fields take their defaults; onboarding only collects the
    //    original physical metrics.
    final profile = UserProfile(
      height: height,
      weight: weight,
      age: age,
      gender: gender,
      goal: WeightGoal.maintain,
      targetWeight: weight,
      weeklyRate: 0.5,
      allergies: const [],
    );
    await _profileRepository.save(profile);

    // 3. API credentials remain local-only (never sent to Firestore).
    await _secureStorage.write(key: ApiCredentialStore.keyKey, value: apiKey);
    await _secureStorage.write(
        key: ApiCredentialStore.providerKey, value: apiProvider);

    // 4. Session bookkeeping.
    await _secureStorage.write(key: _sessionIdKey, value: newSessionId);
    await _secureStorage.write(key: _lastActivityKey, value: now.toIso8601String());
    await _secureStorage.write(key: _profileCompletedKey, value: 'true');
  }
}

final sessionServiceProvider = Provider<SessionService>((ref) {
  return SessionService(ref.watch(profileRepositoryProvider));
});

enum AuthFlowState { loading, login, onboarding, dashboard }

class AuthFlowNotifier extends Notifier<AuthFlowState> {
  // Monotonic token used to discard results from superseded checkFlow() runs.
  // An auth-state change and an app-resume can both trigger checkFlow() at
  // roughly the same time; without this guard a slower, older run could resolve
  // last and overwrite the state produced by the newer one.
  int _checkToken = 0;

  @override
  AuthFlowState build() {
    // Listen to authState changes
    ref.listen<AsyncValue<User?>>(authStateProvider, (previous, next) {
      checkFlow();
    });

    // Run the initial check
    checkFlow();

    return AuthFlowState.loading;
  }

  Future<void> checkFlow() async {
    final authState = ref.read(authStateProvider);

    if (authState.isLoading) {
      state = AuthFlowState.loading;
      return;
    }

    final user = authState.value;
    if (user == null) {
      state = AuthFlowState.login;
      return;
    }

    final token = ++_checkToken;
    state = AuthFlowState.loading;
    try {
      final service = ref.read(sessionServiceProvider);
      final result = await service.manageSessionAndFlow();
      // A newer checkFlow() started while we were awaiting; let it win.
      if (token != _checkToken) return;
      if (result == 'dashboard') {
        // Refresh the cached profile that Settings reads, now that the session
        // sync has reconciled it to secure storage / Firestore.
        ref.invalidate(profileProvider);
        state = AuthFlowState.dashboard;
      } else if (result == 'onboarding') {
        state = AuthFlowState.onboarding;
      } else {
        state = AuthFlowState.login;
      }
    } catch (e) {
      if (token != _checkToken) return;
      state = AuthFlowState.login;
    }
  }

  // Call this after completing onboarding
  void markOnboardingComplete() {
    ref.invalidate(profileProvider);
    state = AuthFlowState.dashboard;
  }
}

final authFlowProvider = NotifierProvider<AuthFlowNotifier, AuthFlowState>(() {
  return AuthFlowNotifier();
});

final profileProvider = FutureProvider<UserProfile>((ref) async {
  final repository = ref.watch(profileRepositoryProvider);
  return await repository.load();
});
