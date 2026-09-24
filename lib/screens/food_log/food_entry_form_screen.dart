import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/food_log/food_analysis_client.dart';
import '../../features/food_log/food_log_grouping.dart';
import '../../features/food_log/food_log_providers.dart';
import '../../models/food_entry.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/food_quantity_stepper.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_card.dart';
import '../../widgets/monolith_text_field.dart';

/// Builds the form's route from its saved arguments.
///
/// Top level and annotated because `Navigator.restorablePush` finds it again in
/// a fresh process through a callback handle, and AOT compilation drops
/// anything native code reaches that is not marked as an entry point — a static
/// method would need its whole class marked too.
@pragma('vm:entry-point')
Route<void> foodEntryFormRoute(BuildContext context, Object? arguments) {
  return MaterialPageRoute<void>(
    builder: (_) => FoodEntryFormScreen.fromArguments(arguments),
  );
}

/// The one form both logging paths end at.
///
/// Vision arrives with [initialName], [initialNutrients] and [initialQuantity]
/// filled from the model; manual arrives empty. Everything the model proposed
/// is editable, because a photo estimate the user cannot correct is worse than
/// no estimate.
///
/// Pushed through [restorableRoute] rather than a named route: the constructor
/// stays typed, and only the trip through saved state — which Android makes
/// when it kills the app in the background — goes through a plain map, in
/// [scanArguments], [manualArguments] and [editArguments].
class FoodEntryFormScreen extends ConsumerStatefulWidget {
  final String initialName;

  /// Per **one** serving. The quantity multiplier is applied for display and
  /// stored beside these figures, never folded into them.
  final Nutrients initialNutrients;

  /// How many servings to start the stepper on.
  ///
  /// Vision passes the count the model read off the plate; manual entry starts
  /// at one. Only a starting point — the stepper owns it from the first tap.
  final double initialQuantity;

  final FoodSource source;

  /// Set when correcting an entry that already exists.
  ///
  /// Its presence is what distinguishes the two modes, so there is no separate
  /// `isEditing` flag that could disagree with it. The saved entry keeps this
  /// entry's id and `loggedAt`: an edit changes what a meal *was*, not when it
  /// happened, and a new id would leave the original behind as a duplicate.
  final FoodEntry? editing;

  const FoodEntryFormScreen({
    super.key,
    this.initialName = '',
    this.initialNutrients = const Nutrients(),
    this.initialQuantity = 1.0,
    required this.source,
    this.editing,
  });

  /// Opens the form on an existing entry, pre-filled with everything it holds.
  FoodEntryFormScreen.edit(FoodEntry entry, {Key? key})
      : this(
          key: key,
          initialName: entry.name,
          initialNutrients: entry.nutrients,
          source: entry.source,
          editing: entry,
        );

  /// The form as one of the argument maps below describes it.
  factory FoodEntryFormScreen.fromArguments(Object? arguments) {
    final args = _stringKeyed(arguments) ?? const <String, dynamic>{};

    final editing = args['editing'];
    if (editing is Map<String, dynamic>) {
      final entry = FoodEntry.tryFromMap(editing);
      if (entry != null) return FoodEntryFormScreen.edit(entry);
    }

    final nutrients = args['nutrients'];
    final quantity = args['quantity'];
    return FoodEntryFormScreen(
      initialName: args['name']?.toString() ?? '',
      initialNutrients: nutrients is Map<String, dynamic>
          ? Nutrients.fromMap(nutrients)
          : const Nutrients(),
      initialQuantity: quantity is num ? quantity.toDouble() : 1.0,
      source: FoodSource.fromWire(args['source']),
    );
  }

  /// What a scan read off the plate.
  static Map<String, Object?> scanArguments(FoodAnalysis draft) => {
        'name': draft.name,
        'nutrients': draft.nutrients.toMap(),
        'quantity': draft.quantity,
        'source': FoodSource.vision.wireValue,
      };

  /// A blank manual entry.
  static final Map<String, Object?> manualArguments = {
    'source': FoodSource.manual.wireValue,
  };

  /// A correction to an entry already logged.
  static Map<String, Object?> editArguments(FoodEntry entry) => {
        'editing': entry.toMap(),
      };

  /// For `Navigator.restorablePush`. See [foodEntryFormRoute].
  static const RestorableRouteBuilder<void> restorableRoute = foodEntryFormRoute;

  /// Saved state comes back with `Object?` keys all the way down, which
  /// [FoodEntry.tryFromMap] and [Nutrients.fromMap] would read as absent.
  static Map<String, dynamic>? _stringKeyed(Object? value) {
    if (value is! Map) return null;
    return {
      for (final MapEntry(:key, :value) in value.entries)
        key.toString(): value is Map ? _stringKeyed(value) : value,
    };
  }

  @override
  ConsumerState<FoodEntryFormScreen> createState() =>
      _FoodEntryFormScreenState();
}

class _FoodEntryFormScreenState extends ConsumerState<FoodEntryFormScreen>
    with RestorationMixin {
  static const String saveLabel = 'SAVE ENTRY';
  static const String saveEditLabel = 'SAVE CHANGES';
  static const String editTitle = 'EDIT ENTRY';

  final _formKey = GlobalKey<FormState>();

  // Restorable, so what the user has typed survives the app being killed in
  // the background — the route comes back through its arguments, and the
  // fields come back as they were left rather than as they were seeded.
  late final _nameController =
      RestorableTextEditingController(text: widget.initialName);
  late final _caloriesController = RestorableTextEditingController(
      text: _seed(widget.initialNutrients.calories));
  late final _proteinController = RestorableTextEditingController(
      text: _seed(widget.initialNutrients.proteinG));
  late final _carbsController = RestorableTextEditingController(
      text: _seed(widget.initialNutrients.carbsG));
  late final _fatsController = RestorableTextEditingController(
      text: _seed(widget.initialNutrients.fatsG));

  // An edit already has a quantity the user chose, and it outranks anything a
  // caller seeded.
  late final _quantity = RestorableDouble(
      widget.editing?.quantity ?? FoodEntry.clampQuantity(widget.initialQuantity));
  bool _isSaving = false;

  @override
  String? get restorationId => 'food_entry_form';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_nameController, 'name');
    registerForRestoration(_caloriesController, 'calories');
    registerForRestoration(_proteinController, 'protein');
    registerForRestoration(_carbsController, 'carbs');
    registerForRestoration(_fatsController, 'fats');
    registerForRestoration(_quantity, 'quantity');
  }

  @override
  void initState() {
    super.initState();
    // The total is the number the user is actually deciding about, so it has to
    // follow the fields rather than the values the model first proposed.
    // Listened to on the restorable wrappers, which forward their controller's
    // changes and outlive the controller a restore swaps in.
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
    _quantity.dispose();
    super.dispose();
  }

  List<RestorableTextEditingController> get _numericControllers => [
        _caloriesController,
        _proteinController,
        _carbsController,
        _fatsController,
      ];

  void _onNutrientsChanged() => setState(() {});

  /// A zero seeds as an empty field, not `"0"`. A manual entry starts blank so
  /// the user can type straight into it instead of clearing a placeholder first.
  static String _seed(double value) => value == 0 ? '' : _format(value);

  /// Trims a pointless decimal: `45.0` reads `45`, `7.5` stays `7.5`. Shared with
  /// the two log lists so the same figure never renders two ways.
  static String _format(double value) => foodLogAmountLabel(value);

  static double _parse(String raw) => double.tryParse(raw.trim()) ?? 0;

  Nutrients get _perServing => Nutrients(
        calories: _parse(_caloriesController.value.text),
        proteinG: _parse(_proteinController.value.text),
        carbsG: _parse(_carbsController.value.text),
        fatsG: _parse(_fatsController.value.text),
      );

  /// The entry as it stands. Used for the live preview and for the save, so what
  /// the user reads above the button is arithmetically the thing that gets
  /// written — not a second calculation that could drift from it.
  FoodEntry _draft() {
    final edited = widget.editing;
    if (edited != null) {
      // copyWith, not create: a new id would orphan the original as a duplicate,
      // and a new timestamp would move the meal to a day it was not eaten on.
      return edited.copyWith(
        name: _nameController.value.text.trim(),
        nutrients: _perServing,
        quantity: _quantity.value,
      );
    }
    return FoodEntry.create(
      name: _nameController.value.text,
      nutrients: _perServing,
      quantity: _quantity.value,
      source: widget.source,
    );
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _isSaving = true);
    try {
      final log = ref.read(recentFoodLogProvider.notifier);
      final draft = _draft();
      await (widget.editing == null ? log.add(draft) : log.replace(draft));
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
                restorationId: 'food_entry_form_scroll',
                padding: const EdgeInsets.all(20),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MonolithTextField(
                        label: 'NAME',
                        hint: 'WHAT DID YOU EAT?',
                        controller: _nameController.value,
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
                        controller: _caloriesController.value,
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
                          Expanded(child: _macroField('PROTEIN', _proteinController.value)),
                          const SizedBox(width: 12),
                          Expanded(child: _macroField('CARBS', _carbsController.value)),
                          const SizedBox(width: 12),
                          Expanded(child: _macroField('FATS', _fatsController.value)),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Text('QUANTITY', style: MonolithTheme.labelMedium),
                      const SizedBox(height: 8),
                      FoodQuantityStepper(
                        quantity: _quantity.value,
                        onChanged: (value) => setState(() => _quantity.value = value),
                      ),
                      const SizedBox(height: 24),
                      _totalCard(draft),
                      const SizedBox(height: 24),
                      MonolithButton(
                        label: widget.editing == null ? saveLabel : saveEditLabel,
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
            // doing the work; an editor is correcting something already logged.
            // The title says which.
            widget.editing != null
                ? editTitle
                : widget.source == FoodSource.vision
                    ? 'CONFIRM ENTRY'
                    : 'ADD ENTRY',
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
