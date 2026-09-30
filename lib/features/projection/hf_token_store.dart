import '../food_log/api_credentials.dart';

/// The old direct Hugging Face flow stored a token under this key. New model
/// downloads use a signed link from the app's service and never read that token.
const legacyHuggingFaceTokenKey = 'hf_token';

Future<void> eraseLegacyHuggingFaceToken([CredentialKeyValueStore? store]) =>
    (store ?? const SecureCredentialKeyValueStore()).delete(
      legacyHuggingFaceTokenKey,
    );
