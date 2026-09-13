import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../features/support/support_links.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_bottom_nav.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_card.dart';

/// Supporting the project, with destinations that exist.
///
/// Everything on this screen used to be decoration: an `Icons.qr_code_2` glyph
/// captioned "UPI QR CODE", a `donate@monolith` handle belonging to nobody, and
/// PAYPAL / STRIPE / CRYPTO rows with no tap handler at all — the builder that
/// drew them accepted no callback. Anyone who acted on it sent money nowhere.
///
/// Now the QR encodes the same `upi://pay` URI the button opens, so the scanned
/// and tapped paths cannot disagree. When no destination is configured the
/// screen says so rather than showing a plausible-looking one.
class DonationScreen extends StatelessWidget {
  const DonationScreen({super.key});

  static const String unconfiguredTitle = 'NOT ACCEPTING SUPPORT YET';
  static const String unconfiguredBody =
      'There is no donation destination set up. Nothing here would reach '
      'anyone, so nothing is shown.';
  static const String couldNotOpenUpi =
      'NO UPI APP FOUND — SCAN THE CODE INSTEAD';
  static const String couldNotOpenLink = "COULDN'T OPEN THAT LINK";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MonolithTheme.background,
      extendBody: true,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _topBar(context),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('SUPPORT', style: MonolithTheme.displayLarge),
                    const SizedBox(height: 4),
                    Text(
                      'KEEP THE BUILD GOING',
                      style: MonolithTheme.labelMedium.copyWith(
                        color: MonolithTheme.outline,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (!SupportLinks.isConfigured)
                      _unconfigured()
                    else ...[
                      if (SupportLinks.hasUpi) _upiCard(context),
                      if (SupportLinks.hasUpi && SupportLinks.hasBuyMeACoffee)
                        const SizedBox(height: 16),
                      if (SupportLinks.hasBuyMeACoffee)
                        _buyMeACoffeeCard(context),
                    ],
                    const SizedBox(height: 16),
                    _note(),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: MonolithBottomNav(
        currentIndex: 0,
        onTap: (i) {
          const routes = [
            '/dashboard',
            '/ai-vision',
            '/projections',
            '/settings'
          ];
          Navigator.pushReplacementNamed(context, routes[i]);
        },
      ),
    );
  }

  Widget _topBar(BuildContext context) => Container(
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
            Text('Void_Factor', style: MonolithTheme.headlineLarge),
          ],
        ),
      );

  Widget _unconfigured() => MonolithCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.info_outline,
                    color: MonolithTheme.primary, size: 18),
                const SizedBox(width: 8),
                Text(unconfiguredTitle, style: MonolithTheme.labelLarge),
              ],
            ),
            const SizedBox(height: 12),
            Text(unconfiguredBody, style: MonolithTheme.bodyMedium),
          ],
        ),
      );

  Widget _upiCard(BuildContext context) {
    return MonolithCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                color: MonolithTheme.primary,
                child: const Icon(Icons.qr_code_2,
                    color: MonolithTheme.surface, size: 18),
              ),
              const SizedBox(width: 12),
              Text('UPI (INDIA)', style: MonolithTheme.headlineMedium),
            ],
          ),
          const SizedBox(height: 16),
          Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(
                  color: MonolithTheme.primary,
                  width: MonolithTheme.heroBorderWidth,
                ),
              ),
              // A real code generated from the same URI the button below opens.
              // White background and black modules regardless of theme: a
              // scanner needs the contrast, not the brand.
              child: QrImageView(
                data: SupportLinks.upiUri.toString(),
                version: QrVersions.auto,
                size: 200,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Colors.black,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Colors.black,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: SelectableText(
              SupportLinks.upiVpa,
              style: MonolithTheme.labelMedium,
            ),
          ),
          const SizedBox(height: 16),
          MonolithButton(
            label: 'OPEN UPI APP',
            onPressed: () => _open(
              context,
              SupportLinks.upiUri,
              // A phone with no UPI app installed is the ordinary case outside
              // India, and the code above still works for someone else's phone.
              failureMessage: couldNotOpenUpi,
              mode: LaunchMode.externalApplication,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buyMeACoffeeCard(BuildContext context) {
    return MonolithCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                color: MonolithTheme.primary,
                child: const Icon(Icons.coffee,
                    color: MonolithTheme.surface, size: 18),
              ),
              const SizedBox(width: 12),
              Text('BUY ME A COFFEE',
                  style: MonolithTheme.headlineMedium),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Card and international payments, handled by Buy Me a Coffee.',
            style: MonolithTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          MonolithButton(
            label: 'OPEN IN BROWSER',
            style: MonolithButtonStyle.secondary,
            onPressed: () => _open(
              context,
              SupportLinks.buyMeACoffeeUri,
              failureMessage: couldNotOpenLink,
              mode: LaunchMode.externalApplication,
            ),
          ),
        ],
      ),
    );
  }

  Widget _note() => MonolithCard(
        inverted: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.info_outline,
                    color: MonolithTheme.surface, size: 18),
                const SizedBox(width: 8),
                Text(
                  'NOTE',
                  style: MonolithTheme.labelLarge
                      .copyWith(color: MonolithTheme.surface),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Support is voluntary and buys nothing: there is no paid tier and '
              'no feature behind one. Payments are handled entirely by your '
              'UPI app or by Buy Me a Coffee — this app never sees them.',
              style: MonolithTheme.bodyMedium
                  .copyWith(color: MonolithTheme.surfaceContainerHigh),
            ),
          ],
        ),
      );

  Future<void> _open(
    BuildContext context,
    Uri uri, {
    required String failureMessage,
    LaunchMode mode = LaunchMode.platformDefault,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: mode);
    } catch (_) {
      // Android throws rather than returning false when nothing can handle the
      // intent, so both outcomes have to mean the same thing here.
      opened = false;
    }
    if (!opened) {
      messenger.showSnackBar(SnackBar(content: Text(failureMessage)));
    }
  }
}
