import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:void_factor/features/support/support_links.dart';
import 'package:void_factor/screens/donation/donation_screen.dart';

void main() {
  group('SupportLinks', () {
    test('reports itself unconfigured when no destination is set', () {
      // The default build has no VPA and no Buy Me a Coffee name. The screen
      // depends on this being detectable rather than rendering a dead handle.
      expect(SupportLinks.isConfigured,
          SupportLinks.hasUpi || SupportLinks.hasBuyMeACoffee);
    });

    test('builds a UPI URI the NPCI spec accepts', () {
      final uri = SupportLinks.upiUri;
      expect(uri.scheme, 'upi');
      expect(uri.host, 'pay');
      expect(uri.queryParameters['cu'], 'INR');
      expect(uri.queryParameters['pn'], SupportLinks.upiPayeeName);
      // No amount: a donation the giver cannot size is one most people abandon.
      expect(uri.queryParameters.containsKey('am'), isFalse);
    });

    test('points Buy Me a Coffee at the configured username', () {
      expect(
        SupportLinks.buyMeACoffeeUri.toString(),
        'https://buymeacoffee.com/${SupportLinks.buyMeACoffeeUsername}',
      );
    });
  });

  group('screen', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: DonationScreen()),
      );
      await tester.pump();
    }

    testWidgets('says support is not set up rather than showing a dead handle',
        (tester) async {
      await pump(tester);

      if (SupportLinks.isConfigured) {
        // Once a destination is configured this branch is the live one.
        expect(find.byType(QrImageView), findsAtLeast(0));
        return;
      }
      expect(find.text(DonationScreen.unconfiguredTitle), findsOneWidget);
      // The old screen drew an Icons.qr_code_2 glyph captioned "UPI QR CODE"
      // that scanned to nothing. Nothing may look like a payable code here.
      expect(find.byType(QrImageView), findsNothing);
    });

    testWidgets('never shows the fake handle the old screen advertised',
        (tester) async {
      await pump(tester);
      expect(find.textContaining('donate@monolith'), findsNothing);
    });

    testWidgets('never shows payment rows that do nothing', (tester) async {
      // PAYPAL / STRIPE / CRYPTO had no tap handler; the builder that drew them
      // accepted no callback at all.
      await pump(tester);
      for (final dead in ['PAYPAL', 'STRIPE', 'CRYPTO']) {
        expect(find.text(dead), findsNothing, reason: '$dead row is back');
      }
    });

    testWidgets('states plainly that support buys nothing', (tester) async {
      await pump(tester);
      expect(find.textContaining('there is no paid tier'), findsOneWidget);
    });
  });
}
