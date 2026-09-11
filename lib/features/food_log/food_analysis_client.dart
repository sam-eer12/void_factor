import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../../models/food_entry.dart';
import 'api_credentials.dart';

/// A failure with a message already written for the user.
///
/// The screens show [message] verbatim in a snackbar, so mapping happens here
/// once rather than at every call site. Nothing in the message names an HTTP
/// status: every branch ends in something the user can act on.
class FoodAnalysisException implements Exception {
  final String message;

  const FoodAnalysisException(this.message);

  @override
  String toString() => message;
}

/// Who a request is made as.
///
/// One record rather than two seams, because the uid and the token must come
/// from the same Firebase user: FastAPI rejects a request whose `X-User-Id`
/// disagrees with the subject of its bearer token, so a client that could
/// source them independently could produce a combination that always 401s.
typedef AnalysisCaller = ({String uid, String idToken});

/// Posts a photo to the analysis microservice and returns what it recognised.
///
/// The microservice fronts three providers behind nginx. nginx rate-limits on
/// `X-User-Id` (10 requests/min per user) and rejects a request without it, so
/// every call carries the signed-in uid. The uid is not what authorizes the
/// call — FastAPI verifies the bearer token — but nginx cannot verify a JWT, so
/// it needs a cheap key of its own.
class FoodAnalysisClient {
  /// Outlasts the backend's own timeout deliberately.
  /// `openai_compatible.py` builds `httpx.AsyncClient(timeout=60)`, so giving up
  /// at 60s or less would abandon a request that is still being served — the
  /// user would see a failure for a scan that succeeded.
  static const Duration defaultTimeout = Duration(seconds: 75);

  // ── User-facing copy. Each maps one failure to one next action. ──
  static const String errorNoKey = 'NO API KEY — SET ONE IN SETTINGS';
  static const String errorRateLimit =
      'RATE LIMIT — 10 SCANS/MIN, WAIT A MOMENT';
  static const String errorKeyRejected =
      'API KEY REJECTED — UPDATE IT IN SETTINGS';
  static const String errorProviderFailed =
      'PROVIDER FAILED — RETRY OR ENTER MANUALLY';
  static const String errorUnreadablePhoto =
      "COULDN'T READ THAT PHOTO — ENTER MANUALLY";
  static const String errorUnreachable = "CAN'T REACH ANALYSIS SERVICE";
  static const String errorSignedOut = 'NOT SIGNED IN — LOG IN AGAIN';
  static const String errorUnknownProvider =
      'UNKNOWN PROVIDER — SET IT AGAIN IN SETTINGS';
  static const String errorSessionExpired = 'SESSION EXPIRED — SIGN IN AGAIN';
  static const String errorServiceNotReady =
      'ANALYSIS SERVICE NOT READY — TRY AGAIN LATER';

  FoodAnalysisClient({
    http.Client? httpClient,
    ApiCredentialStore? credentialStore,
    String? baseUrl,
    Future<AnalysisCaller?> Function()? caller,
    this.timeout = defaultTimeout,
  })  : _http = httpClient ?? http.Client(),
        _credentials = credentialStore ?? SecureApiCredentialStore(),
        _baseUrl = _trimTrailingSlash(baseUrl ?? defaultBaseUrl()),
        _caller = caller ?? firebaseCaller;

  final http.Client _http;
  final ApiCredentialStore _credentials;
  final String _baseUrl;
  final Future<AnalysisCaller?> Function() _caller;
  final Duration timeout;

  /// The signed-in user's uid and a currently-valid ID token.
  ///
  /// `getIdToken()` returns the cached token until it is close to expiry and
  /// only then goes to the network, so this is usually free. Returns `null`
  /// when nobody is signed in; throws when the token could not be obtained,
  /// which [analyze] maps separately — offline is not signed out.
  static Future<AnalysisCaller?> firebaseCaller() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) return null;
    return (uid: user.uid, idToken: token);
  }

  /// `--dart-define=FOOD_API_BASE_URL=...` wins when set, so a physical device
  /// can point at a LAN address. Otherwise: the Android emulator reaches the
  /// host through 10.0.2.2, everything else through localhost. Port 8080 is
  /// nginx's published port in docker-compose.yml.
  static String defaultBaseUrl() {
    const configured = String.fromEnvironment('FOOD_API_BASE_URL');
    if (configured.isNotEmpty) return configured;
    return Platform.isAndroid ? 'http://10.0.2.2:8080' : 'http://localhost:8080';
  }

  /// Maps a stored provider name to its route segment.
  ///
  /// `'NVIDIA NIM'` is the string the onboarding selector writes; `nvidia` is
  /// the route. That gap is the whole reason this is a named function.
  static String providerSlug(String provider) {
    switch (provider.trim().toUpperCase()) {
      case 'GEMINI':
        return 'gemini';
      case 'OPENROUTER':
        return 'openrouter';
      case 'NVIDIA NIM':
      case 'NVIDIA':
        return 'nvidia';
      default:
        throw const FoodAnalysisException(errorUnknownProvider);
    }
  }

  /// `gemini` -> `X-Gemini-Key`, which is the header FastAPI reads into
  /// `x_gemini_key`. The same derivation holds for all three routes.
  static String keyHeaderName(String provider) {
    final slug = providerSlug(provider);
    return 'X-${slug[0].toUpperCase()}${slug.substring(1)}-Key';
  }

  /// Sends [image] for analysis and returns its name and **per-serving**
  /// nutrients. Quantity is the user's business, applied later in the form.
  ///
  /// Throws [FoodAnalysisException] with display-ready copy on every failure.
  Future<(String, Nutrients)> analyze(File image) async {
    final credentials = await _credentials.read();
    // Checked before touching the network: a keyless request would spend one of
    // the user's ten scans per minute to earn a 401.
    if (credentials == null) throw const FoodAnalysisException(errorNoKey);

    final AnalysisCaller? caller;
    try {
      caller = await _caller();
    } on FirebaseAuthException {
      // The account was disabled, deleted, or its tokens revoked. Signing in
      // again is the only thing that helps.
      throw const FoodAnalysisException(errorSessionExpired);
    } catch (_) {
      // Refreshing an expired token needs the network. Being offline is not
      // being logged out, and telling the user to sign in again would send them
      // to a screen that also cannot reach anything.
      throw const FoodAnalysisException(errorUnreachable);
    }
    if (caller == null || caller.uid.isEmpty) {
      // nginx answers a missing X-User-Id with a bare 400, which would surface
      // as a provider failure and send the user to check their key for nothing.
      throw const FoodAnalysisException(errorSignedOut);
    }

    final slug = providerSlug(credentials.provider);

    final List<int> bytes;
    try {
      bytes = await image.readAsBytes();
    } on FileSystemException {
      throw const FoodAnalysisException(errorUnreadablePhoto);
    }

    final request =
        http.MultipartRequest('POST', Uri.parse('$_baseUrl/api/v1/$slug'))
          ..headers[keyHeaderName(credentials.provider)] = credentials.key
          ..headers['X-User-Id'] = caller.uid
          // What actually authorizes the call. nginx keys its rate limit on the
          // header above; FastAPI verifies this and rejects the pair if the
          // token's subject is not that uid.
          ..headers['Authorization'] = 'Bearer ${caller.idToken}'
          // Field name is fixed by routes.py: `image: UploadFile = File(...)`.
          ..files.add(http.MultipartFile.fromBytes('image', bytes,
              filename: 'meal.jpg'));

    final http.Response response;
    try {
      final streamed = await _http.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw const FoodAnalysisException(errorUnreachable);
    } on SocketException {
      throw const FoodAnalysisException(errorUnreachable);
    } on http.ClientException {
      throw const FoodAnalysisException(errorUnreachable);
    }

    if (response.statusCode != 200) {
      throw FoodAnalysisException(
        _messageForFailure(response.statusCode, response.body),
      );
    }

    return _parseSuccess(response.body);
  }

  (String, Nutrients) _parseSuccess(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const FoodAnalysisException(errorUnreadablePhoto);
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FoodAnalysisException(errorUnreadablePhoto);
    }

    final rawNutrients = decoded['nutrients'];
    return (
      // normalize() falls back to "" for a name no model supplied. An empty
      // name is not a failure: the macros are still worth keeping, and the
      // form's validator makes the user name it before saving.
      decoded['name']?.toString().trim() ?? '',
      rawNutrients is Map<String, dynamic>
          ? Nutrients.fromApi(rawNutrients)
          : const Nutrients(),
    );
  }

  /// Turns a status plus FastAPI's `{"detail": ...}` into one next action.
  String _messageForFailure(int status, String body) {
    // nginx, not the microservice: limit_req_status 429.
    if (status == 429) return errorRateLimit;

    final detail = _detailOf(body);

    // Everything auth.py rejects carries an `auth:` prefix. Without this the
    // two meanings of 401 collapse and a user whose login expired is told to
    // go and replace an API key that was never the problem.
    if (detail.startsWith('auth:')) {
      return status == 503 ? errorServiceNotReady : errorSessionExpired;
    }
    // The service is up but has no FIREBASE_PROJECT_ID, so it is refusing
    // everyone. Nothing the user can do, and nothing about their key.
    if (status == 503) return errorServiceNotReady;

    // gemini.py raises a bare 401 when the *provider* key is missing; the
    // openai-compatible path wraps a rejected key as a 502 instead.
    if (status == 401 || status == 403) return errorKeyRejected;

    // The provider replied, but with unusable JSON. Retrying the same photo
    // would spend another scan for the same result, so route to manual entry.
    if (detail.contains('invalid response from model')) {
      return errorUnreadablePhoto;
    }
    // "provider error: 401" — the upstream provider rejected the user's key.
    if (detail.startsWith('provider error:') &&
        (detail.endsWith('401') || detail.endsWith('403'))) {
      return errorKeyRejected;
    }
    return errorProviderFailed;
  }

  String _detailOf(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] != null) {
        return decoded['detail'].toString();
      }
    } on FormatException {
      // A non-JSON body (an nginx error page) carries no detail to read.
    }
    return '';
  }

  static String _trimTrailingSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;
}
