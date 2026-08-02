import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/user_profile.dart';

/// Single source of truth for reading and writing the user's [UserProfile].
///
/// Firestore (`users/{uid}`) is the authoritative store; the encrypted local
/// blob (`profile_json` in secure storage) is a mirror used for offline reads.
/// Every write goes to both. Firestore writes use merge semantics so fields
/// this repository does not own — `sessionId`, `createdAt`, API credentials —
/// are never clobbered.
class ProfileRepository {
  ProfileRepository({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    FlutterSecureStorage? secureStorage,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _db = firestore ?? FirebaseFirestore.instance,
        _secureStorage = secureStorage ?? const FlutterSecureStorage();

  final FirebaseAuth _auth;
  final FirebaseFirestore _db;
  final FlutterSecureStorage _secureStorage;

  static const String profileKey = 'profile_json';
  static const Duration _timeout = Duration(seconds: 15);

  DocumentReference<Map<String, dynamic>>? _docFor(String? uid) {
    if (uid == null) return null;
    return _db.collection('users').doc(uid);
  }

  /// Loads the profile, preferring Firestore and falling back to the local
  /// blob when offline or unauthenticated. Never throws — a totally absent
  /// profile resolves to [UserProfile.empty].
  Future<UserProfile> load() async {
    final uid = _auth.currentUser?.uid;
    final doc = _docFor(uid);

    if (doc != null) {
      try {
        final snap = await doc.get().timeout(_timeout);
        final data = snap.data();
        if (snap.exists && data != null) {
          final profile = UserProfile.fromMap(data);
          // Keep the local mirror warm for the next offline read.
          await _writeLocal(profile);
          return profile;
        }
      } catch (_) {
        // Fall through to the local mirror below.
      }
    }

    return await _readLocal() ?? UserProfile.empty();
  }

  /// Persists [profile] to Firestore (merge) and the local blob.
  ///
  /// Merge is required because this method serves both the first write
  /// (onboarding, when the document may not exist) and later edits. A plain
  /// `.set()` without merge would erase `sessionId` / `createdAt`; `.update()`
  /// would throw on a not-yet-created document. `SetOptions(merge: true)`
  /// creates-or-updates and leaves untouched fields intact.
  Future<void> save(UserProfile profile) async {
    final uid = _auth.currentUser?.uid;
    final doc = _docFor(uid);
    if (doc == null) {
      throw StateError('Cannot save profile: no authenticated user.');
    }

    await doc.set(profile.toMap(), SetOptions(merge: true)).timeout(_timeout);
    await _writeLocal(profile);
  }

  /// Ensures the signed-in user's document carries the current schema. If it
  /// predates the new fields (no `schemaVersion`), writes an upgraded copy with
  /// defaults derived from the existing values. Safe to call on every session
  /// sync; a no-op once the document is already at [currentSchemaVersion].
  ///
  /// Returns the loaded (and possibly upgraded) profile so callers can reuse it.
  Future<UserProfile> reconcileSchema(Map<String, dynamic> remoteData) async {
    final profile = UserProfile.fromMap(remoteData);
    final version = remoteData['schemaVersion'];
    final needsUpgrade =
        version is! num || version.toInt() < UserProfile.currentSchemaVersion;

    if (needsUpgrade) {
      // save() writes with merge, so sessionId/createdAt are preserved.
      await save(profile);
    } else {
      await _writeLocal(profile);
    }
    return profile;
  }

  /// Removes the locally mirrored profile (called on logout).
  Future<void> clearLocal() async {
    await _secureStorage.delete(key: profileKey);
  }

  Future<UserProfile?> _readLocal() async {
    final raw = await _secureStorage.read(key: profileKey);
    return UserProfile.fromJsonString(raw);
  }

  Future<void> _writeLocal(UserProfile profile) async {
    await _secureStorage.write(key: profileKey, value: profile.toJsonString());
  }
}

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository();
});
