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

  group('journal', () {
    List<String> names() =>
        dir.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

    Future<FoodLogStore> seeded(List<FoodEntry> entries) async {
      final store = FoodLogStore(dir: dir, uid: 'uid-1');
      await store.writeAll(entries);
      await store.readAll();
      return store;
    }

    test('logging one meal appends a line instead of rewriting the log',
        () async {
      final store = await seeded([entry('Old')]);
      final before = store.file.readAsStringSync();
      final current = await store.readAll();

      await store.writeAll([entry('New'), ...current]);

      // The snapshot is untouched: the meal went into the journal.
      expect(store.file.readAsStringSync(), before);
      expect(names().where((n) => n.endsWith('.journal')), hasLength(1));
      expect(
        (await FoodLogStore(dir: dir, uid: 'uid-1').readAll()).map((e) => e.name),
        ['New', 'Old'],
      );
    });

    test('replays an edit and a delete in place, in order', () async {
      final a = entry('A');
      final b = entry('B');
      final c = entry('C');
      final store = await seeded([a, b, c]);
      final current = await store.readAll();

      final edited = current[1].copyWith(name: 'B edited');
      final afterEdit = [current[0], edited, current[2]];
      await store.writeAll(afterEdit);
      await store.writeAll([afterEdit[0], afterEdit[1]]);

      expect(
        (await FoodLogStore(dir: dir, uid: 'uid-1').readAll()).map((e) => e.name),
        ['A', 'B edited'],
      );
    });

    test('a line torn by a crash mid-append costs only that line', () async {
      final store = await seeded([entry('Kept')]);
      final current = await store.readAll();
      await store.writeAll([entry('Also kept'), ...current]);
      final journal = dir
          .listSync()
          .whereType<File>()
          .singleWhere((f) => f.path.endsWith('.journal'));
      journal.writeAsStringSync('{"op":"insert","at":0,"ent', mode: FileMode.append);

      expect(
        (await FoodLogStore(dir: dir, uid: 'uid-1').readAll()).map((e) => e.name),
        ['Also kept', 'Kept'],
      );
    });

    test('folds the journal into a new snapshot before it grows unbounded',
        () async {
      final store = await seeded(const []);
      var current = await store.readAll();
      // One past the limit: the last write must land as a snapshot.
      for (var i = 0; i <= FoodLogStore.maxJournalOps; i++) {
        current = [entry('Meal $i'), ...current];
        await store.writeAll(current);
      }

      expect(names().where((n) => n.endsWith('.journal')), isEmpty);
      final reread = await FoodLogStore(dir: dir, uid: 'uid-1').readAll();
      expect(reread, hasLength(FoodLogStore.maxJournalOps + 1));
      expect(reread.first.name, 'Meal ${FoodLogStore.maxJournalOps}');
    });

    test('ignores and removes a journal no snapshot names', () async {
      // What a crash between a new snapshot and deleting the old journal
      // leaves: its changes are already in the snapshot, and must not be
      // applied a second time.
      final store = await seeded([entry('Only once')]);
      final current = await store.readAll();
      File('${dir.path}/food_logs_uid-1.0.journal').writeAsStringSync(
        '${jsonEncode({'op': 'insert', 'at': 0, 'entry': current.first.toMap()})}\n'
        '${jsonEncode({'op': 'insert', 'at': 0, 'entry': entry('Ghost').toMap()})}\n',
      );

      expect((await store.readAll()).map((e) => e.name), ['Only once']);
      expect(names(), ['food_logs_uid-1.json']);
    });

    test('a failed append is reported, and the log is as it was', () async {
      final store = await seeded([entry('Before')]);
      final current = await store.readAll();
      // A directory where the journal goes: the append cannot happen.
      Directory('${dir.path}/food_logs_uid-1.1.journal').createSync();

      await expectLater(
        store.writeAll([entry('Lost'), ...current]),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        (await FoodLogStore(dir: dir, uid: 'uid-1').readAll()).map((e) => e.name),
        ['Before'],
      );
    });

    test('delete removes the journal along with the log', () async {
      final store = await seeded([entry('Toast')]);
      final current = await store.readAll();
      await store.writeAll([entry('Jam'), ...current]);

      await store.delete();

      expect(dir.listSync(), isEmpty);
    });

    test('reads a log too large for the UI isolate off it, unchanged',
        () async {
      final big = [
        for (var i = 0; i < 3000; i++) entry('Meal $i with a longer name'),
      ];
      final store = FoodLogStore(dir: dir, uid: 'uid-1');
      await store.writeAll(big);
      expect(store.file.lengthSync(), greaterThan(FoodLogStore.backgroundParseBytes));

      final reread = await FoodLogStore(dir: dir, uid: 'uid-1').readAll();

      expect(reread, hasLength(3000));
      expect(reread.first.name, 'Meal 0 with a longer name');
      expect(reread.last.id, big.last.id);
    });
  });
}
