import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Every provider the analysis service can call, in the order the app offers
/// them.
///
/// These exact strings are what gets stored and what
/// `FoodAnalysisClient.providerSlug` matches on, so they are storage values
/// rather than display labels. They live here rather than on either screen
/// because onboarding, the key screen and the store all have to agree on them.
const List<String> kApiProviders = ['GEMINI', 'OPENROUTER', 'NVIDIA NIM'];

/// Maps a stored or typed provider name onto one of [kApiProviders].
///
/// Storage is not a closed world: a value read back from a device that has been
/// through several builds has to land somewhere, and the provider name is what
/// a key's storage slot is derived from — two spellings of one provider would
/// put a user's key somewhere nothing looks for it. Returns `null` for anything
/// unrecognised, so the caller decides whether that is a skip or a failure.
String? canonicalApiProvider(String? name) {
  if (name == null) return null;
  final normalized = name.trim().toUpperCase();
  if (normalized.isEmpty) return null;
  for (final provider in kApiProviders) {
    if (provider == normalized) return provider;
  }
  // The route has always been `nvidia`, so that is the spelling an older or
  // hand-set value most plausibly holds.
  if (normalized == 'NVIDIA') return 'NVIDIA NIM';
  return null;
}

/// The provider name plus its API key, as a pair.
///
/// They travel together because either one alone is useless: a key with no
/// provider has no endpoint to call, and a provider with no key cannot
/// authenticate.
class ApiCredentials {
  /// One of [kApiProviders].
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

/// Holds up to one API key per provider, plus which one leads.
///
/// A scan tries the leading provider first and falls back through the rest, so
/// a revoked key or a provider having an outage costs the user a retry rather
/// than a trip to Settings. Ordering is therefore storage's business, not the
/// client's: [readAll] hands back the try order already resolved, and there is
/// nowhere else for a second opinion about it to form.
///
/// This type also owns the storage key names, and is the seam
/// `FoodAnalysisClient` is tested against — a fake implementing this interface
/// is all a client test needs.
abstract class ApiCredentialStore {
  /// The single key every user had before there were three.
  ///
  /// Nothing writes it any more; it is read once and relocated by the migration
  /// in [SecureApiCredentialStore]. The name cannot change or that migration
  /// stops finding anything.
  static const String keyKey = 'api_key';

  /// The provider tried first. Onboarding has always written this name, and it
  /// keeps its meaning: the provider currently in use.
  static const String providerKey = 'api_provider';

  /// Where one provider's key lives: `api_key_gemini`, `api_key_openrouter`,
  /// `api_key_nvidia_nim`.
  ///
  /// Derived from the provider name rather than from
  /// `FoodAnalysisClient.providerSlug`, deliberately — a route rename on the
  /// backend must not orphan a key already sitting in the keychain.
  static String keyKeyFor(String provider) {
    final canonical = canonicalApiProvider(provider) ?? provider;
    final suffix =
        canonical.trim().toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_');
    return '${keyKey}_$suffix';
  }

  /// Every saved credential, in the order a scan should try them: the default
  /// provider first, then the rest in [kApiProviders] order. Empty when nothing
  /// is saved.
  Future<List<ApiCredentials>> readAll();

  /// Saves [credentials] under its own provider, leaving the others alone.
  ///
  /// Becomes the default when no usable default is set, so a user with exactly
  /// one key never has to also nominate it.
  Future<void> write(ApiCredentials credentials);

  /// Makes [provider] the one every scan starts with. The rest stay as
  /// fallbacks.
  Future<void> setDefaultProvider(String provider);

  /// Forgets one provider's key. If it was the default, the next provider that
  /// still has a key takes over.
  Future<void> deleteProvider(String provider);

  /// Forgets every key. After this, vision capture shows
  /// "NO API KEY — SET ONE IN SETTINGS".
  Future<void> deleteAll();
}

class SecureApiCredentialStore implements ApiCredentialStore {
  SecureApiCredentialStore([CredentialKeyValueStore? store])
      : _store = store ?? const SecureCredentialKeyValueStore();

  final CredentialKeyValueStore _store;

  @override
  Future<List<ApiCredentials>> readAll() async {
    await _migrateLegacyKey();

    final saved = <String, String>{};
    for (final provider in kApiProviders) {
      final key = await _store.read(ApiCredentialStore.keyKeyFor(provider));
      // An empty string is treated as absent: a half-written credential would
      // otherwise produce a request the provider rejects with a 401, surfacing
      // as "API KEY REJECTED" when the truth is that no key was ever saved.
      if (key != null && key.isNotEmpty) saved[provider] = key;
    }

    final preferred = await _defaultProvider();
    final order = [
      if (preferred != null && saved.containsKey(preferred)) preferred,
      for (final provider in kApiProviders)
        if (provider != preferred && saved.containsKey(provider)) provider,
    ];
    return [
      for (final provider in order)
        ApiCredentials(provider: provider, key: saved[provider]!),
    ];
  }

  @override
  Future<void> write(ApiCredentials credentials) async {
    await _migrateLegacyKey();
    final provider = canonicalApiProvider(credentials.provider);
    if (provider == null) {
      // Writing under an unrecognised name would put the key in a slot nothing
      // ever reads, and the user would be told a key they just saved was
      // rejected.
      throw ArgumentError.value(
          credentials.provider, 'provider', 'not one of $kApiProviders');
    }

    // Trimmed on the way in: a key pasted from a web console commonly carries a
    // trailing newline, and a header value with one is rejected outright.
    await _store.write(
        ApiCredentialStore.keyKeyFor(provider), credentials.key.trim());

    // The first key in leads, and so does a key added while the stored default
    // names a provider whose key has since been removed — a default nothing can
    // be tried against is not a preference worth keeping.
    if (!await _defaultHasKey()) {
      await _store.write(ApiCredentialStore.providerKey, provider);
    }
  }

  @override
  Future<void> setDefaultProvider(String provider) async {
    await _migrateLegacyKey();
    final canonical = canonicalApiProvider(provider);
    if (canonical == null) {
      throw ArgumentError.value(
          provider, 'provider', 'not one of $kApiProviders');
    }
    await _store.write(ApiCredentialStore.providerKey, canonical);
  }

  @override
  Future<void> deleteProvider(String provider) async {
    await _migrateLegacyKey();
    final canonical = canonicalApiProvider(provider);
    if (canonical == null) return;
    await _store.delete(ApiCredentialStore.keyKeyFor(canonical));

    // Leaving the deleted provider named as the default would report a key the
    // user just removed as the one in use.
    if (await _defaultProvider() != canonical) return;
    final remaining = await readAll();
    if (remaining.isEmpty) {
      await _store.delete(ApiCredentialStore.providerKey);
    } else {
      await _store.write(
          ApiCredentialStore.providerKey, remaining.first.provider);
    }
  }

  @override
  Future<void> deleteAll() async {
    for (final provider in kApiProviders) {
      await _store.delete(ApiCredentialStore.keyKeyFor(provider));
    }
    await _store.delete(ApiCredentialStore.keyKey);
    await _store.delete(ApiCredentialStore.providerKey);
  }

  Future<String?> _defaultProvider() async =>
      canonicalApiProvider(await _store.read(ApiCredentialStore.providerKey));

  Future<bool> _defaultHasKey() async {
    final provider = await _defaultProvider();
    if (provider == null) return false;
    final key = await _store.read(ApiCredentialStore.keyKeyFor(provider));
    return key != null && key.isNotEmpty;
  }

  /// Moves the one pre-existing key into its provider's own slot.
  ///
  /// Before this feature there was a single `api_key`, and `api_provider` named
  /// what it was for. That key is still the user's only working credential, so
  /// it is relocated rather than dropped, and the legacy entry is removed so
  /// this runs exactly once. Cheap enough to attempt on every call — one read
  /// of a key that is no longer there — and attempting it on every call is what
  /// stops a write or a removal from racing ahead of it and being undone.
  Future<void> _migrateLegacyKey() async {
    final legacy = await _store.read(ApiCredentialStore.keyKey);
    if (legacy == null || legacy.trim().isEmpty) {
      // Still cleared, so an empty legacy entry cannot keep costing a read.
      if (legacy != null) await _store.delete(ApiCredentialStore.keyKey);
      return;
    }

    final provider = await _defaultProvider();
    if (provider != null) {
      final slot = ApiCredentialStore.keyKeyFor(provider);
      final existing = await _store.read(slot);
      // A key written since the upgrade is the newer of the two and wins.
      if (existing == null || existing.isEmpty) {
        await _store.write(slot, legacy.trim());
      }
    }
    // Dropped either way — including when no provider was ever stored, where
    // the key names no endpoint and nothing can be done with it.
    await _store.delete(ApiCredentialStore.keyKey);
  }
}

/// Declared here rather than in a providers file, following
/// `healthRepositoryProvider`'s precedent, so both `FoodAnalysisClient` and the
/// API key screen's widget test can override one symbol.
final apiCredentialStoreProvider = Provider<ApiCredentialStore>((ref) {
  return SecureApiCredentialStore();
});

/// What the screens that render credential state need to know: which providers
/// have a key, in the order they will be tried. The first is the one every scan
/// starts with; the rest are fallbacks.
///
/// Carries no key. The API key screen never displays one and Settings only
/// names the provider, so the secret has no reason to leave the store — and a
/// status object that cannot hold it cannot leak it into a widget tree.
typedef ApiCredentialStatus = ({List<String> savedProviders});

/// Read by the API key screen and by the Settings card subtitle. Invalidate it
/// after a write or a removal so both redraw.
final apiCredentialStatusProvider =
    FutureProvider<ApiCredentialStatus>((ref) async {
  final store = ref.watch(apiCredentialStoreProvider);
  final saved = await store.readAll();
  return (savedProviders: [for (final c in saved) c.provider]);
});
