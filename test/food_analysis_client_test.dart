import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:void_factor/features/food_log/api_credentials.dart';
import 'package:void_factor/features/food_log/food_analysis_client.dart';
import 'package:void_factor/models/food_entry.dart';

class FakeCredentialStore implements ApiCredentialStore {
  FakeCredentialStore([List<ApiCredentials>? credentials])
      : credentials = credentials ?? const [];

  /// Already in try order, which is the contract the real store keeps.
  List<ApiCredentials> credentials;

  @override
  Future<List<ApiCredentials>> readAll() async => credentials;
  @override
  Future<void> write(ApiCredentials c) async => credentials = [c];
  @override
  Future<void> setDefaultProvider(String provider) async {}
  @override
  Future<void> deleteProvider(String provider) async => credentials = [
        for (final c in credentials)
          if (c.provider != provider) c,
      ];
  @override
  Future<void> deleteAll() async => credentials = const [];
}

/// The success body the microservice returns: `normalize()` output.
String successBody({
  String name = 'Grilled Chicken Salad',
  Object? calories = 450,
  Object? proteinG = 42,
  Object? carbsG = 30,
  Object? fatsG = 12,
  /// Left out of the body entirely when null — which is what the service
  /// returned before it carried a count, and what a model that ignores the key
  /// still produces.
  Object? quantity,
}) {
  return jsonEncode({
    'name': name,
    'quantity': ?quantity,
    'nutrients': {
      'calories': calories,
      'protein_g': proteinG,
      'carbs_g': carbsG,
      'fats_g': fatsG,
    },
  });
}

/// FastAPI renders every HTTPException as {"detail": ...}.
String detailBody(String detail) => jsonEncode({'detail': detail});

void main() {
  late Directory tempDir;
  late File image;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('food_analysis_test');
    image = File('${tempDir.path}/meal.jpg')
      ..writeAsBytesSync(const [1, 2, 3, 4, 5]);
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  FoodAnalysisClient clientWith(
    MockClient mock, {
    ApiCredentials? credentials =
        const ApiCredentials(provider: 'GEMINI', key: 'test-key'),
    /// Several keys in try order, for the fallback path. Wins over
    /// [credentials] when given.
    List<ApiCredentials>? chain,
    String? uid = 'uid-123',
    String token = 'test-id-token',
    Duration timeout = const Duration(seconds: 5),
    Future<AnalysisCaller?> Function()? caller,
  }) {
    return FoodAnalysisClient(
      httpClient: mock,
      credentialStore: FakeCredentialStore(chain ?? [?credentials]),
      baseUrl: 'http://test.local:8080',
      caller: caller ??
          () async => uid == null ? null : (uid: uid, idToken: token),
      timeout: timeout,
    );
  }

  group('providerSlug', () {
    test('maps the three selector values to microservice path segments', () {
      expect(FoodAnalysisClient.providerSlug('GEMINI'), 'gemini');
      expect(FoodAnalysisClient.providerSlug('OPENROUTER'), 'openrouter');
      // The display name has a space; the route does not.
      expect(FoodAnalysisClient.providerSlug('NVIDIA NIM'), 'nvidia');
    });

    test('tolerates case and surrounding whitespace', () {
      expect(FoodAnalysisClient.providerSlug('  gemini '), 'gemini');
      expect(FoodAnalysisClient.providerSlug('Nvidia Nim'), 'nvidia');
    });

    test('rejects an unknown provider', () {
      expect(
        () => FoodAnalysisClient.providerSlug('SKYNET'),
        throwsA(isA<FoodAnalysisException>()),
      );
    });
  });

  group('keyHeaderName', () {
    test('matches the header names the FastAPI routes declare', () {
      // routes.py declares x_gemini_key / x_openrouter_key / x_nvidia_key,
      // which FastAPI reads from these exact headers.
      expect(FoodAnalysisClient.keyHeaderName('GEMINI'), 'X-Gemini-Key');
      expect(
          FoodAnalysisClient.keyHeaderName('OPENROUTER'), 'X-Openrouter-Key');
      expect(FoodAnalysisClient.keyHeaderName('NVIDIA NIM'), 'X-Nvidia-Key');
    });
  });

  group('request shape', () {
    test('posts to the provider route with the key and user headers', () async {
      http.Request? captured;
      final client = clientWith(MockClient((request) async {
        captured = request;
        return http.Response(successBody(), 200);
      }));

      await client.analyze(image);

      expect(captured!.method, 'POST');
      expect(captured!.url.toString(), 'http://test.local:8080/api/v1/gemini');
      expect(captured!.headers['X-Gemini-Key'], 'test-key');
      // nginx rate-limits on this header and returns 400 without it.
      expect(captured!.headers['X-User-Id'], 'uid-123');
    });

    test('routes OPENROUTER to its own path and header', () async {
      http.Request? captured;
      final client = clientWith(
        MockClient((request) async {
          captured = request;
          return http.Response(successBody(), 200);
        }),
        credentials:
            const ApiCredentials(provider: 'OPENROUTER', key: 'or-key'),
      );

      await client.analyze(image);

      expect(
          captured!.url.toString(), 'http://test.local:8080/api/v1/openrouter');
      expect(captured!.headers['X-Openrouter-Key'], 'or-key');
    });

    test('routes NVIDIA NIM to the nvidia path and header', () async {
      http.Request? captured;
      final client = clientWith(
        MockClient((request) async {
          captured = request;
          return http.Response(successBody(), 200);
        }),
        credentials:
            const ApiCredentials(provider: 'NVIDIA NIM', key: 'nv-key'),
      );

      await client.analyze(image);

      expect(captured!.url.toString(), 'http://test.local:8080/api/v1/nvidia');
      expect(captured!.headers['X-Nvidia-Key'], 'nv-key');
    });

    test('sends the file as multipart under the field name "image"', () async {
      http.Request? captured;
      final client = clientWith(MockClient((request) async {
        captured = request;
        return http.Response(successBody(), 200);
      }));

      await client.analyze(image);

      expect(captured!.headers['content-type'], contains('multipart/form-data'));
      // routes.py binds `image: UploadFile = File(...)`, so the field name is
      // part of the contract.
      final body = latin1.decode(captured!.bodyBytes);
      expect(body, contains('name="image"'));
      expect(captured!.bodyBytes.length, greaterThan(5));
    });

    test('never pre-multiplies quantity — it returns per-serving nutrients',
        () async {
      final client = clientWith(MockClient((_) async {
        return http.Response(successBody(calories: 450), 200);
      }));

      final (name: _, :nutrients, quantity: _) = await client.analyze(image);

      expect(nutrients.calories, 450);
    });
  });

  group('successful analysis', () {
    test('returns the name and per-serving nutrients', () async {
      final client = clientWith(MockClient((_) async {
        return http.Response(successBody(), 200);
      }));

      final (:name, :nutrients, quantity: _) = await client.analyze(image);

      expect(name, 'Grilled Chicken Salad');
      // The model type crosses the boundary, not the raw snake_case wire map.
      expect(nutrients, isA<Nutrients>());
      expect(nutrients.calories, 450);
      expect(nutrients.proteinG, 42);
      expect(nutrients.carbsG, 30);
      expect(nutrients.fatsG, 12);
    });

    test('reads null macros as zero rather than failing', () async {
      // normalize() emits null for any macro the model omitted.
      final client = clientWith(MockClient((_) async {
        return http.Response(
          successBody(proteinG: null, carbsG: null, fatsG: null),
          200,
        );
      }));

      final (name: _, :nutrients, quantity: _) = await client.analyze(image);

      expect(nutrients.calories, 450);
      expect(nutrients.proteinG, 0);
    });

    test('returns an empty name rather than an error when the model gave none',
        () async {
      // normalize() falls back to "" for a missing name. The form's own
      // validator then makes the user supply one, which beats discarding a
      // usable macro reading.
      final client = clientWith(MockClient((_) async {
        return http.Response(successBody(name: ''), 200);
      }));

      final (:name, :nutrients, quantity: _) = await client.analyze(image);

      expect(name, '');
      expect(nutrients.calories, 450);
    });

    test('trims whitespace off the returned name', () async {
      final client = clientWith(MockClient((_) async {
        return http.Response(successBody(name: '  Oatmeal  '), 200);
      }));

      final (:name, nutrients: _, quantity: _) = await client.analyze(image);

      expect(name, 'Oatmeal');
    });
  });

  group('missing credential', () {
    test('throws before making any HTTP call', () async {
      var called = false;
      final client = clientWith(
        MockClient((_) async {
          called = true;
          return http.Response(successBody(), 200);
        }),
        credentials: null,
      );

      await expectLater(
        client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having(
          (e) => e.message,
          'message',
          FoodAnalysisClient.errorNoKey,
        )),
      );
      // The point of the guard: no request is spent on a doomed call, and the
      // per-user rate limit is not consumed.
      expect(called, isFalse);
    });

    test('reports the no-key copy from the design', () {
      expect(FoodAnalysisClient.errorNoKey, 'NO API KEY — SET ONE IN SETTINGS');
    });
  });

  group('error mapping', () {
    Future<void> expectMessage(FoodAnalysisClient client, String message) =>
        expectLater(
          client.analyze(image),
          throwsA(isA<FoodAnalysisException>()
              .having((e) => e.message, 'message', message)),
        );

    test("413 from nginx's body cap says the photo is too large", () async {
      // nginx answers with its own HTML page, so there is no detail to read.
      final client = clientWith(MockClient((_) async {
        return http.Response('<html>413 Request Entity Too Large</html>', 413);
      }));
      await expectMessage(client, 'PHOTO TOO LARGE — TRY A SMALLER ONE');
    });

    test("413 from the service's own cap says the same", () async {
      final client = clientWith(MockClient((_) async {
        return http.Response(detailBody('image: too large'), 413);
      }));
      await expectMessage(client, 'PHOTO TOO LARGE — TRY A SMALLER ONE');
    });

    test('an upload that is not an image blames the photo', () async {
      final client = clientWith(MockClient((_) async {
        return http.Response(detailBody('image: unrecognised format'), 415);
      }));
      await expectMessage(client, "COULDN'T READ THAT PHOTO — ENTER MANUALLY");
    });

    test('an empty upload blames the photo', () async {
      final client = clientWith(MockClient((_) async {
        return http.Response(detailBody('image: empty upload'), 400);
      }));
      await expectMessage(client, "COULDN'T READ THAT PHOTO — ENTER MANUALLY");
    });

    test('a verifier outage at nginx reads as the service not being ready',
        () async {
      final client = clientWith(MockClient((_) async {
        return http.Response(detailBody('auth: verifier unavailable'), 503);
      }));
      await expectMessage(
          client, 'ANALYSIS SERVICE NOT READY — TRY AGAIN LATER');
    });

    test('429 from nginx becomes the rate-limit message', () async {
      final client = clientWith(MockClient((_) async {
        // nginx's limit_req, not the microservice.
        return http.Response(jsonEncode({'error': 'rate limit exceeded'}), 429);
      }));

      await expectLater(
        client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having(
          (e) => e.message,
          'message',
          'RATE LIMIT — 10 SCANS/MIN, WAIT A MOMENT',
        )),
      );
    });

    test('502 provider error: 401 becomes the key-rejected message', () async {
      final client = clientWith(MockClient((_) async {
        return http.Response(detailBody('provider error: 401'), 502);
      }));

      await expectLater(
        client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having(
          (e) => e.message,
          'message',
          'API KEY REJECTED — UPDATE IT IN SETTINGS',
        )),
      );
    });

    test('502 provider error: 403 becomes the key-rejected message', () async {
      final client = clientWith(MockClient((_) async {
        return http.Response(detailBody('provider error: 403'), 502);
      }));

      await expectLater(
        client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having(
          (e) => e.message,
          'message',
          'API KEY REJECTED — UPDATE IT IN SETTINGS',
        )),
      );
    });

    test('a bare 401 becomes the key-rejected message', () async {
      // gemini.py raises 401 "Gemini API Key missing" directly, without the
      // 502 wrapper the openai-compatible path uses.
      final client = clientWith(MockClient((_) async {
        return http.Response(detailBody('Gemini API Key missing'), 401);
      }));

      await expectLater(
        client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having(
          (e) => e.message,
          'message',
          'API KEY REJECTED — UPDATE IT IN SETTINGS',
        )),
      );
    });

    test('502 provider error on another status becomes provider-failed',
        () async {
      final client = clientWith(MockClient((_) async {
        return http.Response(detailBody('provider error: 500'), 502);
      }));

      await expectLater(
        client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having(
          (e) => e.message,
          'message',
          'PROVIDER FAILED — RETRY OR ENTER MANUALLY',
        )),
      );
    });

    test('502 provider request failed becomes provider-failed', () async {
      final client = clientWith(MockClient((_) async {
        return http.Response(detailBody('provider request failed'), 502);
      }));

      await expectLater(
        client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having(
          (e) => e.message,
          'message',
          'PROVIDER FAILED — RETRY OR ENTER MANUALLY',
        )),
      );
    });

    test('502 invalid response from model blames the photo, not the provider',
        () async {
      // The provider answered; it just did not answer with usable JSON. Telling
      // the user to retry the same photo would waste another scan.
      final client = clientWith(MockClient((_) async {
        return http.Response(detailBody('invalid response from model'), 502);
      }));

      await expectLater(
        client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having(
          (e) => e.message,
          'message',
          "COULDN'T READ THAT PHOTO — ENTER MANUALLY",
        )),
      );
    });

    test('an unparseable success body blames the photo', () async {
      final client = clientWith(MockClient((_) async {
        return http.Response('<html>gateway</html>', 200);
      }));

      await expectLater(
        client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having(
          (e) => e.message,
          'message',
          "COULDN'T READ THAT PHOTO — ENTER MANUALLY",
        )),
      );
    });

    test('an unexpected status falls back to provider-failed', () async {
      final client = clientWith(MockClient((_) async {
        return http.Response('', 500);
      }));

      await expectLater(
        client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having(
          (e) => e.message,
          'message',
          'PROVIDER FAILED — RETRY OR ENTER MANUALLY',
        )),
      );
    });

    test('a socket failure becomes the unreachable message', () async {
      final client = clientWith(MockClient((_) async {
        throw const SocketException('connection refused');
      }));

      await expectLater(
        client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having(
          (e) => e.message,
          'message',
          "CAN'T REACH ANALYSIS SERVICE",
        )),
      );
    });

    test('a client exception becomes the unreachable message', () async {
      final client = clientWith(MockClient((_) async {
        throw http.ClientException('broken pipe');
      }));

      await expectLater(
        client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having(
          (e) => e.message,
          'message',
          "CAN'T REACH ANALYSIS SERVICE",
        )),
      );
    });

    test('a timeout becomes the unreachable message', () async {
      final client = clientWith(
        MockClient((_) async {
          await Future.delayed(const Duration(seconds: 30));
          return http.Response(successBody(), 200);
        }),
        timeout: const Duration(milliseconds: 50),
      );

      await expectLater(
        client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having(
          (e) => e.message,
          'message',
          "CAN'T REACH ANALYSIS SERVICE",
        )),
      );
    });

    test('a missing image file blames the photo', () async {
      var called = false;
      final client = clientWith(MockClient((_) async {
        called = true;
        return http.Response(successBody(), 200);
      }));
      final missing = File('${tempDir.path}/gone.jpg');

      await expectLater(
        client.analyze(missing),
        throwsA(isA<FoodAnalysisException>()),
      );
      expect(called, isFalse);
    });
  });

  group('signed-out guard', () {
    test('throws without calling nginx when there is no uid', () async {
      // With no user there is no token, and the request could only come back
      // 401 — a round trip, and a scan, to learn what is already known.
      var called = false;
      final client = clientWith(
        MockClient((_) async {
          called = true;
          return http.Response(successBody(), 200);
        }),
        uid: null,
      );

      await expectLater(
        client.analyze(image),
        throwsA(isA<FoodAnalysisException>()),
      );
      expect(called, isFalse);
    });

    test('says to sign in again rather than blaming the key', () async {
      final client = clientWith(
        MockClient((_) async => http.Response(successBody(), 200)),
        uid: null,
      );

      await expectLater(
        client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having(
          (e) => e.message, 'message', FoodAnalysisClient.errorSignedOut)),
      );
    });
  });

  group('bearer token', () {
    test('sends the ID token the service verifies', () async {
      http.BaseRequest? captured;
      final client = clientWith(
        MockClient((request) async {
          captured = request;
          return http.Response(successBody(), 200);
        }),
        token: 'eyJhbGciOiJSUzI1NiJ9.payload.sig',
      );

      await client.analyze(image);

      expect(captured!.headers['Authorization'],
          'Bearer eyJhbGciOiJSUzI1NiJ9.payload.sig');
    });

    test('still sends X-User-Id, which is what nginx rate-limits on', () async {
      // Both headers, not one: nginx needs a cheap key before FastAPI has
      // verified anything, and FastAPI rejects the request if they disagree.
      http.BaseRequest? captured;
      final client = clientWith(
        MockClient((request) async {
          captured = request;
          return http.Response(successBody(), 200);
        }),
      );

      await client.analyze(image);

      expect(captured!.headers['X-User-Id'], 'uid-123');
      expect(captured!.headers['Authorization'], isNotNull);
    });

    test('a rejected session reports the session, not the API key', () async {
      // Both arrive as 401. Telling the user to update a working API key when
      // what expired was their login sends them to fix the wrong thing.
      final client = clientWith(
        MockClient((_) async => http.Response(
            '{"detail":"auth: invalid token"}', 401)),
      );

      await expectLater(
        client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having((e) => e.message, 'message',
            FoodAnalysisClient.errorSessionExpired)),
      );
    });

    test('a rejected provider key still blames the key', () async {
      final client = clientWith(
        MockClient((_) async =>
            http.Response('{"detail":"Gemini API Key missing"}', 401)),
      );

      await expectLater(
        client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having(
            (e) => e.message, 'message', FoodAnalysisClient.errorKeyRejected)),
      );
    });

    test('a service missing its project id says so, not "check your key"',
        () async {
      final client = clientWith(
        MockClient((_) async =>
            http.Response('{"detail":"auth: not configured"}', 503)),
      );

      await expectLater(
        client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having((e) => e.message, 'message',
            FoodAnalysisClient.errorServiceNotReady)),
      );
    });

    test('a failure fetching the token is not called a signed-out user',
        () async {
      // getIdToken() hits the network when the cached token has expired. Offline
      // is not the same as logged out, and the fixes differ.
      var called = false;
      final client = clientWith(
        MockClient((_) async {
          called = true;
          return http.Response(successBody(), 200);
        }),
        caller: () async => throw const SocketException('offline'),
      );

      await expectLater(
        client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having((e) => e.message, 'message',
            FoodAnalysisClient.errorUnreachable)),
      );
      expect(called, isFalse);
    });
  });

  group('configuration', () {
    test('allows 75 seconds by default, outlasting the backend 60s timeout',
        () {
      // openai_compatible.py uses httpx.AsyncClient(timeout=60); a shorter
      // client timeout would abandon a request the backend is still serving.
      expect(FoodAnalysisClient.defaultTimeout, const Duration(seconds: 75));
    });

    test('defaults to a loopback base URL reachable from the emulator or host',
        () {
      expect(
        FoodAnalysisClient.defaultBaseUrl(),
        anyOf('http://10.0.2.2:8080', 'http://localhost:8080'),
      );
    });

    test('strips a trailing slash off an injected base URL', () async {
      http.Request? captured;
      final client = FoodAnalysisClient(
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(successBody(), 200);
        }),
        credentialStore: FakeCredentialStore(
          const [ApiCredentials(provider: 'GEMINI', key: 'k')],
        ),
        baseUrl: 'http://test.local:8080/',
        caller: () async => (uid: 'uid-1', idToken: 't'),
      );

      await client.analyze(image);

      expect(captured!.url.toString(), 'http://test.local:8080/api/v1/gemini');
    });
  });
  group('falling back to another provider', () {
    /// Answers each request by its route, and records the order they arrived.
    MockClient routed(Map<String, http.Response> byPath, List<String> seen) {
      return MockClient((request) async {
        final path = request.url.path.split('/').last;
        seen.add(path);
        return byPath[path] ??
            http.Response(detailBody('provider error: 500'), 502);
      });
    }

    test('tries the next key when the first one is rejected', () async {
      final seen = <String>[];
      final client = clientWith(
        routed({
          'gemini': http.Response(detailBody('invalid key'), 401),
          'openrouter': http.Response(successBody(name: 'Rice Bowl'), 200),
        }, seen),
        chain: const [
          ApiCredentials(provider: 'GEMINI', key: 'g'),
          ApiCredentials(provider: 'OPENROUTER', key: 'or'),
        ],
      );

      final (:name, nutrients: _, quantity: _) = await client.analyze(image);

      // A revoked key should cost a second or two, not a trip to Settings.
      expect(seen, ['gemini', 'openrouter']);
      expect(name, 'Rice Bowl');
    });

    test('tries the next key when the provider itself is failing', () async {
      final seen = <String>[];
      final client = clientWith(
        routed({
          'gemini': http.Response(detailBody('provider error: 500'), 502),
          'openrouter': http.Response(successBody(), 200),
        }, seen),
        chain: const [
          ApiCredentials(provider: 'GEMINI', key: 'g'),
          ApiCredentials(provider: 'OPENROUTER', key: 'or'),
        ],
      );

      await client.analyze(image);

      expect(seen, ['gemini', 'openrouter']);
    });

    test('sends each attempt with that provider\'s own key and route',
        () async {
      final headers = <String, String?>{};
      final client = clientWith(
        MockClient((request) async {
          final path = request.url.path.split('/').last;
          headers[path] = request.headers['X-${path[0].toUpperCase()}'
              '${path.substring(1)}-Key'];
          return path == 'nvidia'
              ? http.Response(successBody(), 200)
              : http.Response(detailBody('invalid key'), 401);
        }),
        chain: const [
          ApiCredentials(provider: 'GEMINI', key: 'g-key'),
          ApiCredentials(provider: 'NVIDIA NIM', key: 'nv-key'),
        ],
      );

      await client.analyze(image);

      // Carrying the first provider's key to the second would guarantee the
      // fallback fails for the same reason the leader did.
      expect(headers, {'gemini': 'g-key', 'nvidia': 'nv-key'});
    });

    test('tries the next key when this provider cannot read the format',
        () async {
      // A HEIC photo is fine for Gemini and refused by OpenRouter.
      final seen = <String>[];
      final client = clientWith(
        routed({
          'openrouter': http.Response(
              detailBody('image: format not supported by this provider'), 415),
          'gemini': http.Response(successBody(name: 'Dal'), 200),
        }, seen),
        chain: const [
          ApiCredentials(provider: 'OPENROUTER', key: 'or'),
          ApiCredentials(provider: 'GEMINI', key: 'g'),
        ],
      );

      final (:name, nutrients: _, quantity: _) = await client.analyze(image);

      expect(seen, ['openrouter', 'gemini']);
      expect(name, 'Dal');
    });

    test('does not spend another scan on a file that is not a photo',
        () async {
      final seen = <String>[];
      final client = clientWith(
        routed({
          'gemini':
              http.Response(detailBody('image: unrecognised format'), 415),
        }, seen),
        chain: const [
          ApiCredentials(provider: 'GEMINI', key: 'g'),
          ApiCredentials(provider: 'OPENROUTER', key: 'or'),
        ],
      );

      await expectLater(
          client.analyze(image), throwsA(isA<FoodAnalysisException>()));
      // The next provider would refuse the same bytes for the same reason.
      expect(seen, ['gemini']);
    });

    test('stops at the first key that works', () async {
      final seen = <String>[];
      final client = clientWith(
        routed({'gemini': http.Response(successBody(), 200)}, seen),
        chain: const [
          ApiCredentials(provider: 'GEMINI', key: 'g'),
          ApiCredentials(provider: 'OPENROUTER', key: 'or'),
        ],
      );

      await client.analyze(image);

      expect(seen, ['gemini']);
    });

    test('does not spend a second scan on a rate limit', () async {
      final seen = <String>[];
      final client = clientWith(
        routed({'gemini': http.Response('', 429)}, seen),
        chain: const [
          ApiCredentials(provider: 'GEMINI', key: 'g'),
          ApiCredentials(provider: 'OPENROUTER', key: 'or'),
        ],
      );

      // nginx counts *this user's* requests, not the provider's, so a second
      // attempt would spend another of the ten and meet the same wall.
      await expectLater(
        () => client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having(
            (e) => e.message, 'message', FoodAnalysisClient.errorRateLimit)),
      );
      expect(seen, ['gemini']);
    });

    test('does not retry elsewhere when the service itself is refusing',
        () async {
      final seen = <String>[];
      final client = clientWith(
        routed({'gemini': http.Response(detailBody('auth: no project'), 503)},
            seen),
        chain: const [
          ApiCredentials(provider: 'GEMINI', key: 'g'),
          ApiCredentials(provider: 'OPENROUTER', key: 'or'),
        ],
      );

      // All three providers sit behind the same backend.
      await expectLater(() => client.analyze(image), throwsA(isA<Exception>()));
      expect(seen, ['gemini']);
    });

    test('does not retry elsewhere when the model could not read the photo',
        () async {
      final seen = <String>[];
      final client = clientWith(
        routed({
          'gemini':
              http.Response(detailBody('invalid response from model'), 502),
        }, seen),
        chain: const [
          ApiCredentials(provider: 'GEMINI', key: 'g'),
          ApiCredentials(provider: 'OPENROUTER', key: 'or'),
        ],
      );

      // The photo is the problem, not the key: falling through would spend
      // three scans to arrive at the same "enter it manually".
      await expectLater(
        () => client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having((e) => e.message, 'message',
            FoodAnalysisClient.errorUnreadablePhoto)),
      );
      expect(seen, ['gemini']);
    });

    test('reports the leading key\'s failure when every key failed', () async {
      final seen = <String>[];
      final client = clientWith(
        routed({
          'gemini': http.Response(detailBody('invalid key'), 401),
          'openrouter': http.Response(detailBody('provider error: 500'), 502),
        }, seen),
        chain: const [
          ApiCredentials(provider: 'GEMINI', key: 'g'),
          ApiCredentials(provider: 'OPENROUTER', key: 'or'),
        ],
      );

      // The leader is the key the user nominated and the one they can act on;
      // a fallback's unrelated complaint would send them to fix the wrong
      // thing.
      await expectLater(
        () => client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having((e) => e.message, 'message',
            FoodAnalysisClient.errorKeyRejected)),
      );
      expect(seen, ['gemini', 'openrouter']);
    });

    test('walks all three when the first two are rejected', () async {
      final seen = <String>[];
      final client = clientWith(
        routed({
          'gemini': http.Response(detailBody('invalid key'), 401),
          'openrouter': http.Response(detailBody('invalid key'), 401),
          'nvidia': http.Response(successBody(), 200),
        }, seen),
        chain: const [
          ApiCredentials(provider: 'GEMINI', key: 'g'),
          ApiCredentials(provider: 'OPENROUTER', key: 'or'),
          ApiCredentials(provider: 'NVIDIA NIM', key: 'nv'),
        ],
      );

      await client.analyze(image);

      expect(seen, ['gemini', 'openrouter', 'nvidia']);
    });

    test('asks for no key at all when none are saved', () async {
      var requests = 0;
      final client = clientWith(
        MockClient((_) async {
          requests++;
          return http.Response(successBody(), 200);
        }),
        chain: const [],
      );

      await expectLater(
        () => client.analyze(image),
        throwsA(isA<FoodAnalysisException>().having(
            (e) => e.message, 'message', FoodAnalysisClient.errorNoKey)),
      );
      expect(requests, 0);
    });
  });
  group('the serving count', () {
    test('returns how many servings the plate held', () async {
      final client = clientWith(MockClient((_) async {
        return http.Response(successBody(calories: 262, quantity: 3), 200);
      }));

      final analysis = await client.analyze(image);

      // Three samosas at 262 each. The nutrients stay per serving; the count
      // is what the form's stepper opens on.
      expect(analysis.quantity, 3);
      expect(analysis.nutrients.calories, 262);
    });

    test('reads one serving when the response carries no count', () async {
      final client = clientWith(MockClient((_) async {
        return http.Response(successBody(), 200);
      }));

      expect((await client.analyze(image)).quantity, 1);
    });

    test('reads one serving for a count that makes no sense', () async {
      // NaN and infinity are excluded deliberately: JSON cannot carry them, so
      // the client can only meet them through `parsing.py`, whose own suite
      // covers that.
      for (final bad in [0, -3, 'lots', '', <int>[3]]) {
        final client = clientWith(MockClient((_) async {
          return http.Response(successBody(quantity: bad), 200);
        }));

        // The nutrients still describe one serving, so a nonsense count costs
        // the multiplier rather than the whole reading.
        expect((await client.analyze(image)).quantity, 1, reason: '$bad');
      }
    });

    test('accepts a count the model sent as a string', () async {
      final client = clientWith(MockClient((_) async {
        return http.Response(successBody(quantity: '4'), 200);
      }));

      expect((await client.analyze(image)).quantity, 4);
    });

    test('snaps a fractional count onto the stepper\'s half steps', () async {
      final client = clientWith(MockClient((_) async {
        return http.Response(successBody(quantity: 2.7), 200);
      }));

      // 2.7 would leave every later tap off the grid — 3.2x, 3.7x — for a
      // figure that was an estimate to begin with.
      expect((await client.analyze(image)).quantity, 2.5);
    });

    test('clamps a count the stepper could never reach', () async {
      final client = clientWith(MockClient((_) async {
        return http.Response(successBody(quantity: 500), 200);
      }));

      expect((await client.analyze(image)).quantity, FoodEntry.maxQuantity);
    });
  });
}
