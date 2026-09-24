import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_card.dart';
import '../../widgets/monolith_text_field.dart';
import '../../features/profile/profile_repository.dart';
import '../../features/auth/session_provider.dart';
import '../../models/user_profile.dart';

/// Edits the user's goal & diet fields: weight goal, target weight, weekly
/// rate, and allergies. Physical metrics live on EditProfileScreen; saves here
/// preserve them via UserProfile.copyWith on the loaded profile.
class GoalsDietScreen extends ConsumerStatefulWidget {
  const GoalsDietScreen({super.key});

  @override
  ConsumerState<GoalsDietScreen> createState() => _GoalsDietScreenState();
}

class _GoalsDietScreenState extends ConsumerState<GoalsDietScreen>
    with RestorationMixin {
  // Restorable, so edits in progress survive Android killing the app in the
  // background. `_prefilled` is restored with them: a restored form must keep
  // what the user chose, not be overwritten by the saved profile again.
  final _targetWeight = RestorableTextEditingController();
  final _goalValue = RestorableEnum<WeightGoal>(
    WeightGoal.maintain,
    values: WeightGoal.values,
  );
  final _weeklyRateValue = RestorableDouble(0.5);
  final _allergiesValue = _RestorableStringSet();
  final _prefilledValue = RestorableBool(false);

  TextEditingController get _targetWeightController => _targetWeight.value;
  WeightGoal get _goal => _goalValue.value;
  set _goal(WeightGoal value) => _goalValue.value = value;
  double get _weeklyRate => _weeklyRateValue.value;
  set _weeklyRate(double value) => _weeklyRateValue.value = value;
  Set<String> get _allergies => _allergiesValue.value;
  set _allergies(Set<String> value) => _allergiesValue.value = value;
  bool get _prefilled => _prefilledValue.value;
  set _prefilled(bool value) => _prefilledValue.value = value;

  bool _isSaving = false;

  @override
  String? get restorationId => 'goals_diet';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_targetWeight, 'target_weight');
    registerForRestoration(_goalValue, 'goal');
    registerForRestoration(_weeklyRateValue, 'weekly_rate');
    registerForRestoration(_allergiesValue, 'allergies');
    registerForRestoration(_prefilledValue, 'prefilled');
  }

  @override
  void dispose() {
    _targetWeight.dispose();
    _goalValue.dispose();
    _weeklyRateValue.dispose();
    _allergiesValue.dispose();
    _prefilledValue.dispose();
    super.dispose();
  }

  void _prefill(UserProfile profile) {
    if (_prefilled) return;
    _prefilled = true;
    _goal = profile.goal;
    _weeklyRate = profile.weeklyRate;
    _targetWeightController.text =
        profile.targetWeight > 0 ? _trim(profile.targetWeight) : '';
    _allergies = {...profile.allergies};
  }

  String _trim(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  Future<void> _save() async {
    final targetWeight = double.tryParse(_targetWeightController.text.trim());
    if (targetWeight == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid target weight.')),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      final repository = ref.read(profileRepositoryProvider);
      final current = await repository.load();
      final updated = current.copyWith(
        goal: _goal,
        targetWeight: targetWeight,
        weeklyRate: _weeklyRate,
        allergies: _allergies.toList(),
      );
      await repository.save(updated);
      ref.invalidate(profileProvider);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Goals & diet updated.')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save goals: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(profileProvider);

    return Scaffold(
      backgroundColor: MonolithTheme.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // ── Top Bar ──
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
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
                  Text('GOALS & DIET', style: MonolithTheme.headlineLarge),
                ],
              ),
            ),
            Expanded(
              child: profileAsync.when(
                loading: () => const Center(
                  child: CircularProgressIndicator.adaptive(
                    valueColor:
                        AlwaysStoppedAnimation<Color>(MonolithTheme.primary),
                  ),
                ),
                error: (e, s) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Could not load profile.\n$e',
                      textAlign: TextAlign.center,
                      style: MonolithTheme.bodyMedium
                          .copyWith(color: MonolithTheme.outline),
                    ),
                  ),
                ),
                data: (profile) {
                  _prefill(profile);
                  return _buildForm();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Goal ──
          Text('OBJECTIVE', style: MonolithTheme.headlineMedium),
          const SizedBox(height: 16),
          MonolithCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('WEIGHT GOAL', style: MonolithTheme.labelMedium),
                const SizedBox(height: 8),
                _GoalSelector(
                  selected: _goal,
                  onChanged: (g) => setState(() => _goal = g),
                ),
                const SizedBox(height: 20),
                MonolithTextField(
                  label: 'Target Weight (kg)',
                  hint: '65',
                  controller: _targetWeightController,
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 20),
                Text('WEEKLY RATE', style: MonolithTheme.labelMedium),
                const SizedBox(height: 8),
                _RateSelector(
                  selected: _weeklyRate,
                  onChanged: (r) => setState(() => _weeklyRate = r),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── Allergies ──
          Text('ALLERGIES', style: MonolithTheme.headlineMedium),
          const SizedBox(height: 4),
          Text(
            'SELECT ALL THAT APPLY',
            style:
                MonolithTheme.labelSmall.copyWith(color: MonolithTheme.outline),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: UserProfile.allergyOptions.map((allergy) {
              final isSelected = _allergies.contains(allergy);
              return GestureDetector(
                // Reassigned rather than mutated, so the restorable copy
                // hears about it.
                onTap: () => setState(() {
                  _allergies = isSelected
                      ? ({..._allergies}..remove(allergy))
                      : {..._allergies, allergy};
                }),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? MonolithTheme.primary
                        : MonolithTheme.surface,
                    border: Border.all(
                      color: MonolithTheme.primary,
                      width: MonolithTheme.borderWidth,
                    ),
                  ),
                  child: Text(
                    allergy.toUpperCase(),
                    style: MonolithTheme.labelMedium.copyWith(
                      color: isSelected
                          ? MonolithTheme.surface
                          : MonolithTheme.primary,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 32),

          if (_isSaving)
            const Center(
              child: CircularProgressIndicator.adaptive(
                valueColor:
                    AlwaysStoppedAnimation<Color>(MonolithTheme.primary),
              ),
            )
          else
            MonolithButton(label: 'SAVE CHANGES', onPressed: _save),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// LOSE / MAINTAIN / GAIN segmented selector.
class _GoalSelector extends StatelessWidget {
  final WeightGoal selected;
  final ValueChanged<WeightGoal> onChanged;
  const _GoalSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: WeightGoal.values.map((goal) {
        final isSelected = selected == goal;
        final isLast = goal == WeightGoal.values.last;
        return Expanded(
          child: GestureDetector(
            onTap: () => onChanged(goal),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              margin: EdgeInsets.only(right: isLast ? 0 : 6),
              decoration: BoxDecoration(
                color:
                    isSelected ? MonolithTheme.primary : MonolithTheme.surface,
                border: Border.all(
                  color: MonolithTheme.primary,
                  width: MonolithTheme.borderWidth,
                ),
              ),
              child: Center(
                child: Text(
                  goal.name.toUpperCase(),
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
}

/// 0.25 / 0.5 / 0.75 kg-per-week segmented selector.
class _RateSelector extends StatelessWidget {
  final double selected;
  final ValueChanged<double> onChanged;
  const _RateSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: UserProfile.weeklyRateOptions.map((rate) {
        final isSelected = selected == rate;
        final isLast = rate == UserProfile.weeklyRateOptions.last;
        return Expanded(
          child: GestureDetector(
            onTap: () => onChanged(rate),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              margin: EdgeInsets.only(right: isLast ? 0 : 6),
              decoration: BoxDecoration(
                color:
                    isSelected ? MonolithTheme.primary : MonolithTheme.surface,
                border: Border.all(
                  color: MonolithTheme.primary,
                  width: MonolithTheme.borderWidth,
                ),
              ),
              child: Center(
                child: Text(
                  '$rate KG/WK',
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
}

/// The selected allergies, kept across a restore as a plain list.
class _RestorableStringSet extends RestorableValue<Set<String>> {
  @override
  Set<String> createDefaultValue() => <String>{};

  @override
  void didUpdateValue(Set<String>? oldValue) => notifyListeners();

  @override
  Set<String> fromPrimitives(Object? data) =>
      {...?(data as List<Object?>?)?.whereType<String>()};

  @override
  Object toPrimitives() => value.toList();
}
