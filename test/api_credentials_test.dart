import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/food_log/api_credentials.dart';

/// In-memory fake for the key-value seam, shaped like `FakeStore` in
/// test/health_repository_test.dart.
class FakeKeyValueStore implements CredentialKeyValueStore {
  FakeKeyValueStore([Map<String, String>? seed]) {
    if (seed != null) _m.addAll(seed);
  }

  final Map<String, String> _m = {};

  Map<String, String> get contents => Map.unmodifiable(_m);

  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> delete(String key) async => _m.remove(key);
}

void main() {
  group('ApiCredentialStore key names', () {
    // These two strings are load-bearing: they are what onboarding already
    // wrote for every existing user. Renaming either would silently orphan a
    // saved key, so the values are pinned here rather than merely centralised.
    test('match the literals onboarding already wrote', () {
      expect(ApiCredentialStore.keyKey, 'api_key');
      expect(ApiCredentialStore.providerKey, 'api_provider');
    });
  });

  group('SecureApiCredentialStore.read', () {
    test('returns both values when both are present', () async {
      final store = SecureApiCredentialStore(FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key': 'secret-abc',
      }));

      final creds = await store.read();

      expect(creds, isNotNull);
      expect(creds!.provider, 'GEMINI');
      expect(creds.key, 'secret-abc');
    });

    test('returns null when nothing is stored', () async {
      final store = SecureApiCredentialStore(FakeKeyValueStore());

      expect(await store.read(), isNull);
    });

    test('returns null when only the provider is stored', () async {
      final store = SecureApiCredentialStore(FakeKeyValueStore({
        'api_provider': 'GEMINI',
      }));

      expect(await store.read(), isNull);
    });

    test('returns null when only the key is stored', () async {
      final store = SecureApiCredentialStore(FakeKeyValueStore({
        'api_key': 'secret-abc',
      }));

      expect(await store.read(), isNull);
    });

    test('treats an empty stored value as absent', () async {
      final store = SecureApiCredentialStore(FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key': '',
      }));

      expect(await store.read(), isNull);
    });
  });

  group('SecureApiCredentialStore.write', () {
    test('writes both values under the legacy key names', () async {
      final kv = FakeKeyValueStore();
      final store = SecureApiCredentialStore(kv);

      await store.write(
        const ApiCredentials(provider: 'OPENROUTER', key: 'or-key-123'),
      );

      expect(kv.contents['api_provider'], 'OPENROUTER');
      expect(kv.contents['api_key'], 'or-key-123');
    });

    test('trims surrounding whitespace off a pasted key', () async {
      final kv = FakeKeyValueStore();
      final store = SecureApiCredentialStore(kv);

      await store.write(
        const ApiCredentials(provider: 'GEMINI', key: '  pasted-key  '),
      );

      expect(kv.contents['api_key'], 'pasted-key');
    });

    test('replaces a previously stored credential', () async {
      final kv = FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key': 'old',
      });
      final store = SecureApiCredentialStore(kv);

      await store.write(
        const ApiCredentials(provider: 'NVIDIA NIM', key: 'new'),
      );

      final creds = await store.read();
      expect(creds!.provider, 'NVIDIA NIM');
      expect(creds.key, 'new');
    });
  });

  group('SecureApiCredentialStore.delete', () {
    test('removes both values so read() reports absent', () async {
      final kv = FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key': 'secret-abc',
      });
      final store = SecureApiCredentialStore(kv);

      await store.delete();

      expect(await store.read(), isNull);
      expect(kv.contents.containsKey('api_key'), isFalse);
      expect(kv.contents.containsKey('api_provider'), isFalse);
    });

    test('leaves unrelated keys untouched', () async {
      final kv = FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key': 'secret-abc',
        'session_id': 'keep-me',
      });
      final store = SecureApiCredentialStore(kv);

      await store.delete();

      expect(kv.contents['session_id'], 'keep-me');
    });

    test('is a no-op when nothing is stored', () async {
      final store = SecureApiCredentialStore(FakeKeyValueStore());

      await store.delete();

      expect(await store.read(), isNull);
    });
  });

  group('readProvider', () {
    test('returns the stored provider even with no key saved', () async {
      // The API key screen shows "currently set · GEMINI" from this, and must
      // still report the provider chosen during onboarding.
      final store = SecureApiCredentialStore(FakeKeyValueStore({
        'api_provider': 'GEMINI',
      }));

      expect(await store.readProvider(), 'GEMINI');
    });

    test('returns null when no provider is stored', () async {
      final store = SecureApiCredentialStore(FakeKeyValueStore());

      expect(await store.readProvider(), isNull);
    });
  });
}
