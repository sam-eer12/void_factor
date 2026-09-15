import 'package:flutter/material.dart';

import '../../features/legal/privacy_policy.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_card.dart';

/// Settings → Privacy → Privacy Policy. The document itself.
///
/// Distinct from [PrivacyScreen], which is where data is exported, imported or
/// destroyed. This screen makes no promises it has to keep at runtime; it is
/// the text, rendered.
///
/// It exists in the app as well as on the web because a policy reachable only
/// through a browser is a policy nobody reads on a plane, and because the
/// hosted copy going down should not take the disclosure with it. The text
/// comes from [PrivacyPolicy], which the hosted page is generated from — see
/// `tool/privacy_policy_html.dart`.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  static const String title = 'PRIVACY POLICY';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MonolithTheme.background,
      appBar: AppBar(
        backgroundColor: MonolithTheme.background,
        elevation: 0,
        title: Text(title, style: MonolithTheme.headlineMedium),
      ),
      // Selectable throughout, so the contact address can be copied rather than
      // transcribed by hand from a screenshot.
      body: SelectionArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'EFFECTIVE ${PrivacyPolicy.effectiveDate}',
                style: MonolithTheme.labelSmall.copyWith(
                  color: MonolithTheme.outline,
                ),
              ),
              const SizedBox(height: 16),
              for (final section in PrivacyPolicy.sections) ...[
                _section(section),
                const SizedBox(height: 16),
              ],
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(PolicySection section) {
    return MonolithCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(section.title, style: MonolithTheme.labelLarge),
          const SizedBox(height: 12),
          for (final paragraph in section.paragraphs) ...[
            Text(paragraph, style: MonolithTheme.bodyMedium),
            if (paragraph != section.paragraphs.last)
              const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}
