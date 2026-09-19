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
  /// The provider name of each saved credential, in try order.
  Future<List<String>> orderOf(SecureApiCredentialStore store) async =>
      [for (final c in await store.readAll()) c.provider];

  group('storage key names', () {
    // These are load-bearing: they are what onboarding already wrote for every
    // existing user. Renaming either would silently orphan a saved key, so the
    // values are pinned here rather than merely centralised.
    test('match the literals onboarding already wrote', () {
      expect(ApiCredentialStore.keyKey, 'api_key');
      expect(ApiCredentialStore.providerKey, 'api_provider');
    });

    test('give each provider its own slot', () {
      expect(ApiCredentialStore.keyKeyFor('GEMINI'), 'api_key_gemini');
      expect(ApiCredentialStore.keyKeyFor('OPENROUTER'), 'api_key_openrouter');
      expect(ApiCredentialStore.keyKeyFor('NVIDIA NIM'), 'api_key_nvidia_nim');
    });

    test('put every spelling of a provider in the same slot', () {
      // Two slots for one provider would hide a key the user did save.
      expect(ApiCredentialStore.keyKeyFor('NVIDIA'),
          ApiCredentialStore.keyKeyFor('NVIDIA NIM'));
      expect(ApiCredentialStore.keyKeyFor(' gemini '),
          ApiCredentialStore.keyKeyFor('GEMINI'));
    });
  });

  group('canonicalApiProvider', () {
    test('accepts the stored spellings', () {
      for (final provider in kApiProviders) {
        expect(canonicalApiProvider(provider), provider);
      }
    });

    test('normalises case and surrounding space', () {
      expect(canonicalApiProvider('  openrouter '), 'OPENROUTER');
    });

    test('maps the bare route name onto the full one', () {
      expect(canonicalApiProvider('NVIDIA'), 'NVIDIA NIM');
    });

    test('rejects anything it does not recognise', () {
      expect(canonicalApiProvider(null), isNull);
      expect(canonicalApiProvider(''), isNull);
      expect(canonicalApiProvider('OPENAI'), isNull);
    });
  });

  group('readAll', () {
    test('is empty when nothing is stored', () async {
      final store = SecureApiCredentialStore(FakeKeyValueStore());

      expect(await store.readAll(), isEmpty);
    });

    test('returns the one saved key with its provider', () async {
      final store = SecureApiCredentialStore(FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key_gemini': 'secret-abc',
      }));

      final saved = await store.readAll();

      expect(saved, hasLength(1));
      expect(saved.single.provider, 'GEMINI');
      expect(saved.single.key, 'secret-abc');
    });

    test('puts the default first and the rest behind it', () async {
      final store = SecureApiCredentialStore(FakeKeyValueStore({
        'api_provider': 'NVIDIA NIM',
        'api_key_gemini': 'g',
        'api_key_openrouter': 'or',
        'api_key_nvidia_nim': 'nv',
      }));

      // The order this returns *is* the order a scan tries, so it is the whole
      // behaviour of the feature.
      expect(await orderOf(store), ['NVIDIA NIM', 'GEMINI', 'OPENROUTER']);
    });

    test('leaves the others in declaration order behind the default', () async {
      final store = SecureApiCredentialStore(FakeKeyValueStore({
        'api_provider': 'OPENROUTER',
        'api_key_gemini': 'g',
        'api_key_openrouter': 'or',
        'api_key_nvidia_nim': 'nv',
      }));

      expect(await orderOf(store), ['OPENROUTER', 'GEMINI', 'NVIDIA NIM']);
    });

    test('skips a provider with no key rather than offering an empty one',
        () async {
      final store = SecureApiCredentialStore(FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key_gemini': 'g',
        'api_key_openrouter': '',
      }));

      // An empty string would produce a request the provider answers with a
      // 401, surfacing as "API KEY REJECTED" when no key was ever saved.
      expect(await orderOf(store), ['GEMINI']);
    });

    test('still returns the keys when the default names a provider with none',
        () async {
      final store = SecureApiCredentialStore(FakeKeyValueStore({
        'api_provider': 'NVIDIA NIM',
        'api_key_gemini': 'g',
      }));

      expect(await orderOf(store), ['GEMINI']);
    });

    test('reads a default stored under an older spelling', () async {
      final store = SecureApiCredentialStore(FakeKeyValueStore({
        'api_provider': 'nvidia',
        'api_key_gemini': 'g',
        'api_key_nvidia_nim': 'nv',
      }));

      expect(await orderOf(store), ['NVIDIA NIM', 'GEMINI']);
    });
  });

  group('write', () {
    test('stores the key in its own provider slot', () async {
      final kv = FakeKeyValueStore();
      final store = SecureApiCredentialStore(kv);

      await store.write(
        const ApiCredentials(provider: 'OPENROUTER', key: 'or-key-123'),
      );

      expect(kv.contents['api_key_openrouter'], 'or-key-123');
    });

    test('trims surrounding whitespace off a pasted key', () async {
      final kv = FakeKeyValueStore();
      final store = SecureApiCredentialStore(kv);

      await store.write(
        const ApiCredentials(provider: 'GEMINI', key: '  pasted-key  '),
      );

      expect(kv.contents['api_key_gemini'], 'pasted-key');
    });

    test('leaves the other providers alone', () async {
      final kv = FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key_gemini': 'g',
      });
      final store = SecureApiCredentialStore(kv);

      await store.write(const ApiCredentials(provider: 'NVIDIA NIM', key: 'nv'));

      // Adding a fallback must not cost the user the key they were using.
      expect(kv.contents['api_key_gemini'], 'g');
    });

    test('makes the first key in the default', () async {
      final kv = FakeKeyValueStore();
      final store = SecureApiCredentialStore(kv);

      await store.write(const ApiCredentials(provider: 'NVIDIA NIM', key: 'nv'));

      // A user with exactly one key should not also have to nominate it.
      expect(kv.contents['api_provider'], 'NVIDIA NIM');
    });

    test('does not let a later key steal the lead', () async {
      final kv = FakeKeyValueStore();
      final store = SecureApiCredentialStore(kv);

      await store.write(const ApiCredentials(provider: 'GEMINI', key: 'g'));
      await store.write(const ApiCredentials(provider: 'OPENROUTER', key: 'or'));

      expect(kv.contents['api_provider'], 'GEMINI');
      expect(await orderOf(store), ['GEMINI', 'OPENROUTER']);
    });

    test('takes the lead when the stored default has no key', () async {
      final kv = FakeKeyValueStore({'api_provider': 'GEMINI'});
      final store = SecureApiCredentialStore(kv);

      await store.write(const ApiCredentials(provider: 'OPENROUTER', key: 'or'));

      // A default nothing can be tried against is not a preference worth
      // keeping — the alternative is a user with one key and no leader.
      expect(kv.contents['api_provider'], 'OPENROUTER');
    });

    test('replaces a key already held for that provider', () async {
      final kv = FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key_gemini': 'old',
      });
      final store = SecureApiCredentialStore(kv);

      await store.write(const ApiCredentials(provider: 'GEMINI', key: 'new'));

      expect((await store.readAll()).single.key, 'new');
    });

    test('refuses a provider it has no slot for', () async {
      final store = SecureApiCredentialStore(FakeKeyValueStore());

      // Writing under an unrecognised name would put the key somewhere nothing
      // reads, and the user would be told a key they just saved was rejected.
      expect(
        () => store.write(const ApiCredentials(provider: 'OPENAI', key: 'k')),
        throwsArgumentError,
      );
    });
  });

  group('setDefaultProvider', () {
    test('moves the named provider to the front', () async {
      final store = SecureApiCredentialStore(FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key_gemini': 'g',
        'api_key_openrouter': 'or',
      }));

      await store.setDefaultProvider('OPENROUTER');

      expect(await orderOf(store), ['OPENROUTER', 'GEMINI']);
    });

    test('keeps the others as fallbacks rather than dropping them', () async {
      final kv = FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key_gemini': 'g',
        'api_key_openrouter': 'or',
      });
      final store = SecureApiCredentialStore(kv);

      await store.setDefaultProvider('OPENROUTER');

      expect(kv.contents['api_key_gemini'], 'g');
    });

    test('refuses a provider it has no slot for', () async {
      final store = SecureApiCredentialStore(FakeKeyValueStore());

      expect(() => store.setDefaultProvider('OPENAI'), throwsArgumentError);
    });
  });

  group('deleteProvider', () {
    test('removes only that provider', () async {
      final kv = FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key_gemini': 'g',
        'api_key_openrouter': 'or',
      });
      final store = SecureApiCredentialStore(kv);

      await store.deleteProvider('OPENROUTER');

      expect(await orderOf(store), ['GEMINI']);
      expect(kv.contents.containsKey('api_key_openrouter'), isFalse);
    });

    test('hands the lead to what is left when the default goes', () async {
      final kv = FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key_gemini': 'g',
        'api_key_openrouter': 'or',
      });
      final store = SecureApiCredentialStore(kv);

      await store.deleteProvider('GEMINI');

      // Leaving GEMINI named would report a key the user just removed as the
      // one in use.
      expect(kv.contents['api_provider'], 'OPENROUTER');
      expect(await orderOf(store), ['OPENROUTER']);
    });

    test('forgets the default entirely once the last key goes', () async {
      final kv = FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key_gemini': 'g',
      });
      final store = SecureApiCredentialStore(kv);

      await store.deleteProvider('GEMINI');

      expect(kv.contents.containsKey('api_provider'), isFalse);
      expect(await store.readAll(), isEmpty);
    });

    test('leaves the lead alone when a fallback is removed', () async {
      final kv = FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key_gemini': 'g',
        'api_key_openrouter': 'or',
      });
      final store = SecureApiCredentialStore(kv);

      await store.deleteProvider('OPENROUTER');

      expect(kv.contents['api_provider'], 'GEMINI');
    });

    test('leaves unrelated keys untouched', () async {
      final kv = FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key_gemini': 'g',
        'session_id': 'keep-me',
      });
      final store = SecureApiCredentialStore(kv);

      await store.deleteProvider('GEMINI');

      expect(kv.contents['session_id'], 'keep-me');
    });
  });

  group('deleteAll', () {
    test('removes every provider key and the default', () async {
      final kv = FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key_gemini': 'g',
        'api_key_openrouter': 'or',
        'api_key_nvidia_nim': 'nv',
      });
      final store = SecureApiCredentialStore(kv);

      await store.deleteAll();

      expect(await store.readAll(), isEmpty);
      expect(kv.contents.keys, isEmpty);
    });

    test('also clears a key left over from before there were three', () async {
      final kv = FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key': 'legacy',
      });
      final store = SecureApiCredentialStore(kv);

      await store.deleteAll();

      // Logging out has to leave nothing behind for the next user of a shared
      // device, and the legacy slot is still a live secret until it migrates.
      expect(kv.contents.containsKey('api_key'), isFalse);
    });

    test('is a no-op when nothing is stored', () async {
      final store = SecureApiCredentialStore(FakeKeyValueStore());

      await store.deleteAll();

      expect(await store.readAll(), isEmpty);
    });
  });

  group('the key saved before there were three', () {
    test('becomes that provider\'s key', () async {
      final kv = FakeKeyValueStore({
        'api_provider': 'OPENROUTER',
        'api_key': 'the-one-key',
      });
      final store = SecureApiCredentialStore(kv);

      final saved = await store.readAll();

      // This is the user's only working credential. Dropping it on upgrade
      // would break food analysis for everyone already using the app.
      expect(saved.single.provider, 'OPENROUTER');
      expect(saved.single.key, 'the-one-key');
      expect(kv.contents['api_key_openrouter'], 'the-one-key');
    });

    test('is moved rather than copied, so it migrates once', () async {
      final kv = FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key': 'the-one-key',
      });
      final store = SecureApiCredentialStore(kv);

      await store.readAll();

      expect(kv.contents.containsKey('api_key'), isFalse);
    });

    test('does not come back after its provider is removed', () async {
      final kv = FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key': 'the-one-key',
      });
      final store = SecureApiCredentialStore(kv);

      await store.deleteProvider('GEMINI');

      // A removal that the next read quietly undoes is worse than no removal:
      // the user believes a key they wanted gone is gone.
      expect(await store.readAll(), isEmpty);
    });

    test('loses to a key saved since the upgrade', () async {
      final kv = FakeKeyValueStore({
        'api_provider': 'GEMINI',
        'api_key': 'stale',
        'api_key_gemini': 'current',
      });
      final store = SecureApiCredentialStore(kv);

      expect((await store.readAll()).single.key, 'current');
      expect(kv.contents.containsKey('api_key'), isFalse);
    });

    test('is dropped when no provider was ever stored', () async {
      final kv = FakeKeyValueStore({'api_key': 'orphan'});
      final store = SecureApiCredentialStore(kv);

      // A key with no provider names no endpoint; there is nothing to do with
      // it but stop carrying it around.
      expect(await store.readAll(), isEmpty);
      expect(kv.contents.containsKey('api_key'), isFalse);
    });

    test('is honoured under an older provider spelling', () async {
      final kv = FakeKeyValueStore({
        'api_provider': 'NVIDIA',
        'api_key': 'nv-key',
      });
      final store = SecureApiCredentialStore(kv);

      expect((await store.readAll()).single.provider, 'NVIDIA NIM');
      expect(kv.contents['api_key_nvidia_nim'], 'nv-key');
    });
  });
}
