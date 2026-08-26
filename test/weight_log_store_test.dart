import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/weight_log/weight_log_store.dart';
import 'package:void_factor/models/weight_entry.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('weight_log_store_test');
  });

  tearDown(() async {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  WeightEntry entry(double kg, {DateTime? at}) {
    return WeightEntry.create(
      weightKg: kg,
      recordedAt: at ?? DateTime(2026, 8, 26, 7, 30),
    );
  }

  group('file naming', () {
    test('namespaces the file by uid', () {
      final store = WeightLogStore(dir: dir, uid: 'uid-abc');

      expect(store.file.path, '${dir.path}/weight_logs_uid-abc.json');
    });

    test('two users on one device never share a file', () {
      final first = WeightLogStore(dir: dir, uid: 'uid-1');
      final second = WeightLogStore(dir: dir, uid: 'uid-2');

      expect(first.file.path, isNot(second.file.path));
    });
  });

  group('readAll', () {
    test('returns an empty list when no file exists yet', () async {
      final store = WeightLogStore(dir: dir, uid: 'fresh-user');

      expect(await store.readAll(), isEmpty);
    });

    test('round-trips what writeAll wrote', () async {
      final store = WeightLogStore(dir: dir, uid: 'uid-1');
      final written = [entry(82.4), entry(81.9)];

      await store.writeAll(written);
      final read = await store.readAll();

      expect(read.map((e) => e.weightKg), [82.4, 81.9]);
      expect(read.first.id, written.first.id);
      expect(read.first.recordedAt, written.first.recordedAt);
    });

    test('preserves the order it was given', () async {
      final store = WeightLogStore(dir: dir, uid: 'uid-1');

      await store.writeAll([entry(80), entry(81), entry(82)]);

      expect((await store.readAll()).map((e) => e.weightKg), [80, 81, 82]);
    });

    test('reads back nothing after an empty write', () async {
      final store = WeightLogStore(dir: dir, uid: 'uid-1');

      await store.writeAll([entry(80)]);
      await store.writeAll([]);

      expect(await store.readAll(), isEmpty);
    });

    test('a user reads only their own file', () async {
      await WeightLogStore(dir: dir, uid: 'uid-1').writeAll([entry(80)]);

      final other = WeightLogStore(dir: dir, uid: 'uid-2');

      expect(await other.readAll(), isEmpty);
    });
  });

  group('a file it cannot use', () {
    // Failing to open the screen is worse than showing nothing: the file is the
    // only copy, so there is no repair path the user could take from an error.

    test('returns empty for malformed JSON', () async {
      final store = WeightLogStore(dir: dir, uid: 'uid-1');
      await store.file.writeAsString('{not json');

      expect(await store.readAll(), isEmpty);
    });

    test('returns empty when the envelope is a bare array', () async {
      final store = WeightLogStore(dir: dir, uid: 'uid-1');
      await store.file.writeAsString(jsonEncode([{'weightKg': 80}]));

      expect(await store.readAll(), isEmpty);
    });

    test('returns empty when entries is not a list', () async {
      final store = WeightLogStore(dir: dir, uid: 'uid-1');
      await store.file
          .writeAsString(jsonEncode({'schemaVersion': 1, 'entries': 'nope'}));

      expect(await store.readAll(), isEmpty);
    });

    test('skips one unplottable entry and keeps the rest', () async {
      final store = WeightLogStore(dir: dir, uid: 'uid-1');
      await store.file.writeAsString(jsonEncode({
        'schemaVersion': 1,
        'entries': [
          {'id': 'a', 'weightKg': 80.0, 'recordedAt': '2026-08-24T07:00:00.000'},
          // No timestamp: nothing to plot it against.
          {'id': 'b', 'weightKg': 81.0},
          // Zero weight: would bend the regression through a false point.
          {'id': 'c', 'weightKg': 0, 'recordedAt': '2026-08-25T07:00:00.000'},
          {'id': 'd', 'weightKg': 82.0, 'recordedAt': '2026-08-26T07:00:00.000'},
        ],
      }));

      final read = await store.readAll();

      expect(read.map((e) => e.id), ['a', 'd']);
    });

    test('skips a non-map row', () async {
      final store = WeightLogStore(dir: dir, uid: 'uid-1');
      await store.file.writeAsString(jsonEncode({
        'schemaVersion': 1,
        'entries': [
          'garbage',
          {'id': 'a', 'weightKg': 80.0, 'recordedAt': '2026-08-26T07:00:00.000'},
        ],
      }));

      expect((await store.readAll()).map((e) => e.id), ['a']);
    });
  });

  group('writeAll', () {
    test('creates the directory if it is missing', () async {
      final missing = Directory('${dir.path}/not-yet');
      final store = WeightLogStore(dir: missing, uid: 'uid-1');

      await store.writeAll([entry(80)]);

      expect(await store.readAll(), hasLength(1));
    });

    test('leaves no temp file behind', () async {
      final store = WeightLogStore(dir: dir, uid: 'uid-1');

      await store.writeAll([entry(80)]);

      expect(File('${store.file.path}.tmp').existsSync(), isFalse);
    });

    test('replaces rather than appends', () async {
      final store = WeightLogStore(dir: dir, uid: 'uid-1');

      await store.writeAll([entry(80), entry(81)]);
      await store.writeAll([entry(75)]);

      expect((await store.readAll()).map((e) => e.weightKg), [75]);
    });

    test('writes the envelope schema version', () async {
      final store = WeightLogStore(dir: dir, uid: 'uid-1');

      await store.writeAll([entry(80)]);
      final decoded =
          jsonDecode(await store.file.readAsString()) as Map<String, dynamic>;

      expect(decoded['schemaVersion'], WeightLogStore.currentSchemaVersion);
    });
  });

  group('delete', () {
    test('removes the file', () async {
      final store = WeightLogStore(dir: dir, uid: 'uid-1');
      await store.writeAll([entry(80)]);

      await store.delete();

      expect(store.file.existsSync(), isFalse);
      expect(await store.readAll(), isEmpty);
    });

    test('removes a stale temp file too', () async {
      final store = WeightLogStore(dir: dir, uid: 'uid-1');
      final temp = File('${store.file.path}.tmp');
      await store.writeAll([entry(80)]);
      // A crash mid-write would leave one holding the same measurements the
      // user asked to erase.
      await temp.writeAsString('{"entries":[]}');

      await store.delete();

      expect(temp.existsSync(), isFalse);
    });

    test('is a no-op when nothing was ever written', () async {
      final store = WeightLogStore(dir: dir, uid: 'never-logged');

      await expectLater(store.delete(), completes);
    });

    test('leaves another user file untouched', () async {
      final mine = WeightLogStore(dir: dir, uid: 'uid-1');
      final theirs = WeightLogStore(dir: dir, uid: 'uid-2');
      await mine.writeAll([entry(80)]);
      await theirs.writeAll([entry(90)]);

      await mine.delete();

      expect(await theirs.readAll(), hasLength(1));
    });
  });
}
