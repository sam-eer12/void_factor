import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/food_log/food_analysis_client.dart';
import '../../features/food_log/food_log_providers.dart';
import '../../models/food_entry.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/food_quantity_stepper.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_card.dart';
import '../../widgets/monolith_text_field.dart';

/// The one form both logging paths end at.
///
/// Vision arrives with [initialName] and [initialNutrients] filled from the
/// model; manual arrives empty. Everything the model proposed is editable,
/// because a photo estimate the user cannot correct is worse than no estimate.
///
/// Pushed as a plain [MaterialPageRoute] rather than a named route: the
/// arguments are typed, and a named route would flatten them into
/// `Object? arguments` and lose that.
class FoodEntryFormScreen extends ConsumerStatefulWidget {
  final String initialName;

  /// Per **one** serving. The quantity multiplier is applied for display and
  /// stored beside these figures, never folded into them.
  final Nutrients initialNutrients;

  final FoodSource source;

  const FoodEntryFormScreen({
    super.key,
    this.initialName = '',
    this.initialNutrients = const Nutrients(),
    required this.source,
  });

  @override
  ConsumerState<FoodEntryFormScreen> createState() =>
      _FoodEntryFormScreenState();
}

class _FoodEntryFormScreenState extends ConsumerState<FoodEntryFormScreen> {
  static const String saveLabel = 'SAVE ENTRY';

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _caloriesController = TextEditingController();
  final _proteinController = TextEditingController();
  final _carbsController = TextEditingController();
  final _fatsController = TextEditingController();

  double _quantity = 1.0;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _nameController.text = widget.initialName;
    _caloriesController.text = _seed(widget.initialNutrients.calories);
    _proteinController.text = _seed(widget.initialNutrients.proteinG);
    _carbsController.text = _seed(widget.initialNutrients.carbsG);
    _fatsController.text = _seed(widget.initialNutrients.fatsG);

    // The total is the number the user is actually deciding about, so it has to
    // follow the fields rather than the values the model first proposed.
    for (final controller in _numericControllers) {
      controller.addListener(_onNutrientsChanged);
    }
  }

  @override
  void dispose() {
    for (final controller in _numericControllers) {
      controller.removeListener(_onNutrientsChanged);
      controller.dispose();
    }
    _nameController.dispose();
    super.dispose();
  }

  List<TextEditingController> get _numericControllers => [
        _caloriesController,
        _proteinController,
        _carbsController,
        _fatsController,
      ];

  void _onNutrientsChanged() => setState(() {});

  /// A zero seeds as an empty field, not `"0"`. A manual entry starts blank so
  /// the user can type straight into it instead of clearing a placeholder first.
  static String _seed(double value) => value == 0 ? '' : _format(value);

  /// Trims a pointless decimal: `45.0` reads `45`, `7.5` stays `7.5`.
  static String _format(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);

  static double _parse(String raw) => double.tryParse(raw.trim()) ?? 0;

  Nutrients get _perServing => Nutrients(
        calories: _parse(_caloriesController.text),
        proteinG: _parse(_proteinController.text),
        carbsG: _parse(_carbsController.text),
        fatsG: _parse(_fatsController.text),
      );

  /// The entry as it stands. Used for the live preview and for the save, so what
  /// the user reads above the button is arithmetically the thing that gets
  /// written — not a second calculation that could drift from it.
  FoodEntry _draft() => FoodEntry.create(
        name: _nameController.text,
        nutrients: _perServing,
        quantity: _quantity,
        source: widget.source,
      );

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _isSaving = true);
    try {
      await ref.read(recentFoodLogProvider.notifier).add(_draft());
      if (!mounted) return;
      Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      // Staying put with the fields intact: the entry exists nowhere yet, and
      // popping would report a save that did not happen.
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          error is FoodAnalysisException
              ? error.message
              : RecentFoodLog.errorSaveFailed,
        ),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft();

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
                      MonolithTextField(
                        label: 'NAME',
                        hint: 'WHAT DID YOU EAT?',
                        controller: _nameController,
                        validator: (value) =>
                            (value == null || value.trim().isEmpty)
                                ? 'REQUIRED'
                                : null,
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'PER SERVING',
                        style: MonolithTheme.labelMedium.copyWith(
                          color: MonolithTheme.outline,
                        ),
                      ),
                      const SizedBox(height: 12),
                      MonolithTextField(
                        label: 'KCAL',
                        controller: _caloriesController,
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                        validator: (value) {
                          final parsed = double.tryParse(value?.trim() ?? '');
                          // Macros may be zero — a black coffee is real. Zero
                          // calories is not: it would log nothing at all.
                          return (parsed == null || parsed <= 0)
                              ? 'REQUIRED'
                              : null;
                        },
                      ),
                      const SizedBox(height: 16),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _macroField('PROTEIN', _proteinController)),
                          const SizedBox(width: 12),
                          Expanded(child: _macroField('CARBS', _carbsController)),
                          const SizedBox(width: 12),
                          Expanded(child: _macroField('FATS', _fatsController)),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Text('QUANTITY', style: MonolithTheme.labelMedium),
                      const SizedBox(height: 8),
                      FoodQuantityStepper(
                        quantity: _quantity,
                        onChanged: (value) => setState(() => _quantity = value),
                      ),
                      const SizedBox(height: 24),
                      _totalCard(draft),
                      const SizedBox(height: 24),
                      MonolithButton(
                        label: saveLabel,
                        isExpanded: true,
                        onPressed: _isSaving ? null : _save,
                      ),
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

  Widget _topBar() {
    return Container(
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
          Text(
            // Vision users are checking work the model did; manual users are
            // doing the work. The title says which.
            widget.source == FoodSource.vision ? 'CONFIRM ENTRY' : 'ADD ENTRY',
            style: MonolithTheme.headlineLarge,
          ),
        ],
      ),
    );
  }

  Widget _macroField(String label, TextEditingController controller) {
    return MonolithTextField(
      label: label,
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
    );
  }

  Widget _totalCard(FoodEntry draft) {
    return MonolithCard(
      inverted: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'TOTAL',
            style: MonolithTheme.labelMedium.copyWith(
              color: MonolithTheme.surface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${_format(draft.totalCalories)} KCAL',
            style: MonolithTheme.displayMedium.copyWith(
              color: MonolithTheme.surface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${_format(draft.totalProteinG)}G PROTEIN · '
            '${_format(draft.totalCarbsG)}G CARBS · '
            '${_format(draft.totalFatsG)}G FATS',
            style: MonolithTheme.labelSmall.copyWith(
              color: MonolithTheme.surfaceContainerHigh,
            ),
          ),
        ],
      ),
    );
  }
}
