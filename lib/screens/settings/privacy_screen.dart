import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/routes.dart';
import '../../features/data_transfer/data_bundle.dart';
import '../../features/data_transfer/data_transfer_providers.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_card.dart';
import 'delete_account_dialog.dart';

/// Settings → Privacy. Where the user's data leaves, arrives, or is destroyed.
///
/// The settings row that leads here has always advertised "Data management &
/// export" and done nothing. The export half matters more than it sounds: the
/// food and weight logs are per-device files with no sync, so until this screen
/// existed a reinstall destroyed the entire history with no way back.
class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  static const String readPolicyLabel = 'READ THE FULL POLICY';
  static const String exportedLabel = 'EXPORT READY';
  static const String nothingImportedLabel =
      'NOTHING NEW — YOU ALREADY HAD ALL OF IT';

  /// What the user is told after an import. Counts what was *added*, because
  /// after re-importing a file they already hold, "added 0" is the true and
  /// reassuring answer and "imported 200" is a lie.
  static String importedLabel(ImportSummary summary) {
    if (summary.changedNothing) return nothingImportedLabel;
    final parts = <String>[
      if (summary.foodEntriesAdded > 0)
        '${summary.foodEntriesAdded} '
            '${summary.foodEntriesAdded == 1 ? 'MEAL' : 'MEALS'}',
      if (summary.weightEntriesAdded > 0)
        '${summary.weightEntriesAdded} '
            '${summary.weightEntriesAdded == 1 ? 'WEIGH-IN' : 'WEIGH-INS'}',
    ];
    return 'ADDED ${parts.join(' AND ')}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(dataTransferProvider).isLoading;

    return Scaffold(
      backgroundColor: MonolithTheme.background,
      appBar: AppBar(
        backgroundColor: MonolithTheme.background,
        elevation: 0,
        title: Text('PRIVACY', style: MonolithTheme.headlineMedium),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _whereYourDataLives(),
            const SizedBox(height: 24),
            _exportCard(context, ref, busy),
            const SizedBox(height: 16),
            _importCard(context, ref, busy),
            const SizedBox(height: 24),
            _policyCard(context),
            const SizedBox(height: 24),
            _deleteCard(context, ref),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _whereYourDataLives() {
    return MonolithCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('WHERE YOUR DATA LIVES', style: MonolithTheme.labelLarge),
          const SizedBox(height: 12),
          Text(
            'Your meals and weigh-ins are stored only on this phone. They are '
            'never uploaded, which also means nothing restores them if you '
            'reinstall or switch devices. Export is how you keep a copy.',
            style: MonolithTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Text(
            'Your profile syncs to your account and comes back when you sign '
            'in. Your provider API key never leaves this device.',
            style: MonolithTheme.bodyMedium.copyWith(
              color: MonolithTheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  /// The policy proper. It sits after the export/import controls because
  /// someone who opened this screen came to do something, not to read; and
  /// before the delete box because the danger zone stays terminal — nothing
  /// invites a tap below "DELETE EVERYTHING".
  Widget _policyCard(BuildContext context) {
    return MonolithCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.description_outlined,
                  color: MonolithTheme.primary, size: 20),
              const SizedBox(width: 12),
              Text('PRIVACY POLICY', style: MonolithTheme.headlineMedium),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'The whole document: what your account stores, what stays on this '
            'phone, and what happens to a food photo after you scan it.',
            style: MonolithTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          MonolithButton(
            label: readPolicyLabel,
            style: MonolithButtonStyle.secondary,
            onPressed: () =>
                Navigator.pushNamed(context, AppRoutes.privacyPolicy),
          ),
        ],
      ),
    );
  }

  Widget _exportCard(BuildContext context, WidgetRef ref, bool busy) {
    return MonolithCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.upload_file,
                  color: MonolithTheme.primary, size: 20),
              const SizedBox(width: 12),
              Text('EXPORT', style: MonolithTheme.headlineMedium),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Writes one file holding your profile, every meal and every '
            'weigh-in, then hands it to your share sheet.',
            style: MonolithTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          MonolithButton(
            label: 'EXPORT MY DATA',
            onPressed: busy ? null : () => _export(context, ref),
          ),
        ],
      ),
    );
  }

  Widget _importCard(BuildContext context, WidgetRef ref, bool busy) {
    return MonolithCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.download, color: MonolithTheme.primary, size: 20),
              const SizedBox(width: 12),
              Text('IMPORT', style: MonolithTheme.headlineMedium),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Adds anything in the file that this phone does not already have. '
            'Nothing is replaced or deleted, so importing twice is safe.',
            style: MonolithTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          MonolithButton(
            label: 'IMPORT A FILE',
            style: MonolithButtonStyle.secondary,
            onPressed: busy ? null : () => _import(context, ref),
          ),
        ],
      ),
    );
  }

  Widget _deleteCard(BuildContext context, WidgetRef ref) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        border: Border.all(
          color: MonolithTheme.error,
          width: MonolithTheme.borderWidth,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'DELETE EVERYTHING',
            style: MonolithTheme.labelLarge.copyWith(
              color: MonolithTheme.error,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Removes your account, your profile, and every meal and weigh-in '
            'on this device. Export first if you want a copy.',
            style: MonolithTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          MonolithButton(
            label: 'DELETE ACCOUNT',
            style: MonolithButtonStyle.tertiary,
            onPressed: () => DeleteAccountDialog.showAndPerform(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(dataTransferProvider.notifier).export();
      messenger.showSnackBar(const SnackBar(content: Text(exportedLabel)));
    } on DataTransferException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final summary = await ref.read(dataTransferProvider.notifier).import();
      // Null means the picker was dismissed: a deliberate choice, so nothing
      // happens and nothing is said.
      if (summary == null) return;
      messenger.showSnackBar(SnackBar(content: Text(importedLabel(summary))));
    } on DataTransferException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}
