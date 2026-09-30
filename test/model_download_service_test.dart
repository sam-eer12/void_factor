import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/projection/model_artifact.dart';
import 'package:void_factor/features/projection/model_download_link.dart';
import 'package:void_factor/features/projection/model_download_service.dart';

const fixture = ModelArtifact(
  version: 'gemma-fixture-v1',
  filename: 'fixture.litertlm',
  sourceRepository: 'test/model',
  sourceRevision: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  sizeBytes: 3,
  sha256: 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  termsVersion: '2026-04-01',
);

class _Queue implements ModelTransferQueue {
  final controller = StreamController<TaskUpdate>.broadcast();
  TaskRecord? currentRecord;
  Task? active;
  DownloadTask? lastTask;
  int enqueues = 0;
  int resumes = 0;
  int cancels = 0;
  int forgets = 0;
  Future<void> Function(DownloadTask)? onEnqueue;
  Future<void> Function(DownloadTask)? onResume;

  @override
  Stream<TaskUpdate> get updates => controller.stream;
  @override
  Future<void> start() async {}
  @override
  Future<TaskRecord?> record(String id) async => currentRecord;
  @override
  Future<Task?> activeTask(String id) async => active;
  @override
  Future<bool> enqueue(DownloadTask task) async {
    enqueues++;
    lastTask = task;
    await onEnqueue?.call(task);
    return true;
  }

  @override
  Future<bool> resume(DownloadTask task) async {
    resumes++;
    lastTask = task;
    await onResume?.call(task);
    return true;
  }

  @override
  Future<bool> cancel(String id) async {
    cancels++;
    active = null;
    return true;
  }

  @override
  Future<void> forget(String id) async {
    forgets++;
    currentRecord = null;
  }
}

void main() {
  late Directory root;
  late _Queue queue;
  late ModelDownloadService service;
  final link = ModelDownloadLink(
    url: Uri.parse('https://example.test/models/fixture?signature=secret'),
    expiresAt: DateTime.utc(2099),
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('void-factor-model-test-');
    queue = _Queue();
    service = ModelDownloadService(queue: queue, root: root);
  });
  tearDown(() async {
    await queue.controller.close();
    await root.delete(recursive: true);
  });

  Future<File> staging() async {
    final file = File(
      '${root.path}/models/${fixture.sha256}/fixture.litertlm.download',
    );
    await file.parent.create(recursive: true);
    return file;
  }

  test('task identity is independent of renewed signed links', () {
    expect(ModelDownloadService.taskId(fixture), 'gemma-gemma-fixture-v1');
  });

  test('verifies size and SHA-256 with streamed reads', () async {
    final file = await staging();
    await file.writeAsString('abc');
    expect(await service.verify(file, fixture), isTrue);
    await file.writeAsString('abd');
    expect(await service.verify(file, fixture), isFalse);
    await file.writeAsString('ab');
    expect(await service.verify(file, fixture), isFalse);
  });

  test(
    'completed download from a closed app finalizes without a new link',
    () async {
      final file = await staging();
      await file.writeAsString('abc');
      final task = DownloadTask(
        taskId: ModelDownloadService.taskId(fixture),
        url: link.url.toString(),
      );
      queue.currentRecord = TaskRecord(task, TaskStatus.complete, 1, 3);
      final state = File('${root.path}/models/download-state.json');
      await state.writeAsString(
        jsonEncode({
          'owner_uid': 'u1',
          'version': fixture.version,
          'sha256': fixture.sha256,
          'task_id': task.taskId,
        }),
      );
      var linksRequested = 0;
      var verifying = false;
      final result = await service.download(
        uid: 'u1',
        artifact: fixture,
        renewLink: () async {
          linksRequested++;
          return link;
        },
        onProgress: (_) {},
        onVerifying: () => verifying = true,
      );
      expect(linksRequested, 0);
      expect(verifying, isTrue);
      expect(await result.readAsString(), 'abc');
      expect(await file.exists(), isFalse);
    },
  );

  test('new download uses fixed ID and verifies before finalization', () async {
    final file = await staging();
    queue.onEnqueue = (task) async {
      await file.writeAsString('abc');
      scheduleMicrotask(
        () => queue.controller.add(TaskStatusUpdate(task, TaskStatus.complete)),
      );
    };
    var verifying = false;
    final result = await service.download(
      uid: 'u1',
      artifact: fixture,
      renewLink: () async => link,
      onProgress: (_) {},
      onVerifying: () => verifying = true,
    );
    expect(queue.enqueues, 1);
    expect(queue.lastTask!.taskId, ModelDownloadService.taskId(fixture));
    expect(queue.lastTask!.url, link.url.toString());
    expect(verifying, isTrue);
    expect(await result.readAsString(), 'abc');
  });

  test('progress is persisted while a transfer is running', () async {
    final file = await staging();
    final enqueued = Completer<DownloadTask>();
    queue.onEnqueue = (task) async => enqueued.complete(task);
    final running = service.download(
      uid: 'u1',
      artifact: fixture,
      renewLink: () async => link,
      onProgress: (_) {},
      onVerifying: () {},
    );
    final task = await enqueued.future;
    queue.controller.add(TaskProgressUpdate(task, 0.42));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final state =
        jsonDecode(
              await File(
                '${root.path}/models/download-state.json',
              ).readAsString(),
            )
            as Map<String, dynamic>;
    expect(state['progress'], 42);
    expect(state['descriptor'], fixture.toJson());
    await file.writeAsString('abc');
    queue.controller.add(TaskStatusUpdate(task, TaskStatus.complete));
    await running;
  });

  test('checksum failure deletes the untrusted staging file', () async {
    final file = await staging();
    queue.onEnqueue = (task) async {
      await file.writeAsString('abd');
      scheduleMicrotask(
        () => queue.controller.add(TaskStatusUpdate(task, TaskStatus.complete)),
      );
    };
    await expectLater(
      service.download(
        uid: 'u1',
        artifact: fixture,
        renewLink: () async => link,
        onProgress: (_) {},
        onVerifying: () {},
      ),
      throwsA(isA<ModelDownloadException>()),
    );
    expect(await file.exists(), isFalse);
    expect(await (await service.finalFile(fixture)).exists(), isFalse);
  });

  test('paused transfer resumes with a renewed URL and the same ID', () async {
    final old = DownloadTask(
      taskId: ModelDownloadService.taskId(fixture),
      url: 'https://example.test/expired',
    );
    queue.currentRecord = TaskRecord(old, TaskStatus.paused, 0.5, 3);
    queue.active = old; // The real taskForId API also returns paused tasks.
    final state = File('${root.path}/models/download-state.json');
    await state.parent.create(recursive: true);
    await state.writeAsString(
      jsonEncode({
        'owner_uid': 'u1',
        'version': fixture.version,
        'sha256': fixture.sha256,
        'task_id': old.taskId,
      }),
    );
    await (await staging()).writeAsString('ab');
    queue.onResume = (task) async {
      await (await staging()).writeAsString('abc');
      scheduleMicrotask(
        () => queue.controller.add(TaskStatusUpdate(task, TaskStatus.complete)),
      );
    };
    await service.download(
      uid: 'u1',
      artifact: fixture,
      renewLink: () async => link,
      onProgress: (_) {},
      onVerifying: () {},
    );
    expect(queue.resumes, 1);
    expect(queue.enqueues, 0);
    expect(queue.lastTask!.taskId, old.taskId);
    expect(queue.lastTask!.url, link.url.toString());
  });

  test('account change cancels and clears pending transfer', () async {
    final state = File('${root.path}/models/download-state.json');
    await state.parent.create(recursive: true);
    await state.writeAsString(
      jsonEncode({
        'owner_uid': 'old-user',
        'version': fixture.version,
        'sha256': fixture.sha256,
        'task_id': ModelDownloadService.taskId(fixture),
      }),
    );
    final file = await staging();
    await file.writeAsString('ab');
    await service.reconcileOwner('new-user', fixture);
    expect(queue.cancels, 1);
    expect(await state.exists(), isFalse);
    expect(await file.exists(), isFalse);
  });

  test('streaming task reattaches without renewing an expired URL', () async {
    final task = DownloadTask(
      taskId: ModelDownloadService.taskId(fixture),
      url: 'https://example.test/expired',
    );
    queue.active = task;
    queue.currentRecord = TaskRecord(task, TaskStatus.running, 0.5, 3);
    final state = File('${root.path}/models/download-state.json');
    await state.parent.create(recursive: true);
    await state.writeAsString(
      jsonEncode({
        'owner_uid': 'u1',
        'version': fixture.version,
        'sha256': fixture.sha256,
        'task_id': task.taskId,
        'expires_at': '2000-01-01T00:00:00Z',
      }),
    );
    final running = service.download(
      uid: 'u1',
      artifact: fixture,
      renewLink: () => throw StateError('must not renew a streaming task'),
      onProgress: (_) {},
      onVerifying: () {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await (await staging()).writeAsString('abc');
    queue.controller.add(TaskStatusUpdate(task, TaskStatus.complete));
    expect(await (await running).readAsString(), 'abc');
    expect(queue.enqueues, 0);
  });

  test('logout during link renewal cannot enqueue a new transfer', () async {
    final renewal = Completer<ModelDownloadLink>();
    final entered = Completer<void>();
    final running = service.download(
      uid: 'u1',
      artifact: fixture,
      renewLink: () {
        entered.complete();
        return renewal.future;
      },
      onProgress: (_) {},
      onVerifying: () {},
    );
    final failed = expectLater(running, throwsA(isA<ModelDownloadException>()));
    await entered.future;
    await service.clearPending();
    renewal.complete(link);
    await failed;
    expect(queue.enqueues, 0);
    expect(
      await File('${root.path}/models/download-state.json').exists(),
      isFalse,
    );
  });

  test(
    'an orphaned live transfer is canceled before changing accounts',
    () async {
      queue.active = DownloadTask(
        taskId: ModelDownloadService.taskId(fixture),
        url: 'https://example.test/unknown-owner',
      );
      await service.reconcileOwner('new-user', fixture);
      expect(queue.cancels, 1);
      expect(queue.active, isNull);
    },
  );

  test('removal deletes the app-owned file and pending state', () async {
    final finalFile = await service.finalFile(fixture);
    await finalFile.parent.create(recursive: true);
    await finalFile.writeAsString('abc');
    final state = File('${root.path}/models/download-state.json');
    await state.writeAsString(
      jsonEncode({
        'owner_uid': 'u1',
        'version': fixture.version,
        'sha256': fixture.sha256,
        'task_id': ModelDownloadService.taskId(fixture),
      }),
    );
    await service.remove(fixture);
    expect(await finalFile.exists(), isFalse);
    expect(await state.exists(), isFalse);
    expect(queue.cancels, 1);
  });
}
