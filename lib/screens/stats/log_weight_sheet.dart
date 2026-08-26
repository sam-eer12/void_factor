import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/projection/projection_format.dart';
import '../../features/weight_log/weight_log_providers.dart';
import '../../models/weight_entry.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_text_field.dart';

/// Records a weigh-in.
///
/// A bottom sheet rather than a screen: it is one number, the chart behind it is
/// the reason the user is entering it, and pushing a route would take that chart
/// off screen at the moment it matters most.
class LogWeightSheet extends ConsumerStatefulWidget {
  const LogWeightSheet({super.key, required this.seedKg});

  /// The weight the field starts at — the user's latest, so a weigh-in is a nudge
  /// from where they were rather than a number typed from scratch.
  final double seedKg;

  static const String title = 'LOG WEIGHT';
  static const String caption = 'STORED ON THIS DEVICE. UPDATES YOUR '
      'TRAJECTORY AND THE WEIGHT YOUR TARGETS ARE BUILT FROM.';
  /// Interpolated from the model's own bounds rather than written out, so the
  /// number the user is told cannot drift from the number that is enforced.
  static final String invalidWeight = 'ENTER A WEIGHT BETWEEN '
      '${projectionKgLabel(WeightEntry.minKg)} AND '
      '${projectionKgLabel(WeightEntry.maxKg)} KG';

  static const String saveLabel = 'SAVE WEIGHT';
  static const String savingLabel = 'SAVING…';

  /// The steps offered either side of the current value.
  ///
  /// 0.1 is the resolution of a bathroom scale; 0.5 covers the distance a week
  /// usually moves. Anything coarser than that is faster to type.
  static const List<double> steps = [-0.5, -0.1, 0.1, 0.5];

  /// Opens the sheet, resolving to how the save went, or `null` if the user
  /// dismissed it without saving.
  static Future<WeightSaveOutcome?> show(
    BuildContext context, {
    required double seedKg,
  }) {
    return showModalBottomSheet<WeightSaveOutcome>(
      context: context,
      // The keyboard covers a bottom sheet of fixed height, and this one is
      // nothing but a field.
      isScrollControlled: true,
      // The sheet paints its own surface and its own 2px top border; Material's
      // default background would sit behind it as a second, rounded edge.
      backgroundColor: Colors.transparent,
      elevation: 0,
      builder: (_) => LogWeightSheet(seedKg: seedKg),
    );
  }

  @override
  ConsumerState<LogWeightSheet> createState() => _LogWeightSheetState();
}

class _LogWeightSheetState extends ConsumerState<LogWeightSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller;

  bool _isSaving = false;

  /// Shown inline rather than in a SnackBar: a SnackBar raised from under a modal
  /// sheet appears behind it, so the user would be told nothing at all.
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      // Empty rather than `0` when there is no weight anywhere yet — a field
      // pre-filled with a value that fails its own validator is worse than an
      // empty one.
      text: WeightEntry.isPlausible(widget.seedKg)
          ? projectionKgLabel(widget.seedKg)
          : '',
    );
    // The step controls enable and disable with what is typed, so their state
    // has to follow the field.
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  /// The number the steppers work from: whatever is typed, falling back to the
  /// seed while the field is empty.
  double? get _base {
    final typed = double.tryParse(_controller.text.trim());
    if (typed != null && typed.isFinite) return typed;
    return WeightEntry.isPlausible(widget.seedKg) ? widget.seedKg : null;
  }

  void _step(double delta) {
    final base = _base;
    // Unreachable while the button is enabled; a guard rather than a `!` so a
    // future caller cannot turn this into a crash.
    if (base == null) return;
    _controller.text = projectionKgLabel(WeightEntry.clampKg(base + delta));
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final weightKg = double.parse(_controller.text.trim());
    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      final outcome = await ref
          .read(weightLogProvider.notifier)
          .add(WeightEntry.create(weightKg: weightKg));
      if (!mounted) return;
      Navigator.pop(context, outcome);
    } on WeightLogException catch (e) {
      // The entry is not on disk, so the sheet stays open holding the number the
      // user typed. Closing it would look like a save.
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final canStep = _base != null;

    return Container(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        // Clears the keyboard when it is up, and the home indicator when it is
        // not.
        bottom: 20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      decoration: const BoxDecoration(
        color: MonolithTheme.surface,
        border: Border(
          top: BorderSide(
            color: MonolithTheme.primary,
            width: MonolithTheme.heroBorderWidth,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(LogWeightSheet.title,
                        style: MonolithTheme.headlineLarge),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: MonolithTheme.containerDecoration,
                      child: const Icon(Icons.close,
                          color: MonolithTheme.primary, size: 20),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                LogWeightSheet.caption,
                style: MonolithTheme.labelSmall
                    .copyWith(color: MonolithTheme.outline),
              ),
              const SizedBox(height: 20),
              MonolithTextField(
                label: 'WEIGHT (KG)',
                hint: 'E.G. 74.5',
                controller: _controller,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  // A body weight needs digits and at most one separator. Letting
                  // the field accept anything and rejecting it at save time would
                  // make the steppers' parse fail for input the user believes is
                  // fine.
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                validator: (value) {
                  final parsed = double.tryParse((value ?? '').trim());
                  if (parsed == null || !WeightEntry.isPlausible(parsed)) {
                    return LogWeightSheet.invalidWeight;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final step in LogWeightSheet.steps)
                    Expanded(
                      child: _StepButton(
                        label: _stepLabel(step),
                        enabled: canStep && !_isSaving,
                        onTap: () => _step(step),
                      ),
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: MonolithTheme.labelMedium
                      .copyWith(color: MonolithTheme.error),
                ),
              ],
              const SizedBox(height: 20),
              MonolithButton(
                label: _isSaving
                    ? LogWeightSheet.savingLabel
                    : LogWeightSheet.saveLabel,
                // Never disabled on an invalid value: the validator is what
                // explains *why* a weight was refused, and it only runs on a
                // press.
                onPressed: _isSaving ? null : _save,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// `-0.5`, `+0.1` — the sign is the button's whole meaning, so it is never
  /// dropped.
  static String _stepLabel(double step) =>
      '${step > 0 ? '+' : '-'}${step.abs().toStringAsFixed(1)}';
}

/// One step control, sized to share a row with the others.
///
/// Flush against its neighbours, the way `FoodQuantityStepper` sets its buttons
/// against the field it steps: in this system two 2px borders meeting reads as a
/// single heavier rule, not as a mistake.
class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Null rather than a no-op, so a disabled control does not report taps its
      // parent would rebuild for.
      onTap: enabled ? onTap : null,
      child: Container(
        height: 48,
        decoration: MonolithTheme.containerDecoration,
        alignment: Alignment.center,
        child: Text(
          label,
          style: MonolithTheme.labelLarge.copyWith(
            color: enabled ? MonolithTheme.primary : MonolithTheme.outline,
          ),
        ),
      ),
    );
  }
}
