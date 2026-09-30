import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../food_log/food_analysis_client.dart';
import 'model_artifact.dart';

class ModelDownloadException implements Exception {
  const ModelDownloadException(this.message);
  final String message;

  @override
  String toString() => message;
}

class ModelDownloadLink {
  const ModelDownloadLink({required this.url, required this.expiresAt});
  final Uri url;
  final DateTime expiresAt;
}

/// Signed URLs are never printed or included in exceptions. A response only
/// becomes usable after its descriptor matches the app's pinned manifest.
class ModelDownloadLinkClient {
  ModelDownloadLinkClient({
    http.Client? client,
    String? baseUrl,
    Future<AnalysisCaller?> Function()? caller,
  }) : _client = client ?? http.Client(),
       _baseUrl = baseUrl ?? FoodAnalysisClient.defaultBaseUrl(),
       _caller = caller ?? FoodAnalysisClient.firebaseCaller;

  final http.Client _client;
  final String _baseUrl;
  final Future<AnalysisCaller?> Function() _caller;

  Future<({String uid, ModelDownloadLink link})> request(
    ModelArtifact expected,
  ) async {
    final caller = await _caller();
    if (caller == null || caller.uid.isEmpty || caller.idToken.isEmpty) {
      throw const ModelDownloadException('SIGN IN TO DOWNLOAD THE MODEL');
    }
    final endpoint = Uri.parse(
      '${_baseUrl.replaceFirst(RegExp(r'/$'), '')}'
      '/api/v1/models/gemma/download-link',
    );
    late http.Response response;
    try {
      response = await _client
          .post(
            endpoint,
            headers: {
              'Authorization': 'Bearer ${caller.idToken}',
              'X-User-Id': caller.uid,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'accepted_terms_version': expected.termsVersion}),
          )
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      throw const ModelDownloadException(
        'MODEL SERVICE UNREACHABLE — TRY AGAIN',
      );
    }
    if (response.statusCode == 401) {
      throw const ModelDownloadException('SESSION EXPIRED — SIGN IN AGAIN');
    }
    if (response.statusCode == 429) {
      throw const ModelDownloadException(
        'TOO MANY MODEL REQUESTS — WAIT A MOMENT',
      );
    }
    if (response.statusCode == 503) {
      throw const ModelDownloadException(
        'MODEL DOWNLOAD UNAVAILABLE — TRY LATER',
      );
    }
    if (response.statusCode == 409) {
      throw const ModelDownloadException(
        'MODEL TERMS UPDATED — UPDATE THIS APP',
      );
    }
    if (response.statusCode != 200) {
      throw const ModelDownloadException(
        'COULDN’T ISSUE MODEL LINK — TRY AGAIN',
      );
    }
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final actual = ModelArtifact.fromJson(
        body['model'] as Map<String, dynamic>,
      );
      if (!expected.matches(actual)) {
        throw const FormatException('Model descriptor mismatch');
      }
      final url = Uri.parse(body['url'] as String);
      final expiry = DateTime.parse(body['expires_at'] as String).toUtc();
      final base = Uri.parse(_baseUrl);
      final local =
          base.scheme == 'http' &&
          {'localhost', '127.0.0.1', '::1', '10.0.2.2'}.contains(base.host) &&
          url.host == base.host &&
          url.port == base.port;
      if (url.host.isEmpty ||
          url.userInfo.isNotEmpty ||
          url.fragment.isNotEmpty ||
          (url.scheme != 'https' && !(local && url.scheme == 'http'))) {
        throw const FormatException('Unsafe model URL');
      }
      if (!expiry.isAfter(DateTime.now().toUtc())) {
        throw const FormatException('Expired model URL');
      }
      return (
        uid: caller.uid,
        link: ModelDownloadLink(url: url, expiresAt: expiry),
      );
    } catch (_) {
      throw const ModelDownloadException('MODEL LINK DID NOT MATCH THIS APP');
    }
  }
}

final modelDownloadLinkClientProvider = Provider<ModelDownloadLinkClient>((
  ref,
) {
  return ModelDownloadLinkClient();
});
