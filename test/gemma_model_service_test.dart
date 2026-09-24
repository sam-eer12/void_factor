import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/projection/gemma_engine.dart';
import 'package:void_factor/features/projection/gemma_model_service.dart';
import 'package:void_factor/features/projection/hf_token_store.dart';

class _FakeTokenStore implements HuggingFaceTokenStore {
  String? token;

  @override
  Future<String?> read() async => token;

  @override
  Future<void> write(String token) async => this.token = token;

  @override
  Future<void> delete() async => token = null;
}

class _MockGemmaGateway implements GemmaGateway {
  /// Set by each test rather than passed in, so a test reads as the one line it
  /// changes from the default.
  bool initialReady = false;
  Object? installException;
  int installCalls = 0;
  String? lastInstallUrl;
  String? lastInstallToken;
  void Function(int progress)? lastOnProgress;
  int uninstallCalls = 0;

  @override
  Future<bool> isReady() async => initialReady;

  @override
  Future<void> install({
    required String url,
    required String? token,
    required void Function(int progress) onProgress,
  }) async {
    installCalls++;
    lastInstallUrl = url;
    lastInstallToken = token;
    lastOnProgress = onProgress;

    final gate = installGate;
    if (gate != null) await gate.future;
    if (installException != null) {
      throw installException!;
    }
    for (final progress in progressScript) {
      onProgress(progress);
    }
    initialReady = true;
  }

  /// Held open to observe a download in flight.
  Completer<void>? installGate;

  /// What the install reports, in order.
  List<int> progressScript = const [50, 100];

  @override
  Future<String> generate({
    required String prompt,
    required String systemInstruction,
    required Duration timeout,
  }) async =>
      '[]';

  @override
  Future<void> uninstall() async {
    uninstallCalls++;
    initialReady = false;
  }

  /// A download left running by an earlier process, for the resume tests.
  bool installing = false;

  @override
  Future<bool> isInstalling() async => installing;
}

void main() {
  group('GemmaModel', () {
    late _FakeTokenStore tokenStore;
    late _MockGemmaGateway gateway;
    late ProviderContainer container;

    setUp(() {
      tokenStore = _FakeTokenStore();
      gateway = _MockGemmaGateway();
      container = ProviderContainer(
        overrides: [
          huggingFaceTokenStoreProvider.overrideWithValue(tokenStore),
          gemmaGatewayProvider.overrideWithValue(gateway),
        ],
      );
    });

    tearDown(() => container.dispose());

    test('initial state is ready if model is already on disk', () async {
      gateway.initialReady = true;
      final state = await container.read(gemmaModelProvider.future);
      expect(state.stage, GemmaModelStage.ready);
      expect(state.isReady, isTrue);
    });

    test('initial state is needsToken if no model and no token', () async {
      final state = await container.read(gemmaModelProvider.future);
      expect(state.stage, GemmaModelStage.needsToken);
    });

    test('initial state is notInstalled if token exists but model absent',
        () async {
      tokenStore.token = 'hf_valid_token';
      final state = await container.read(gemmaModelProvider.future);
      expect(state.stage, GemmaModelStage.notInstalled);
    });

    test('download fails gracefully with needsToken if no token is saved',
        () async {
      tokenStore.token = null;
      await container.read(gemmaModelProvider.notifier).download();
      final state = container.read(gemmaModelProvider).value!;
      expect(state.stage, GemmaModelStage.needsToken);
      expect(state.message, GemmaModel.errorNoToken);
      expect(gateway.installCalls, 0);
    });

    test('download progresses and transitions to ready on success', () async {
      tokenStore.token = 'hf_valid_token';
      final modelNotifier = container.read(gemmaModelProvider.notifier);

      // Trigger download
      await modelNotifier.download();

      expect(gateway.installCalls, 1);
      expect(gateway.lastInstallUrl, FlutterGemmaGateway.defaultModelUrl);
      expect(gateway.lastInstallToken, 'hf_valid_token');

      final state = container.read(gemmaModelProvider).value!;
      expect(state.stage, GemmaModelStage.ready);
      expect(state.isReady, isTrue);
    });

    test('download sets failed with 401 message when token is rejected',
        () async {
      tokenStore.token = 'hf_invalid_token';
      gateway.installException = Exception('HTTP 401 Unauthorized');
      final modelNotifier = container.read(gemmaModelProvider.notifier);

      await modelNotifier.download();

      final state = container.read(gemmaModelProvider).value!;
      expect(state.stage, GemmaModelStage.failed);
      expect(state.message, contains('401'));
      expect(state.message, contains('VERIFY YOUR HUGGINGFACE TOKEN'));
    });

    test('download sets failed with 403 message when repo terms not accepted',
        () async {
      tokenStore.token = 'hf_token_no_access';
      gateway.installException = Exception('GatedRepo 403 Forbidden');
      final modelNotifier = container.read(gemmaModelProvider.notifier);

      await modelNotifier.download();

      final state = container.read(gemmaModelProvider).value!;
      expect(state.stage, GemmaModelStage.failed);
      expect(state.message, contains('403'));
      expect(state.message, contains('ACCEPT GEMMA ACCESS TERMS'));
    });

    test('a network error whose text merely contains 403 stays a network error',
        () async {
      tokenStore.token = 'hf_token';
      // The plugin renders transient failures as `Network error: <message>`,
      // and that message is free-form: an offset, a host, a byte count. Matching
      // a bare "403" anywhere in it would tell the user to go accept a licence
      // when the truth is their connection dropped.
      gateway.installException = Exception(
        'DownloadException: Network error: connection reset after 403 bytes',
      );

      await container.read(gemmaModelProvider.notifier).download();

      final state = container.read(gemmaModelProvider).value!;
      expect(state.message, contains('NETWORK CONNECTION ERROR'));
    });

    test('download sets failed with network message on socket exception',
        () async {
      tokenStore.token = 'hf_token';
      gateway.installException = Exception('SocketException: connection failed');
      final modelNotifier = container.read(gemmaModelProvider.notifier);

      await modelNotifier.download();

      final state = container.read(gemmaModelProvider).value!;
      expect(state.stage, GemmaModelStage.failed);
      expect(state.message, contains('NETWORK CONNECTION ERROR'));
    });

    test('remove calls gateway uninstall', () async {
      gateway.initialReady = true;
      await container.read(gemmaModelProvider.notifier).remove();
      expect(gateway.uninstallCalls, 1);
    });

    test('a second download while one runs joins it instead of starting another',
        () async {
      // The projections card and the settings screen both offer the download,
      // and a second tap lands before the first has even read the token.
      tokenStore.token = 'hf_token';
      gateway.installGate = Completer<void>();
      final notifier = container.read(gemmaModelProvider.notifier);

      final first = notifier.download();
      final second = notifier.download();
      gateway.installGate!.complete();
      await Future.wait([first, second]);

      expect(gateway.installCalls, 1);
      expect(container.read(gemmaModelProvider).value!.stage,
          GemmaModelStage.ready);
    });

    test('a rebuild mid-download still reports the download', () async {
      // Saving a token invalidates the model's state; the download under way
      // must not turn back into a DOWNLOAD MODEL button.
      tokenStore.token = 'hf_token';
      gateway.installGate = Completer<void>();
      final download = container.read(gemmaModelProvider.notifier).download();
      await Future<void>.delayed(Duration.zero);

      container.invalidate(gemmaModelProvider);
      final rebuilt = await container.read(gemmaModelProvider.future);

      expect(rebuilt.stage, GemmaModelStage.downloading);
      gateway.installGate!.complete();
      await download;
      expect(gateway.installCalls, 1);
    });

    test('attaches to a download an earlier process left running', () async {
      tokenStore.token = 'hf_token';
      gateway.installing = true;

      final initial = await container.read(gemmaModelProvider.future);
      expect(initial.stage, GemmaModelStage.downloading);

      // The attach happens right after the state is built.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(gateway.installCalls, 1);
      expect(container.read(gemmaModelProvider).value!.stage,
          GemmaModelStage.ready);
    });

    test('does not attach without a token to download with', () async {
      gateway.installing = true;

      final initial = await container.read(gemmaModelProvider.future);

      expect(initial.stage, GemmaModelStage.needsToken);
      expect(gateway.installCalls, 0);
    });

    test('progress never steps backwards', () async {
      // The engine and the model report separately; a bar that drops from 5%
      // to 0% when the second begins reads as a restart.
      tokenStore.token = 'hf_token';
      gateway.progressScript = const [3, 5, 4, 5, 60, 100];
      await container.read(gemmaModelProvider.future);
      final seen = <int>[];
      container.listen(gemmaModelProvider, (_, next) {
        final state = next.value;
        if (state?.stage == GemmaModelStage.downloading) seen.add(state!.progress);
      });

      await container.read(gemmaModelProvider.notifier).download();

      expect(seen, [0, 3, 5, 60, 100]);
    });

    test('names a full disk as the reason, before any download', () async {
      tokenStore.token = 'hf_token';
      gateway.installException = const GemmaStorageException();

      await container.read(gemmaModelProvider.notifier).download();

      final state = container.read(gemmaModelProvider).value!;
      expect(state.stage, GemmaModelStage.failed);
      expect(state.message, GemmaModel.errorNoStorage);
    });

    group('engine delivery failures', () {
      Future<String?> messageFor(String code) async {
        tokenStore.token = 'hf_token';
        gateway.installException = GemmaEngineException(code);
        await container.read(gemmaModelProvider.notifier).download();
        return container.read(gemmaModelProvider).value!.message;
      }

      test('a network failure says so', () async {
        expect(await messageFor('NETWORK_ERROR'), GemmaModel.errorNetwork);
      });

      test('a full disk says so', () async {
        expect(await messageFor('INSUFFICIENT_STORAGE'), GemmaModel.errorNoStorage);
      });

      test('a copy Play will not serve says where to get one it will',
          () async {
        expect(await messageFor('APP_NOT_OWNED'),
            GemmaModel.errorEngineUnavailable);
        expect(await messageFor('PLAY_STORE_NOT_FOUND'),
            GemmaModel.errorEngineUnavailable);
      });

      test('anything else is a failed download', () async {
        expect(await messageFor('INSTALL_FAILED'), GemmaModel.errorDownloadFailed);
      });
    });
  });
}
