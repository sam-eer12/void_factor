import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../food_log/api_credentials.dart';

/// Acceptance is stored per account and per displayed terms revision.
abstract class ModelTermsStore {
  Future<bool> hasAccepted(String uid, String version);
  Future<void> accept(String uid, String version);
}

class SecureModelTermsStore implements ModelTermsStore {
  SecureModelTermsStore([CredentialKeyValueStore? store])
    : _store = store ?? const SecureCredentialKeyValueStore();

  final CredentialKeyValueStore _store;

  String _key(String uid) => 'gemma_terms_$uid';

  @override
  Future<bool> hasAccepted(String uid, String version) async =>
      await _store.read(_key(uid)) == version;

  @override
  Future<void> accept(String uid, String version) =>
      _store.write(_key(uid), version);
}

final modelTermsStoreProvider = Provider<ModelTermsStore>((ref) {
  return SecureModelTermsStore();
});
