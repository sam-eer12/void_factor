import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:void_factor/features/food_log/api_credentials.dart';
import 'package:void_factor/features/food_log/food_analysis_client.dart';
import 'package:void_factor/features/food_log/food_log_providers.dart';
import 'package:void_factor/features/food_log/food_log_store.dart';
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

/// Fake picker + compressor. Records what it was asked for and whether the
/// temp file it handed out was cleaned up.
class FakeImageCaptureGateway implements ImageCaptureGateway {
  FakeImageCaptureGateway({this.fileToReturn, this.throwPlatformException = false});

  File? fileToReturn;
  bool throwPlatformException;
  ImageSource? lastSource;
  int callCount = 0;

  @override
  Future<File?> capture(ImageSource source) async {
    callCount++;
    lastSource = source;
    if (throwPlatformException) {
      throw PlatformException(code: 'camera_access_denied');
    }
    return fileToReturn;
  }
}

void main() {
  late Directory dir;
  late FoodLogStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('food_log_providers_test');
    store = FoodLogStore(dir: dir, uid: 'uid-1');
  });

  tearDown(() async {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  FoodEntry entry(String name, {DateTime? at}) {
    return FoodEntry.create(
      name: name,
      nutrients: const Nutrients(calories: 100, proteinG: 10),
      quantity: 1.0,
      source: FoodSource.manual,
      loggedAt: at ?? DateTime(2026, 8, 22, 12, 0),
    );
  }

  ProviderContainer containerWith({
    FoodLogStore? logStore,
    FoodAnalysisClient? client,
    ImageCaptureGateway? gateway,
  }) {
    final container = ProviderContainer(overrides: [
      foodLogStoreProvider.overrideWith((ref) async => logStore ?? store),
      if (client != null) foodAnalysisClientProvider.overrideWithValue(client),
      if (gateway != null)
        imageCaptureGatewayProvider.overrideWithValue(gateway),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  FoodAnalysisClient analysisClientReturning(String body, {int status = 200}) {
    return FoodAnalysisClient(
      httpClient: MockClient((_) async => http.Response(body, status)),
      credentialStore: FakeCredentialStore(
        const ApiCredentials(provider: 'GEMINI', key: 'k'),
      ),
      baseUrl: 'http://test.local:8080',
      currentUserId: () => 'uid-1',
    );
  }

  group('recentFoodLogProvider build', () {
    test('loads what the store already holds', () async {
      await store.writeAll([entry('Oatmeal'), entry('Eggs')]);
      final container = containerWith();

      final entries = await container.read(recentFoodLogProvider.future);

      expect(entries.map((e) => e.name), ['Oatmeal', 'Eggs']);
    });

    test('starts empty for a user with no file', () async {
      final container = containerWith();

      expect(await container.read(recentFoodLogProvider.future), isEmpty);
    });
  });

  group('recentFoodLogProvider add', () {
    test('puts the new entry at the front of the list', () async {
      await store.writeAll([entry('Older')]);
      final container = containerWith();
      await container.read(recentFoodLogProvider.future);

      await container
          .read(recentFoodLogProvider.notifier)
          .add(entry('Just Logged'));

      expect(
        container.read(recentFoodLogProvider).requireValue.map((e) => e.name),
        ['Just Logged', 'Older'],
      );
    });

    test('persists the entry to the store', () async {
      final container = containerWith();
      await container.read(recentFoodLogProvider.future);

      await container.read(recentFoodLogProvider.notifier).add(entry('Toast'));

      // Read through a fresh store: the file, not the in-memory list.
      final reread = await FoodLogStore(dir: dir, uid: 'uid-1').readAll();
      expect(reread.map((e) => e.name), ['Toast']);
    });

    test('persists before committing state, so a failed write does not show as logged',
        () async {
      final container = containerWith();
      await container.read(recentFoodLogProvider.future);

      // Make the real write fail: a directory sits where the log file goes, so
      // rename() cannot replace it. There is no offline queue, so an entry that
      // failed to persist exists nowhere and must not appear as saved.
      Directory('${dir.path}/food_logs_uid-1.json').createSync();

      await expectLater(
        container.read(recentFoodLogProvider.notifier).add(entry('Lost')),
        throwsA(isA<FoodAnalysisException>().having(
          (e) => e.message,
          'message',
          RecentFoodLog.errorSaveFailed,
        )),
      );

      expect(container.read(recentFoodLogProvider).requireValue, isEmpty);
    });

    test('reports the save-failure copy from the design', () {
      expect(RecentFoodLog.errorSaveFailed, "COULDN'T SAVE — TRY AGAIN");
    });

    test('keeps both screens in agreement through one shared provider',
        () async {
      final container = containerWith();
      await container.read(recentFoodLogProvider.future);

      await container.read(recentFoodLogProvider.notifier).add(entry('Shared'));

      // Any second reader of the same provider sees the entry without re-reading
      // the file — this is what makes a save from the form redraw both lists.
      expect(
        container.read(recentFoodLogProvider).requireValue.map((e) => e.name),
        ['Shared'],
      );
    });

    test('survives being called twice in a row', () async {
      final container = containerWith();
      await container.read(recentFoodLogProvider.future);
      final notifier = container.read(recentFoodLogProvider.notifier);

      await notifier.add(entry('First'));
      await notifier.add(entry('Second'));

      expect(
        (await FoodLogStore(dir: dir, uid: 'uid-1').readAll())
            .map((e) => e.name),
        ['Second', 'First'],
      );
    });
  });

  group('visionAnalysisProvider', () {
    File writeTempImage() {
      final file = File('${dir.path}/compressed.jpg')
        ..writeAsBytesSync(const [1, 2, 3]);
      return file;
    }

    test('returns the analysed name and nutrients', () async {
      final gateway = FakeImageCaptureGateway(fileToReturn: writeTempImage());
      final container = containerWith(
        gateway: gateway,
        client: analysisClientReturning(
          '{"name":"Grilled Chicken","nutrients":{"calories":450,"protein_g":42,"carbs_g":30,"fats_g":12}}',
        ),
      );

      final result = await container
          .read(visionAnalysisProvider.notifier)
          .capture(ImageSource.camera);

      expect(result, isNotNull);
      expect(result!.$1, 'Grilled Chicken');
      expect(result.$2.calories, 450);
    });

    test('passes the requested source through to the picker', () async {
      final gateway = FakeImageCaptureGateway(fileToReturn: writeTempImage());
      final container = containerWith(
        gateway: gateway,
        client: analysisClientReturning('{"name":"X","nutrients":{}}'),
      );

      await container
          .read(visionAnalysisProvider.notifier)
          .capture(ImageSource.gallery);

      expect(gateway.lastSource, ImageSource.gallery);
    });

    test('deletes the compressed temp file once analysis is done', () async {
      final temp = writeTempImage();
      final container = containerWith(
        gateway: FakeImageCaptureGateway(fileToReturn: temp),
        client: analysisClientReturning('{"name":"X","nutrients":{}}'),
      );

      await container
          .read(visionAnalysisProvider.notifier)
          .capture(ImageSource.camera);

      expect(temp.existsSync(), isFalse);
    });

    test('deletes the temp file even when analysis fails', () async {
      final temp = writeTempImage();
      final container = containerWith(
        gateway: FakeImageCaptureGateway(fileToReturn: temp),
        client: analysisClientReturning('{"detail":"provider error: 500"}',
            status: 502),
      );

      await expectLater(
        container
            .read(visionAnalysisProvider.notifier)
            .capture(ImageSource.camera),
        throwsA(isA<FoodAnalysisException>()),
      );
      expect(temp.existsSync(), isFalse);
    });

    test('returns null when the user backs out of the picker', () async {
      // A cancelled picker is not an error — the screen shows nothing at all.
      final container = containerWith(
        gateway: FakeImageCaptureGateway(fileToReturn: null),
        client: analysisClientReturning('{"name":"X","nutrients":{}}'),
      );

      final result = await container
          .read(visionAnalysisProvider.notifier)
          .capture(ImageSource.camera);

      expect(result, isNull);
      expect(container.read(visionAnalysisProvider).hasError, isFalse);
    });

    test('does not call the analysis service when the picker was cancelled',
        () async {
      var called = false;
      final container = containerWith(
        gateway: FakeImageCaptureGateway(fileToReturn: null),
        client: FoodAnalysisClient(
          httpClient: MockClient((_) async {
            called = true;
            return http.Response('{}', 200);
          }),
          credentialStore: FakeCredentialStore(
            const ApiCredentials(provider: 'GEMINI', key: 'k'),
          ),
          baseUrl: 'http://test.local:8080',
          currentUserId: () => 'uid-1',
        ),
      );

      await container
          .read(visionAnalysisProvider.notifier)
          .capture(ImageSource.camera);

      expect(called, isFalse);
    });

    test('turns a denied permission into actionable copy', () async {
      final container = containerWith(
        gateway: FakeImageCaptureGateway(throwPlatformException: true),
        client: analysisClientReturning('{"name":"X","nutrients":{}}'),
      );

      await expectLater(
        container
            .read(visionAnalysisProvider.notifier)
            .capture(ImageSource.camera),
        throwsA(isA<FoodAnalysisException>().having(
          (e) => e.message,
          'message',
          VisionAnalysisController.errorPermissionDenied,
        )),
      );
    });

    test('reports the permission copy from the design', () {
      expect(
        VisionAnalysisController.errorPermissionDenied,
        'PERMISSION DENIED — ENABLE IN SETTINGS',
      );
    });

    test('rethrows an analysis failure with its display copy intact', () async {
      final container = containerWith(
        gateway: FakeImageCaptureGateway(fileToReturn: writeTempImage()),
        client: analysisClientReturning(
            '{"error":"rate limit exceeded"}', status: 429),
      );

      await expectLater(
        container
            .read(visionAnalysisProvider.notifier)
            .capture(ImageSource.camera),
        throwsA(isA<FoodAnalysisException>().having(
          (e) => e.message,
          'message',
          FoodAnalysisClient.errorRateLimit,
        )),
      );
    });

    test('exposes the failure as error state for the screen to render',
        () async {
      final container = containerWith(
        gateway: FakeImageCaptureGateway(fileToReturn: writeTempImage()),
        client: analysisClientReturning(
            '{"error":"rate limit exceeded"}', status: 429),
      );

      await container
          .read(visionAnalysisProvider.notifier)
          .capture(ImageSource.camera)
          .catchError((_) => null);

      expect(container.read(visionAnalysisProvider).hasError, isTrue);
    });

    test('starts idle with no result', () async {
      final container = containerWith();

      expect(await container.read(visionAnalysisProvider.future), isNull);
    });
  });
}
