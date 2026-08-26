import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/weight_log/weight_log_providers.dart';
import 'package:void_factor/models/weight_entry.dart';
import 'package:void_factor/screens/stats/log_weight_sheet.dart';

/// Stands in for the log.
///
/// The real notifier reads and rewrites a JSON file, which a widget test cannot
/// drive — `testWidgets` runs inside `fake_async`, where a `dart:io` future never
/// completes. `test/weight_log_providers_test.dart` covers that half against real
/// disk; these tests are about what the sheet does with each outcome.
class FakeWeightLog extends WeightLog {
  FakeWeightLog({this.outcome = WeightSaveOutcome.saved, this.failure});

  final WeightSaveOutcome outcome;
  final Object? failure;

  final List<WeightEntry> added = [];

  @override
  Future<List<WeightEntry>> build() async => const [];

  @override
  Future<WeightSaveOutcome> add(WeightEntry entry) async {
    final error = failure;
    if (error != null) throw error;
    added.add(entry);
    return outcome;
  }
}

void main() {
  late FakeWeightLog log;

  /// What `LogWeightSheet.show` resolved to, so the caller's contract is asserted
  /// rather than assumed: the projections screen decides whether to warn about an
  /// unsynced profile from this value alone.
  late List<WeightSaveOutcome?> outcomes;

  setUp(() {
    log = FakeWeightLog();
    outcomes = [];
  });

  Finder field() => find.byType(TextFormField);

  Future<void> openSheet(WidgetTester tester, {double seedKg = 80}) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [weightLogProvider.overrideWith(() => log)],
      child: MaterialApp(
        // Opened through `show` from a real route, rather than pumped directly:
        // the sheet's result is half of its contract, and only a route can
        // deliver it.
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  outcomes.add(
                    await LogWeightSheet.show(context, seedKg: seedKg),
                  );
                },
                child: const Text('OPEN'),
              ),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
  }

  group('the field', () {
    testWidgets('starts at the weight the user is coming from', (tester) async {
      await openSheet(tester, seedKg: 78.4);

      expect(find.widgetWithText(TextFormField, '78.4'), findsOneWidget);
    });

    testWidgets('drops a decimal point that says nothing', (tester) async {
      await openSheet(tester, seedKg: 80);

      expect(find.widgetWithText(TextFormField, '80'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '80.0'), findsNothing);
    });

    testWidgets('starts empty rather than at a value it would reject',
        (tester) async {
      await openSheet(tester, seedKg: 0);

      expect(find.text('E.G. 74.5'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '0'), findsNothing);
    });

    testWidgets('accepts only what a weight is made of', (tester) async {
      await openSheet(tester, seedKg: 80);

      await tester.enterText(field(), '7a4.5kg');
      await tester.pump();

      // Filtered as it is typed, not rejected at save: the steppers parse this
      // text, and they would fail on input the user believes is fine.
      expect(find.widgetWithText(TextFormField, '74.5'), findsOneWidget);
    });
  });

  group('the steppers', () {
    testWidgets('nudge the value by their own label', (tester) async {
      await openSheet(tester, seedKg: 80);

      await tester.tap(find.text('+0.1'));
      await tester.pump();
      expect(find.widgetWithText(TextFormField, '80.1'), findsOneWidget);

      await tester.tap(find.text('-0.5'));
      await tester.pump();
      expect(find.widgetWithText(TextFormField, '79.6'), findsOneWidget);
    });

    testWidgets('step from what is typed, not from the seed', (tester) async {
      await openSheet(tester, seedKg: 80);

      await tester.enterText(field(), '70');
      await tester.tap(find.text('+0.5'));
      await tester.pump();

      expect(find.widgetWithText(TextFormField, '70.5'), findsOneWidget);
    });

    testWidgets('cannot step past the bounds of a plausible weight',
        (tester) async {
      await openSheet(tester, seedKg: WeightEntry.minKg);

      await tester.tap(find.text('-0.5'));
      await tester.pump();

      expect(
        find.widgetWithText(TextFormField, '20'),
        findsOneWidget,
        reason: 'clamped rather than stepped below the minimum',
      );
    });

    testWidgets('are inert when there is no number to step from',
        (tester) async {
      await openSheet(tester, seedKg: 0);

      await tester.tap(find.text('+0.1'));
      await tester.pump();

      // A stepper that invented 0.1 kg would be offering a weight nobody has.
      expect(find.widgetWithText(TextFormField, '0.1'), findsNothing);
      expect(find.text('E.G. 74.5'), findsOneWidget);
    });
  });

  group('saving', () {
    testWidgets('records the weight and closes with the outcome',
        (tester) async {
      await openSheet(tester, seedKg: 80);

      await tester.enterText(field(), '77.5');
      await tester.tap(find.text(LogWeightSheet.saveLabel));
      await tester.pumpAndSettle();

      expect(log.added.single.weightKg, 77.5);
      expect(find.byType(LogWeightSheet), findsNothing);
      expect(outcomes, [WeightSaveOutcome.saved]);
    });

    testWidgets('passes the unsynced outcome back to the caller',
        (tester) async {
      log = FakeWeightLog(outcome: WeightSaveOutcome.savedWithoutSync);
      await openSheet(tester, seedKg: 80);

      await tester.tap(find.text(LogWeightSheet.saveLabel));
      await tester.pumpAndSettle();

      // The screen shows its warning off this value, and nothing else.
      expect(outcomes, [WeightSaveOutcome.savedWithoutSync]);
    });

    testWidgets('resolves to null when the user dismisses the sheet',
        (tester) async {
      await openSheet(tester, seedKg: 80);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(outcomes, [null]);
      expect(log.added, isEmpty);
    });

    testWidgets('refuses a weight outside the plausible range and says why',
        (tester) async {
      await openSheet(tester, seedKg: 80);

      await tester.enterText(field(), '750');
      await tester.tap(find.text(LogWeightSheet.saveLabel));
      await tester.pumpAndSettle();

      // Refused rather than clamped: a silently clamped 500 is a weight the user
      // never typed, and the projection would then be built on it.
      expect(find.text(LogWeightSheet.invalidWeight), findsOneWidget);
      expect(log.added, isEmpty);
      expect(find.byType(LogWeightSheet), findsOneWidget);
    });

    testWidgets('refuses an empty field', (tester) async {
      await openSheet(tester, seedKg: 0);

      await tester.tap(find.text(LogWeightSheet.saveLabel));
      await tester.pumpAndSettle();

      expect(find.text(LogWeightSheet.invalidWeight), findsOneWidget);
      expect(log.added, isEmpty);
    });

    test('names the bounds it enforces', () {
      // Interpolated from the model rather than written out, so the number the
      // user is told cannot drift from the number that is enforced.
      expect(LogWeightSheet.invalidWeight, contains('20'));
      expect(LogWeightSheet.invalidWeight, contains('500'));
    });

    testWidgets('stays open holding the number when the write failed',
        (tester) async {
      log = FakeWeightLog(
        failure: const WeightLogException(WeightLog.errorSaveFailed),
      );
      await openSheet(tester, seedKg: 80);

      await tester.enterText(field(), '77.5');
      await tester.tap(find.text(LogWeightSheet.saveLabel));
      await tester.pumpAndSettle();

      // Closing would look like a save, and the entry is not on disk.
      expect(find.byType(LogWeightSheet), findsOneWidget);
      expect(find.text(WeightLog.errorSaveFailed), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '77.5'), findsOneWidget);
      expect(outcomes, isEmpty);
    });

    testWidgets('offers the save again after a failure', (tester) async {
      log = FakeWeightLog(
        failure: const WeightLogException(WeightLog.errorSaveFailed),
      );
      await openSheet(tester, seedKg: 80);

      await tester.tap(find.text(LogWeightSheet.saveLabel));
      await tester.pumpAndSettle();

      // Not stuck on 'SAVING…' — the button has to come back or the sheet is a
      // dead end.
      expect(find.text(LogWeightSheet.saveLabel), findsOneWidget);
      expect(find.text(LogWeightSheet.savingLabel), findsNothing);
    });
  });
}
