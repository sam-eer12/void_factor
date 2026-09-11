import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/data_transfer/data_bundle.dart';
import 'package:void_factor/features/data_transfer/data_transfer_providers.dart';
import 'package:void_factor/screens/settings/privacy_screen.dart';

class RecordingGateway implements DataFileGateway {
  String? pickReturns;
  Object? shareThrows;
  int shareCount = 0;

  @override
  Future<void> share(String contents, String filename) async {
    shareCount++;
    if (shareThrows != null) throw shareThrows!;
  }

  @override
  Future<String?> pick() async => pickReturns;
}

void main() {
  group('importedLabel', () {
    test('counts what was added, not what the file held', () {
      // After re-importing a file already on the device, "added 0" is the true
      // and reassuring answer; "imported 200" would be a lie.
      expect(
        PrivacyScreen.importedLabel(
          const ImportSummary(foodEntriesAdded: 0, weightEntriesAdded: 0),
        ),
        PrivacyScreen.nothingImportedLabel,
      );
    });

    test('singular and plural read correctly', () {
      expect(
        PrivacyScreen.importedLabel(
          const ImportSummary(foodEntriesAdded: 1, weightEntriesAdded: 0),
        ),
        'ADDED 1 MEAL',
      );
      expect(
        PrivacyScreen.importedLabel(
          const ImportSummary(foodEntriesAdded: 3, weightEntriesAdded: 0),
        ),
        'ADDED 3 MEALS',
      );
    });

    test('names both kinds when both arrived', () {
      expect(
        PrivacyScreen.importedLabel(
          const ImportSummary(foodEntriesAdded: 2, weightEntriesAdded: 1),
        ),
        'ADDED 2 MEALS AND 1 WEIGH-IN',
      );
    });

    test('omits a kind that gained nothing', () {
      expect(
        PrivacyScreen.importedLabel(
          const ImportSummary(foodEntriesAdded: 0, weightEntriesAdded: 4),
        ),
        'ADDED 4 WEIGH-INS',
      );
    });
  });

  group('screen', () {
    late RecordingGateway gateway;

    setUp(() => gateway = RecordingGateway());

    Future<void> pumpScreen(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [dataFileGatewayProvider.overrideWithValue(gateway)],
          child: const MaterialApp(home: PrivacyScreen()),
        ),
      );
      await tester.pump();
    }

    testWidgets('says plainly that the logs are device-only', (tester) async {
      await pumpScreen(tester);
      // The one fact a user needs before deciding whether to export.
      expect(find.textContaining('only on this phone'), findsOneWidget);
    });

    testWidgets('offers both directions and the delete path', (tester) async {
      await pumpScreen(tester);
      expect(find.text('EXPORT MY DATA'), findsOneWidget);
      expect(find.text('IMPORT A FILE'), findsOneWidget);
      expect(find.text('DELETE ACCOUNT'), findsOneWidget);
    });

    testWidgets('a rejected file is reported rather than passing silently',
        (tester) async {
      gateway.pickReturns = '{"not":"ours"}';
      await pumpScreen(tester);

      // The button sits below the fold on a test-sized surface; without this
      // the tap misses and the assertion below passes for the wrong reason.
      await tester.ensureVisible(find.text('IMPORT A FILE'));
      await tester.tap(find.text('IMPORT A FILE'));
      await tester.pump();
      await tester.pump();

      expect(
        find.text(DataTransferController.errorUnreadableFile),
        findsOneWidget,
      );
    });

    testWidgets('a dismissed picker says nothing at all', (tester) async {
      gateway.pickReturns = null;
      await pumpScreen(tester);

      await tester.ensureVisible(find.text('IMPORT A FILE'));
      await tester.tap(find.text('IMPORT A FILE'));
      await tester.pump();
      await tester.pump();

      // Backing out is a decision, not a failure.
      expect(find.byType(SnackBar), findsNothing);
    });
  });
}
