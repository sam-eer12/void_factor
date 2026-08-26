import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

    if (installException != null) {
      throw installException!;
    }
    onProgress(50);
    onProgress(100);
    initialReady = true;
  }

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
  });
}
