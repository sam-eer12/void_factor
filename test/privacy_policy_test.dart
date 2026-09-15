import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/legal/privacy_policy.dart';
import 'package:void_factor/screens/settings/privacy_policy_screen.dart';

import '../tool/privacy_policy_html.dart';

/// The policy is one set of facts rendered twice: as a screen in the app and as
/// a page on the web, because Google Play requires a public URL and a reader
/// offline requires neither a browser nor a network.
///
/// Two copies of a legal document drift, and a privacy policy that has drifted
/// from what the app does is worse than none — so the web page is generated
/// from the same constant the screen reads, and the test below fails if the
/// checked-in file is not what the generator would produce today.
void main() {
  group('content', () {
    test('every section says something', () {
      expect(PrivacyPolicy.sections, isNotEmpty);
      for (final section in PrivacyPolicy.sections) {
        expect(section.title, isNotEmpty);
        expect(section.paragraphs, isNotEmpty,
            reason: '${section.title} has a heading and no text');
        for (final paragraph in section.paragraphs) {
          expect(paragraph.trim(), isNotEmpty);
        }
      }
    });

    test('titles are unique, so a reader can be pointed at one', () {
      final titles = PrivacyPolicy.sections.map((s) => s.title).toList();
      expect(titles.toSet(), hasLength(titles.length));
    });

    test('the contact address appears in the text, not just in metadata', () {
      // A policy naming no reachable human is not a policy. The address has to
      // be in a paragraph someone reads, not only in a constant we render in
      // small print.
      final body = PrivacyPolicy.sections
          .expand((s) => s.paragraphs)
          .join('\n');
      expect(body, contains(PrivacyPolicy.contactEmail));
    });

    test('no placeholder text survived', () {
      final all = [
        PrivacyPolicy.effectiveDate,
        PrivacyPolicy.contactEmail,
        ...PrivacyPolicy.sections.expand((s) => [s.title, ...s.paragraphs]),
      ].join('\n').toLowerCase();
      for (final marker in ['lorem', 'tbd', 'todo', 'xxx', '[insert']) {
        expect(all, isNot(contains(marker)), reason: 'left a $marker behind');
      }
    });
  });

  group('the hosted page', () {
    final file = File('firebase_hosting/public/privacy.html');

    test('is checked in', () {
      expect(file.existsSync(), isTrue,
          reason: 'run: dart run tool/privacy_policy_html.dart');
    });

    test('is exactly what the generator produces today', () {
      // The drift guard. Editing the policy without regenerating fails here.
      expect(
        file.readAsStringSync(),
        renderPrivacyPolicyHtml(),
        reason: 'privacy.html is stale — run: '
            'dart run tool/privacy_policy_html.dart',
      );
    });

    test('carries every section and the contact address', () {
      final html = file.readAsStringSync();
      for (final section in PrivacyPolicy.sections) {
        expect(html, contains(section.title));
      }
      expect(html, contains(PrivacyPolicy.effectiveDate));
      expect(html, contains(PrivacyPolicy.contactEmail));
    });

    test('escapes markup rather than emitting it', () {
      // A stray < or & in the policy text must not become markup, and the
      // generator is the only thing standing between the two.
      const nasty = PolicySection(
        title: 'A & B',
        paragraphs: ['5 < 6 and "quoted" text'],
      );
      final html = renderPrivacyPolicyHtml(sections: [nasty]);
      expect(html, contains('A &amp; B'));
      expect(html, contains('5 &lt; 6'));
      expect(html, isNot(contains('5 < 6')));
    });
  });

  group('the screen', () {
    Future<void> pumpScreen(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: PrivacyPolicyScreen()),
      );
      await tester.pump();
    }

    testWidgets('renders every section heading', (tester) async {
      await pumpScreen(tester);
      for (final section in PrivacyPolicy.sections) {
        expect(find.text(section.title), findsOneWidget,
            reason: '${section.title} never made it onto the screen');
      }
    });

    testWidgets('renders every paragraph', (tester) async {
      // The whole point of the in-app copy is that it is readable without a
      // browser, so a section that renders its heading and drops its body is
      // a failure, not a cosmetic issue.
      await pumpScreen(tester);
      for (final section in PrivacyPolicy.sections) {
        for (final paragraph in section.paragraphs) {
          expect(find.text(paragraph), findsOneWidget);
        }
      }
    });

    testWidgets('dates itself, so a reader knows which version this is',
        (tester) async {
      await pumpScreen(tester);
      expect(find.textContaining(PrivacyPolicy.effectiveDate), findsOneWidget);
    });
  });
}
