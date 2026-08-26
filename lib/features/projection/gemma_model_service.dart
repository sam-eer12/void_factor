import 'dart:async';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  /// Downloads and installs the model, reporting 0–100 through [onProgress].
  Future<void> install({
    required String url,
    required String? token,
    required void Function(int progress) onProgress,
  });

  /// One-shot generation. Opens a session, asks, closes.
  Future<String> generate({
    required String prompt,
    required String systemInstruction,
    required Duration timeout,
  });

  /// Removes the model files, freeing the half gigabyte.
  Future<void> uninstall();
}

class FlutterGemmaGateway implements GemmaGateway {
  FlutterGemmaGateway({required HuggingFaceTokenStore tokenStore})
      : _tokenStore = tokenStore;

  final HuggingFaceTokenStore _tokenStore;

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

  /// Whether `FlutterGemma.initialize` has run in this process.
  ///
  /// Static because the plugin's own registry is process-global: calling
  /// initialize twice is wasted work, and a per-instance flag would not prevent
  /// it if the provider were ever rebuilt.
  static bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    // Passed at initialize as well as per-download: the package's own guidance,
    // and it covers the resume path where a retry re-requests the file without
    // going back through our install().
    await FlutterGemma.initialize(huggingFaceToken: await _tokenStore.read());
    _initialized = true;
  }

  @override
  Future<bool> isReady() async {
    await _ensureInitialized();
    return FlutterGemma.hasActiveModel();
  }

  @override
  Future<void> install({
    required String url,
    required String? token,
    required void Function(int progress) onProgress,
  }) async {
    await _ensureInitialized();
    await FlutterGemma.installModel(modelType: ModelType.gemmaIt)
        .fromNetwork(url, token: token)
        .withProgress(onProgress)
        .install();
  }

  @override
  Future<String> generate({
    required String prompt,
    required String systemInstruction,
    required Duration timeout,
  }) async {
    await _ensureInitialized();
    final model = await FlutterGemma.getActiveModel(maxTokens: maxTokens);
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
      // Closed even on timeout. A session left open holds its KV cache, and the
      // next visit to the screen would allocate a second one on a device that
      // has half a gigabyte of weights resident already.
      try {
        await session.close();
      } catch (_) {
        // A session that cannot be closed is already gone; nothing to recover.
      }
    }
  }

  @override
  Future<void> uninstall() async {
    await _ensureInitialized();
    for (final id in await FlutterGemma.listInstalledModels()) {
      await FlutterGemma.uninstallModel(id);
    }
  }
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
  static const String errorNoToken = 'NO HUGGINGFACE TOKEN';

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
    final token = await ref.watch(huggingFaceTokenStoreProvider).read();
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
  Future<void> download() async {
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
              state = AsyncData(GemmaModelState(
                stage: GemmaModelStage.downloading,
                progress: progress.clamp(0, 100),
              ));
            },
          );
      if (!ref.mounted) return;
      state = const AsyncData(GemmaModelState(stage: GemmaModelStage.ready));
    } catch (_) {
      if (!ref.mounted) return;
      // The underlying message is a plugin or HTTP detail — a gated-repo 403 and
      // a dropped connection both surface as noise the user cannot act on. The
      // two things they *can* fix are named instead.
      state = const AsyncData(GemmaModelState(
        stage: GemmaModelStage.failed,
        message: errorDownloadFailed,
      ));
    }
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
