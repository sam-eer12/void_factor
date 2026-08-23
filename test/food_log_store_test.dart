import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/food_log/food_log_store.dart';
import 'package:void_factor/models/food_entry.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('food_log_store_test');
  });

  tearDown(() async {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  FoodEntry entry(String name, {double calories = 100, DateTime? at}) {
    return FoodEntry.create(
      name: name,
      nutrients: Nutrients(calories: calories, proteinG: 10),
      quantity: 1.0,
      source: FoodSource.manual,
      loggedAt: at ?? DateTime(2026, 8, 22, 12, 0),
    );
  }

  group('file naming', () {
    test('namespaces the file by uid', () {
      final store = FoodLogStore(dir: dir, uid: 'uid-abc');

      expect(store.file.path, '${dir.path}/food_logs_uid-abc.json');
    });
  });

  group('readAll', () {
    test('returns an empty list when no file exists yet', () async {
      final store = FoodLogStore(dir: dir, uid: 'fresh-user');

      expect(await store.readAll(), isEmpty);
    });

    test('round-trips what writeAll wrote', () async {
      final store = FoodLogStore(dir: dir, uid: 'uid-1');
      final written = [entry('Oatmeal', calories: 300), entry('Eggs')];

      await store.writeAll(written);
      final read = await store.readAll();

      expect(read.map((e) => e.name), ['Oatmeal', 'Eggs']);
      expect(read.first.nutrients.calories, 300);
      expect(read.first.id, written.first.id);
    });

    test('preserves the order it was given', () async {
      final store = FoodLogStore(dir: dir, uid: 'uid-1');

      await store.writeAll([entry('A'), entry('B'), entry('C')]);

      expect((await store.readAll()).map((e) => e.name), ['A', 'B', 'C']);
    });

    test('returns an empty list rather than throwing on a corrupt file',
        () async {
      final store = FoodLogStore(dir: dir, uid: 'uid-1');
      store.file.writeAsStringSync('this is not json {{{');

      // The log is a convenience, not a ledger. Failing to launch over a
      // corrupt file would be worse than starting empty.
      expect(await store.readAll(), isEmpty);
    });

    test('returns an empty list when the root is not the expected shape',
        () async {
      final store = FoodLogStore(dir: dir, uid: 'uid-1');
      store.file.writeAsStringSync(jsonEncode([1, 2, 3]));

      expect(await store.readAll(), isEmpty);
    });

    test('returns an empty list when entries is not a list', () async {
      final store = FoodLogStore(dir: dir, uid: 'uid-1');
      store.file
          .writeAsStringSync(jsonEncode({'schemaVersion': 1, 'entries': 'nope'}));

      expect(await store.readAll(), isEmpty);
    });

    test('skips one malformed entry and keeps the rest', () async {
      final store = FoodLogStore(dir: dir, uid: 'uid-1');
      store.file.writeAsStringSync(jsonEncode({
        'schemaVersion': 1,
        'entries': [
          entry('Good One').toMap(),
          // No loggedAt: unrenderable, there is no day to group it under.
          {'id': 'x', 'name': 'Broken'},
          entry('Good Two').toMap(),
        ],
      }));

      final read = await store.readAll();

      // One bad row costs one row, not the whole log.
      expect(read.map((e) => e.name), ['Good One', 'Good Two']);
    });

    test('skips a non-map element without throwing', () async {
      final store = FoodLogStore(dir: dir, uid: 'uid-1');
      store.file.writeAsStringSync(jsonEncode({
        'schemaVersion': 1,
        'entries': [entry('Good').toMap(), 'garbage', 42],
      }));

      expect((await store.readAll()).map((e) => e.name), ['Good']);
    });
  });

  group('writeAll', () {
    test('writes the versioned envelope, not a bare list', () async {
      final store = FoodLogStore(dir: dir, uid: 'uid-1');

      await store.writeAll([entry('Toast')]);

      final decoded = jsonDecode(store.file.readAsStringSync());
      expect(decoded, isA<Map>());
      expect(decoded['schemaVersion'], FoodLogStore.currentSchemaVersion);
      expect(decoded['entries'], isA<List>());
      expect(decoded['entries'].length, 1);
    });

    test('replaces the previous contents rather than appending', () async {
      final store = FoodLogStore(dir: dir, uid: 'uid-1');

      await store.writeAll([entry('First'), entry('Second')]);
      await store.writeAll([entry('Only')]);

      expect((await store.readAll()).map((e) => e.name), ['Only']);
    });

    test('writes an empty list without error', () async {
      final store = FoodLogStore(dir: dir, uid: 'uid-1');

      await store.writeAll([entry('Toast')]);
      await store.writeAll([]);

      expect(await store.readAll(), isEmpty);
      expect(store.file.existsSync(), isTrue);
    });

    test('leaves no temp file behind after a successful write', () async {
      final store = FoodLogStore(dir: dir, uid: 'uid-1');

      await store.writeAll([entry('Toast')]);

      // The write goes to a temp file and is renamed into place; a leftover
      // .tmp would mean the rename never happened.
      final names = dir.listSync().map((e) => e.path.split('/').last).toList();
      expect(names, ['food_logs_uid-1.json']);
    });

    test('creates the directory when it does not exist yet', () async {
      final nested = Directory('${dir.path}/nested/deeper');
      final store = FoodLogStore(dir: nested, uid: 'uid-1');

      await store.writeAll([entry('Toast')]);

      expect((await store.readAll()).map((e) => e.name), ['Toast']);
    });

    test('a torn write leaves the previous good file readable', () async {
      final store = FoodLogStore(dir: dir, uid: 'uid-1');
      await store.writeAll([entry('Committed')]);

      // Simulate a crash mid-write: a stale temp file exists, but the real file
      // was never replaced.
      File('${store.file.path}.tmp').writeAsStringSync('half-written {{{');

      expect((await store.readAll()).map((e) => e.name), ['Committed']);
    });
  });

  group('per-uid isolation', () {
    test('two users do not see each other\'s entries', () async {
      final alice = FoodLogStore(dir: dir, uid: 'alice');
      final bob = FoodLogStore(dir: dir, uid: 'bob');

      await alice.writeAll([entry('Alice Salad')]);
      await bob.writeAll([entry('Bob Burger')]);

      expect((await alice.readAll()).map((e) => e.name), ['Alice Salad']);
      expect((await bob.readAll()).map((e) => e.name), ['Bob Burger']);
    });

    test('a second user on the same device starts with an empty log', () async {
      await FoodLogStore(dir: dir, uid: 'alice').writeAll([entry('Alice Only')]);

      // This is what makes keeping logs through logout safe: the next user
      // reads a different file, not a filtered view of one shared file.
      expect(await FoodLogStore(dir: dir, uid: 'bob').readAll(), isEmpty);
    });
  });

  group('delete', () {
    test('removes the calling user\'s file', () async {
      final store = FoodLogStore(dir: dir, uid: 'uid-1');
      await store.writeAll([entry('Toast')]);

      await store.delete();

      expect(store.file.existsSync(), isFalse);
      expect(await store.readAll(), isEmpty);
    });

    test('leaves another user\'s file untouched', () async {
      final alice = FoodLogStore(dir: dir, uid: 'alice');
      final bob = FoodLogStore(dir: dir, uid: 'bob');
      await alice.writeAll([entry('Alice Salad')]);
      await bob.writeAll([entry('Bob Burger')]);

      // Account deletion must not take a co-user's data with it.
      await alice.delete();

      expect((await bob.readAll()).map((e) => e.name), ['Bob Burger']);
    });

    test('is a no-op when no file exists', () async {
      final store = FoodLogStore(dir: dir, uid: 'never-logged');

      await store.delete();

      expect(store.file.existsSync(), isFalse);
    });

    test('also removes a stale temp file', () async {
      final store = FoodLogStore(dir: dir, uid: 'uid-1');
      await store.writeAll([entry('Toast')]);
      File('${store.file.path}.tmp').writeAsStringSync('half-written');

      await store.delete();

      // A leftover temp file holds the same meal names the user asked to erase.
      expect(dir.listSync(), isEmpty);
    });
  });
}
