import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_card.dart';
import '../../widgets/monolith_text_field.dart';
import '../../features/profile/profile_repository.dart';
import '../../features/auth/session_provider.dart';
import '../../models/user_profile.dart';

/// Edits the user's physical metrics (height, weight, age, gender).
/// The goal/diet fields live on [GoalsDietScreen]; saves here only touch these
/// fields because they go through UserProfile.copyWith on the loaded profile.
class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  final _heightController = TextEditingController();
  final _weightController = TextEditingController();
  final _ageController = TextEditingController();
  String _gender = 'MALE';

  bool _prefilled = false;
  bool _isSaving = false;

  @override
  void dispose() {
    _heightController.dispose();
    _weightController.dispose();
    _ageController.dispose();
    super.dispose();
  }

  void _prefill(UserProfile profile) {
    if (_prefilled) return;
    _prefilled = true;
    _heightController.text = profile.height > 0 ? _trim(profile.height) : '';
    _weightController.text = profile.weight > 0 ? _trim(profile.weight) : '';
    _ageController.text = profile.age > 0 ? profile.age.toString() : '';
    _gender = profile.gender;
  }

  String _trim(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  Future<void> _save() async {
    final height = double.tryParse(_heightController.text.trim());
    final weight = double.tryParse(_weightController.text.trim());
    final age = int.tryParse(_ageController.text.trim());

    if (height == null || weight == null || age == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter valid physical metrics.')),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      final repository = ref.read(profileRepositoryProvider);
      // Load the full current profile so goal/diet fields are preserved, then
      // overwrite only the metrics owned by this screen.
      final current = await repository.load();
      final updated = current.copyWith(
        height: height,
        weight: weight,
        age: age,
        gender: _gender,
      );
      await repository.save(updated);
      ref.invalidate(profileProvider);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile updated.')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save profile: $e')),
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
            _TopBar(title: 'EDIT PROFILE'),
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
          Text('PHYSICAL METRICS', style: MonolithTheme.headlineMedium),
          const SizedBox(height: 16),
          MonolithCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: MonolithTextField(
                        label: 'Height (cm)',
                        hint: '175',
                        controller: _heightController,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: MonolithTextField(
                        label: 'Weight (kg)',
                        hint: '70',
                        controller: _weightController,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                MonolithTextField(
                  label: 'Age',
                  hint: '25',
                  controller: _ageController,
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 20),
                Text('GENDER', style: MonolithTheme.labelMedium),
                const SizedBox(height: 8),
                _GenderSelector(
                  selected: _gender,
                  onChanged: (g) => setState(() => _gender = g),
                ),
              ],
            ),
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

/// Shared top bar for the settings edit screens.
class _TopBar extends StatelessWidget {
  final String title;
  const _TopBar({required this.title});

  @override
  Widget build(BuildContext context) {
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
              child: const Icon(Icons.arrow_back,
                  color: MonolithTheme.primary, size: 22),
            ),
          ),
          const SizedBox(width: 16),
          Text(title, style: MonolithTheme.headlineLarge),
        ],
      ),
    );
  }
}

/// MALE / FEMALE / OTHER segmented selector.
class _GenderSelector extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onChanged;
  const _GenderSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const genders = ['MALE', 'FEMALE', 'OTHER'];
    return Row(
      children: genders.map((gender) {
        final isSelected = selected == gender;
        return Expanded(
          child: GestureDetector(
            onTap: () => onChanged(gender),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              margin: EdgeInsets.only(right: gender != 'OTHER' ? 8 : 0),
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
                  gender,
                  style: MonolithTheme.labelMedium.copyWith(
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
