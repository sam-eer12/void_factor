import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/food_log/api_credentials.dart';
import 'package:void_factor/features/projection/hf_token_store.dart';
import 'package:void_factor/features/projection/model_terms_store.dart';

class _Memory implements CredentialKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  test('acceptance is isolated by account and displayed revision', () async {
    final store = SecureModelTermsStore(_Memory());
    await store.accept('u1', '2026-04-01');
    expect(await store.hasAccepted('u1', '2026-04-01'), isTrue);
    expect(await store.hasAccepted('u2', '2026-04-01'), isFalse);
    expect(await store.hasAccepted('u1', '2026-05-01'), isFalse);
    await store.accept('u1', '2026-05-01');
    expect(await store.hasAccepted('u1', '2026-05-01'), isTrue);
  });

  test('migration erases only the legacy Hugging Face credential', () async {
    final storage = _Memory();
    storage.values.addAll({
      'hf_token': 'legacy-token',
      'gemma_terms_u1': '2026-04-01',
    });
    await eraseLegacyHuggingFaceToken(storage);
    expect(storage.values, {'gemma_terms_u1': '2026-04-01'});
    await eraseLegacyHuggingFaceToken(storage);
  });
}
