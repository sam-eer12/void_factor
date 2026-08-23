import 'package:flutter/material.dart';

import '../models/food_entry.dart';
import '../theme/monolith_theme.dart';

/// `[-] 1.0x [+]` — a serving multiplier, not a gram weight.
///
/// Stateless: the parent owns the value, because the form needs it to recompute
/// the live total alongside the per-serving fields the user is editing. Two
/// copies of the number would be one too many.
class FoodQuantityStepper extends StatelessWidget {
  /// Applied to a step control that cannot do anything at the current value. A
  /// live-looking button that ignores taps reads as a broken screen.
  static const Color disabledColor = MonolithTheme.outline;

  final double quantity;
  final ValueChanged<double> onChanged;

  const FoodQuantityStepper({
    super.key,
    required this.quantity,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Clamped on the way in as well as on the way out, so a stored entry with an
    // out-of-range quantity still renders something sane.
    final current = FoodEntry.clampQuantity(quantity);
    final canDecrease = current > FoodEntry.minQuantity;
    final canIncrease = current < FoodEntry.maxQuantity;

    return Row(
      children: [
        _StepButton(
          icon: Icons.remove,
          enabled: canDecrease,
          onTap: () => onChanged(
            FoodEntry.clampQuantity(current - FoodEntry.quantityStep),
          ),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: MonolithTheme.containerDecoration,
            alignment: Alignment.center,
            child: Text(
              '${current.toStringAsFixed(1)}x',
              style: MonolithTheme.labelLarge,
            ),
          ),
        ),
        _StepButton(
          icon: Icons.add,
          enabled: canIncrease,
          onTap: () => onChanged(
            FoodEntry.clampQuantity(current + FoodEntry.quantityStep),
          ),
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _StepButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Null rather than a no-op callback: at a bound there is nothing to report
      // and the parent should not see a rebuild for a tap that changed nothing.
      onTap: enabled ? onTap : null,
      child: Container(
        width: 52,
        height: 48,
        decoration: MonolithTheme.containerDecoration,
        alignment: Alignment.center,
        child: Icon(
          icon,
          size: 22,
          color: enabled
              ? MonolithTheme.primary
              : FoodQuantityStepper.disabledColor,
        ),
      ),
    );
  }
}
