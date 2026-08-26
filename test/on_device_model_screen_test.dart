import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/projection/gemma_model_service.dart';
import 'package:void_factor/features/projection/hf_token_store.dart';
import 'package:void_factor/screens/settings/on_device_model_screen.dart';

class _FakeHfTokenStore implements HuggingFaceTokenStore {
  _FakeHfTokenStore([this.token]);

  String? token;

  @override
  Future<String?> read() async => token;

  @override
  Future<void> write(String token) async => this.token = token;

  @override
  Future<void> delete() async => token = null;
}

class _TestGemmaModel extends GemmaModel {
  _TestGemmaModel(this.initial);

  final GemmaModelState initial;
  int downloadCalls = 0;
  int removeCalls = 0;

  @override
  Future<GemmaModelState> build() async => initial;

  @override
  Future<void> download() async => downloadCalls++;

  @override
  Future<void> remove() async => removeCalls++;
}

void main() {
  late _FakeHfTokenStore tokenStore;
  late _TestGemmaModel model;

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          huggingFaceTokenStoreProvider.overrideWithValue(tokenStore),
          huggingFaceTokenPresentProvider
              .overrideWith((ref) async => tokenStore.token != null),
          gemmaModelProvider.overrideWith(() => model),
        ],
        child: const MaterialApp(
          home: OnDeviceModelScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    tokenStore = _FakeHfTokenStore('hf_token_value');
    model = _TestGemmaModel(
      const GemmaModelState(stage: GemmaModelStage.notInstalled),
    );
  });

  testWidgets('shows DOWNLOAD MODEL button when token is present but model absent',
      (tester) async {
    await pumpScreen(tester);

    expect(find.text('DOWNLOAD MODEL'), findsOneWidget);
    expect(find.textContaining('Ready to download'), findsOneWidget);

    await tester.tap(find.text('DOWNLOAD MODEL'));
    await tester.pumpAndSettle();

    expect(model.downloadCalls, 1);
  });

  testWidgets('shows progress when model is downloading', (tester) async {
    model = _TestGemmaModel(
      const GemmaModelState(stage: GemmaModelStage.downloading, progress: 65),
    );
    await pumpScreen(tester);

    expect(find.text('Downloading — 65% complete.'), findsOneWidget);
    expect(find.text('DOWNLOAD MODEL'), findsNothing);
  });

  testWidgets('shows TRY AGAIN when download failed', (tester) async {
    model = _TestGemmaModel(
      const GemmaModelState(
        stage: GemmaModelStage.failed,
        message: 'AUTHENTICATION FAILED (401)',
      ),
    );
    await pumpScreen(tester);

    expect(find.text('AUTHENTICATION FAILED (401)'), findsOneWidget);
    expect(find.text('TRY AGAIN'), findsOneWidget);

    await tester.tap(find.text('TRY AGAIN'));
    await tester.pumpAndSettle();

    expect(model.downloadCalls, 1);
  });

  testWidgets('shows DELETE MODEL when model is ready', (tester) async {
    model = _TestGemmaModel(
      const GemmaModelState(stage: GemmaModelStage.ready),
    );
    await pumpScreen(tester);

    expect(find.text('DELETE MODEL'), findsOneWidget);
    expect(find.text('DOWNLOAD MODEL'), findsNothing);
  });
}
