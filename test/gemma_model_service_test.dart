import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/projection/gemma_engine.dart';
import 'package:void_factor/features/projection/gemma_model_service.dart';
import 'package:void_factor/features/projection/model_artifact.dart';
import 'package:void_factor/features/projection/model_download_link.dart';

class _MockGemmaGateway implements GemmaGateway {
  bool ready = false;
  bool installing = false;
  Object? installError;
  Completer<void>? gate;
  int installCalls = 0;
  int uninstallCalls = 0;
  ModelArtifact? installedArtifact;
  List<int> progress = const [3, 5, 4, 5, 60, 100];
  bool reportVerification = false;

  @override
  Future<bool> isReady() async => ready;

  @override
  Future<bool> isInstalling() async => installing;

  @override
  Future<void> install({
    required ModelArtifact artifact,
    required void Function(int progress) onProgress,
    required void Function() onVerifying,
  }) async {
    installCalls++;
    installedArtifact = artifact;
    if (gate != null) await gate!.future;
    if (installError != null) throw installError!;
    for (final value in progress) {
      onProgress(value);
    }
    if (reportVerification) onVerifying();
    ready = true;
  }

  @override
  Future<void> uninstall() async {
    uninstallCalls++;
    ready = false;
  }

  @override
  Future<String> generate({
    required String prompt,
    required String systemInstruction,
    required Duration timeout,
  }) async => '[]';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('GemmaModel', () {
    late _MockGemmaGateway gateway;
    late ProviderContainer container;

    setUp(() {
      gateway = _MockGemmaGateway();
      container = ProviderContainer(
        overrides: [gemmaGatewayProvider.overrideWithValue(gateway)],
      );
    });
    tearDown(() => container.dispose());

    test('existing model is ready without a download', () async {
      gateway.ready = true;
      expect(
        (await container.read(gemmaModelProvider.future)).stage,
        GemmaModelStage.ready,
      );
      expect(gateway.installCalls, 0);
    });

    test('absent model offers optional download without a token', () async {
      expect(
        (await container.read(gemmaModelProvider.future)).stage,
        GemmaModelStage.notInstalled,
      );
    });

    test('download uses the pinned bundled descriptor', () async {
      await container.read(gemmaModelProvider.notifier).download();
      expect(gateway.installCalls, 1);
      expect(
        gateway.installedArtifact!.matches(await ModelArtifact.bundled()),
        isTrue,
      );
      expect(
        container.read(gemmaModelProvider).value!.stage,
        GemmaModelStage.ready,
      );
    });

    test('duplicate taps join one download', () async {
      gateway.gate = Completer<void>();
      final notifier = container.read(gemmaModelProvider.notifier);
      final first = notifier.download();
      final second = notifier.download();
      await Future<void>.delayed(Duration.zero);
      gateway.gate!.complete();
      await Future.wait([first, second]);
      expect(gateway.installCalls, 1);
    });

    test('restores a transfer left by an earlier process', () async {
      gateway.installing = true;
      expect(
        (await container.read(gemmaModelProvider.future)).stage,
        GemmaModelStage.downloading,
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(gateway.installCalls, 1);
    });

    test('verification has its own state', () async {
      gateway.reportVerification = true;
      await container.read(gemmaModelProvider.future);
      final stages = <GemmaModelStage>[];
      container.listen(gemmaModelProvider, (_, next) {
        if (next.value != null) stages.add(next.value!.stage);
      });
      await container.read(gemmaModelProvider.notifier).download();
      expect(stages, contains(GemmaModelStage.verifying));
      expect(stages.last, GemmaModelStage.ready);
    });

    test('progress reports a restart when resume bytes are lost', () async {
      await container.read(gemmaModelProvider.future);
      final seen = <int>[];
      container.listen(gemmaModelProvider, (_, next) {
        if (next.value?.stage == GemmaModelStage.downloading) {
          seen.add(next.value!.progress);
        }
      });
      await container.read(gemmaModelProvider.notifier).download();
      expect(seen, [0, 3, 5, 4, 5, 60, 100]);
    });

    test('checksum failure is actionable', () async {
      gateway.installError = const ModelDownloadException(
        'MODEL FILE FAILED VERIFICATION — RETRY',
      );
      await container.read(gemmaModelProvider.notifier).download();
      expect(
        container.read(gemmaModelProvider).value!.message,
        contains('VERIFICATION'),
      );
    });

    test('low storage and engine failures have distinct messages', () async {
      gateway.installError = const GemmaStorageException();
      await container.read(gemmaModelProvider.notifier).download();
      expect(
        container.read(gemmaModelProvider).value!.message,
        GemmaModel.errorNoStorage,
      );
      gateway.installError = const GemmaEngineException('APP_NOT_OWNED');
      await container.read(gemmaModelProvider.notifier).download();
      expect(
        container.read(gemmaModelProvider).value!.message,
        GemmaModel.errorEngineUnavailable,
      );
    });

    test('removal unregisters the model', () async {
      gateway.ready = true;
      await container.read(gemmaModelProvider.notifier).remove();
      expect(gateway.uninstallCalls, 1);
    });
  });
}
