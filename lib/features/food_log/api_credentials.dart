import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The provider name plus its API key, as a pair.
///
/// They travel together because either one alone is useless: a key with no
/// provider has no endpoint to call, and a provider with no key cannot
/// authenticate.
class ApiCredentials {
  /// One of `'GEMINI'`, `'OPENROUTER'`, `'NVIDIA NIM'` — the exact strings the
  /// onboarding selector writes.
  final String provider;

  final String key;

  const ApiCredentials({required this.provider, required this.key});
}

/// Minimal key-value seam over secure storage.
///
/// Mirrors `HealthKeyValueStore` in features/health so the credential logic is
/// unit-testable without the platform channel, which is unavailable under
/// `flutter_test`.
abstract class CredentialKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureCredentialKeyValueStore implements CredentialKeyValueStore {
  const SecureCredentialKeyValueStore(
      [this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Reads and writes the analysis provider credential.
///
/// This type exists to own the two storage keys. `'api_key'` and
/// `'api_provider'` were previously raw literals in two places in
/// `session_provider.dart`; this feature adds a third writer (the API key
/// screen) and a first reader (`FoodAnalysisClient`). Four copies of a magic
/// string is how one of them drifts.
///
/// It is also the seam `FoodAnalysisClient` is tested against — a fake
/// implementing this interface is all a client test needs.
abstract class ApiCredentialStore {
  /// The exact keys onboarding has always written. Changing either value would
  /// orphan every existing user's saved credential.
  static const String keyKey = 'api_key';
  static const String providerKey = 'api_provider';

  /// Returns `null` unless *both* values are present and non-empty.
  Future<ApiCredentials?> read();

  /// The provider alone, for the "currently set · GEMINI" line on the API key
  /// screen — which must still name the provider even when the key is gone.
  Future<String?> readProvider();

  Future<void> write(ApiCredentials credentials);

  /// Removes both values. After this, [read] reports absent and vision capture
  /// shows "NO API KEY — SET ONE IN SETTINGS".
  Future<void> delete();
}

class SecureApiCredentialStore implements ApiCredentialStore {
  SecureApiCredentialStore([CredentialKeyValueStore? store])
      : _store = store ?? const SecureCredentialKeyValueStore();

  final CredentialKeyValueStore _store;

  @override
  Future<ApiCredentials?> read() async {
    final provider = await _store.read(ApiCredentialStore.providerKey);
    final key = await _store.read(ApiCredentialStore.keyKey);
    // An empty string is treated as absent: a half-written credential would
    // otherwise produce a request the provider rejects with a 401, surfacing as
    // "API KEY REJECTED" when the truth is that no key was ever saved.
    if (provider == null || provider.isEmpty) return null;
    if (key == null || key.isEmpty) return null;
    return ApiCredentials(provider: provider, key: key);
  }

  @override
  Future<String?> readProvider() =>
      _store.read(ApiCredentialStore.providerKey);

  @override
  Future<void> write(ApiCredentials credentials) async {
    // Trimmed on the way in: a key pasted from a web console commonly carries a
    // trailing newline, and a header value with one is rejected outright.
    await _store.write(
        ApiCredentialStore.providerKey, credentials.provider.trim());
    await _store.write(ApiCredentialStore.keyKey, credentials.key.trim());
  }

  @override
  Future<void> delete() async {
    await _store.delete(ApiCredentialStore.keyKey);
    await _store.delete(ApiCredentialStore.providerKey);
  }
}

/// Declared here rather than in a providers file, following
/// `healthRepositoryProvider`'s precedent, so both `FoodAnalysisClient` and the
/// API key screen's widget test can override one symbol.
final apiCredentialStoreProvider = Provider<ApiCredentialStore>((ref) {
  return SecureApiCredentialStore();
});

/// What the two screens that render credential state need to know: which
/// provider, and whether a key is actually there.
///
/// Carries no key. The API key screen never displays one and Settings only
/// names the provider, so the secret has no reason to leave the store — and a
/// status object that cannot hold it cannot leak it into a widget tree.
typedef ApiCredentialStatus = ({String? provider, bool hasKey});

/// Read by the API key screen and by the Settings card subtitle. Invalidate it
/// after a write or a removal so both redraw.
final apiCredentialStatusProvider =
    FutureProvider<ApiCredentialStatus>((ref) async {
  final store = ref.watch(apiCredentialStoreProvider);
  final credentials = await store.read();
  if (credentials != null) {
    return (provider: credentials.provider, hasKey: true);
  }
  // `read()` also reports null for a half-written credential, so fall back to
  // the provider alone: there is no usable key, but it still names the provider
  // to preselect.
  return (provider: await store.readProvider(), hasKey: false);
});
