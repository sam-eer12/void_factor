import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'gemma_engine.dart';
import 'model_artifact.dart';
import 'model_download_link.dart';
import 'model_download_service.dart';

/// Where the on-device model stands.
enum GemmaModelStage {
  notInstalled,

  /// Download in flight — see [GemmaModelState.progress].
  downloading,

  /// The bytes are complete and their digest is being checked.
  verifying,

  /// Installed and usable.
  ready,

  /// The last attempt failed. [GemmaModelState.message] says how.
  failed,
}

/// The model's state as the screen renders it.
class GemmaModelState {
  const GemmaModelState({required this.stage, this.progress = 0, this.message});

  final GemmaModelStage stage;

  /// 0–100. Only meaningful while [stage] is [GemmaModelStage.downloading].
  final int progress;

  /// Display-ready failure copy, in the app's uppercase voice.
  final String? message;

  bool get isReady => stage == GemmaModelStage.ready;
  bool get isBusy =>
      stage == GemmaModelStage.downloading ||
      stage == GemmaModelStage.verifying;
}

/// Everything this feature needs from `flutter_gemma`, behind one seam.
///
/// The plugin talks to platform channels and native FFI, neither of which exists
/// under `flutter_test`. Without this interface the narrator's fallback paths —
/// the ones that actually matter, since they are what every user without a
/// downloaded model gets — would be the only untestable part of the feature.
///
/// Kept deliberately narrow: install, ask, forget. The plugin's session lifecycle
/// stays on the far side.
abstract class GemmaGateway {
  /// Whether a model is installed and set active. Survives app restarts —
  /// the plugin rehydrates the active-model identity from preferences on init.
  Future<bool> isReady();

  /// Downloads and installs the model — and, where it is delivered on its own,
  /// the engine that runs it — reporting 0–100 through [onProgress].
  Future<void> install({
    required ModelArtifact artifact,
    required void Function(int progress) onProgress,
    required void Function() onVerifying,
  });

  /// One-shot generation. Opens a session, asks, closes.
  ///
  /// Throws when no model is installed, before loading anything — so a caller
  /// needs no readiness check of its own.
  Future<String> generate({
    required String prompt,
    required String systemInstruction,
    required Duration timeout,
  });

  /// Removes the model files, freeing the half gigabyte.
  Future<void> uninstall();

  /// Whether a download is running that nothing in this process started — one
  /// that outlived the app being closed or killed. Attaching to it resumes the
  /// progress bar where it was instead of offering a second download.
  Future<bool> isInstalling();
}

/// Not enough room for the download, found before starting it.
class GemmaStorageException implements Exception {
  const GemmaStorageException();

  @override
  String toString() => 'GemmaStorageException: not enough free storage';
}

class FlutterGemmaGateway implements GemmaGateway {
  FlutterGemmaGateway({
    GemmaEngine? engine,
    ModelDownloadService? downloads,
    ModelDownloadLinkClient? links,
  }) : _engine = engine ?? PlatformGemmaEngine(),
       _downloads = downloads ?? sharedModelDownloadService,
       _links = links ?? ModelDownloadLinkClient();

  final GemmaEngine _engine;
  final ModelDownloadService _downloads;
  final ModelDownloadLinkClient _links;
  String? _registeredOwnedPath;

  /// The model, and the exact file within its repository.
  ///
  /// `.litertlm` rather than `.task`: the package's own docs note `.task` is
  /// MediaPipe-only, so the LiteRT bundle is the one that keeps this working if
  /// the app is ever built for desktop. `q4` int4 quantisation at a 4096-token
  /// context is ~0.5 GB — the smallest bundle that comfortably fits the prompt
  /// this feature sends.
  ///
  /// The model, the engine beside it once installed (~52 MB), and headroom for
  /// the filesystem. Checked before a download starts, because a download that
  /// fills the disk fails near the end — after the user has waited for most of
  /// half a gigabyte.
  static const int storageHeadroomBytes = 128 * 1024 * 1024;

  /// Context window. The narrator's prompt is a few hundred tokens and its reply
  /// is capped far below this; 1024 is headroom, not a target, and a larger
  /// window costs KV-cache memory on a phone for nothing.
  static const int maxTokens = 1024;

  /// Sampling: as close to deterministic as the plugin allows.
  ///
  /// This is not creative writing — the same projection should not produce
  /// differently-worded advice on each visit, which would read as instability
  /// rather than variety. `topK: 1` is greedy decoding; the temperature is then
  /// largely moot but kept low for the backends that still apply it.
  static const double temperature = 0.2;
  static const int topK = 1;
  static const int randomSeed = 1;

  /// GPU first; flutter_gemma falls back to the CPU on its own when a device has
  /// no usable OpenCL.
  ///
  /// Not the NPU: that needs a model compiled for one specific SoC, and the
  /// generic model this app downloads would only fail there — slowly, since the
  /// NPU attempt comes first — before landing on the GPU anyway.
  static const PreferredBackend preferredBackend = PreferredBackend.gpu;

  /// The in-flight or completed `FlutterGemma.initialize` for this process.
  ///
  /// Static because the plugin's own registry is process-global: calling
  /// initialize twice is wasted work, and a per-instance flag would not prevent
  /// it if the provider were ever rebuilt.
  ///
  /// Held as the future rather than a bool so two concurrent callers — the
  /// settings screen asking [isReady] while a download runs — await one
  /// initialize instead of racing two.
  static Future<void>? _initialization;

  Future<void> _ensureInitialized() async {
    final inFlight = _initialization;
    if (inFlight != null) return inFlight;
    final started = _initialize();
    _initialization = started;
    try {
      await started;
    } catch (_) {
      // A failed initialize must not be remembered as done, or every later call
      // replays the same error forever with no way back.
      if (_initialization == started) _initialization = null;
      rethrow;
    }
  }

  Future<void> _initialize() async {
    await FlutterGemma.initialize();
  }

  @override
  Future<bool> isReady() async {
    // Wrapped because everything below reaches platform channels and native
    // FFI: a cleared model directory or a failed channel throws, and the honest
    // answer to "is a model installed" is then "no", not an error card.
    try {
      // An installed model is no use without the engine to run it. After an
      // update that moved the engine into its own module, that is exactly what
      // a returning user has — and "not installed" routes them to the download,
      // which skips the model it already has and fetches only the engine.
      if (!await _engine.isInstalled()) return false;
      await _ensureInitialized();
      final artifact = await ModelArtifact.bundled();
      final ownedFile = await _downloads.finalFile(artifact);
      if (await ownedFile.exists()) {
        if (!await _downloads.verify(ownedFile, artifact)) return false;
        // flutter_gemma 0.16.4 restores its default directory on launch, not
        // this external path. Re-register the verified app-owned file offline.
        if (_registeredOwnedPath != ownedFile.path) {
          await _registerFile(ownedFile.path);
        }
      }
      if (!FlutterGemma.hasActiveModel()) return false;
      // A legacy install has a plugin-owned file rather than the new app-owned
      // file. Loading the registered model checks that either path is usable;
      // hasActiveModel() alone only checks metadata.
      await _engine.ensureLoaded();
      await _serialized(() async {
        await _warmModel();
      });
      return true;
    } catch (e) {
      debugPrint('Gemma readiness check failed: $e');
      return false;
    }
  }

  @override
  Future<void> install({
    required ModelArtifact artifact,
    required void Function(int progress) onProgress,
    required void Function() onVerifying,
  }) async {
    await _ensureInitialized();
    final ownedFile = await _downloads.finalFile(artifact);
    final manager = FlutterGemmaPlugin.instance.modelManager;
    final legacy = manager.activeInferenceModel;
    final modelPresent =
        await _downloads.verify(ownedFile, artifact) ||
        (legacy != null && await manager.isModelInstalled(legacy));
    if (!modelPresent) {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      final pending =
          uid != null && await _downloads.isTransferring(uid, artifact);
      if (!pending) {
        final free = await _engine.freeBytes();
        if (free != null && free < artifact.sizeBytes + storageHeadroomBytes) {
          throw const GemmaStorageException();
        }
      }
      // Native transfer checks account for remaining bytes on a resumed task.
      // Requiring a second full model's free space would block a valid resume.
    }

    // The engine first, and inside the same progress bar: to the user this is
    // one download, and it is — both halves exist only to run the model. Its
    // share of the bar is its share of the bytes, so the bar moves at the same
    // speed throughout.
    var engineShare = 0.0;
    if (!await _engine.isInstalled()) {
      await _engine.install(
        onProgress: (downloaded, total) {
          if (total <= 0) return;
          engineShare = modelPresent
              ? 1.0
              : total / (total + artifact.sizeBytes);
          onProgress((downloaded / total * engineShare * 100).floor());
        },
      );
    }
    final modelBase = engineShare * 100;

    // An older installation may only need the Play engine. Keep its existing
    // file and registry usable without contacting the model host.
    if (modelPresent && await isReady()) return;

    // A transfer already streaming does not need another link. In particular,
    // it can finish while offline after its original 24-hour link expires.
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      throw const ModelDownloadException('SIGN IN TO DOWNLOAD THE MODEL');
    }
    final file = await _downloads.download(
      uid: uid,
      artifact: artifact,
      renewLink: () async {
        final renewed = await _links.request(artifact);
        if (renewed.uid != uid) {
          throw const ModelDownloadException(
            'ACCOUNT CHANGED — RETRY DOWNLOAD',
          );
        }
        return renewed.link;
      },
      onProgress: (progress) =>
          onProgress((modelBase + progress * (1 - engineShare)).floor()),
      onVerifying: onVerifying,
    );
    await _registerFile(file.path);
    if (!await isReady()) {
      throw const ModelDownloadException('MODEL INSTALLED BUT COULD NOT START');
    }
  }

  Future<void> _registerFile(String path) async {
    await FlutterGemma.installModel(
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.litertlm,
    ).fromFile(path).install();
    _registeredOwnedPath = path;
  }

  @override
  Future<bool> isInstalling() async {
    try {
      if (await _engine.isInstalling()) return true;
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return false;
      return await _downloads.isTransferring(uid, await ModelArtifact.bundled());
    } catch (e) {
      debugPrint('Gemma download check failed: $e');
      return false;
    }
  }

  @override
  Future<String> generate({
    required String prompt,
    required String systemInstruction,
    required Duration timeout,
  }) {
    return _serialized(() async {
      await _ensureInitialized();
      await _engine.ensureLoaded();
      final model = await _warmModel();
      final session = await model.createSession(
        temperature: temperature,
        topK: topK,
        randomSeed: randomSeed,
        systemInstruction: systemInstruction,
      );
      try {
        await session.addQueryChunk(Message.text(text: prompt, isUser: true));
        return await session.getResponse().timeout(timeout);
      } finally {
        // Closed even on timeout. A session left open holds its KV cache, and
        // the next visit to the screen would allocate a second one on a device
        // that has half a gigabyte of weights resident already.
        try {
          await session.close();
        } catch (_) {
          // A session that cannot be closed is already gone; nothing to recover.
        }
      }
    });
  }

  // ── The warm model ─────────────────────────────────────────────────────────
  //
  // Loading the model is the slow part of a generation — seconds of reading
  // weights and building the GPU graph — and the projections screen asks again
  // every time the data under it changes. So one model stays loaded between
  // generations, and is let go when the app leaves the screen or the system asks
  // for memory back: a backgrounded app holding half a gigabyte is the first one
  // Android kills, and then nothing at all resumes where the user left it.
  //
  // Static because the plugin's model is itself a process-wide singleton.

  static InferenceModel? _model;
  static _GemmaMemoryObserver? _observer;

  /// Every generation and every unload, one at a time. Closing the model under
  /// a generation that is still running would pull its weights out from under
  /// native code mid-token.
  static Future<void> _tail = Future.value();

  static Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<InferenceModel> _warmModel() async {
    final existing = _model;
    if (existing != null) return existing;

    final model = await FlutterGemma.getActiveModel(
      maxTokens: maxTokens,
      preferredBackend: preferredBackend,
    );
    _model = model;
    _observer ??= _GemmaMemoryObserver(() => _serialized(_unload))..attach();
    return model;
  }

  static Future<void> _unload() async {
    final model = _model;
    _model = null;
    _observer?.detach();
    _observer = null;
    if (model == null) return;
    try {
      await model.close();
    } catch (e) {
      debugPrint('Gemma model close failed: $e');
    }
  }

  @override
  Future<void> uninstall() async {
    await _ensureInitialized();
    await _serialized(() async {
      // Keep generation excluded until both registry and file are gone.
      await _unload();
      for (final id in await FlutterGemma.listInstalledModels()) {
        await FlutterGemma.uninstallModel(id);
      }
      await FlutterGemmaPlugin.instance.modelManager.clearModelCache();
      _registeredOwnedPath = null;
      await _downloads.remove(await ModelArtifact.bundled());
    });
    // Nothing left for the engine to run. Play removes it when the app is next
    // in the background; a later download brings it back with the model.
    await _engine.release();
  }
}

/// Unloads the warm model when the app is no longer on screen, or when the
/// system reports memory pressure. Attached only while a model is loaded.
class _GemmaMemoryObserver with WidgetsBindingObserver {
  _GemmaMemoryObserver(this._unload);

  final Future<void> Function() _unload;

  void attach() => WidgetsBinding.instance.addObserver(this);

  void detach() => WidgetsBinding.instance.removeObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _unload();
    }
  }

  @override
  void didHaveMemoryPressure() => _unload();
}

final gemmaGatewayProvider = Provider<GemmaGateway>((ref) {
  return FlutterGemmaGateway(
    downloads: ref.watch(modelDownloadServiceProvider),
    links: ref.watch(modelDownloadLinkClientProvider),
  );
});

final modelDownloadServiceProvider = Provider<ModelDownloadService>((ref) {
  return sharedModelDownloadService;
});

/// Owns the model's install lifecycle, and nothing about recommendations.
///
/// Lazy by construction: nothing here runs until the projections screen builds,
/// and the download only on an explicit tap. Half a gigabyte fetched at launch
/// would stall startup for a feature the user may never open.
class GemmaModel extends AsyncNotifier<GemmaModelState> {
  static const String errorDownloadFailed = 'MODEL DOWNLOAD FAILED — TRY AGAIN';
  static const String errorNetwork =
      'NETWORK CONNECTION ERROR — CHECK YOUR CONNECTION';
  static const String errorNoStorage =
      'NOT ENOUGH STORAGE — FREE UP SPACE AND TRY AGAIN';
  static const String errorEngineUnavailable =
      'ENGINE UNAVAILABLE — INSTALL THE APP FROM GOOGLE PLAY';

  /// The download in flight, which every caller of [download] shares.
  ///
  /// Both the projections card and the settings screen offer the download, and
  /// a second tap arrives before the first has even read the token. Two
  /// installs would race for one file. Kept on the notifier because Riverpod
  /// reuses the instance across rebuilds.
  Future<void>? _inFlight;
  int _lastProgress = 0;

  @override
  Future<GemmaModelState> build() async {
    final gateway = ref.watch(gemmaGatewayProvider);

    if (await gateway.isReady()) {
      return const GemmaModelState(stage: GemmaModelStage.ready);
    }
    // Rebuilt mid-download: still downloading, not "ready to download".
    if (_inFlight != null) {
      return GemmaModelState(
        stage: GemmaModelStage.downloading,
        progress: _lastProgress,
      );
    }
    if (await gateway.isInstalling()) {
      // A download that outlived the process that started it — the app was
      // closed or killed partway. Attach to it rather than offer another, so
      // the bar picks up where it was and the model is registered when it
      // lands. After build, because download() writes state.
      Future.microtask(download);
      return const GemmaModelState(stage: GemmaModelStage.downloading);
    }
    return const GemmaModelState(stage: GemmaModelStage.notInstalled);
  }

  /// Downloads the model, publishing progress as it goes.
  ///
  /// Returns normally on success or failure — the outcome is in [state]. The
  /// screen shows a progress bar and then either a ready card or an error line,
  /// so a throw would be a second channel for something already reported.
  ///
  /// A call while a download is running joins it instead of starting another.
  Future<void> download() =>
      _inFlight ??= _download().whenComplete(() => _inFlight = null);

  Future<void> _download() async {
    _lastProgress = 0;
    state = const AsyncData(
      GemmaModelState(stage: GemmaModelStage.downloading),
    );

    try {
      final artifact = await ModelArtifact.bundled();
      await ref
          .read(gemmaGatewayProvider)
          .install(
            artifact: artifact,
            onProgress: (progress) {
              // Progress arrives from a native callback that outlives a disposed
              // notifier — the user can leave the screen mid-download. Writing to
              // state then would throw inside the plugin's callback, where
              // nothing can catch it.
              if (!ref.mounted) return;
              // A restart after lost resume data resets the figure honestly.
              final clamped = progress.clamp(0, 100);
              if (clamped == _lastProgress) return;
              _lastProgress = clamped;
              state = AsyncData(
                GemmaModelState(
                  stage: GemmaModelStage.downloading,
                  progress: clamped,
                ),
              );
            },
            onVerifying: () {
              if (!ref.mounted) return;
              state = const AsyncData(
                GemmaModelState(stage: GemmaModelStage.verifying),
              );
            },
          );
      if (!ref.mounted) return;
      state = const AsyncData(GemmaModelState(stage: GemmaModelStage.ready));
    } catch (e) {
      // A downloader exception can contain its signed URL. Log only the type.
      debugPrint('Gemma model download failed (${e.runtimeType})');
      if (!ref.mounted) return;
      state = AsyncData(
        GemmaModelState(
          stage: GemmaModelStage.failed,
          message: _formatErrorMessage(e),
        ),
      );
    }
  }

  /// Turns a download failure into a line that says what to *do* about it.
  ///
  /// Three tiers, in order, because a looser rule placed earlier steals cases
  /// from a stricter one placed later:
  ///
  /// Typed errors from the link and transfer services already carry safe copy.
  static String _formatErrorMessage(Object e) {
    // Typed failures first: these come from this app, not from free-form text.
    if (e is ModelDownloadException) return e.message;
    if (e is GemmaStorageException) return errorNoStorage;
    if (e is GemmaEngineException) {
      if (e.isStorage) return errorNoStorage;
      if (e.isNetwork) return errorNetwork;
      return switch (e.code) {
        // Play is absent, or did not install this copy of the app, so it will
        // not deliver the engine to it.
        'PLAY_STORE_NOT_FOUND' ||
        'APP_NOT_OWNED' ||
        'API_NOT_AVAILABLE' => errorEngineUnavailable,
        _ => errorDownloadFailed,
      };
    }

    final error = e.toString().toLowerCase();
    if (error.contains('network error')) {
      return errorNetwork;
    }
    if (error.contains('http 401') || error.contains('unauthorized')) {
      return 'SESSION EXPIRED — SIGN IN AGAIN';
    }
    if (error.contains('http 403') || error.contains('forbidden')) {
      return 'MODEL LINK EXPIRED — TRY AGAIN';
    }
    if (error.contains('http 404') || error.contains('not found')) {
      return 'MODEL NOT FOUND (404) — THE SPECIFIED FILE DOES NOT EXIST';
    }
    if (error.contains('http 429') || error.contains('rate limit')) {
      return 'RATE LIMITED (429) — PLEASE WAIT A MOMENT BEFORE RETRYING';
    }
    if (error.contains('socket') || error.contains('connection')) {
      return errorNetwork;
    }
    return errorDownloadFailed;
  }

  /// Deletes the model files.
  Future<void> remove() async {
    try {
      await ref.read(gemmaGatewayProvider).uninstall();
    } catch (_) {
      // Fall through to the rebuild: whether or not the delete succeeded, the
      // gateway is the authority on what is installed now.
    }
    ref.invalidateSelf();
  }
}

final gemmaModelProvider = AsyncNotifierProvider<GemmaModel, GemmaModelState>(
  () {
    return GemmaModel();
  },
);
