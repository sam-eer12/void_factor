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

/// What one analysis came back with.
///
/// [nutrients] always describe a single serving and [quantity] is how many of
/// that serving the model counted on the plate — the same split [FoodEntry]
/// stores, so the form can seed its stepper without re-deriving anything. A
/// record rather than a third tuple slot: `draft.$3` says nothing at a call
/// site, and these three travel together everywhere.
typedef FoodAnalysis = ({String name, Nutrients nutrients, double quantity});

/// Posts a photo to the analysis microservice and returns what it recognised.
///
/// The microservice fronts three providers behind nginx, which rate-limits
/// each user to 10 requests/min. The bearer token is what identifies the user
/// for that limit and what authorizes the call: nginx has FastAPI verify it
/// before counting the request. `X-User-Id` still travels alongside, and
/// FastAPI refuses the pair unless it names the token's own subject.
///
/// A user may have a key for more than one of those providers. The store hands
/// them over already ordered — the one they nominated first — and [analyze]
/// walks that order, so a revoked key or a provider outage is absorbed here
/// rather than becoming a trip to Settings. Each attempt is a real request and
/// costs one of the ten per minute, which is why only failures another provider
/// could actually fix are worth continuing past.
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
  static const String errorPhotoTooLarge =
      'PHOTO TOO LARGE — TRY A SMALLER ONE';
  static const String errorProviderCannotReadPhoto =
      "THIS PROVIDER CAN'T READ THAT PHOTO — TRY A JPEG";

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
  Future<FoodAnalysis> analyze(File image) async {
    final credentials = await _credentials.readAll();
    // Checked before touching the network: a keyless request would spend one of
    // the user's ten scans per minute to earn a 401.
    if (credentials.isEmpty) throw const FoodAnalysisException(errorNoKey);

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
      // Without a user there is no token to send, and the request could only
      // come back 401 — spending a round trip to learn what is known here.
      throw const FoodAnalysisException(errorSignedOut);
    }

    // Read once and reused across attempts. Re-reading per provider would go to
    // the filesystem three times for bytes that cannot have changed, and would
    // turn a file deleted mid-fallback into a second, different failure.
    final List<int> bytes;
    try {
      bytes = await image.readAsBytes();
    } on FileSystemException {
      throw const FoodAnalysisException(errorUnreadablePhoto);
    }

    // Whatever the chain does, the *first* provider's failure is what gets
    // reported: it is the key the user nominated and the one they can act on,
    // and a fallback's unrelated complaint would send them to fix the wrong
    // thing.
    FoodAnalysisException? firstFailure;
    for (final credential in credentials) {
      try {
        return await _attempt(credential, caller, bytes);
      } on FoodAnalysisException catch (error) {
        firstFailure ??= error;
        if (!_isWorthAnotherProvider(error.message)) break;
      }
    }
    throw firstFailure!;
  }

  /// Whether a different provider could plausibly succeed where this one did
  /// not.
  ///
  /// Deliberately narrow. A rate limit is nginx counting *this user's* requests
  /// rather than the provider's, so a second attempt would spend another of the
  /// ten and meet the same wall. A session or reachability failure belongs to
  /// the app's own backend, which all three providers sit behind. And a photo
  /// the model could not read is the photo's problem, not the key's — falling
  /// through there would spend three scans to arrive at the same "enter it
  /// manually".
  static bool _isWorthAnotherProvider(String message) =>
      message == errorKeyRejected ||
      message == errorProviderFailed ||
      // A real photo in a format this provider does not take (HEIC, to an
      // OpenAI-compatible one). Gemini reads it, so the next key may well.
      message == errorProviderCannotReadPhoto ||
      // Not a failure of the request at all: this build does not recognise the
      // stored provider, so there was never anything to try for it. The next
      // one may be perfectly fine.
      message == errorUnknownProvider;

  /// One request to one provider.
  ///
  /// Every failure leaves as a [FoodAnalysisException], so the only decision
  /// left to [analyze] is whether to try the next provider.
  Future<FoodAnalysis> _attempt(
    ApiCredentials credentials,
    AnalysisCaller caller,
    List<int> bytes,
  ) async {
    final slug = providerSlug(credentials.provider);

    final request =
        http.MultipartRequest('POST', Uri.parse('$_baseUrl/api/v1/$slug'))
          ..headers[keyHeaderName(credentials.provider)] = credentials.key
          ..headers['X-User-Id'] = caller.uid
          // What actually authorizes the call, and whose subject nginx keys its
          // rate limit on once FastAPI has verified it. FastAPI also rejects
          // the pair if the token's subject is not the uid above.
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

  FoodAnalysis _parseSuccess(String body) {
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
      name: decoded['name']?.toString().trim() ?? '',
      nutrients: rawNutrients is Map<String, dynamic>
          ? Nutrients.fromApi(rawNutrients)
          : const Nutrients(),
      // The model counts pieces; the stepper works in half servings and has
      // bounds of its own. Snapped here so the form never opens on a quantity
      // its own control could not have produced.
      quantity: FoodEntry.snapQuantity(_quantityOf(decoded['quantity'])),
    );
  }

  /// How many servings the plate holds, defaulting to one.
  ///
  /// `parsing.py` already coerces this, so anything unusable here means the
  /// response did not come from the service. One serving is the honest reading
  /// either way — the nutrients describe one, and the user can step it.
  static double _quantityOf(Object? value) {
    final quantity = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString().trim() ?? '');
    if (quantity == null || !quantity.isFinite || quantity <= 0) return 1.0;
    return quantity;
  }

  /// Turns a status plus FastAPI's `{"detail": ...}` into one next action.
  String _messageForFailure(int status, String body) {
    // nginx, not the microservice: limit_req_status 429.
    if (status == 429) return errorRateLimit;
    // From nginx's body cap (an HTML page) or the service's own
    // (`image: too large`). Either way no provider could take it.
    if (status == 413) return errorPhotoTooLarge;

    final detail = _detailOf(body);

    // Everything images.py rejects carries an `image:` prefix: the upload was
    // refused before any provider saw it, so the key is not at fault.
    if (detail.startsWith('image:')) {
      return detail == 'image: format not supported by this provider'
          ? errorProviderCannotReadPhoto
          : errorUnreadablePhoto;
    }

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
