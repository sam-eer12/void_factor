import 'dart:io';

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:void_factor/features/food_log/api_credentials.dart';
import 'package:void_factor/features/food_log/food_analysis_client.dart';
import 'package:void_factor/features/food_log/food_log_providers.dart';
import 'package:void_factor/features/food_log/food_log_store.dart';
import 'package:void_factor/features/food_log/pending_scan.dart';
import 'package:void_factor/features/lifecycle/app_lifecycle.dart';
import 'package:void_factor/models/food_entry.dart';

class FakeCredentialStore implements ApiCredentialStore {
  /// Takes the single credential these tests care about; the store's real
  /// contract is an ordered list, which the client's own suite exercises.
  FakeCredentialStore([ApiCredentials? credentials])
      : credentials = [?credentials];

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
  Future<void> deleteAll() async => credentials = [];
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

  /// What the picker hands back after the app was killed behind it.
  File? lostFile;

  @override
  Future<File?> recoverLost() async {
    final file = lostFile;
    lostFile = null;
    return file;
  }
}

/// A store whose writes can be made to fail.
///
/// Subclassed rather than faked wholesale so the passing paths exercise the real
/// file, which is what makes "persisted before committing" a claim about disk
/// rather than about a list in memory.
class FailingFoodLogStore extends FoodLogStore {
  FailingFoodLogStore({required super.dir, required super.uid});

  bool failWrites = false;

  @override
  Future<void> writeAll(List<FoodEntry> entries) async {
    if (failWrites) {
      throw const FileSystemException('no space left on device');
    }
    return super.writeAll(entries);
  }
}

void main() {
  late Directory dir;
  late FailingFoodLogStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('food_log_providers_test');
    store = FailingFoodLogStore(dir: dir, uid: 'uid-1');
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
      caller: () async => (uid: 'uid-1', idToken: 't'),
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
      expect(result!.name, 'Grilled Chicken');
      expect(result.nutrients.calories, 450);
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
          caller: () async => (uid: 'uid-1', idToken: 't'),
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

  group('replace', () {
    test('swaps the entry in place, keeping its position', () async {
      // An edit that moved a meal to the top of the list would read as a second
      // meal having been logged.
      await store.writeAll([entry('Newest'), entry('Target'), entry('Oldest')]);
      final container = containerWith();
      final log = container.read(recentFoodLogProvider.notifier);
      final before = await container.read(recentFoodLogProvider.future);

      await log.replace(before[1].copyWith(name: 'Corrected'));

      final after = await container.read(recentFoodLogProvider.future);
      expect(after.map((e) => e.name), ['Newest', 'Corrected', 'Oldest']);
    });

    test('reaches disk, not just memory', () async {
      await store.writeAll([entry('Before')]);
      final container = containerWith();
      final existing = (await container.read(recentFoodLogProvider.future)).single;

      await container
          .read(recentFoodLogProvider.notifier)
          .replace(existing.copyWith(name: 'After'));

      expect((await store.readAll()).single.name, 'After');
    });

    test('ignores an entry that is no longer in the log', () async {
      // A stale screen editing something deleted elsewhere. Writing it back
      // would resurrect a row the user deleted.
      await store.writeAll([entry('Kept')]);
      final container = containerWith();

      await container
          .read(recentFoodLogProvider.notifier)
          .replace(entry('Ghost'));

      expect((await container.read(recentFoodLogProvider.future)).length, 1);
    });

    test('a failed write leaves the old entry standing', () async {
      await store.writeAll([entry('Original')]);
      final container = containerWith();
      final existing = (await container.read(recentFoodLogProvider.future)).single;
      store.failWrites = true;

      await expectLater(
        container
            .read(recentFoodLogProvider.notifier)
            .replace(existing.copyWith(name: 'Never saved')),
        throwsA(isA<FoodAnalysisException>()),
      );

      store.failWrites = false;
      expect((await store.readAll()).single.name, 'Original');
    });
  });

  group('remove', () {
    test('drops the entry and reports where it was', () async {
      await store.writeAll([entry('A'), entry('B'), entry('C')]);
      final container = containerWith();
      final entries = await container.read(recentFoodLogProvider.future);

      final index = await container
          .read(recentFoodLogProvider.notifier)
          .remove(entries[1].id);

      expect(index, 1);
      expect(
        (await container.read(recentFoodLogProvider.future)).map((e) => e.name),
        ['A', 'C'],
      );
    });

    test('reports -1 for an id that is already gone', () async {
      final container = containerWith();
      expect(
        await container.read(recentFoodLogProvider.notifier).remove('nope'),
        -1,
      );
    });

    test('reaches disk', () async {
      await store.writeAll([entry('Doomed')]);
      final container = containerWith();
      final logged = (await container.read(recentFoodLogProvider.future)).single;

      await container.read(recentFoodLogProvider.notifier).remove(logged.id);

      expect(await store.readAll(), isEmpty);
    });
  });

  group('insertAt', () {
    test('puts an undone delete back where it came from', () async {
      await store.writeAll([entry('A'), entry('B'), entry('C')]);
      final container = containerWith();
      final log = container.read(recentFoodLogProvider.notifier);
      final removed = (await container.read(recentFoodLogProvider.future))[1];

      final index = await log.remove(removed.id);
      await log.insertAt(removed, index);

      expect(
        (await container.read(recentFoodLogProvider.future)).map((e) => e.name),
        ['A', 'B', 'C'],
      );
    });

    test('refuses to create a duplicate', () async {
      // Two taps on one UNDO, or an undo after the entry came back some other
      // way.
      await store.writeAll([entry('A')]);
      final container = containerWith();
      final logged = (await container.read(recentFoodLogProvider.future)).single;

      await container.read(recentFoodLogProvider.notifier).insertAt(logged, 0);

      expect((await container.read(recentFoodLogProvider.future)).length, 1);
    });

    test('clamps a stale index rather than throwing', () async {
      // Between the delete and the undo the user may have removed other rows,
      // leaving the recorded index past the end of a now-shorter list.
      final container = containerWith();

      await container
          .read(recentFoodLogProvider.notifier)
          .insertAt(entry('Restored'), 99);

      expect(
        (await container.read(recentFoodLogProvider.future)).single.name,
        'Restored',
      );
    });
  });

  group('a scan the app was killed or backgrounded through', () {
    late Directory keep;
    late PendingScanStore pending;

    setUp(() {
      keep = Directory('${dir.path}/support')..createSync();
      pending = PendingScanStore(directory: () async => keep);
    });

    const success =
        '{"name":"Dal","nutrients":{"calories":300,"protein_g":12,"carbs_g":40,"fats_g":8}}';

    File photo([String name = 'vf_meal_1.jpg']) =>
        File('${dir.path}/$name')..writeAsBytesSync(const [1, 2, 3]);

    /// A process: its own container over the same disk, as a relaunch is.
    ProviderContainer process({
      required http.Client http,
      FakeImageCaptureGateway? gateway,
    }) {
      final container = ProviderContainer(overrides: [
        foodLogStoreProvider.overrideWith((ref) async => store),
        pendingScanStoreProvider.overrideWithValue(pending),
        imageCaptureGatewayProvider
            .overrideWithValue(gateway ?? FakeImageCaptureGateway()),
        foodAnalysisClientProvider.overrideWithValue(FoodAnalysisClient(
          httpClient: http,
          credentialStore: FakeCredentialStore(
            const ApiCredentials(provider: 'GEMINI', key: 'k'),
          ),
          baseUrl: 'http://test.local:8080',
          caller: () async => (uid: 'uid-1', idToken: 't'),
        )),
      ]);
      addTearDown(container.dispose);
      return container;
    }

    MockClient answering(String body) =>
        MockClient((_) async => http.Response(body, 200));

    test('holds the photo on disk until the analysis answers', () async {
      final answer = Completer<http.Response>();
      final container = process(
        http: MockClient((_) => answer.future),
        gateway: FakeImageCaptureGateway(fileToReturn: photo()),
      );

      final scan = container
          .read(visionAnalysisProvider.notifier)
          .capture(ImageSource.camera);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Mid-upload: this is what a killed process leaves for the next one.
      expect(await pending.find(owner: 'uid-1'), isNotNull);

      answer.complete(http.Response(success, 200));
      await scan;
      expect(await pending.find(owner: 'uid-1'), isNull);
      expect(keep.listSync(recursive: true).whereType<File>(), isEmpty);
    });

    test('the next process finishes a scan the last one was killed during',
        () async {
      // What capture() leaves on disk before its upload returns.
      await pending.hold(photo(), owner: 'uid-1');

      final container = process(http: answering(success));
      final vision = container.read(visionAnalysisProvider.notifier);

      expect(await vision.hasPendingScan(), isTrue);
      final draft = await vision.resumePending();

      expect(draft!.name, 'Dal');
      expect(draft.nutrients.calories, 300);
      expect(container.read(visionAnalysisProvider).value?.name, 'Dal');
      expect(await pending.find(owner: 'uid-1'), isNull);
    });

    test('recovers a photo the camera delivered to a killed app', () async {
      final gateway = FakeImageCaptureGateway()..lostFile = photo();
      final container = process(http: answering(success), gateway: gateway);
      final vision = container.read(visionAnalysisProvider.notifier);

      expect(await vision.hasPendingScan(), isTrue);
      expect((await vision.resumePending())!.name, 'Dal');
    });

    test("never finishes another account's scan", () async {
      await pending.hold(photo(), owner: 'someone-else');
      var requests = 0;
      final container = process(
        http: MockClient((_) async {
          requests++;
          return http.Response(success, 200);
        }),
      );

      expect(
        await container.read(visionAnalysisProvider.notifier).hasPendingScan(),
        isFalse,
      );
      expect(requests, 0);
    });

    test('has nothing to resume while a scan is already running', () async {
      await pending.hold(photo(), owner: 'uid-1');
      final answer = Completer<http.Response>();
      final container = process(http: MockClient((_) => answer.future));
      final vision = container.read(visionAnalysisProvider.notifier);

      final first = vision.resumePending();
      // A second shell asking in the same frame must not start it twice.
      expect(await vision.resumePending(), isNull);
      expect(await vision.hasPendingScan(), isFalse);

      answer.complete(http.Response(success, 200));
      expect((await first)!.name, 'Dal');
    });

    test('a scan cut off by leaving the app is retried on return, not failed',
        () async {
      var requests = 0;
      late ProviderContainer container;
      container = process(
        gateway: FakeImageCaptureGateway(fileToReturn: photo()),
        http: MockClient((_) async {
          requests++;
          if (requests == 1) {
            // The user switched away, and Android froze the app mid-request.
            container
                .read(appLifecycleProvider.notifier)
                .report(AppLifecycleState.paused);
            throw const SocketException('frozen');
          }
          return http.Response(success, 200);
        }),
      );

      final scan = container
          .read(visionAnalysisProvider.notifier)
          .capture(ImageSource.camera);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Still reading the plate, waiting for the user rather than failing.
      expect(container.read(visionAnalysisProvider).isLoading, isTrue);
      expect(requests, 1);

      container
          .read(appLifecycleProvider.notifier)
          .report(AppLifecycleState.resumed);
      expect((await scan)!.name, 'Dal');
      expect(requests, 2);
    });

    test('a failure while the user stayed in the app is shown at once',
        () async {
      var requests = 0;
      final container = process(
        gateway: FakeImageCaptureGateway(fileToReturn: photo()),
        http: MockClient((_) async {
          requests++;
          throw const SocketException('offline');
        }),
      );

      await expectLater(
        container
            .read(visionAnalysisProvider.notifier)
            .capture(ImageSource.camera),
        throwsA(isA<FoodAnalysisException>().having(
          (e) => e.message,
          'message',
          FoodAnalysisClient.errorUnreachable,
        )),
      );
      expect(requests, 1);
      // Shown, so nothing is left to resume on the next launch.
      expect(await pending.find(owner: 'uid-1'), isNull);
    });
  });
}
