import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/projection/gemma_model_service.dart';
import '../../features/projection/hf_token_store.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_text_field.dart';

/// Manages the HuggingFace token and the downloaded on-device model.
///
/// Mirrors `ApiKeyScreen` deliberately — same secret-handling rules, same
/// add/replace/remove shape — so the two credential screens in the app behave
/// identically. In particular the field is never pre-filled with what is stored:
/// a secret the user cannot act on seeing buys nothing, and putting it on screen
/// invites a shoulder-surf. The line beneath the field carries the state that
/// matters.
///
/// It also owns model *removal*, because this is the only screen where reclaiming
/// half a gigabyte belongs. Downloading stays on the projections screen, where the
/// user can see what the model is for — one download flow with one progress
/// indicator, rather than two that must agree.
class OnDeviceModelScreen extends ConsumerStatefulWidget {
  const OnDeviceModelScreen({super.key});

  static const String errorSaveFailed = "COULDN'T SAVE THE TOKEN — TRY AGAIN";
  static const String errorRemoveFailed =
      "COULDN'T REMOVE THE TOKEN — TRY AGAIN";
  static const String confirmRemoveTokenTitle = 'REMOVE TOKEN?';
  static const String confirmRemoveModelTitle = 'DELETE MODEL?';

  @override
  ConsumerState<OnDeviceModelScreen> createState() =>
      _OnDeviceModelScreenState();
}

class _OnDeviceModelScreenState extends ConsumerState<OnDeviceModelScreen> {
  final _formKey = GlobalKey<FormState>();
  final _tokenController = TextEditingController();

  bool _isRevealed = false;
  bool _isBusy = false;

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _saveToken() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _isBusy = true);
    try {
      await ref
          .read(huggingFaceTokenStoreProvider)
          .write(_tokenController.text);
      ref.invalidate(huggingFaceTokenPresentProvider);
      // The model's own state reads the token to decide between "needs a token"
      // and "ready to download", so it is stale the moment one is saved.
      ref.invalidate(gemmaModelProvider);
      if (!mounted) return;
      setState(() => _isBusy = false);
      _tokenController.clear();
    } catch (_) {
      if (!mounted) return;
      setState(() => _isBusy = false);
      _complain(OnDeviceModelScreen.errorSaveFailed);
    }
  }

  Future<void> _removeToken() async {
    final confirmed = await _confirm(
      title: OnDeviceModelScreen.confirmRemoveTokenTitle,
      body: 'A MODEL ALREADY ON THIS DEVICE KEEPS WORKING. YOU WOULD NEED A '
          'TOKEN AGAIN TO DOWNLOAD IT AFRESH, AND THE APP CANNOT GIVE THIS '
          'ONE BACK.',
      action: 'REMOVE',
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isBusy = true);
    try {
      await ref.read(huggingFaceTokenStoreProvider).delete();
      ref.invalidate(huggingFaceTokenPresentProvider);
      ref.invalidate(gemmaModelProvider);
      if (!mounted) return;
      setState(() => _isBusy = false);
      _tokenController.clear();
    } catch (_) {
      if (!mounted) return;
      setState(() => _isBusy = false);
      _complain(OnDeviceModelScreen.errorRemoveFailed);
    }
  }

  Future<void> _removeModel() async {
    final confirmed = await _confirm(
      title: OnDeviceModelScreen.confirmRemoveModelTitle,
      body: 'FREES ABOUT HALF A GIGABYTE. YOUR RECOMMENDATIONS KEEP WORKING '
          'ON THE BUILT-IN WORDING, AND YOU CAN DOWNLOAD THE MODEL AGAIN '
          'FROM THE PROJECTIONS SCREEN.',
      action: 'DELETE',
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isBusy = true);
    await ref.read(gemmaModelProvider.notifier).remove();
    if (!mounted) return;
    setState(() => _isBusy = false);
  }

  Future<void> _downloadModel() async {
    setState(() => _isBusy = true);
    try {
      await ref.read(gemmaModelProvider.notifier).download();
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String action,
  }) =>
      showDialog<bool>(
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
          title: Text(title, style: MonolithTheme.headlineMedium),
          content: Text(body, style: MonolithTheme.bodyMedium),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('CANCEL',
                  style: MonolithTheme.labelMedium
                      .copyWith(color: MonolithTheme.primary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action,
                  style: MonolithTheme.labelMedium
                      .copyWith(color: MonolithTheme.error)),
            ),
          ],
        ),
      );

  void _complain(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final hasToken = ref.watch(huggingFaceTokenPresentProvider);
    final model = ref.watch(gemmaModelProvider);

    return Scaffold(
      backgroundColor: MonolithTheme.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _topBar(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'RECOMMENDATIONS ARE WORDED BY A MODEL THAT RUNS ENTIRELY '
                        'ON THIS DEVICE. NOTHING ABOUT YOUR BODY OR YOUR FOOD '
                        'LEAVES THE PHONE. THE NUMBERS THEMSELVES ARE ALWAYS '
                        'COMPUTED BY THE APP, NEVER BY THE MODEL.',
                        style: MonolithTheme.labelSmall
                            .copyWith(color: MonolithTheme.outline),
                      ),
                      const SizedBox(height: 24),
                      MonolithTextField(
                        label: 'HUGGINGFACE TOKEN',
                        hint: 'PASTE A READ TOKEN',
                        controller: _tokenController,
                        obscureText: !_isRevealed,
                        validator: (value) =>
                            (value == null || value.trim().isEmpty)
                                ? 'REQUIRED'
                                : null,
                        suffixIcon: GestureDetector(
                          onTap: () =>
                              setState(() => _isRevealed = !_isRevealed),
                          child: Icon(
                            _isRevealed
                                ? Icons.visibility_off
                                : Icons.visibility,
                            color: MonolithTheme.outline,
                            size: 20,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _tokenStatusLine(hasToken),
                        style: MonolithTheme.labelSmall
                            .copyWith(color: MonolithTheme.outline),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'THE MODEL IS A GATED DOWNLOAD, SO IT NEEDS A TOKEN '
                        'ONCE. REQUEST ACCESS TO GEMMA ON HUGGINGFACE, THEN '
                        'CREATE A READ TOKEN IN YOUR ACCOUNT SETTINGS.',
                        style: MonolithTheme.labelSmall
                            .copyWith(color: MonolithTheme.outline),
                      ),
                      const SizedBox(height: 24),
                      MonolithButton(
                        label: 'SAVE TOKEN',
                        onPressed: _isBusy ? null : _saveToken,
                      ),
                      if (hasToken.value == true) ...[
                        const SizedBox(height: 12),
                        MonolithButton(
                          label: 'REMOVE TOKEN',
                          style: MonolithButtonStyle.tertiary,
                          onPressed: _isBusy ? null : _removeToken,
                        ),
                      ],
                      const SizedBox(height: 32),
                      Container(
                        height: MonolithTheme.borderWidth,
                        color: MonolithTheme.primary,
                      ),
                      const SizedBox(height: 24),
                      Text('MODEL', style: MonolithTheme.labelMedium),
                      const SizedBox(height: 8),
                      Text(
                        _modelStatusLine(model),
                        style: MonolithTheme.bodyMedium
                            .copyWith(color: MonolithTheme.outline),
                      ),
                      if (model.value?.stage == GemmaModelStage.notInstalled) ...[
                        const SizedBox(height: 16),
                        MonolithButton(
                          label: 'DOWNLOAD MODEL',
                          onPressed: _isBusy ? null : _downloadModel,
                        ),
                      ],
                      if (model.value?.stage == GemmaModelStage.failed) ...[
                        const SizedBox(height: 16),
                        MonolithButton(
                          label: 'TRY AGAIN',
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
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

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
                child: const Icon(Icons.arrow_back,
                    color: MonolithTheme.primary, size: 22),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text('ON-DEVICE MODEL',
                  style: MonolithTheme.headlineLarge),
            ),
          ],
        ),
      );

  String _tokenStatusLine(AsyncValue<bool> hasToken) {
    return switch (hasToken) {
      AsyncData(value: true) => 'CURRENTLY SET',
      AsyncData() => 'NOT SET',
      AsyncError() => "COULDN'T READ THE SAVED TOKEN.",
      _ => 'CHECKING…',
    };
  }

  String _modelStatusLine(AsyncValue<GemmaModelState> model) {
    return switch (model) {
      AsyncData(value: final state) => switch (state.stage) {
          GemmaModelStage.ready =>
            'Installed. Your recommendations are worded on device.',
          GemmaModelStage.downloading =>
            'Downloading — ${state.progress}% complete.',
          GemmaModelStage.needsToken =>
            'Not installed. Save a token above, then download the model.',
          GemmaModelStage.notInstalled =>
            'Not installed. Ready to download (about half a gigabyte).',
          GemmaModelStage.failed =>
            state.message ?? 'The last download attempt failed.',
        },
      AsyncError() => "Couldn't check what is installed.",
      _ => 'Checking…',
    };
  }
}
