import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/monolith_theme.dart';
import 'gemma_model_service.dart';
import 'model_artifact.dart';
import 'model_terms_store.dart';

Future<void> showGemmaAgreement(BuildContext context) => _showBundledDocument(
  context,
  'GEMMA TERMS OF USE',
  'assets/legal/GEMMA_TERMS_2026-04-01.txt',
);

Future<void> showGemmaUseRestrictions(BuildContext context) =>
    _showBundledDocument(
      context,
      'VOID FACTOR MODEL TERMS',
      'assets/legal/VOID_FACTOR_MODEL_TERMS.txt',
    );

Future<void> _showBundledDocument(
  BuildContext context,
  String title,
  String asset,
) async {
  final text = await rootBundle.loadString(asset);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: MonolithTheme.surface,
      title: Text(title, style: MonolithTheme.headlineMedium),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: SelectableText(text, style: MonolithTheme.bodyMedium),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CLOSE'),
        ),
      ],
    ),
  );
}

abstract class ModelDownloadConsent {
  Future<bool> ensureAccepted(BuildContext context);
}

class GemmaDownloadConsent implements ModelDownloadConsent {
  GemmaDownloadConsent(this._store);

  final ModelTermsStore _store;

  @override
  Future<bool> ensureAccepted(BuildContext context) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return false;
    final artifact = await ModelArtifact.bundled();
    if (await _store.hasAccepted(uid, artifact.termsVersion)) return true;
    if (!context.mounted) return false;

    final accepted = await showDialog<bool>(
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
        title: Text('GEMMA TERMS', style: MonolithTheme.headlineMedium),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'VERSION ${artifact.termsVersion}. THIS DOWNLOAD IS ABOUT 584 MB. '
                'THE MODEL RUNS ON YOUR DEVICE AFTER DOWNLOAD.',
                style: MonolithTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'BY CONTINUING, YOU AGREE TO THE VOID FACTOR MODEL TERMS, '
                'GEMMA TERMS OF USE AND '
                'PROHIBITED USE POLICY. DO NOT USE THE MODEL FOR ILLEGAL, '
                'HARMFUL, EXPLOITATIVE, OR RIGHTS-INFRINGING CONTENT. '
                'THESE RESTRICTIONS APPLY TO YOUR USE OF THE MODEL.',
                style: MonolithTheme.bodyMedium,
              ),
              TextButton(
                onPressed: () => showGemmaAgreement(context),
                child: const Text('READ GEMMA AGREEMENT'),
              ),
              TextButton(
                onPressed: () => showGemmaUseRestrictions(context),
                child: const Text('READ APP TERMS & USE RESTRICTIONS'),
              ),
              TextButton(
                onPressed: () => launchUrl(
                  Uri.parse('https://ai.google.dev/gemma/terms'),
                  mode: LaunchMode.externalApplication,
                ),
                child: const Text('CURRENT TERMS ONLINE'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('AGREE & DOWNLOAD MODEL'),
          ),
        ],
      ),
    );
    if (accepted != true || FirebaseAuth.instance.currentUser?.uid != uid) {
      return false;
    }
    await _store.accept(uid, artifact.termsVersion);
    return true;
  }
}

final modelDownloadConsentProvider = Provider<ModelDownloadConsent>((ref) {
  return GemmaDownloadConsent(ref.watch(modelTermsStoreProvider));
});

Future<void> agreeAndDownloadModel(BuildContext context, WidgetRef ref) async {
  if (!await ref.read(modelDownloadConsentProvider).ensureAccepted(context)) {
    return;
  }
  if (!context.mounted) return;
  await ref.read(gemmaModelProvider.notifier).download();
}
