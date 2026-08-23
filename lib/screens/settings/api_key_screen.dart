import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/food_log/api_credentials.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_text_field.dart';

/// Adds, replaces or removes the analysis provider credential.
///
/// Serves first-time entry, correcting a mistyped key, switching provider and
/// rotation — all the same two writes, so there is one screen rather than four.
///
/// The key field is never pre-filled with what is stored. A secret the user
/// cannot act on seeing buys nothing, and putting it on screen invites a
/// shoulder-surf or a screenshot; the line beneath the field carries the state
/// that actually matters. Saving an empty field is therefore rejected rather
/// than read as "clear it" — removal is its own button, behind a confirmation.
class ApiKeyScreen extends ConsumerStatefulWidget {
  const ApiKeyScreen({super.key});

  static const String errorSaveFailed = "COULDN'T SAVE THE KEY — TRY AGAIN";
  static const String errorRemoveFailed =
      "COULDN'T REMOVE THE KEY — TRY AGAIN";
  static const String confirmRemoveTitle = 'REMOVE KEY?';

  /// The exact strings onboarding writes. `FoodAnalysisClient.providerSlug`
  /// matches on them, so they are storage values, not display labels.
  static const List<String> providers = ['GEMINI', 'OPENROUTER', 'NVIDIA NIM'];

  @override
  ConsumerState<ApiKeyScreen> createState() => _ApiKeyScreenState();
}

class _ApiKeyScreenState extends ConsumerState<ApiKeyScreen> {
  final _formKey = GlobalKey<FormState>();
  final _keyController = TextEditingController();

  /// Null until the user picks one, so the stored provider stays the selection
  /// without having to seed state from an async read during build.
  String? _pickedProvider;
  bool _isRevealed = false;
  bool _isBusy = false;

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _isBusy = true);
    try {
      await ref.read(apiCredentialStoreProvider).write(ApiCredentials(
            provider: _selectedProvider,
            key: _keyController.text,
          ));
      ref.invalidate(apiCredentialStatusProvider);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (_) {
      if (!mounted) return;
      // Popping would report a saved key that vision capture then cannot find.
      setState(() => _isBusy = false);
      _complain(ApiKeyScreen.errorSaveFailed);
    }
  }

  Future<void> _remove() async {
    final confirmed = await _confirmRemoval();
    if (confirmed != true || !mounted) return;

    setState(() => _isBusy = true);
    try {
      await ref.read(apiCredentialStoreProvider).delete();
      ref.invalidate(apiCredentialStatusProvider);
      if (!mounted) return;
      // Staying put: replacing a key is the common reason to remove one, and
      // popping would send the user back in through Settings to do it.
      setState(() => _isBusy = false);
      _keyController.clear();
    } catch (_) {
      if (!mounted) return;
      setState(() => _isBusy = false);
      _complain(ApiKeyScreen.errorRemoveFailed);
    }
  }

  Future<bool?> _confirmRemoval() => showDialog<bool>(
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
            ApiKeyScreen.confirmRemoveTitle,
            style: MonolithTheme.headlineMedium,
          ),
          content: Text(
            'FOOD ANALYSIS STOPS WORKING UNTIL YOU ADD ONE. THE APP CANNOT '
            'GIVE THE KEY BACK — YOU WOULD HAVE TO COPY IT FROM YOUR '
            'PROVIDER AGAIN.',
            style: MonolithTheme.bodyMedium,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('CANCEL',
                  style: MonolithTheme.labelMedium
                      .copyWith(color: MonolithTheme.primary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('REMOVE',
                  style: MonolithTheme.labelMedium
                      .copyWith(color: MonolithTheme.error)),
            ),
          ],
        ),
      );

  void _complain(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  String get _selectedProvider =>
      _pickedProvider ??
      ref.read(apiCredentialStatusProvider).value?.provider ??
      ApiKeyScreen.providers.first;

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(apiCredentialStatusProvider);

    return Scaffold(
      backgroundColor: MonolithTheme.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _topBar(),
            Expanded(
              child: status.when(
                loading: () => const Center(
                  child: CircularProgressIndicator.adaptive(
                    valueColor:
                        AlwaysStoppedAnimation<Color>(MonolithTheme.primary),
                  ),
                ),
                error: (error, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      "COULDN'T READ THE SAVED KEY.",
                      textAlign: TextAlign.center,
                      style: MonolithTheme.bodyMedium,
                    ),
                  ),
                ),
                data: _body,
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
            Text('API KEY', style: MonolithTheme.headlineLarge),
          ],
        ),
      );

  Widget _body(ApiCredentialStatus status) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'KEPT IN THIS DEVICE\'S KEYCHAIN AND SENT WITH EACH ANALYSIS '
              'REQUEST SO THE SERVICE CAN CALL YOUR PROVIDER. NEVER STORED '
              'WITH YOUR ACCOUNT.',
              style: MonolithTheme.labelSmall
                  .copyWith(color: MonolithTheme.outline),
            ),
            const SizedBox(height: 24),
            Text('PROVIDER', style: MonolithTheme.labelMedium),
            const SizedBox(height: 8),
            _providerSelector(),
            const SizedBox(height: 24),
            MonolithTextField(
              label: 'KEY',
              hint: 'PASTE YOUR API KEY',
              controller: _keyController,
              obscureText: !_isRevealed,
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? 'REQUIRED'
                  : null,
              suffixIcon: GestureDetector(
                onTap: () => setState(() => _isRevealed = !_isRevealed),
                child: Icon(
                  _isRevealed ? Icons.visibility_off : Icons.visibility,
                  color: MonolithTheme.outline,
                  size: 20,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              status.hasKey
                  ? 'CURRENTLY SET · ${status.provider}'
                  : 'NOT SET',
              style: MonolithTheme.labelSmall
                  .copyWith(color: MonolithTheme.outline),
            ),
            const SizedBox(height: 24),
            MonolithButton(
              label: 'SAVE KEY',
              onPressed: _isBusy ? null : _save,
            ),
            if (status.hasKey) ...[
              const SizedBox(height: 12),
              MonolithButton(
                label: 'REMOVE KEY',
                style: MonolithButtonStyle.tertiary,
                onPressed: _isBusy ? null : _remove,
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  /// The onboarding selector, reproduced so the two places that write these
  /// exact strings offer the same three choices.
  Widget _providerSelector() => Row(
        children: ApiKeyScreen.providers.map((provider) {
          final isSelected = provider == _selectedProvider;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _pickedProvider = provider),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                margin: EdgeInsets.only(
                    right: provider == ApiKeyScreen.providers.last ? 0 : 6),
                decoration: BoxDecoration(
                  color: isSelected
                      ? MonolithTheme.primary
                      : MonolithTheme.surface,
                  border: Border.all(
                    color: MonolithTheme.primary,
                    width: MonolithTheme.borderWidth,
                  ),
                ),
                child: Center(
                  child: Text(
                    provider,
                    style: MonolithTheme.labelSmall.copyWith(
                      color: isSelected
                          ? MonolithTheme.surface
                          : MonolithTheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      );
}
