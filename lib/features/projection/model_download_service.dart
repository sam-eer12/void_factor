import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'model_artifact.dart';
import 'model_download_link.dart';

/// Narrow seam over the persistent native transfer queue. The app, rather than
/// flutter_gemma's URL-based downloader, owns the task and its final file.
abstract class ModelTransferQueue {
  Stream<TaskUpdate> get updates;
  Future<void> start();
  Future<TaskRecord?> record(String id);
  Future<Task?> activeTask(String id);
  Future<bool> enqueue(DownloadTask task);
  Future<bool> resume(DownloadTask task);
  Future<bool> cancel(String id);
  Future<void> forget(String id);
}

class BackgroundModelTransferQueue implements ModelTransferQueue {
  BackgroundModelTransferQueue([FileDownloader? downloader])
    : _downloader = downloader ?? FileDownloader();

  final FileDownloader _downloader;
  static Future<void>? _started;

  @override
  Stream<TaskUpdate> get updates => _downloader.updates;

  @override
  Future<void> start() async {
    final attempt = _started ??= _start();
    try {
      await attempt;
    } catch (_) {
      if (_started == attempt) _started = null;
      rethrow;
    }
  }

  Future<void> _start() async {
    await _downloader.configure(
      androidConfig: [
        (Config.runInForegroundIfFileLargerThan, 8),
        (Config.checkAvailableSpace, 128),
      ],
    );
    _downloader.configureNotification(
      running: const TaskNotification(
        'DOWNLOADING ON-DEVICE MODEL',
        '{progress}',
      ),
      complete: const TaskNotification('MODEL DOWNLOAD COMPLETE', ''),
      error: const TaskNotification('MODEL DOWNLOAD FAILED', ''),
      progressBar: true,
    );
    // Old flutter_gemma tasks may still contain a Hugging Face header. Cancel
    // those transfers during migration while preserving installed model files.
    await _downloader.reset(group: 'smart_downloads');
    // The caller subscribes before start(), so events that arrived while the
    // app was closed are seen. Expired links are renewed by the app before any
    // killed task is rescheduled.
    await _downloader.start(
      doRescheduleKilledTasks: false,
      markDownloadedComplete: false,
    );
    await _downloader.database.deleteAllRecords(group: 'smart_downloads');
  }

  @override
  Future<TaskRecord?> record(String id) => _downloader.database.recordForId(id);

  @override
  Future<Task?> activeTask(String id) => _downloader.taskForId(id);

  @override
  Future<bool> enqueue(DownloadTask task) => _downloader.enqueue(task);

  @override
  Future<bool> resume(DownloadTask task) => _downloader.resume(task);

  @override
  Future<bool> cancel(String id) => _downloader.cancelTaskWithId(id);

  @override
  Future<void> forget(String id) => _downloader.database.deleteRecordWithId(id);
}

class ModelDownloadService {
  ModelDownloadService({ModelTransferQueue? queue, Directory? root})
    : _queue = queue ?? BackgroundModelTransferQueue(),
      _providedRoot = root;

  final ModelTransferQueue _queue;
  final Directory? _providedRoot;
  Directory? _root;
  StreamSubscription<TaskUpdate>? _subscription;
  Completer<TaskStatusUpdate>? _completion;
  String? _waitingTaskId;
  void Function(int)? _progress;
  Future<void>? _startFuture;
  Future<void> _progressWrites = Future<void>.value();
  int _epoch = 0;

  static String taskId(ModelArtifact artifact) => 'gemma-${artifact.version}';

  Future<void> prepareForAccount(String? uid) async {
    await reconcileOwner(uid ?? '', await ModelArtifact.bundled());
  }

  Future<Directory> _directory() async {
    final existing = _root;
    if (existing != null) return existing;
    final base = _providedRoot ?? await getApplicationSupportDirectory();
    final root = Directory('${base.path}/models');
    await root.create(recursive: true);
    return _root = root;
  }

  Future<File> finalFile(ModelArtifact artifact) async {
    final root = await _directory();
    return File('${root.path}/${artifact.sha256}/${artifact.filename}');
  }

  Future<File> _stagingFile(ModelArtifact artifact) async {
    final root = await _directory();
    return File(
      '${root.path}/${artifact.sha256}/${artifact.filename}.download',
    );
  }

  Future<File> _stateFile() async {
    final root = await _directory();
    return File('${root.path}/download-state.json');
  }

  Future<Map<String, dynamic>?> _readState() async {
    try {
      final value = jsonDecode(await (await _stateFile()).readAsString());
      if (value is! Map<String, dynamic> ||
          value['owner_uid'] is! String ||
          value['task_id'] is! String ||
          value['version'] is! String ||
          value['sha256'] is! String) {
        return null;
      }
      return value;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _writeState(Map<String, dynamic> state) async {
    final file = await _stateFile();
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(state), flush: true);
    await temp.rename(file.path);
  }

  Future<void> _start() async {
    final attempt = _startFuture ??= _initialize();
    try {
      await attempt;
    } catch (_) {
      if (_startFuture == attempt) _startFuture = null;
      rethrow;
    }
  }

  Future<void> _initialize() async {
    // Listener first, then background event replay.
    _subscription ??= _queue.updates.listen((update) {
      if (update.task.taskId != _waitingTaskId) return;
      if (update is TaskProgressUpdate && update.progress >= 0) {
        final percent = (update.progress * 100).floor().clamp(0, 100);
        _progress?.call(percent);
        _progressWrites = _progressWrites
            .then((_) async {
              final state = await _readState();
              if (state != null && state['task_id'] == update.task.taskId) {
                state['progress'] = percent;
                await _writeState(state);
              }
            })
            .catchError((Object _) {
              // Progress is advisory; the downloader's own record remains durable.
            });
      } else if (update is TaskStatusUpdate && update.status.isFinalState) {
        final completion = _completion;
        if (completion != null && !completion.isCompleted) {
          completion.complete(update);
        }
      }
    });
    await _queue.start();
  }

  /// A completed app-owned file is trusted only after size and streaming SHA-256
  /// agree with the bundled manifest. This never loads 584 MB into Dart memory.
  Future<bool> verify(File file, ModelArtifact artifact) async {
    if (!await file.exists() || await file.length() != artifact.sizeBytes) {
      return false;
    }
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == artifact.sha256;
  }

  /// Reconcile the previous account before observing or starting a transfer.
  /// A verified final model is device-wide; only the pending task is account
  /// owned, because its signed link carries that account's identity.
  Future<void> reconcileOwner(String uid, ModelArtifact artifact) async {
    await _start();
    final state = await _readState();
    if (state == null) {
      // Never adopt a live capability whose owning account cannot be proved.
      final id = taskId(artifact);
      if (await _queue.activeTask(id) != null) {
        await _queue.cancel(id);
        await _queue.forget(id);
      }
      return;
    }
    if (state['owner_uid'] == uid &&
        state['version'] == artifact.version &&
        state['sha256'] == artifact.sha256) {
      return;
    }
    final id = state['task_id'] as String?;
    if (id != null) {
      await _queue.cancel(id);
      await _queue.forget(id);
    }
    final oldHash = state['sha256'] as String?;
    if (oldHash != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(oldHash)) {
      final root = await _directory();
      final oldDir = Directory('${root.path}/$oldHash');
      if (await oldDir.exists()) {
        await for (final entry in oldDir.list()) {
          if (entry is File && entry.path.endsWith('.download')) {
            await entry.delete();
          }
        }
      }
    }
    await (await _stateFile()).delete();
  }

  Future<bool> isTransferring(String uid, ModelArtifact artifact) async {
    await reconcileOwner(uid, artifact);
    final state = await _readState();
    if (state == null) return false;
    final active = await _queue.activeTask(taskId(artifact));
    final record = await _queue.record(taskId(artifact));
    return active != null ||
        record?.status == TaskStatus.paused ||
        record?.status == TaskStatus.complete ||
        await (await _stagingFile(artifact)).exists();
  }

  Future<File> download({
    required String uid,
    required ModelArtifact artifact,
    required Future<ModelDownloadLink> Function() renewLink,
    required void Function(int) onProgress,
    required void Function() onVerifying,
  }) async {
    final epoch = _epoch;
    await reconcileOwner(uid, artifact);
    final finalPath = await finalFile(artifact);
    if (await verify(finalPath, artifact)) return finalPath;
    final staging = await _stagingFile(artifact);
    await staging.parent.create(recursive: true);

    final id = taskId(artifact);
    final prior = await _readState();
    final record = await _queue.record(id);
    final active = await _queue.activeTask(id);
    // taskForId() also returns paused tasks in background_downloader 9.5.5.
    // Those must renew/resume rather than wait for a stream that has stopped.
    final running =
        active != null &&
        record?.status != TaskStatus.paused &&
        !(record?.status.isFinalState ?? false);
    if (await staging.exists() &&
        (record?.status == TaskStatus.complete ||
            (record == null && !running))) {
      return _finalize(staging, finalPath, artifact, onVerifying);
    }

    _waitingTaskId = id;
    _progress = onProgress;
    _completion = Completer<TaskStatusUpdate>();
    try {
      final savedProgress = prior?['progress'];
      onProgress(
        record != null && record.progress >= 0
            ? (record.progress * 100).floor().clamp(0, 100)
            : savedProgress is num
            ? savedProgress.toInt().clamp(0, 100)
            : 0,
      );
      if (!running) {
        // A paused task can retain native resume bytes. Renew before resuming
        // if the old URL expired; the fixed task id ties both links together.
        final link = await renewLink();
        if (epoch != _epoch) {
          throw const ModelDownloadException(
            'ACCOUNT CHANGED — RETRY DOWNLOAD',
          );
        }
        final task = DownloadTask(
          taskId: id,
          url: link.url.toString(),
          filename: '${artifact.filename}.download',
          directory: 'models/${artifact.sha256}',
          baseDirectory: BaseDirectory.applicationSupport,
          group: 'gemma-model',
          updates: Updates.statusAndProgress,
          allowPause: true,
          retries: 0,
          displayName: 'On-device model',
        );
        await _writeState({
          'owner_uid': uid,
          'version': artifact.version,
          'sha256': artifact.sha256,
          'descriptor': artifact.toJson(),
          'task_id': id,
          'expires_at': link.expiresAt.toIso8601String(),
          'progress': prior?['progress'] is num
              ? (prior!['progress'] as num).toInt()
              : 0,
        });
        final resumed =
            record?.status == TaskStatus.paused && await _queue.resume(task);
        if (!resumed) {
          await _queue.forget(id);
          onProgress(0); // Resume bytes were unavailable: show the reset.
          if (!await _queue.enqueue(task)) {
            throw const ModelDownloadException('COULDN’T START MODEL DOWNLOAD');
          }
        }
      }
      // The task may have completed between our initial queue lookup and
      // subscription. The persistent record closes that event race.
      final latest = await _queue.record(id);
      if (latest != null &&
          latest.status.isFinalState &&
          !_completion!.isCompleted) {
        _completion!.complete(TaskStatusUpdate(latest.task, latest.status));
      }
      final result = await _completion!.future;
      if (result.status != TaskStatus.complete) {
        throw ModelDownloadException(
          result.responseStatusCode == 429
              ? 'MODEL RATE LIMIT — WAIT A MOMENT'
              : 'MODEL DOWNLOAD INTERRUPTED — TRY AGAIN',
        );
      }
      return await _finalize(staging, finalPath, artifact, onVerifying);
    } finally {
      _completion = null;
      _waitingTaskId = null;
      _progress = null;
    }
  }

  Future<File> _finalize(
    File staging,
    File finalPath,
    ModelArtifact artifact,
    void Function() onVerifying,
  ) async {
    onVerifying();
    if (!await verify(staging, artifact)) {
      if (await staging.exists()) await staging.delete();
      await _queue.forget(taskId(artifact));
      throw const ModelDownloadException(
        'MODEL FILE FAILED VERIFICATION — RETRY',
      );
    }
    if (await finalPath.exists()) await finalPath.delete();
    await staging.rename(finalPath.path);
    await _progressWrites;
    await _queue.forget(taskId(artifact));
    final state = await _stateFile();
    if (await state.exists()) await state.delete();
    return finalPath;
  }

  Future<void> remove(ModelArtifact artifact) async {
    _epoch++;
    await _start();
    await _queue.cancel(taskId(artifact));
    await _queue.forget(taskId(artifact));
    final state = await _stateFile();
    if (await state.exists()) await state.delete();
    final staging = await _stagingFile(artifact);
    if (await staging.exists()) await staging.delete();
    final finalPath = await finalFile(artifact);
    if (await finalPath.exists()) await finalPath.delete();
  }

  /// Called on logout. The verified model is not personal and remains; the
  /// pending signed transfer belongs to the previous account and must stop.
  Future<void> clearPending() async {
    _epoch++;
    await _start();
    await _progressWrites;
    final state = await _readState();
    if (state == null) return;
    final pending = _completion;
    if (pending != null && !pending.isCompleted) {
      pending.complete(
        TaskStatusUpdate(
          DownloadTask(
            taskId: state['task_id'] as String? ?? 'gemma-canceled',
            url: 'https://invalid.local/canceled',
          ),
          TaskStatus.canceled,
        ),
      );
    }
    _waitingTaskId = null;
    _progress = null;
    final id = state['task_id'] as String?;
    if (id != null) {
      await _queue.cancel(id);
      await _queue.forget(id);
    }
    final hash = state['sha256'] as String?;
    if (hash != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      final root = await _directory();
      final directory = Directory('${root.path}/$hash');
      if (await directory.exists()) {
        await for (final entry in directory.list()) {
          if (entry is File && entry.path.endsWith('.download')) {
            await entry.delete();
          }
        }
      }
    }
    await (await _stateFile()).delete();
  }
}

/// Process-wide owner of the native transfer listener, shared by the model
/// provider and logout cleanup.
final sharedModelDownloadService = ModelDownloadService();
