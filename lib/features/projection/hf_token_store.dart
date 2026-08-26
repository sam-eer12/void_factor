import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../food_log/api_credentials.dart';

/// Reads and writes the HuggingFace access token used to download the on-device
/// model.
///
/// A separate store from [ApiCredentialStore] despite both holding a secret, for
/// two reasons that matter more than the duplication saved: the two are used at
/// completely different moments (one per meal photo, one per model download), and
/// removing one must never remove the other. A user who clears their analysis key
/// should not silently lose the ability to re-download a model.
///
/// The key-value seam itself *is* reused — `CredentialKeyValueStore` was written
/// as a general seam over secure storage, and re-declaring it here would be the
/// third copy of the same three methods.
abstract class HuggingFaceTokenStore {
  /// Namespaced away from `api_key` so neither feature can read the other's
  /// secret by mistake.
  static const String tokenKey = 'hf_token';

  /// Null when absent or empty. An empty token is treated as absent: sending one
  /// produces a 401 that reads as "your token was rejected" when the truth is
  /// that no token was ever saved.
  Future<String?> read();

  Future<void> write(String token);

  Future<void> delete();
}

class SecureHuggingFaceTokenStore implements HuggingFaceTokenStore {
  SecureHuggingFaceTokenStore([CredentialKeyValueStore? store])
      : _store = store ?? const SecureCredentialKeyValueStore();

  final CredentialKeyValueStore _store;

  @override
  Future<String?> read() async {
    final token = await _store.read(HuggingFaceTokenStore.tokenKey);
    if (token == null || token.isEmpty) return null;
    return token;
  }

  @override
  Future<void> write(String token) {
    // Trimmed on the way in: a token pasted from the HuggingFace settings page
    // commonly carries a trailing newline, and a bearer header containing one is
    // rejected outright.
    return _store.write(HuggingFaceTokenStore.tokenKey, token.trim());
  }

  @override
  Future<void> delete() => _store.delete(HuggingFaceTokenStore.tokenKey);
}

/// Declared alongside the store rather than in a providers file, following
/// `apiCredentialStoreProvider`'s precedent, so a widget test overrides one
/// symbol.
final huggingFaceTokenStoreProvider = Provider<HuggingFaceTokenStore>((ref) {
  return SecureHuggingFaceTokenStore();
});

/// Whether a token is saved — all the settings screen needs to render its state.
///
/// Carries no token. The screen never displays one, so the secret has no reason
/// to enter the widget tree, and a bool cannot leak it.
final huggingFaceTokenPresentProvider = FutureProvider<bool>((ref) async {
  final token = await ref.watch(huggingFaceTokenStoreProvider).read();
  return token != null;
});
