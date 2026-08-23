import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:void_factor/features/food_log/api_credentials.dart';
import 'package:void_factor/features/food_log/food_analysis_client.dart';
import 'package:void_factor/models/food_entry.dart';

class FakeCredentialStore implements ApiCredentialStore {
  FakeCredentialStore([this.credentials]);

  ApiCredentials? credentials;

  @override
  Future<ApiCredentials?> read() async => credentials;
  @override
  Future<String?> readProvider() async => credentials?.provider;
  @override
  Future<void> write(ApiCredentials c) async => credentials = c;
  @override
  Future<void> delete() async => credentials = null;
}

/// The success body the microservice returns: `normalize()` output.
String successBody({
  String name = 'Grilled Chicken Salad',
  Object? calories = 450,
  Object? proteinG = 42,
  Object? carbsG = 30,
  Object? fatsG = 12,
}) {
  return jsonEncode({
    'name': name,
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
    String? uid = 'uid-123',
    Duration timeout = const Duration(seconds: 5),
  }) {
    return FoodAnalysisClient(
      httpClient: mock,
      credentialStore: FakeCredentialStore(credentials),
      baseUrl: 'http://test.local:8080',
      currentUserId: () => uid,
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

      final (_, nutrients) = await client.analyze(image);

      expect(nutrients.calories, 450);
    });
  });

  group('successful analysis', () {
    test('returns the name and per-serving nutrients', () async {
      final client = clientWith(MockClient((_) async {
        return http.Response(successBody(), 200);
      }));

      final (name, nutrients) = await client.analyze(image);

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

      final (_, nutrients) = await client.analyze(image);

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

      final (name, nutrients) = await client.analyze(image);

      expect(name, '');
      expect(nutrients.calories, 450);
    });

    test('trims whitespace off the returned name', () async {
      final client = clientWith(MockClient((_) async {
        return http.Response(successBody(name: '  Oatmeal  '), 200);
      }));

      final (name, _) = await client.analyze(image);

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
      // nginx returns a bare 400 for an empty X-User-Id, which would surface as
      // a confusing provider error.
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
          const ApiCredentials(provider: 'GEMINI', key: 'k'),
        ),
        baseUrl: 'http://test.local:8080/',
        currentUserId: () => 'uid-1',
      );

      await client.analyze(image);

      expect(captured!.url.toString(), 'http://test.local:8080/api/v1/gemini');
    });
  });
}
