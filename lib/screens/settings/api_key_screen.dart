import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/food_log/api_credentials.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_text_field.dart';

/// Manages one API key per provider, and which of them scans start with.
///
/// All three providers are on screen at once, each with its own field, so a
/// user who holds keys for several can enter them in one pass instead of
/// walking this screen three times. Exactly one saved provider leads; the rest
/// stand behind it, and a scan falls through to them when the leader's key is
/// rejected or its provider is failing. Which one leads is stated at the top
/// and again on each block, because "which key is actually being used" is the
/// question this screen exists to answer.
///
/// No key field is ever pre-filled with what is stored. A secret the user
/// cannot act on seeing buys nothing, and putting it on screen invites a
/// shoulder-surf or a screenshot; the badge beside each provider carries the
/// state that actually matters. An empty field therefore means "leave this one
/// alone" — removal is its own button, behind a confirmation.
class ApiKeyScreen extends ConsumerStatefulWidget {
  const ApiKeyScreen({super.key});

  static const String errorSaveFailed = "COULDN'T SAVE — TRY AGAIN";
  static const String errorRemoveFailed = "COULDN'T REMOVE THE KEY — TRY AGAIN";
  static const String errorDefaultFailed =
      "COULDN'T CHANGE WHICH KEY LEADS — TRY AGAIN";
  static const String errorNothingToSave = 'ENTER AT LEAST ONE KEY';
  static const String savedMessage = 'SAVED';
  static const String confirmRemoveTitle = 'REMOVE KEY?';

  static const String saveLabel = 'SAVE KEYS';
  static const String makeDefaultLabel = 'MAKE DEFAULT';
  static const String removeLabel = 'REMOVE';

  /// Badges. [activeBadge] marks the one every scan starts with.
  static const String activeBadge = 'ACTIVE';
  static const String fallbackBadge = 'FALLBACK';
  static const String notSetBadge = 'NOT SET';

  static const String noKeysLine = 'NO KEYS SAVED — FOOD ANALYSIS IS OFF';

  /// The try order, said in one line: "EVERY SCAN TRIES GEMINI → OPENROUTER".
  static String orderLine(List<String> saved) {
    if (saved.isEmpty) return noKeysLine;
    if (saved.length == 1) return 'EVERY SCAN USES ${saved.single}';
    return 'EVERY SCAN TRIES ${saved.join(' → ')}';
  }

  @override
  ConsumerState<ApiKeyScreen> createState() => _ApiKeyScreenState();
}

class _ApiKeyScreenState extends ConsumerState<ApiKeyScreen> {
  /// One field per provider, so all three can be filled before a single save.
  final Map<String, TextEditingController> _controllers = {
    for (final provider in kApiProviders) provider: TextEditingController(),
  };
  final Set<String> _revealed = {};
  bool _isBusy = false;

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final pending = [
      for (final provider in kApiProviders)
        if (_controllers[provider]!.text.trim().isNotEmpty)
          ApiCredentials(provider: provider, key: _controllers[provider]!.text),
    ];
    if (pending.isEmpty) {
      _complain(ApiKeyScreen.errorNothingToSave);
      return;
    }

    setState(() => _isBusy = true);
    final store = ref.read(apiCredentialStoreProvider);
    final stored = <String>[];
    Object? failure;
    for (final credentials in pending) {
      try {
        await store.write(credentials);
        stored.add(credentials.provider);
      } catch (error) {
        // One keychain failure must not discard the keys that did land: a retry
        // would then re-ask for keys already saved, and clearing their fields
        // would be the only record that they were.
        failure = error;
      }
    }

    if (!mounted) return;
    ref.invalidate(apiCredentialStatusProvider);
    setState(() {
      _isBusy = false;
      // Only what was actually written. A field whose write failed keeps its
      // text so the user can try again without pasting it a second time.
      for (final provider in stored) {
        _controllers[provider]!.clear();
      }
    });
    // Staying put rather than popping: this is a management screen now, and
    // seeing the badge flip to ACTIVE is the confirmation that the save landed.
    _complain(failure == null
        ? ApiKeyScreen.savedMessage
        : ApiKeyScreen.errorSaveFailed);
  }

  Future<void> _makeDefault(String provider) async {
    setState(() => _isBusy = true);
    try {
      await ref.read(apiCredentialStoreProvider).setDefaultProvider(provider);
      if (!mounted) return;
      ref.invalidate(apiCredentialStatusProvider);
      setState(() => _isBusy = false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isBusy = false);
      _complain(ApiKeyScreen.errorDefaultFailed);
    }
  }

  Future<void> _remove(String provider, List<String> saved) async {
    final confirmed = await _confirmRemoval(provider, saved);
    if (confirmed != true || !mounted) return;

    setState(() => _isBusy = true);
    try {
      await ref.read(apiCredentialStoreProvider).deleteProvider(provider);
      if (!mounted) return;
      ref.invalidate(apiCredentialStatusProvider);
      setState(() => _isBusy = false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isBusy = false);
      _complain(ApiKeyScreen.errorRemoveFailed);
    }
  }

  Future<bool?> _confirmRemoval(String provider, List<String> saved) {
    final remaining = [
      for (final other in saved)
        if (other != provider) other,
    ];
    // What actually changes depends on whether anything is left to fall back
    // to, and the old copy could only ever say the worst case.
    final consequence = remaining.isEmpty
        ? 'FOOD ANALYSIS STOPS WORKING UNTIL YOU ADD ONE.'
        : 'SCANS WILL USE ${remaining.join(' → ')} INSTEAD.';

    return showDialog<bool>(
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
          'REMOVING THE $provider KEY. $consequence THE APP CANNOT GIVE THE '
          'KEY BACK — YOU WOULD HAVE TO COPY IT FROM YOUR PROVIDER AGAIN.',
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
            child: Text(ApiKeyScreen.removeLabel,
                style: MonolithTheme.labelMedium
                    .copyWith(color: MonolithTheme.error)),
          ),
        ],
      ),
    );
  }

  void _complain(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(apiCredentialStatusProvider);
    // Rendered from the last known value while a refresh is in flight. A write
    // invalidates this provider, and dropping to the spinner would blank the
    // three fields the user is working in every time they save one.
    final saved = status.value?.savedProviders;

    return Scaffold(
      backgroundColor: MonolithTheme.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _topBar(),
            Expanded(
              child: saved != null
                  ? _body(saved)
                  : status.hasError
                      ? _unreadable()
                      : _loading(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _loading() => const Center(
        child: CircularProgressIndicator.adaptive(
          valueColor: AlwaysStoppedAnimation<Color>(MonolithTheme.primary),
        ),
      );

  Widget _unreadable() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            "COULDN'T READ THE SAVED KEYS.",
            textAlign: TextAlign.center,
            style: MonolithTheme.bodyMedium,
          ),
        ),
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
                child: const Icon(Icons.arrow_back,
                    color: MonolithTheme.primary, size: 22),
              ),
            ),
            const SizedBox(width: 16),
            Text('API KEYS', style: MonolithTheme.headlineLarge),
          ],
        ),
      );

  Widget _body(List<String> saved) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'KEPT IN THIS DEVICE\'S KEYCHAIN AND SENT WITH EACH ANALYSIS '
            'REQUEST SO THE SERVICE CAN CALL YOUR PROVIDER. NEVER STORED '
            'WITH YOUR ACCOUNT.',
            style:
                MonolithTheme.labelSmall.copyWith(color: MonolithTheme.outline),
          ),
          const SizedBox(height: 16),
          _orderSummary(saved),
          const SizedBox(height: 24),
          for (final provider in kApiProviders) ...[
            _providerBlock(provider, saved),
            const SizedBox(height: 20),
          ],
          MonolithButton(
            label: ApiKeyScreen.saveLabel,
            onPressed: _isBusy ? null : _save,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// The whole answer to "which key is being used", in one line.
  Widget _orderSummary(List<String> saved) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: saved.isEmpty
              ? MonolithTheme.surface
              : MonolithTheme.primary,
          border: Border.all(
            color: MonolithTheme.primary,
            width: MonolithTheme.borderWidth,
          ),
        ),
        child: Text(
          ApiKeyScreen.orderLine(saved),
          style: MonolithTheme.labelMedium.copyWith(
            color: saved.isEmpty
                ? MonolithTheme.primary
                : MonolithTheme.surface,
          ),
        ),
      );

  Widget _providerBlock(String provider, List<String> saved) {
    final hasKey = saved.contains(provider);
    final leads = saved.isNotEmpty && saved.first == provider;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: MonolithTheme.surface,
        border: Border.all(
          color: MonolithTheme.primary,
          // The leader is drawn heavier, so the answer survives a glance that
          // does not read any of the words.
          width: leads
              ? MonolithTheme.heroBorderWidth
              : MonolithTheme.borderWidth,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(provider, style: MonolithTheme.headlineMedium),
              ),
              _badge(hasKey
                  ? (leads
                      ? ApiKeyScreen.activeBadge
                      : ApiKeyScreen.fallbackBadge)
                  : ApiKeyScreen.notSetBadge),
            ],
          ),
          const SizedBox(height: 16),
          MonolithTextField(
            label: 'KEY',
            hint: hasKey ? 'SAVED — PASTE TO REPLACE' : 'PASTE YOUR API KEY',
            controller: _controllers[provider],
            obscureText: !_revealed.contains(provider),
            suffixIcon: GestureDetector(
              onTap: () => setState(() {
                if (!_revealed.remove(provider)) _revealed.add(provider);
              }),
              child: Icon(
                _revealed.contains(provider)
                    ? Icons.visibility_off
                    : Icons.visibility,
                color: MonolithTheme.outline,
                size: 20,
              ),
            ),
          ),
          if (hasKey) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (!leads) ...[
                  Expanded(
                    child: MonolithButton(
                      label: ApiKeyScreen.makeDefaultLabel,
                      style: MonolithButtonStyle.secondary,
                      onPressed:
                          _isBusy ? null : () => _makeDefault(provider),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: MonolithButton(
                    label: ApiKeyScreen.removeLabel,
                    style: MonolithButtonStyle.tertiary,
                    onPressed:
                        _isBusy ? null : () => _remove(provider, saved),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _badge(String label) {
    final isActive = label == ApiKeyScreen.activeBadge;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isActive ? MonolithTheme.primary : MonolithTheme.surface,
        border: Border.all(
          color: isActive ? MonolithTheme.primary : MonolithTheme.outline,
          width: MonolithTheme.borderWidth,
        ),
      ),
      child: Text(
        label,
        style: MonolithTheme.labelSmall.copyWith(
          color: isActive ? MonolithTheme.surface : MonolithTheme.outline,
        ),
      ),
    );
  }
}
