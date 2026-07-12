import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'auth_provider.dart';

class SessionService {
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
    await _secureStorage.delete(key: 'height');
    await _secureStorage.delete(key: 'weight');
    await _secureStorage.delete(key: 'age');
    await _secureStorage.delete(key: 'gender');
    await _secureStorage.delete(key: 'api_key');
    await _secureStorage.delete(key: 'api_provider');
  }

  // Retrieve cached profile metrics
  Future<Map<String, String>> getCachedProfile() async {
    final height = await _secureStorage.read(key: 'height') ?? '0';
    final weight = await _secureStorage.read(key: 'weight') ?? '0';
    final age = await _secureStorage.read(key: 'age') ?? '0';
    final gender = await _secureStorage.read(key: 'gender') ?? 'MALE';
    final apiKey = await _secureStorage.read(key: 'api_key') ?? '';
    final apiProvider = await _secureStorage.read(key: 'api_provider') ?? 'GEMINI';
    return {
      'height': height,
      'weight': weight,
      'age': age,
      'gender': gender,
      'apiKey': apiKey,
      'apiProvider': apiProvider,
    };
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

    // Check last activity time
    final lastActivityStr = await _secureStorage.read(key: _lastActivityKey);
    final sessionId = await _secureStorage.read(key: _sessionIdKey);

    bool needNewSession = false;

    if (sessionId == null || lastActivityStr == null) {
      needNewSession = true;
    } else {
      final lastActivity = DateTime.tryParse(lastActivityStr);
      if (lastActivity == null) {
        needNewSession = true;
      } else {
        final difference = now.difference(lastActivity).inDays;
        if (difference >= 30) {
          // 30 days of inactivity expiry
          needNewSession = true;
        }
      }
    }

    if (needNewSession) {
      // Automatically regenerate a new session ID
      final newSessionId = _generateSessionId();
      await _secureStorage.write(key: _sessionIdKey, value: newSessionId);
      await _secureStorage.write(key: _lastActivityKey, value: now.toIso8601String());
    } else {
      // Session is active and valid, update the last activity time to current time (renew inactivity)
      await _secureStorage.write(key: _lastActivityKey, value: now.toIso8601String());
    }

    // Now check if onboarding is complete
    final localProfileCompleted = await _secureStorage.read(key: _profileCompletedKey);
    if (localProfileCompleted == 'true') {
      return 'dashboard';
    }

    // Check remote Firestore
    try {
      final doc = await _db.collection('users').doc(uid).get().timeout(const Duration(seconds: 15));
      if (doc.exists) {
        final profile = doc.data();
        if (profile != null) {
          await _secureStorage.write(key: 'height', value: profile['height']?.toString() ?? '0');
          await _secureStorage.write(key: 'weight', value: profile['weight']?.toString() ?? '0');
          await _secureStorage.write(key: 'age', value: profile['age']?.toString() ?? '0');
          await _secureStorage.write(key: 'gender', value: profile['gender']?.toString() ?? 'MALE');
        }
        // Profile exists! Cache it locally
        await _secureStorage.write(key: _profileCompletedKey, value: 'true');
        return 'dashboard';
      } else {
        return 'onboarding';
      }
    } catch (e) {
      // Profile doesn't exist or error fetching
      return 'onboarding';
    }
  }

  // Save onboarding details to Firebase Storage, generate session ID and mark completed
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
    final profileData = {
      'height': height,
      'weight': weight,
      'age': age,
      'gender': gender,
      'createdAt': DateTime.now().toIso8601String(),
    };

    // 1. Save to Cloud Firestore (excluding the API Key)
    await _db.collection('users').doc(uid).set(profileData).timeout(const Duration(seconds: 15));

    // 2. Save details locally
    await _secureStorage.write(key: 'height', value: height.toString());
    await _secureStorage.write(key: 'weight', value: weight.toString());
    await _secureStorage.write(key: 'age', value: age.toString());
    await _secureStorage.write(key: 'gender', value: gender);
    await _secureStorage.write(key: 'api_key', value: apiKey);
    await _secureStorage.write(key: 'api_provider', value: apiProvider);

    // 3. Generate a new session ID and save it locally
    final newSessionId = _generateSessionId();
    final now = DateTime.now();
    await _secureStorage.write(key: _sessionIdKey, value: newSessionId);
    await _secureStorage.write(key: _lastActivityKey, value: now.toIso8601String());

    // 4. Mark profile as completed locally
    await _secureStorage.write(key: _profileCompletedKey, value: 'true');
  }
}

final sessionServiceProvider = Provider<SessionService>((ref) {
  return SessionService();
});

enum AuthFlowState { loading, login, onboarding, dashboard }

class AuthFlowNotifier extends Notifier<AuthFlowState> {
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

    state = AuthFlowState.loading;
    try {
      final service = ref.read(sessionServiceProvider);
      final result = await service.manageSessionAndFlow();
      if (result == 'dashboard') {
        state = AuthFlowState.dashboard;
      } else if (result == 'onboarding') {
        state = AuthFlowState.onboarding;
      } else {
        state = AuthFlowState.login;
      }
    } catch (e) {
      state = AuthFlowState.login;
    }
  }

  // Call this after completing onboarding
  void markOnboardingComplete() {
    state = AuthFlowState.dashboard;
  }
}

final authFlowProvider = NotifierProvider<AuthFlowNotifier, AuthFlowState>(() {
  return AuthFlowNotifier();
});

final profileProvider = FutureProvider<Map<String, String>>((ref) async {
  final service = ref.watch(sessionServiceProvider);
  return await service.getCachedProfile();
});
