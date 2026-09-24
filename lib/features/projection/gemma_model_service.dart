import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'gemma_engine.dart';
import 'hf_token_store.dart';

/// Where the on-device model stands.
enum GemmaModelStage {
  /// No token saved, so the download cannot even be attempted.
  needsToken,

  /// Token present, model absent.
  notInstalled,

  /// Download in flight — see [GemmaModelState.progress].
  downloading,

  /// Installed and usable.
  ready,

  /// The last attempt failed. [GemmaModelState.message] says how.
  failed,
}

/// The model's state as the screen renders it.
class GemmaModelState {
  const GemmaModelState({
    required this.stage,
    this.progress = 0,
    this.message,
  });

  final GemmaModelStage stage;

  /// 0–100. Only meaningful while [stage] is [GemmaModelStage.downloading].
  final int progress;

  /// Display-ready failure copy, in the app's uppercase voice.
  final String? message;

  bool get isReady => stage == GemmaModelStage.ready;
  bool get isBusy => stage == GemmaModelStage.downloading;
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
    required String url,
    required String? token,
    required void Function(int progress) onProgress,
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
    required HuggingFaceTokenStore tokenStore,
    GemmaEngine? engine,
  })  : _tokenStore = tokenStore,
        _engine = engine ?? PlatformGemmaEngine();

  final HuggingFaceTokenStore _tokenStore;
  final GemmaEngine _engine;

  /// The model, and the exact file within its repository.
  ///
  /// `.litertlm` rather than `.task`: the package's own docs note `.task` is
  /// MediaPipe-only, so the LiteRT bundle is the one that keeps this working if
  /// the app is ever built for desktop. `q4` int4 quantisation at a 4096-token
  /// context is ~0.5 GB — the smallest bundle that comfortably fits the prompt
  /// this feature sends.
  ///
  /// Overridable at construction so a wrong or withdrawn filename is a setting
  /// the user can fix, not a dead end requiring an app update.
  static const String defaultModelUrl =
      'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/'
      'Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm';

  /// What [defaultModelUrl] weighs, near enough to plan around.
  static const int modelBytes = 584 * 1024 * 1024;

  /// The model, the engine beside it once installed (~52 MB), and headroom for
  /// the filesystem. Checked before a download starts, because a download that
  /// fills the disk fails near the end — after the user has waited for most of
  /// half a gigabyte.
  static const int requiredFreeBytes = modelBytes + 128 * 1024 * 1024;

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
    // Passed here for the paths that carry no token of their own. The plugin
    // prefers a per-download token over this one and [install] always passes its
    // own, so a token saved *after* this has run still reaches the request —
    // which is why nothing re-initializes when the token changes. Resetting the
    // plugin's registry to pick up a new token would drop the singleton the
    // download service lives on, orphaning any transfer already in flight.
    await FlutterGemma.initialize(huggingFaceToken: await _tokenStore.read());

    // Without a `running` notification the downloader ignores foreground mode
    // outright — its documentation is explicit that the setting has no effect
    // unless one is configured — and the transfer then dies at Android's
    // nine-minute limit for background work. `flutter_gemma` configures none of
    // its own, so this is what makes [install]'s `foreground: true` real.
    FileDownloader().configureNotification(
      running: const TaskNotification('DOWNLOADING ON-DEVICE MODEL', '{progress}'),
      complete: const TaskNotification('ON-DEVICE MODEL READY', ''),
      error: const TaskNotification('MODEL DOWNLOAD FAILED', ''),
      progressBar: true,
    );
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
      // Deliberately not widened to "some file is on disk". The plugin
      // rehydrates the active model on init, and a file present *without* an
      // active spec is precisely the state in which `getActiveModel` throws —
      // so answering yes here would only move the failure to generation time,
      // where the user sees it as broken recommendations instead of a model
      // that needs installing. Re-running [install] is the supported repair:
      // it is idempotent, skips the download, and sets the active model.
      return FlutterGemma.hasActiveModel();
    } catch (e) {
      debugPrint('Gemma readiness check failed: $e');
      return false;
    }
  }

  @override
  Future<void> install({
    required String url,
    required String? token,
    required void Function(int progress) onProgress,
  }) async {
    await _ensureInitialized();

    final modelPresent = await FlutterGemma.isModelInstalled(_fileNameOf(url));
    if (!modelPresent) {
      final free = await _engine.freeBytes();
      if (free != null && free < requiredFreeBytes) {
        throw const GemmaStorageException();
      }
    }

    // The engine first, and inside the same progress bar: to the user this is
    // one download, and it is — both halves exist only to run the model. Its
    // share of the bar is its share of the bytes, so the bar moves at the same
    // speed throughout.
    var engineShare = 0.0;
    if (!await _engine.isInstalled()) {
      await _engine.install(onProgress: (downloaded, total) {
        if (total <= 0) return;
        engineShare = modelPresent ? 1.0 : total / (total + modelBytes);
        onProgress((downloaded / total * engineShare * 100).floor());
      });
    }
    final modelBase = engineShare * 100;

    // The foreground service's notification is only *visible* with this
    // permission — the service, and so the download, runs either way. A refusal
    // is therefore not a failure, and must not stop the install.
    try {
      await FileDownloader().permissions.request(PermissionType.notifications);
    } catch (e) {
      debugPrint('Notification permission request failed: $e');
    }

    await FlutterGemma.installModel(
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.litertlm,
    )
        .fromNetwork(
          url,
          token: token,
          // A foreground service, not a plain work request. The plugin turns off
          // background_downloader's pause/resume for HuggingFace URLs, whose
          // weak ETags make resume unreliable, and leaves the task above the
          // priority that would qualify for user-initiated data transfer — so
          // foreground mode is the only remaining way past the nine-minute cap.
          // 584 MB does not reliably arrive inside nine minutes on a phone.
          foreground: true,
        )
        .withProgress(
          (progress) =>
              onProgress((modelBase + progress * (1 - engineShare)).floor()),
        )
        .install();
  }

  @override
  Future<bool> isInstalling() async {
    try {
      if (await _engine.isInstalling()) return true;
      await _ensureInitialized();
      final tasks = await FileDownloader().allTasks(allGroups: true);
      return tasks.any((task) => task.url == defaultModelUrl);
    } catch (e) {
      debugPrint('Gemma download check failed: $e');
      return false;
    }
  }

  /// The model's id in flutter_gemma's registry: the file name the URL ends in.
  static String _fileNameOf(String url) => Uri.parse(url).pathSegments.last;

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
    _observer ??= _GemmaMemoryObserver(() => _serialized(_unload))
      ..attach();
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
    // The loaded model maps the very file about to be deleted.
    await _serialized(_unload);
    for (final id in await FlutterGemma.listInstalledModels()) {
      await FlutterGemma.uninstallModel(id);
    }
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
    tokenStore: ref.watch(huggingFaceTokenStoreProvider),
  );
});

/// Owns the model's install lifecycle, and nothing about recommendations.
///
/// Lazy by construction: nothing here runs until the projections screen builds,
/// and the download only on an explicit tap. Half a gigabyte fetched at launch
/// would stall startup for a feature the user may never open.
class GemmaModel extends AsyncNotifier<GemmaModelState> {
  static const String errorDownloadFailed =
      'DOWNLOAD FAILED — CHECK TOKEN AND CONNECTION';
  static const String errorNetwork =
      'NETWORK CONNECTION ERROR — CHECK YOUR CONNECTION';
  static const String errorNoToken = 'NO HUGGINGFACE TOKEN';
  static const String errorNoStorage =
      'NOT ENOUGH STORAGE — FREE UP SPACE AND TRY AGAIN';
  static const String errorEngineUnavailable =
      'ENGINE UNAVAILABLE — INSTALL THE APP FROM GOOGLE PLAY';

  /// The download in flight, which every caller of [download] shares.
  ///
  /// Both the projections card and the settings screen offer the download, and
  /// a second tap arrives before the first has even read the token. Two
  /// installs would race for one file. Kept on the notifier because Riverpod
  /// reuses the instance across rebuilds, so it also survives the invalidation
  /// that saving a token causes mid-download.
  Future<void>? _inFlight;
  int _lastProgress = 0;

  @override
  Future<GemmaModelState> build() async {
    final gateway = ref.watch(gemmaGatewayProvider);

    // Installed wins over token-present. A model already on disk keeps working
    // even if the user later removes the token — the download it was needed for
    // is done, and reporting `needsToken` would offer to re-fetch a file that is
    // already there.
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
    final token = await ref.watch(huggingFaceTokenStoreProvider).read();
    if (token != null && await gateway.isInstalling()) {
      // A download that outlived the process that started it — the app was
      // closed or killed partway. Attach to it rather than offer another, so
      // the bar picks up where it was and the model is registered when it
      // lands. After build, because download() writes state.
      Future.microtask(download);
      return const GemmaModelState(stage: GemmaModelStage.downloading);
    }
    return GemmaModelState(
      stage: token == null
          ? GemmaModelStage.needsToken
          : GemmaModelStage.notInstalled,
    );
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
    final token = await ref.read(huggingFaceTokenStoreProvider).read();
    if (token == null) {
      state = const AsyncData(GemmaModelState(
        stage: GemmaModelStage.needsToken,
        message: errorNoToken,
      ));
      return;
    }

    state = const AsyncData(
      GemmaModelState(stage: GemmaModelStage.downloading),
    );

    try {
      await ref.read(gemmaGatewayProvider).install(
            url: FlutterGemmaGateway.defaultModelUrl,
            token: token,
            onProgress: (progress) {
              // Progress arrives from a native callback that outlives a disposed
              // notifier — the user can leave the screen mid-download. Writing to
              // state then would throw inside the plugin's callback, where
              // nothing can catch it.
              if (!ref.mounted) return;
              // Only forward: the engine and the model report separately, and
              // a bar that steps backwards reads as a restart. A repeat of the
              // figure already shown is dropped too — it would redraw nothing.
              final clamped = progress.clamp(0, 100);
              if (clamped <= _lastProgress) return;
              _lastProgress = clamped;
              state = AsyncData(GemmaModelState(
                stage: GemmaModelStage.downloading,
                progress: clamped,
              ));
            },
          );
      if (!ref.mounted) return;
      state = const AsyncData(GemmaModelState(stage: GemmaModelStage.ready));
    } catch (e, st) {
      debugPrint('Gemma model download failed: $e\n$st');
      if (!ref.mounted) return;
      state = AsyncData(GemmaModelState(
        stage: GemmaModelStage.failed,
        message: _formatErrorMessage(e),
      ));
    }
  }

  /// Turns a download failure into a line that says what to *do* about it.
  ///
  /// Three tiers, in order, because a looser rule placed earlier steals cases
  /// from a stricter one placed later:
  ///
  /// 1. The plugin's own verdict. It renders a transport failure as
  ///    `Network error: <message>`, and that message is free-form — an offset, a
  ///    host, a byte count. Its digits are not status codes, so its
  ///    classification has to win before any of them are looked at.
  /// 2. Explicit status codes, matched as `http <code>` rather than as a bare
  ///    three-digit number, so "reset after 403 bytes" is not read as a licence
  ///    the user must go and accept.
  /// 3. Transport words for the failures that never reach the plugin's own
  ///    classifier — a `SocketException` from the platform channel. Last because
  ///    "connection" also appears in advice text.
  static String _formatErrorMessage(Object e) {
    // Typed failures first: these come from this app, not from free-form text.
    if (e is GemmaStorageException) return errorNoStorage;
    if (e is GemmaEngineException) {
      if (e.isStorage) return errorNoStorage;
      if (e.isNetwork) return errorNetwork;
      return switch (e.code) {
        // Play is absent, or did not install this copy of the app, so it will
        // not deliver the engine to it.
        'PLAY_STORE_NOT_FOUND' ||
        'APP_NOT_OWNED' ||
        'API_NOT_AVAILABLE' =>
          errorEngineUnavailable,
        _ => errorDownloadFailed,
      };
    }

    final error = e.toString().toLowerCase();
    if (error.contains('network error')) {
      return errorNetwork;
    }
    if (error.contains('http 401') || error.contains('unauthorized')) {
      return 'AUTHENTICATION FAILED (401) — VERIFY YOUR HUGGINGFACE TOKEN';
    }
    if (error.contains('http 403') ||
        error.contains('forbidden') ||
        error.contains('gated')) {
      return 'ACCESS FORBIDDEN (403) — ACCEPT GEMMA ACCESS TERMS ON HUGGINGFACE';
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

final gemmaModelProvider =
    AsyncNotifierProvider<GemmaModel, GemmaModelState>(() {
  return GemmaModel();
});
