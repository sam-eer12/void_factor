import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/projection/gemma_model_service.dart';
import '../../features/projection/model_download_consent.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';

/// One entry point for the optional model. Settings and Projections use the
/// same consent action, and neither needs a Hugging Face credential.
class OnDeviceModelScreen extends ConsumerStatefulWidget {
  const OnDeviceModelScreen({super.key});

  static const String confirmRemoveModelTitle = 'DELETE MODEL?';

  @override
  ConsumerState<OnDeviceModelScreen> createState() =>
      _OnDeviceModelScreenState();
}

class _OnDeviceModelScreenState extends ConsumerState<OnDeviceModelScreen> {
  bool _isBusy = false;

  Future<void> _removeModel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: MonolithTheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(
            color: MonolithTheme.primary,
            width: MonolithTheme.borderWidth,
          ),
        ),
        title: Text(
          OnDeviceModelScreen.confirmRemoveModelTitle,
          style: MonolithTheme.headlineMedium,
        ),
        content: Text(
          'FREES ABOUT HALF A GIGABYTE. YOUR RECOMMENDATIONS KEEP WORKING '
          'WITH BUILT-IN WORDING. YOU CAN DOWNLOAD THE MODEL AGAIN LATER.',
          style: MonolithTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('DELETE'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _isBusy = true);
    try {
      await ref.read(gemmaModelProvider.notifier).remove();
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _downloadModel() async {
    setState(() => _isBusy = true);
    try {
      await agreeAndDownloadModel(context, ref);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: MonolithTheme.background,
    body: SafeArea(
      bottom: false,
      child: Column(
        children: [
          _topBar(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'RECOMMENDATIONS ARE WORDED BY A MODEL THAT RUNS ENTIRELY '
                    'ON THIS DEVICE. NOTHING ABOUT YOUR BODY OR FOOD IS SENT '
                    'FOR MODEL INFERENCE. THE NUMBERS ARE ALWAYS COMPUTED BY '
                    'THE APP.',
                    style: MonolithTheme.labelSmall.copyWith(
                      color: MonolithTheme.outline,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Consumer(
                    builder: (context, ref, _) =>
                        _modelSection(ref.watch(gemmaModelProvider)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _modelSection(AsyncValue<GemmaModelState> model) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('MODEL', style: MonolithTheme.labelMedium),
      const SizedBox(height: 8),
      Text(
        _modelStatusLine(model),
        style: MonolithTheme.bodyMedium.copyWith(color: MonolithTheme.outline),
      ),
      TextButton(
        onPressed: () => showGemmaAgreement(context),
        child: const Text('READ GEMMA TERMS'),
      ),
      if (model.value?.stage == GemmaModelStage.notInstalled ||
          model.value?.stage == GemmaModelStage.failed) ...[
        const SizedBox(height: 16),
        MonolithButton(
          label: 'AGREE & DOWNLOAD MODEL',
          onPressed: _isBusy ? null : _downloadModel,
        ),
      ],
      if (model.value?.isReady == true) ...[
        const SizedBox(height: 16),
        MonolithButton(
          label: 'DELETE MODEL',
          style: MonolithButtonStyle.tertiary,
          onPressed: _isBusy ? null : _removeModel,
        ),
      ],
    ],
  );

  Widget _topBar() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
    decoration: const BoxDecoration(
      color: MonolithTheme.surface,
      border: Border(
        bottom: BorderSide(
          color: MonolithTheme.primary,
          width: MonolithTheme.borderWidth,
        ),
      ),
    ),
    child: Row(
      children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: MonolithTheme.containerDecoration,
            child: const Icon(
              Icons.arrow_back,
              color: MonolithTheme.primary,
              size: 22,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text('ON-DEVICE MODEL', style: MonolithTheme.headlineLarge),
        ),
      ],
    ),
  );

  String _modelStatusLine(AsyncValue<GemmaModelState> model) {
    return switch (model) {
      AsyncData(value: final state) => switch (state.stage) {
        GemmaModelStage.ready =>
          'Installed. Your recommendations are worded on device.',
        GemmaModelStage.downloading =>
          'Downloading — ${state.progress}% complete.',
        GemmaModelStage.verifying => 'Verifying the downloaded model…',
        GemmaModelStage.notInstalled =>
          'Not installed. Optional download (about half a gigabyte).',
        GemmaModelStage.failed =>
          state.message ?? 'The last download attempt failed.',
      },
      AsyncError() => "Couldn't check what is installed.",
      _ => 'Checking…',
    };
  }
}
