import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/food_log/pending_scan.dart';

void main() {
  late Directory dir;
  late DateTime now;
  late PendingScanStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pending_scan_test');
    now = DateTime(2026, 9, 24, 12, 0);
    store = PendingScanStore(directory: () async => dir, clock: () => now);
  });

  tearDown(() async {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File photo([String name = 'vf_meal_1.jpg']) =>
      File('${dir.path}/$name')..writeAsBytesSync(const [1, 2, 3]);

  group('hold', () {
    test('moves the photo into the store, leaving no second copy', () async {
      final original = photo();

      final kept = await store.hold(original, owner: 'uid-1');

      expect(kept.existsSync(), isTrue);
      expect(kept.readAsBytesSync(), [1, 2, 3]);
      expect(original.existsSync(), isFalse);
    });

    test('hands back the photo itself when there is nowhere to keep it',
        () async {
      final unavailable = PendingScanStore(
        directory: () async => throw const FileSystemException('no storage'),
      );
      final original = photo();

      expect((await unavailable.hold(original, owner: 'uid-1')).path,
          original.path);
      expect(await unavailable.find(owner: 'uid-1'), isNull);
    });
  });

  group('find', () {
    test('returns the scan held for the same account', () async {
      await store.hold(photo(), owner: 'uid-1');

      final pending = await store.find(owner: 'uid-1');

      expect(pending, isNotNull);
      expect(pending!.image.readAsBytesSync(), [1, 2, 3]);
      expect(pending.startedAt, now);
    });

    test("never returns, and removes, another account's photo", () async {
      final kept = await store.hold(photo(), owner: 'someone-else');

      expect(await store.find(owner: 'uid-1'), isNull);
      expect(kept.existsSync(), isFalse);
    });

    test('drops a scan older than it will resume', () async {
      final kept = await store.hold(photo(), owner: 'uid-1');
      now = now.add(store.maxAge + const Duration(minutes: 1));

      expect(await store.find(owner: 'uid-1'), isNull);
      expect(kept.existsSync(), isFalse);
    });

    test('drops a scan dated in the future by a clock that has since moved',
        () async {
      await store.hold(photo(), owner: 'uid-1');
      now = now.subtract(const Duration(hours: 2));

      expect(await store.find(owner: 'uid-1'), isNull);
    });

    test('drops a marker whose photo is gone', () async {
      final kept = await store.hold(photo(), owner: 'uid-1');
      kept.deleteSync();

      expect(await store.find(owner: 'uid-1'), isNull);
      expect(Directory('${dir.path}/pending_scan').listSync(), isEmpty);
    });

    test('drops a marker that will not parse', () async {
      await store.hold(photo(), owner: 'uid-1');
      File('${dir.path}/pending_scan/scan.json').writeAsStringSync('{{{');

      expect(await store.find(owner: 'uid-1'), isNull);
      expect(Directory('${dir.path}/pending_scan').listSync(), isEmpty);
    });

    test('finds nothing when nothing was held', () async {
      expect(await store.find(owner: 'uid-1'), isNull);
    });
  });

  test('clear removes the photo and its marker', () async {
    await store.hold(photo(), owner: 'uid-1');

    await store.clear();

    expect(Directory('${dir.path}/pending_scan').listSync(), isEmpty);
  });

  group('sweepStrayTempImages', () {
    test('deletes old compressed photos and nothing else', () async {
      final old = photo('vf_meal_old.jpg')
        ..setLastModifiedSync(now.subtract(const Duration(hours: 1)));
      final fresh = photo('vf_meal_fresh.jpg')..setLastModifiedSync(now);
      final unrelated = photo('holiday.jpg')
        ..setLastModifiedSync(now.subtract(const Duration(days: 1)));

      await PendingScanStore.sweepStrayTempImages(temp: dir, clock: () => now);

      expect(old.existsSync(), isFalse);
      // A scan being compressed right now is not a stray.
      expect(fresh.existsSync(), isTrue);
      expect(unrelated.existsSync(), isTrue);
    });
  });
}
